import Foundation

/// Resolves the recommendation-only LLM route without coupling it to lyric
/// analysis. A legacy/default Groq radio value should not keep Gemini dormant
/// after the user adds a Gemini key.
enum RecommendationAIRouting {
    static func resolve(
        _ settings: LyricIntelligenceSettings,
        defaults: UserDefaults = .standard
    ) -> LyricIntelligenceSettings {
        var resolved = settings
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
