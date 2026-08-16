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
            if signature.details.audioEnergy > 0 {
                if energy.contains(signature.details.audioEnergy) { value += 0.06 }
            }
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

    func score(
        song: Song,
        signature: LyricSignature?,
        seedBPM: Int
    ) -> Double {
        var value = score(song: song, signature: signature)
        let bpm = SoundFeatureExtractor.bpm(song: song, signature: signature)
        value += SoundFeatureExtractor.closeness(left: seedBPM, right: bpm) * 0.14
        return max(0, min(1, value))
    }
}

/// Local lane first, then one Groq pass that only reorders a small pack.
enum RadioIDStream {
    static func newIDs(
        in text: String,
        allowed: Set<String>,
        already: Set<String>
    ) -> [String] {
        var result: [String] = []
        var seen = already
        var current = ""
        var inString = false
        var escaped = false
        for character in text {
            if inString {
                if escaped {
                    current.append(character)
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                    if allowed.contains(current), seen.insert(current).inserted {
                        result.append(current)
                    }
                    current = ""
                } else if current.count < 80 {
                    current.append(character)
                }
            } else if character == "\"" {
                inString = true
                current = ""
            }
        }
        return result
    }
}

struct RadioNeed: Sendable {
    var count: Int
    var feel: String
    var moods: [String]
    var genre: String
    var vocal: String
    var energy: ClosedRange<Double>?
    var want: String

    func score(song: Song, lyricIndex: LyricSignatureIndex) -> Double {
        let signature = lyricIndex.bySongID[song.id]
        var value = 0.0
        if !feel.isEmpty {
            let have = RadioFeelGrammar.feel(song: song, signature: signature).rawValue
            value += have == feel ? 0.36 : 0
        }
        if let energy, let signature {
            value += energy.contains(signature.energy) ? 0.18 : 0
        }
        if !genre.isEmpty {
            let wanted = LyricLexicalEmbedding.normalized(genre)
            let blob = LyricLexicalEmbedding.normalized(
                [song.genre, signature?.details.genre]
                    .compactMap { $0 }
                    .joined(separator: " ")
            )
            if blob.contains(wanted) || wanted.contains("kpop")
                && RadioContinuity.isKPop(song: song, signature: signature) {
                value += 0.22
            }
        }
        if !vocal.isEmpty {
            let have = RadioContinuity.vocalGender(song: song, signature: signature)
            value += have == vocal ? 0.12 : 0
        }
        if !moods.isEmpty, let signature {
            let have = Set(signature.moodKeys)
            let hits = moods.filter {
                have.contains(LyricLexicalEmbedding.normalized($0))
            }.count
            value += min(0.18, Double(hits) * 0.08)
        }
        if !want.isEmpty, let signature {
            let blob = LyricLexicalEmbedding.normalized(
                signature.summary + " " + signature.details.tagBlob
            )
            let tokens = want.split { !$0.isLetter && !$0.isNumber }
                .map { LyricLexicalEmbedding.normalized(String($0)) }
                .filter { $0.count > 2 }
            let hits = tokens.filter { blob.contains($0) }.count
            value += min(0.12, Double(hits) * 0.03)
        }
        return value
    }
}

struct RadioCandidatePack: Sendable {
    var room: [Song]
    var nearby: [Song]
    var turns: [Song]

    var all: [Song] {
        TrackWorkIdentity.uniqueRecordings(room + nearby + turns)
    }
}

enum RadioLLMDirector {
    static let requestedCount = 50
    static let enginePool = 50
    static let coreMLKeep = 30
    static let reviewKeep = 8
    static let packSize = 30
    static let mixerLimit = 50
    static let streamWaitDeadline: TimeInterval = 1.5
    static let firstPickDeadline: TimeInterval = 3.0

