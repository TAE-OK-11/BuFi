import Foundation

/// Subsonic-family servers are spoken in this order:
/// 1. OpenSubsonic
/// 2. Standard Subsonic
/// 3. Older last-resort endpoints
enum SubsonicAPIFamily: String, Equatable, Sendable {
    case openSubsonic
    case subsonic
    case legacy
}

enum SubsonicCompatibilityPolicy {
    static func family(from status: StatusBody) -> SubsonicAPIFamily {
        if status.advertisesOpenSubsonic {
            return .openSubsonic
        }
        let type = (status.type ?? "").lowercased()
        if type.contains("navidrome")
            || type.contains("opensubsonic")
            || type.contains("gonic")
            || type.contains("airsonic") {
            return .openSubsonic
        }
        let version = status.version?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ) ?? ""
        if !version.isEmpty {
            return .subsonic
        }
        return .legacy
    }

    static func searchEndpoints(for family: SubsonicAPIFamily) -> [String] {
        switch family {
        case .openSubsonic, .subsonic:
            ["search3", "search2"]
        case .legacy:
            ["search2", "search3"]
        }
    }

    static func starredEndpoints(for family: SubsonicAPIFamily) -> [String] {
        switch family {
        case .openSubsonic, .subsonic:
            ["getStarred2", "getStarred"]
        case .legacy:
            ["getStarred", "getStarred2"]
        }
    }

    static func albumListEndpoints(for family: SubsonicAPIFamily) -> [String] {
        switch family {
        case .openSubsonic, .subsonic:
            ["getAlbumList2", "getAlbumList"]
        case .legacy:
            ["getAlbumList", "getAlbumList2"]
        }
    }

    static func similarSongEndpoints(for family: SubsonicAPIFamily) -> [String] {
        switch family {
        case .openSubsonic:
            ["getSonicSimilarTracks", "getSimilarSongs2", "getSimilarSongs"]
        case .subsonic:
            ["getSimilarSongs2", "getSimilarSongs"]
        case .legacy:
            ["getSimilarSongs", "getSimilarSongs2"]
        }
    }

    static func lyricsEndpoints(for family: SubsonicAPIFamily) -> [String] {
        switch family {
        case .openSubsonic, .subsonic:
            ["getLyricsBySongId", "getLyrics"]
        case .legacy:
            ["getLyrics", "getLyricsBySongId"]
        }
    }

    static func shouldContinueFallback(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if TransientServiceFailurePolicy.isAuthenticationFailure(error) {
            return false
        }
        if let openSubsonic = error as? OpenSubsonicError {
            switch openSubsonic {
            case .http(let status):
                return status == 404 || status == 405 || status == 501
                    || (500...599).contains(status)
            case .server(let code, let message):
                if code == 70 { return true }
                let lowercased = message.lowercased()
                return lowercased.contains("not found")
                    || lowercased.contains("unknown")
                    || lowercased.contains("not implemented")
                    || lowercased.contains("not supported")
            case .invalidResponse:
                return true
            case .invalidServerURL,
                    .insecureServerURL,
                    .credentialsEmbeddedInServerURL:
                return false
            }
        }
        return true
    }
}
