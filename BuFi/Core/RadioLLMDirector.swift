import Foundation

/// Gemini is the radio programmer. Last.fm and ListenBrainz discover the
/// candidate records; BuFi does not score, weight, or rerank those candidates.
enum RadioLLMDirector {
    static let requestedCount = 40
    static let enginePool = 40
    static let reviewKeep = 20
    static let packSize = 40

    // Kept for the non-LLM compatibility path in AppModel. The Gemini radio
    // path below does not use RecommendationMixer or this limit.
    static let mixerLimit = 360

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
        // Keep the public signature stable while deliberately removing BuFi
        // recommendation weights and analysis vectors from the Gemini path.
        _ = lyricIndex
        _ = weights

        let settings = if let loadedSettings {
            loadedSettings
        } else {
            await LyricIntelligenceSettings.load()
        }
        let external = await RadioExternalSourcePool.shared.candidates(
            seed: seed,
            excludedIDs: excludedIDs,
            snapshot: snapshot,
            behavior: behavior
        )
        guard !external.isEmpty else {
            RecommendationDiagnostics.record(
                kind: .radio,
                level: .error,
                title: String(localized: "외부 라디오 후보를 찾지 못했습니다"),
                detail: "Last.fm/ListenBrainz matched=0"
            )
            return []
        }

        let prompt = externalRadioPrompt(
            seed: seed,
            recent: behavior.recentSongs,
            candidates: external
        )
        let raw = await RadioGeminiRuntime.stream(
            prompt: prompt,
            settings: settings,
            maxTokens: 2_400
        ) { _ in
            // Candidate transport intentionally contains no opaque song ids.
            // Wait for the complete JSON object, then resolve the exact
            // artist/album/title tuple back to its local Song below.
        }

