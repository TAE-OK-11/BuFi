from pathlib import Path
import re


def sub_once(path: str, pattern: str, replacement: str) -> None:
    file = Path(path)
    text = file.read_text()
    updated, count = re.subn(pattern, replacement, text, count=1, flags=re.MULTILINE)
    if count != 1:
        raise SystemExit(f"expected one match in {path}, found {count}")
    file.write_text(updated)


Path("BuFi/Core/ModernNetworkPolicy.swift").write_text('''import Foundation

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
''')

sub_once(
    "BuFi/Core/OpenSubsonicClient.swift",
    re.escape('''        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 18
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.waitsForConnectivity = true
'''),
    '''        let configuration = ModernNetworkPolicy.makeEphemeralConfiguration(
            requestTimeout: 18,
            resourceTimeout: 60,
            maximumConnectionsPerHost: 6,
            allowsExpensiveNetworkAccess: true,
            allowsConstrainedNetworkAccess: true
        )
'''
)

sub_once(
    "BuFi/Core/OpenSubsonicClient.swift",
    re.escape('''        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            acceptsZstandard ? "zstd, br, gzip" : "br, gzip",
            forHTTPHeaderField: "Accept-Encoding"
        )
        request.assumesHTTP3Capable = true
'''),
    '''        var request = URLRequest(url: url)
        ModernNetworkPolicy.prepareAPIRequest(
            &request,
            acceptsZstandard: acceptsZstandard
        )
'''
)

sub_once(
    "BuFi/Core/ArtworkStore.swift",
    re.escape('''        let request = ImageRequest(
            url: url,
            processors: [.resize(width: requestedPixelSize)]
        )
'''),
    '''        var urlRequest = URLRequest(url: url)
        ModernNetworkPolicy.prepareImageRequest(&urlRequest)
        let request = ImageRequest(
            urlRequest: urlRequest,
            processors: [.resize(width: requestedPixelSize)]
        )
'''
)

sub_once(
    "BuFi/Core/ArtworkStore.swift",
    re.escape('''        var configuration = ImagePipeline.Configuration.withDataCache(
            name: name,
            sizeLimit: 256 * 1_024 * 1_024
        )
'''),
    '''        var configuration = ImagePipeline.Configuration.withDataCache(
            name: name,
            sizeLimit: 256 * 1_024 * 1_024
        )
        configuration.dataLoader = DataLoader(
            configuration: ModernNetworkPolicy.makeEphemeralConfiguration(
                requestTimeout: 20,
                resourceTimeout: 120,
                maximumConnectionsPerHost: 6,
                allowsExpensiveNetworkAccess: true,
                allowsConstrainedNetworkAccess: true
            )
        )
        configuration.maximumResponseDataSize = 32 * 1_024 * 1_024
'''
)

sub_once(
    "BuFi/Core/OfflineStore.swift",
    re.escape('''            let (temporary, response) = try await session.download(from: remote)
'''),
    '''            var request = URLRequest(url: remote)
            ModernNetworkPolicy.prepareMediaRequest(&request)
            let (temporary, response) = try await session.download(for: request)
'''
)

sub_once(
    "BuFi/Core/OfflineStore.swift",
    re.escape('''    private static func makeDownloadSession(allowsExpensiveAccess: Bool) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.allowsExpensiveNetworkAccess = allowsExpensiveAccess
        configuration.allowsConstrainedNetworkAccess = allowsExpensiveAccess
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(
'''),
    '''    private static func makeDownloadSession(allowsExpensiveAccess: Bool) -> URLSession {
        let configuration = ModernNetworkPolicy.makeEphemeralConfiguration(
            requestTimeout: 30,
            resourceTimeout: 60 * 60,
            maximumConnectionsPerHost: 2,
            allowsExpensiveNetworkAccess: allowsExpensiveAccess,
            allowsConstrainedNetworkAccess: allowsExpensiveAccess
        )
        return URLSession(
'''
)

