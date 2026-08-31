import Foundation

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
    static let jsonBody: [String: Any] = [
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
}

enum OpenSubsonicPublicDiscovery {
    static func fetchExtensions(serverURL: String) async -> OpenSubsonicExtensionRegistry {
        guard let url = URL(
            string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
                + "/rest/getOpenSubsonicExtensions.view?f=json&v="
                + OpenSubsonicClient.apiVersion
                + "&c="
                + OpenSubsonicClient.clientName
        ), url.scheme?.lowercased() == "https" else {
            return .empty
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return .empty
            }
            let payload: OpenSubsonicExtensionsPayload = try JSONDecoder().decode(
                APIEnvelope<OpenSubsonicExtensionsPayload>.self,
                from: data
            ).response
            return OpenSubsonicExtensionRegistry(
                extensions: payload.openSubsonicExtensions ?? []
            )
        } catch {
            return .empty
        }
    }
}
