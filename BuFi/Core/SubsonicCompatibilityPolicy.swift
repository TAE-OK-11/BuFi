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

    /// Endpoint fallback is for protocol compatibility, not transport recovery.
    ///
    /// A transient 5xx/network failure is already handled by the bounded read
    /// retry policy. Falling through to two older endpoints after that retry
    /// multiplies traffic exactly when the server or network is unhealthy and
    /// can turn one user action into a request storm. Only an explicit
    /// unsupported/missing endpoint (or an incompatible response shape) should
    /// advance to the next API generation.
    static func shouldContinueFallback(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if TransientServiceFailurePolicy.isAuthenticationFailure(error) {
            return false
        }
        guard let openSubsonic = error as? OpenSubsonicError else {
            return false
        }
        switch openSubsonic {
        case .http(let status):
            return status == 404 || status == 405 || status == 501
        case .server(let code, let message):
            if code == 70 { return true }
            let normalized = message.lowercased()
            return normalized.contains("not found")
                || normalized.contains("unknown endpoint")
                || normalized.contains("not implemented")
                || normalized.contains("not supported")
        case .invalidResponse:
            return true
        case .invalidServerURL,
                .insecureServerURL,
                .credentialsEmbeddedInServerURL:
            return false
        }
    }
}
