import Foundation

/// Shared helpers for turning messy model replies into JSON and for talking
/// to OpenAI-compatible lyric endpoints without repeating retry/fallback
/// policy in every caller.
enum LyricJSONExtractor {
    static func stripped(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            if let newline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: newline)...])
            }
            if let fence = text.range(of: "```", options: .backwards) {
                text = String(text[..<fence.lowerBound])
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func object(from raw: String) -> String? {
        balanced(in: stripped(raw), opening: "{", closing: "}")
    }

    static func array(from raw: String) -> String? {
        balanced(in: stripped(raw), opening: "[", closing: "]")
    }

    static func payload(from raw: String) -> String {
        object(from: raw) ?? array(from: raw) ?? stripped(raw)
    }

    static func chatContent(from raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            return nil
        }
        if let content = message["content"] as? String {
            return content
        }
        if let parts = message["content"] as? [[String: Any]] {
            let text = parts.compactMap { part -> String? in
                if let text = part["text"] as? String { return text }
                if let text = part["content"] as? String { return text }
                return nil
            }.joined()
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private static func balanced(
        in raw: String,
        opening: Character,
        closing: Character
    ) -> String? {
        guard let start = raw.firstIndex(of: opening) else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < raw.endIndex {
            let character = raw[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == opening {
                depth += 1
            } else if character == closing {
                depth -= 1
                if depth == 0 {
                    return String(raw[start...index])
                }
            }
            index = raw.index(after: index)
        }
        if let end = raw.lastIndex(of: closing), start < end {
            return String(raw[start...end])
        }
        return nil
    }
}

enum LyricProviderCircuit {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var failures: [String: (count: Int, until: Date)] = [:]

    static func isOpen(_ key: String, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let state = failures[key] else { return false }
        if state.until <= now {
            failures.removeValue(forKey: key)
            return false
        }
        return state.count >= 2
    }

    static func recordSuccess(_ key: String) {
        lock.lock()
        failures.removeValue(forKey: key)
        lock.unlock()
    }

    static func recordFailure(_ key: String, now: Date = Date()) {
        lock.lock()
        let previous = failures[key]
        let base = (previous?.until ?? .distantPast) > now ? (previous?.count ?? 0) : 0
        let count = base + 1
        // Remember a single failure long enough to detect a repeat. Two
        // failures open the provider for 45 seconds, then the slate resets.
        let cooldown = count >= 2 ? 45.0 : 60.0
        failures[key] = (count, now.addingTimeInterval(cooldown))
        lock.unlock()
    }

    static func resetForTests() {
        lock.lock()
        failures.removeAll()
        lock.unlock()
    }
}

struct LyricChatTarget: Sendable {
    var endpoint: URL
    var key: String
    var model: String
    var source: String
    var embeddingEndpoint: URL? = nil
    var embeddingModel: String = ""
    var reasoningEffort: String? = nil

    var circuitKey: String { "\(source)|\(model)" }

    var prefersJSONObject: Bool {
        let value = model.lowercased()
        if value.contains("gemma-3-270") || value.contains("gemma-2-2b") {
            return false
        }
        return true
    }
}

enum LyricInferenceRuntime {
    static func completeRadio(
        prompt: String,
        settings: LyricIntelligenceSettings,
        maxTokens: Int = 700
    ) async -> String? {
        for target in radioTargets(settings) {
            if let text = await chat(
                prompt: prompt,
                target: target,
                maxTokens: maxTokens
            ) {
                return text
            }
        }
        if settings.provider == .off { return nil }
        return await complete(
            prompt: prompt,
            settings: settings,
            maxTokens: maxTokens
        )
    }

    static func radioTargets(_ settings: LyricIntelligenceSettings) -> [LyricChatTarget] {
        guard !settings.groqKey.isEmpty,
              let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions") else {
            return []
        }
        return [
            LyricChatTarget(
                endpoint: endpoint,
                key: settings.groqKey,
                model: LyricIntelligenceSettings.radioPrimaryModel,
                source: "groq",
                reasoningEffort: "medium"
            ),
            LyricChatTarget(
                endpoint: endpoint,
                key: settings.groqKey,
                model: LyricIntelligenceSettings.radioFallbackModel,
                source: "groq"
            )
        ]
    }

    static func complete(
        prompt: String,
        settings: LyricIntelligenceSettings,
        maxTokens: Int = 700
    ) async -> String? {
        guard settings.provider != .off else { return nil }
        if let text = await completePrimary(
            prompt: prompt,
            settings: settings,
            maxTokens: maxTokens
        ) {
            return text
        }
        return await completeFallbacks(
            prompt: prompt,
            settings: settings,
            excluding: settings.provider,
            maxTokens: maxTokens
        )
    }

    static func completePrimary(
        prompt: String,
        settings: LyricIntelligenceSettings,
        maxTokens: Int
    ) async -> String? {
        switch settings.provider {
        case .off:
            return nil
        case .onDevice, .applePrivateCloud:
            return await AppleFoundationLyricClient.complete(prompt)
        case .openAI, .openRouter, .groq, .cerebras:
            guard let target = primaryTarget(settings) else { return nil }
            return await chat(prompt: prompt, target: target, maxTokens: maxTokens)
        }
    }

    static func completeFallbacks(
        prompt: String,
        settings: LyricIntelligenceSettings,
        excluding provider: LyricIntelligenceProviderKind,
        maxTokens: Int
    ) async -> String? {
        for target in fallbackTargets(settings, excluding: provider) {
            if let text = await chat(prompt: prompt, target: target, maxTokens: maxTokens) {
                return text
            }
        }
        return nil
    }

    static func chat(
        prompt: String,
        target: LyricChatTarget,
        maxTokens: Int
    ) async -> String? {
        guard !LyricProviderCircuit.isOpen(target.circuitKey) else { return nil }
        if let text = await postChat(
            prompt: prompt,
            target: target,
            maxTokens: maxTokens,
            forceJSONObject: target.prefersJSONObject
        ) {
            LyricProviderCircuit.recordSuccess(target.circuitKey)
            return text
        }
        LyricProviderCircuit.recordFailure(target.circuitKey)
        return nil
    }

    static func repairedJSON(
        from raw: String,
        settings: LyricIntelligenceSettings
    ) async -> String? {
        let snippet = String(LyricJSONExtractor.stripped(raw).prefix(900))
        guard snippet.count >= 8 else { return nil }
        let prompt = """
        Convert this model reply into one valid JSON object. Keep the same fields and meaning. JSON only.

        \(snippet)
        """
        return await completePrimary(
            prompt: prompt,
            settings: settings,
            maxTokens: 500
        )
    }

    static func primaryTarget(_ settings: LyricIntelligenceSettings) -> LyricChatTarget? {
        target(for: settings.provider, settings: settings)
    }

    static func fallbackTargets(
        _ settings: LyricIntelligenceSettings,
        excluding provider: LyricIntelligenceProviderKind
    ) -> [LyricChatTarget] {
        let order: [LyricIntelligenceProviderKind] = [
            .groq, .cerebras, .openRouter, .openAI
        ]
        return order.compactMap { kind in
            guard kind != provider else { return nil }
            return target(for: kind, settings: settings)
        }
    }

    static func target(
        for provider: LyricIntelligenceProviderKind,
        settings: LyricIntelligenceSettings
    ) -> LyricChatTarget? {
        switch provider {
        case .off, .onDevice, .applePrivateCloud:
            return nil
        case .openAI:
            guard !settings.openAIKey.isEmpty,
                  let endpoint = URL(string: "https://api.openai.com/v1/chat/completions") else {
                return nil
            }
            return LyricChatTarget(
                endpoint: endpoint,
                key: settings.openAIKey,
                model: "gpt-4o-mini",
                source: "openai",
                embeddingEndpoint: URL(string: "https://api.openai.com/v1/embeddings"),
                embeddingModel: "text-embedding-3-small"
            )
        case .openRouter:
            guard !settings.openRouterKey.isEmpty,
                  let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions") else {
                return nil
            }
            return LyricChatTarget(
                endpoint: endpoint,
                key: settings.openRouterKey,
                model: settings.openRouterModel,
                source: "openrouter",
                embeddingEndpoint: URL(string: "https://openrouter.ai/api/v1/embeddings"),
                embeddingModel: "openai/text-embedding-3-small"
            )
        case .groq:
            guard !settings.groqKey.isEmpty,
                  let endpoint = URL(string: "https://api.groq.com/openai/v1/chat/completions") else {
                return nil
            }
            return LyricChatTarget(
                endpoint: endpoint,
                key: settings.groqKey,
                model: settings.groqModel,
                source: "groq",
                reasoningEffort: settings.groqModel.lowercased().contains("gpt-oss")
                    || settings.groqModel.lowercased().contains("oss-120")
                    ? "medium"
                    : nil
            )
        case .cerebras:
            guard !settings.cerebrasKey.isEmpty,
                  let endpoint = URL(string: "https://api.cerebras.ai/v1/chat/completions") else {
                return nil
            }
            return LyricChatTarget(
                endpoint: endpoint,
                key: settings.cerebrasKey,
                model: settings.cerebrasModel,
                source: "cerebras"
            )
        }
    }

    static func embedding(
        lyrics: String,
        target: LyricChatTarget
    ) async -> [Float]? {
        guard let endpoint = target.embeddingEndpoint,
              !target.embeddingModel.isEmpty else {
            return nil
        }
        let body: [String: Any] = [
            "model": target.embeddingModel,
            "input": String(LyricTextSampler.sample(lyrics, limit: 4_000))
        ]
        guard let raw = await postJSON(
            url: endpoint,
            key: target.key,
            body: body,
            timeout: 18
        ),
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let items = root["data"] as? [[String: Any]],
              let first = items.first else {
            return nil
        }
        return floatVector(first["embedding"])
    }

    static func floatVector(_ value: Any?) -> [Float]? {
        if let values = value as? [Double] {
            return values.isEmpty ? nil : values.map { Float($0) }
        }
        if let values = value as? [Int] {
            return values.isEmpty ? nil : values.map { Float($0) }
        }
        if let values = value as? [Any] {
            let parsed: [Float] = values.compactMap { item in
                if let value = item as? Double { return Float(value) }
                if let value = item as? Int { return Float(value) }
                if let value = item as? Float { return value }
                return nil
            }
            return parsed.count == values.count && !parsed.isEmpty ? parsed : nil
        }
        return nil
    }

    private static func postChat(
        prompt: String,
        target: LyricChatTarget,
        maxTokens: Int,
        forceJSONObject: Bool
    ) async -> String? {
        var body: [String: Any] = [
            "model": target.model,
            "temperature": 0,
            "max_tokens": maxTokens,
            "messages": [
                [
                    "role": "system",
                    "content": "Return one JSON object only. No markdown, no preamble."
                ],
                ["role": "user", "content": prompt]
            ]
        ]
        if forceJSONObject {
            body["response_format"] = ["type": "json_object"]
        }
        if let effort = target.reasoningEffort, !effort.isEmpty {
            body["reasoning_effort"] = effort
        }
        if let text = await postChatOnce(
            target: target,
            body: body,
            timeout: 22
        ) {
            return text
        }
        if forceJSONObject {
            body.removeValue(forKey: "response_format")
            if let text = await postChatOnce(
                target: target,
                body: body,
                timeout: 22
            ) {
                return text
            }
        }
        body.removeValue(forKey: "max_tokens")
        return await postChatOnce(
            target: target,
            body: body,
            timeout: 22,
            retry: true
        )
    }

    private static func postChatOnce(
        target: LyricChatTarget,
        body: [String: Any],
        timeout: TimeInterval,
        retry: Bool = false
    ) async -> String? {
        if let text = await decodedChat(
            url: target.endpoint,
            key: target.key,
            body: body,
            timeout: timeout
        ) {
            return text
        }
        guard retry else { return nil }
        try? await Task.sleep(for: .milliseconds(350))
        return await decodedChat(
            url: target.endpoint,
            key: target.key,
            body: body,
            timeout: timeout
        )
    }

    private static func decodedChat(
        url: URL,
        key: String,
        body: [String: Any],
        timeout: TimeInterval
    ) async -> String? {
        guard let raw = await postJSON(
            url: url,
            key: key,
            body: body,
            timeout: timeout
        ) else {
            return nil
        }
        let content = LyricJSONExtractor.chatContent(from: raw) ?? raw
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : content
    }

    private static func postJSON(
        url: URL,
        key: String,
        body: [String: Any],
        timeout: TimeInterval
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
        request.timeoutInterval = timeout
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }
}

