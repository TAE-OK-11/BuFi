import Foundation

enum LyricModelFamily: String, Sendable {
    case appleFoundation
    case llama70B
    case gptOSS
    case gemini
    case generic

    static func resolve(_ settings: LyricIntelligenceSettings) -> LyricModelFamily {
        switch settings.provider {
        case .onDevice, .applePrivateCloud:
            return .appleFoundation
        case .off:
            return .generic
        case .openAI, .openRouter, .groq, .googleAI, .cerebras:
            return resolve(model: settings.activeModelName)
        }
    }

    static func resolve(model: String) -> LyricModelFamily {
        let value = model.lowercased()
        if value.contains("gemini") {
            return .gemini
        }
        if value.contains("gpt-oss")
            || value.contains("oss-120")
            || value.contains("qwen3.6")
            || value.contains("qwen/qwen3") {
            return .gptOSS
        }
        if value.contains("llama-3.3")
            || value.contains("llama3.3")
            || value.contains("llama-3.1-70")
            || value.contains("llama3.1-70") {
            return .llama70B
        }
        return .generic
    }

    var lyricCharacterLimit: Int {
        switch self {
        case .appleFoundation: 1_500
        case .llama70B: 3_600
        case .gptOSS: 5_000
        case .gemini: 4_200
        case .generic: 2_400
        }
    }

    var reviewPoolLimit: Int {
        switch self {
        case .appleFoundation: 8
        case .llama70B: 16
        case .gptOSS: 18
        case .gemini: 20
        case .generic: 12
        }
    }
}

/// Keeps the beginning, middle and ending of long lyrics inside a fixed model
/// budget instead of feeding only the first verse. This improves narrative
/// coverage while reducing prompt size for the on-device model.
enum LyricTextSampler {
    static func normalized(_ text: String) -> String {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var result: [String] = []
        result.reserveCapacity(lines.count)
        var previousWasBlank = true
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if !previousWasBlank {
                    result.append("")
                }
                previousWasBlank = true
            } else {
                result.append(trimmed)
                previousWasBlank = false
            }
        }
        while result.last?.isEmpty == true {
            result.removeLast()
        }
        return result.joined(separator: "\n")
    }

    static func sample(_ text: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        let clean = normalized(text)
        let characters = Array(clean)
        guard characters.count > limit else { return clean }

        let divider = Array("\n[…]\n")
        let dividerCost = divider.count * 2
        guard limit > dividerCost + 24 else {
            return String(characters.prefix(limit))
        }

        let usable = limit - dividerCost
        let headCount = max(1, usable * 45 / 100)
        let middleCount = max(1, usable * 20 / 100)
        let tailCount = max(1, usable - headCount - middleCount)
        let middleStart = min(
            max(
                0,
                max(
                    headCount,
                    min(
                        characters.count - tailCount - middleCount,
                        characters.count / 2 - middleCount / 2
                    )
                )
            ),
            max(0, characters.count - middleCount)
        )
        let middleEnd = min(characters.count, middleStart + middleCount)
        let tailStart = min(characters.count, max(0, characters.count - tailCount))
        guard middleStart < middleEnd else {
            return String(characters.prefix(limit))
        }

        var sampled: [Character] = []
        sampled.reserveCapacity(limit)
        sampled.append(contentsOf: characters.prefix(headCount))
        sampled.append(contentsOf: divider)
        sampled.append(contentsOf: characters[middleStart..<middleEnd])
        sampled.append(contentsOf: divider)
        sampled.append(contentsOf: characters[tailStart..<characters.count])
        let chorus = repeatedLines(in: clean)
        if !chorus.isEmpty {
            let chorusBlock = Array("\n[chorus]\n" + chorus.joined(separator: "\n"))
            if sampled.count + chorusBlock.count <= limit {
                sampled.append(contentsOf: chorusBlock)
            } else if sampled.count > chorusBlock.count + 24 {
                sampled.removeLast(min(chorusBlock.count, sampled.count))
                sampled.append(contentsOf: chorusBlock)
            }
        }
        return String(sampled.prefix(limit))
    }

    static func repeatedLines(in text: String) -> [String] {
        var counts: [String: (line: String, count: Int)] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 8 else { continue }
            let key = LyricLexicalEmbedding.normalized(trimmed)
            if var existing = counts[key] {
                existing.count += 1
                counts[key] = existing
            } else {
                counts[key] = (trimmed, 1)
            }
        }
        return counts.values
            .filter { $0.count >= 2 && $0.line.count <= 96 }
            .sorted {
                if $0.count == $1.count { return $0.line.count < $1.line.count }
                return $0.count > $1.count
            }
            .prefix(3)
            .map(\.line)
    }
}

