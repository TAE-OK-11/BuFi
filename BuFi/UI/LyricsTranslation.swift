import Foundation
import NaturalLanguage
import SwiftUI
@preconcurrency import Translation

enum LyricsTranslationPhase: Equatable {
    case idle
    case loadingCache
    case preparing
    case translating(completed: Int, total: Int)
    case ready
    case unsupported
    case failed

    var isWorking: Bool {
        switch self {
        case .loadingCache, .preparing, .translating:
            true
        case .idle, .ready, .unsupported, .failed:
            false
        }
    }

    var statusText: String? {
        switch self {
        case .loadingCache:
            "저장된 번역 확인 중"
        case .preparing:
            "번역 모델 준비 중"
        case let .translating(completed, total):
            "번역 중 \(completed)/\(total)"
        case .unsupported:
            "이 언어는 번역할 수 없습니다"
        case .failed:
            "번역을 완료하지 못했습니다"
        case .idle, .ready:
            nil
        }
    }
}

struct LyricsTranslationTaskHost: View {
    let accountScope: String?
    let songID: String
    let lines: [LyricLine]
    let isEnabled: Bool

    @Binding var translations: [Int: String]
    @Binding var phase: LyricsTranslationPhase
    @State private var loadedCacheIdentity: LyricsTranslationCacheIdentity?

    private var targetLanguageCode: String {
        Locale.current.language.languageCode?.identifier ?? "ko"
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 18.0, *) {
            SystemLyricsTranslationTaskHost(
                accountScope: accountScope,
                songID: songID,
                lines: lines,
                targetLanguageCode: targetLanguageCode,
                isEnabled: isEnabled,
                translations: $translations,
                phase: $phase
            )
        } else {
            Color.clear
                .task(id: fallbackIdentity) {
                    await loadFallbackCache()
                }
        }
    }

    private var fallbackIdentity: LyricsTranslationContentIdentity {
        LyricsTranslationContentIdentity(
            accountScope: accountScope,
            songID: songID,
            targetLanguageCode: targetLanguageCode,
            isEnabled: isEnabled,
            lines: lines
        )
    }

    @MainActor
    private func loadFallbackCache() async {
        if loadedCacheIdentity != cacheIdentity {
            loadedCacheIdentity = cacheIdentity
            translations = [:]
        }
        guard isEnabled else {
            phase = translations.isEmpty ? .idle : .ready
            return
        }
        guard let accountScope else {
            translations = [:]
            phase = .unsupported
            return
        }
        phase = .loadingCache
        let cached = await AppDatabase.shared.loadLyricsTranslations(
            scope: accountScope,
            songID: songID,
            targetLanguage: targetLanguageCode,
            sourceLines: Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0.text) })
        )
        guard !Task.isCancelled else { return }
        translations = cached
        phase = cached.isEmpty ? .unsupported : .ready
    }

    private var cacheIdentity: LyricsTranslationCacheIdentity {
        LyricsTranslationCacheIdentity(
            accountScope: accountScope,
            songID: songID,
            targetLanguageCode: targetLanguageCode
        )
    }
}

private struct LyricsTranslationCacheIdentity: Equatable {
    let accountScope: String?
    let songID: String
    let targetLanguageCode: String
}

private struct LyricsTranslationContentIdentity: Equatable {
    let accountScope: String?
    let songID: String
    let targetLanguageCode: String
    let isEnabled: Bool
    let lines: [LyricLine]
}

private struct LyricsTranslationPlan: Sendable {
    let sourceLanguageCode: String
    let lines: [LyricLine]
}

private enum LyricsTranslationPlanner {
    static func makePlan(
        lines: [LyricLine],
        targetLanguageCode: String,
        cachedTranslations: [Int: String]
    ) -> LyricsTranslationPlan? {
        let targetBase = baseLanguageCode(targetLanguageCode)
        let candidates = lines.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && cachedTranslations[$0.id] == nil
        }
        guard !candidates.isEmpty else { return nil }

        var recognized = [Int: String](minimumCapacity: candidates.count)
        for line in candidates {
            guard let language = NLLanguageRecognizer.dominantLanguage(
                for: line.text
            ) else { continue }
            recognized[line.id] = language.rawValue
        }
        var weights = [String: Int]()
        for line in candidates {
            guard let code = recognized[line.id] else { continue }
            let base = baseLanguageCode(code)
            guard base != targetBase else { continue }
            weights[base, default: 0] += max(line.text.count, 1)
        }
        guard let sourceLanguageCode = weights.max(by: { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key > rhs.key }
            return lhs.value < rhs.value
        })?.key else {
            return nil
        }

        let sourceLines = candidates.filter { line in
            guard let code = recognized[line.id] else { return true }
            return baseLanguageCode(code) == sourceLanguageCode
        }
        guard !sourceLines.isEmpty else { return nil }
        return LyricsTranslationPlan(
            sourceLanguageCode: sourceLanguageCode,
            lines: sourceLines
        )
    }

    private static func baseLanguageCode(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-", maxSplits: 1)
            .first
            .map { String($0).lowercased() } ?? identifier.lowercased()
    }
}

@available(iOS 18.0, *)
private struct SystemLyricsTranslationTaskHost: View {
    let accountScope: String?
    let songID: String
    let lines: [LyricLine]
    let targetLanguageCode: String
    let isEnabled: Bool