enum LyricOrderBlend {
    static func combine(
        llmOrder: [String],
        songs: [Song],
        laneScores: [String: Double]
    ) -> [String] {
        guard !llmOrder.isEmpty else {
            return rankedIDs(songs: songs, scores: laneScores)
        }
        let span = max(llmOrder.count - 1, 1)
        var scores: [String: Double] = [:]
        scores.reserveCapacity(songs.count)
        for (rank, id) in llmOrder.enumerated() {
            let llm = 1 - Double(rank) / Double(span)
            scores[id] = llm * 0.76 + (laneScores[id] ?? 0) * 0.24
        }
        for song in songs where scores[song.id] == nil {
            scores[song.id] = (laneScores[song.id] ?? 0) * 0.24
        }
        return rankedIDs(songs: songs, scores: scores)
    }

    private static func rankedIDs(
        songs: [Song],
        scores: [String: Double]
    ) -> [String] {
        var ranked: [(String, Double)] = []
        ranked.reserveCapacity(songs.count)
        for song in songs {
            ranked.append((song.id, scores[song.id] ?? 0))
        }
        ranked.sort { lhs, rhs in
            if lhs.1 == rhs.1 { return lhs.0 < rhs.0 }
            return lhs.1 > rhs.1
        }
        return ranked.map(\.0)
    }
}
