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
        allowsConstrainedNetworkAccess: Bool,
        waitsForConnectivity: Bool = true
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = maximumConnectionsPerHost
        // This affects only the HTTP/1.1 fallback. HTTP/2 and HTTP/3 continue
        // to multiplex streams through CFNetwork's native transport stack.
        configuration.httpShouldUsePipelining = true
        configuration.waitsForConnectivity = waitsForConnectivity
        configuration.allowsCellularAccess = true
        configuration.allowsExpensiveNetworkAccess = allowsExpensiveNetworkAccess
        configuration.allowsConstrainedNetworkAccess = allowsConstrainedNetworkAccess
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return configuration
    }

    /// Cached variant for public metadata services such as recommendation APIs.
    /// It keeps the same connection, privacy, and fallback policy as BuFi's
    /// authenticated traffic while allowing small JSON responses to be reused.
    static func makeCachedConfiguration(
        requestTimeout: TimeInterval,
        resourceTimeout: TimeInterval,
        maximumConnectionsPerHost: Int,
        memoryCapacity: Int,
        diskCapacity: Int,
        allowsExpensiveNetworkAccess: Bool = true,
        allowsConstrainedNetworkAccess: Bool = false
    ) -> URLSessionConfiguration {
        let configuration = makeEphemeralConfiguration(
            requestTimeout: requestTimeout,
            resourceTimeout: resourceTimeout,
            maximumConnectionsPerHost: maximumConnectionsPerHost,
            allowsExpensiveNetworkAccess: allowsExpensiveNetworkAccess,
            allowsConstrainedNetworkAccess: allowsConstrainedNetworkAccess
        )
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.urlCache = URLCache(
            memoryCapacity: memoryCapacity,
            diskCapacity: diskCapacity
        )
        return configuration
    }

    static func prepareAPIRequest(
        _ request: inout URLRequest,
        acceptsZstandard: Bool
    ) {
        prepareJSONRequest(
            &request,
            acceptsZstandard: acceptsZstandard,
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    /// Third-party JSON APIs are not BuFi-controlled endpoints. Do not claim
    /// HTTP/3 support before CFNetwork has learned it from DNS/Alt-Svc. Forcing
    /// QUIC here can turn an otherwise healthy Groq/Gemini/OpenAI request into
    /// a transport failure on networks or providers where H3 is unavailable.
    /// Let URLSession negotiate the best supported protocol normally.
    static func prepareExternalAPIRequest(
        _ request: inout URLRequest,
        acceptsZstandard: Bool
    ) {
        request.assumesHTTP3Capable = false
        request.httpShouldHandleCookies = false
        request.allowsCellularAccess = true
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.networkServiceType = .responsiveData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            acceptsZstandard ? modernContentEncodings : compatibilityContentEncodings,
            forHTTPHeaderField: "Accept-Encoding"
        )
    }

    static func prepareHealthCheckRequest(
        _ request: inout URLRequest,
        acceptsZstandard: Bool = true
    ) {
        prepareJSONRequest(
            &request,
            acceptsZstandard: acceptsZstandard,
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        request.timeoutInterval = 8
    }

    static func prepareImageRequest(_ request: inout URLRequest) {
        prepareHTTP3Request(&request)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.networkServiceType = .responsiveData
        request.setValue("image/*, */*;q=0.8", forHTTPHeaderField: "Accept")
        // CFNetwork natively expands Brotli and gzip. zstd is intentionally not
        // advertised here because Nuke receives bytes outside BuFi's zstd decoder.
        request.setValue(compatibilityContentEncodings, forHTTPHeaderField: "Accept-Encoding")
    }

    /// Analysis samples must not race the player for the AV streaming class.
    /// Keep identity encoding so the range maps to raw audio bytes.
    static func prepareAnalysisMediaRequest(_ request: inout URLRequest) {
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.networkServiceType = .background
        request.setValue(
            "audio/*, application/octet-stream;q=0.9, */*;q=0.1",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    }

    static func prepareMediaRequest(_ request: inout URLRequest) {
        prepareHTTP3Request(&request)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.networkServiceType = .avStreaming
        request.setValue(
            "audio/*, application/octet-stream;q=0.9, */*;q=0.1",
            forHTTPHeaderField: "Accept"
        )
        // Audio files are already compressed and AVFoundation relies on exact
        // byte ranges for seeking. Content-coding would waste CPU and can make
        // range offsets ambiguous, so media transfers explicitly use identity.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    }

    /// Reapplies safe transport semantics after an HTTPS redirect. URLSession
    /// may synthesize a new request and drop non-default request properties;
    /// preserving these values keeps media byte ranges and JSON compression
    /// behavior stable across CDN or object-storage redirects. Sensitive
    /// headers such as Authorization are intentionally never copied here.
    static func prepareRedirect(
        _ request: inout URLRequest,
        inheriting originalRequest: URLRequest? = nil
    ) {
        prepareHTTP3Request(&request)
        guard let originalRequest else { return }

        request.cachePolicy = originalRequest.cachePolicy
        request.timeoutInterval = originalRequest.timeoutInterval
        request.networkServiceType = originalRequest.networkServiceType
        for header in ["Accept", "Accept-Encoding"] {
            if let value = originalRequest.value(forHTTPHeaderField: header) {
                request.setValue(value, forHTTPHeaderField: header)
            }
        }
    }

    private static func prepareJSONRequest(
        _ request: inout URLRequest,
        acceptsZstandard: Bool,
        cachePolicy: URLRequest.CachePolicy
    ) {
        prepareHTTP3Request(&request)
        request.cachePolicy = cachePolicy
        request.networkServiceType = .responsiveData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            acceptsZstandard ? modernContentEncodings : compatibilityContentEncodings,
            forHTTPHeaderField: "Accept-Encoding"
        )
    }

    private static func prepareHTTP3Request(_ request: inout URLRequest) {
        request.assumesHTTP3Capable = true
        request.httpShouldHandleCookies = false
        request.allowsCellularAccess = true
    }
}
