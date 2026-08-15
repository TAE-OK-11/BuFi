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
        let middleStart = max(
            headCount,
            min(
                characters.count - tailCount - middleCount,
                characters.count / 2 - middleCount / 2
            )
        )
        let tailStart = characters.count - tailCount

        var sampled: [Character] = []
        sampled.reserveCapacity(limit)
        sampled.append(contentsOf: characters.prefix(headCount))
        sampled.append(contentsOf: divider)
        sampled.append(contentsOf: characters[middleStart..<(middleStart + middleCount)])
        sampled.append(contentsOf: divider)
        sampled.append(contentsOf: characters[tailStart..<characters.count])
        return String(sampled.prefix(limit))
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
            {"moods":[],"themes":[],"energy":0.0,"valence":0.0,"summary":"","season":"spring|summer|autumn|winter|any","dayparts":[],"style":"","content":"","setting":"","tempo":0.0,"intimacy":0.0,"narrative":"","weather":"","social":"","color":"","vocal":"","vocalGender":"","genre":"","language":"ko|en|ja|other","emotion":0.0,"context":""}
            Ground every field in the lyrics. energy is lyrical intensity, tempo is narrative pace, valence is emotional positivity. summary retells who feels or does what and how it changes or ends, in the lyric language.
            Never write language commentary. Do not guess singer gender, production, or genre from lyrics; leave audio-only fields empty unless the text itself proves them.
            Lyrics:
            \(body)
            """
        case .gptOSS:
            return """
            Role: senior lyric editor for a recommender. Understand the whole excerpt, then output one JSON object only.
            {"moods":[],"themes":[],"energy":0.0,"valence":0.0,"summary":"","season":"","dayparts":[],"style":"","content":"","setting":"","tempo":0.0,"intimacy":0.0,"narrative":"","weather":"","social":"","color":"","vocal":"","vocalGender":"","genre":"","language":"","emotion":0.0,"context":""}
            Prefer evidence over guesses. summary is the actual lyric narrative, including its emotional turn or ending. energy and tempo describe the words, not the recording. Never infer singer gender or musical genre only from lyric text.
            Lyrics:
            \(body)
            """
        case .generic:
            return """
            Analyze these lyrics for recommendations. JSON only:
            {"moods":[],"themes":[],"energy":0.0,"valence":0.0,"summary":"","season":"any","dayparts":[],"style":"","content":"","setting":"","weather":"","language":"","emotion":0.0,"context":""}
            Use only evidence in the lyrics. summary retells the lyric story. Never describe the task or language.
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
            Rank by: (1) same emotional lane as Taste, (2) matching energy/vocalGender/genre, (3) seed album/era before random same-artist, (4) demote empty analysis and valence clashes, (5) avoid three songs in a row by one artist.
            Taste:
            \(taste)
            Candidates:
            \(candidates)
            """
        case .gptOSS:
            return """
            Role: radio programmer. Purpose: \(purpose).
            Think about lane (mood, vocal, genre, energy) then emit JSON only:
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
