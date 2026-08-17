import Foundation

/// Local radio lane: K-pop stays in the K-pop room, vocals lean the same
/// gender without becoming a single-gender block.
enum RadioContinuity {
    static func isKPop(song: Song, signature: LyricSignature?) -> Bool {
        let blobs = [
            song.genre,
            song.genres?.map(\.name).joined(separator: " "),
            song.artist,
            song.title,
            signature?.details.genre,
            signature?.details.language,
            signature?.details.style
        ]
        .compactMap { $0 }
        .map(LyricLexicalEmbedding.normalized)
        let markers = [
            "kpop", "k-pop", "k pop", "케이팝", "idol", "아이돌",
            "korean pop", "girl group", "boy group", "걸그룹", "보이그룹",
            "krnb", "k-rnb", "khiphop", "k-hiphop"
        ]
        if blobs.contains(where: { text in
            markers.contains { text.contains($0) }
        }) {
            return true
        }
        let language = (signature?.details.language ?? "").lowercased()
        let koreanLanguage = language == "ko"
            || language.contains("korean")
            || language.contains("한국어")
        if koreanLanguage {
            let energy = signature?.energy ?? 0
            if energy >= 0.42 { return true }
            if blobs.contains(where: {
                $0.contains("pop") || $0.contains("dance") || $0.contains("idol")
            }) {
                return true
            }
        }
        if containsHangul(song.artist) || containsHangul(song.title) {
            if blobs.contains(where: {
                $0.contains("pop") || $0.contains("dance") || $0.contains("idol")
            }) {
                return true
            }
        }
        return false
    }

    static func vocalGender(song: Song, signature: LyricSignature?) -> String {
        let stored = LyricLexicalEmbedding.normalized(
            signature?.details.vocalGender ?? ""
        )
        if stored == "female" || stored == "male" || stored == "mixed" {
            return stored
        }
        if let labels = signature?.soundLabels, !labels.isEmpty {
            let inferred = SoundAnalysisClassifier.vocalGender(from: labels)
            if !inferred.isEmpty { return inferred }
        }
        _ = song
        return ""
    }

    static func laneScore(
        candidate: Song,
        seed: Song,
        lyricIndex: LyricSignatureIndex
    ) -> Double {
        let seedSignature = lyricIndex.bySongID[seed.id]
        let candidateSignature = lyricIndex.bySongID[candidate.id]
        var score = 0.0
        if isKPop(song: seed, signature: seedSignature) {
            score += isKPop(song: candidate, signature: candidateSignature)
                ? 0.11 : -0.05
        }
        let seedGender = vocalGender(song: seed, signature: seedSignature)
        let candidateGender = vocalGender(
            song: candidate,
            signature: candidateSignature
        )
        if seedGender == "female" || seedGender == "male" {
            if candidateGender == seedGender {
                score += 0.06
            } else if candidateGender == "mixed" {
                score += 0.02
            }
        }

        // First-stage radio now consumes the full structured lyric/audio view,
        // not just artist/genre identity. 0.5 is neutral, so old or incomplete
        // analyses do not receive an artificial boost or penalty.
        let semantic = LyricRecommendationFeatures.similarity(
            seed: seed,
            candidate: candidate,
            lyricIndex: lyricIndex
        )
        score += (semantic - 0.5) * 0.24
        return min(0.28, max(-0.18, score))
    }

