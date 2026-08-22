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

struct LyricsTranslationEligibilityIdentity: Hashable, Sendable {
    let targetLanguageCode: String
    let lines: [LyricLine]

    init(
        lines: [LyricLine],
        targetLanguageCode: String = LyricsTranslationEligibility.targetLanguageCode
    ) {
        self.targetLanguageCode = targetLanguageCode
        self.lines = lines
    }
}

enum LyricsTranslationEligibility {
    static var targetLanguageCode: String {
        Locale.current.language.languageCode?.identifier ?? "ko"
    }

    /// Translation is an explicit affordance. Korean-only lyrics never show it,
    /// regardless of the device locale. A deterministic Unicode scan keeps even
    /// very short Hangul lyrics out of the language recognizer, while mixed or
    /// foreign-language lyrics remain eligible for an explicit translation.
    static func shouldOfferTranslation(
        lines: [LyricLine],
        targetLanguageCode: String = LyricsTranslationEligibility.targetLanguageCode
    ) -> Bool {
        let meaningfulLines = lines.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !meaningfulLines.isEmpty else { return false }

        let letterScalars = meaningfulLines.flatMap { line in
            line.text.unicodeScalars.filter {
                CharacterSet.letters.contains($0)
            }
        }
        guard let firstLetter = letterScalars.first else { return false }
        let isKoreanOnly = isHangul(firstLetter.value)
            && letterScalars.dropFirst().allSatisfy { isHangul($0.value) }
        if isKoreanOnly {
            return false
        }

        let targetBase = baseLanguageCode(targetLanguageCode)
        if targetBase == "ko" { return true }

        let sample = String(
            meaningfulLines
                .lazy
                .map(\.text)
                .joined(separator: "\n")
                .prefix(4_000)
        )
        guard let language = NLLanguageRecognizer.dominantLanguage(for: sample) else {
            return false
        }
        return baseLanguageCode(language.rawValue) != targetBase
    }

    private static func isHangul(_ value: UInt32) -> Bool {
        (0x1100...0x11FF).contains(value)
            || (0x3130...0x318F).contains(value)
            || (0xA960...0xA97F).contains(value)
            || (0xAC00...0xD7AF).contains(value)
            || (0xD7B0...0xD7FF).contains(value)
    }

    private static func baseLanguageCode(_ identifier: String) -> String {
        identifier
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-", maxSplits: 1)
            .first
            .map { String($0).lowercased() } ?? identifier.lowercased()
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
        LyricsTranslationEligibility.targetLanguageCode
    }

    private var translationCacheLanguage: String {
        LyricsTranslationCachePolicy.languageKey(for: targetLanguageCode)
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
            targetLanguage: translationCacheLanguage,
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
            targetLanguageCode: translationCacheLanguage
        )
    }
}

private struct LyricsTranslationCacheIdentity: Equatable {
    let accountScope: String?
    let songID: String
    let targetLanguageCode: String
}

private enum LyricsTranslationCachePolicy {
    // Context-free translations from the first implementation must not mask
    // the improved stanza-aware result after an app update.
    static func languageKey(for targetLanguageCode: String) -> String {
        if #available(iOS 26.4, *) {
            return "\(targetLanguageCode)#lyrics-attributed-context-v4"
        }
        return "\(targetLanguageCode)#lyrics-context-v2"
    }
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

private struct LyricsTranslationChunk: Sendable {
    let identifier: String
    let lines: [LyricLine]

    var sourceText: String {
        lines.map(\.text).joined(separator: "\n")
    }
}

private enum LyricsTranslationChunker {
    private static let maximumLines = 12
    private static let maximumCharacters = 1_200
    private static let stanzaGap: TimeInterval = 9
    private static let lineLinkScheme = "bufi-lyric"

