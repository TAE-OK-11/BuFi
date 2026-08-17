import Foundation

/// Recommendation-oriented projection of the stored lyric + sound analysis.
///
/// The LLM is allowed to describe lyrics naturally, but the first-stage radio
/// ranker should compare stable numeric dimensions and a small controlled
/// vocabulary. This adapter keeps old analyses useful while new analyses are
/// gradually taught to emit the same vocabulary directly.
enum LyricRecommendationFeatures {
    enum Mood: String, CaseIterable, Sendable {
        case euphoric
        case bright
        case warm
        case yearning
        case nostalgic
        case melancholic
        case anxious
        case angry
        case defiant
        case sensual
        case calm
        case lonely
    }

    enum Theme: String, CaseIterable, Sendable {
        case romance
        case breakup
        case longing
        case memory
        case identity
        case growth
        case freedom
        case conflict
        case friendship
        case nightlife
        case loss
        case celebration
        case escape
    }

    enum Arc: String, CaseIterable, Sendable {
        case steady
        case rising
        case falling
        case recovery
        case collapse
        case bittersweet
        case oscillating
        case unknown
    }

    struct Vector: Sendable {
        let lyricEnergy: Double
        let valence: Double
        let narrativeTempo: Double
        let intimacy: Double
        let emotionIntensity: Double
        let tension: Double
        let warmth: Double
        let bpm: Double?
        let audioEnergy: Double?
        let brightness: Double?
        let pulse: Double?
        let moods: Set<Mood>
        let themes: Set<Theme>
        let arc: Arc
    }

    static func vector(song: Song, signature: LyricSignature?) -> Vector {
        let details = signature?.details
        let lyricEnergy = unit(signature?.energy ?? details?.energy ?? 0.5)
        let valence = unit(signature?.valence ?? details?.valence ?? 0.5)
        let tempo = unit(details?.tempo ?? 0.5)
        let intimacy = unit(details?.intimacy ?? 0.5)
        let emotion = unit(details?.emotionIntensity ?? 0.5)
        let tension = unit(
            emotion * 0.48
                + lyricEnergy * 0.30
                + (1 - valence) * 0.22
        )
        let warmth = unit(valence * 0.58 + intimacy * 0.42)
        let measuredBPM = SoundFeatureExtractor.bpm(song: song, signature: signature)
        let bpm = measuredBPM > 0 ? Double(measuredBPM) : nil
        let audioEnergy = measured(details?.audioEnergy, enabled: details?.audioMeasured == true)
        let brightness = measured(details?.audioBrightness, enabled: details?.audioMeasured == true)
        let pulse = measured(details?.audioPulse, enabled: details?.audioMeasured == true)
        let text = semanticText(signature)
        return Vector(
            lyricEnergy: lyricEnergy,
            valence: valence,
            narrativeTempo: tempo,
            intimacy: intimacy,
            emotionIntensity: emotion,
            tension: tension,
            warmth: warmth,
            bpm: bpm,
            audioEnergy: audioEnergy,
            brightness: brightness,
            pulse: pulse,
            moods: moodClusters(from: text),
            themes: themeClusters(from: text),
            arc: arc(from: details?.emotionalArc ?? "")
        )
    }