extension LyricIntelligenceSettings {
    var activeModelName: String {
        switch provider {
        case .groq: groqModel
        case .googleAI: geminiModel
        case .cerebras: cerebrasModel
        case .openRouter: openRouterModel
        case .openAI: "gpt-4o-mini"
        case .onDevice, .applePrivateCloud: "apple-foundation-3b"
        case .off: ""
        }
    }
}

enum LyricModelPrompts {
    static func lyricAnalysis(lyrics: String, family: LyricModelFamily) -> String {
        let body = LyricTextSampler.sample(lyrics, limit: family.lyricCharacterLimit)
        switch family {
        case .appleFoundation:
            return """
            Analyze lyric meaning for music recommendations. Return one JSON object only.
            {"moods":["calm"],"themes":["night"],"energy":0.3,"valence":0.2,"summary":"창가에서 그 이름을 부른다.\\n빗소리가 방을 채운다.","season":"autumn","dayparts":["night"],"style":"","content":"그리움","setting":"","tempo":0.3,"intimacy":0.8,"narrative":"confession","weather":"rain","social":"alone","color":"blue","vocal":"","vocalGender":"","genre":"","language":"ko","emotion":0.7,"context":"late night"}
            Use 1-4 short moods/themes. energy=lyrical intensity; valence=emotional positivity. summary=the lyric story, not metadata.
            Use season/daypart/weather only when the words support them. Do not invent audio facts: vocal, vocalGender and genre stay empty unless explicit in the text.
            Lyrics:
            \(body)
            """
        case .llama70B:
            return """
            You catalogue lyrics for a personal recommender. Return exactly one JSON object, no markdown.
            {"primaryMoods":[],"secondaryMoods":[],"themes":[],"energy":0.0,"valence":0.0,"emotion":0.0,"summary":"","interpretation":"","emotionalArc":"","relationship":"","season":"spring|summer|autumn|winter|any","dayparts":[],"style":"","content":"","setting":"","tempo":0.0,"intimacy":0.0,"narrative":"","weather":"","social":"","color":"","vocal":"","vocalGender":"","genre":"","language":"ko|en|ja|other","context":""}
            Ground every field in the lyrics. primaryMoods are 1-3 core narrator emotions ranked by importance; secondaryMoods are 0-2 supporting ones. Prefer precise labels such as yearning, nostalgic, anxious over generic sad/happy when the text supports them.
            energy is lyrical intensity, tempo is narrative pace, valence is emotional positivity, emotion is intensity. summary retells who feels or does what and how it changes or ends, in the lyric language. interpretation is the higher-level meaning. emotionalArc is begin -> turn -> end.
            Never write language commentary. Do not guess singer gender, production, or genre from lyrics; leave audio-only fields empty unless the text itself proves them.
            Lyrics:
            \(body)
            """
        case .gptOSS:
            return """
            Role: senior lyric analyst for a music recommender. Read the excerpt as one narrative, then return exactly one JSON object and nothing else.
            {"primaryMoods":[],"secondaryMoods":[],"themes":[],"energy":0.0,"valence":0.0,"emotion":0.0,"summary":"","explicitContent":"","interpretation":"","emotionalArc":"","relationship":"","season":"","dayparts":[],"content":"","setting":"","narrative":"","social":"","language":"","context":"","style":"","tempo":0.0,"intimacy":0.0,"weather":"","color":"","vocal":"","vocalGender":"","genre":""}
            primaryMoods: 1-3 emotions that define the narrator's core state. secondaryMoods: 0-2 real but less central emotions. Rank both by importance; prefer precise labels such as yearning, resentful, obsessive, nostalgic, anxious, euphoric over generic sad/happy/angry when the lyrics support them.
            themes are recurring ideas or conflicts, not duplicate mood words. energy=lyrical intensity, valence=emotional positivity, emotion=emotional intensity, tempo=narrative pace. These describe the words, never the recording.
            explicitContent contains only events, situations or desires directly stated or strongly evidenced by the lyrics. interpretation is the higher-level meaning inferred from that evidence. emotionalArc describes how the narrator's state changes from beginning to end. relationship names the relationship only when supported.
            summary: 2-4 concise sentences that paraphrase the speaker, desire/conflict, important turn and ending. Do not quote or reproduce lyric lines. Do not call the narrator the artist. Distinguish fantasies, threats, irony, metaphor and hyperbole from literal actions when the text does.
            Never invent biography, production, instrumentation, genre, singer identity or vocal gender. Leave audio-only fields vocal/vocalGender/genre empty unless explicitly stated in the words. Leave season/daypart/weather/setting empty when unsupported.
            Lyrics:
            \(body)
            """
        case .gemini:
            return """
            You extract grounded lyric meaning for a music recommender. Treat the text as one narrator's story. Use Korean or the lyric language for summary and interpretation.

            Return exactly one JSON object. Start with { . No markdown fences, no preface, no trailing commentary.

            {"primaryMoods":[],"secondaryMoods":[],"themes":[],"energy":0.0,"valence":0.0,"emotion":0.0,"summary":"","explicitContent":"","interpretation":"","emotionalArc":"","relationship":"","season":"","dayparts":[],"content":"","setting":"","narrative":"","social":"","language":"","context":"","style":"","tempo":0.0,"intimacy":0.0,"weather":"","color":"","vocal":"","vocalGender":"","genre":""}

            Constraints:
            - primaryMoods: 1-3 precise narrator emotions ranked by importance (yearning, nostalgic, anxious, resentful, euphoric). Avoid vague sad/happy when a sharper word fits.
            - secondaryMoods: 0-2 supporting emotions. themes: ideas/conflicts, not mood synonyms.
            - energy = intensity of the words. valence = positivity of the feeling. emotion = how strongly it is felt. tempo = how fast the story moves. These are literary, never production.
            - summary: 2-4 sentences in the lyric language. Paraphrase the speaker, want/conflict, turn, ending. Call the speaker the narrator, never the artist. Do not quote lyric lines.
            - Distinguish metaphor, fantasy, threat, irony, and hyperbole from literal events.
            - vocal, vocalGender, genre stay empty unless the words themselves state them.
            - Leave unsupported fields empty. Do not invent biography, season, weather, or setting.

            Lyrics:
            \(body)
            """
        case .generic:
            return """
            Analyze these lyrics for recommendations. JSON only:
            {"moods":[],"themes":[],"energy":0.0,"valence":0.0,"summary":"","season":"any","dayparts":[],"style":"","content":"","setting":"","weather":"","language":"","emotion":0.0,"context":"","emotionalArc":""}
            Use only evidence in the lyrics. summary retells the lyric story and how it changes. emotionalArc is begin -> turn -> end when present. Never describe the task or language.
            Lyrics:
            \(body)
            """
        }
    }

