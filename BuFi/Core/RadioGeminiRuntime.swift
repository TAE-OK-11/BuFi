import Foundation

private struct RadioGeminiHistoryTurn: Sendable {
    let role: String
    let content: String
}

/// Keeps one lightweight Gemini chat thread for the active autoplay queue.
/// The API itself is stateless, so a "same conversation" means replaying the
/// previous user/assistant turn as message history. Candidate ids are no longer
/// exposed to Gemini; artist/title anchors reconnect the next playback chapter.
private actor RadioGeminiConversationMemory {
    static let shared = RadioGeminiConversationMemory()

    private struct TrackAnchor: Sendable {
        let artist: String
        let album: String
        let title: String
    }

    private struct Session: Sendable {
        let id: UUID
        var turns: [RadioGeminiHistoryTurn]
        var anchors: [TrackAnchor]
        var updatedAt: Date
    }

    private var active: Session?
    private let lifetime: TimeInterval = 2 * 60 * 60
    private let previousPromptLimit = 24_000

    func prepare(for prompt: String) -> (id: UUID, history: [RadioGeminiHistoryTurn]) {
        let now = Date()
        if let session = active,
           now.timeIntervalSince(session.updatedAt) <= lifetime,
           !session.anchors.isEmpty,
           session.anchors.contains(where: { anchor in
               prompt.localizedCaseInsensitiveContains(anchor.artist)
                   && prompt.localizedCaseInsensitiveContains(anchor.title)
           }) {
            return (session.id, session.turns)
        }

        let session = Session(
            id: UUID(),
            turns: [],
            anchors: [],
            updatedAt: now
        )
        active = session
        return (session.id, [])
    }

    func commit(id: UUID, prompt: String, response: String) {
        guard var session = active, session.id == id else { return }
        // One prior full turn is enough to preserve the station's decisions and
        // path without letting repeated candidate lists grow without bound.
        let carriedPrompt = prompt.count <= previousPromptLimit
            ? prompt
            : String(prompt.prefix(previousPromptLimit))
        session.turns = [
            RadioGeminiHistoryTurn(role: "user", content: carriedPrompt),
            RadioGeminiHistoryTurn(role: "assistant", content: response)
        ]
        session.anchors = Self.anchors(from: response)
        session.updatedAt = Date()
        active = session
    }

    private static func anchors(from raw: String) -> [TrackAnchor] {
        guard let json = LyricJSONExtractor.object(from: raw),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              let tracks = dictionary["tracks"] as? [[String: Any]] else {
            return []
        }
        return tracks.prefix(20).compactMap { track in
            guard let artist = track["artist"] as? String,
                  let title = track["title"] as? String,
                  !artist.isEmpty,
                  !title.isEmpty else {
                return nil
            }
            return TrackAnchor(
                artist: artist,
                album: track["album"] as? String ?? "",
                title: title
            )
        }
    }
}

/// Recommendation-only Gemini route. Radio intentionally does not fall back to
/// Groq, OpenRouter, or Apple Foundation Models. Last.fm/ListenBrainz discover
/// records and Gemini alone chooses and sequences the final radio chapter.
enum RadioGeminiRuntime {
    private enum Attempt {
        case text(String)
        case rateLimited(String)
        case failed(String)
    }

    static func stream(
        prompt: String,
        settings: LyricIntelligenceSettings,
        maxTokens: Int,
        onDelta: @escaping @Sendable (String) async -> Void
    ) async -> String? {
        let conversation = await RadioGeminiConversationMemory.shared.prepare(
            for: prompt
        )
        var models: [String] = []
        let selected = settings.radioModel
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let canonicalSelected = LyricInferenceRuntime.canonicalCloudModel(selected)
        if canonicalSelected.lowercased().contains("gemini") {
            models.append(selected)
        }
        models.append(LyricIntelligenceSettings.geminiFlashLiteModel)
        models.append(LyricIntelligenceSettings.geminiFlashModel)

        var seen = Set<String>()
        var failures: [String] = []
        for model in models {
            let canonical = LyricInferenceRuntime.canonicalCloudModel(model)
            guard seen.insert(canonical).inserted,
                  let target = LyricInferenceRuntime.radioTarget(
                    model: model,
                    settings: settings
                  ),
                  target.source == "google-ai",
                  !LyricProviderCircuit.isOpen(target.circuitKey) else {
                continue
            }
            let tokens = LyricInferenceRuntime.radioTokenBudget(
                for: target.model,
                requested: maxTokens
            )
            let attempt = await streamGemini(
                prompt: prompt,
                history: conversation.history,
                target: target,
                maxTokens: tokens,
                onDelta: onDelta
            )
            switch attempt {
            case .text(let text):
                LyricProviderCircuit.recordSuccess(target.circuitKey)
                await RadioGeminiConversationMemory.shared.commit(
                    id: conversation.id,
                    prompt: prompt,
                    response: text
                )
                return text
            case .rateLimited(let detail):
                LyricProviderCircuit.recordFailure(target.circuitKey)
                failures.append("\(canonical):429 \(detail)")
                continue
            case .failed:
                // Streaming is the low-latency path. If the provider closes a
                // stream early, retry once non-streaming with the same message
                // history rather than dropping the conversation context.
                switch await completeGemini(
                    prompt: prompt,
                    history: conversation.history,
                    target: target,
                    maxTokens: tokens
                ) {
                case .text(let text):
                    LyricProviderCircuit.recordSuccess(target.circuitKey)
                    await onDelta(text)
                    await RadioGeminiConversationMemory.shared.commit(
                        id: conversation.id,
                        prompt: prompt,
                        response: text
                    )
                    return text
                case .rateLimited(let detail):
                    LyricProviderCircuit.recordFailure(target.circuitKey)
                    failures.append("\(canonical):429 \(detail)")
                case .failed(let detail):
                    LyricProviderCircuit.recordFailure(target.circuitKey)
                    failures.append("\(canonical) \(detail)")
                }
            }
        }

        RecommendationDiagnostics.record(
            kind: .llm,
            level: .error,
            title: String(localized: "Gemini 라디오 호출이 실패했습니다"),
            detail: failures.isEmpty
                ? "google-ai key unavailable"
                : failures.joined(separator: " → ")
        )
        return nil
    }

