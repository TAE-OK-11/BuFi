import XCTest
@testable import BuFi

final class QueueRestorePolicyTests: XCTestCase {
    func testRestoreRequiresMatchingSessionRevisionAndScope() {
        XCTAssertTrue(QueueRestorePolicy.isCurrent(
            expectedGeneration: 7,
            currentGeneration: 7,
            expectedRevision: 11,
            currentRevision: 11,
            expectedAccountScope: "account-a",
            activeAccountScope: "account-a"
        ))
        XCTAssertFalse(QueueRestorePolicy.isCurrent(
            expectedGeneration: 7,
            currentGeneration: 8,
            expectedRevision: 11,
            currentRevision: 11,
            expectedAccountScope: "account-a",
            activeAccountScope: "account-a"
        ))
        // This represents an explicit user mutation whose resulting queue is
        // still empty. A late restore must not use emptiness as authorization.
        XCTAssertFalse(QueueRestorePolicy.isCurrent(
            expectedGeneration: 7,
            currentGeneration: 7,
            expectedRevision: 11,
            currentRevision: 12,
            expectedAccountScope: "account-a",
            activeAccountScope: "account-a"
        ))
        XCTAssertFalse(QueueRestorePolicy.isCurrent(
            expectedGeneration: 7,
            currentGeneration: 7,
            expectedRevision: 11,
            currentRevision: 11,
            expectedAccountScope: "account-a",
            activeAccountScope: "account-b"
        ))
    }
}
