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
            {"moods":["yearning"],"themes":["longing"],"energy":0.45,"valence":0.28,"emotion":0.78,"tempo":0.35,"intimacy":0.82,"summary":"창가에서 그 이름을 기다리며 그리움을 견딘다.","emotionalArc":"steady","relationship":"romantic","season":"autumn","dayparts":["night"],"style":"","content":"그리움","setting":"","narrative":"longing","weather":"rain","social":"alone","color":"blue","vocal":"","vocalGender":"","genre":"","language":"ko","context":"late night"}
            Numbers are 0.0...1.0: energy=lyrical force, valence=positivity, emotion=strength, tempo=story movement, intimacy=emotional closeness.
            Prefer mood words from: euphoric, bright, warm, yearning, nostalgic, melancholic, anxious, angry, defiant, sensual, calm, lonely.
            Prefer themes from: romance, breakup, longing, memory, identity, growth, freedom, conflict, friendship, nightlife, loss, celebration, escape.
            emotionalArc is one of steady,rising,falling,recovery,collapse,bittersweet,oscillating. narrative is confession,memory,argument,celebration,escape,reflection,fantasy,longing,story,none.
            Use only lyric evidence. Do not invent audio facts: vocal, vocalGender and genre stay empty unless explicit in the text.
            Lyrics:
            \(body)
            """
        case .llama70B:
            return """
            You catalogue lyrics for a personal recommender. Return exactly one JSON object, no markdown.
            {"primaryMoods":[],"secondaryMoods":[],"themes":[],"energy":0.0,"valence":0.0,"emotion":0.0,"summary":"","interpretation":"","emotionalArc":"steady","relationship":"none","season":"spring|summer|autumn|winter|any","dayparts":[],"style":"","content":"","setting":"","tempo":0.0,"intimacy":0.0,"narrative":"reflection","weather":"","social":"alone|pair|group|crowd|public|unknown","color":"","vocal":"","vocalGender":"","genre":"","language":"ko|en|ja|other","context":""}
            Score every numeric field 0.0...1.0: energy=lyrical force, valence=emotional positivity, emotion=emotional intensity, tempo=narrative movement, intimacy=emotional closeness.
            Use 1-3 primary and 0-2 secondary moods. Prefer this controlled vocabulary when it fits: euphoric, bright, warm, yearning, nostalgic, melancholic, anxious, angry, defiant, sensual, calm, lonely.
            Prefer themes from: romance, breakup, longing, memory, identity, growth, freedom, conflict, friendship, nightlife, loss, celebration, escape. Do not use a mood word as a theme.
            emotionalArc must be one of steady,rising,falling,recovery,collapse,bittersweet,oscillating. relationship should be romantic,breakup,crush,friendship,family,self,rivalry,none when supported. narrative should be confession,memory,argument,celebration,escape,reflection,fantasy,longing,story,none.
            summary retells who feels or does what and how it changes or ends, in the lyric language. interpretation is the higher-level meaning.
            Never write language commentary. Do not guess singer gender, production, or genre from lyrics; leave audio-only fields empty unless the text itself proves them.
            Lyrics:
            \(body)
            """
        case .gptOSS:
            return """
            Role: senior lyric analyst for a music recommender. Read the excerpt as one narrative, then return exactly one JSON object and nothing else.
            {"primaryMoods":[],"secondaryMoods":[],"themes":[],"energy":0.0,"valence":0.0,"emotion":0.0,"summary":"","explicitContent":"","interpretation":"","emotionalArc":"steady","relationship":"none","season":"","dayparts":[],"content":"","setting":"","narrative":"reflection","social":"unknown","language":"","context":"","style":"","tempo":0.0,"intimacy":0.0,"weather":"","color":"","vocal":"","vocalGender":"","genre":""}
            Recommendation feature contract:
            - energy, valence, emotion, tempo, intimacy are always numbers 0.0...1.0. energy=force of the words; valence=positivity; emotion=intensity; tempo=how quickly the narrative moves; intimacy=how emotionally close/exposed the narrator is.
            - primaryMoods (1-3) and secondaryMoods (0-2): prefer euphoric, bright, warm, yearning, nostalgic, melancholic, anxious, angry, defiant, sensual, calm, lonely. Rank by importance.
            - themes: prefer romance, breakup, longing, memory, identity, growth, freedom, conflict, friendship, nightlife, loss, celebration, escape. Themes are ideas/conflicts, not mood synonyms.
            - emotionalArc is exactly one of steady,rising,falling,recovery,collapse,bittersweet,oscillating. relationship prefers romantic,breakup,crush,friendship,family,self,rivalry,none. narrative prefers confession,memory,argument,celebration,escape,reflection,fantasy,longing,story,none. social prefers alone,pair,group,crowd,public,unknown.
            explicitContent contains only events, situations or desires directly stated or strongly evidenced by the lyrics. interpretation is the higher-level meaning inferred from that evidence.
            summary: 2-4 concise sentences that paraphrase the speaker, desire/conflict, important turn and ending. Do not quote or reproduce lyric lines. Do not call the narrator the artist. Distinguish fantasies, threats, irony, metaphor and hyperbole from literal actions when the text does.
            Never invent biography, production, instrumentation, genre, singer identity or vocal gender. Leave audio-only fields vocal/vocalGender/genre empty unless explicitly stated in the words. Leave season/daypart/weather/setting empty when unsupported.
            Lyrics:
            \(body)
            """
        case .gemini:
            return """
            You extract grounded lyric meaning as structured features for a music recommender. Treat the text as one narrator's story. Use Korean or the lyric language for summary and interpretation.

            Return exactly one JSON object. Start with { . No markdown fences, no preface, no trailing commentary.

            {"primaryMoods":[],"secondaryMoods":[],"themes":[],"energy":0.0,"valence":0.0,"emotion":0.0,"summary":"","explicitContent":"","interpretation":"","emotionalArc":"steady","relationship":"none","season":"","dayparts":[],"content":"","setting":"","narrative":"reflection","social":"unknown","language":"","context":"","style":"","tempo":0.0,"intimacy":0.0,"weather":"","color":"","vocal":"","vocalGender":"","genre":""}

            Recommendation feature contract:
            - Always score energy, valence, emotion, tempo, intimacy from 0.0 to 1.0. energy=force of the words; valence=positivity; emotion=intensity; tempo=narrative movement; intimacy=emotional closeness/exposure. Do not infer recording energy from lyrics.
            - primaryMoods: 1-3 ranked labels. secondaryMoods: 0-2. Prefer: euphoric, bright, warm, yearning, nostalgic, melancholic, anxious, angry, defiant, sensual, calm, lonely.
            - themes prefer: romance, breakup, longing, memory, identity, growth, freedom, conflict, friendship, nightlife, loss, celebration, escape. Do not duplicate mood labels as themes.
            - emotionalArc must be one of: steady, rising, falling, recovery, collapse, bittersweet, oscillating.
            - relationship prefers: romantic, breakup, crush, friendship, family, self, rivalry, none. narrative prefers: confession, memory, argument, celebration, escape, reflection, fantasy, longing, story, none. social prefers: alone, pair, group, crowd, public, unknown.
            - summary: 2-4 sentences in the lyric language. Paraphrase narrator, desire/conflict, turn, ending. Do not quote lyric lines.
            - Distinguish metaphor, fantasy, threat, irony, and hyperbole from literal events.
            - vocal, vocalGender, genre stay empty unless the words themselves state them. Leave unsupported season/weather/setting fields empty.

            Lyrics:
            \(body)
            """
        case .generic:
            return """
            Analyze these lyrics as recommendation features. JSON only:
            {"moods":[],"themes":[],"energy":0.0,"valence":0.0,"emotion":0.0,"tempo":0.0,"intimacy":0.0,"summary":"","season":"any","dayparts":[],"style":"","content":"","setting":"","weather":"","language":"","context":"","emotionalArc":"steady"}
            Use 0.0...1.0 numeric scales. Prefer moods from euphoric,bright,warm,yearning,nostalgic,melancholic,anxious,angry,defiant,sensual,calm,lonely and themes from romance,breakup,longing,memory,identity,growth,freedom,conflict,friendship,nightlife,loss,celebration,escape.
            emotionalArc is one of steady,rising,falling,recovery,collapse,bittersweet,oscillating. Use only evidence in the lyrics. summary retells the lyric story. Never describe the task or language.
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
            {"moods":["yearning"],"themes":["longing"],"energy":0.45,"valence":0.28,"emotion":0.78,"tempo":0.35,"intimacy":0.82,"summary":"창가에서 기다린다.\\n비가 이름을 적신다.","emotionalArc":"steady","season":"autumn","dayparts":["night"],"content":"그리움","setting":"city","weather":"rain","language":"ko","context":"late night"}
            Numbers are 0.0...1.0. Prefer the controlled mood/theme vocabulary from the full analysis prompt. Use only evidence in the words. summary is story only.
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
            Sequence "\(title)" using only the listed library ids. \(context)
            Target lane: mood=\(brief.mood); theme=\(brief.theme); audio=\(brief.audioFeel).

            Priority:
            1. Continue today's listening direction for this hour/season without copying it.
            2. Judge song-level fit first: mood/theme/feel/BPM/energy/valence > artist identity, fame, or favorite status.
            3. Make tracks 1-3 immediately convincing. Keep neighboring transitions smooth; allow at most one deliberate energy/valence jump, then resolve it.
            4. Never place the same artist back-to-back. Avoid near-duplicate, live, acoustic, or alternate siblings. Do not let one artist dominate.
            5. Pick the strongest 8-12 ids when enough fit. Omit a clearly wrong candidate instead of forcing the quota. Never invent ids.

            Return JSON only, immediately:
            {"ids":["ordered id"],"subtitle":"short natural line in the user's language"}

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
            RECENT PLAYBACK CONTEXT — up to 10 tracks from the active listening session. Read this first; it is the path the listener actually took, not a bag of preferences:
            \(recent)

            CURRENT SEED / NOW PLAYING:
            \(seed)

            \(session)

            \(RadioFeelGrammar.geminiRadioBrief)

            Evidence policy:
            - Combine ALL supplied evidence: measured numeric audio values, structured lyric numbers, moods/themes/arcs, exact lyric memory, listening history, catalog metadata, and your pretrained knowledge of the title/artist/scene.
            - The supplied measurements describe this local recording and win when your memory disagrees. Your own knowledge is valuable for musical context, production character, era, influence, cultural adjacency, collaborations and why a bridge makes sense — but it must not overwrite measured facts.
            - Reason across the sequence, not one candidate at a time. Use the previous 10 tracks to infer momentum and use the current seed as the immediate handoff anchor.

            Keep up to \(keep) listed ids from the 50-candidate pack. Prefer a coherent living order over filling with weak tracks.
            Preferred artists are a slight lean only.

            Return one JSON object immediately:
            {"ids":[],"need":{"count":0}}

            CANDIDATES:
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
        let recommendation = LyricRecommendationFeatures.vector(
            song: song,
            signature: signature
        )
        let moods = (details?.primaryMoods.isEmpty == false
            ? details?.primaryMoods
            : signature?.moods)?.prefix(3).joined(separator: ",") ?? ""
        let themes = (signature?.themes.isEmpty == false
            ? signature?.themes
            : details?.themes)?.prefix(3).joined(separator: ",") ?? ""
        let canonicalMoods = recommendation.moods
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
        let canonicalThemes = recommendation.themes
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
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
            "album:\(song.album) bpm:\(bpm) e:\(energy) v:\(valence) vox:\(vocal) g:\(genre)",
            String(
                format: "lyric le:%.2f nv:%.2f int:%.2f emo:%.2f tension:%.2f warmth:%.2f",
                recommendation.lyricEnergy,
                recommendation.narrativeTempo,
                recommendation.intimacy,
                recommendation.emotionIntensity,
                recommendation.tension,
                recommendation.warmth
            )
        ]
        let feel = RadioFeelGrammar.feel(song: song, signature: signature).rawValue
        parts.append("feel:\(feel) canonicalArc:\(recommendation.arc.rawValue)")
        if !moods.isEmpty { parts.append("moods:\(moods)") }
        if !canonicalMoods.isEmpty { parts.append("canonicalMoods:\(canonicalMoods)") }
        if !themes.isEmpty { parts.append("themes:\(themes)") }
        if !canonicalThemes.isEmpty { parts.append("canonicalThemes:\(canonicalThemes)") }
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