    static func tagging(lyrics: String, family: LyricModelFamily) -> String {
        let body = LyricTextSampler.sample(lyrics, limit: family.lyricCharacterLimit)
        switch family {
        case .appleFoundation:
            return """
            Extract grounded lyric meaning for recommendations. One JSON object only:
            {"moods":["calm"],"themes":["night"],"energy":0.3,"valence":0.2,"summary":"창가에서 기다린다.\\n비가 이름을 적신다.","season":"autumn","dayparts":["night"],"content":"그리움","setting":"city","weather":"rain","language":"ko","emotion":0.7,"context":"late night"}
            Use only evidence in the words. energy=lyrical intensity, valence=emotional positivity. summary is story only.
            Lyrics:
            \(body)
            """
        default:
            return lyricAnalysis(lyrics: lyrics, family: family)
        }
    }

    static func summaryOnly(lyrics: String, family: LyricModelFamily) -> String {
        let body = LyricTextSampler.sample(lyrics, limit: family.lyricCharacterLimit)
        switch family {
        case .appleFoundation:
            return """
            Retell the lyric story accurately. JSON only:
            {"summary":"창가에서 그 이름을 부른다.\\n빗소리가 방을 채운다."}
            Include the emotional turn or ending when present. No language or task commentary.
            Lyrics:
            \(body)
            """
        case .llama70B:
            return """
            Write an accurate lyric synopsis in the lyric language. JSON only:
            {"summary":"..."}
            Cover the speaker, desire or conflict, important turn, and ending when present. Story only; no metadata commentary.
            Lyrics:
            \(body)
            """
        case .gptOSS:
            return """
            Music editor task. Understand the full excerpt and output JSON only:
            {"summary":"..."}
            Preserve the lyric's narrative and emotional change. Never mention the task, sentence count, or language label.
            Lyrics:
            \(body)
            """
        case .gemini:
            return """
            Retell the lyric story in the lyric language. One JSON object only, start with {.

            {"summary":"..."}

            2-4 sentences. Speaker, desire or conflict, turn, ending. Paraphrase — do not quote. No task or language labels.

            Lyrics:
            \(body)
            """
        case .generic:
            return """
            {"summary":"accurate lyric story"}
            Lyrics:
            \(body)
            """
        }
    }