    private static func messages(
        prompt: String,
        history: [RadioGeminiHistoryTurn]
    ) -> [[String: Any]] {
        var result: [[String: Any]] = [[
            "role": "system",
            "content": "Continue the same personal-radio conversation when history is present. Return exactly one JSON object with a tracks array. Select only exact artist/album/title tuples from the supplied candidate list and never invent songs."
        ]]
        result.append(contentsOf: history.map {
            ["role": $0.role, "content": $0.content]
        })
        result.append(["role": "user", "content": prompt])
        return result
    }

    private static func requestBody(
        prompt: String,
        history: [RadioGeminiHistoryTurn],
        target: LyricChatTarget,
        maxTokens: Int,
        stream: Bool
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": target.model,
            "temperature": 0.18,
            "max_tokens": maxTokens,
            "messages": messages(prompt: prompt, history: history)
        ]
        if stream { body["stream"] = true }
        return body
    }

    private static func streamGemini(
        prompt: String,
        history: [RadioGeminiHistoryTurn],
        target: LyricChatTarget,
        maxTokens: Int,
        onDelta: @escaping @Sendable (String) async -> Void
    ) async -> Attempt {
        guard target.endpoint.scheme?.lowercased() == "https",
              let payload = try? JSONSerialization.data(
                withJSONObject: requestBody(
                    prompt: prompt,
                    history: history,
                    target: target,
                    maxTokens: maxTokens,
                    stream: true
                )
              ) else {
            return .failed("invalid request")
        }
        var request = URLRequest(url: target.endpoint)
        ModernNetworkPolicy.prepareExternalAPIRequest(
            &request,
            acceptsZstandard: false
        )
        request.httpMethod = "POST"
        request.httpBody = payload
        applyHeaders(&request, key: target.key)
        request.timeoutInterval = max(35, target.timeout)

        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                let snippet = await httpSnippet(from: bytes)
                return status == 429
                    ? .rateLimited(snippet)
                    : .failed("HTTP \(status) \(snippet)")
            }
            var assembled = ""
            for try await line in bytes.lines {
                if Task.isCancelled { return .failed("cancelled") }
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("data:") else { continue }
                let payload = trimmed.dropFirst(5)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if payload == "[DONE]" { break }
                guard let piece = streamDelta(from: payload), !piece.isEmpty else {
                    continue
                }
                assembled += piece
                await onDelta(assembled)
            }
            let text = assembled.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? .failed("empty stream") : .text(assembled)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func completeGemini(
        prompt: String,
        history: [RadioGeminiHistoryTurn],
        target: LyricChatTarget,
        maxTokens: Int
    ) async -> Attempt {
        guard target.endpoint.scheme?.lowercased() == "https",
              let payload = try? JSONSerialization.data(
                withJSONObject: requestBody(
                    prompt: prompt,
                    history: history,
                    target: target,
                    maxTokens: maxTokens,
                    stream: false
                )
              ) else {
            return .failed("invalid request")
        }
        var request = URLRequest(url: target.endpoint)
        ModernNetworkPolicy.prepareExternalAPIRequest(
            &request,
            acceptsZstandard: false
        )
        request.httpMethod = "POST"
        request.httpBody = payload
        applyHeaders(&request, key: target.key)
        request.timeoutInterval = max(35, target.timeout)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let raw = String(data: data, encoding: .utf8) ?? ""
            guard (200..<300).contains(status) else {
                let snippet = compact(raw)
                return status == 429
                    ? .rateLimited(snippet)
                    : .failed("HTTP \(status) \(snippet)")
            }
            let content = LyricJSONExtractor.chatContent(from: raw) ?? raw
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? .failed("empty response") : .text(content)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static func streamDelta(from raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first else {
            return nil
        }
        if let delta = first["delta"] as? [String: Any],
           let content = streamText(delta["content"]) {
            return content
        }
        if let message = first["message"] as? [String: Any],
           let content = streamText(message["content"]) {
            return content
        }
        return nil
    }

    private static func streamText(_ value: Any?) -> String? {
        if let text = value as? String {
            return text.isEmpty ? nil : text
        }
        if let parts = value as? [[String: Any]] {
            let text = parts.compactMap { part -> String? in
                if let text = part["text"] as? String { return text }
                if let text = part["content"] as? String { return text }
                return nil
            }.joined()
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private static func applyHeaders(_ request: inout URLRequest, key: String) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
    }

    private static func httpSnippet(from bytes: URLSession.AsyncBytes) async -> String {
        var value = ""
        do {
            for try await line in bytes.lines {
                value += line
                if value.count >= 240 { break }
            }
        } catch {
            if value.isEmpty { return error.localizedDescription }
        }
        return compact(value)
    }

    private static func compact(_ raw: String) -> String {
        String(
            raw.replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(240)
        )
    }
}