    static func continueRadio(
        seed: Song,
        excludedIDs: Set<String>,
        snapshot: HomeSnapshot,
        behavior: RecommendationBehaviorSnapshot,
        lyricIndex: LyricSignatureIndex,
        weights: RecommendationWeights,
        settings loadedSettings: LyricIntelligenceSettings? = nil,
        onPick: (@Sendable (Song) async -> Void)? = nil
    ) async -> [Song] {
        let settings = if let loadedSettings {
            loadedSettings
        } else {
            await LyricIntelligenceSettings.load()
        }
        let profile = AIRecommendationProfile.load()
        let algorithm = await RecommendationMixer.scoreConcurrently(
            snapshot: snapshot,
            weights: profile.applied(to: weights),
            purpose: .autoplay,
            behavior: behavior,
            seed: seed,
            lyricIndex: lyricIndex,
            limit: enginePool
        )
        let brief = heuristicBrief(seed: seed, lyricIndex: lyricIndex)
        let filtered = algorithm.filter {
            $0.id != seed.id
                && !excludedIDs.contains($0.id)
                && $0.externalStreamURL == nil
        }
        let session = Array(behavior.recentSongs.prefix(5))
        let ranked = RadioCoreMLTransition.shortlist(
            seed: seed,
            candidates: filtered,
            lyricIndex: lyricIndex,
            keep: coreMLKeep,
            session: session
        )
        let leftover = filtered.filter { song in
            !ranked.contains(where: { $0.id == song.id })
        }
        let pack = fillPack(
            brief: brief,
            algorithm: ranked,
            lyricIndex: lyricIndex,
            profile: profile,
            seed: seed
        )
        let catalog = pack.all
        let local = sequenceLocally(
            RadioContinuity.balance(
                catalog,
                seed: seed,
                lyricIndex: lyricIndex,
                limit: reviewKeep
            ),
            seed: seed,
            lyricIndex: lyricIndex,
            limit: reviewKeep
        )
        guard catalog.count >= 6 else {
            await emit(Array(filtered.prefix(reviewKeep)), using: onPick)
            return Array(filtered.prefix(reviewKeep))
        }
        let picked = await reviewStreaming(
            pack: pack,
            local: local,
            leftover: leftover,
            brief: brief,
            seed: seed,
            recent: behavior.recentSongs,
            lyricIndex: lyricIndex,
            settings: settings,
            profile: profile,
            onPick: onPick
        )
        if !picked.isEmpty { return Array(picked.prefix(reviewKeep)) }
        await emit(local, using: onPick)
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
    ) -> RadioCandidatePack {
        let seedBPM = seed.map {
            SoundFeatureExtractor.bpm(
                song: $0,
                signature: lyricIndex.bySongID[$0.id]
            )
        } ?? 0
        let seedEnergy = seed.flatMap { lyricIndex.bySongID[$0.id]?.energy } ?? 0.5
        let seedArtist = seed.map { LyricLexicalEmbedding.normalized($0.artist) } ?? ""
        let uniqueAlgorithm = TrackWorkIdentity.uniqueRecordings(algorithm)
        let scored = uniqueAlgorithm.map { song in
            let signature = lyricIndex.bySongID[song.id]
            var value = brief.score(
                song: song,
                signature: signature,
                seedBPM: seedBPM
            ) + profile.score(song: song, signature: signature)
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
        var room: [Song] = []
        var nearby: [Song] = []
        var turns: [Song] = []
        var seen = Set<String>()
        var roomArtists: [String] = []
        let roomTarget = 14
        let nearbyTarget = 10
        let turnTarget = 6

        func take(_ song: Song, into bucket: inout [Song], artists: inout [String]) -> Bool {
            guard seen.insert(song.id).inserted else { return false }
            bucket.append(song)
            let artist = LyricLexicalEmbedding.normalized(song.artist)
            if !artist.isEmpty { artists.append(artist) }
            return true
        }

        for (song, score) in scored {
            guard room.count < roomTarget else { break }
            let artist = LyricLexicalEmbedding.normalized(song.artist)
            if roomArtists.suffix(2).allSatisfy({ !$0.isEmpty && $0 == artist }),
               score < 0.78 {
                continue
            }
            _ = take(song, into: &room, artists: &roomArtists)
        }
        var nearbyArtists: [String] = []
        for (song, score) in scored {
            guard nearby.count < nearbyTarget else { break }
            guard !seen.contains(song.id), score >= 0.08 else { continue }
            let artist = LyricLexicalEmbedding.normalized(song.artist)
            let energy = lyricIndex.bySongID[song.id]?.energy ?? 0.5
            let sameArtist = !seedArtist.isEmpty && artist == seedArtist
            let textureShift = abs(energy - seedEnergy) >= 0.12
            let feelFit: Double
            if let seed {
                feelFit = RadioFeelGrammar.placement(
                    from: seed,
                    to: song,
                    lyricIndex: lyricIndex
                )
            } else {
                feelFit = 0.5
            }
            if sameArtist || textureShift || feelFit >= 0.55
                || nearbyArtists.last != artist {
                _ = take(song, into: &nearby, artists: &nearbyArtists)
            }
        }
        var turnArtists: [String] = []
        for (song, _) in scored {
            guard turns.count < turnTarget else { break }
            guard !seen.contains(song.id) else { continue }
            let artist = LyricLexicalEmbedding.normalized(song.artist)
            let signature = lyricIndex.bySongID[song.id]
            let energy = signature?.energy ?? 0.5
            let isDeepCut = song.isStarred || (song.playCount ?? 0) >= 4
            let complementary = abs(energy - seedEnergy) >= 0.22
            let sameArtistOtherWork = !seedArtist.isEmpty && artist == seedArtist
            if isDeepCut || complementary || sameArtistOtherWork {
                _ = take(song, into: &turns, artists: &turnArtists)
            }
        }
        if room.count + nearby.count + turns.count < 8 {
            for (song, _) in scored where room.count < packSize {
                _ = take(song, into: &room, artists: &roomArtists)
            }
        }
        return RadioCandidatePack(room: room, nearby: nearby, turns: turns)
    }

    static func sequenceLocally(
        _ songs: [Song],
        seed: Song,
        lyricIndex: LyricSignatureIndex,
        limit: Int
    ) -> [Song] {
        guard !songs.isEmpty else { return [] }
        var rest = songs
        var picked: [Song] = []
        var last = seed
        while picked.count < limit, !rest.isEmpty {
            var bestIndex = 0
            var best = -1.0
            let neighbors = [seed] + picked
            for (index, song) in rest.enumerated() {
                var score = RadioFeelGrammar.placement(
                    from: last,
                    to: song,
                    lyricIndex: lyricIndex
                )
                score += SoundFeatureExtractor.transitionScore(
                    from: last,
                    to: song,
                    lyricIndex: lyricIndex
                ) * 0.35
                let learned = RadioCoreMLTransition.score(
                    seed: last,
                    candidate: song,
                    lyricIndex: lyricIndex
                )
                score = learned * 0.45 + score * 0.55
                if TrackWorkIdentity.isNearVariant(song, of: neighbors) {
                    score -= 0.55
                }
                if score > best {
                    best = score
                    bestIndex = index
                }
            }
            let next = rest.remove(at: bestIndex)
            picked.append(next)
            last = next
        }
        return picked
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
        let energyPad = 0.28
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

    private static func reviewStreaming(
        pack: RadioCandidatePack,
        local: [Song],
        leftover: [Song],
        brief: RadioLaneBrief,
        seed: Song,
        recent: [Song],
        lyricIndex: LyricSignatureIndex,
        settings: LyricIntelligenceSettings,
        profile: AIRecommendationProfile,
        onPick: (@Sendable (Song) async -> Void)?
    ) async -> [Song] {
        let catalog = pack.all
        let allowed = Set(catalog.map(\.id))
        let byID = Dictionary(
            catalog.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let box = RadioPickBox(onPick: onPick)
        let prompt = reviewPrompt(
            pack: pack,
            brief: brief,
            seed: seed,
            recent: recent,
            lyricIndex: lyricIndex,
            settings: settings,
            profile: profile
        )
        async let streamed: String? = LyricInferenceRuntime.streamRadio(
            prompt: prompt,
            settings: settings,
            maxTokens: 420
        ) { partial in
            let ids = RadioIDStream.newIDs(
                in: partial,
                allowed: allowed,
                already: await box.ids
            )
            for id in ids {
                guard let song = byID[id] else { continue }
                guard await box.accepts(song) else { continue }
                await box.push(song)
                if await box.count == reviewKeep { break }
            }
        }
        _ = await AsyncDeadline.first(seconds: firstPickDeadline) {
            await box.waitUntilNonEmpty()
            return true
        }
        if await box.isEmpty, let fallback = local.first {
            await box.push(fallback)
        }
        let raw = await streamed
        if await box.count < reviewKeep,
           let need = parseNeed(raw),
           need.count > 0 {
            let replacements = refill(
                need: need,
                leftover: leftover + pack.all,
                excluding: await box.ids,
                seed: seed,
                lyricIndex: lyricIndex
            )
            for song in replacements {
                guard await box.accepts(song) else { continue }
                await box.push(song)
                if await box.count == reviewKeep { break }
            }
        }
        if await box.count < reviewKeep {
            for song in local {
                guard await box.accepts(song) else { continue }
                await box.push(song)
                if await box.count == reviewKeep { break }
            }
        }
        return await box.songs
    }

    private static func parseNeed(_ raw: String?) -> RadioNeed? {
        guard let raw,
              let json = LyricJSONExtractor.object(from: raw),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let need = dictionary["need"] as? [String: Any] else {
            return nil
        }
        let count = Int(number(need["count"]) ?? 0)
        guard count > 0 else { return nil }
        return RadioNeed(
            count: min(count, reviewKeep),
            feel: token(need["feel"]),
            moods: stringList(need["moods"]),
            genre: token(need["genre"]),
            vocal: token(need["vocal"]),
            energy: need["energy"] == nil
                ? nil
                : parseRange(need["energy"], fallback: 0...1),
            want: token(need["want"])
        )
    }

    private static func refill(
        need: RadioNeed,
        leftover: [Song],
        excluding: Set<String>,
        seed: Song,
        lyricIndex: LyricSignatureIndex
    ) -> [Song] {
        let pool = leftover.filter { !excluding.contains($0.id) }
        let ranked = pool.map { song -> (Song, Double) in
            (song, need.score(song: song, lyricIndex: lyricIndex))
        }.sorted {
            if $0.1 == $1.1 { return $0.0.id < $1.0.id }
            return $0.1 > $1.1
        }
        return Array(
            ranked
                .filter { $0.1 >= 0.28 }
                .prefix(need.count)
                .map(\.0)
        )
    }

    private static func reviewPrompt(
        pack: RadioCandidatePack,
        brief: RadioLaneBrief,
        seed: Song,
        recent: [Song],
        lyricIndex: LyricSignatureIndex,
        settings: LyricIntelligenceSettings,
        profile: AIRecommendationProfile
    ) -> String {
        func block(_ title: String, _ songs: [Song]) -> String {
            guard !songs.isEmpty else { return "" }
            let lines = songs.enumerated().map { index, song in
                "\(index + 1). \(card(song, lyricIndex: lyricIndex))"
            }.joined(separator: "\n")
            return "\(title)\n\(lines)"
        }
        let candidates = [
            block("In the room (same emotional weather — honor the seed, do not clone it):", pack.room),
            block("Nearby (same world, different texture, era, or artist):", pack.nearby),
            block("Left turns (surprising but obviously right if you know both records):", pack.turns)
        ].filter { !$0.isEmpty }.joined(separator: "\n\n")
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
                "The seed lives in K-pop. Walk to similar adjacent artists in the same room — same generation, neighboring sound, shared vocal color. Do not shuffle random idol groups or jump to Western pop because both are tagged pop."
            )
        }
        if seedGender == "female" || seedGender == "male" {
            extras.append(
                "Lean \(seedGender) vocals the way a DJ would, but include at least one other gender so the set breathes."
            )
        }
        let user = extras.isEmpty ? "" : "\n\(extras.joined(separator: "\n"))\n"
        return LyricModelPrompts.radioProgram(
            family: LyricModelFamily.resolve(model: settings.radioModel),
            keep: reviewKeep,
            session: sessionWeather(seed: seed, brief: brief),
            seed: RecommendationPromptCard.make(
                seed,
                lyricIndex: lyricIndex,
                excerptLimit: 240
            ),
            recent: recent.prefix(4).map {
                RecommendationPromptCard.make($0, lyricIndex: lyricIndex, excerptLimit: 140)
            }
                .joined(separator: "\n"),
            candidates: candidates,
            extras: user
        )
    }

    private static func sessionWeather(seed: Song, brief: RadioLaneBrief) -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        let weekday = Calendar.current.component(.weekday, from: Date())
        let daypart: String
        switch hour {
        case 5..<11: daypart = "morning"
        case 11..<17: daypart = "afternoon"
        case 17..<21: daypart = "evening"
        default: daypart = "late night"
        }
        let days = ["", "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let day = weekday >= 1 && weekday < days.count ? days[weekday] : ""
        let moods = brief.moods.joined(separator: ", ")
        let themes = brief.themes.joined(separator: ", ")
        return """
        Local time: \(day) \(daypart) (\(hour):00).
        They just chose "\(seed.title)" by \(seed.artist). Program the next \(reviewKeep) as one short radio block for the whole recent session, not a 15-song station from this single title.
        Seed lane: moods [\(moods)] themes [\(themes)] genre \(brief.genre) vocal \(brief.vocal).
        """
    }

    private static func emit(
        _ songs: [Song],
        using onPick: (@Sendable (Song) async -> Void)?
    ) async {
        guard let onPick else { return }
        for song in songs {
            await onPick(song)
        }
    }

    private static func card(_ song: Song, lyricIndex: LyricSignatureIndex) -> String {
        RecommendationPromptCard.make(song, lyricIndex: lyricIndex)
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

actor RadioPickBox {
    private var picked: [Song] = []
    private var seen: Set<String> = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let onPick: (@Sendable (Song) async -> Void)?

    init(onPick: (@Sendable (Song) async -> Void)?) {
        self.onPick = onPick
    }

    var ids: Set<String> { seen }
    var songs: [Song] { picked }
    var count: Int { picked.count }
    var isEmpty: Bool { picked.isEmpty }

    func accepts(_ song: Song) -> Bool {
        let recording = TrackWorkIdentity.recordingKey(for: song)
        if picked.contains(where: {
            TrackWorkIdentity.recordingKey(for: $0) == recording
        }) {
            return false
        }
        return !TrackWorkIdentity.isNearVariant(song, of: picked, window: 2)
    }

    func push(_ song: Song) async {
        guard seen.insert(song.id).inserted else { return }
        guard accepts(song) else { return }
        picked.append(song)
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await onPick?(song)
    }

    func waitUntilNonEmpty() async {
        if !picked.isEmpty { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if !picked.isEmpty {
                    continuation.resume()
                } else {
                    waiters.append(continuation)
                }
            }
        } onCancel: {
            Task { await self.releaseWaiters() }
        }
    }

    func releaseWaiters() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
