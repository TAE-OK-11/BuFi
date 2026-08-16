import Foundation

/// Lane the radio model wants next. The local mixer fills this instead of
/// asking the model to invent library ids.
struct RadioLaneBrief: Equatable, Sendable {
    var moods: [String]
    var themes: [String]
    var energy: ClosedRange<Double>
    var valence: ClosedRange<Double>
    var vocal: String
    var genre: String
    var sound: [String]
    var avoid: [String]
    var want: String

    static let open = RadioLaneBrief(
        moods: [],
        themes: [],
        energy: 0...1,
        valence: 0...1,
        vocal: "",
        genre: "",
        sound: [],
        avoid: [],
        want: ""
    )

    func score(song: Song, signature: LyricSignature?) -> Double {
        var value = 0.0
        if let signature {
            let moodHits = Set(signature.moodKeys)
                .intersection(Set(moods.map(LyricLexicalEmbedding.normalized)))
            value += min(0.28, Double(moodHits.count) * 0.10)
            let themeHits = Set(signature.themeKeys)
                .intersection(Set(themes.map(LyricLexicalEmbedding.normalized)))
            value += min(0.16, Double(themeHits.count) * 0.06)
            if energy.contains(signature.energy) { value += 0.16 }
            else {
                let nearest = min(
                    abs(signature.energy - energy.lowerBound),
                    abs(signature.energy - energy.upperBound)
                )
                value -= min(0.14, nearest)
            }
            if valence.contains(signature.valence) { value += 0.12 }
            if !vocal.isEmpty {
                let wanted = LyricLexicalEmbedding.normalized(vocal)
                let have = LyricLexicalEmbedding.normalized(signature.details.vocalGender)
                if have == wanted { value += 0.12 }
                else if have == "mixed" { value += 0.03 }
                else if !have.isEmpty { value -= 0.06 }
            }
            if SoundLabelSpace.matches(signature.soundLabels, hints: sound) {
                value += 0.14
            }
            let blob = LyricLexicalEmbedding.normalized(
                signature.summary + " " + signature.details.tagBlob
            )
            if !want.isEmpty {
                let tokens = want.split { !$0.isLetter && !$0.isNumber }
                    .map { LyricLexicalEmbedding.normalized(String($0)) }
                    .filter { $0.count > 2 }
                let hits = tokens.reduce(into: 0) { count, token in
                    if blob.contains(token) { count += 1 }
                }
                value += min(0.12, Double(hits) * 0.03)
            }
            let avoidHits = avoid.filter {
                blob.contains(LyricLexicalEmbedding.normalized($0))
                    || signature.moodKeys.contains(LyricLexicalEmbedding.normalized($0))
            }
            value -= min(0.24, Double(avoidHits.count) * 0.08)
        }
        if !genre.isEmpty {
            let wanted = LyricLexicalEmbedding.normalized(genre)
            let have = [
                song.genre,
                song.genres?.map(\.name).joined(separator: " "),
                signature?.details.genre
            ]
            .compactMap { $0 }
            .map(LyricLexicalEmbedding.normalized)
            if have.contains(where: { $0.contains(wanted) || wanted.contains($0) }) {
                value += 0.10
            }
            if wanted.contains("kpop") || wanted.contains("케이팝"),
               RadioContinuity.isKPop(song: song, signature: signature) {
                value += 0.10
            }
        }
        return max(0, min(1, value))
    }
}

/// Local lane first, then one Groq pass that only reorders a small pack.
enum RadioLLMDirector {
    static let requestedCount = 12
    static let algorithmCount = 4
    static let reviewKeep = 12
    static let packSize = requestedCount + algorithmCount
    static let mixerLimit = 32

    static func continueRadio(
        seed: Song,
        excludedIDs: Set<String>,
        snapshot: HomeSnapshot,
        behavior: RecommendationBehaviorSnapshot,
        lyricIndex: LyricSignatureIndex,
        weights: RecommendationWeights,
        lyricsProvider _: (@Sendable (Song) async -> String)? = nil
    ) async -> [Song] {
        let settings = await LyricIntelligenceSettings.load()
        let profile = AIRecommendationProfile.load()
        let algorithm = await RecommendationMixer.scoreConcurrently(
            snapshot: snapshot,
            weights: profile.applied(to: weights),
            purpose: .autoplay,
            behavior: behavior,
            seed: seed,
            lyricIndex: lyricIndex,
            limit: mixerLimit
        )
        let brief = heuristicBrief(seed: seed, lyricIndex: lyricIndex)
        let filtered = algorithm.filter {
            $0.id != seed.id
                && !excludedIDs.contains($0.id)
                && $0.externalStreamURL == nil
        }
        let pack = fillPack(
            brief: brief,
            algorithm: filtered,
            lyricIndex: lyricIndex,
            profile: profile,
            seed: seed
        )
        let local = RadioContinuity.balance(
            pack,
            seed: seed,
            lyricIndex: lyricIndex,
            limit: reviewKeep
        )
        guard pack.count >= 6 else {
            return Array(filtered.prefix(reviewKeep))
        }
        if let kept = await review(
            pack: pack,
            brief: brief,
            seed: seed,
            recent: behavior.recentSongs,
            lyricIndex: lyricIndex,
            settings: settings,
            profile: profile
        ), !kept.isEmpty {
            return RadioContinuity.balance(
                kept,
                seed: seed,
                lyricIndex: lyricIndex,
                limit: reviewKeep
            )
        }
        return local
    }

