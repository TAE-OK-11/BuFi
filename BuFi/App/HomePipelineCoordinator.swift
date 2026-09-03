import Foundation

/// Coordinates the post-network home refresh pipeline so every ingress path
/// (manual refresh, automatic sync, cached preparation) follows the same
/// prepare → publish → persist → follow-up ordering.
@MainActor
enum HomePipelineCoordinator {
    enum Outcome: Sendable {
        case published
        case deferredForStarMutations
        case aborted
    }

    static func completeRefreshLoad(
        on model: AppModel,
        loadResult: HomeLoadResult,
        needsFullRefresh: Bool,
        generation: Int,
        client: OpenSubsonicClient,
        revision: Int
    ) async -> Outcome {
        guard generation == model.pipelineSessionGeneration,
              model.pipelineClient === client else {
            return .aborted
        }
        guard revision == model.pipelineHomeRevision else { return .aborted }
        guard !model.pipelineHasPendingStarRequests else {
            return .deferredForStarMutations
        }

        let snapshot = await model.pipelinePreparedHomeSnapshot(loadResult.snapshot)
        guard generation == model.pipelineSessionGeneration,
              model.pipelineClient === client else {
            return .aborted
        }
        guard revision == model.pipelineHomeRevision else { return .aborted }
        guard !model.pipelineHasPendingStarRequests else {
            return .deferredForStarMutations
        }

        if needsFullRefresh {
            model.pipelineRecordFullRefresh()
        }
        model.pipelineReconcileFavoriteStates(
            in: snapshot,
            authoritative: loadResult.hasAuthoritativeStarredState
        )
        let resolvedSnapshot = model.pipelineApplyingFavoriteOverrides(to: snapshot)
        let snapshotChanged = model.pipelinePublishHome(resolvedSnapshot)

        let saveNow = model.pipelineRuntimeClock.now
        let snapshotSaveIsDue = model.pipelineLastHomeSnapshotSave.map {
            $0.duration(to: saveNow) >= .seconds(3_600)
        } ?? true
        if snapshotChanged || snapshotSaveIsDue {
            let accountScope = AccountScope.identifier(for: client.credentials)
            await HomeSnapshotStore.shared.save(
                resolvedSnapshot,
                accountScope: accountScope
            )
            guard generation == model.pipelineSessionGeneration,
                  model.pipelineClient === client else {
                return .aborted
            }
            model.pipelineRecordHomeSnapshotSave(at: saveNow)
        }

        model.pipelineScheduleLibraryCatalogRefresh(snapshot: resolvedSnapshot)
        model.pipelineLastSuccessfulSyncDate = Date()

        if needsFullRefresh {
            model.pipelineScheduleExternalRecommendationRefresh(
                client: client,
                generation: generation
            )
        }

        return .published
    }
}
