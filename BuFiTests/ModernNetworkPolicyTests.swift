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