    static func makeChunks(from lines: [LyricLine]) -> [LyricsTranslationChunk] {
        var chunks = [LyricsTranslationChunk]()
        var currentLines = [LyricLine]()
        var currentCharacterCount = 0

        func commitCurrentChunk() {
            guard !currentLines.isEmpty else { return }
            chunks.append(LyricsTranslationChunk(
                identifier: "context-\(chunks.count)",
                lines: currentLines
            ))
            currentLines.removeAll(keepingCapacity: true)
            currentCharacterCount = 0
        }

        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let previousLine = currentLines.last
            let startsNewStanza = previousLine.map {
                line.id != $0.id + 1
                    || (line.start > 0
                        && $0.start > 0
                        && line.start - $0.start >= stanzaGap)
            } ?? false
            let exceedsBudget = !currentLines.isEmpty
                && (currentLines.count >= maximumLines
                    || currentCharacterCount + text.count > maximumCharacters)
            if startsNewStanza || exceedsBudget {
                commitCurrentChunk()
            }
            currentLines.append(line)
            currentCharacterCount += text.count
        }
        commitCurrentChunk()
        return chunks
    }

    static func mapTranslatedText(
        _ translatedText: String,
        to lines: [LyricLine]
    ) -> [Int: String]? {
        var translatedLines = translatedText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        while translatedLines.first?.isEmpty == true {
            translatedLines.removeFirst()
        }
        while translatedLines.last?.isEmpty == true {
            translatedLines.removeLast()
        }
        guard translatedLines.count == lines.count,
              translatedLines.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }
        return Dictionary(uniqueKeysWithValues: zip(lines, translatedLines).map {
            ($0.0.id, $0.1)
        })
    }

    @available(iOS 26.4, *)
    static func attributedSourceText(for lines: [LyricLine]) -> AttributedString {
        var result = AttributedString()
        for (index, line) in lines.enumerated() {
            var segment = AttributedString(line.text)
            segment.link = URL(
                string: "\(lineLinkScheme)://line/\(line.id)"
            )
            result.append(segment)
            if index < lines.count - 1 {
                result.append(AttributedString("\n"))
            }
        }
        return result
    }

    @available(iOS 26.4, *)
    static func mapAttributedText(
        _ translatedText: AttributedString,
        expectedLines: [LyricLine]
    ) -> [Int: String]? {
        let expectedLineIDs = Set(expectedLines.map(\.id))
        var fragments = [Int: String]()
        for run in translatedText.runs {
            guard let link = run.link,
                  link.scheme == lineLinkScheme,
                  link.host == "line",
                  let lineID = Int(link.lastPathComponent),
                  expectedLineIDs.contains(lineID) else {
                continue
            }
            let fragment = String(translatedText[run.range].characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !fragment.isEmpty else { continue }
            if let existing = fragments[lineID], !existing.isEmpty {
                fragments[lineID] = "\(existing) \(fragment)"
            } else {
                fragments[lineID] = fragment
            }
        }
        guard fragments.count == expectedLineIDs.count else { return nil }
        return fragments
    }
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
            let detectedBase = baseLanguageCode(code)
            if detectedBase == sourceLanguageCode { return true }
            if detectedBase == targetBase { return false }
            // Language identification is deliberately conservative for short
            // lyric fragments such as "oh", "I do", names, and ad-libs. They
            // inherit the song's dominant source language instead of being
            // dropped after a low-confidence one-line classification.
            let letterCount = line.text.unicodeScalars.lazy.filter {
                CharacterSet.letters.contains($0)
            }.count
            return letterCount <= 24
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

    private var translationCacheLanguage: String {
        LyricsTranslationCachePolicy.languageKey(for: targetLanguageCode)
    }

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
            targetLanguage: translationCacheLanguage,
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
        let availability: LanguageAvailability
        if #available(iOS 26.4, *) {
            availability = LanguageAvailability(
                preferredStrategy: .highFidelity
            )
        } else {
            availability = LanguageAvailability()
        }
        let status = await availability.status(
            from: sourceLanguage,
            to: targetLanguage
        )
        guard !Task.isCancelled else { return }
        switch status {
        case .installed, .supported:
            sourceLanguageCode = plan.sourceLanguageCode
            pendingLines = plan.lines
            if #available(iOS 26.4, *) {
                configuration = TranslationSession.Configuration(
                    source: sourceLanguage,
                    target: targetLanguage,
                    preferredStrategy: .highFidelity
                )
            } else {
                configuration = TranslationSession.Configuration(
                    source: sourceLanguage,
                    target: targetLanguage
                )
            }
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
            targetLanguageCode: translationCacheLanguage
        )
    }

    @MainActor
    private func translatePendingLines(using session: TranslationSession) async {
        let requestSongID = songID
        let requestScope = accountScope
        let requestTargetLanguage = targetLanguageCode
        let requestCacheLanguage = translationCacheLanguage
        let requestSourceLanguage = sourceLanguageCode
        let requestedLines = pendingLines
        guard let requestScope,
              !requestSourceLanguage.isEmpty,
              !requestedLines.isEmpty else { return }

        let linesByID = Dictionary(uniqueKeysWithValues: requestedLines.map {
            ($0.id, $0)
        })
        phase = .translating(completed: 0, total: requestedLines.count)

        do {
            let translatedLines = try await Self.performContextualTranslation(
                using: session,
                lines: requestedLines
            )
            guard !Task.isCancelled,
                  songID == requestSongID,
                  accountScope == requestScope,
                  targetLanguageCode == requestTargetLanguage else { return }
            var nextTranslations = translations
            var records = [LyricsTranslationRecord]()
            records.reserveCapacity(translatedLines.count)
            for (lineID, rawTranslatedText) in translatedLines {
                guard let line = linesByID[lineID] else { continue }
                let translatedText = rawTranslatedText.trimmingCharacters(
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
                targetLanguage: requestCacheLanguage
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
    private static func performContextualTranslation(
        using session: TranslationSession,
        lines: [LyricLine]
    ) async throws -> [Int: String] {
        let chunks = LyricsTranslationChunker.makeChunks(from: lines)
        let chunksByID = Dictionary(uniqueKeysWithValues: chunks.map {
            ($0.identifier, $0)
        })
        let contextualResponses: [TranslationSession.Response]
        if #available(iOS 26.4, *) {
            let contextualRequests = chunks.map {
                TranslationSession.Request(
                    sourceText: LyricsTranslationChunker.attributedSourceText(
                        for: $0.lines
                    ),
                    clientIdentifier: $0.identifier
                )
            }
            contextualResponses = try await session.translations(
                from: contextualRequests
            )
        } else {
            let contextualRequests = chunks.map {
                TranslationSession.Request(
                    sourceText: $0.sourceText,
                    clientIdentifier: $0.identifier
                )
            }
            contextualResponses = try await session.translations(
                from: contextualRequests
            )
        }

        var translatedLines = [Int: String](minimumCapacity: lines.count)
        var unresolvedLineIDs = Set(lines.map(\.id))
        for response in contextualResponses {
            guard let identifier = response.clientIdentifier,
                  let chunk = chunksByID[identifier],
                  let mapped = mappedContextualResponse(
                    response,
                    to: chunk.lines
                  ) else {
                continue
            }
            translatedLines.merge(mapped) { current, _ in current }
            unresolvedLineIDs.subtract(mapped.keys)
        }

        // Translation models occasionally merge poetic line breaks. Preserve
        // correctness by retrying only those ambiguous chunks one line at a
        // time instead of displaying a translation under the wrong lyric.
        let fallbackLines = lines.filter { unresolvedLineIDs.contains($0.id) }
        guard !fallbackLines.isEmpty else { return translatedLines }
        let fallbackRequests = fallbackLines.map {
            TranslationSession.Request(
                sourceText: $0.text,
                clientIdentifier: String($0.id)
            )
        }
        let fallbackResponses = try await session.translations(
            from: fallbackRequests
        )
        for response in fallbackResponses {
            guard let identifier = response.clientIdentifier,
                  let lineID = Int(identifier) else { continue }
            let text = response.targetText.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if !text.isEmpty {
                translatedLines[lineID] = text
            }
        }
        return translatedLines
    }

    nonisolated private static func mappedContextualResponse(
        _ response: TranslationSession.Response,
        to lines: [LyricLine]
    ) -> [Int: String]? {
        if #available(iOS 26.4, *),
           let attributedTargetText = response.attributedTargetText,
           let mapped = LyricsTranslationChunker.mapAttributedText(
                attributedTargetText,
                expectedLines: lines
           ) {
            return mapped
        }
        return LyricsTranslationChunker.mapTranslatedText(
            response.targetText,
            to: lines
        )
    }
}
