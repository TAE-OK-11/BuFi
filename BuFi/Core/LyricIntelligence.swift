import Foundation

enum LyricIntelligenceProviderKind: String, CaseIterable, Identifiable, Sendable {
    case off
    case onDevice
    case applePrivateCloud
    case openAI
    case openRouter
    case groq
    case cerebras

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: String(localized: "끄기")
        case .onDevice: String(localized: "자동 (Apple 3B → Gemma 3)")
        case .applePrivateCloud: String(localized: "Apple Privacy Cloud")
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter"
        case .groq: "Groq"
        case .cerebras: "Cerebras"
        }
    }

    var isVisibleInSettings: Bool {
        // Privacy Cloud stays in the enum for a later entitlement, but it is
        // not offered or invoked until that capability is available.
        self != .applePrivateCloud
    }

    static var visibleCases: [LyricIntelligenceProviderKind] {
        allCases.filter(\.isVisibleInSettings)
    }
}

struct LyricSignature: Codable, Equatable, Sendable {
    var songID: String
    var lyricsHash: String
    var moods: [String]
    var themes: [String]
    var energy: Double
    var valence: Double
    var embedding: [Float]
    var source: String
    var sentenceEmbedding: [Float]
    var soundLabels: [String]
    var soundEmbedding: [Float]
    var audioRevision: String
    var soundSource: String
    var summary: String
    var details: LyricDetailProfile

    init(
        songID: String,
        lyricsHash: String,
        moods: [String],
        themes: [String],
        energy: Double,
        valence: Double,
        embedding: [Float],
        source: String,
        sentenceEmbedding: [Float] = [],
        soundLabels: [String] = [],
        soundEmbedding: [Float] = [],
        audioRevision: String = "",
        soundSource: String = "",
        summary: String = "",
        details: LyricDetailProfile = .empty
    ) {
        self.songID = songID
        self.lyricsHash = lyricsHash
        self.moods = moods
        self.themes = themes
        self.energy = energy
        self.valence = valence
        self.embedding = embedding
        self.source = source
        self.sentenceEmbedding = sentenceEmbedding
        self.soundLabels = soundLabels
        self.soundEmbedding = soundEmbedding
        self.audioRevision = audioRevision
        self.soundSource = soundSource
        self.summary = summary
        self.details = details.withBasics(
            moods: moods,
            themes: themes,
            energy: energy,
            valence: valence,
            summary: summary
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        songID = try container.decode(String.self, forKey: .songID)
        lyricsHash = try container.decode(String.self, forKey: .lyricsHash)
        moods = try container.decode([String].self, forKey: .moods)
        themes = try container.decode([String].self, forKey: .themes)
        energy = try container.decode(Double.self, forKey: .energy)
        valence = try container.decode(Double.self, forKey: .valence)
        embedding = try container.decode([Float].self, forKey: .embedding)
        source = try container.decode(String.self, forKey: .source)
        sentenceEmbedding = try container.decodeIfPresent(
            [Float].self,
            forKey: .sentenceEmbedding
        ) ?? []
        soundLabels = try container.decodeIfPresent(
            [String].self,
            forKey: .soundLabels
        ) ?? []
        soundEmbedding = try container.decodeIfPresent(
            [Float].self,
            forKey: .soundEmbedding
        ) ?? []
        audioRevision = try container.decodeIfPresent(
            String.self,
            forKey: .audioRevision
        ) ?? ""
        soundSource = try container.decodeIfPresent(
            String.self,
            forKey: .soundSource
        ) ?? ""
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        details = try container.decodeIfPresent(
            LyricDetailProfile.self,
            forKey: .details
        ) ?? LyricDetailProfile(
            moods: moods,
            themes: themes,
            energy: energy,
            valence: valence,
            summary: summary
        )
    }

    var moodKeys: [String] {
        uniqueNormalized(
            moods + details.primaryMoods + details.secondaryMoods
        )
    }

    var hasStoredLyricAnalysis: Bool {
        // Lexical/heuristic output is not a completed lyric analysis. Only an
        // actual language-model result with a usable story may satisfy the
        // cache and coverage layer.
        !lyricsHash.isEmpty
            && !source.isEmpty
            && source != "lexical"
            && hasStoredSummary
    }

    var hasStoredSoundAnalysis: Bool {
        !soundLabels.isEmpty || soundEmbedding.contains { $0 != 0 }
    }

    var hasSentenceEmbedding: Bool {
        sentenceEmbedding.count >= 8
    }

    var hasStoredSummary: Bool {
        LyricIntelligencePrompt.isContentSummary(summary)
    }

    var themeKeys: [String] {
        uniqueNormalized(
            themes + [details.content, details.relationship, details.narrative]
                .filter { !$0.isEmpty }
        )
    }

    private func uniqueNormalized(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let key = LyricLexicalEmbedding.normalized(value)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            result.append(key)
        }
        return result
    }

    var sourceTitle: String {
        let manualPrefix = "manual:"
        if source.hasPrefix(manualPrefix) {
            let original = String(source.dropFirst(manualPrefix.count))
            let originalTitle = Self.displaySourceTitle(original)
            return originalTitle.isEmpty
                ? String(localized: "사용자 수정")
                : String(localized: "사용자 수정") + " · " + originalTitle
        }
        return Self.displaySourceTitle(source)
    }

    private static func displaySourceTitle(_ raw: String) -> String {
        switch raw {
        case "apple-intelligence-tagging+default":
            String(localized: "Apple Intelligence (태깅+기본)")
        case "apple-intelligence-tagging":
            String(localized: "Apple Intelligence (태깅)")
        case "apple-intelligence":
            String(localized: "Apple Intelligence")
        case "apple-privacy-cloud":
            String(localized: "Apple Privacy Cloud")
        case "apple-intelligence-3b":
            String(localized: "Apple Intelligence 3B (로컬)")
        case "gemma-3-270m":
            "Gemma 3 270M"
        case "openai":
            "OpenAI"
        case "openrouter":
            "OpenRouter"
        case "groq":
            "Groq"
        case "cerebras":
            "Cerebras"
        case "manual":
            String(localized: "사용자 수정")
        case "lexical":
            String(localized: "이전 로컬 결과 (LLM 재분석 필요)")
        default:
            raw
        }
    }
}

