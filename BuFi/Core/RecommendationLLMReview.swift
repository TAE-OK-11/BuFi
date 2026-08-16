import Foundation

enum RecommendationLLMReview {
    static let enabledKey = "recommendation-llm-review-enabled"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: enabledKey) == nil {
            defaults.set(true, forKey: enabledKey)
            return true
        }
        return defaults.bool(forKey: enabledKey)
    }

    static func refine(
        songs: [Song],
        seed: Song?,
        recent: [Song],
        favorites: [Song],
        lyricIndex: LyricSignatureIndex,
        purpose: RecommendationPurpose,
        limit: Int
    ) async -> [Song] {
        guard !songs.isEmpty, limit > 0 else { return songs }
        guard isEnabled() else { return Array(songs.prefix(limit)) }
        let loadedSettings = await currentSettings()
        let settings = RecommendationAIRouting.resolve(loadedSettings)
        let family = LyricModelFamily.resolve(model: settings.radioModel)
        let pool = Array(songs.prefix(family.reviewPoolLimit))
        guard pool.count >= 3 else { return songs }
        var laneScores: [String: Double] = [:]
        laneScores.reserveCapacity(pool.count)
        for song in pool {
            laneScores[song.id] = lyricIndex.affinity(
                candidateID: song.id,
                recentIDs: recent.map(\.id),
                favoriteIDs: favorites.map(\.id),
                seedID: seed?.id
            )
        }
        if let cached = cachedOrder(
            songs: pool,
            seed: seed,
            lyricIndex: lyricIndex,
            purpose: purpose
        ) {
            return apply(
                order: cached,
                to: songs,
                limit: limit,
                laneScores: laneScores
            )
        }
        let prompt = prompt(
            pool: pool,
            seed: seed,
            recent: recent,
            favorites: favorites,
            lyricIndex: lyricIndex,
            purpose: purpose,
            family: family
        )
        let raw = await LyricInferenceRuntime.completeRadio(
            prompt: prompt,
            settings: settings,
            maxTokens: 900,
            applePrompt: compactApplePrompt(
                pool: pool,
                seed: seed,
                recent: recent,
                purpose: purpose,
                lyricIndex: lyricIndex,
                limit: limit
            )
        )
        var order = raw.flatMap { parseIDs($0, allowed: Set(pool.map(\.id))) }
        if order == nil, let broken = raw,
           let repaired = await LyricInferenceRuntime.repairedJSON(
            from: broken,
            settings: settings
           ) {
            order = parseIDs(repaired, allowed: Set(pool.map(\.id)))
        }
        guard let order, !order.isEmpty else {
            return Array(songs.prefix(limit))
        }
        store(
            order: order,
            songs: pool,
            seed: seed,
            lyricIndex: lyricIndex,
            purpose: purpose
        )
        return apply(
            order: order,
            to: songs,
            limit: limit,
            laneScores: laneScores
        )
    }

    static func parseIDs(_ raw: String, allowed: Set<String>) -> [String]? {
        let json = LyricJSONExtractor.payload(from: raw)
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        let values: [String]
        if let dictionary = object as? [String: Any] {
            values = stringList(dictionary["ids"] ?? dictionary["order"])
        } else {
            values = stringList(object)
        }
        var seen = Set<String>()
        var order: [String] = []
        for value in values where allowed.contains(value) && seen.insert(value).inserted {
            order.append(value)
        }
        return order.isEmpty ? nil : order
    }

    static func merged(
        order: [String],
        songs: [Song],
        limit: Int,
        laneScores: [String: Double]
    ) -> [Song] {
        let reviewedIDs = Set(laneScores.keys).union(order)
        let reviewed = songs.filter { reviewedIDs.contains($0.id) }
        let blended = LyricOrderBlend.combine(
            llmOrder: order,
            songs: reviewed,
            laneScores: laneScores
        )
        var byID = Dictionary(
            songs.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var result: [Song] = []
        result.reserveCapacity(min(limit, songs.count))
        for id in blended {
            guard let song = byID.removeValue(forKey: id) else { continue }
            result.append(song)
            if result.count == limit { return result }
        }
        for song in songs {
            guard byID.removeValue(forKey: song.id) != nil else { continue }
            result.append(song)
            if result.count == limit { break }
        }
        return result
    }

    private static func apply(
        order: [String],
        to songs: [Song],
        limit: Int,
        laneScores: [String: Double]
    ) -> [Song] {
        merged(
            order: order,
            songs: songs,
            limit: limit,
            laneScores: laneScores
        )
    }

    private static func prompt(
        pool: [Song],
        seed: Song?,
        recent: [Song],
        favorites: [Song],
        lyricIndex: LyricSignatureIndex,
        purpose: RecommendationPurpose,
        family: LyricModelFamily
    ) -> String {
        let taste = (recent.prefix(4) + favorites.prefix(4) + [seed].compactMap { $0 })
            .reduce(into: [String: Song]()) { $0[$1.id] = $1 }
            .values
            .prefix(6)
            .map { card(for: $0, lyricIndex: lyricIndex) }
            .joined(separator: "\n")
        let candidates = pool.enumerated().map { index, song in
            "\(index + 1). \(card(for: song, lyricIndex: lyricIndex))"
        }.joined(separator: "\n")
        return LyricModelPrompts.recommendationReview(
            family: family,
            purpose: purpose.rawValue,
            taste: taste.isEmpty ? "(none)" : taste,
            candidates: candidates
        )
    }

    private static func compactApplePrompt(
        pool: [Song],
        seed: Song?,
        recent: [Song],
        purpose: RecommendationPurpose,
        lyricIndex: LyricSignatureIndex,
        limit: Int
    ) -> String {
        let recentLine = recent.prefix(4)
            .map { "\($0.title) — \($0.artist)" }
            .joined(separator: " | ")
        let candidates = pool.prefix(20).map { song in
            let signature = lyricIndex.bySongID[song.id]
            let moods = (signature?.details.primaryMoods.isEmpty == false
                ? signature?.details.primaryMoods
                : signature?.moods)?.prefix(2).joined(separator: ",") ?? ""
            let genre = signature?.details.genre ?? song.genre ?? ""
            return "\(song.id) | \(song.title) — \(song.artist) | \(genre) | \(moods)"
        }.joined(separator: "\n")
        return """
        Pick up to \(limit) song ids for \(purpose.rawValue).
        Seed: \(seed.map { "\($0.title) — \($0.artist)" } ?? "none")
        Recent: \(recentLine.isEmpty ? "none" : recentLine)
        Reorder only listed ids. Keep the flow coherent and avoid needless artist repetition.
        JSON only: {"ids":[]}
        Candidates:
        \(candidates)
        """
    }

    private static func card(for song: Song, lyricIndex: LyricSignatureIndex) -> String {
        RecommendationPromptCard.make(song, lyricIndex: lyricIndex, excerptLimit: 160)
    }

    private static func currentSettings() async -> LyricIntelligenceSettings {
        await LyricIntelligenceSettings.load()
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: [String]] = [:]
    nonisolated(unsafe) private static var cacheOrder: [String] = []

    private static func cacheKey(
        songs: [Song],
        seed: Song?,
        lyricIndex: LyricSignatureIndex,
        purpose: RecommendationPurpose
    ) -> String {
        var fingerprint = songs.map(\.id).joined(separator: ",")
        fingerprint += "|\(purpose.rawValue)|\(seed?.id ?? "")"
        for song in songs {
            let signature = lyricIndex.bySongID[song.id]
            fingerprint += "|\(song.id):\(signature?.source ?? ""):\(signature?.summary ?? ""):\(signature?.moods.joined() ?? "")"
        }
        return LyricLexicalEmbedding.hash(fingerprint)
    }

    private static func cachedOrder(
        songs: [Song],
        seed: Song?,
        lyricIndex: LyricSignatureIndex,
        purpose: RecommendationPurpose
    ) -> [String]? {
        let key = cacheKey(
            songs: songs,
            seed: seed,
            lyricIndex: lyricIndex,
            purpose: purpose
        )
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let order = cache[key] else { return nil }
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        return order
    }

    private static func store(
        order: [String],
        songs: [Song],
        seed: Song?,
        lyricIndex: LyricSignatureIndex,
        purpose: RecommendationPurpose
    ) {
        let key = cacheKey(
            songs: songs,
            seed: seed,
            lyricIndex: lyricIndex,
            purpose: purpose
        )
        cacheLock.lock()
        if cache[key] != nil {
            cacheOrder.removeAll { $0 == key }
        } else if cache.count >= 24, let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
        cache[key] = order
        cacheOrder.append(key)
        cacheLock.unlock()
    }

    private static func stringList(_ value: Any?) -> [String] {
        if let values = value as? [String] { return values }
        if let values = value as? [Any] {
            return values.compactMap { $0 as? String }
        }
        if let value = value as? String { return [value] }
        return []
    }
}
