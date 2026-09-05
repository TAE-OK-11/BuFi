import Foundation
import os

enum OpenSubsonicExtensionName {
    static let apiKeyAuthentication = "apiKeyAuthentication"
    static let httpFormPost = "httpFormPost"
    static let indexBasedQueue = "indexBasedQueue"
    static let playbackReport = "playbackReport"
    static let sonicSimilarity = "sonicSimilarity"
    static let topSongsByArtistId = "topSongsByArtistId"
    static let transcoding = "transcoding"
    static let transcodeOffset = "transcodeOffset"
    static let getPodcastEpisode = "getPodcastEpisode"
}

struct OpenSubsonicExtensionRegistry: Sendable, Equatable {
    private let versionsByName: [String: Set<Int>]

    init(extensions: [OpenSubsonicExtension]) {
        var map: [String: Set<Int>] = [:]
        for entry in extensions where !entry.versions.isEmpty {
            map[entry.name] = Set(entry.versions)
        }
        versionsByName = map
    }

    var names: Set<String> {
        Set(versionsByName.keys)
    }

    func supports(_ name: String, minimumVersion: Int = 1) -> Bool {
        guard let versions = versionsByName[name] else { return false }
        return versions.contains { $0 >= minimumVersion }
    }

    static let empty = OpenSubsonicExtensionRegistry(extensions: [])
}

enum ServerAuthMethod: String, Codable, Sendable {
    case password
    case apiKey
}

struct TokenInfoPayload: Decodable, Sendable {
    let tokenInfo: TokenInfoBody?
}

struct TokenInfoBody: Decodable, Sendable {
    let username: String?
}

struct PlayQueueByIndexPayload: Decodable, Sendable {
    let playQueueByIndex: PlayQueueByIndexContainer?
}

struct PlayQueueByIndexContainer: Decodable, Sendable {
    let currentIndex: Int?
    let position: Int?
    let entry: [Song]?
}

struct PodcastEpisodePayload: Decodable, Sendable {
    let podcastEpisode: PodcastEpisode?
}

struct PodcastEpisode: Decodable, Sendable, Identifiable {
    let id: String?
    let title: String?
    let artist: String?
    let album: String?
    let coverArt: String?
    let duration: Int?
    let contentType: String?
    let suffix: String?
    let streamId: String?
    let channelId: String?
    let description: String?
    let publishDate: String?
    let status: String?
}

struct TranscodeDecisionPayload: Decodable, Sendable {
    let transcodeDecision: TranscodeDecision?
}

struct TranscodeDecision: Decodable, Sendable {
    let canDirectPlay: Bool?
    let canTranscode: Bool?
    let transcodeReason: [String]?
    let errorReason: String?
    let transcodeParams: String?
}

enum OpenSubsonicClientInfo {
    /// Client capabilities advertised to OpenSubsonic transcoding servers.
    /// Pre-serialized so callers never need a non-Sendable `[String: Any]`
    /// constant crossing concurrency domains.
    static let jsonBodyData: Data = {
        let body: [String: Any] = [
            "name": OpenSubsonicClient.clientName,
            "platform": "iOS",
            "maxAudioBitrate": 1_024_000,
            "maxTranscodingAudioBitrate": 320_000,
            "directPlayProfiles": [
                [
                    "containers": ["mp3"],
                    "audioCodecs": ["mp3"],
                    "protocols": ["http"],
                    "maxAudioChannels": 2
                ],
                [
                    "containers": ["mp4", "m4a"],
                    "audioCodecs": ["aac", "alac"],
                    "protocols": ["http"],
                    "maxAudioChannels": 2
                ],
                [
                    "containers": ["flac"],
                    "audioCodecs": ["flac"],
                    "protocols": ["http"],
                    "maxAudioChannels": 2
                ]
            ],
            "transcodingProfiles": [
                [
                    "container": "mp3",
                    "audioCodec": "mp3",
                    "protocol": "http",
                    "maxAudioChannels": 2
                ],
                [
                    "container": "aac",
                    "audioCodec": "aac",
                    "protocol": "http",
                    "maxAudioChannels": 2
                ]
            ],
            "codecProfiles": [
                [
                    "type": "AudioCodec",
                    "name": "mp3",
                    "limitations": [
                        [
                            "name": "audioBitrate",
                            "comparison": "LessThanEqual",
                            "values": ["320000"],
                            "required": true
                        ]
                    ]
                ]
            ]
        ]
        // Serialization cannot fail for this fixed literal graph.
        return try! JSONSerialization.data(withJSONObject: body)
    }()
}

enum OpenSubsonicPublicDiscovery {
    private struct DecoderCapture: Decodable {
        let decoder: Decoder
        init(from decoder: Decoder) throws {
            self.decoder = decoder
        }
    }

    private struct CachedEntry: Sendable {
        let registry: OpenSubsonicExtensionRegistry
        let storedAt: Date
    }

    // Process-local discovery cache shared across short-lived clients.
    private static let cache = OSAllocatedUnfairLock(
        initialState: [String: CachedEntry]()
    )
    private static let cacheLifetime: TimeInterval = 5 * 60

    private static let session: URLSession = {
        let configuration = ModernNetworkPolicy.makeEphemeralConfiguration(
            requestTimeout: 12,
            resourceTimeout: 20,
            maximumConnectionsPerHost: 2,
            allowsExpensiveNetworkAccess: true,
            allowsConstrainedNetworkAccess: true,
            waitsForConnectivity: false
        )
        return URLSession(
            configuration: configuration,
            delegate: HTTPSOnlyURLSessionDelegate(),
            delegateQueue: nil
        )
    }()

    static func fetchExtensions(serverURL: String) async -> OpenSubsonicExtensionRegistry? {
        let normalized = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cached = cachedRegistry(for: normalized) {
            return cached
        }
        guard let url = URL(
            string: normalized
                + "/rest/getOpenSubsonicExtensions.view?f=json&v="
                + OpenSubsonicClient.apiVersion
                + "&c="
                + OpenSubsonicClient.clientName
        ), url.scheme?.lowercased() == "https" else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return nil
            }
            let capture = try JSONDecoder().decode(DecoderCapture.self, from: data)
            let envelope = try StatusEnvelope(from: capture.decoder)
            guard envelope.response.status == "ok" else {
                return nil
            }
            let payload = try APIEnvelope<OpenSubsonicExtensionsPayload>(
                from: capture.decoder
            ).response
            let registry = OpenSubsonicExtensionRegistry(
                extensions: payload.openSubsonicExtensions ?? []
            )
            store(registry: registry, for: normalized)
            return registry
        } catch {
            return nil
        }
    }

    private static func cachedRegistry(for serverURL: String) -> OpenSubsonicExtensionRegistry? {
        cache.withLock { state in
            guard let entry = state[serverURL],
                  Date().timeIntervalSince(entry.storedAt) < cacheLifetime else {
                _ = state.removeValue(forKey: serverURL)
                return nil
            }
            return entry.registry
        }
    }

    private static func store(
        registry: OpenSubsonicExtensionRegistry,
        for serverURL: String
    ) {
        cache.withLock {
            $0[serverURL] = CachedEntry(registry: registry, storedAt: Date())
        }
    }
}