enum LyricAnalysisCachePolicy {
    static func shouldReuseLyric(existing: LyricSignature?, lyricsHash: String) -> Bool {
        guard let existing else { return false }
        return existing.lyricsHash == lyricsHash && existing.hasStoredLyricAnalysis
    }

    static func shouldReuseSound(existing: LyricSignature?, audioRevision: String) -> Bool {
        guard let existing, !audioRevision.isEmpty else { return false }
        return existing.audioRevision == audioRevision && existing.hasStoredSoundAnalysis
    }
}

struct LyricIntelligenceProbe: Equatable, Sendable {
    var reusedCache: Bool
    var signature: LyricSignature?
    var provider: LyricIntelligenceProviderKind
    var appleOnDevice: AppleOnDeviceModelStatus
    var privateCloud: ApplePrivateCloudStatus
}

struct LyricSignatureIndex: Sendable {
    let bySongID: [String: LyricSignature]
    private let unifiedBySongID: [String: [Float]]

    static let empty = LyricSignatureIndex()

    init(bySongID: [String: LyricSignature] = [:]) {
        self.bySongID = bySongID
        var vectors: [String: [Float]] = [:]
        vectors.reserveCapacity(bySongID.count)
        for (id, signature) in bySongID {
            vectors[id] = LyricLexicalEmbedding.unified(signature)
        }
        self.unifiedBySongID = vectors
    }

    func similarity(between leftID: String, and rightID: String) -> Double {
        guard let left = bySongID[leftID], let right = bySongID[rightID] else {
            return 0
        }
        return LyricLexicalEmbedding.similarity(
            left,
            right,
            leftUnified: unifiedBySongID[leftID],
            rightUnified: unifiedBySongID[rightID]
        )
    }

    func affinity(
        candidateID: String,
        recentIDs: [String],
        favoriteIDs: [String],
        seedID: String? = nil
    ) -> Double {
        guard bySongID[candidateID] != nil else { return 0 }
        let seedScore: Double
        if let seedID, seedID != candidateID, bySongID[seedID] != nil {
            seedScore = similarity(between: candidateID, and: seedID)
        } else {
            seedScore = 0
        }
        let anchors = recentIDs.prefix(8) + favoriteIDs.prefix(12)
        var best = 0.0
        var samples = 0
        var total = 0.0
        for id in anchors {
            guard id != candidateID, bySongID[id] != nil else { continue }
            let score = similarity(between: candidateID, and: id)
            best = max(best, score)
            total += score
            samples += 1
        }
        let rest: Double
        if samples > 0 {
            rest = min(1, best * 0.72 + (total / Double(samples)) * 0.28)
        } else {
            rest = 0
        }
        if seedScore > 0 {
            return min(1, seedScore * 0.78 + rest * 0.22)
        }
        return rest
    }
}

enum LyricLexicalEmbedding {
    static let dimensions = 64

    static func hash(_ text: String) -> String {
        var value: UInt64 = 1_469_598_103_934_665_637
        for byte in text.utf8 {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }
        return String(value, radix: 16)
    }

