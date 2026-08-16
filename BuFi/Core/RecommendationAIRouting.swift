import Foundation

/// Resolves the recommendation-only LLM route without coupling it to lyric
/// analysis. A configured Google AI provider should not keep an older Groq
/// radio selection in front of Gemini.
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
        let selected = settings.radioModel
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !geminiKey.isEmpty else {
            // If Google AI is selected but the runtime did not receive a key,
            // make that distinction visible. Never print the secret itself.
            if settings.provider == .googleAI
                || selected.lowercased().contains("gemini") {
                RecommendationDiagnostics.record(
                    kind: .llm,
                    level: .error,
                    title: String(localized: "Gemini 키를 추천 엔진에서 읽지 못했습니다"),
                    detail: "google-ai keychain secret unavailable"
                )
            }
            return resolved
        }

        // `RadioModelOption` still carries the old Gemini aliases so that old
        // preferences migrate cleanly, while the HTTP runtime canonicalizes
        // them to 3.6 Flash / 3.5 Flash-Lite. If a new canonical model string
        // is stored directly, feeding it to the old enum would incorrectly
        // resolve to Groq. Convert the current Gemini choice back to the known
        // alias here, then let LyricInferenceRuntime canonicalize it at the
        // network boundary.
        let preferredGemini = LyricInferenceRuntime.canonicalCloudModel(
            settings.geminiModel
        )
        let geminiRadioAlias: String
        if preferredGemini == "gemini-3.5-flash-lite" {
            geminiRadioAlias = LyricIntelligenceSettings.geminiFlashLiteModel
        } else {
            geminiRadioAlias = LyricIntelligenceSettings.geminiFlashModel
        }

        // Selecting Google AI Studio is explicit intent to use Gemini. An old
        // Groq radio preference (for example OSS 20B from earlier testing) must
        // not silently override that provider choice after a Gemini key has
        // been saved. This is the case that made the algorithm appear to ignore
        // a valid Gemini key.
        if settings.provider == .googleAI {
            if LyricInferenceRuntime.canonicalCloudModel(selected)
                != preferredGemini {
                RecommendationDiagnostics.record(
                    kind: .llm,
                    level: .info,
                    title: String(localized: "Gemini를 추천 기본 모델로 사용합니다"),
                    detail: "google-ai key loaded · \(preferredGemini)"
                )
            }
            resolved.radioModel = geminiRadioAlias
            return resolved
        }

        // A radio model that is already Gemini stays Gemini even if it was
        // saved under the current canonical ID rather than the legacy alias.
        if selected.lowercased().contains("gemini") {
            resolved.radioModel = geminiRadioAlias
            return resolved
        }

        let hasExplicitRadioSelection = defaults.object(
            forKey: LyricIntelligenceSettings.radioModelKey
        ) != nil
        let legacyDefault = selected.isEmpty
            || selected == LyricIntelligenceSettings.defaultRadioModel

        // For an untouched/default radio preference, adding a Gemini key makes
        // Gemini the useful primary and leaves Groq as fallback. A genuinely
        // explicit non-Gemini radio selection is preserved when Google AI is
        // not the selected provider.
        guard legacyDefault, !hasExplicitRadioSelection else {
            return resolved
        }

        resolved.radioModel = geminiRadioAlias
        return resolved
    }
}