    static func recommendationReview(
        family: LyricModelFamily,
        purpose: String,
        taste: String,
        candidates: String
    ) -> String {
        let brief = radioProgramInstructions(keep: nil, purpose: purpose)
        switch family {
        case .appleFoundation:
            return """
            \(brief)
            Taste:
            \(taste)
            Tracks:
            \(candidates)
            """
        default:
            return """
            \(brief)
            Taste:
            \(taste)
            Candidates:
            \(candidates)
            """
        }
    }

    static func playlistCompose(
        family: LyricModelFamily,
        title: String,
        brief: PersonalizedMixBrief,
        hour: Int,
        month: Int,
        today: String,
        candidates: String
    ) -> String {
        let season: String
        switch month {
        case 3...5: season = "spring"
        case 6...8: season = "summer"
        case 9...11: season = "autumn"
        default: season = "winter"
        }
        let context = "hour=\(hour) season=\(season) mix=\(title)"
        switch family {
        case .appleFoundation:
            return """
            Pick songs for this mix. JSON only:
            {"ids":["id"],"subtitle":"short"}
            Mood: \(brief.mood)
            Audio: \(brief.audioFeel)
            Today:
            \(today)
            Tracks:
            \(candidates)
            """
        case .llama70B:
            return """
            Build the playlist "\(title)" from listed library ids only.
            \(context)
            Locked lane:
            mood: \(brief.mood)
            theme: \(brief.theme)
            audio: \(brief.audioFeel)
            Use today's listens as the emotional weather, then stay inside the lane.
            JSON only:
            {"ids":["order to play"],"subtitle":"one line in the user's language"}
            Today:
            \(today)
            Candidates:
            \(candidates)
            """
        case .gptOSS:
            return """
            Role: playlist director for "\(title)". \(context)
            The lane is already decided — do not invent a new mood:
            mood: \(brief.mood)
            theme: \(brief.theme)
            audio: \(brief.audioFeel)
            Today's listening is the weather report. Sequence a set that feels like one room.
            JSON only, no preamble:
            {"ids":["id"],"subtitle":""}
            Today:
            \(today)
            Candidates:
            \(candidates)
            """
        case .gemini:
            return """
            Build the mix "\(title)" from listed ids only. \(context)
            Stay in the locked lane — do not invent a new mood:
            mood: \(brief.mood)
            theme: \(brief.theme)
            audio: \(brief.audioFeel)
            Today's listens are the weather. Sequence one room, not a shuffle.

            One JSON object, start with {:
            {"ids":["id"],"subtitle":"한 줄"}

            Today:
            \(today)
            Candidates:
            \(candidates)
            """
        case .generic:
            return """
            {"ids":[],"subtitle":""}
            \(brief.mood) / \(brief.audioFeel)
            \(today)
            \(candidates)
            """
        }
    }