    static func vector(from text: String) -> [Float] {
        var buckets = [Float](repeating: 0, count: dimensions)
        let tokens = normalized(text)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count > 1 }
        guard !tokens.isEmpty else { return buckets }
        for token in tokens {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in token.utf8 {
                hash ^= UInt64(byte)
                hash &*= 0x100_0000_01b3
            }
            let index = Int(hash % UInt64(dimensions))
            let sign: Float = hash & 1 == 0 ? 1 : -1
            buckets[index] += sign
        }
        return l2Normalized(buckets)
    }

    static func merge(moods: [String], energy: Double, valence: Double, lyrics: String) -> [Float] {
        var merged = Self.vector(from: lyrics)
        guard merged.count == dimensions else { return merged }
        let moodVector = Self.vector(from: moods.joined(separator: " "))
        for index in merged.indices {
            merged[index] = merged[index] * 0.72 + moodVector[index] * 0.20
        }
        if dimensions > 2 {
            merged[0] += Float(min(max(energy, 0), 1) - 0.5)
            merged[1] += Float(min(max(valence, 0), 1) - 0.5)
        }
        let extras = LyricLexicalFeatures.extraTokens(from: lyrics)
        if !extras.isEmpty {
            let extraVector = Self.vector(from: extras.joined(separator: " "))
            for index in merged.indices {
                merged[index] = merged[index] * 0.90 + extraVector[index] * 0.10
            }
        }
        return l2Normalized(merged)
    }

    static func projected(_ values: [Float], to dimensions: Int) -> [Float] {
        guard dimensions > 0 else { return [] }
        guard !values.isEmpty else { return [Float](repeating: 0, count: dimensions) }
        if values.count == dimensions { return values }
        var buckets = [Float](repeating: 0, count: dimensions)
        for (offset, value) in values.enumerated() {
            buckets[offset % dimensions] += value
        }
        return l2Normalized(buckets)
    }

    static func unified(_ signature: LyricSignature) -> [Float] {
        var merged = signature.embedding
        if merged.count != dimensions {
            merged = projected(merged, to: dimensions)
        }
        if signature.hasSentenceEmbedding {
            let sentence = projected(signature.sentenceEmbedding, to: dimensions)
            for index in merged.indices {
                merged[index] = merged[index] * 0.58 + sentence[index] * 0.42
            }
        }
        if signature.hasStoredSoundAnalysis {
            let stored = projected(signature.soundEmbedding, to: dimensions)
            let live = SoundLabelSpace.embedding(fromLabels: signature.soundLabels)
            for index in merged.indices {
                let sound = stored[index] * 0.35 + live[index] * 0.65
                merged[index] = merged[index] * 0.82 + sound * 0.18
            }
        }
        if signature.hasStoredSummary || signature.details.hasExtendedFields {
            let summary = vector(
                from: signature.summary + " " + signature.details.tagBlob
            )
            for index in merged.indices {
                merged[index] = merged[index] * 0.86 + summary[index] * 0.14
            }
        }
        let voiceAndGenre = [
            signature.details.vocalGender,
            signature.details.genre,
            signature.details.vocal,
            signature.details.style,
            SoundLabelSpace.canonicalize(signature.soundLabels)
                .joined(separator: " ")
        ].joined(separator: " ")
        if !voiceAndGenre.trimmingCharacters(in: .whitespaces).isEmpty {
            let extra = vector(from: voiceAndGenre)
            for index in merged.indices {
                merged[index] = merged[index] * 0.82 + extra[index] * 0.18
            }
        }
        return l2Normalized(merged)
    }

    static func similarity(
        _ left: LyricSignature,
        _ right: LyricSignature,
        leftUnified: [Float]? = nil,
        rightUnified: [Float]? = nil
    ) -> Double {
        let fused = cosine(
            leftUnified ?? unified(left),
            rightUnified ?? unified(right)
        )
        let mood = jaccard(left.moodKeys, right.moodKeys)
        let theme = jaccard(left.themeKeys, right.themeKeys)
        let energy = closeness(left.energy, right.energy)
        let valence = closeness(left.valence, right.valence)
        let tempo = closeness(left.details.tempo, right.details.tempo)
        let intimacy = closeness(left.details.intimacy, right.details.intimacy)
        let vocal = exactMatch(left.details.vocalGender, right.details.vocalGender)
        let genre = looseMatch(
            left.details.genre.isEmpty ? left.details.style : left.details.genre,
            right.details.genre.isEmpty ? right.details.style : right.details.genre
        )
        let context = contextMatch(left.details, right.details)
        let sound = SoundLabelSpace.overlap(left.soundLabels, right.soundLabels)
        return min(
            1,
            fused * 0.44
                + mood * 0.13
                + theme * 0.09
                + energy * 0.06
                + valence * 0.06
                + tempo * 0.04
                + intimacy * 0.03
                + vocal * 0.04
                + genre * 0.04
                + context * 0.03
                + sound * 0.04
        )
    }

    private static func closeness(_ left: Double, _ right: Double) -> Double {
        1 - min(1, abs(left - right))
    }

    private static func exactMatch(_ left: String, _ right: String) -> Double {
        let a = normalized(left)
        let b = normalized(right)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return a == b ? 1 : 0
    }

    private static func looseMatch(_ left: String, _ right: String) -> Double {
        let a = normalized(left)
        let b = normalized(right)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        if a == b { return 1 }
        let shorter = a.count <= b.count ? a : b
        let longer = a.count <= b.count ? b : a
        guard shorter.count >= 4, longer.contains(shorter) else { return 0 }
        return 1
    }

    private static func contextMatch(
        _ left: LyricDetailProfile,
        _ right: LyricDetailProfile
    ) -> Double {
        var score = 0.0
        var parts = 0
        if !left.season.isEmpty, !right.season.isEmpty {
            parts += 1
            if left.season == "any" || right.season == "any" || left.season == right.season {
                score += 1
            }
        }
        if !left.dayparts.isEmpty, !right.dayparts.isEmpty {
            parts += 1
            score += jaccard(left.dayparts, right.dayparts)
        }
        guard parts > 0 else { return 0 }
        return score / Double(parts)
    }

    static func cosine(_ left: [Float], _ right: [Float]) -> Double {
        let count = min(left.count, right.count)
        guard count > 0 else { return 0 }
        var dot: Float = 0
        var leftNorm: Float = 0
        var rightNorm: Float = 0
        for index in 0..<count {
            dot += left[index] * right[index]
            leftNorm += left[index] * left[index]
            rightNorm += right[index] * right[index]
        }
        let denominator = (leftNorm.squareRoot() * rightNorm.squareRoot())
        guard denominator > 0 else { return 0 }
        return Double(max(-1, min(1, dot / denominator)))
    }

    static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func jaccard(_ left: [String], _ right: [String]) -> Double {
        let a = Set(left)
        let b = Set(right)
        guard !a.isEmpty || !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    static func l2Normalized(_ values: [Float]) -> [Float] {
        let norm = values.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return values }
        return values.map { $0 / norm }
    }
}

struct ParsedLyricAnalysis: Equatable, Sendable {
    var moods: [String]
    var themes: [String]
    var energy: Double
    var valence: Double
    var summary: String
    var details: LyricDetailProfile = .empty
}

enum LyricIntelligencePrompt {
    static func moodAnalysis(
        lyrics: String,
        family: LyricModelFamily = .generic
    ) -> String {
        LyricModelPrompts.lyricAnalysis(lyrics: lyrics, family: family)
    }

    static func tagging(
        lyrics: String,
        family: LyricModelFamily = .appleFoundation
    ) -> String {
        LyricModelPrompts.tagging(lyrics: lyrics, family: family)
    }

    static func scales(lyrics: String) -> String {
        """
        Score these song lyrics for a recommender. JSON only:
        {"energy":0.0,"valence":0.0}
        energy is 0.0 still/whisper to 1.0 intense/driving.
        valence is 0.0 desolate to 1.0 joyful.
        Lyrics:
        \(lyrics.prefix(LyricModelFamily.generic.lyricCharacterLimit))
        """
    }

    static func summaryOnly(
        lyrics: String,
        family: LyricModelFamily = .generic
    ) -> String {
        LyricModelPrompts.summaryOnly(lyrics: lyrics, family: family)
    }

