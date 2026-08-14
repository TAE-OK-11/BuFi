import Foundation

/// Exact identity for one coalescible offline transfer.
///
/// Account scope and song identity remain separate values instead of being
/// flattened into a delimiter-bearing String. This keeps cancellation and
/// shared-transfer ownership collision-safe under Swift 6.
struct OfflineDownloadKey: Hashable, Sendable {
    let accountScope: String
    let songID: String
}

/// Exact identity for one in-flight artwork palette computation.
///
/// The generation is part of the key so work from a cleared or replaced
/// account generation cannot be joined by a newer request.
struct ArtworkPaletteRequestKey: Hashable, Sendable {
    let accountScope: String
    let cacheKey: String
    let generation: UInt64
}

/// Session-local monotonic recency for persistent offline LRU timestamps.
///
/// `Date` is retained on disk for cross-launch ordering, but wall-clock
/// rollback must never make a newly accessed file look older than a previous
/// access from the same process.
struct OfflineAccessRecency: Sendable {
    private(set) var lastIssued = Date.distantPast

    mutating func seed(lastAccess: Date?, now: Date = Date()) {
        guard let lastAccess else {
            lastIssued = .distantPast
            return
        }
        lastIssued = min(lastAccess, now)
    }

    mutating func next(now: Date = Date(), after previous: Date? = nil) -> Date {
        let boundedPrevious = min(previous ?? .distantPast, now)
        let baseline = max(lastIssued, boundedPrevious)
        let value = max(now, baseline.addingTimeInterval(0.001))
        lastIssued = value
        return value
    }
}

/// Shared freshness rule for persisted cache snapshots.
///
/// A small future tolerance handles harmless clock skew, while snapshots far
/// in the future are rejected instead of becoming effectively immortal after
/// a device clock correction.
enum CacheFreshnessPolicy {
    static func isFresh(
        savedAt: Date,
        now: Date = Date(),
        maximumAge: TimeInterval,
        futureTolerance: TimeInterval = 5 * 60
    ) -> Bool {
        guard maximumAge >= 0, futureTolerance >= 0 else { return false }
        let age = now.timeIntervalSince(savedAt)
        return age >= -futureTolerance && age <= maximumAge
    }
}