    static func radioProgram(
        family: LyricModelFamily,
        keep: Int,
        session: String,
        seed: String,
        recent: String,
        candidates: String,
        extras: String
    ) -> String {
        if family == .gemini {
            return """
            \(RadioFeelGrammar.geminiRadioBrief)

            These candidates already survived the library engine (50) and the
            on-device ranker (30). Throw out anything off-lane. Keep up to \(keep)
            listed ids that belong in this show — fewer is fine if the rest do not fit.
            If you still need more songs in-lane, add a need object with the weights
            those replacements must match (feel, moods, energy, genre, vocal, want).
            K-pop: walk to similar artists in the same room, not a random idol shuffle.
            Same artist+title is one recording — do not sit a live/acoustic sibling next to the original.
            Preferred artists are a slight lean, never a block.

            Return one JSON object and start writing it immediately:
            {"ids":[],"need":{"count":0}}
            No markdown, no analysis text.

            \(session)
            Seed (opening thesis of the show):
            \(seed)
            Recent (already heard — hand off from this weather, do not ignore it):
            \(recent)
            Candidates (grouped by room / nearby / left turn — pick a living sequence from all three):
            \(candidates)
            \(extras)
            """
        }
        let rules = radioProgramInstructions(keep: keep, purpose: nil, soulful: true)
        return """
        \(rules)

        \(session)
        Seed (the record they just chose — this is the show's opening thesis):
        \(seed)
        Recent (what they already heard this session):
        \(recent)
        Candidates:
        \(candidates)
        \(extras)
        """
    }

    private static func radioProgramInstructions(
        keep: Int?,
        purpose: String?,
        soulful: Bool = true
    ) -> String {
        let keepLine: String
        if let keep {
            keepLine = "Keep exactly \(keep) listed ids. Discard the rest."
        } else if let purpose {
            keepLine = "Purpose: \(purpose). Rank the listed ids only."
        } else {
            keepLine = "Keep only listed ids."
        }
        let craft = soulful
            ? """
            Program this like a great personal radio show, not a similarity engine.
            The next song should feel inevitable — the kind of pick a friend who knows the catalog would send at this hour. Clones of the seed are a failure. Tag overlap without a point of view is a failure.

            Shape the set in three movements:
            1. Settle (2-3 songs): honor why they started this seed. Same emotional room, different record.
            2. Deepen: stay inside the story, night, or desire. Change artist, era, or texture so it does not sound generated.
            3. One turn, then land: one song that is surprising but obviously right if you know both records. Then resolve without snapping back to copies.

            Use your own knowledge of these artists and titles (what the song is known for, who they tour or collab with, title track vs b-side, cultural room). Use stored lyric memory and excerpts as your notes on this exact recording. Trust measured BPM/energy when they disagree with memory. A planned lift or drop is allowed once; do not jerk the body around.

            \(RadioFeelGrammar.promptAppendix)
            """
            : """
            Combine pretrained knowledge of the listed artists/titles, stored lyric memory, and measured BPM/energy. Thin cards should be filled from what you know about that title. Sequence a listen, not a shuffle.
            """
        return """
        You are a music director with taste. \(craft)

        \(keepLine)
        Same artist+title is one recording — do not sit a live/acoustic sibling next to the original.
        Preferred artists are a slight lean, never a block. Avoid three songs by one artist in a row.
        Never invent a song that is not listed. Never invent ids.

        Return one JSON object and start writing it immediately:
        {"ids":[]}
        No markdown, no analysis text.
        """
    }
}

