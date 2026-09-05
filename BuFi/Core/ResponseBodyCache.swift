import Foundation

/// Actor-owned response-body cache with O(1) recency updates. Eviction scans
/// only when a configured bound is exceeded, keeping the common cache-hit path
/// independent of the number of cached endpoints.
struct ResponseBodyCache: Sendable {
    struct Validators: Equatable, Sendable {
        let entityTag: String?
        let lastModified: String?

        static let none = Validators(entityTag: nil, lastModified: nil)

        var isEmpty: Bool {
            entityTag == nil && lastModified == nil
        }

        func merging(_ newer: Validators) -> Validators {
            Validators(
                entityTag: newer.entityTag ?? entityTag,
                lastModified: newer.lastModified ?? lastModified
            )
        }
    }

    struct Value: Equatable, Sendable {
        let data: Data
        let storedAt: ContinuousClock.Instant
        let validators: Validators
        let identity: UUID
    }

    enum Lookup: Equatable, Sendable {
        case fresh(Value)
        case stale(Value)
        case miss
    }

    private struct Entry: Sendable {
        let data: Data
        let storedAt: ContinuousClock.Instant
        let validators: Validators
        let identity: UUID
        let dependencies: Set<OpenSubsonicCacheDependency>
        var accessOrdinal: UInt64

        var value: Value {
            Value(
                data: data,
                storedAt: storedAt,
                validators: validators,
                identity: identity
            )
        }
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
        if case .fresh(let value) = lookup(
            for: key,
            maximumAge: maximumAge,
            staleGrace: 0,
            now: now
        ) {
            return value.data
        }
        return nil
    }

    mutating func lookup(
        for key: String,
        maximumAge: TimeInterval,
        staleGrace: TimeInterval,
        now: ContinuousClock.Instant = ContinuousClock().now
    ) -> Lookup {
        guard var entry = entries[key] else { return .miss }
        let age = entry.storedAt.duration(to: now)
        if maximumAge > 0, age <= .seconds(maximumAge) {
            entry.accessOrdinal = nextAccessOrdinal()
            entries[key] = entry
            return .fresh(entry.value)
        }
        if staleGrace > 0, age <= .seconds(maximumAge + staleGrace) {
            entry.accessOrdinal = nextAccessOrdinal()
            entries[key] = entry
            return .stale(entry.value)
        }
        removeValue(for: key)
        return .miss
    }

    mutating func insert(
        _ data: Data,
        for key: String,
        validators: Validators = .none,
        identity: UUID = UUID(),
        dependencies: Set<OpenSubsonicCacheDependency> = [],
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
            validators: validators,
            identity: identity,
            dependencies: dependencies,
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

    mutating func removeAll(
        affecting dependencies: Set<OpenSubsonicCacheDependency>
    ) {
        guard !dependencies.isEmpty else { return }
        let invalidKeys = entries.compactMap { key, entry in
            entry.dependencies.isDisjoint(with: dependencies) ? nil : key
        }
        for key in invalidKeys {
            removeValue(for: key)
        }
    }

    private mutating func removeValue(for key: String) {
        guard let removed = entries.removeValue(forKey: key) else { return }
        byteCount = max(0, byteCount - removed.data.count)
    }

    private mutating func evictIfNeeded() {
        while entries.count > countLimit || byteCount > byteLimit {
            guard let victim = entries.min(
                by: { $0.value.accessOrdinal < $1.value.accessOrdinal }
            )?.key else {
                break
            }
            removeValue(for: victim)
        }
    }

    mutating func trim(keepFraction: Double) {
        let fraction = min(1, max(0, keepFraction))
        let targetCount = max(
            0,
            Int((Double(entries.count) * fraction).rounded(.down))
        )
        let removeCount = entries.count - targetCount
        guard removeCount > 0 else { return }
        for _ in 0..<removeCount {
            guard let victim = entries.min(
                by: { $0.value.accessOrdinal < $1.value.accessOrdinal }
            )?.key else {
                break
            }
            removeValue(for: victim)
        }
    }

    private mutating func nextAccessOrdinal() -> UInt64 {
        accessClock &+= 1
        return accessClock
    }
}