        var picked = parseSelections(raw, candidates: external)
        if picked.isEmpty {
            // Reliability fallback only: preserve provider discovery order.
            // No BuFi score, user weight, audio feature, or local reranker is
            // used when Gemini is unavailable or returns malformed metadata.
            picked = Array(external.prefix(reviewKeep).map(\.song))
            RecommendationDiagnostics.record(
                kind: .radio,
                level: .error,
                title: String(localized: "Gemini 라디오 응답을 읽지 못해 외부 후보 순서를 사용합니다"),
                detail: seed.title
            )
        }
        picked = Array(picked.prefix(reviewKeep))
        await emit(picked, using: onPick)
        return picked
    }

    /// Legacy no-Gemini fallback used by AppModel when AI is disabled. This is
    /// intentionally outside the external-source Gemini path above.
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
                ) * 0.45
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

    private static func externalRadioPrompt(
        seed: Song,
        recent: [Song],
        candidates: [RadioExternalTrack]
    ) -> String {
        let recentLines = recent.prefix(10).map(metadataLine).joined(separator: "\n")
        let candidateLines = candidates.map { candidate in
            "source: \(candidate.sourceLabel) | \(metadataLine(candidate.song))"
        }.joined(separator: "\n")

        return """
        You are the music director for one continuing BuFi personal-radio station.
        Use your pretrained knowledge of the actual songs, artists, albums, scenes, eras, production styles, melodies, cultural neighborhoods and collaborations. BuFi is deliberately NOT giving you local recommendation scores, popularity weights, lyric vectors, BPM weights, favorites, or any other numeric ranking signal. Make the musical judgement yourself.

        The only candidate-song information supplied is artist, album, title, and discovery source. Discovery source is provenance, not a score. If a track says "Last.fm + ListenBrainz", both independent recommenders surfaced the same playable library recording; treat that as useful corroboration, but never auto-promote it over a musically better transition.

        Continue the station as a path, not twenty independent seed lookalikes. Start close to what is currently playing, then diffuse gradually through bridges. Change one major axis at a time when possible: artist, era, texture, energy, lyrical shade, or cultural room. A distant track can be excellent later if earlier tracks earn the route to it.

        Distilled Spotify-radio behavior from observed runs:
        - Same-artist adjacency was very rare overall. A same-artist first handoff can be excellent when it is an obvious sister track, but after that let the artist breathe.
        - Seed artists often return as anchors after roughly four intervening songs. Treat that as a soft cadence, never a quota.
        - Exact peer titles vary between runs more than the artist/room cadence. Prefer the shape of the journey over copying a memorized song list.
        - Do not teleport from the seed to a far-away left turn. Use bridge records.
        - Do not reset to the original seed when conversation history is present. Continue from the recent listening trajectory and the previous Gemini chapter.
        - Tracks 1-3 should be immediately convincing; 4-8 gently widen; 9-14 can broaden the neighborhood; 15-20 may reach the outer edge while leaving a believable doorway for the next chapter.

        Real Spotify observations — learn the topology, not the titles:
        1) Vitamin ME — fromis_9
           -> 잔혹한 천사의 테제 — HANRORO
           -> Ever2Late! — KiiiKiii
           -> Lemon Tang — Hearts2Hearts
           -> 4 Flowers — MAMAMOO
           -> LOVE BOMB — fromis_9
           -> 만찬가 — TAEYEON
           -> 상상더하기 — LABOUM
           -> Hey Hi — KiiiKiii
           -> 갑자기 — I.O.I
           -> LIKE YOU BETTER — fromis_9
           This shows gradual widening with the seed artist returning as an anchor rather than chaining.

        2) Feel Special — TWICE
           -> FANCY — TWICE
           -> HOT — LE SSERAFIM
           -> Cosmic — Red Velvet
           -> Whiplash — aespa
           -> NEKKOYA (PICK ME) — PRODUCE 48
           -> YES or YES — TWICE
           This shows the rare strong same-artist opening sister followed immediately by cross-artist breathing and a later anchor return.

        3) MANIAC — VIVIZ
           -> After School — Weeekly
           -> HOT — LE SSERAFIM
           -> Cosmic — Red Velvet
           -> 다시 만난 세계 — Girls' Generation
           -> Cheshire — ITZY
           -> Underwater — KWON EUNBI
           -> BOP BOP! — VIVIZ
           This shows cross-generation movement inside a coherent musical room before returning to the seed artist.

        4) Ode to Love — NCT WISH
           -> Lucky to be loved — TWS
           -> YOUNGCREATORCREW — CORTIS
           -> Ever2Late! — KiiiKiii
           -> Lemon Tang — Hearts2Hearts
           -> ddok ddok ddok — BOYNEXTDOOR
           -> BOY MEETS GIRL — NCT WISH
           -> If I'm S, Can You Be My N? — TWS
           -> TNT — CORTIS
           -> LOUD — NMIXX
           -> Hype Boy — NewJeans
           -> Surf — NCT WISH
           This shows a stable youth-pop micro-neighborhood whose peers explore while familiar artists periodically stabilize it.

        MOST RECENT PLAYBACK — newest first, maximum 10:
        \(recentLines.isEmpty ? "none" : recentLines)

        CURRENT TRACK / SEED:
        \(metadataLine(seed))

        PLAYABLE EXTERNAL CANDIDATES — already matched into the BuFi library and deduplicated. Do not invent anything outside this list:
        \(candidateLines)

        Choose up to 20 tracks in actual playback order. Return 20 when at least 20 candidates can form a coherent chapter. Copy artist, album, and title EXACTLY from the candidate list so BuFi can resolve your choices without exposing internal ids.

        Return one JSON object only, no markdown or explanation:
        {"tracks":[{"artist":"exact artist","album":"exact album","title":"exact title"}]}
        """
    }

    private static func parseSelections(
        _ raw: String?,
        candidates: [RadioExternalTrack]
    ) -> [Song] {
        guard let raw,
              let json = LyricJSONExtractor.object(from: raw),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let tracks = dictionary["tracks"] as? [[String: Any]] else {
            return []
        }

        var result: [Song] = []
        var seen = Set<String>()
        for track in tracks {
            guard result.count < reviewKeep,
                  let artist = track["artist"] as? String,
                  let title = track["title"] as? String else {
                continue
            }
            let album = track["album"] as? String ?? ""
            let artistKey = normalized(artist)
            let titleKey = normalized(title)
            let albumKey = normalized(album)
            let matches = candidates.filter {
                normalized($0.song.artist) == artistKey
                    && normalized($0.song.title) == titleKey
            }
            let selected: Song?
            if !albumKey.isEmpty,
               let albumMatch = matches.first(where: {
                   normalized($0.song.album) == albumKey
               }) {
                selected = albumMatch.song
            } else {
                selected = matches.count == 1 ? matches[0].song : matches.first?.song
            }
            guard let selected else { continue }
            let recording = TrackWorkIdentity.recordingKey(for: selected)
            guard seen.insert(recording).inserted else { continue }
            result.append(selected)
        }
        return result
    }

    private static func metadataLine(_ song: Song) -> String {
        "artist: \(song.artist) | album: \(song.album) | title: \(song.title)"
    }

    private static func normalized(_ value: String) -> String {
        value
            .precomposedStringWithCompatibilityMapping
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func emit(
        _ songs: [Song],
        using onPick: (@Sendable (Song) async -> Void)?
    ) async {
        guard let onPick else { return }
        for song in songs {
            guard !Task.isCancelled else { return }
            await onPick(song)
        }
    }
}
