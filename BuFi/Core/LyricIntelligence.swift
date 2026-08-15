import Foundation

enum LyricIntelligenceProviderKind: String, CaseIterable, Identifiable, Sendable {
    case off
    case onDevice
    case applePrivateCloud
    case openAI
    case openRouter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: String(localized: "끄기")
        case .onDevice: String(localized: "자동 (Apple 3B → Gemma 3)")
        case .applePrivateCloud: String(localized: "Apple Privacy Cloud")
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter"
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
        moods.map(LyricLexicalEmbedding.normalized)
            .filter { !$0.isEmpty }
    }

    var hasStoredLyricAnalysis: Bool {
        !lyricsHash.isEmpty && !source.isEmpty
    }

    var hasStoredSoundAnalysis: Bool {
        !soundLabels.isEmpty || soundEmbedding.contains { $0 != 0 }
    }

    var hasSentenceEmbedding: Bool {
        sentenceEmbedding.count >= 8
    }

    var hasStoredSummary: Bool {
        !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var themeKeys: [String] {
        themes.map(LyricLexicalEmbedding.normalized).filter { !$0.isEmpty }
    }

    var sourceTitle: String {
        switch source {
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
        case "lexical":
            String(localized: "로컬 어휘 (모델 없음)")
        default:
            source
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
    var bySongID: [String: LyricSignature] = [:]

    static let empty = LyricSignatureIndex()

    func affinity(
        candidateID: String,
        recentIDs: [String],
        favoriteIDs: [String]
    ) -> Double {
        guard let candidate = bySongID[candidateID] else { return 0 }
        let anchors = recentIDs.prefix(8) + favoriteIDs.prefix(12)
        var best = 0.0
        var samples = 0
        var total = 0.0
        for id in anchors {
            guard id != candidateID, let other = bySongID[id] else { continue }
            let score = LyricLexicalEmbedding.similarity(candidate, other)
            best = max(best, score)
            total += score
            samples += 1
        }
        guard samples > 0 else { return 0 }
        return min(1, best * 0.72 + (total / Double(samples)) * 0.28)
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
            let sound = projected(signature.soundEmbedding, to: dimensions)
            for index in merged.indices {
                merged[index] = merged[index] * 0.82 + sound[index] * 0.18
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
        return l2Normalized(merged)
    }

    static func similarity(_ left: LyricSignature, _ right: LyricSignature) -> Double {
        let fused = cosine(unified(left), unified(right))
        let mood = jaccard(left.moodKeys, right.moodKeys)
        let theme = jaccard(left.themeKeys, right.themeKeys)
        let energy = 1 - min(1, abs(left.energy - right.energy))
        let valence = 1 - min(1, abs(left.valence - right.valence))
        return min(
            1,
            fused * 0.60
                + mood * 0.16
                + theme * 0.10
                + energy * 0.07
                + valence * 0.07
        )
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
    static func moodAnalysis(lyrics: String, characterLimit: Int = 2_400) -> String {
        """
        Score these lyrics for a personal music recommender. JSON only, 20 fields, no markdown:
        {"moods":["up to 5 mood tags"],"themes":["up to 5 themes"],"energy":0.0,"valence":0.0,"summary":"two short lines","season":"spring|summer|autumn|winter|any","dayparts":["morning","afternoon","evening","night"],"style":"short style","content":"what the song is about","setting":"place","tempo":0.0,"intimacy":0.0,"narrative":"story|confession|party|letter","weather":"rain|sun|snow|clear|any","social":"alone|couple|crowd","color":"one color word","vocal":"soft|powerful|rap|choir","language":"ko|en|ja|other","emotion":0.0,"context":"sleep|commute|workout|date|focus"}
        energy/tempo/intimacy/emotion are 0-1. valence 0 sad to 1 joyful. summary two sentences in the lyric language.
        Lyrics:
        \(lyrics.prefix(characterLimit))
        """
    }

    static func tagging(lyrics: String) -> String {
        """
        Tag these lyrics for recommendation matching. JSON only:
        {"moods":["up to 5 mood tags"],"themes":["up to 5 themes"],"summary":"two short lines","season":"spring|summer|autumn|winter|any","dayparts":["morning","afternoon","evening","night"],"style":"short style","content":"what it is about","setting":"place","narrative":"story|confession|party|letter","weather":"rain|sun|snow|clear|any","social":"alone|couple|crowd","color":"one color","vocal":"soft|powerful|rap|choir","language":"ko|en|ja|other","context":"sleep|commute|workout|date|focus"}
        Lyrics:
        \(lyrics.prefix(2_400))
        """
    }

    static func scales(lyrics: String) -> String {
        """
        Score these song lyrics for a recommender. JSON only:
        {"energy":0.0,"valence":0.0}
        energy is 0.0 still/whisper to 1.0 intense/driving.
        valence is 0.0 desolate to 1.0 joyful.
        Lyrics:
        \(lyrics.prefix(2_400))
        """
    }

    static func summaryOnly(lyrics: String) -> String {
        """
        Summarize these song lyrics in exactly two short sentences.
        JSON only: {"summary":"line one\\nline two"}
        Same language as the lyrics. No title, no quotes, no extra keys.
        Lyrics:
        \(lyrics.prefix(2_400))
        """
    }

    static func parse(_ raw: String) -> ParsedLyricAnalysis? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let json = extractJSONObject(from: trimmed) ?? trimmed
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            return nil
        }
        let moods = stringList(dictionary["moods"]).prefix(5).map {
            LyricLexicalEmbedding.normalized($0)
        }.filter { !$0.isEmpty }
        let themes = stringList(dictionary["themes"]).prefix(5)
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
            moods: Array(moods),
            themes: Array(themes),
            energy: min(max(energy, 0), 1),
            valence: min(max(valence, 0), 1),
            summary: summary
        )
        parsed.details = LyricDetailProfile(
            moods: Array(moods),
            themes: Array(themes),
            energy: min(max(energy, 0), 1),
            valence: min(max(valence, 0), 1),
            summary: summary,
            season: token(dictionary["season"]),
            dayparts: stringList(dictionary["dayparts"]).prefix(4).map {
                LyricLexicalEmbedding.normalized($0)
            },
            style: token(dictionary["style"]),
            content: clipped(dictionary["content"] as? String, 120),
            setting: token(dictionary["setting"]),
            tempo: min(max(numeric(dictionary["tempo"]) ?? 0.5, 0), 1),
            intimacy: min(max(numeric(dictionary["intimacy"]) ?? 0.5, 0), 1),
            narrative: token(dictionary["narrative"]),
            weather: token(dictionary["weather"]),
            social: token(dictionary["social"]),
            color: token(dictionary["color"]),
            vocal: token(dictionary["vocal"]),
            language: token(dictionary["language"]),
            emotionIntensity: min(max(numeric(dictionary["emotion"]) ?? 0.5, 0), 1),
            listenContext: token(dictionary["context"])
        )
        return parsed
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
            .filter { !$0.isEmpty }
            .prefix(2)
            .map { String($0.prefix(90)) }
        return lines.joined(separator: "\n")
    }

    static func heuristicSummary(from lyrics: String) -> String {
        let lines = lyrics
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 8 }
            .prefix(2)
            .map { String($0.prefix(90)) }
        return lines.joined(separator: "\n")
    }

    private static func extractJSONObject(from raw: String) -> String? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start < end else {
            return nil
        }
        return String(raw[start...end])
    }

    private static func stringList(_ value: Any?) -> [String] {
        if let values = value as? [String] { return values }
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

    func analyzePending(
        catalog: [Song],
        accountScope: String,
        lyricsProvider: @escaping @Sendable (Song) async -> String,
        fileProvider: @escaping @Sendable (Song) async -> URL?
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
            if lyrics.count >= 24 {
                let hash = LyricLexicalEmbedding.hash(lyrics)
                let reused = LyricAnalysisCachePolicy.shouldReuseLyric(
                    existing: signatures[song.id],
                    lyricsHash: hash
                )
                await analyze(song: song, lyrics: lyrics, hash: hash)
                if reused {
                    progress.cached += 1
                } else {
                    progress.analyzed += 1
                }
            } else {
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
        let reused = LyricAnalysisCachePolicy.shouldReuseLyric(
            existing: signatures[song.id],
            lyricsHash: hash
        )
        await analyze(song: song, lyrics: lyrics, hash: hash)
        return LyricIntelligenceProbe(
            reusedCache: reused,
            signature: signatures[song.id],
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

    private func analyze(song: Song, lyrics: String, hash: String) async {
        if var existing = signatures[song.id],
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
            if !existing.details.hasExtendedFields || !existing.hasStoredSummary {
                let store = SecureStore()
                let settings = LyricIntelligenceSettings.current(
                    openAIKey: await store.loadSecret(
                        account: LyricIntelligenceSettings.openAIAccount
                    ) ?? "",
                    openRouterKey: await store.loadSecret(
                        account: LyricIntelligenceSettings.openRouterAccount
                    ) ?? ""
                )
                if settings.provider != .off,
                   let analyzed = await LyricIntelligenceBackend.analyze(
                    lyrics: lyrics,
                    settings: settings
                   ) {
                    if existing.moods.isEmpty { existing.moods = analyzed.moods }
                    if existing.themes.isEmpty { existing.themes = analyzed.themes }
                    if !analyzed.summary.isEmpty { existing.summary = analyzed.summary }
                    existing.details = analyzed.details.withBasics(
                        moods: existing.moods,
                        themes: existing.themes,
                        energy: existing.energy,
                        valence: existing.valence,
                        summary: existing.summary
                    )
                    dirty = true
                } else if !existing.hasStoredSummary {
                    existing.summary = LyricIntelligencePrompt.heuristicSummary(
                        from: lyrics
                    )
                    dirty = !existing.summary.isEmpty
                }
            }
            if dirty {
                signatures[song.id] = existing
                await persist(existing)
            }
            return
        }
        guard inFlight.insert(song.id).inserted else { return }
        defer { inFlight.remove(song.id) }
        let store = SecureStore()
        let settings = LyricIntelligenceSettings.current(
            openAIKey: await store.loadSecret(
                account: LyricIntelligenceSettings.openAIAccount
            ) ?? "",
            openRouterKey: await store.loadSecret(
                account: LyricIntelligenceSettings.openRouterAccount
            ) ?? ""
        )
        guard settings.provider != .off else { return }
        var signature = signatures[song.id] ?? LyricSignature(
            songID: song.id,
            lyricsHash: hash,
            moods: [],
            themes: [],
            energy: 0.5,
            valence: 0.5,
            embedding: [],
            source: "lexical"
        )
        signature.lyricsHash = hash
        signature.embedding = LyricLexicalEmbedding.merge(
            moods: signature.moods,
            energy: signature.energy,
            valence: signature.valence,
            lyrics: lyrics
        )
        if let analyzed = await LyricIntelligenceBackend.analyze(
            lyrics: lyrics,
            settings: settings
        ) {
            signature.moods = analyzed.moods
            signature.themes = analyzed.themes
            signature.energy = analyzed.energy
            signature.valence = analyzed.valence
            signature.source = analyzed.source
            if !analyzed.summary.isEmpty {
                signature.summary = analyzed.summary
            }
            if analyzed.details.hasExtendedFields || !analyzed.details.moods.isEmpty {
                signature.details = analyzed.details.withBasics(
                    moods: analyzed.moods,
                    themes: analyzed.themes,
                    energy: analyzed.energy,
                    valence: analyzed.valence,
                    summary: analyzed.summary
                )
            }
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
        } else {
            signature.source = "lexical"
        }
        if !signature.hasStoredSummary {
            signature.summary = LyricIntelligencePrompt.heuristicSummary(from: lyrics)
        }
        if !signature.hasSentenceEmbedding {
            signature.sentenceEmbedding =
                await LyricSentenceEmbedding.vector(from: lyrics) ?? []
        }
        if let current = signatures[song.id] {
            if signature.soundLabels.isEmpty {
                signature.soundLabels = current.soundLabels
                signature.soundEmbedding = current.soundEmbedding
                signature.audioRevision = current.audioRevision
                signature.soundSource = current.soundSource
            }
            if signature.sentenceEmbedding.count < 8 {
                signature.sentenceEmbedding = current.sentenceEmbedding
            }
            if !signature.hasStoredSummary {
                signature.summary = current.summary
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
            }
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

    static let providerKey = "lyric-intelligence-provider"
    static let openRouterModelKey = "lyric-intelligence-openrouter-model"
    static let openAIAccount = "openai-api-key"
    static let openRouterAccount = "openrouter-api-key"

    static func current(
        defaults: UserDefaults = .standard,
        openAIKey: String = "",
        openRouterKey: String = ""
    ) -> LyricIntelligenceSettings {
        let raw = defaults.string(forKey: providerKey) ?? ""
        return LyricIntelligenceSettings(
            provider: resolvedProvider(raw),
            openAIKey: openAIKey,
            openRouterKey: openRouterKey,
            openRouterModel: defaults.string(forKey: openRouterModelKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
                ?? "google/gemma-3-270m-it"
        )
    }

    static func resolvedProvider(_ raw: String) -> LyricIntelligenceProviderKind {
        let provider = LyricIntelligenceProviderKind(rawValue: raw) ?? .onDevice
        return provider == .applePrivateCloud ? .onDevice : provider
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
        switch settings.provider {
        case .off:
            return nil
        case .onDevice, .applePrivateCloud:
            return await onDevice(lyrics: lyrics, settings: settings)
        case .openAI:
            return await remote(
                lyrics: lyrics,
                endpoint: URL(string: "https://api.openai.com/v1/chat/completions"),
                embeddingEndpoint: URL(string: "https://api.openai.com/v1/embeddings"),
                key: settings.openAIKey,
                model: "gpt-4o-mini",
                embeddingModel: "text-embedding-3-small",
                source: "openai"
            )
        case .openRouter:
            return await remote(
                lyrics: lyrics,
                endpoint: URL(string: "https://openrouter.ai/api/v1/chat/completions"),
                embeddingEndpoint: URL(string: "https://openrouter.ai/api/v1/embeddings"),
                key: settings.openRouterKey,
                model: settings.openRouterModel,
                embeddingModel: "openai/text-embedding-3-small",
                source: "openrouter"
            )
        }
    }

    private static func onDevice(
        lyrics: String,
        settings: LyricIntelligenceSettings
    ) async -> Analysis? {
        if let apple = await AppleFoundationLyricClient.analyzeLocal3B(lyrics: lyrics) {
            return appleAnalysis(apple)
        }
        if let apple = await AppleFoundationLyricClient.analyze(lyrics: lyrics) {
            return appleAnalysis(apple)
        }
        if !settings.openRouterKey.isEmpty,
           let gemma = await remote(
            lyrics: lyrics,
            endpoint: URL(string: "https://openrouter.ai/api/v1/chat/completions"),
            embeddingEndpoint: nil,
            key: settings.openRouterKey,
            model: "google/gemma-3-270m-it",
            embeddingModel: "openai/text-embedding-3-small",
            source: "gemma-3-270m"
           ) {
            return gemma
        }
        return Analysis(
            moods: heuristicMoods(in: lyrics),
            themes: [],
            energy: 0.5,
            valence: 0.5,
            summary: LyricIntelligencePrompt.heuristicSummary(from: lyrics),
            embedding: nil,
            source: "lexical"
        )
    }

    private static func heuristicMoods(in lyrics: String) -> [String] {
        let text = LyricLexicalEmbedding.normalized(lyrics)
        var moods: [String] = []
        let lexicon: [(String, [String])] = [
            ("sad", ["cry", "tears", "lonely", "grief", "슬픔", "눈물"]),
            ("happy", ["smile", "dance", "joy", "sunshine", "행복", "웃"]),
            ("calm", ["quiet", "slow", "ocean", "sleep", "잔잔", "밤"]),
            ("angry", ["hate", "rage", "fight", "fire", "화나"]),
            ("romantic", ["love", "heart", "kiss", "사랑", "마음"])
        ]
        for (mood, tokens) in lexicon where tokens.contains(where: text.contains) {
            moods.append(mood)
        }
        return moods.isEmpty ? ["neutral"] : moods
    }

    private static func remote(
        lyrics: String,
        endpoint: URL?,
        embeddingEndpoint: URL?,
        key: String,
        model: String,
        embeddingModel: String,
        source: String
    ) async -> Analysis? {
        guard !key.isEmpty, let endpoint else { return nil }
        let prompt = LyricIntelligencePrompt.moodAnalysis(lyrics: lyrics)
        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": "Return JSON only."],
                ["role": "user", "content": prompt]
            ]
        ]
        guard let text = await postJSON(
            url: endpoint,
            key: key,
            body: body
        ) else {
            return nil
        }
        let content = chatContent(from: text) ?? text
        guard let parsed = LyricIntelligencePrompt.parse(content) else {
            return nil
        }
        var embedding: [Float]?
        if let embeddingEndpoint {
            embedding = await remoteEmbedding(
                lyrics: lyrics,
                endpoint: embeddingEndpoint,
                key: key,
                model: embeddingModel
            )
        }
        return Analysis(
            moods: parsed.moods,
            themes: parsed.themes,
            energy: parsed.energy,
            valence: parsed.valence,
            summary: parsed.summary,
            details: parsed.details,
            embedding: embedding,
            source: source
        )
    }

    static func complete(
        prompt: String,
        settings: LyricIntelligenceSettings
    ) async -> String? {
        switch settings.provider {
        case .off:
            return nil
        case .onDevice, .applePrivateCloud:
            if let text = await AppleFoundationLyricClient.complete(prompt) {
                return text
            }
            return await remoteText(
                prompt: prompt,
                endpoint: URL(string: "https://openrouter.ai/api/v1/chat/completions"),
                key: settings.openRouterKey,
                model: "google/gemma-3-270m-it"
            )
        case .openAI:
            return await remoteText(
                prompt: prompt,
                endpoint: URL(string: "https://api.openai.com/v1/chat/completions"),
                key: settings.openAIKey,
                model: "gpt-4o-mini"
            )
        case .openRouter:
            return await remoteText(
                prompt: prompt,
                endpoint: URL(string: "https://openrouter.ai/api/v1/chat/completions"),
                key: settings.openRouterKey,
                model: settings.openRouterModel
            )
        }
    }

    static func summarize(
        lyrics: String,
        settings: LyricIntelligenceSettings
    ) async -> String? {
        guard let text = await complete(
            prompt: LyricIntelligencePrompt.summaryOnly(lyrics: lyrics),
            settings: settings
        ) else {
            return nil
        }
        if let parsed = LyricIntelligencePrompt.parse(text), !parsed.summary.isEmpty {
            return parsed.summary
        }
        let normalized = LyricIntelligencePrompt.normalizedSummary(text)
        return normalized.isEmpty ? nil : normalized
    }

    private static func remoteText(
        prompt: String,
        endpoint: URL?,
        key: String,
        model: String
    ) async -> String? {
        guard !key.isEmpty, let endpoint else { return nil }
        let body: [String: Any] = [
            "model": model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": "Return JSON only."],
                ["role": "user", "content": prompt]
            ]
        ]
        guard let text = await postJSON(url: endpoint, key: key, body: body) else {
            return nil
        }
        return chatContent(from: text) ?? text
    }

    private static func remoteEmbedding(
        lyrics: String,
        endpoint: URL,
        key: String,
        model: String
    ) async -> [Float]? {
        let body: [String: Any] = [
            "model": model,
            "input": String(lyrics.prefix(4_000))
        ]
        guard let raw = await postJSON(url: endpoint, key: key, body: body),
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let items = root["data"] as? [[String: Any]],
              let first = items.first,
              let values = first["embedding"] as? [Double] else {
            return nil
        }
        return values.map { Float($0) }
    }

    private static func chatContent(from raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            return nil
        }
        return content
    }

    private static func postJSON(
        url: URL,
        key: String,
        body: [String: Any]
    ) async -> String? {
        guard url.scheme?.lowercased() == "https",
              let payload = try? JSONSerialization.data(withJSONObject: body) else {
            return nil
        }
        var request = URLRequest(url: url)
        ModernNetworkPolicy.prepareExternalAPIRequest(
            &request,
            acceptsZstandard: false
        )
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 18
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }
}
