import Foundation

// The pre-AI AppModel supplied autoplay continuations as one completed batch.
// Modern AudioEngine can additionally stream each accepted pick into the queue.
// Keep the newer player/runtime API and bridge the old provider shape without
// reintroducing any AI recommendation or analysis dependency.
extension AudioEngine {
    func configure(
        client: OpenSubsonicClient?,
        historySession: AccountSessionToken?,
        songFavoriteMutationHandler: (@MainActor (Song) async -> Bool)?,
        autoplayContinuationProvider:
            @escaping @MainActor (Song, Set<String>) async -> [Song]
    ) {
        configure(
            client: client,
            historySession: historySession,
            songFavoriteMutationHandler: songFavoriteMutationHandler,
            autoplayContinuationProvider: { seed, excludedIDs, _ in
                await autoplayContinuationProvider(seed, excludedIDs)
            }
        )
    }
}
