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
        return score
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
