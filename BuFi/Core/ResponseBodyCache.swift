import Foundation

/// Actor-owned response-body cache with O(1) recency updates. Eviction scans
/// only when a configured bound is exceeded, keeping the common cache-hit path
/// independent of the number of cached endpoints.
struct ResponseBodyCache: Sendable {
    private struct Entry: Sendable {
        let data: Data
        let storedAt: ContinuousClock.Instant
        var accessOrdinal: UInt64
    }

    let countLimit: Int
    let byteLimit: Int
    let maximumEntryBytes: Int

    private var entries: [String: Entry] = [:]
    private var accessClock: UInt64 = 0

    private(set) var byteCount = 0
    var count: Int { entries.count }

    init(
        countLimit: Int,
        byteLimit: Int,
        maximumEntryBytes: Int
    ) {
        self.countLimit = max(0, countLimit)
        self.byteLimit = max(0, byteLimit)
        self.maximumEntryBytes = max(0, maximumEntryBytes)
    }

    mutating func value(
        for key: String,
        maximumAge: TimeInterval,
        now: ContinuousClock.Instant = ContinuousClock().now
    ) -> Data? {
        guard var entry = entries[key] else { return nil }
        guard maximumAge > 0,
              entry.storedAt.duration(to: now) <= .seconds(maximumAge) else {
            removeValue(for: key)
            return nil
        }

        entry.accessOrdinal = nextAccessOrdinal()
        entries[key] = entry
        return entry.data
    }

    mutating func insert(
        _ data: Data,
        for key: String,
        now: ContinuousClock.Instant = ContinuousClock().now
    ) {
        // A response that cannot be cached must still invalidate an older body
        // under the same key; otherwise a later read can resurrect stale data.
        removeValue(for: key)
        guard countLimit > 0,
              byteLimit > 0,
              data.count <= maximumEntryBytes,
              data.count <= byteLimit else {
            return
        }

        entries[key] = Entry(
            data: data,
            storedAt: now,
            accessOrdinal: nextAccessOrdinal()
        )
        byteCount += data.count
        evictIfNeeded()
    }

    mutating func removeAll(keepingCapacity: Bool = false) {
        entries.removeAll(keepingCapacity: keepingCapacity)
        byteCount = 0
        accessClock = 0
    }

    private mutating func removeValue(for key: String) {
        guard let removed = entries.removeValue(forKey: key) else { return }
        byteCount = max(0, byteCount - removed.data.count)
    }

    private mutating func evictIfNeeded() {
        while entries.count > countLimit || byteCount > byteLimit {
            guard let leastRecentlyUsed = entries.min(by: {
                $0.value.accessOrdinal < $1.value.accessOrdinal
            })?.key else {
                break
            }
            removeValue(for: leastRecentlyUsed)
        }
    }

    private mutating func nextAccessOrdinal() -> UInt64 {
        accessClock &+= 1
        return accessClock
    }
}