Path("BuFi/Core/HTTPSOnlyURLSessionDelegate.swift").write_text('''import Foundation

/// Prevents authenticated requests from following an HTTPS-to-HTTP redirect.
/// OpenSubsonic credentials are carried in query parameters, so rejecting a
/// downgrade before URLSession follows it avoids leaking them to cleartext HTTP.
final class HTTPSOnlyURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard request.url?.scheme?.lowercased() == "https" else {
            completionHandler(nil)
            return
        }
        var redirectedRequest = request
        ModernNetworkPolicy.prepareRedirect(&redirectedRequest)
        completionHandler(redirectedRequest)
    }
}
''')

Path("BuFiTests/ModernNetworkPolicyTests.swift").write_text('''import Foundation
import XCTest
@testable import BuFi

final class ModernNetworkPolicyTests: XCTestCase {
    func testAPIRequestEnablesHTTP3AndModernCompression() throws {
        var request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://example.com/rest/ping.view"))
        )

        ModernNetworkPolicy.prepareAPIRequest(&request, acceptsZstandard: true)

        XCTAssertTrue(request.assumesHTTP3Capable)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Accept-Encoding"),
            "zstd, br, gzip"
        )
    }

    func testCompatibilityRetryDropsOnlyZstandard() throws {
        var request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://example.com/rest/ping.view"))
        )

        ModernNetworkPolicy.prepareAPIRequest(&request, acceptsZstandard: false)

        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "br, gzip")
        XCTAssertTrue(request.assumesHTTP3Capable)
    }

    func testMediaRequestPreservesByteRangeSemantics() throws {
        var request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://example.com/rest/stream.view"))
        )

        ModernNetworkPolicy.prepareMediaRequest(&request)

        XCTAssertTrue(request.assumesHTTP3Capable)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
    }
}
''')

Path("Docs/NETWORKING.md").write_text('''# BuFi networking policy

BuFi uses Apple's URL Loading System and AVFoundation rather than embedding a
third-party QUIC stack. This keeps transport security, connection migration,
radio scheduling, and background behavior integrated with iOS.

## Enabled transport behavior

- API, artwork, and offline-download URL requests set `assumesHTTP3Capable` so
  CFNetwork races QUIC immediately without waiting for a previous Alt-Svc
  discovery. HTTP/2 remains the automatic fallback.
- TLS 1.3 is negotiated automatically when the origin supports it. App Transport
  Security and the HTTPS-only redirect delegate keep cleartext and downgrade
  redirects out of authenticated traffic.
- OpenSubsonic JSON requests advertise `zstd, br, gzip` in that order. BuFi has a
  bounded zstd decoder and retries with `br, gzip` if a server returns malformed
  or unsupported zstd content.
- Artwork requests use HTTP/3 racing and the system Brotli/gzip decoder. zstd is
  not advertised to Nuke because those bytes do not pass through BuFi's custom
  zstd decoder.
- Offline media downloads use HTTP/3 racing but explicitly request `identity`
  content coding. Audio is already compressed, and preserving byte identity is
  necessary for reliable range requests, seeking, and resume offsets.
- Cookies, ambient credential storage, and URLSession response caches are
  disabled for authenticated API and download sessions. BuFi's own scoped image
  and offline caches remain in control.

## System-managed features

AVPlayer/AVURLAsset does not expose the `assumesHTTP3Capable` switch. Streaming
therefore negotiates HTTP/3 through the server's Alt-Svc advertisement and the
system connection cache, with HTTP/2 fallback. QUIC 0-RTT, ECH, congestion
control, and TLS session resumption are also selected by CFNetwork and the OS;
there is no supported application flag to force them.
''')

sub_once(
    "README.md",
    re.escape(
        "- HTTP/3-capable API requests plus gzip, Brotli, and bounded Zstandard response decoding\n"
    ),
    "- HTTP/3 racing for API, artwork, and offline downloads; HTTP/2 fallback; gzip, Brotli, and bounded Zstandard API decoding\n"
)

for temporary in [
    ".github/workflows/network-upgrade.yml",
    ".github/workflows/network-upgrade-trigger.yml",
    "Scripts/apply-modern-network.py",
]:
    Path(temporary).unlink(missing_ok=True)