    static func parseBrief(_ raw: String?) -> RadioLaneBrief? {
        guard let raw else { return nil }
        let json = LyricJSONExtractor.object(from: raw) ?? raw
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        let moods = stringList(dictionary["moods"])
        let themes = stringList(dictionary["themes"])
        let want = (dictionary["want"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if moods.isEmpty, themes.isEmpty, want.isEmpty,
           dictionary["energy"] == nil,
           dictionary["sound"] == nil {
            return nil
        }
        return RadioLaneBrief(
            moods: moods,
            themes: themes,
            energy: parseRange(dictionary["energy"], fallback: 0...1),
            valence: parseRange(dictionary["valence"], fallback: 0...1),
            vocal: token(dictionary["vocal"]),
            genre: token(dictionary["genre"]),
            sound: stringList(dictionary["sound"]),
            avoid: stringList(dictionary["avoid"]),
            want: want
        )
    }

    static func fillPack(
        brief: RadioLaneBrief,
        algorithm: [Song],
        lyricIndex: LyricSignatureIndex,
        profile: AIRecommendationProfile = .unset,
        seed: Song? = nil
    ) -> [Song] {
        let scored = algorithm.map { song in
            let signature = lyricIndex.bySongID[song.id]
            var value = brief.score(song: song, signature: signature)
                + profile.score(song: song, signature: signature)
            if let seed {
                value += RadioContinuity.laneScore(
                    candidate: song,
                    seed: seed,
                    lyricIndex: lyricIndex
                )
            }
            return (song, value)
        }.sorted {
            if $0.1 == $1.1 { return $0.0.id < $1.0.id }
            return $0.1 > $1.1
        }
        var requested: [Song] = []
        var recentArtists: [String] = []
        var preferredCount = 0
        for (song, score) in scored {
            let artist = LyricLexicalEmbedding.normalized(song.artist)
            if recentArtists.suffix(2).allSatisfy({ !$0.isEmpty && $0 == artist }),
               score < 0.72 {
                continue
            }
            let isPreferred = profile.preferredArtists.contains { name in
                artist.contains(LyricLexicalEmbedding.normalized(name))
                    || LyricLexicalEmbedding.normalized(name).contains(artist)
            }
            if isPreferred, preferredCount >= 5 {
                continue
            }
            requested.append(song)
            if isPreferred { preferredCount += 1 }
            if !artist.isEmpty { recentArtists.append(artist) }
            if requested.count == requestedCount { break }
        }
        var seen = Set(requested.map(\.id))
        var extras: [Song] = []
        for song in algorithm where seen.insert(song.id).inserted {
            extras.append(song)
            if extras.count == algorithmCount { break }
        }
        let pack = requested + extras
        guard let seed else { return pack }
        return RadioContinuity.balance(
            pack,
            seed: seed,
            lyricIndex: lyricIndex,
            limit: packSize
        )
    }

    static func heuristicBrief(
        seed: Song,
        lyricIndex: LyricSignatureIndex
    ) -> RadioLaneBrief {
        guard let signature = lyricIndex.bySongID[seed.id] else {
            if RadioContinuity.isKPop(song: seed, signature: nil) {
                return RadioLaneBrief(
                    moods: [],
                    themes: [],
                    energy: 0...1,
                    valence: 0...1,
                    vocal: "",
                    genre: "k-pop",
                    sound: [],
                    avoid: [],
                    want: "stay in the k-pop lane"
                )
            }
            return .open
        }
        let energyPad = 0.14
        let gender = RadioContinuity.vocalGender(song: seed, signature: signature)
        let vocal = (gender == "female" || gender == "male") ? gender : ""
        var genre = signature.details.genre
        if RadioContinuity.isKPop(song: seed, signature: signature) {
            let key = LyricLexicalEmbedding.normalized(genre)
            if key.isEmpty || !(key.contains("kpop") || key.contains("케이팝")) {
                genre = "k-pop"
            }
        }
        return RadioLaneBrief(
            moods: Array((signature.details.primaryMoods.isEmpty
                ? signature.moods
                : signature.details.primaryMoods).prefix(3)),
            themes: Array(signature.themes.prefix(3)),
            energy: max(0, signature.energy - energyPad)...min(1, signature.energy + energyPad),
            valence: max(0, signature.valence - energyPad)...min(1, signature.valence + energyPad),
            vocal: vocal,
            genre: genre,
            sound: SoundLabelSpace.canonicalize(signature.soundLabels),
            avoid: [],
            want: signature.summary
        )
    }

    private static func review(
        pack: [Song],
        brief: RadioLaneBrief,
        seed: Song,
        recent: [Song],
        lyricIndex: LyricSignatureIndex,
        settings: LyricIntelligenceSettings,
        profile: AIRecommendationProfile
    ) async -> [Song]? {
        let allowed = Set(pack.map(\.id))
        let candidates = pack.enumerated().map { index, song in
            "\(index + 1). \(card(song, lyricIndex: lyricIndex))"
        }.joined(separator: "\n")
        var extras: [String] = []
        let taste = profile.promptAppendix()
        if !taste.isEmpty { extras.append(taste) }
        if !settings.userPrompt.isEmpty {
            extras.append("Listener note:\n\(settings.userPrompt)")
        }
        let seedKPop = RadioContinuity.isKPop(
            song: seed,
            signature: lyricIndex.bySongID[seed.id]
        )
        let seedGender = RadioContinuity.vocalGender(
            song: seed,
            signature: lyricIndex.bySongID[seed.id]
        )
        if seedKPop {
            extras.append(
                "Seed is K-pop/idol. Keep a K-pop majority. Do not jump to Western pop."
            )
        }
        if seedGender == "female" || seedGender == "male" {
            extras.append(
                "Lean \(seedGender) vocals, but include at least one other gender. Never return only one gender."
            )
        }
        let user = extras.isEmpty ? "" : "\n\(extras.joined(separator: "\n"))\n"
        let prompt = """
        Reorder this radio pack. JSON only, no explanation:
        {"ids":[]}
        Keep exactly \(reviewKeep) listed ids in listen-next order. Stay in this lane: moods:\(brief.moods.joined(separator: ",")) energy:\(fmt(brief.energy.lowerBound))-\(fmt(brief.energy.upperBound)) vocal:\(brief.vocal) genre:\(brief.genre)
        Prefer lyric/energy continuity over title match. Preferred artists are a slight lean, never a block. Avoid three songs by one artist in a row.
        Seed: \(card(seed, lyricIndex: lyricIndex))
        Recent: \(recent.prefix(3).map { card($0, lyricIndex: lyricIndex) }.joined(separator: " | "))
        Candidates:
        \(candidates)
        \(user)
        """
        let raw = await LyricInferenceRuntime.completeRadio(
            prompt: prompt,
            settings: settings,
            maxTokens: 280
        )
        var ids = raw.flatMap { RecommendationLLMReview.parseIDs($0, allowed: allowed) }
        if ids == nil, let broken = raw,
           let repaired = await LyricInferenceRuntime.repairedJSON(
            from: broken,
            settings: settings
           ) {
            ids = RecommendationLLMReview.parseIDs(repaired, allowed: allowed)
        }
        guard let ids, !ids.isEmpty else { return nil }
        var byID = Dictionary(
            pack.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var kept: [Song] = []
        for id in ids {
            guard let song = byID.removeValue(forKey: id) else { continue }
            kept.append(song)
            if kept.count == reviewKeep { return kept }
        }
        for song in pack where byID.removeValue(forKey: song.id) != nil {
            kept.append(song)
            if kept.count == reviewKeep { break }
        }
        return kept
    }

    private static func card(_ song: Song, lyricIndex: LyricSignatureIndex) -> String {
        let signature = lyricIndex.bySongID[song.id]
        let moods = (signature?.details.primaryMoods.isEmpty == false
            ? signature?.details.primaryMoods
            : signature?.moods)?.prefix(2).joined(separator: ",") ?? ""
        let sound = SoundLabelSpace.canonicalize(signature?.soundLabels ?? [])
            .prefix(2)
            .joined(separator: ",")
        let summary = String(
            (signature?.summary.replacingOccurrences(of: "\n", with: " / ") ?? "")
                .prefix(80)
        )
        let energy = signature.map { fmt($0.energy) } ?? "-"
        let vocal = RadioContinuity.vocalGender(song: song, signature: signature)
        var genre = signature?.details.genre ?? song.genre ?? ""
        if RadioContinuity.isKPop(song: song, signature: signature) {
            genre = genre.isEmpty ? "k-pop" : genre
        }
        return "\(song.id)|\(song.title)-\(song.artist)|m:\(moods) e:\(energy) vox:\(vocal) g:\(genre) s:\(sound)|\(summary)"
    }

    private static func fmt(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func token(_ value: Any?) -> String {
        (value as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func stringList(_ value: Any?) -> [String] {
        if let values = value as? [String] { return values }
        if let values = value as? [Any] {
            return values.compactMap { $0 as? String }
        }
        if let value = value as? String { return [value] }
        return []
    }

    private static func parseRange(
        _ value: Any?,
        fallback: ClosedRange<Double>
    ) -> ClosedRange<Double> {
        if let values = value as? [Any], values.count >= 2 {
            let low = number(values[0]) ?? fallback.lowerBound
            let high = number(values[1]) ?? fallback.upperBound
            return min(low, high)...max(low, high)
        }
        if let object = value as? [String: Any] {
            let low = number(object["min"] ?? object["low"]) ?? fallback.lowerBound
            let high = number(object["max"] ?? object["high"]) ?? fallback.upperBound
            return min(low, high)...max(low, high)
        }
        if let single = number(value) {
            let pad = 0.12
            return max(0, single - pad)...min(1, single + pad)
        }
        return fallback
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) }
        return nil
    }
}
