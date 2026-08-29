import Foundation

private struct DeezerArtistSearchResponse: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        let name: String
        let pictureXl: String?
        let pictureBig: String?
        let pictureMedium: String?

        enum CodingKeys: String, CodingKey {
            case name
            case pictureXl = "picture_xl"
            case pictureBig = "picture_big"
            case pictureMedium = "picture_medium"
        }
    }

    let data: [Item]
}

actor ArtistImageClient {
    static let shared = ArtistImageClient()

    private struct CacheEntry {
        let url: URL?
        let expiresAt: Date
    }

    private let session: URLSession
    private var cache: [String: CacheEntry] = [:]
    private let cacheLifetime: TimeInterval = 7 * 24 * 60 * 60

    private init() {
        session = URLSession(
            configuration: ModernNetworkPolicy.makeCachedConfiguration(
                requestTimeout: 10,
                resourceTimeout: 18,
                maximumConnectionsPerHost: 2,
                memoryCapacity: 2 * 1_024 * 1_024,
                diskCapacity: 12 * 1_024 * 1_024,
                allowsExpensiveNetworkAccess: true,
                allowsConstrainedNetworkAccess: false
            ),
            delegate: HTTPSOnlyURLSessionDelegate(),
            delegateQueue: nil
        )
    }

    func imageURL(for artistName: String) async -> URL? {
        let key = ArtistPersonaResolver.normalized(artistName)
        guard !key.isEmpty else { return nil }
        if let cached = cache[key], cached.expiresAt > Date() {
            return cached.url
        }
        guard EnergyConstraintsPolicy.allowsExternalRecommendationRefresh(
            thermalState: ProcessInfo.processInfo.thermalState
        ) else {
            return cache[key]?.url
        }
        let resolved = await fetchImageURL(for: artistName, normalizedKey: key)
        cache[key] = CacheEntry(
            url: resolved,
            expiresAt: Date().addingTimeInterval(cacheLifetime)
        )
        return resolved
    }

    private func fetchImageURL(
        for artistName: String,
        normalizedKey: String
    ) async -> URL? {
        guard var components = URLComponents(
            string: "https://api.deezer.com/search/artist"
        ) else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "q", value: artistName),
            URLQueryItem(name: "limit", value: "5")
        ]
        guard let url = components.url else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return nil
            }
            let payload = try JSONDecoder().decode(
                DeezerArtistSearchResponse.self,
                from: data
            )
            guard let match = bestMatch(
                in: payload.data,
                for: artistName,
                normalizedKey: normalizedKey
            ) else {
                return nil
            }
            return pictureURL(from: match)
        } catch {
            return nil
        }
    }

    private func bestMatch(
        in items: [DeezerArtistSearchResponse.Item],
        for artistName: String,
        normalizedKey: String
    ) -> DeezerArtistSearchResponse.Item? {
        guard !items.isEmpty else { return nil }
        let exact = items.first {
            ArtistPersonaResolver.normalized($0.name) == normalizedKey
        }
        if let exact { return exact }
        return items.first
    }

    private func pictureURL(
        from item: DeezerArtistSearchResponse.Item
    ) -> URL? {
        for candidate in [item.pictureXl, item.pictureBig, item.pictureMedium] {
            guard let value = candidate?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty,
                  let url = URL(string: value),
                  url.scheme == "https" else {
                continue
            }
            return url
        }
        return nil
    }
}