    @Binding var translations: [Int: String]
    @Binding var phase: LyricsTranslationPhase

    @State private var configuration: TranslationSession.Configuration?
    @State private var pendingLines: [LyricLine] = []
    @State private var sourceLanguageCode = ""
    @State private var loadedCacheIdentity: LyricsTranslationCacheIdentity?

    var body: some View {
        Color.clear
            .task(id: contentIdentity) {
                await prepareTranslation()
            }
            .translationTask(configuration) { session in
                await translatePendingLines(using: session)
            }
    }

    private var contentIdentity: LyricsTranslationContentIdentity {
        LyricsTranslationContentIdentity(
            accountScope: accountScope,
            songID: songID,
            targetLanguageCode: targetLanguageCode,
            isEnabled: isEnabled,
            lines: lines
        )
    }

    @MainActor
    private func prepareTranslation() async {
        configuration = nil
        pendingLines = []
        sourceLanguageCode = ""
        if loadedCacheIdentity != cacheIdentity {
            loadedCacheIdentity = cacheIdentity
            translations = [:]
        }
        guard isEnabled else {
            phase = translations.isEmpty ? .idle : .ready
            return
        }
        guard let accountScope else {
            translations = [:]
            phase = .failed
            return
        }

        phase = .loadingCache
        let sourceLines = Dictionary(
            uniqueKeysWithValues: lines.map { ($0.id, $0.text) }
        )
        let cached = await AppDatabase.shared.loadLyricsTranslations(
            scope: accountScope,
            songID: songID,
            targetLanguage: targetLanguageCode,
            sourceLines: sourceLines
        )
        guard !Task.isCancelled else { return }
        translations = cached
        guard let plan = LyricsTranslationPlanner.makePlan(
            lines: lines,
            targetLanguageCode: targetLanguageCode,
            cachedTranslations: cached
        ) else {
            phase = cached.isEmpty ? .unsupported : .ready
            return
        }

        phase = .preparing
        let sourceLanguage = Locale.Language(identifier: plan.sourceLanguageCode)
        let targetLanguage = Locale.Language(identifier: targetLanguageCode)
        let availability = LanguageAvailability()
        let status = await availability.status(
            from: sourceLanguage,
            to: targetLanguage
        )
        guard !Task.isCancelled else { return }
        switch status {
        case .installed, .supported:
            sourceLanguageCode = plan.sourceLanguageCode
            pendingLines = plan.lines
            configuration = TranslationSession.Configuration(
                source: sourceLanguage,
                target: targetLanguage
            )
        case .unsupported:
            phase = cached.isEmpty ? .unsupported : .ready
        @unknown default:
            phase = cached.isEmpty ? .unsupported : .ready
        }
    }

    private var cacheIdentity: LyricsTranslationCacheIdentity {
        LyricsTranslationCacheIdentity(
            accountScope: accountScope,
            songID: songID,
            targetLanguageCode: targetLanguageCode
        )
    }

    @MainActor
    private func translatePendingLines(using session: TranslationSession) async {
        let requestSongID = songID
        let requestScope = accountScope
        let requestTargetLanguage = targetLanguageCode
        let requestSourceLanguage = sourceLanguageCode
        let requestedLines = pendingLines
        guard let requestScope,
              !requestSourceLanguage.isEmpty,
              !requestedLines.isEmpty else { return }

        let linesByID = Dictionary(uniqueKeysWithValues: requestedLines.map {
            (String($0.id), $0)
        })
        phase = .translating(completed: 0, total: requestedLines.count)

        do {
            let responses = try await Self.performBatchTranslation(
                using: session,
                lines: requestedLines
            )
            guard !Task.isCancelled,
                  songID == requestSongID,
                  accountScope == requestScope,
                  targetLanguageCode == requestTargetLanguage else { return }
            var nextTranslations = translations
            var records = [LyricsTranslationRecord]()
            records.reserveCapacity(responses.count)
            for response in responses {
                guard let clientIdentifier = response.clientIdentifier,
                      let line = linesByID[clientIdentifier] else { continue }
                let translatedText = response.targetText.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                guard !translatedText.isEmpty else { continue }
                nextTranslations[line.id] = translatedText
                records.append(LyricsTranslationRecord(
                    lineID: line.id,
                    sourceLanguage: requestSourceLanguage,
                    sourceText: line.text,
                    translatedText: translatedText
                ))
            }
            phase = .translating(
                completed: records.count,
                total: requestedLines.count
            )
            let saved = await AppDatabase.shared.saveLyricsTranslations(
                records,
                scope: requestScope,
                songID: requestSongID,
                targetLanguage: requestTargetLanguage
            )
            guard !Task.isCancelled,
                  songID == requestSongID,
                  accountScope == requestScope,
                  targetLanguageCode == requestTargetLanguage else { return }
            translations = nextTranslations
            phase = saved || records.isEmpty ? .ready : .failed
            configuration = nil
        } catch {
            guard !Task.isCancelled else { return }
            phase = translations.isEmpty ? .failed : .ready
            configuration = nil
        }
    }

    @concurrent
    private static func performBatchTranslation(
        using session: TranslationSession,
        lines: [LyricLine]
    ) async throws -> [TranslationSession.Response] {
        let requests = lines.map {
            TranslationSession.Request(
                sourceText: $0.text,
                clientIdentifier: String($0.id)
            )
        }
        return try await session.translations(from: requests)
    }
}
