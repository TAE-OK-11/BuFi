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
        let canonicalSelected = LyricInferenceRuntime.canonicalCloudModel(selected)

        // A model picked explicitly in the recommendation-model menu owns the
        // recommendation route. In particular, do not replace Flash-Lite with
        // the separate lyric-analysis Gemini model just because Google AI is
        // the configured lyric provider.
        switch canonicalSelected.lowercased() {
        case "gemini-3.6-flash":
            resolved.radioModel = LyricIntelligenceSettings.geminiFlashModel
            return resolved
        case "gemini-3.5-flash-lite":
            resolved.radioModel = LyricIntelligenceSettings.geminiFlashLiteModel
            return resolved
        default:
            break
        }

        // These are explicit recommendation-engine choices with their own
        // provider routing. Do not rewrite them just because lyric analysis is
        // currently configured for Google AI Studio.
        if let explicit = RadioModelOption(rawValue: selected) {
            switch explicit {
            case .googleGemma431, .googleGemma426, .openRouterNemotron35Lightning:
                return resolved
            default:
                break
            }
        }

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

        // The lyric-analysis Gemini model is only an automatic recommendation
        // default. It must not override an explicit recommendation-model pick.
        let preferredGemini = LyricInferenceRuntime.canonicalCloudModel(
            settings.geminiModel
        )
        let geminiRadioAlias: String
        if preferredGemini == "gemini-3.5-flash-lite" {
            geminiRadioAlias = LyricIntelligenceSettings.geminiFlashLiteModel
        } else {
            geminiRadioAlias = LyricIntelligenceSettings.geminiFlashModel
        }

        // Selecting Google AI Studio is explicit intent to use Google AI when
        // no Google recommendation model was picked directly. An old Groq
        // preference must not silently override a valid Gemini key.
        if settings.provider == .googleAI {
            if canonicalSelected != preferredGemini {
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
