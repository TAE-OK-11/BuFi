from pathlib import Path

path = Path(__file__).resolve().parents[1] / "BuFi/Core/OpenSubsonicClient.swift"
text = path.read_text(encoding="utf-8")

old = '''        if ttl > 0 {
            storeResponse(data, for: cacheKey)
        } else if endpoint != "ping" {
            // A successful mutation can invalidate any cached library, queue,
            // recommendation, or favorite response from the same account.
            clearResponseCache()
        }
        return try APIEnvelope<Payload>(from: capture.decoder).response
'''
new = '''        let payload = try APIEnvelope<Payload>(from: capture.decoder).response
        if ttl > 0 {
            // Cache only responses that successfully decode into the expected
            // endpoint payload, never malformed or schema-incompatible data.
            storeResponse(data, for: cacheKey)
        } else if endpoint != "ping" {
            // A successful mutation can invalidate any cached library, queue,
            // recommendation, or favorite response from the same account.
            clearResponseCache()
        }
        return payload
'''
if old not in text:
    raise SystemExit("payload cache block not found")
text = text.replace(old, new, 1)

old = '''    private static func responseCacheKey(
        endpoint: String,
        queryItems: [URLQueryItem]
    ) -> String {
        let parameters = queryItems
            .map { ($0.name, $0.value ?? "") }
            .sorted {
                $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0
            }
            .map { "\\($0.0)=\\($0.1)" }
            .joined(separator: "&")
        return endpoint + "?" + parameters
    }
'''
new = '''    private static func responseCacheKey(
        endpoint: String,
        queryItems: [URLQueryItem]
    ) -> String {
        var parameters: [String] = []
        parameters.reserveCapacity(queryItems.count)
        for item in queryItems {
            parameters.append(item.name + "=" + (item.value ?? ""))
        }
        parameters.sort()
        return endpoint + "?" + parameters.joined(separator: "&")
    }
'''
if old not in text:
    raise SystemExit("cache key block not found")
text = text.replace(old, new, 1)
path.write_text(text, encoding="utf-8")
