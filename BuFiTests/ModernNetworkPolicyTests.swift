import Foundation
import XCTest
@testable import BuFi

final class ModernNetworkPolicyTests: XCTestCase {
    private actor ConcurrencyProbe {
        private var active = 0
        private var peak = 0

        func begin() {
            active += 1
            peak = max(peak, active)
        }

        func end() {
            active = max(0, active - 1)
        }

        func maximum() -> Int { peak }
    }

    func testAPIRequestEnablesHTTP3AndModernCompression() throws {
        var request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://example.com/rest/ping.view"))
        )

        ModernNetworkPolicy.prepareAPIRequest(&request, acceptsZstandard: true)

        XCTAssertTrue(request.assumesHTTP3Capable)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.networkServiceType, .responsiveData)
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

    func testExternalAPIUsesHTTP3AndCachedJSONPolicy() throws {
        var request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://api.example.com/recommendations"))
        )

        ModernNetworkPolicy.prepareExternalAPIRequest(
            &request,
            acceptsZstandard: true
        )

        XCTAssertTrue(request.assumesHTTP3Capable)
        XCTAssertEqual(request.cachePolicy, .useProtocolCachePolicy)
        XCTAssertEqual(request.networkServiceType, .responsiveData)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Accept-Encoding"),
            "zstd, br, gzip"
        )
    }

    func testImageRequestUsesHTTP3WithoutZstandard() throws {
        var request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://example.com/cover.jpg"))
        )

        ModernNetworkPolicy.prepareImageRequest(&request)

        XCTAssertTrue(request.assumesHTTP3Capable)
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.networkServiceType, .responsiveData)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "br, gzip")
    }

    func testHealthCheckIsShortLivedAndUncached() throws {
        var request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://example.com/rest/ping.view"))
        )

        ModernNetworkPolicy.prepareHealthCheckRequest(&request)

        XCTAssertTrue(request.assumesHTTP3Capable)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.timeoutInterval, 8)
        XCTAssertEqual(request.networkServiceType, .responsiveData)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Accept-Encoding"),
            "zstd, br, gzip"
        )

        var compatibilityRequest = URLRequest(
            url: try XCTUnwrap(URL(string: "https://example.com/rest/ping.view"))
        )
        ModernNetworkPolicy.prepareHealthCheckRequest(
            &compatibilityRequest,
            acceptsZstandard: false
        )
        XCTAssertTrue(compatibilityRequest.assumesHTTP3Capable)
        XCTAssertEqual(
            compatibilityRequest.value(forHTTPHeaderField: "Accept-Encoding"),
            "br, gzip"
        )
    }

    func testSessionConfigurationReusesFallbackConnections() {
        let configuration = ModernNetworkPolicy.makeEphemeralConfiguration(
            requestTimeout: 10,
            resourceTimeout: 20,
            maximumConnectionsPerHost: 6,
            allowsExpensiveNetworkAccess: true,
            allowsConstrainedNetworkAccess: true
        )

        XCTAssertTrue(configuration.waitsForConnectivity)
        XCTAssertTrue(configuration.httpShouldUsePipelining)
        XCTAssertEqual(configuration.httpMaximumConnectionsPerHost, 6)
        XCTAssertNil(configuration.urlCache)
        XCTAssertFalse(configuration.httpShouldSetCookies)
    }

    func testCachedConfigurationRetainsModernSessionPolicy() {
        let configuration = ModernNetworkPolicy.makeCachedConfiguration(
            requestTimeout: 12,
            resourceTimeout: 24,
            maximumConnectionsPerHost: 2,
            memoryCapacity: 2 * 1_024 * 1_024,
            diskCapacity: 12 * 1_024 * 1_024
        )

        XCTAssertTrue(configuration.waitsForConnectivity)
        XCTAssertTrue(configuration.httpShouldUsePipelining)
        XCTAssertEqual(configuration.requestCachePolicy, .useProtocolCachePolicy)
        XCTAssertNotNil(configuration.urlCache)
        XCTAssertFalse(configuration.allowsConstrainedNetworkAccess)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCredentialStorage)
    }

    func testMediaRequestPreservesByteRangeSemantics() throws {
        var request = URLRequest(
            url: try XCTUnwrap(URL(string: "https://example.com/rest/stream.view"))
        )

        ModernNetworkPolicy.prepareMediaRequest(&request)

        XCTAssertTrue(request.assumesHTTP3Capable)
        XCTAssertEqual(request.networkServiceType, .avStreaming)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
    }

    func testMediaRedirectRetainsRangeSafeTransportPolicy() throws {
        var original = URLRequest(
            url: try XCTUnwrap(URL(string: "https://music.example.com/rest/download.view"))
        )
        ModernNetworkPolicy.prepareMediaRequest(&original)
        original.timeoutInterval = 37
        original.setValue(
            "Bearer source-secret",
            forHTTPHeaderField: "Authorization"
        )

        var redirected = URLRequest(
            url: try XCTUnwrap(URL(string: "https://cdn.example.net/object/audio"))
        )
        ModernNetworkPolicy.prepareRedirect(
            &redirected,
            inheriting: original
        )

        XCTAssertTrue(redirected.assumesHTTP3Capable)
        XCTAssertEqual(redirected.networkServiceType, .avStreaming)
        XCTAssertEqual(redirected.timeoutInterval, 37)
        XCTAssertEqual(redirected.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(
            redirected.value(forHTTPHeaderField: "Accept-Encoding"),
            "identity"
        )
        XCTAssertEqual(
            redirected.value(forHTTPHeaderField: "Accept"),
            "audio/*, application/octet-stream;q=0.9, */*;q=0.1"
        )
        XCTAssertNil(redirected.value(forHTTPHeaderField: "Authorization"))
    }

    func testAPIRedirectRetainsCompressionFallbackChoice() throws {
        var original = URLRequest(
            url: try XCTUnwrap(URL(string: "https://music.example.com/rest/ping.view"))
        )
        ModernNetworkPolicy.prepareAPIRequest(
            &original,
            acceptsZstandard: false
        )

        var redirected = URLRequest(
            url: try XCTUnwrap(URL(string: "https://api.example.net/ping"))
        )
        ModernNetworkPolicy.prepareRedirect(
            &redirected,
            inheriting: original
        )

        XCTAssertTrue(redirected.assumesHTTP3Capable)
        XCTAssertEqual(redirected.networkServiceType, .responsiveData)
        XCTAssertEqual(
            redirected.value(forHTTPHeaderField: "Accept-Encoding"),
            "br, gzip"
        )
        XCTAssertEqual(
            redirected.value(forHTTPHeaderField: "Accept"),
            "application/json"
        )
    }

    func testMutationImpactsAreEndpointScoped() {
        let metadataPolicy = OpenSubsonicRequestPolicy.responseCachePolicy(
            for: "getSong"
        )
        let queuePolicy = OpenSubsonicRequestPolicy.responseCachePolicy(
            for: "getPlayQueue"
        )
        var state = OpenSubsonicCacheRevisionState()
        let metadataRevision = state.revision(
            for: metadataPolicy.dependencies
        )
        let queueRevision = state.revision(for: queuePolicy.dependencies)

        let telemetry = OpenSubsonicRequestPolicy.mutationImpact(
            for: "reportPlayback"
        )
        XCTAssertFalse(telemetry.participatesInStaleReadBarrier)
        XCTAssertEqual(
            OpenSubsonicRequestPolicy.mutationImpact(for: "scrobble"),
            .none
        )
        state.begin(telemetry)
        state.finish(telemetry)
        XCTAssertEqual(
            state.revision(for: metadataPolicy.dependencies),
            metadataRevision
        )

        let queueSave = OpenSubsonicRequestPolicy.mutationImpact(
            for: "savePlayQueue"
        )
        XCTAssertEqual(queueSave.invalidatedDependencies, [.playQueue])
        state.begin(queueSave)
        XCTAssertTrue(state.hasMutation(affecting: queuePolicy.dependencies))
        XCTAssertFalse(state.hasMutation(affecting: metadataPolicy.dependencies))
        XCTAssertEqual(
            state.revision(for: metadataPolicy.dependencies),
            metadataRevision
        )
        XCTAssertNotEqual(
            state.revision(for: queuePolicy.dependencies),
            queueRevision
        )
        state.finish(queueSave)
    }

    func testPlaybackTelemetryRetriesOnlyTransientFailures() {
        XCTAssertTrue(PlaybackTelemetryRetryPolicy.shouldRetry(
            URLError(.networkConnectionLost)
        ))
        XCTAssertTrue(PlaybackTelemetryRetryPolicy.shouldRetry(
            OpenSubsonicError.http(503)
        ))
        XCTAssertTrue(PlaybackTelemetryRetryPolicy.shouldRetry(
            OpenSubsonicError.http(429)
        ))
        XCTAssertFalse(PlaybackTelemetryRetryPolicy.shouldRetry(
            OpenSubsonicError.invalidResponse
        ))
        XCTAssertFalse(PlaybackTelemetryRetryPolicy.shouldRetry(
            CancellationError()
        ))
    }

    func testFavoriteMutationInvalidatesOnlyRelevantRepresentations() {
        let songStar = OpenSubsonicRequestPolicy.mutationImpact(
            for: "star",
            queryItems: [URLQueryItem(name: "id", value: "song-1")]
        )

        XCTAssertTrue(songStar.invalidatedDependencies.contains(.favorites))
        XCTAssertTrue(songStar.invalidatedDependencies.contains(.songDetails))
        XCTAssertTrue(songStar.invalidatedDependencies.contains(.albumDetails))
        XCTAssertTrue(songStar.invalidatedDependencies.contains(.libraryLists))
        XCTAssertTrue(songStar.invalidatedDependencies.contains(.recommendations))
        XCTAssertFalse(
            OpenSubsonicRequestPolicy.responseCachePolicy(
                for: "getLyricsBySongId"
            ).dependencies.contains {
                songStar.invalidatedDependencies.contains($0)
            }
        )
        XCTAssertFalse(
            OpenSubsonicRequestPolicy.responseCachePolicy(
                for: "getGenres"
            ).dependencies.contains {
                songStar.invalidatedDependencies.contains($0)
            }
        )
    }

    func testResponseCacheTTLsAreEndpointAware() {
        XCTAssertEqual(
            OpenSubsonicRequestPolicy.responseCachePolicy(
                for: "getLyricsBySongId"
            ).lifetime,
            0
        )
        XCTAssertEqual(
            OpenSubsonicRequestPolicy.responseCachePolicy(
                for: "getSong"
            ).lifetime,
            5 * 60
        )
        XCTAssertEqual(
            OpenSubsonicRequestPolicy.responseCachePolicy(
                for: "getAlbumList2",
                queryItems: [URLQueryItem(name: "type", value: "random")]
            ).lifetime,
            30
        )
        XCTAssertEqual(
            OpenSubsonicRequestPolicy.responseCachePolicy(
                for: "getAlbumList2",
                queryItems: [URLQueryItem(name: "type", value: "newest")]
            ).lifetime,
            2 * 60
        )
        XCTAssertEqual(
            OpenSubsonicRequestPolicy.responseCachePolicy(
                for: "unclassifiedEndpoint"
            ).lifetime,
            0
        )
        XCTAssertEqual(
            OpenSubsonicRequestPolicy.responseCachePolicy(
                for: "getSong"
            ).revalidation,
            .timeToLive
        )
    }

    func testHomeEnrichmentLimiterBoundsConcurrentOperations() async {
        let expectedLimit = OpenSubsonicRequestPolicy
            .homeEnrichmentConcurrencyLimit
        let limiter = HomeEnrichmentRequestLimiter(limit: expectedLimit)
        let probe = ConcurrencyProbe()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    _ = try? await limiter.withPermit {
                        await probe.begin()
                        try await Task.sleep(for: .milliseconds(20))
                        await probe.end()
                    }
                }
            }
        }

        let maximum = await probe.maximum()
        XCTAssertEqual(expectedLimit, 5)
        XCTAssertEqual(maximum, expectedLimit)
    }
}
