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
        case .appleFoundation: 1_800
        case .llama70B: 4_000
        case .gptOSS: 6_000
        case .generic: 2_800
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
        let body = String(lyrics.prefix(family.lyricCharacterLimit))
        switch family {
        case .appleFoundation:
            return """
            Extract tags for a music app. JSON only. Short values.
            {"moods":["calm"],"themes":["night"],"energy":0.3,"valence":0.2,"summary":"창가에서 그 이름을 부른다.\\n빗소리가 방을 채운다.","season":"autumn","dayparts":["night"],"style":"ballad","content":"그리움","vocal":"soft","vocalGender":"female","genre":"ballad"}
            summary = what happens in the lyrics, never language or "two sentences".
            Lyrics:
            \(body)
            """
        case .llama70B:
            return """
            You are a cataloguer for a personal music library. Return one JSON object, no markdown.
            Schema:
            {"moods":["<=5"],"themes":["<=5"],"energy":0-1,"valence":0-1,"summary":"full lyric retelling","season":"spring|summer|autumn|winter|any","dayparts":["morning|afternoon|evening|night"],"style":"","content":"","setting":"","tempo":0-1,"intimacy":0-1,"narrative":"","weather":"","social":"","color":"","vocal":"soft|powerful|rap|choir","vocalGender":"female|male|mixed|instrumental","genre":"","language":"ko|en|ja|other","emotion":0-1,"context":""}
            summary retells the lyric story in the singer's language. Do not mention language, genre, or the word sentence.
            vocalGender is who is singing. genre is the musical lane, not the language.
            Lyrics:
            \(body)
            """
        case .gptOSS:
            return """
            Role: senior music editor writing library cards.
            Decide the song's inner story, then emit JSON only — no analysis text, no markdown.
            {"moods":[],"themes":[],"energy":0,"valence":0,"summary":"","season":"","dayparts":[],"style":"","content":"","setting":"","tempo":0,"intimacy":0,"narrative":"","weather":"","social":"","color":"","vocal":"","vocalGender":"female|male|mixed|instrumental","genre":"","language":"","emotion":0,"context":""}
            summary is the lyric narrative itself, as long as needed. Never write "two sentences in korean" or name the language.
            Lyrics:
            \(body)
            """
        case .generic:
            return """
            Score these lyrics for a recommender. JSON only:
            {"moods":[],"themes":[],"energy":0.0,"valence":0.0,"summary":"","season":"any","dayparts":[],"style":"","content":"","vocal":"soft","vocalGender":"","genre":""}
            summary retells the lyric story. Never mention language.
            Lyrics:
            \(body)
            """
        }
    }

    static func tagging(lyrics: String, family: LyricModelFamily) -> String {
        let body = String(lyrics.prefix(family.lyricCharacterLimit))
        switch family {
        case .appleFoundation:
            return """
            Tags only. JSON:
            {"moods":["calm"],"themes":["night"],"summary":"창가에서 기다린다.\\n비가 이름을 적신다.","vocalGender":"female","genre":"ballad"}
            Lyrics:
            \(body)
            """
        default:
            return lyricAnalysis(lyrics: lyrics, family: family)
        }
    }

    static func summaryOnly(lyrics: String, family: LyricModelFamily) -> String {
        let body = String(lyrics.prefix(family.lyricCharacterLimit))
        switch family {
        case .appleFoundation:
            return """
            Retell the lyric story. JSON only:
            {"summary":"창가에서 그 이름을 부른다.\\n빗소리가 방을 채운다."}
            Do not write language names.
            Lyrics:
            \(body)
            """
        case .llama70B:
            return """
            Write a complete lyric synopsis in the singer's language. JSON only:
            {"summary":"..."}
            Cover who speaks, what they want, and how it ends. No length cap. Never mention language.
            Lyrics:
            \(body)
            """
        case .gptOSS:
            return """
            Music editor task. After you understand the lyrics, output JSON only:
            {"summary":"full story of the lyrics"}
            Unlimited length. Story only — never "two sentences" or a language label.
            Lyrics:
            \(body)
            """
        case .generic:
            return """
            {"summary":"lyric story"}
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
