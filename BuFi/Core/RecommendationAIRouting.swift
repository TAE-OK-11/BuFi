import Foundation

/// Resolves the recommendation-only LLM route without coupling it to lyric
/// analysis. A legacy/default Groq radio value should not keep Gemini dormant
/// after the user adds a Gemini key.
enum RecommendationAIRouting {
    static let openRouterGemma4FreeModel = "google/gemma-4-31b-it:free"

    static func resolve(
        _ settings: LyricIntelligenceSettings,
        defaults: UserDefaults = .standard
    ) -> LyricIntelligenceSettings {
        var resolved = settings

        // Recommendation calls already de-duplicate each model and try it at
        // most once per route. Do not let cancellation/timeouts from an older
        // Home/radio task poison the next recommendation request for 45s. The
        // shared circuit remains useful for bulk lyric-analysis paths, but a
        // fresh recommendation request must be allowed to reach the provider
        // so its real HTTP/transport result can be observed.
        LyricProviderCircuit.resetForTests()

        // Recommendation fallback used to inherit the very small Gemma 3
        // default. Upgrade only that legacy/default value to OpenRouter's
        // Gemma 4 31B free endpoint; preserve any genuinely custom model.
        let openRouterKey = settings.openRouterKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let openRouterModel = settings.openRouterModel
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !openRouterKey.isEmpty,
           openRouterModel.isEmpty
            || openRouterModel == LyricIntelligenceSettings.defaultOpenRouterModel
            || openRouterModel == "google/gemma-3-270m-it" {
            resolved.openRouterModel = openRouterGemma4FreeModel
        }

        let geminiKey = settings.geminiKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !geminiKey.isEmpty else { return resolved }

        let selected = settings.radioModel
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasExplicitRadioSelection = defaults.object(
            forKey: LyricIntelligenceSettings.radioModelKey
        ) != nil
        let legacyDefault = selected.isEmpty
            || selected == LyricIntelligenceSettings.defaultRadioModel

        // New/default installs used to inherit Groq's GPT-OSS 120B even when
        // Gemini was the only newly configured recommendation provider. Prefer
        // Gemini in that implicit/default state. Also migrate the old default
        // while Google AI is the selected lyric provider. Any non-default radio
        // model remains an explicit user choice and is left untouched.
        guard legacyDefault,
              !hasExplicitRadioSelection || settings.provider == .googleAI else {
            return resolved
        }

        let preferredGemini = settings.geminiModel
            .trimmingCharacters(in: .whitespacesAndNewlines)
        resolved.radioModel = preferredGemini.isEmpty
            ? LyricIntelligenceSettings.defaultGeminiModel
            : preferredGemini
        return resolved
    }
}
