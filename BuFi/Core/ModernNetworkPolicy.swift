import Foundation

/// Shared transport policy for BuFi-owned URLSession traffic.
///
/// Keep request preparation in one place so OpenSubsonic, artwork, playback,
/// diagnostics, and external AI/recommendation APIs cannot slowly diverge into
/// separate transport stacks. URLSession still owns TLS/HTTP negotiation; BuFi
/// only supplies the endpoint-specific hints that are safe and measurable.
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
        configuration.httpMaximumConnectionsPerHost = max(
            1,
            maximumConnectionsPerHost
        )
        // Let CFNetwork choose the HTTP/1.1 fallback behavior. H2/H3 already
        // multiplex natively and forcing legacy pipelining adds no benefit to
        // the common path while increasing compatibility risk on old origins.
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
    /// Authenticated/private requests continue to use the zero-cache path.
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
            memoryCapacity: max(0, memoryCapacity),
            diskCapacity: max(0, diskCapacity)
        )
        return configuration
    }

    static func prepareAPIRequest(
        _ request: inout URLRequest,
        acceptsZstandard: Bool
    ) {
        prepareJSONRequest(
            &request,
            assumesHTTP3Capable: true,
            acceptsZstandard: acceptsZstandard,
            cachePolicy: .reloadIgnoringLocalCacheData
        )
    }

    /// Third-party JSON APIs are not BuFi-controlled endpoints. Do not claim
    /// HTTP/3 support before CFNetwork learns it from DNS/Alt-Svc; an optimistic
    /// QUIC race here can turn a healthy external API call into a transport
    /// failure on providers or networks without H3.
    static func prepareExternalAPIRequest(
        _ request: inout URLRequest,
        acceptsZstandard: Bool,
        allowsCaching: Bool
    ) {
        prepareJSONRequest(
            &request,
            assumesHTTP3Capable: false,
            acceptsZstandard: acceptsZstandard,
            cachePolicy: allowsCaching
                ? .useProtocolCachePolicy
                : .reloadIgnoringLocalCacheData
        )
    }

    static func prepareHealthCheckRequest(
        _ request: inout URLRequest,
        acceptsZstandard: Bool = true
    ) {
        prepareJSONRequest(
            &request,
            assumesHTTP3Capable: true,
            acceptsZstandard: acceptsZstandard,
            cachePolicy: .reloadIgnoringLocalCacheData
        )
        request.timeoutInterval = 8
    }

    static func prepareImageRequest(_ request: inout URLRequest) {
        prepareTransport(&request, assumesHTTP3Capable: true)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.networkServiceType = .responsiveData
        request.setValue("image/*, */*;q=0.8", forHTTPHeaderField: "Accept")
        // Nuke receives bytes outside BuFi's zstd decoder, so images advertise
        // only encodings CFNetwork expands transparently.
        request.setValue(
            compatibilityContentEncodings,
            forHTTPHeaderField: "Accept-Encoding"
        )
    }

    /// Analysis samples must not race the player for the AV streaming class.
    /// Keep identity encoding so the range maps to raw audio bytes.
    static func prepareAnalysisMediaRequest(_ request: inout URLRequest) {
        prepareTransport(&request, assumesHTTP3Capable: false)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.networkServiceType = .background
        request.setValue(
            "audio/*, application/octet-stream;q=0.9, */*;q=0.1",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    }

    /// Full-file/offline transfers share the media headers but must not
    /// compete with the active AVPlayer stream for responsive/AV bandwidth.
    static func prepareBackgroundMediaRequest(_ request: inout URLRequest) {
        prepareTransport(&request, assumesHTTP3Capable: true)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.networkServiceType = .background
        request.setValue(
            "audio/*, application/octet-stream;q=0.9, */*;q=0.1",
            forHTTPHeaderField: "Accept"
        )
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    }

    static func prepareMediaRequest(_ request: inout URLRequest) {
        prepareTransport(&request, assumesHTTP3Capable: true)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.networkServiceType = .avStreaming
        request.setValue(
            "audio/*, application/octet-stream;q=0.9, */*;q=0.1",
            forHTTPHeaderField: "Accept"
        )
        // Audio files are already compressed and AVFoundation relies on exact
        // byte ranges for seeking, so media transfers explicitly use identity.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    }

    /// Reapplies safe transport semantics after an HTTPS redirect. URLSession
    /// may synthesize a new request and drop non-default request properties.
    /// Sensitive headers such as Authorization are intentionally never copied.
    static func prepareRedirect(
        _ request: inout URLRequest,
        inheriting originalRequest: URLRequest? = nil
    ) {
        // Preserve the policy chosen at the request boundary. In particular,
        // an external API that intentionally avoided optimistic H3 must not be
        // converted into an H3-assumed request just because it redirected.
        let assumesHTTP3Capable = originalRequest?.assumesHTTP3Capable
            ?? request.assumesHTTP3Capable
        prepareTransport(
            &request,
            assumesHTTP3Capable: assumesHTTP3Capable
        )
        guard let originalRequest else { return }

        request.cachePolicy = originalRequest.cachePolicy
        request.timeoutInterval = originalRequest.timeoutInterval
        request.networkServiceType = originalRequest.networkServiceType
        for header in [
            "Accept",
            "Accept-Encoding",
            "If-None-Match",
            "If-Modified-Since",
            "Range"
        ] {
            if let value = originalRequest.value(forHTTPHeaderField: header) {
                request.setValue(value, forHTTPHeaderField: header)
            }
        }
    }

    private static func prepareJSONRequest(
        _ request: inout URLRequest,
        assumesHTTP3Capable: Bool,
        acceptsZstandard: Bool,
        cachePolicy: URLRequest.CachePolicy
    ) {
        prepareTransport(
            &request,
            assumesHTTP3Capable: assumesHTTP3Capable
        )
        request.cachePolicy = cachePolicy
        request.networkServiceType = .responsiveData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            acceptsZstandard
                ? modernContentEncodings
                : compatibilityContentEncodings,
            forHTTPHeaderField: "Accept-Encoding"
        )
    }

    private static func prepareTransport(
        _ request: inout URLRequest,
        assumesHTTP3Capable: Bool
    ) {
        request.assumesHTTP3Capable = assumesHTTP3Capable
        request.httpShouldHandleCookies = false
        request.allowsCellularAccess = true
    }
}