    /// Rebalances the engine pool before Core ML. The base algorithm order is
    /// preserved as much as possible, but one familiar artist can no longer
    /// consume most of the shortlist before Core ML/LLM ever see alternatives.
    static func diversifiedEnginePool(
        _ songs: [Song],
        seed: Song,
        behavior: RecommendationBehaviorSnapshot,
        lyricIndex: LyricSignatureIndex,
        limit: Int
    ) -> [Song] {
        guard limit > 0 else { return [] }
        let values = TrackWorkIdentity.uniqueRecordings(songs)
        guard values.count > 1 else { return Array(values.prefix(limit)) }

        let recentlyPlayedArtists = Set(
            behavior.recentSongs.prefix(16).map {
                LyricLexicalEmbedding.normalized($0.artist)
            }
        )
        let knownArtists = Set(
            behavior.songs.values.compactMap { value -> String? in
                guard value.playCount > 0 else { return nil }
                let key = LyricLexicalEmbedding.normalized(value.song.artist)
                return key.isEmpty ? nil : key
            }
        )
        let seedArtist = LyricLexicalEmbedding.normalized(seed.artist)
        let maxPerArtist = max(4, min(8, limit / 12))
        let freshTarget = min(24, max(4, limit / 4))

        func isFresh(_ song: Song) -> Bool {
            let artist = LyricLexicalEmbedding.normalized(song.artist)
            let exposure = behavior.songs[song.id]?.playCount ?? 0
            return exposure <= 1
                || (!artist.isEmpty
                    && !knownArtists.contains(artist)
                    && !recentlyPlayedArtists.contains(artist))
        }

        // Stable quality order: retain the engine rank, using the richer
        // lyric/audio similarity only as a small tie-breaker. Freshness is a
        // final nudge, not permission for an unrelated track to enter.
        let count = max(values.count, 1)
        let ordered = values.enumerated().map { index, song -> (Song, Double) in
            let base = 1 - Double(index) / Double(count)
            let semantic = LyricRecommendationFeatures.similarity(
                seed: seed,
                candidate: song,
                lyricIndex: lyricIndex
            )
            let fresh = isFresh(song) ? 1.0 : 0.0
            return (song, base * 0.78 + semantic * 0.18 + fresh * 0.04)
        }
        .sorted {
            if $0.1 == $1.1 { return $0.0.id < $1.0.id }
            return $0.1 > $1.1
        }
        .map(\.0)

        var result: [Song] = []
        var remaining = ordered
        var artistCounts: [String: Int] = [:]
        var freshCount = 0
        result.reserveCapacity(min(limit, ordered.count))

        func allowed(_ song: Song, cap: Int) -> Bool {
            let artist = LyricLexicalEmbedding.normalized(song.artist)
            guard !artist.isEmpty else { return true }
            let count = artistCounts[artist, default: 0]
            // The seed artist is welcome as an anchor, but it follows the same
            // soft cap instead of receiving an identity shortcut.
            _ = seedArtist
            return count < cap
        }

        func take(at index: Int) {
            let song = remaining.remove(at: index)
            result.append(song)
            let artist = LyricLexicalEmbedding.normalized(song.artist)
            if !artist.isEmpty { artistCounts[artist, default: 0] += 1 }
            if isFresh(song) { freshCount += 1 }
        }

        while result.count < limit, !remaining.isEmpty {
            let wantsFresh = freshCount < freshTarget && result.count % 4 == 3
            if wantsFresh,
               let index = remaining.firstIndex(where: {
                   isFresh($0) && allowed($0, cap: maxPerArtist)
               }) {
                take(at: index)
                continue
            }
            if let index = remaining.firstIndex(where: {
                allowed($0, cap: maxPerArtist)
            }) {
                take(at: index)
                continue
            }
            break
        }

        // Small or single-artist libraries must still fill the requested pool.
        for relaxedCap in [maxPerArtist * 2, Int.max]
            where result.count < limit && !remaining.isEmpty {
            var index = 0
            while index < remaining.count, result.count < limit {
                if allowed(remaining[index], cap: relaxedCap) {
                    take(at: index)
                } else {
                    index += 1
                }
            }
        }
        return result
    }

    static func balance(
        _ songs: [Song],
        seed: Song,
        lyricIndex: LyricSignatureIndex,
        limit: Int
    ) -> [Song] {
        guard songs.count > 2 else { return Array(songs.prefix(limit)) }
        let seedSignature = lyricIndex.bySongID[seed.id]
        let seedKPop = isKPop(song: seed, signature: seedSignature)
        let seedGender = vocalGender(song: seed, signature: seedSignature)
        var picked: [Song] = []
        var rest = songs
        var sameGender = 0
        var kpopCount = 0

        func take(matching: (Song) -> Bool) -> Song? {
            guard let index = rest.firstIndex(where: matching) else { return nil }
            return rest.remove(at: index)
        }

        while picked.count < limit, !rest.isEmpty {
            let lastThreeSameGender =
                picked.suffix(3).count == 3
                && picked.suffix(3).allSatisfy {
                    vocalGender(song: $0, signature: lyricIndex.bySongID[$0.id])
                        == seedGender
                }
            let wantOtherGender =
                (seedGender == "female" || seedGender == "male")
                && (
                    (picked.count >= 3 && sameGender == picked.count)
                    || lastThreeSameGender
                )
            let wantKPop =
                seedKPop
                && (
                    picked.isEmpty
                    || (picked.count >= 2 && kpopCount * 2 < picked.count)
                )
            let next: Song
            if wantOtherGender,
               let song = take(matching: {
                   let gender = vocalGender(
                       song: $0,
                       signature: lyricIndex.bySongID[$0.id]
                   )
                   return !gender.isEmpty && gender != seedGender
               }) {
                next = song
            } else if wantKPop,
                      let song = take(matching: {
                          isKPop(song: $0, signature: lyricIndex.bySongID[$0.id])
                      }) {
                next = song
            } else {
                next = rest.removeFirst()
            }
            picked.append(next)
            if vocalGender(song: next, signature: lyricIndex.bySongID[next.id])
                == seedGender {
                sameGender += 1
            }
            if isKPop(song: next, signature: lyricIndex.bySongID[next.id]) {
                kpopCount += 1
            }
        }
        if seedGender == "female" || seedGender == "male",
           !picked.isEmpty,
           picked.allSatisfy({
               vocalGender(song: $0, signature: lyricIndex.bySongID[$0.id])
                   == seedGender
           }),
           let other = take(matching: {
               let gender = vocalGender(
                   song: $0,
                   signature: lyricIndex.bySongID[$0.id]
               )
               return !gender.isEmpty && gender != seedGender
           }) {
            picked[picked.count - 1] = other
        }
        return picked
    }

    private static func containsHangul(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0xAC00...0xD7A3).contains(scalar.value)
                || (0x1100...0x11FF).contains(scalar.value)
        }
    }
}
