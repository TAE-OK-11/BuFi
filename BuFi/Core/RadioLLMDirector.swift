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

enum RadioLLMDirector {
    static let requestedCount = 30
    static let algorithmCount = 0
    static let reviewKeep = 15
    static let packSize = 30
    static let mixerLimit = 30
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
        lyricsProvider _: (@Sendable (Song) async -> String)? = nil,
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
        let local = sequenceLocally(
            RadioContinuity.balance(
                pack,
                seed: seed,
                lyricIndex: lyricIndex,
                limit: reviewKeep
            ),
            seed: seed,
            lyricIndex: lyricIndex,
            limit: reviewKeep
        )
        guard pack.count >= 6 else {
            await emit(Array(filtered.prefix(reviewKeep)), using: onPick)
            return Array(filtered.prefix(reviewKeep))
        }
        let picked = await reviewStreaming(
            pack: pack,
            local: local,
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
    ) -> [Song] {
        let seedBPM = seed.map {
            SoundFeatureExtractor.bpm(
                song: $0,
                signature: lyricIndex.bySongID[$0.id]
            )
        } ?? 0
        let scored = algorithm.map { song in
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
            if isPreferred, preferredCount >= 6 {
                continue
            }
            requested.append(song)
            if isPreferred { preferredCount += 1 }
            if !artist.isEmpty { recentArtists.append(artist) }
            if requested.count == packSize { break }
        }
        guard let seed else { return requested }
        return RadioContinuity.balance(
            requested,
            seed: seed,
            lyricIndex: lyricIndex,
            limit: packSize
        )
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
            for (index, song) in rest.enumerated() {
                let score = SoundFeatureExtractor.transitionScore(
                    from: last,
                    to: song,
                    lyricIndex: lyricIndex
                )
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

    private static func reviewStreaming(
        pack: [Song],
        local: [Song],
        brief: RadioLaneBrief,
        seed: Song,
        recent: [Song],
        lyricIndex: LyricSignatureIndex,
        settings: LyricIntelligenceSettings,
        profile: AIRecommendationProfile,
        onPick: (@Sendable (Song) async -> Void)?
    ) async -> [Song] {
        let allowed = Set(pack.map(\.id))
        let byID = Dictionary(
            pack.map { ($0.id, $0) },
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
            maxTokens: 360
        ) { partial in
            let ids = RadioIDStream.newIDs(
                in: partial,
                allowed: allowed,
                already: await box.ids
            )
            for id in ids {
                guard let song = byID[id] else { continue }
                await box.push(song)
                if await box.count == reviewKeep { break }
            }
        }
        let first = await AsyncDeadline.first(seconds: firstPickDeadline) {
            await box.waitUntilNonEmpty()
            return true
        }
        if first == nil, await box.isEmpty, let fallback = local.first {
            await box.push(fallback)
        }
        _ = await streamed
        if await box.count < reviewKeep {
            for song in local {
                await box.push(song)
                if await box.count == reviewKeep { break }
            }
        }
        return await box.songs
    }

    private static func reviewPrompt(
        pack: [Song],
        brief: RadioLaneBrief,
        seed: Song,
        recent: [Song],
        lyricIndex: LyricSignatureIndex,
        settings: LyricIntelligenceSettings,
        profile: AIRecommendationProfile
    ) -> String {
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
        let lane = "moods:\(brief.moods.joined(separator: ",")) energy:\(fmt(brief.energy.lowerBound))-\(fmt(brief.energy.upperBound)) vocal:\(brief.vocal) genre:\(brief.genre)"
        return LyricModelPrompts.radioProgram(
            family: LyricModelFamily.resolve(model: settings.radioModel),
            keep: reviewKeep,
            lane: lane,
            seed: card(seed, lyricIndex: lyricIndex),
            recent: recent.prefix(4).map { card($0, lyricIndex: lyricIndex) }
                .joined(separator: " | "),
            candidates: candidates,
            extras: user
        )
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
        let signature = lyricIndex.bySongID[song.id]
        let moods = (signature?.details.primaryMoods.isEmpty == false
            ? signature?.details.primaryMoods
            : signature?.moods)?.prefix(2).joined(separator: ",") ?? ""
        let sound = SoundLabelSpace.canonicalize(signature?.soundLabels ?? [])
            .prefix(2)
            .joined(separator: ",")
        let summary = String(
            (signature?.summary.replacingOccurrences(of: "\n", with: " / ") ?? "")
                .prefix(72)
        )
        let energy = signature.map { fmt($0.energy) } ?? "-"
        let vocal = RadioContinuity.vocalGender(song: song, signature: signature)
        var genre = signature?.details.genre ?? song.genre ?? ""
        if RadioContinuity.isKPop(song: song, signature: signature) {
            genre = genre.isEmpty ? "k-pop" : genre
        }
        let bpm = SoundFeatureExtractor.bpm(song: song, signature: signature)
        let audio = signature?.details.audioMeasured == true
            ? " ae:\(fmt(signature?.details.audioEnergy ?? 0)) br:\(fmt(signature?.details.audioBrightness ?? 0))"
            : ""
        let starred = song.isStarred ? " fav" : ""
        let plays = song.playCount.map { " plays:\($0)" } ?? ""
        return "\(song.id)|\(song.title)-\(song.artist)|bpm:\(bpm) m:\(moods) e:\(energy) vox:\(vocal) g:\(genre) s:\(sound)\(audio)\(starred)\(plays)|\(summary)"
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

    func push(_ song: Song) async {
        guard seen.insert(song.id).inserted else { return }
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
                waiters.append(continuation)
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