enum RecommendationPromptCard {
    static func make(
        _ song: Song,
        lyricIndex: LyricSignatureIndex,
        excerptLimit: Int = 180
    ) -> String {
        let signature = lyricIndex.bySongID[song.id]
        let details = signature?.details
        let moods = (details?.primaryMoods.isEmpty == false
            ? details?.primaryMoods
            : signature?.moods)?.prefix(3).joined(separator: ",") ?? ""
        let themes = (signature?.themes.isEmpty == false
            ? signature?.themes
            : details?.themes)?.prefix(3).joined(separator: ",") ?? ""
        let sound = SoundLabelSpace.canonicalize(signature?.soundLabels ?? [])
            .prefix(3)
            .joined(separator: ",")
        let vocal = RadioContinuity.vocalGender(song: song, signature: signature)
        var genre = details?.genre ?? song.genre ?? ""
        if RadioContinuity.isKPop(song: song, signature: signature) {
            genre = genre.isEmpty ? "k-pop" : genre
        }
        let bpm = SoundFeatureExtractor.bpm(song: song, signature: signature)
        let energy = signature.map { String(format: "%.2f", $0.energy) } ?? "-"
        let valence = signature.map { String(format: "%.2f", $0.valence) } ?? "-"
        let summary = clipped(
            signature?.summary.replacingOccurrences(of: "\n", with: " / "),
            limit: 140
        )
        let interpretation = clipped(details?.interpretation, limit: 100)
        let arc = clipped(details?.emotionalArc, limit: 80)
        let excerpt = clipped(
            details?.lyricExcerpt.replacingOccurrences(of: "\n", with: " / "),
            limit: excerptLimit
        )
        var parts = [
            "\(song.id) | \(song.title) — \(song.artist)",
            "album:\(song.album) bpm:\(bpm) e:\(energy) v:\(valence) vox:\(vocal) g:\(genre)"
        ]
        let feel = RadioFeelGrammar.feel(song: song, signature: signature).rawValue
        parts.append("feel:\(feel)")
        if !moods.isEmpty { parts.append("moods:\(moods)") }
        if !themes.isEmpty { parts.append("themes:\(themes)") }
        if !sound.isEmpty { parts.append("sound:\(sound)") }
        if let details, details.audioMeasured {
            parts.append(
                String(
                    format: "audio e:%.2f br:%.2f pulse:%.2f",
                    details.audioEnergy,
                    details.audioBrightness,
                    details.audioPulse
                )
            )
        }
        if song.isStarred { parts.append("fav") }
        if let plays = song.playCount { parts.append("plays:\(plays)") }
        if !summary.isEmpty { parts.append("memory:\(summary)") }
        if !interpretation.isEmpty { parts.append("read:\(interpretation)") }
        if !arc.isEmpty { parts.append("arc:\(arc)") }
        if let relationship = details?.relationship, !relationship.isEmpty {
            parts.append("rel:\(relationship)")
        }
        if let setting = details?.setting, !setting.isEmpty {
            parts.append("set:\(setting)")
        }
        if !excerpt.isEmpty { parts.append("lyrics:\(excerpt)") }
        return parts.joined(separator: " | ")
    }

    private static func clipped(_ value: String?, limit: Int) -> String {
        let text = (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        return text.count <= limit ? text : String(text.prefix(limit))
    }
}
