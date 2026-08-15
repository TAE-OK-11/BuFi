import Foundation

enum RecommendationLLMReview {
    static let enabledKey = "recommendation-llm-review-enabled"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
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
        let pool = Array(songs.prefix(min(18, max(limit + 6, songs.count))))
        guard pool.count >= 3 else { return songs }
        let settings = await currentSettings()
        guard settings.provider != .off else { return songs }
        if let cached = cachedOrder(
            songs: pool,
            seed: seed,
            lyricIndex: lyricIndex,
            purpose: purpose
        ) {
            return apply(order: cached, to: songs, limit: limit)
        }
        let prompt = prompt(
            pool: pool,
            seed: seed,
            recent: recent,
            favorites: favorites,
            lyricIndex: lyricIndex,
            purpose: purpose
        )
        guard let raw = await LyricIntelligenceBackend.complete(
            prompt: prompt,
            settings: settings
        ), let order = parseIDs(raw, allowed: Set(pool.map(\.id))), !order.isEmpty else {
            return Array(songs.prefix(limit))
        }
        store(
            order: order,
            songs: pool,
            seed: seed,
            lyricIndex: lyricIndex,
            purpose: purpose
        )
        return apply(order: order, to: songs, limit: limit)
    }

    static func parseIDs(_ raw: String, allowed: Set<String>) -> [String]? {
        let json = extractJSON(from: raw) ?? raw
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

    private static func apply(order: [String], to songs: [Song], limit: Int) -> [Song] {
        var byID = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
        var result: [Song] = []
        result.reserveCapacity(min(limit, songs.count))
        for id in order {
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

    private static func prompt(
        pool: [Song],
        seed: Song?,
        recent: [Song],
        favorites: [Song],
        lyricIndex: LyricSignatureIndex,
        purpose: RecommendationPurpose
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
        return """
        You finish a music recommendation ranking. The numeric ranker already chose these library tracks.
        Goal: \(purpose.rawValue). Keep every listed id, invent none, return JSON only:
        {"ids":["id in listen-next order"]}
        Prefer the same emotional lane as taste, then a slight contrast that still matches energy.
        Demote same-artist spam, clashing valence, and cards with empty analysis.
        Taste:
        \(taste.isEmpty ? "(none)" : taste)
        Candidates:
        \(candidates)
        """
    }

    private static func card(for song: Song, lyricIndex: LyricSignatureIndex) -> String {
        let signature = lyricIndex.bySongID[song.id]
        let moods = signature?.moods.prefix(3).joined(separator: ",") ?? ""
        let themes = signature?.themes.prefix(3).joined(separator: ",") ?? ""
        let sound = signature?.soundLabels.prefix(3).joined(separator: ",") ?? ""
        let summary = signature?.summary.replacingOccurrences(of: "\n", with: " / ") ?? ""
        let energy = signature.map { String(format: "%.2f", $0.energy) } ?? "-"
        let valence = signature.map { String(format: "%.2f", $0.valence) } ?? "-"
        return "\(song.id) | \(song.title) — \(song.artist) | moods:\(moods) themes:\(themes) e:\(energy) v:\(valence) sound:\(sound) | \(summary)"
    }

    private static func currentSettings() async -> LyricIntelligenceSettings {
        let store = SecureStore()
        return LyricIntelligenceSettings.current(
            openAIKey: await store.loadSecret(
                account: LyricIntelligenceSettings.openAIAccount
            ) ?? "",
            openRouterKey: await store.loadSecret(
                account: LyricIntelligenceSettings.openRouterAccount
            ) ?? ""
        )
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: [String]] = [:]

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
        return cache[key]
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
        if cache.count >= 16 {
            cache.removeAll(keepingCapacity: true)
        }
        cache[key] = order
        cacheLock.unlock()
    }

    private static func extractJSON(from raw: String) -> String? {
        if let start = raw.firstIndex(of: "{"),
           let end = raw.lastIndex(of: "}"),
           start < end {
            return String(raw[start...end])
        }
        if let start = raw.firstIndex(of: "["),
           let end = raw.lastIndex(of: "]"),
           start < end {
            return String(raw[start...end])
        }
        return nil
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
