import Foundation

/// On-device tools the radio model may call. Arguments stay inside the
/// current pack so the model can read lyrics and analysis instead of
/// inventing an order from titles alone.
struct LyricModelToolkit: Sendable {
    var songsByID: [String: Song]
    var lyricIndex: LyricSignatureIndex
    var seed: Song?
    var lyricsProvider: (@Sendable (Song) async -> String)?

    static let maxLyricCalls = 4
    static let lyricCharacterLimit = 1_600

    private static let allowedTools: Set<String> = [
        "get_lyrics",
        "get_analysis",
        "compare_to_seed",
        "lookup_tracks"
    ]

    static var toolSchemas: [[String: Any]] {
        [
            function(
                name: "get_lyrics",
                description: "Fetch the lyric text for one library track in the current pack.",
                properties: [
                    "song_id": [
                        "type": "string",
                        "description": "Exact track id from the candidate list."
                    ]
                ],
                required: ["song_id"]
            ),
            function(
                name: "get_analysis",
                description: "Read stored lyric mood, summary, energy, and sound tags for one track.",
                properties: [
                    "song_id": [
                        "type": "string",
                        "description": "Exact track id from the candidate list."
                    ]
                ],
                required: ["song_id"]
            ),
            function(
                name: "compare_to_seed",
                description: "Compare one candidate to the now-playing seed using lyric and sound analysis.",
                properties: [
                    "song_id": [
                        "type": "string",
                        "description": "Exact track id from the candidate list."
                    ]
                ],
                required: ["song_id"]
            ),
            function(
                name: "lookup_tracks",
                description: "Refresh compact cards for up to 8 listed ids.",
                properties: [
                    "song_ids": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Track ids from the candidate list."
                    ]
                ],
                required: ["song_ids"]
            )
        ]
    }

    func invoke(name: String, argumentsJSON: String) async -> String {
        guard Self.allowedTools.contains(name) else {
            return #"{"error":"unknown tool"}"#
        }
        let arguments = Self.decodeObject(argumentsJSON)
        switch name {
        case "get_lyrics":
            return await lyricsJSON(id: string(arguments["song_id"]))
        case "get_analysis":
            return analysisJSON(id: string(arguments["song_id"]))
        case "compare_to_seed":
            return compareJSON(id: string(arguments["song_id"]))
        case "lookup_tracks":
            return lookupJSON(ids: stringList(arguments["song_ids"]))
        default:
            return #"{"error":"unknown tool"}"#
        }
    }

    static func decodeObject(_ raw: String) -> [String: Any] {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return [:]
        }
        return dictionary
    }

    private func lyricsJSON(id: String) async -> String {
        guard let song = songsByID[id] else {
            return #"{"error":"unknown id"}"#
        }
        let raw = await lyricsProvider?(song) ?? ""
        let text = LyricTextSampler.sample(raw, limit: Self.lyricCharacterLimit)
        if text.count < 24 {
            return encode([
                "song_id": id,
                "lyrics": "",
                "note": "no lyrics"
            ])
        }
        return encode([
            "song_id": id,
            "title": song.title,
            "artist": song.artist,
            "lyrics": text
        ])
    }

    private func analysisJSON(id: String) -> String {
        guard let song = songsByID[id] else {
            return #"{"error":"unknown id"}"#
        }
        guard let signature = lyricIndex.bySongID[id],
              signature.hasStoredLyricAnalysis else {
            return encode([
                "song_id": id,
                "title": song.title,
                "artist": song.artist,
                "note": "no stored lyric analysis"
            ])
        }
        return encode([
            "song_id": id,
            "title": song.title,
            "artist": song.artist,
            "moods": signature.moods,
            "themes": signature.themes,
            "energy": signature.energy,
            "valence": signature.valence,
            "summary": signature.summary,
            "arc": signature.details.emotionalArc,
            "vocal": signature.details.vocalGender,
            "genre": signature.details.genre,
            "language": signature.details.language,
            "sound": SoundLabelSpace.canonicalize(signature.soundLabels)
        ])
    }

    private func compareJSON(id: String) -> String {
        guard let seed,
              let left = lyricIndex.bySongID[seed.id],
              let right = lyricIndex.bySongID[id] else {
            return encode([
                "song_id": id,
                "note": "missing analysis for comparison"
            ])
        }
        return encode([
            "song_id": id,
            "seed_id": seed.id,
            "similarity": LyricLexicalEmbedding.similarity(left, right),
            "shared_moods": Array(
                Set(left.moodKeys).intersection(right.moodKeys)
            ),
            "energy_delta": abs(left.energy - right.energy),
            "valence_delta": abs(left.valence - right.valence)
        ])
    }

    private func lookupJSON(ids: [String]) -> String {
        let cards = Array(ids.prefix(8)).compactMap { id -> [String: Any]? in
            guard let song = songsByID[id] else { return nil }
            let signature = lyricIndex.bySongID[id]
            return [
                "song_id": id,
                "title": song.title,
                "artist": song.artist,
                "moods": signature?.moods ?? [],
                "summary": signature?.summary ?? "",
                "energy": signature?.energy ?? 0.5
            ]
        }
        return encode(["tracks": cards])
    }

    private func string(_ value: Any?) -> String {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func stringList(_ value: Any?) -> [String] {
        if let values = value as? [String] { return values }
        if let values = value as? [Any] {
            return values.compactMap { $0 as? String }
        }
        if let value = value as? String { return [value] }
        return []
    }

    private func encode(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    private static func function(
        name: String,
        description: String,
        properties: [String: Any],
        required: [String]
    ) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": required
                ]
            ]
        ]
    }
}

struct LyricToolCall: Equatable, Sendable {
    var id: String
    var name: String
    var arguments: String
}

enum LyricChatReply: Equatable, Sendable {
    case text(String)
    case tools([LyricToolCall])
}
