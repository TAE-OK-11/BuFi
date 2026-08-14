from pathlib import Path

path = Path("BuFi/Core/OpenSubsonicClient.swift")
text = path.read_text()


def replace_once(old: str, new: str, label: str) -> None:
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected 1 match, found {count}")
    text = text.replace(old, new, 1)
    print(f"patched: {label}")


def replace_count(old: str, new: str, expected: int, label: str) -> None:
    global text
    count = text.count(old)
    if count != expected:
        raise SystemExit(f"{label}: expected {expected} matches, found {count}")
    text = text.replace(old, new)
    print(f"patched: {label} ({count})")


# Replace existing finish sites first. The helper inserted below deliberately
# retains the one real cacheRevisionState.finish call.
replace_count(
    "cacheRevisionState.finish(impact)",
    "finishMutation(impact)",
    4,
    "route mutation completion through waiter-aware helper",
)

replace_once(
    '''    private struct InFlightReadRequest {
        let token: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<HTTPResponseData, Error>]
    }
''',
    '''    private struct InFlightReadRequest {
        let token: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<HTTPResponseData, Error>]
    }

    private struct MutationWaiter {
        let dependencies: Set<OpenSubsonicCacheDependency>
        let continuation: CheckedContinuation<Void, Error>
    }

    private var mutationWaiters: [UUID: MutationWaiter] = [:]
''',
    "add mutation waiter state",
)

replace_once(
    '''                while cacheRevisionState.hasMutation(
                    affecting: cachePolicy.dependencies
                ) {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(20))
                }
''',
    '''                try await waitForRelevantMutations(
                    affecting: cachePolicy.dependencies
                )
''',
    "replace 20ms mutation polling",
)

finish_read = '''    private func finishReadRequest(
        key: ReadRequestKey,
        token: UUID,
        result: Result<HTTPResponseData, Error>
    ) {
        guard let request = inFlightReadRequests[key],
              request.token == token else {
            return
        }
        inFlightReadRequests[key] = nil
        for continuation in request.waiters.values {
            switch result {
            case .success(let response):
                continuation.resume(returning: response)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }
'''

waiter_helpers = finish_read + '''
    private func waitForRelevantMutations(
        affecting dependencies: Set<OpenSubsonicCacheDependency>
    ) async throws {
        try Task.checkCancellation()
        guard cacheRevisionState.hasMutation(affecting: dependencies) else {
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                registerMutationWaiter(
                    continuation,
                    id: waiterID,
                    dependencies: dependencies
                )
            }
        } onCancel: {
            Task {
                await self.cancelMutationWaiter(waiterID)
            }
        }
        try Task.checkCancellation()
    }

    private func registerMutationWaiter(
        _ continuation: CheckedContinuation<Void, Error>,
        id: UUID,
        dependencies: Set<OpenSubsonicCacheDependency>
    ) {
        guard !Task.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }
        guard cacheRevisionState.hasMutation(affecting: dependencies) else {
            continuation.resume(returning: ())
            return
        }
        mutationWaiters[id] = MutationWaiter(
            dependencies: dependencies,
            continuation: continuation
        )
    }

    private func cancelMutationWaiter(_ id: UUID) {
        guard let waiter = mutationWaiters.removeValue(forKey: id) else {
            return
        }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func finishMutation(_ impact: OpenSubsonicMutationImpact) {
        cacheRevisionState.finish(impact)
        guard !mutationWaiters.isEmpty else { return }

        let readyIDs = mutationWaiters.compactMap { id, waiter in
            cacheRevisionState.hasMutation(affecting: waiter.dependencies)
                ? nil
                : id
        }
        for id in readyIDs {
            mutationWaiters.removeValue(forKey: id)?
                .continuation
                .resume(returning: ())
        }
    }
'''

replace_once(
    finish_read,
    waiter_helpers,
    "add cancellation-aware mutation waiters",
)

path.write_text(text)
