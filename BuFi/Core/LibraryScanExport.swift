import Foundation

enum LibraryScanExport {
    static func make(
        catalog: [Song],
        index: LyricSignatureIndex
    ) -> String {
        let songs = MediaIdentity.uniqueSongs(from: [catalog])
        let tracks: [[String: Any]] = songs.compactMap { song in
            let signature = index.bySongID[song.id]
            guard signature != nil
                    || song.bpm != nil
                    || song.genre != nil else {
                // Keep unscanned catalog rows so missing coverage is visible.
                return row(song: song, signature: nil)
            }
            return row(song: song, signature: signature)
        }.sorted {
            let left = ($0["title"] as? String ?? "")
            let right = ($1["title"] as? String ?? "")
            return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
        }
        let payload: [String: Any] = [
            "version": 1,
            "purpose": "bufi-scan-export",
            "trackCount": tracks.count,
            "featureNames": RadioTransitionFeatures.names,
            "tracks": tracks
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private static func row(
        song: Song,
        signature: LyricSignature?
    ) -> [String: Any] {
        let details = signature?.details
        let feel = RadioFeelGrammar.feel(song: song, signature: signature).rawValue
        return [
            "id": song.id,
            "title": song.title,
            "artist": song.artist,
            "album": song.album,
            "genre": song.genre ?? "",
            "bpmServer": song.bpm ?? 0,
            "bpmMeasured": details?.audioBPM ?? 0,
            "energy": signature?.energy ?? 0,
            "valence": signature?.valence ?? 0,
            "intimacy": details?.intimacy ?? 0,
            "feel": feel,
            "moods": signature?.moods ?? [],
            "themes": signature?.themes ?? [],
            "summary": signature?.summary ?? "",
            "lyricExcerpt": details?.lyricExcerpt ?? "",
            "interpretation": details?.interpretation ?? "",
            "emotionalArc": details?.emotionalArc ?? "",
            "soundLabels": signature?.soundLabels ?? [],
            "audioEnergy": details?.audioEnergy ?? 0,
            "audioBrightness": details?.audioBrightness ?? 0,
            "audioPulse": details?.audioPulse ?? 0,
            "audioMeasured": details?.audioMeasured ?? false,
            "vocalGender": RadioContinuity.vocalGender(
                song: song,
                signature: signature
            ),
            "kpop": RadioContinuity.isKPop(song: song, signature: signature),
            "starred": song.isStarred,
            "playCount": song.playCount ?? 0,
            "lyricSource": signature?.source ?? "",
            "soundSource": signature?.soundSource ?? "",
            "hasLyricAnalysis": signature?.hasStoredLyricAnalysis ?? false,
            "hasSoundAnalysis": signature?.hasStoredSoundAnalysis ?? false,
            "features": RadioTransitionFeatures.snapshot(
                song: song,
                signature: signature
            )
        ]
    }
}
