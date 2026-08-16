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
                else if !have.isEmpty { value -= 0.08 }
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
                song.genres?.map(\.name).joined(separator: " ")
            ]
            .compactMap { $0 }
            .map(LyricLexicalEmbedding.normalized)
            if have.contains(where: { $0.contains(wanted) || wanted.contains($0) }) {
                value += 0.10
            }
        }
        return max(0, min(1, value))
    }
}

/// Two-step radio: the model writes a lane brief while the mixer pre-ranks
/// the library, then reviews a 15+5 pack and keeps 16 listen-next tracks.
enum RadioLLMDirector {
    static let requestedCount = 15
    static let algorithmCount = 5
    static let reviewKeep = 16
    static let packSize = requestedCount + algorithmCount

    static func continueRadio(
        seed: Song,
        excludedIDs: Set<String>,
        snapshot: HomeSnapshot,
        behavior: RecommendationBehaviorSnapshot,
        lyricIndex: LyricSignatureIndex,
        weights: RecommendationWeights
    ) async -> [Song] {
        let settings = await LyricIntelligenceSettings.load()
        async let baseline = RecommendationMixer.scoreConcurrently(
            snapshot: snapshot,
            weights: weights,
            purpose: .autoplay,
            behavior: behavior,
            seed: seed,
            lyricIndex: lyricIndex,
            limit: 48
        )
        async let briefText = requestBrief(
            seed: seed,
            recent: behavior.recentSongs,
            lyricIndex: lyricIndex,
            settings: settings
        )
        let algorithm = await baseline
        let brief = parseBrief(await briefText)
            ?? heuristicBrief(seed: seed, lyricIndex: lyricIndex)
        let pack = fillPack(
            brief: brief,
            algorithm: algorithm.filter {
                $0.id != seed.id
                    && !excludedIDs.contains($0.id)
                    && $0.externalStreamURL == nil
            },
            lyricIndex: lyricIndex
        )
        guard pack.count >= 8 else { return Array(algorithm.prefix(reviewKeep)) }
        if let kept = await review(
            pack: pack,
            brief: brief,
            seed: seed,
            recent: behavior.recentSongs,
            lyricIndex: lyricIndex,
            settings: settings
        ), !kept.isEmpty {
            return Array(kept.prefix(reviewKeep))
        }
        return Array(pack.prefix(reviewKeep))
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
        lyricIndex: LyricSignatureIndex
    ) -> [Song] {
        let scored = algorithm.map { song in
            (
                song,
                brief.score(
                    song: song,
                    signature: lyricIndex.bySongID[song.id]
                )
            )
        }.sorted {
            if $0.1 == $1.1 { return $0.0.id < $1.0.id }
            return $0.1 > $1.1
        }
        var requested: [Song] = []
        var recentArtists: [String] = []
        for (song, score) in scored {
            let artist = LyricLexicalEmbedding.normalized(song.artist)
            if recentArtists.suffix(2).allSatisfy({ !$0.isEmpty && $0 == artist }),
               score < 0.72 {
                continue
            }
            requested.append(song)
            if !artist.isEmpty { recentArtists.append(artist) }
            if requested.count == requestedCount { break }
        }
        var seen = Set(requested.map(\.id))
        var extras: [Song] = []
        for song in algorithm where seen.insert(song.id).inserted {
            extras.append(song)
            if extras.count == algorithmCount { break }
        }
        return requested + extras
    }

    static func heuristicBrief(
        seed: Song,
        lyricIndex: LyricSignatureIndex
    ) -> RadioLaneBrief {
        guard let signature = lyricIndex.bySongID[seed.id] else { return .open }
        let energyPad = 0.14
        return RadioLaneBrief(
            moods: Array((signature.details.primaryMoods.isEmpty
                ? signature.moods
                : signature.details.primaryMoods).prefix(3)),
            themes: Array(signature.themes.prefix(3)),
            energy: max(0, signature.energy - energyPad)...min(1, signature.energy + energyPad),
            valence: max(0, signature.valence - energyPad)...min(1, signature.valence + energyPad),
            vocal: signature.details.vocalGender,
            genre: signature.details.genre,
            sound: SoundLabelSpace.canonicalize(signature.soundLabels),
            avoid: [],
            want: signature.summary
        )
    }