    static func parse(_ raw: String) -> ParsedLyricAnalysis? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let json = extractJSONObject(from: trimmed) ?? trimmed
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }

        let primaryMoods = normalizedTags(
            dictionary["primaryMoods"] ?? dictionary["primary_moods"],
            limit: 3
        )
        let secondaryMoods = normalizedTags(
            dictionary["secondaryMoods"] ?? dictionary["secondary_moods"],
            limit: 2
        )
        let legacyMoods = normalizedTags(dictionary["moods"], limit: 5)
        let moods = uniqueTags(primaryMoods + secondaryMoods + legacyMoods, limit: 5)
        let themes = uniqueTags(stringList(dictionary["themes"]), limit: 5)
        let energy = numeric(dictionary["energy"]) ?? 0.5
        let valence = numeric(dictionary["valence"]) ?? 0.5
        let summary = normalizedSummary(dictionary["summary"] as? String ?? "")
        if moods.isEmpty,
           dictionary["energy"] == nil,
           dictionary["valence"] == nil,
           summary.isEmpty,
           dictionary["season"] == nil,
           dictionary["style"] == nil {
            return nil
        }
        var parsed = ParsedLyricAnalysis(
            moods: moods,
            themes: themes,
            energy: min(max(energy, 0), 1),
            valence: min(max(valence, 0), 1),
            summary: summary
        )
        var details = LyricDetailProfile(
            moods: moods,
            themes: themes,
            energy: min(max(energy, 0), 1),
            valence: min(max(valence, 0), 1),
            summary: summary,
            season: token(dictionary["season"]),
            dayparts: normalizedTags(dictionary["dayparts"], limit: 4),
            style: token(dictionary["style"]),
            content: clipped(dictionary["content"] as? String, 160),
            setting: token(dictionary["setting"]),
            tempo: min(max(numeric(dictionary["tempo"]) ?? 0.5, 0), 1),
            intimacy: min(max(numeric(dictionary["intimacy"]) ?? 0.5, 0), 1),
            narrative: token(dictionary["narrative"]),
            weather: token(dictionary["weather"]),
            social: token(dictionary["social"]),
            color: token(dictionary["color"]),
            vocal: token(dictionary["vocal"]),
            vocalGender: token(dictionary["vocalGender"] ?? dictionary["vocal_gender"]),
            genre: token(dictionary["genre"]),
            language: token(dictionary["language"]),
            emotionIntensity: min(max(numeric(dictionary["emotion"]) ?? 0.5, 0), 1),
            listenContext: token(dictionary["context"])
        )
        details.primaryMoods = primaryMoods.isEmpty ? Array(moods.prefix(3)) : primaryMoods
        details.secondaryMoods = secondaryMoods.isEmpty
            ? Array(moods.dropFirst(details.primaryMoods.count).prefix(2))
            : secondaryMoods
        details.explicitContent = clipped(
            dictionary["explicitContent"] as? String
                ?? dictionary["explicit_content"] as? String,
            320
        )
        details.interpretation = clipped(dictionary["interpretation"] as? String, 420)
        details.emotionalArc = clipped(
            dictionary["emotionalArc"] as? String
                ?? dictionary["emotional_arc"] as? String,
            320
        )
        details.relationship = clipped(dictionary["relationship"] as? String, 80)
        parsed.details = details
        return parsed
    }

    private static func normalizedTags(_ value: Any?, limit: Int) -> [String] {
        uniqueTags(
            stringList(value).map { LyricLexicalEmbedding.normalized($0) },
            limit: limit
        )
    }

    private static func uniqueTags(_ values: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = LyricLexicalEmbedding.normalized(trimmed)
            guard seen.insert(key).inserted else { continue }
            result.append(trimmed)
            if result.count >= limit { break }
        }
        return result
    }

    private static func token(_ value: Any?) -> String {
        clipped(value as? String, 32)
    }

    private static func clipped(_ value: String?, _ limit: Int) -> String {
        guard let value else { return "" }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(limit))
    }

    static func normalizedSummary(_ raw: String) -> String {
        let cleaned = raw
            .replacingOccurrences(of: "\\n", with: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))
        let lines = cleaned
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isMetaCommentary($0) }
        let summary = lines.joined(separator: "\n")
        return isContentSummary(summary) ? summary : ""
    }

    static func resolvedSummary(_ model: String, lyrics: String) -> String {
        let cleaned = normalizedSummary(model)
        return cleaned.isEmpty ? heuristicSummary(from: lyrics) : cleaned
    }

    static func isContentSummary(_ raw: String) -> Bool {
        let lines = raw
            .replacingOccurrences(of: "\\n", with: "\n")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let first = lines.first, first.count >= 8 else { return false }
        return lines.contains { $0.count >= 8 && !isMetaCommentary($0) }
    }

    static func heuristicSummary(from lyrics: String) -> String {
        let lines = lyrics
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { isLyricStoryLine($0) }
        guard let first = lines.first else { return "" }
        let rest = lines.dropFirst()
        let second = rest.first { $0 != first }
            ?? rest.max { $0.count < $1.count }
        if let second {
            return [first, second].joined(separator: "\n")
        }
        return first
    }

    private static func isLyricStoryLine(_ line: String) -> Bool {
        guard line.count >= 8, !isMetaCommentary(line) else { return false }
        let compact = compactText(line)
        let headers = [
            "verse", "verse1", "verse2", "chorus", "hook", "intro", "outro",
            "bridge", "prechorus", "1절", "2절", "3절", "후렴"
        ]
        return !headers.contains(compact)
    }

    static func isMetaCommentary(_ raw: String) -> Bool {
        let compact = compactText(raw)
        guard compact.count >= 2 else { return true }
        let languageOnly: Set<String> = [
            "korean", "english", "japanese", "chinese",
            "한국어", "영어", "일본어", "중국어",
            "ko", "en", "ja", "zh", "kr"
        ]
        if languageOnly.contains(compact) { return true }
        let markers = [
            "한국어다", "한국어임", "한국어입니다", "한국어로된", "한국어로쓰",
            "한국어가사", "가사는한국어", "이곡은한국어", "이노래는한국어",
            "영어다", "영어임", "영어입니다", "영어가사", "가사는영어",
            "일본어다", "일본어임", "일본어입니다", "일본어가사",
            "중국어다", "중국어임",
            "thisiskorean", "thisisenglish", "thisisjapanese",
            "lyricsarein", "lyricsarewrittenin", "writteninkorean",
            "writteninenglish", "languageis", "thelanguageis",
            "sunginkorean", "sunginenglish",
            "thelyricsarekorean", "thelyricsareenglish",
            "koreantlyrics", "englishlyrics", "japaneselyrics",
            "가사언어", "가사의언어",
            "thisisasong", "이것은노래", "이건노래",
            "twosentences", "twoshortlines", "twoshortsentences",
            "sentencesinkorean", "sentencesinenglish", "sentencesinjapanese",
            "twosentencesin", "twosentencesinkorean", "twosentencesinenglish",
            "두문장", "한국어로두", "영어로두",
            "aboutthelyricstory", "lyricstory", "shortlinesabout"
        ]
        return markers.contains { compact.contains($0) }
    }

    private static func compactText(_ raw: String) -> String {
        raw.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "!", with: "")
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
    }

    private static func extractJSONObject(from raw: String) -> String? {
        LyricJSONExtractor.object(from: raw)
    }

    private static func stringList(_ value: Any?) -> [String] {
        if let values = value as? [String] { return values }
        if let values = value as? [Any] {
            return values.compactMap { item in
                if let value = item as? String { return value }
                if let value = item as? Int { return String(value) }
                if let value = item as? Double { return String(value) }
                return nil
            }
        }
        if let value = value as? String { return [value] }
        return []
    }

    private static func numeric(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? Int { return Double(value) }
        if let value = value as? String { return Double(value) }
        return nil
    }
}

