import Foundation

enum LyricModelFamily: String, Sendable {
    case appleFoundation
    case llama70B
    case gptOSS
    case generic

    static func resolve(_ settings: LyricIntelligenceSettings) -> LyricModelFamily {
        switch settings.provider {
        case .onDevice, .applePrivateCloud:
            return .appleFoundation
        case .off:
            return .generic
        case .openAI, .openRouter, .groq, .cerebras:
            return resolve(model: settings.activeModelName)
        }
    }

    static func resolve(model: String) -> LyricModelFamily {
        let value = model.lowercased()
        if value.contains("gpt-oss") || value.contains("oss-120") {
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
        case .generic: 2_400
        }
    }

    var reviewPoolLimit: Int {
        switch self {
        case .appleFoundation: 8
        case .llama70B: 16
        case .gptOSS: 18
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
        switch family {
        case .appleFoundation:
            return """
            Rank these library tracks. JSON only:
            {"ids":["id"]}
            Same mood as taste. No new ids.
            Taste:
            \(taste)
            Tracks:
            \(candidates)
            """
        case .llama70B:
            return """
            You are finishing a radio queue for purpose=\(purpose).
            Rules: keep only listed ids, no inventions, one JSON object.
            {"ids":["listen-next order"]}
            Rank by: (1) same emotional lane as Taste including emotionalArc, (2) matching energy/vocalGender/genre/tempo, (3) seed album/era before random same-artist, (4) demote empty analysis and valence clashes, (5) avoid three songs in a row by one artist, (6) keep a coherent listen rather than shuffling moods.
            Taste:
            \(taste)
            Candidates:
            \(candidates)
            """
        case .gptOSS:
            return """
            Role: radio programmer. Purpose: \(purpose).
            Emit JSON only, no explanation:
            {"ids":["id"]}
            Listed ids only. Prefer Taste continuity, then a slight contrast that keeps the same body of sound. Crush out-of-lane tracks.
            Taste:
            \(taste)
            Candidates:
            \(candidates)
            """
        case .generic:
            return """
            Rank for \(purpose). JSON {"ids":[]} only. Taste then candidates:
            \(taste)
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
        case .generic:
            return """
            {"ids":[],"subtitle":""}
            \(brief.mood) / \(brief.audioFeel)
            \(today)
            \(candidates)
            """
        }
    }
}
