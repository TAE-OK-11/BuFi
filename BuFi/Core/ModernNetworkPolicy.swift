import Foundation

/// Shared transport policy for BuFi-owned URLSession traffic.
///
/// URLSession negotiates TLS 1.3 and HTTP/2 automatically. Marking known BuFi
/// endpoints as HTTP/3-capable additionally enables QUIC racing before an
/// Alt-Svc discovery round trip, while retaining the system HTTP/2 fallback.
enum ModernNetworkPolicy {
    static let modernContentEncodings = "zstd, br, gzip"
    static let compatibilityContentEncodings = "br, gzip"

    static func makeEphemeralConfiguration(
        requestTimeout: TimeInterval,
        resourceTimeout: TimeInterval,
        maximumConnectionsPerHost: Int,
        allowsExpensiveNetworkAccess: Bool,
        allowsConstrainedNetworkAccess: Bool
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = maximumConnectionsPerHost
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
        configuration.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return configuration
    }

    static func prepareAPIRequest(
        _ request: inout URLRequest,
        acceptsZstandard: Bool
    ) {
        prepareHTTP3Request(&request)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            acceptsZstandard ? modernContentEncodings : compatibilityContentEncodings,
            forHTTPHeaderField: "Accept-Encoding"
        )
    }

    static func prepareImageRequest(_ request: inout URLRequest) {
        prepareHTTP3Request(&request)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("image/*, */*;q=0.8", forHTTPHeaderField: "Accept")
        // CFNetwork natively expands Brotli and gzip. zstd is intentionally not
        // advertised here because Nuke receives bytes outside BuFi's zstd decoder.
        request.setValue(compatibilityContentEncodings, forHTTPHeaderField: "Accept-Encoding")
    }

    static func prepareMediaRequest(_ request: inout URLRequest) {
        prepareHTTP3Request(&request)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(
            "audio/*, application/octet-stream;q=0.9, */*;q=0.1",
            forHTTPHeaderField: "Accept"
        )
        // Audio files are already compressed and AVFoundation relies on exact
        // byte ranges for seeking. Content-coding would waste CPU and can make
        // range offsets ambiguous, so media transfers explicitly use identity.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    }

    static func prepareRedirect(_ request: inout URLRequest) {
        prepareHTTP3Request(&request)
    }

    private static func prepareHTTP3Request(_ request: inout URLRequest) {
        request.assumesHTTP3Capable = true
        request.httpShouldHandleCookies = false
        request.allowsCellularAccess = true
    }
}
