import Foundation
import XCTest
@testable import BuFi

final class HTTPContentDecoderTests: XCTestCase {
    func testAlreadyDecodedBodyPassesThrough() throws {
        let data = Data("{\"ok\":true}".utf8)
        XCTAssertEqual(
            try HTTPContentDecoder.decode(data, contentEncoding: "zstd"),
            data
        )
    }

    func testZstandardMagicIsNotDecodedWhenHeaderDoesNotDeclareZstandard() throws {
        let data = Data([0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x01, 0x02, 0x03])
        XCTAssertEqual(
            try HTTPContentDecoder.decode(data, contentEncoding: "gzip"),
            data
        )
    }

    func testContentEncodingUsesExactTokens() throws {
        let data = Data([0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x01, 0x02, 0x03])
        XCTAssertEqual(
            try HTTPContentDecoder.decode(data, contentEncoding: "notzstd"),
            data
        )
    }

    func testMalformedDeclaredZstandardFrameFailsCleanly() {
        let data = Data([0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x01, 0x02, 0x03])
        XCTAssertThrowsError(
            try HTTPContentDecoder.decode(data, contentEncoding: "zstd")
        ) { error in
            XCTAssertEqual((error as? URLError)?.code, .cannotDecodeContentData)
        }
    }

    func testSkippableFrameIsRecognizedAsZstandard() {
        let data = Data([0x50, 0x2A, 0x4D, 0x18, 0x00, 0x00, 0x00, 0x00])
        XCTAssertThrowsError(
            try HTTPContentDecoder.decode(data, contentEncoding: "zstd")
        )
    }
}
