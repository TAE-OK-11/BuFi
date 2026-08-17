import Foundation

enum RadioExternalSource: String, Hashable, Sendable {
    case lastFM = "Last.fm"
    case listenBrainz = "ListenBrainz"
}

struct RadioExternalTrack: Sendable {
    let song: Song
    var sources: Set<RadioExternalSource>

    var sourceLabel: String {
        if sources.contains(.lastFM), sources.contains(.listenBrainz) {
            return "Last.fm + ListenBrainz"
        }
        if sources.contains(.lastFM) { return RadioExternalSource.lastFM.rawValue }
        return RadioExternalSource.listenBrainz.rawValue
    }
}

/// Radio discovery is intentionally source-driven. Last.fm and ListenBrainz
/// choose the candidates; BuFi only resolves those external identities back to
/// playable library songs and merges duplicates before Gemini programs them.
actor RadioExternalSourcePool {
    static let shared = RadioExternalSourcePool()

    static let perSourceLimit = 20

    private let secureStore = SecureStore()
    private static let lastFMAccount = "lastfm-api-key"
    private static let listenBrainzAccount = "listenbrainz-token"
    private static let listenBrainzUsernameKey = "listenbrainz-username"

    func candidates(
        seed: Song,
        excludedIDs: Set<String>,
        snapshot: HomeSnapshot,
        behavior: RecommendationBehaviorSnapshot
    ) async -> [RadioExternalTrack] {
        async let lastFMKey = secureStore.loadSecret(account: Self.lastFMAccount)
        async let listenBrainzToken = secureStore.loadSecret(
            account: Self.listenBrainzAccount
        )
        let username = UserDefaults.standard.string(
            forKey: Self.listenBrainzUsernameKey
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let resolvedLastFMKey = await lastFMKey ?? ""
        let resolvedListenBrainzToken = await listenBrainzToken

        async let lastFMRaw: [ExternalRecommendationCandidate] = {
            guard !resolvedLastFMKey.isEmpty else { return [] }
            return await ExternalRecommendationClient.shared.lastFM(
                seed: seed,
                apiKey: resolvedLastFMKey,
                limit: Self.perSourceLimit
            )
        }()
        async let listenBrainzRaw: [ExternalRecommendationCandidate] = {
            guard !username.isEmpty else { return [] }
            return await ExternalRecommendationClient.shared.listenBrainz(
                username: username,
                token: resolvedListenBrainzToken,
                limit: Self.perSourceLimit
            )
        }()

        let library = MediaIdentity.uniqueSongs(
            from: [
                snapshot.knownSongs(),
                behavior.recentSongs,
                behavior.songs.values.map(\.song)
            ]
        ).filter {
            $0.id != seed.id
                && !excludedIDs.contains($0.id)
                && $0.externalStreamURL == nil
        }

        let rawLastFM = await lastFMRaw
        let rawListenBrainz = await listenBrainzRaw
        var lastFMSongs = matched(
            rawLastFM,
            in: library,
            limit: Self.perSourceLimit
        )
        var listenBrainzSongs = matched(
            rawListenBrainz,
            in: library,
            limit: Self.perSourceLimit
        )

        // Keep the last successful home enrichment useful when a public source
        // has a transient failure. These are still source results, not BuFi
        // recommendations or weighted substitutions.
        if lastFMSongs.isEmpty {
            lastFMSongs = Array(
                snapshot.lastFMRecommendedSongs
                    .filter {
                        $0.id != seed.id
                            && !excludedIDs.contains($0.id)
                            && $0.externalStreamURL == nil
                    }
                    .prefix(Self.perSourceLimit)
            )
        }
        if listenBrainzSongs.isEmpty {
            listenBrainzSongs = Array(
                snapshot.listenBrainzRecommendedSongs
                    .filter {
                        $0.id != seed.id
                            && !excludedIDs.contains($0.id)
                            && $0.externalStreamURL == nil
                    }
                    .prefix(Self.perSourceLimit)
            )
        }

        var merged: [String: RadioExternalTrack] = [:]
        var order: [String] = []
        func append(_ songs: [Song], source: RadioExternalSource) {
            for song in songs {
                let key = TrackWorkIdentity.recordingKey(for: song)
                if var existing = merged[key] {
                    existing.sources.insert(source)
                    merged[key] = existing
                } else {
                    merged[key] = RadioExternalTrack(
                        song: song,
                        sources: [source]
                    )
                    order.append(key)
                }
            }
        }
        append(lastFMSongs, source: .lastFM)
        append(listenBrainzSongs, source: .listenBrainz)
        return order.compactMap { merged[$0] }
    }

    private func matched(
        _ candidates: [ExternalRecommendationCandidate],
        in library: [Song],
        limit: Int
    ) -> [Song] {
        var result: [Song] = []
        var seen = Set<String>()
        for candidate in candidates {
            guard result.count < limit,
                  let song = bestMatch(candidate, in: library) else {
                continue
            }
            let recording = TrackWorkIdentity.recordingKey(for: song)
            guard seen.insert(recording).inserted else { continue }
            result.append(song)
        }
        return result
    }

    private func bestMatch(
        _ candidate: ExternalRecommendationCandidate,
        in library: [Song]
    ) -> Song? {
        if let mbid = candidate.recordingMBID?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !mbid.isEmpty,
           let exactMBID = library.first(where: {
               $0.musicBrainzId?.caseInsensitiveCompare(mbid) == .orderedSame
           }) {
            return exactMBID
        }

        let wantedTitle = normalized(candidate.title)
        let wantedArtist = normalized(candidate.artist)
        guard !wantedTitle.isEmpty, !wantedArtist.isEmpty else { return nil }
        let exact = library.filter {
            normalized($0.title) == wantedTitle
                && normalized($0.artist) == wantedArtist
        }
        guard !exact.isEmpty else { return nil }
        if exact.count == 1 { return exact[0] }

        if let album = candidate.album,
           !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let wantedAlbum = normalized(album)
            let albumMatches = exact.filter { normalized($0.album) == wantedAlbum }
            if albumMatches.count == 1 { return albumMatches[0] }
            if let first = albumMatches.first { return first }
        }

        // When the source does not provide a release, prefer an unqualified
        // studio title over a live/remix/acoustic sibling instead of guessing
        // from play count, favorites, or any BuFi recommendation weight.
        let sourceVariant = variantPenalty(candidate.title)
        return exact.min {
            let leftPenalty = abs(variantPenalty($0.title) - sourceVariant)
            let rightPenalty = abs(variantPenalty($1.title) - sourceVariant)
            if leftPenalty == rightPenalty { return $0.id < $1.id }
            return leftPenalty < rightPenalty
        }
    }

    private func normalized(_ value: String) -> String {
        value
            .precomposedStringWithCompatibilityMapping
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private func variantPenalty(_ value: String) -> Int {
        let text = value.lowercased()
        let markers = [
            "live", "remix", "acoustic", "instrumental", "karaoke",
            "remaster", "sped up", "slowed", "edit", "version"
        ]
        return markers.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
    }
}
