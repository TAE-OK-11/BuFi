import Foundation

enum PersonalizedMixLLM {
    static func apply(
        to mixes: [PersonalizedMix],
        snapshot: HomeSnapshot,
        recent: [Song],
        lyricIndex: LyricSignatureIndex,
        date: Date = Date()
    ) async -> [PersonalizedMix] {
        let settings = await LyricIntelligenceSettings.load()
        let family = LyricModelFamily.resolve(model: settings.radioModel)
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let month = calendar.component(.month, from: date)
        let today = recent.prefix(6).map { song in
            card(song, lyricIndex: lyricIndex)
        }.joined(separator: "\n")
        var remaining = mixes
        var selected: [PersonalizedMix] = []
        if let index = remaining.firstIndex(where: { $0.kind == .daylist }) {
            selected.append(remaining.remove(at: index))
        }
        let refined = await withTaskGroup(
            of: (String, PersonalizedMix).self,
            returning: [String: PersonalizedMix].self
        ) { group in
            for mix in selected {
                group.addTask {
                    let composed = await compose(
                        mix: mix,
                        family: family,
                        settings: settings,
                        hour: hour,
                        month: month,
                        today: today,
                        lyricIndex: lyricIndex
                    )
                    return (mix.id, composed)
                }
            }
            var byID: [String: PersonalizedMix] = [:]
            for await item in group {
                byID[item.0] = item.1
            }
            return byID
        }
        var result: [PersonalizedMix] = []
        result.reserveCapacity(mixes.count)
        for mix in selected {
            result.append(refined[mix.id] ?? mix)
        }
        result.append(contentsOf: remaining)
        return result
    }

