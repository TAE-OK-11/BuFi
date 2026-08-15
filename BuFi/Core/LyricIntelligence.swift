import Foundation

enum LyricIntelligenceProviderKind: String, CaseIterable, Identifiable, Sendable {
    case off
    case onDevice
    case openAI
    case openRouter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: String(localized: "끄기")
        case .onDevice: String(localized: "자동 (기기 → Gemma 3)")
        case .openAI: "OpenAI"
        case .openRouter: "OpenRouter"
        }
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

    var moodKeys: [String] {
        moods.map(LyricLexicalEmbedding.normalized)
            .filter { !$0.isEmpty }
    }
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
        var vector = vector(from: lyrics)
        guard vector.count == dimensions else { return vector }
        let moodVector = vector(from: moods.joined(separator: " "))
        for index in vector.indices {
            vector[index] = vector[index] * 0.72 + moodVector[index] * 0.20
        }
        if dimensions > 2 {
            vector[0] += Float(min(max(energy, 0), 1) - 0.5)
            vector[1] += Float(min(max(valence, 0), 1) - 0.5)
        }
        return l2Normalized(vector)
    }

    static func similarity(_ left: LyricSignature, _ right: LyricSignature) -> Double {
        let cosine = cosine(left.embedding, right.embedding)
        let mood = jaccard(left.moodKeys, right.moodKeys)
        let energy = 1 - min(1, abs(left.energy - right.energy))
        let valence = 1 - min(1, abs(left.valence - right.valence))
        return min(1, cosine * 0.58 + mood * 0.24 + energy * 0.09 + valence * 0.09)
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

    private static func l2Normalized(_ values: [Float]) -> [Float] {
        let norm = values.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return values }
        return values.map { $0 / norm }
    }
}

enum LyricIntelligencePrompt {
    static func moodAnalysis(lyrics: String) -> String {
        """
        Analyze these song lyrics. Reply with JSON only, no markdown:
        {"moods":["up to 5 lowercase mood words"],"themes":["up to 5 short themes"],"energy":0.0,"valence":0.0}
        energy is 0 calm to 1 intense. valence is 0 sad to 1 joyful.
        Lyrics:
        \(lyrics.prefix(2_400))
        """
    }

    static func parse(_ raw: String) -> (moods: [String], themes: [String], energy: Double, valence: Double)? {
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
        guard !moods.isEmpty else { return nil }
        return (
            Array(moods),
            Array(themes),
            min(max(energy, 0), 1),
            min(max(valence, 0), 1)
        )
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
    private var loaded = false

    func index() -> LyricSignatureIndex {
        loadIfNeeded()
        return LyricSignatureIndex(bySongID: signatures)
    }

    func signature(for songID: String) -> LyricSignature? {
        loadIfNeeded()
        return signatures[songID]
    }

    func scheduleAnalysis(song: Song, document: LyricsDocument) {
        let lyrics = document.lines
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard lyrics.count >= 24 else { return }
        let hash = LyricLexicalEmbedding.hash(lyrics)
        loadIfNeeded()
        if signatures[song.id]?.lyricsHash == hash { return }
        guard inFlight.insert(song.id).inserted else { return }
        Task { [song, lyrics, hash] in
            await self.analyze(song: song, lyrics: lyrics, hash: hash)
        }
    }

    private func analyze(song: Song, lyrics: String, hash: String) async {
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
        let lexical = LyricLexicalEmbedding.merge(
            moods: [],
            energy: 0.5,
            valence: 0.5,
            lyrics: lyrics
        )
        var signature = LyricSignature(
            songID: song.id,
            lyricsHash: hash,
            moods: [],
            themes: [],
            energy: 0.5,
            valence: 0.5,
            embedding: lexical,
            source: "lexical"
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
        }
        signatures[song.id] = signature
        persist()
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let url = Self.storageURL
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(
                [String: LyricSignature].self,
                from: data
              ) else {
            return
        }
        signatures = decoded
    }

    private func persist() {
        let url = Self.storageURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if let data = try? JSONEncoder().encode(signatures) {
            try? data.write(to: url, options: .atomic)
        }
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
            provider: LyricIntelligenceProviderKind(rawValue: raw) ?? .onDevice,
            openAIKey: openAIKey,
            openRouterKey: openRouterKey,
            openRouterModel: defaults.string(forKey: openRouterModelKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
                ?? "google/gemma-3-270m-it"
        )
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
        var embedding: [Float]?
        var source: String
    }

    static func analyze(
        lyrics: String,
        settings: LyricIntelligenceSettings
    ) async -> Analysis? {
        switch settings.provider {
        case .off:
            return nil
        case .onDevice:
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
        if let text = await AppleFoundationLyricClient.complete(
            LyricIntelligencePrompt.moodAnalysis(lyrics: lyrics)
        ), let parsed = LyricIntelligencePrompt.parse(text) {
            return Analysis(
                moods: parsed.moods,
                themes: parsed.themes,
                energy: parsed.energy,
                valence: parsed.valence,
                embedding: nil,
                source: "apple-intelligence"
            )
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
            embedding: embedding,
            source: source
        )
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