    private static func requestBrief(
        seed: Song,
        recent: [Song],
        lyricIndex: LyricSignatureIndex,
        settings: LyricIntelligenceSettings
    ) async -> String? {
        let playing = card(seed, lyricIndex: lyricIndex)
        let history = recent.prefix(6).map { card($0, lyricIndex: lyricIndex) }
            .joined(separator: "\n")
        let user = settings.userPrompt.isEmpty
            ? ""
            : "\nListener note:\n\(settings.userPrompt)\n"
        let prompt = """
        Continue a personal radio. Inspect the now-playing lane and recent listens, then describe the NEXT songs you want. JSON only:
        {"moods":[],"themes":[],"energy":[0.0,1.0],"valence":[0.0,1.0],"vocal":"","genre":"","sound":[],"avoid":[],"want":""}
        moods/themes/sound stay inside the current lane. energy/valence are inclusive ranges. vocal is female, male, or empty. avoid is what would break the room. want is one sentence about how the next block should feel.
        Do not invent ids. Do not jump genre unless the recent list already did.
        Now playing:
        \(playing)
        Recent:
        \(history.isEmpty ? "(none)" : history)
        \(user)
        """
        return await LyricInferenceRuntime.completeRadio(
            prompt: prompt,
            settings: settings,
            maxTokens: 420
        )
    }

    private static func review(
        pack: [Song],
        brief: RadioLaneBrief,
        seed: Song,
        recent: [Song],
        lyricIndex: LyricSignatureIndex,
        settings: LyricIntelligenceSettings
    ) async -> [Song]? {
        let allowed = Set(pack.map(\.id))
        let candidates = pack.enumerated().map { index, song in
            "\(index + 1). \(card(song, lyricIndex: lyricIndex))"
        }.joined(separator: "\n")
        let user = settings.userPrompt.isEmpty
            ? ""
            : "\nListener note:\n\(settings.userPrompt)\n"
        let prompt = """
        You asked for this radio lane:
        moods:\(brief.moods.joined(separator: ",")) themes:\(brief.themes.joined(separator: ",")) energy:\(brief.energy.lowerBound)-\(brief.energy.upperBound) valence:\(brief.valence.lowerBound)-\(brief.valence.upperBound) vocal:\(brief.vocal) genre:\(brief.genre) sound:\(brief.sound.joined(separator: ",")) want:\(brief.want)
        Here are \(pack.count) library tracks. The first \(min(requestedCount, pack.count)) match your brief; the rest are algorithm contrast.
        Keep exactly \(reviewKeep) listed ids in listen-next order. JSON only:
        {"ids":[]}
        Stay in the lane. Prefer a coherent arc over shuffle. Avoid three songs by one artist in a row.
        Seed:
        \(card(seed, lyricIndex: lyricIndex))
        Recent:
        \(recent.prefix(4).map { card($0, lyricIndex: lyricIndex) }.joined(separator: "\n"))
        Candidates:
        \(candidates)
        \(user)
        """
        let raw = await LyricInferenceRuntime.completeRadio(
            prompt: prompt,
            settings: settings,
            maxTokens: 500
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
            : signature?.moods)?.prefix(3).joined(separator: ",") ?? ""
        let sound = SoundLabelSpace.canonicalize(signature?.soundLabels ?? [])
            .prefix(3)
            .joined(separator: ",")
        let summary = signature?.summary.replacingOccurrences(of: "\n", with: " / ") ?? ""
        let energy = signature.map { String(format: "%.2f", $0.energy) } ?? "-"
        let valence = signature.map { String(format: "%.2f", $0.valence) } ?? "-"
        let vocal = signature?.details.vocalGender ?? ""
        let genre = signature?.details.genre ?? song.genre ?? ""
        return "\(song.id) | \(song.title) — \(song.artist) | moods:\(moods) e:\(energy) v:\(valence) vocal:\(vocal) genre:\(genre) sound:\(sound) | \(summary)"
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
