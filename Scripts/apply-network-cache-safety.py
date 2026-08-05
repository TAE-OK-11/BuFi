from pathlib import Path

root = Path(__file__).resolve().parents[1]
path = root / "BuFi/Core/OpenSubsonicClient.swift"
text = path.read_text(encoding="utf-8")


def replace(old: str, new: str) -> None:
    global text
    if old not in text:
        raise SystemExit(f"missing block: {old[:100]!r}")
    text = text.replace(old, new, 1)


replace(
    '''    private static let responseCacheLimit = 128
    private var responseCache: [String: CachedAPIResponse] = [:]
    private var responseCacheOrder: [String] = []
    private var inFlightResponses: [String: InFlightAPIRequest] = [:]
''',
    '''    private static let responseCacheLimit = 128
    private static let responseCacheByteLimit = 16 * 1_024 * 1_024
    private static let maximumCachedResponseBytes = 2 * 1_024 * 1_024
    private var responseCache: [String: CachedAPIResponse] = [:]
    private var responseCacheOrder: [String] = []
    private var responseCacheBytes = 0
    private var inFlightResponses: [String: InFlightAPIRequest] = [:]
'''
)

replace(
    '''        if ttl > 0 {
            storeResponse(data, for: cacheKey)
        }
        return try APIEnvelope<Payload>(from: capture.decoder).response
''',
    '''        if ttl > 0 {
            storeResponse(data, for: cacheKey)
        } else if endpoint != "ping" {
            // A successful mutation can invalidate any cached library, queue,
            // recommendation, or favorite response from the same account.
            clearResponseCache()
        }
        return try APIEnvelope<Payload>(from: capture.decoder).response
'''
)

replace(
    '''        guard Date().timeIntervalSince(value.storedAt) <= lifetime else {
            responseCache[key] = nil
            responseCacheOrder.removeAll { $0 == key }
            return nil
        }
''',
    '''        guard Date().timeIntervalSince(value.storedAt) <= lifetime else {
            responseCache[key] = nil
            responseCacheBytes = max(0, responseCacheBytes - value.data.count)
            responseCacheOrder.removeAll { $0 == key }
            return nil
        }
'''
)

replace(
    '''    private func storeResponse(_ data: Data, for key: String) {
        responseCache[key] = CachedAPIResponse(data: data, storedAt: Date())
        responseCacheOrder.removeAll { $0 == key }
        responseCacheOrder.append(key)
        while responseCacheOrder.count > Self.responseCacheLimit {
            let evicted = responseCacheOrder.removeFirst()
            responseCache[evicted] = nil
        }
    }

    private static func responseCacheKey(
''',
    '''    private func storeResponse(_ data: Data, for key: String) {
        guard data.count <= Self.maximumCachedResponseBytes else { return }
        if let existing = responseCache[key] {
            responseCacheBytes = max(0, responseCacheBytes - existing.data.count)
        }
        responseCache[key] = CachedAPIResponse(data: data, storedAt: Date())
        responseCacheBytes += data.count
        responseCacheOrder.removeAll { $0 == key }
        responseCacheOrder.append(key)
        while responseCacheOrder.count > Self.responseCacheLimit
                || responseCacheBytes > Self.responseCacheByteLimit {
            let evicted = responseCacheOrder.removeFirst()
            if let removed = responseCache.removeValue(forKey: evicted) {
                responseCacheBytes = max(0, responseCacheBytes - removed.data.count)
            }
        }
    }

    private func clearResponseCache() {
        responseCache.removeAll(keepingCapacity: false)
        responseCacheOrder.removeAll(keepingCapacity: false)
        responseCacheBytes = 0
    }

    private static func responseCacheKey(
'''
)

replace(
    '''        responseCache.removeAll(keepingCapacity: false)
        responseCacheOrder.removeAll(keepingCapacity: false)
''',
    '''        clearResponseCache()
'''
)

path.write_text(text, encoding="utf-8")

docs = root / "Docs/NETWORKING.md"
doc_text = docs.read_text(encoding="utf-8")
doc_text = doc_text.replace(
    "A small bounded\n  actor-local response cache absorbs overlapping view/recommendation bursts,",
    "A 16 MiB bounded\n  actor-local response cache absorbs overlapping view/recommendation bursts,"
)
docs.write_text(doc_text, encoding="utf-8")