actor LyricIntelligence {
    static let shared = LyricIntelligence()

    private var signatures: [String: LyricSignature] = [:]
    private var inFlight: Set<String> = []
    private var soundInFlight: Set<String> = []
    private var loaded = false
    private var scope = ""
    private var batchGeneration: UInt64 = 0
    private var batchProgress = LyricBatchProgress.idle
    private var sweepTask: Task<Void, Never>?

    func activate(accountScope: String) async {
        if loaded, scope == accountScope { return }
        if scope != accountScope {
            signatures = [:]
            inFlight = []
            soundInFlight = []
            loaded = false
        }
        scope = accountScope
        signatures = await AppDatabase.shared.loadTrackIntelligence(scope: accountScope)
        await migrateLegacyJSONIfNeeded()
        loaded = true
    }

    func deactivate() {
        batchGeneration &+= 1
        sweepTask?.cancel()
        sweepTask = nil
        signatures = [:]
        inFlight = []
        soundInFlight = []
        loaded = false
        scope = ""
        batchProgress = .idle
    }

    func index() async -> LyricSignatureIndex {
        await loadIfNeeded()
        return LyricSignatureIndex(bySongID: signatures)
    }

    func signature(for songID: String) async -> LyricSignature? {
        await loadIfNeeded()
        return signatures[songID]
    }

    func saveManualEdit(
        song: Song,
        lyrics: String,
        accountScope: String,
        moods: [String],
        themes: [String],
        energy: Double,
        valence: Double,
        summary: String,
        details: LyricDetailProfile
    ) async -> LyricSignature? {
        await activate(accountScope: accountScope)
        guard var current = signatures[song.id], current.hasStoredLyricAnalysis else {
            return nil
        }
        let cleanedMoods = Array(moods.prefix(5)).map {
            LyricLexicalEmbedding.normalized(
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }.filter { !$0.isEmpty }
        let cleanedThemes = Array(themes.prefix(5)).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        let cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseSource = current.source.hasPrefix("manual:")
            ? String(current.source.dropFirst("manual:".count))
            : current.source

        current.lyricsHash = LyricLexicalEmbedding.hash(lyrics)
        current.moods = cleanedMoods
        current.themes = cleanedThemes
        current.energy = min(max(energy, 0), 1)
        current.valence = min(max(valence, 0), 1)
        current.summary = cleanSummary
        current.source = "manual:" + baseSource
        if current.embedding.count == LyricLexicalEmbedding.dimensions {
            current.embedding = LyricLexicalEmbedding.merge(
                moods: cleanedMoods,
                energy: current.energy,
                valence: current.valence,
                lyrics: lyrics
            )
        }
        var revisedDetails = details
        revisedDetails.moods = cleanedMoods
        revisedDetails.themes = cleanedThemes
        revisedDetails.energy = current.energy
        revisedDetails.valence = current.valence
        revisedDetails.summary = cleanSummary
        if revisedDetails.primaryMoods.isEmpty {
            revisedDetails.primaryMoods = Array(cleanedMoods.prefix(3))
        }
        current.details = revisedDetails
        signatures[song.id] = current
        await persist(current)
        return current
    }

    func coverage(catalog: [Song]) async -> LyricAnalysisCoverage {
        await loadIfNeeded()
        return LyricAnalysisCoverage.make(
            catalog: catalog,
            signatures: signatures
        )
    }

    func currentBatchProgress() -> LyricBatchProgress {
        batchProgress
    }

    func cancelBatch() {
        batchGeneration &+= 1
        sweepTask?.cancel()
        sweepTask = nil
        batchProgress.isRunning = false
        batchProgress.isCancelled = true
        batchProgress.currentTitle = ""
    }

    func reanalyze(
        song: Song,
        lyrics: String,
        accountScope: String,
        settings: LyricIntelligenceSettings? = nil
    ) async {
        await activate(accountScope: accountScope)
        let hash = LyricLexicalEmbedding.hash(lyrics)
        await analyze(
            song: song,
            lyrics: lyrics,
            hash: hash,
            force: true,
            settings: settings
        )
    }

    func analyzePending(
        catalog: [Song],
        accountScope: String,
        lyricsProvider: @escaping @Sendable (Song) async -> String,
        fileProvider: @escaping @Sendable (Song) async -> URL?,
        force: Bool = false,
        settings: LyricIntelligenceSettings? = nil
    ) async -> LyricBatchProgress {
        await activate(accountScope: accountScope)
        batchGeneration &+= 1
        let generation = batchGeneration
        let report = LyricAnalysisCoverage.make(
            catalog: catalog,
            signatures: signatures
        )
        var progress = LyricBatchProgress.idle
        let queue = report.workQueue
        progress.total = queue.count
        progress.isRunning = true
        batchProgress = progress
        for song in queue {
            guard generation == batchGeneration else {
                progress.isCancelled = true
                progress.isRunning = false
                progress.currentTitle = ""
                batchProgress = progress
                return progress
            }
            progress.currentTitle = song.title
            batchProgress = progress
            let lyrics = await lyricsProvider(song)
            let hadLyrics = lyrics.count >= 24
            var reused = false
            if hadLyrics {
                let hash = LyricLexicalEmbedding.hash(lyrics)
                let missingSummary = !(signatures[song.id]?.hasStoredSummary ?? false)
                reused = !force
                    && !missingSummary
                    && LyricAnalysisCachePolicy.shouldReuseLyric(
                        existing: signatures[song.id],
                        lyricsHash: hash
                    )
                await analyze(
                    song: song,
                    lyrics: lyrics,
                    hash: hash,
                    force: force || missingSummary,
                    settings: settings
                )
            }
            switch LyricBatchAccounting.outcome(
                hadLyrics: hadLyrics,
                reusedCache: reused,
                storedAnalysis: signatures[song.id]?.hasStoredLyricAnalysis == true
            ) {
            case .cached:
                progress.cached += 1
            case .analyzed:
                progress.analyzed += 1
            case .failed:
                progress.failed += 1
            case .noLyrics:
                progress.noLyrics += 1
            }
            if let fileURL = await fileProvider(song) {
                let before = signatures[song.id]?.hasStoredSoundAnalysis ?? false
                let revision = song.audioResourceRevision.isEmpty
                    ? song.id
                    : song.audioResourceRevision
                await analyzeSound(
                    song: song,
                    fileURL: fileURL,
                    audioRevision: revision
                )
                if !before, signatures[song.id]?.hasStoredSoundAnalysis == true {
                    progress.soundAnalyzed += 1
                }
            }
            progress.processed += 1
            batchProgress = progress
        }
        progress.isRunning = false
        progress.currentTitle = ""
        batchProgress = progress
        return progress
    }

    func startBackgroundSweep(
        catalog: [Song],
        accountScope: String,
        lyricsProvider: @escaping @Sendable (Song) async -> String,
        fileProvider: @escaping @Sendable (Song) async -> URL?
    ) {
        sweepTask?.cancel()
        sweepTask = Task { [catalog, accountScope] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, !self.batchProgress.isRunning else { return }
            _ = await self.analyzePending(
                catalog: catalog,
                accountScope: accountScope,
                lyricsProvider: lyricsProvider,
                fileProvider: fileProvider
            )
        }
    }

    func probeSample(accountScope: String?) async -> LyricIntelligenceProbe {
        if let accountScope {
            await activate(accountScope: accountScope)
        } else {
            await loadIfNeeded()
        }
        let lyrics = Self.sampleLyrics
        let hash = LyricLexicalEmbedding.hash(lyrics)
        let song = Song(
            id: Self.probeSongID,
            title: "Probe",
            artist: "BuFi",
            album: "Probe"
        )
        // A probe is a real engine test, not a cache test. Remove the in-memory
        // probe result first and force a fresh LLM request every time.
        signatures.removeValue(forKey: song.id)
        await analyze(song: song, lyrics: lyrics, hash: hash, force: true)
        let fresh = signatures[song.id]
        return LyricIntelligenceProbe(
            reusedCache: false,
            signature: fresh?.hasStoredLyricAnalysis == true ? fresh : nil,
            provider: LyricIntelligenceSettings.current().provider,
            appleOnDevice: AppleFoundationLyricClient.onDeviceStatus(),
            privateCloud: AppleFoundationLyricClient.privateCloudStatus()
        )
    }

    func scheduleAnalysis(song: Song, document: LyricsDocument, accountScope: String? = nil) {
        let lyrics = document.lines
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard lyrics.count >= 24 else { return }
        let hash = LyricLexicalEmbedding.hash(lyrics)
        Task { [song, lyrics, hash, accountScope] in
            if let accountScope {
                await self.activate(accountScope: accountScope)
            } else {
                await self.loadIfNeeded()
            }
            await self.analyze(song: song, lyrics: lyrics, hash: hash)
        }
    }

    func scheduleSoundAnalysis(
        song: Song,
        fileURL: URL,
        audioRevision: String,
        accountScope: String? = nil
    ) {
        guard !audioRevision.isEmpty, fileURL.isFileURL else { return }
        Task { [song, fileURL, audioRevision, accountScope] in
            if let accountScope {
                await self.activate(accountScope: accountScope)
            } else {
                await self.loadIfNeeded()
            }
            await self.analyzeSound(
                song: song,
                fileURL: fileURL,
                audioRevision: audioRevision
            )
        }
    }

    private func analyze(
        song: Song,
        lyrics: String,
        hash: String,
        force: Bool = false,
        settings: LyricIntelligenceSettings? = nil
    ) async {
        if !force,
           var existing = signatures[song.id],
           LyricAnalysisCachePolicy.shouldReuseLyric(
            existing: existing,
            lyricsHash: hash
           ) {
            var dirty = false
            if !existing.hasSentenceEmbedding,
               let sentence = await LyricSentenceEmbedding.vector(from: lyrics) {
                existing.sentenceEmbedding = sentence
                dirty = true
            }
            if !existing.hasStoredSummary {
                existing.summary = await Self.filledSummary(lyrics: lyrics)
                existing.details.summary = existing.summary
                dirty = dirty || existing.hasStoredSummary
            }
            if dirty {
                signatures[song.id] = existing
                await persist(existing)
            }
            return
        }
        guard inFlight.insert(song.id).inserted else { return }
        defer { inFlight.remove(song.id) }
        let resolvedSettings: LyricIntelligenceSettings
        if let provided = settings {
            resolvedSettings = provided
        } else {
            resolvedSettings = await LyricIntelligenceSettings.load()
        }
        guard resolvedSettings.provider != .off else { return }
        let previous = signatures[song.id]
        // Never relabel old fields as a new result. A fresh lyric analysis starts
        // from a clean record and is committed only after an LLM succeeds.
        guard let analyzed = await LyricIntelligenceBackend.analyze(
            lyrics: lyrics,
            settings: resolvedSettings
        ) else {
            // Keep a previously valid LLM result intact. After a full reset there
            // is nothing valid to keep, so coverage remains pending and retries.
            return
        }

        var signature = LyricSignature(
            songID: song.id,
            lyricsHash: hash,
            moods: analyzed.moods,
            themes: analyzed.themes,
            energy: analyzed.energy,
            valence: analyzed.valence,
            embedding: [],
            source: analyzed.source,
            summary: analyzed.summary,
            details: analyzed.details
        )
        if let remote = analyzed.embedding, remote.count >= 8 {
            signature.embedding = remote
        } else {
            signature.embedding = LyricLexicalEmbedding.merge(
                moods: analyzed.moods,
                energy: analyzed.energy,
                valence: analyzed.valence,
                lyrics: lyrics
            )
        }
        signature.sentenceEmbedding =
            await LyricSentenceEmbedding.vector(from: lyrics) ?? []

        // Sound analysis is independent from lyric LLM output and may safely be
        // carried forward. Sentence embeddings can also be reused if generation
        // was deferred by thermal/low-power policy.
        if let previous {
            signature.soundLabels = previous.soundLabels
            signature.soundEmbedding = previous.soundEmbedding
            signature.audioRevision = previous.audioRevision
            signature.soundSource = previous.soundSource
            if signature.sentenceEmbedding.count < 8 {
                signature.sentenceEmbedding = previous.sentenceEmbedding
            }
            if signature.details.vocalGender.isEmpty {
                signature.details.vocalGender = previous.details.vocalGender
            }
        }
        signatures[song.id] = signature
        await persist(signature)
    }

    private func analyzeSound(
        song: Song,
        fileURL: URL,
        audioRevision: String
    ) async {
        if LyricAnalysisCachePolicy.shouldReuseSound(
            existing: signatures[song.id],
            audioRevision: audioRevision
        ) {
            return
        }
        guard soundInFlight.insert(song.id).inserted else { return }
        defer { soundInFlight.remove(song.id) }
        guard let analyzed = await SoundAnalysisClassifier.analyzeFile(at: fileURL) else {
            return
        }
        var signature = signatures[song.id] ?? LyricSignature(
            songID: song.id,
            lyricsHash: "",
            moods: [],
            themes: [],
            energy: 0.5,
            valence: 0.5,
            embedding: [],
            source: ""
        )
        signature.soundLabels = analyzed.labels
        signature.soundEmbedding = analyzed.embedding
        signature.audioRevision = audioRevision
        signature.soundSource = analyzed.source
        if let current = signatures[song.id] {
            if signature.lyricsHash.isEmpty {
                signature.lyricsHash = current.lyricsHash
                signature.moods = current.moods
                signature.themes = current.themes
                signature.energy = current.energy
                signature.valence = current.valence
                signature.embedding = current.embedding
                signature.source = current.source
                signature.sentenceEmbedding = current.sentenceEmbedding
                signature.summary = current.summary
                signature.details = current.details
            }
        }
        if signature.details.vocalGender.isEmpty {
            signature.details.vocalGender = SoundAnalysisClassifier.vocalGender(
                from: analyzed.labels
            )
        }
        signatures[song.id] = signature
        await persist(signature)
    }

    private func loadIfNeeded() async {
        guard !loaded else { return }
        if !scope.isEmpty {
            signatures = await AppDatabase.shared.loadTrackIntelligence(scope: scope)
        }
        await migrateLegacyJSONIfNeeded()
        loaded = true
    }

    private func persist(_ signature: LyricSignature) async {
        guard !scope.isEmpty else { return }
        _ = await AppDatabase.shared.saveTrackIntelligence(signature, scope: scope)
    }

    private func migrateLegacyJSONIfNeeded() async {
        let url = Self.storageURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(
                [String: LyricSignature].self,
                from: data
              ) else {
            return
        }
        for (id, signature) in decoded where signatures[id] == nil {
            signatures[id] = signature
            await persist(signature)
        }
        try? FileManager.default.removeItem(at: url)
    }

    static let probeSongID = "__bufi-lyric-probe__"
    static let sampleLyrics = """
        I walk alone at midnight under the quiet rain
        The city lights are fading and I keep repeating your name
        Slow breath, heavy heart, a calm and lonely tune
        """

    private static func filledSummary(lyrics: String) async -> String {
        let settings = await LyricIntelligenceSettings.load()
        if settings.provider != .off,
           let summary = await LyricIntelligenceBackend.summarize(
            lyrics: lyrics,
            settings: settings
           ),
           LyricIntelligencePrompt.isContentSummary(summary) {
            return summary
        }
        // Do not manufacture an apparent analysis from copied lyric lines.
        // Missing LLM output stays missing and remains eligible for retry.
        return ""
    }

    private static var storageURL: URL {
        let folder = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return folder
            .appendingPathComponent("BuFi", isDirectory: true)
            .appendingPathComponent("lyric-signatures.json")
    }
}

struct LyricIntelligenceSettings: Sendable {
    var provider: LyricIntelligenceProviderKind
    var openAIKey: String
    var openRouterKey: String
    var openRouterModel: String
    var groqKey: String = ""
    var groqModel: String = "openai/gpt-oss-120b"
    var cerebrasKey: String = ""
    var cerebrasModel: String = "llama-3.3-70b"
    var userPrompt: String = ""

    static let providerKey = "lyric-intelligence-provider"
    static let openRouterModelKey = "lyric-intelligence-openrouter-model"
    static let groqModelKey = "lyric-intelligence-groq-model"
    static let cerebrasModelKey = "lyric-intelligence-cerebras-model"
    static let userPromptKey = "lyric-intelligence-user-prompt"
    static let openAIAccount = "openai-api-key"
    static let openRouterAccount = "openrouter-api-key"
    static let groqAccount = "groq-api-key"
    static let cerebrasAccount = "cerebras-api-key"
    static let defaultOpenRouterModel = "google/gemma-3-270m-it"
    static let defaultGroqModel = "openai/gpt-oss-120b"
    static let defaultCerebrasModel = "llama-3.3-70b"
    static let radioPrimaryModel = "openai/gpt-oss-120b"
    static let radioFallbackModel = "llama-3.3-70b-versatile"

    static func current(
        defaults: UserDefaults = .standard,
        openAIKey: String = "",
        openRouterKey: String = "",
        groqKey: String = "",
        cerebrasKey: String = ""
    ) -> LyricIntelligenceSettings {
        let raw = defaults.string(forKey: providerKey) ?? ""
        return LyricIntelligenceSettings(
            provider: resolvedProvider(raw),
            openAIKey: openAIKey,
            openRouterKey: openRouterKey,
            openRouterModel: storedModel(
                defaults: defaults,
                key: openRouterModelKey,
                fallback: defaultOpenRouterModel
            ),
            groqKey: groqKey,
            groqModel: storedModel(
                defaults: defaults,
                key: groqModelKey,
                fallback: defaultGroqModel
            ),
            cerebrasKey: cerebrasKey,
            cerebrasModel: storedModel(
                defaults: defaults,
                key: cerebrasModelKey,
                fallback: defaultCerebrasModel
            ),
            userPrompt: defaults.string(forKey: userPromptKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }

    static func load(defaults: UserDefaults = .standard) async -> LyricIntelligenceSettings {
        let store = SecureStore()
        return current(
            defaults: defaults,
            openAIKey: await store.loadSecret(account: openAIAccount) ?? "",
            openRouterKey: await store.loadSecret(account: openRouterAccount) ?? "",
            groqKey: await store.loadSecret(account: groqAccount) ?? "",
            cerebrasKey: await store.loadSecret(account: cerebrasAccount) ?? ""
        )
    }

    static func resolvedProvider(_ raw: String) -> LyricIntelligenceProviderKind {
        let provider = LyricIntelligenceProviderKind(rawValue: raw) ?? .onDevice
        return provider == .applePrivateCloud ? .onDevice : provider
    }

    static func keychainAccount(for provider: LyricIntelligenceProviderKind) -> String? {
        switch provider {
        case .openAI: openAIAccount
        case .openRouter: openRouterAccount
        case .groq: groqAccount
        case .cerebras: cerebrasAccount
        case .off, .onDevice, .applePrivateCloud: nil
        }
    }

    private static func storedModel(
        defaults: UserDefaults,
        key: String,
        fallback: String
    ) -> String {
        defaults.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            ?? fallback
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

enum LyricIntelligenceBackend {
    struct Analysis: Sendable {
        var moods: [String]
        var themes: [String]
        var energy: Double
        var valence: Double
        var summary: String
        var details: LyricDetailProfile = .empty
        var embedding: [Float]?
        var source: String
    }

    private static func appleAnalysis(
        _ apple: AppleFoundationLyricClient.Analysis
    ) -> Analysis {
        Analysis(
            moods: apple.moods,
            themes: apple.themes,
            energy: apple.energy,
            valence: apple.valence,
            summary: apple.summary,
            details: apple.details,
            embedding: nil,
            source: apple.source
        )
    }

    static func analyze(
        lyrics: String,
        settings: LyricIntelligenceSettings
    ) async -> Analysis? {
        var result: Analysis?
        switch settings.provider {
        case .off:
            result = nil
        case .onDevice, .applePrivateCloud:
            result = await onDevice(lyrics: lyrics)
        case .openAI, .openRouter, .groq, .cerebras:
            if let target = LyricInferenceRuntime.primaryTarget(settings) {
                result = await remote(
                    lyrics: lyrics,
                    target: target,
                    settings: settings
                )
            }
        }
        if let validated = validatedLLMAnalysis(result) {
            return validated
        }
        guard settings.provider != .off else { return nil }
        return await fallbackLLMAnalysis(
            lyrics: lyrics,
            settings: settings,
            excluding: settings.provider
        )
    }

    private static func onDevice(lyrics: String) async -> Analysis? {
        if let apple = await AppleFoundationLyricClient.analyzeLocal3B(lyrics: lyrics) {
            return appleAnalysis(apple)
        }
        if let apple = await AppleFoundationLyricClient.analyze(lyrics: lyrics) {
            return appleAnalysis(apple)
        }
        return nil
    }

    private static func validatedLLMAnalysis(_ candidate: Analysis?) -> Analysis? {
        guard var analysis = candidate else { return nil }
        analysis.summary = LyricIntelligencePrompt.normalizedSummary(analysis.summary)
        guard LyricIntelligencePrompt.isContentSummary(analysis.summary) else {
            return nil
        }
        analysis.details.summary = analysis.summary
        return analysis
    }

    private static func fallbackLLMAnalysis(
        lyrics: String,
        settings: LyricIntelligenceSettings,
        excluding provider: LyricIntelligenceProviderKind
    ) async -> Analysis? {
        for target in LyricInferenceRuntime.fallbackTargets(
            settings,
            excluding: provider
        ) {
            if let analysis = validatedLLMAnalysis(
                await remote(lyrics: lyrics, target: target, settings: settings)
            ) {
                return analysis
            }
        }
        return nil
    }

    private static func remote(
        lyrics: String,
        target: LyricChatTarget,
        settings: LyricIntelligenceSettings
    ) async -> Analysis? {
        let prompt = LyricIntelligencePrompt.moodAnalysis(
            lyrics: lyrics,
            family: LyricModelFamily.resolve(model: target.model)
        )
        guard var text = await LyricInferenceRuntime.chat(
            prompt: prompt,
            target: target,
            maxTokens: 900
        ) else {
            return nil
        }
        if LyricIntelligencePrompt.parse(text) == nil,
           let repaired = await LyricInferenceRuntime.repairedJSON(
            from: text,
            settings: settings
           ) {
            text = repaired
        }
        guard let parsed = LyricIntelligencePrompt.parse(text) else {
            return nil
        }
        let embedding = await LyricInferenceRuntime.embedding(
            lyrics: lyrics,
            target: target
        )
        return Analysis(
            moods: parsed.moods,
            themes: parsed.themes,
            energy: parsed.energy,
            valence: parsed.valence,
            summary: parsed.summary,
            details: parsed.details,
            embedding: embedding,
            source: target.source
        )
    }

    static func complete(
        prompt: String,
        settings: LyricIntelligenceSettings
    ) async -> String? {
        await LyricInferenceRuntime.complete(
            prompt: prompt,
            settings: settings,
            maxTokens: 700
        )
    }

    static func summarize(
        lyrics: String,
        settings: LyricIntelligenceSettings
    ) async -> String? {
        guard var text = await complete(
            prompt: LyricIntelligencePrompt.summaryOnly(
                lyrics: lyrics,
                family: LyricModelFamily.resolve(settings)
            ),
            settings: settings
        ) else {
            return nil
        }
        if LyricIntelligencePrompt.parse(text) == nil,
           let repaired = await LyricInferenceRuntime.repairedJSON(
            from: text,
            settings: settings
           ) {
            text = repaired
        }
        if let parsed = LyricIntelligencePrompt.parse(text), !parsed.summary.isEmpty {
            return parsed.summary
        }
        let normalized = LyricIntelligencePrompt.normalizedSummary(text)
        return normalized.isEmpty ? nil : normalized
    }
}
