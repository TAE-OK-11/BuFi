import Foundation

/// Compact model-facing song card for recommendation/radio prompts.
/// Local ranking already did the expensive feature work, so the LLM only
/// needs enough signal to sequence the shortlist rather than the full stored
/// lyric-analysis record.
enum RecommendationCompactCard {
    static func make(
        _ song: Song,
        lyricIndex: LyricSignatureIndex,
        memoryLimit: Int = 72
    ) -> String {
        let signature = lyricIndex.bySongID[song.id]
        let details = signature?.details
        let moods = (details?.primaryMoods.isEmpty == false
            ? details?.primaryMoods
            : signature?.moods)?.prefix(2).joined(separator: ",") ?? ""
        let themes = (signature?.themes.isEmpty == false
            ? signature?.themes
            : details?.themes)?.prefix(2).joined(separator: ",") ?? ""
        let sound = SoundLabelSpace.canonicalize(signature?.soundLabels ?? [])
            .prefix(2)
            .joined(separator: ",")
        var genre = details?.genre ?? song.genre ?? ""
        if RadioContinuity.isKPop(song: song, signature: signature), genre.isEmpty {
            genre = "k-pop"
        }
        let bpm = SoundFeatureExtractor.bpm(song: song, signature: signature)
        let energy = signature.map { String(format: "%.2f", $0.energy) } ?? "-"
        let valence = signature.map { String(format: "%.2f", $0.valence) } ?? "-"
        let feel = RadioFeelGrammar.feel(song: song, signature: signature).rawValue
        let memory = clipped(
            signature?.summary.replacingOccurrences(of: "\n", with: " / "),
            limit: memoryLimit
        )

        var parts = [
            "\(song.id) | \(song.title) — \(song.artist)",
            "g:\(genre) bpm:\(bpm) e:\(energy) v:\(valence) feel:\(feel)"
        ]
        if !moods.isEmpty { parts.append("m:\(moods)") }
        if !themes.isEmpty { parts.append("t:\(themes)") }
        if !sound.isEmpty { parts.append("s:\(sound)") }
        if song.isStarred { parts.append("fav") }
        if !memory.isEmpty { parts.append("mem:\(memory)") }
        return parts.joined(separator: " | ")
    }

    private static func clipped(_ value: String?, limit: Int) -> String {
        guard limit > 0 else { return "" }
        let text = (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        return text.count <= limit ? text : String(text.prefix(limit))
    }
}