    /// 0...1 pair affinity used before Core ML. Lyrics and measured audio are
    /// deliberately comparable here so a famous/same-artist song cannot win
    /// only because its artist identity is familiar.
    static func similarity(
        seed: Song,
        candidate: Song,
        lyricIndex: LyricSignatureIndex
    ) -> Double {
        let leftSignature = lyricIndex.bySongID[seed.id]
        let rightSignature = lyricIndex.bySongID[candidate.id]
        guard leftSignature != nil || rightSignature != nil else { return 0.5 }
        let left = vector(song: seed, signature: leftSignature)
        let right = vector(song: candidate, signature: rightSignature)

        var weighted = 0.0
        var weight = 0.0
        func include(_ score: Double, _ amount: Double) {
            weighted += unit(score) * amount
            weight += amount
        }

        include(closeness(left.lyricEnergy, right.lyricEnergy), 0.13)
        include(closeness(left.valence, right.valence), 0.11)
        include(closeness(left.narrativeTempo, right.narrativeTempo), 0.07)
        include(closeness(left.intimacy, right.intimacy), 0.07)
        include(closeness(left.emotionIntensity, right.emotionIntensity), 0.08)
        include(closeness(left.tension, right.tension), 0.08)
        include(closeness(left.warmth, right.warmth), 0.05)

        if !left.moods.isEmpty, !right.moods.isEmpty {
            include(jaccard(left.moods, right.moods), 0.12)
        }
        if !left.themes.isEmpty, !right.themes.isEmpty {
            include(jaccard(left.themes, right.themes), 0.07)
        }
        if left.arc != .unknown, right.arc != .unknown {
            include(arcAffinity(left.arc, right.arc), 0.05)
        }
        if let a = left.bpm, let b = right.bpm {
            let normalizedGap = min(1, abs(a - b) / 80)
            include(1 - normalizedGap, 0.07)
        }
        if let a = left.audioEnergy, let b = right.audioEnergy {
            include(closeness(a, b), 0.04)
        }
        if let a = left.brightness, let b = right.brightness {
            include(closeness(a, b), 0.03)
        }
        if let a = left.pulse, let b = right.pulse {
            include(closeness(a, b), 0.03)
        }

        guard weight > 0 else { return 0.5 }
        return unit(weighted / weight)
    }

    static func moodNames(for signature: LyricSignature?) -> [String] {
        let text = semanticText(signature)
        return moodClusters(from: text).map(\.rawValue).sorted()
    }

    static func themeNames(for signature: LyricSignature?) -> [String] {
        let text = semanticText(signature)
        return themeClusters(from: text).map(\.rawValue).sorted()
    }

    private static func semanticText(_ signature: LyricSignature?) -> String {
        guard let signature else { return "" }
        return LyricLexicalEmbedding.normalized(
            (
                signature.moods
                    + signature.details.primaryMoods
                    + signature.details.secondaryMoods
                    + signature.themes
                    + [
                        signature.details.content,
                        signature.details.interpretation,
                        signature.details.emotionalArc,
                        signature.details.relationship,
                        signature.details.narrative,
                        signature.details.social,
                        signature.details.listenContext
                    ]
            ).joined(separator: " ")
        )
    }

    private static func moodClusters(from text: String) -> Set<Mood> {
        var result = Set<Mood>()
        match(text, into: &result, .euphoric, ["euphor", "ecstatic", "thrill", "황홀", "벅차", "환희"])
        match(text, into: &result, .bright, ["happy", "joy", "bright", "cheer", "행복", "기쁨", "신나", "밝"])
        match(text, into: &result, .warm, ["warm", "comfort", "tender", "affection", "따뜻", "포근", "다정"])
        match(text, into: &result, .yearning, ["yearn", "longing", "miss", "crave", "그리움", "그리워", "갈망", "보고싶"])
        match(text, into: &result, .nostalgic, ["nostalg", "memory", "reminisc", "추억", "회상", "그때"])
        match(text, into: &result, .melancholic, ["melanch", "sad", "sorrow", "heartbreak", "슬픔", "우울", "서글", "애잔"])
        match(text, into: &result, .anxious, ["anx", "fear", "worry", "uneasy", "불안", "두려", "초조"])
        match(text, into: &result, .angry, ["angry", "rage", "resent", "furious", "분노", "화남", "원망"])
        match(text, into: &result, .defiant, ["defiant", "rebell", "bold", "empower", "저항", "당당", "반항"])
        match(text, into: &result, .sensual, ["sensual", "seduct", "lust", "desire", "관능", "유혹", "욕망"])
        match(text, into: &result, .calm, ["calm", "peace", "serene", "quiet", "차분", "평온", "고요"])
        match(text, into: &result, .lonely, ["lonely", "alone", "isolat", "외로", "고독", "혼자"])
        return result
    }

