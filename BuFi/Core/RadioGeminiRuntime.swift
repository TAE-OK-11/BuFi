import Foundation

/// Recommendation-only Gemini route. Radio intentionally does not fall back to
/// Groq, OpenRouter, or Apple Foundation Models: the local BuFi algorithm owns
/// candidate generation and Gemini only performs the final 30-to-8 program.
enum RadioGeminiRuntime {
    static func stream(
        prompt: String,
        settings: LyricIntelligenceSettings,
        maxTokens: Int,
        onDelta: @escaping @Sendable (String) async -> Void
    ) async -> String? {
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
                  target.source == "google-ai" else {
                continue
            }
            switch await LyricInferenceRuntime.radioAttempt(
                prompt: prompt,
                target: target,
                maxTokens: maxTokens,
                onDelta: onDelta
            ) {
            case .text(let text):
                return text
            case .rateLimited:
                failures.append("\(canonical):429")
            case .failed:
                failures.append(canonical)
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
}