    private static func compose(
        mix: PersonalizedMix,
        family: LyricModelFamily,
        settings: LyricIntelligenceSettings,
        hour: Int,
        month: Int,
        today: String,
        lyricIndex: LyricSignatureIndex
    ) async -> PersonalizedMix {
        let brief = PersonalizedMixCatalog.brief(
            forKind: mix.kind,
            mixID: mix.id,
            hour: hour,
            month: month
        )
        let rankedPool = mix.songs.sorted { lhs, rhs in
            let left = brief.score(
                song: lhs,
                signature: lyricIndex.bySongID[lhs.id],
                searchableText: "\(lhs.title) \(lhs.artist) \(lhs.genre ?? "")"
            )
            let right = brief.score(
                song: rhs,
                signature: lyricIndex.bySongID[rhs.id],
                searchableText: "\(rhs.title) \(rhs.artist) \(rhs.genre ?? "")"
            )
            if left == right { return lhs.id < rhs.id }
            return left > right
        }
        let pool = Array(rankedPool.prefix(family.reviewPoolLimit + 8))
        guard pool.count >= 4 else { return mix }
        let prompt = LyricModelPrompts.playlistCompose(
            family: family,
            title: mix.title,
            brief: brief,
            hour: hour,
            month: month,
            today: today.isEmpty ? "(no listens yet today)" : today,
            candidates: pool.enumerated().map { index, song in
                "\(index + 1). \(card(song, lyricIndex: lyricIndex))"
            }.joined(separator: "\n")
        )
        let applePrompt = compactApplePrompt(
            mix: mix,
            pool: pool,
            hour: hour,
            month: month,
            lyricIndex: lyricIndex
        )
        let raw = await completeRecommendation(
            prompt: prompt,
            applePrompt: applePrompt,
            settings: settings
        )
        var parsed = raw.map { parse($0, allowed: Set(pool.map(\.id))) }
        if parsed?.ids == nil, let broken = raw,
           let repaired = await LyricInferenceRuntime.repairedJSON(
            from: broken,
            settings: settings
           ) {
            parsed = parse(repaired, allowed: Set(pool.map(\.id)))
        }
        guard let parsed, let ids = parsed.ids, !ids.isEmpty else { return mix }
        var byID = Dictionary(
            mix.songs.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var songs: [Song] = []
        for id in ids {
            guard let song = byID.removeValue(forKey: id) else { continue }
            songs.append(song)
        }
        for song in mix.songs where byID.removeValue(forKey: song.id) != nil {
            songs.append(song)
        }
        return PersonalizedMix(
            id: mix.id,
            title: mix.title,
            subtitle: parsed.subtitle?.isEmpty == false ? parsed.subtitle! : mix.subtitle,
            songs: songs,
            kind: mix.kind,
            artworkCoverArt: mix.artworkCoverArt,
            mood: mix.mood.isEmpty ? brief.mood : mix.mood,
            theme: mix.theme.isEmpty ? brief.theme : mix.theme,
            audioFeel: mix.audioFeel.isEmpty ? brief.audioFeel : mix.audioFeel
        )
    }

    private static func completeRecommendation(
        prompt: String,
        applePrompt: String,
        settings: LyricIntelligenceSettings
    ) async -> String? {
        var attempted = Set<String>()
        var trail: [String] = []

        func attempt(
            _ target: LyricChatTarget,
            title: String,
            maxTokens: Int
        ) async -> String? {
            guard attempted.insert(target.circuitKey).inserted else { return nil }
            RecommendationDiagnostics.record(
                kind: .llm,
                level: .info,
                title: title,
                detail: "\(target.source) \(target.model)"
            )
            switch await LyricInferenceRuntime.radioAttempt(
                prompt: prompt,
                target: target,
                maxTokens: maxTokens,
                onDelta: { _ in }
            ) {
            case .text(let text):
                return text
            case .rateLimited:
                trail.append("\(target.source)/\(target.model):429")
            case .failed:
                trail.append("\(target.source)/\(target.model)")
            }
            return nil
        }

        for target in LyricInferenceRuntime.radioTargets(settings) {
            if let text = await attempt(
                target,
                title: String(localized: "AI 재생목록 모델을 호출합니다"),
                maxTokens: 900
            ) {
                return text
            }
        }

        // Exhaust configured cloud providers before using the on-device model.
        // This keeps the larger-context Gemini/Groq path useful while Apple 3B
        // remains a privacy-preserving last fallback.
        for target in LyricInferenceRuntime.fallbackTargets(settings, excluding: .off) {
            if let text = await attempt(
                target,
                title: String(localized: "AI 재생목록 대체 모델을 호출합니다"),
                maxTokens: 900
            ) {
                return text
            }
        }

        RecommendationDiagnostics.record(
            kind: .llm,
            level: .info,
            title: String(localized: "Apple 3B 재생목록 모델을 호출합니다"),
            detail: "apple-intelligence-3b"
        )
        if let text = await AppleFoundationLyricClient.complete(applePrompt) {
            RecommendationDiagnostics.record(
                kind: .llm,
                level: .info,
                title: String(localized: "Apple 3B로 재생목록을 구성했습니다"),
                detail: "apple-intelligence-3b"
            )
            return text
        }
        trail.append("apple-3b")

        RecommendationDiagnostics.record(
            kind: .llm,
            level: .error,
            title: String(localized: "AI 재생목록 호출이 모두 실패했습니다"),
            detail: trail.isEmpty ? "none" : trail.joined(separator: " → ")
        )
        return nil
    }

    private static func compactApplePrompt(
        mix: PersonalizedMix,
        pool: [Song],
        hour: Int,
        month: Int,
        lyricIndex: LyricSignatureIndex
    ) -> String {
        let candidates = pool.prefix(20).map { song in
            let signature = lyricIndex.bySongID[song.id]
            let mood = (signature?.details.primaryMoods.isEmpty == false
                ? signature?.details.primaryMoods
                : signature?.moods)?.prefix(2).joined(separator: ",") ?? ""
            let genre = signature?.details.genre ?? song.genre ?? ""
            return "\(song.id) | \(song.title) — \(song.artist) | \(genre) | \(mood)"
        }.joined(separator: "\n")
        return """
        Build the playlist "\(mix.title)" for month \(month), hour \(hour).
        Reorder only listed song ids. Prefer a coherent flow and avoid repeating one artist too much.
        Return JSON only:
        {"ids":[],"subtitle":""}
        Candidates:
        \(candidates)
        """
    }

    static func parse(
        _ raw: String,
        allowed: Set<String>
    ) -> (ids: [String]?, subtitle: String?) {
        let json = LyricJSONExtractor.object(from: raw) ?? raw
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return (RecommendationLLMReview.parseIDs(raw, allowed: allowed), nil)
        }
        let ids = RecommendationLLMReview.parseIDs(json, allowed: allowed)
        let subtitle = (dictionary["subtitle"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (ids, subtitle)
    }

    private static func card(_ song: Song, lyricIndex: LyricSignatureIndex) -> String {
        RecommendationPromptCard.make(song, lyricIndex: lyricIndex, excerptLimit: 120)
    }
}
