import Foundation

/// Canonical server-address parsing for login and the OpenSubsonic client.
///
/// Users type hosts, reverse-proxy paths, and sometimes a trailing `/rest`.
/// The client always appends `/rest/<endpoint>.view`, so this type keeps the
/// real base path and drops a duplicated REST suffix. Explicit HTTP and HTTPS
/// schemes are both preserved; addresses without a scheme default to HTTPS.
enum ServerURLNormalization {
    enum Outcome: Equatable, Sendable {
        case success(URL)
        case empty
        case invalid
        case insecure
        case credentialsInURL
    }

    static func normalize(_ value: String) -> Outcome {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .empty }

        let lowercased = text.lowercased()
        if !lowercased.hasPrefix("https://"), !lowercased.hasPrefix("http://") {
            text = "https://" + text
        }

        guard var components = URLComponents(string: text) else {
            return .invalid
        }
        let scheme = components.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else { return .invalid }
        if components.user != nil || components.password != nil {
            return .credentialsInURL
        }

        let host = components.host?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !host.isEmpty else { return .invalid }

        components.scheme = scheme
        components.host = host.lowercased()
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        components.path = normalizedPath(components.percentEncodedPath)
        guard let url = components.url else { return .invalid }
        return .success(url)
    }

    static func url(from value: String) -> URL? {
        if case .success(let url) = normalize(value) {
            return url
        }
        return nil
    }

    static func isSupportedTransportURL(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    static func resolvedURL(from value: String) throws -> URL {
        switch normalize(value) {
        case .success(let url):
            return url
        case .insecure:
            throw OpenSubsonicError.insecureServerURL
        case .credentialsInURL:
            throw OpenSubsonicError.credentialsEmbeddedInServerURL
        case .empty, .invalid:
            throw OpenSubsonicError.invalidServerURL
        }
    }

    static func persistedServerURL(from url: URL) -> String {
        url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func normalizedPath(_ rawPath: String) -> String {
        let decoded = rawPath.removingPercentEncoding ?? rawPath
        var parts = decoded
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        while parts.last?.caseInsensitiveCompare("rest") == .orderedSame {
            parts.removeLast()
        }
        guard !parts.isEmpty else { return "" }
        return "/" + parts.joined(separator: "/")
    }
}
