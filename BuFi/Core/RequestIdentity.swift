import Foundation

/// Canonical, collision-safe representation of one URL query item.
///
/// OpenSubsonic request coalescing used to flatten each query item into a
/// `name=value` String. Keeping the two fields distinct avoids separator
/// aliases and gives Swift 6 a fully value-semantic, Sendable request key.
struct OpenSubsonicQueryIdentity: Hashable, Sendable {
    let name: String
    let value: String?
}

/// Immutable identity for one coalescible OpenSubsonic read.
///
/// The cache revision is part of the identity, so a request started before a
/// relevant mutation can never be reused by a request created after it. Cache
/// validators are also distinct: an unconditional refresh must never join a
/// conditional request that is allowed to return an empty 304 response.
struct OpenSubsonicReadRequestKey: Hashable, Sendable {
    let endpoint: String
    let queryItems: [OpenSubsonicQueryIdentity]
    let cacheRevision: OpenSubsonicCacheRevision
    let entityTag: String?
    let lastModified: String?

    init(
        endpoint: String,
        queryItems: [URLQueryItem],
        cacheRevision: OpenSubsonicCacheRevision,
        entityTag: String? = nil,
        lastModified: String? = nil
    ) {
        self.endpoint = endpoint
        self.cacheRevision = cacheRevision
        self.entityTag = entityTag
        self.lastModified = lastModified
        self.queryItems = queryItems
            .map {
                OpenSubsonicQueryIdentity(
                    name: $0.name,
                    value: $0.value
                )
            }
            .sorted(by: Self.queryItemSort)
    }

    private static func queryItemSort(
        _ lhs: OpenSubsonicQueryIdentity,
        _ rhs: OpenSubsonicQueryIdentity
    ) -> Bool {
        if lhs.name != rhs.name { return lhs.name < rhs.name }
        switch (lhs.value, rhs.value) {
        case (nil, .some):
            return true
        case (.some, nil):
            return false
        case (.some(let left), .some(let right)):
            return left < right
        case (nil, nil):
            return false
        }
    }
}

/// Exact identity of a speculative/warmed stream resource.
///
/// A queue occurrence, account, media revision, quality, and compatibility
/// format remain separate fields instead of being concatenated with a
/// delimiter. This prevents a warmed AVURLAsset from aliasing another logical
/// stream request when opaque server values contain that delimiter.
struct PreparedPlaybackKey: Hashable, Sendable {
    let accountScope: String?
    let queueEntryID: UUID
    let streamRevision: String
    let qualityRawValue: String
    let compatibilityFormat: String

    init(
        accountScope: String?,
        queueEntryID: UUID,
        streamRevision: String,
        quality: StreamQuality,
        compatibilityFormat: String
    ) {
        self.accountScope = accountScope
        self.queueEntryID = queueEntryID
        self.streamRevision = streamRevision
        qualityRawValue = quality.rawValue
        self.compatibilityFormat = compatibilityFormat.lowercased()
    }
}
