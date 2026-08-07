import Foundation
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
        XCTAssertEqual(request.cachePolicy, .returnCacheDataElseLoad)
        XCTAssertEqual(request.networkServiceType, .responsiveData)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Accept-Encoding"),
            "zstd, br, gzip"
        )
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
        XCTAssertEqual(configuration.requestCachePolicy, .returnCacheDataElseLoad)
        XCTAssertNotNil(configuration.urlCache)
        XCTAssertFalse(configuration.allowsConstrainedNetworkAccess)
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
}
