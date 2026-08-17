import Foundation

extension RadioLLMDirector {
    /// Keep the call-site label used by AppModel while forwarding to the
    /// director's existing `settings:` entry point. This preserves the already
    /// loaded settings value and avoids a second keychain/settings load.
    static func continueRadio(
        seed: Song,
        excludedIDs: Set<String>,
        snapshot: HomeSnapshot,
        behavior: RecommendationBehaviorSnapshot,
        lyricIndex: LyricSignatureIndex,
        weights: RecommendationWeights,
        loadedSettings: LyricIntelligenceSettings,
        onPick: (@Sendable (Song) async -> Void)? = nil
    ) async -> [Song] {
        var settings = RecommendationAIRouting.resolve(loadedSettings)
        let selected = LyricInferenceRuntime.canonicalCloudModel(settings.radioModel)
        // Radio runtime is Gemini-only now. Keep an explicitly selected Gemini
        // Flash/Flash-Lite model, but normalize stale Groq/Gemma/OpenRouter
        // preferences to Flash-Lite so prompt-family selection and execution
        // cannot disagree about which model is actually programming the set.
        if !selected.lowercased().contains("gemini") {
            settings.radioModel = LyricIntelligenceSettings.geminiFlashLiteModel
        }
        return await continueRadio(
            seed: seed,
            excludedIDs: excludedIDs,
            snapshot: snapshot,
            behavior: behavior,
            lyricIndex: lyricIndex,
            weights: weights,
            settings: settings,
            onPick: onPick
        )
    }
}
