import XCTest
@testable import BuFi

final class AppModelDisplayTests: XCTestCase {
    func testServerDisplayAddressKeepsHostExplicitPortAndBasePath() {
        let value = AppModel.serverDisplayAddress(
            from: "https://alice:super-secret@Music.Example.COM:8443/navidrome/?token=private#account"
        )

        XCTAssertEqual(value, "music.example.com:8443/navidrome")
        XCTAssertFalse(value.contains("https"))
        XCTAssertFalse(value.contains("alice"))
        XCTAssertFalse(value.contains("super-secret"))
        XCTAssertFalse(value.contains("private"))
        XCTAssertFalse(value.contains("account"))
    }

    func testServerDisplayAddressPreservesExplicitDefaultPort() {
        XCTAssertEqual(
            AppModel.serverDisplayAddress(
                from: "https://music.example.com:443/subsonic/"
            ),
            "music.example.com:443/subsonic"
        )
    }

    func testServerDisplayAddressFormatsIPv6WithoutCredentials() {
        let value = AppModel.serverDisplayAddress(
            from: "https://listener:password@[2001:DB8::1]:9443/music/?apiKey=secret#profile"
        )

        XCTAssertEqual(value, "[2001:db8::1]:9443/music")
        XCTAssertFalse(value.contains("listener"))
        XCTAssertFalse(value.contains("password"))
        XCTAssertFalse(value.contains("secret"))
        XCTAssertFalse(value.contains("profile"))
    }

    func testServerDisplayAddressRejectsValuesWithoutAHost() {
        XCTAssertEqual(
            AppModel.serverDisplayAddress(from: "not a server URL"),
            ""
        )
    }

    func testHomeRevisionPolicyRequiresMatchingRevisionAndSource() {
        XCTAssertTrue(
            HomeRevisionPolicy.canCommit(
                sourceRevision: 4,
                currentRevision: 4,
                source: "latest",
                current: "latest"
            )
        )
        XCTAssertFalse(
            HomeRevisionPolicy.canCommit(
                sourceRevision: 3,
                currentRevision: 4,
                source: "latest",
                current: "latest"
            )
        )
        XCTAssertFalse(
            HomeRevisionPolicy.canCommit(
                sourceRevision: 4,
                currentRevision: 4,
                source: "stale",
                current: "latest"
            )
        )
    }

    func testDownloadBatchPolicyBoundsConcurrentWork() {
        XCTAssertEqual(
            DownloadBatchPolicy.initialTaskCount(itemCount: -1),
            0
        )
        XCTAssertEqual(
            DownloadBatchPolicy.initialTaskCount(itemCount: 1),
            1
        )
        XCTAssertEqual(
            DownloadBatchPolicy.initialTaskCount(itemCount: 20),
            2
        )
    }
}
