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
        let settings = RecommendationAIRouting.resolve(loadedSettings)
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