    private static func themeClusters(from text: String) -> Set<Theme> {
        var result = Set<Theme>()
        match(text, into: &result, .romance, ["romance", "love", "lover", "crush", "사랑", "연애", "설렘", "고백"])
        match(text, into: &result, .breakup, ["breakup", "break up", "separat", "ex lover", "이별", "헤어", "전애인"])
        match(text, into: &result, .longing, ["longing", "yearn", "miss", "그리움", "갈망", "보고싶"])
        match(text, into: &result, .memory, ["memory", "past", "reminisc", "추억", "과거", "회상"])
        match(text, into: &result, .identity, ["identity", "self", "who i am", "정체성", "나 자신", "자아"])
        match(text, into: &result, .growth, ["growth", "heal", "moving on", "성장", "회복", "극복"])
        match(text, into: &result, .freedom, ["freedom", "free", "independ", "자유", "해방", "독립"])
        match(text, into: &result, .conflict, ["conflict", "fight", "argument", "betray", "갈등", "싸움", "배신"])
        match(text, into: &result, .friendship, ["friend", "friendship", "친구", "우정"])
        match(text, into: &result, .nightlife, ["party", "club", "dancefloor", "nightlife", "파티", "클럽", "밤거리"])
        match(text, into: &result, .loss, ["loss", "grief", "death", "mourning", "상실", "죽음", "애도"])
        match(text, into: &result, .celebration, ["celebrat", "victory", "festival", "축하", "승리", "축제"])
        match(text, into: &result, .escape, ["escape", "run away", "leave", "도망", "탈출", "떠나"])
        return result
    }

    private static func arc(from raw: String) -> Arc {
        let text = LyricLexicalEmbedding.normalized(raw)
        guard !text.isEmpty else { return .unknown }
        if containsAny(text, ["bittersweet", "mixed ending", "씁쓸", "애틋", " bittersweet"]) {
            return .bittersweet
        }
        if containsAny(text, ["oscillat", "back and forth", "swing", "요동", "오락가락", "반복"]) {
            return .oscillating
        }
        if containsAny(text, ["recover", "heal", "resolve", "accept", "회복", "극복", "받아들", "안정"]) {
            return .recovery
        }
        if containsAny(text, ["collapse", "break down", "despair", "무너", "절망", "파국"]) {
            return .collapse
        }
        if containsAny(text, ["rise", "build", "hope", "empower", "고조", "상승", "희망", "당당"]) {
            return .rising
        }
        if containsAny(text, ["fall", "decline", "darken", "악화", "하강", "가라앉", "어두워"]) {
            return .falling
        }
        return .steady
    }

    private static func arcAffinity(_ left: Arc, _ right: Arc) -> Double {
        if left == right { return 1 }
        let compatible: Set<Set<Arc>> = [
            [.rising, .recovery],
            [.falling, .collapse],
            [.bittersweet, .oscillating],
            [.steady, .bittersweet]
        ]
        return compatible.contains([left, right]) ? 0.72 : 0.35
    }

    private static func match<T: Hashable>(
        _ text: String,
        into result: inout Set<T>,
        _ value: T,
        _ tokens: [String]
    ) {
        if containsAny(text, tokens) { result.insert(value) }
    }

    private static func containsAny(_ text: String, _ tokens: [String]) -> Bool {
        tokens.contains { text.contains(LyricLexicalEmbedding.normalized($0)) }
    }

    private static func measured(_ value: Double?, enabled: Bool) -> Double? {
        guard enabled, let value, value.isFinite, value > 0 else { return nil }
        return unit(value)
    }

    private static func closeness(_ left: Double, _ right: Double) -> Double {
        1 - min(1, abs(left - right))
    }

    private static func jaccard<T: Hashable>(_ left: Set<T>, _ right: Set<T>) -> Double {
        let union = left.union(right)
        guard !union.isEmpty else { return 0 }
        return Double(left.intersection(right).count) / Double(union.count)
    }

    private static func unit(_ value: Double) -> Double {
        guard value.isFinite else { return 0.5 }
        return min(1, max(0, value))
    }
}
