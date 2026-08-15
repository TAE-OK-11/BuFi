import Foundation
import XCTest
@testable import BuFi

final class ReadRequestRetryPolicyTests: XCTestCase {
    private let policy = ReadRequestRetryPolicy(baseDelay: 1)

    func testRetriesOnlyTransientHTTPStatuses() {
        XCTAssertTrue(policy.shouldRetry(statusCode: 408))
        XCTAssertTrue(policy.shouldRetry(statusCode: 429))
        XCTAssertTrue(policy.shouldRetry(statusCode: 500))
        XCTAssertTrue(policy.shouldRetry(statusCode: 599))

        XCTAssertFalse(policy.shouldRetry(statusCode: 401))
        XCTAssertFalse(policy.shouldRetry(statusCode: 403))
        XCTAssertFalse(policy.shouldRetry(statusCode: 404))
        XCTAssertFalse(policy.shouldRetry(statusCode: 400))
    }

    func testRetriesTransientNetworkErrorsButNotCancellationOrDecoding() {
        XCTAssertTrue(policy.shouldRetry(error: URLError(.timedOut)))
        XCTAssertTrue(policy.shouldRetry(error: URLError(.networkConnectionLost)))
        XCTAssertTrue(policy.shouldRetry(error: URLError(.notConnectedToInternet)))
        XCTAssertTrue(policy.shouldRetry(error: URLError(.secureConnectionFailed)))
        XCTAssertTrue(policy.shouldRetry(error: OpenSubsonicError.http(503)))
        XCTAssertFalse(policy.shouldRetry(error: OpenSubsonicError.http(404)))

        XCTAssertFalse(policy.shouldRetry(error: CancellationError()))
        XCTAssertFalse(policy.shouldRetry(error: URLError(.cancelled)))
        XCTAssertFalse(policy.shouldRetry(error: URLError(.userAuthenticationRequired)))
        XCTAssertFalse(policy.shouldRetry(error: URLError(.cannotDecodeContentData)))
    }

    func testExponentialDelayUsesBoundedJitter() throws {
        XCTAssertEqual(
            try XCTUnwrap(policy.delay(
                retryNumber: 1,
                retryAfterHeader: nil,
                jitter: 0.75
            )),
            0.75,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(policy.delay(
                retryNumber: 2,
                retryAfterHeader: nil,
                jitter: 1.25
            )),
            2.5,
            accuracy: 0.001
        )
    }

    func testRetryAfterIsHonoredAndLongServerDelayStopsRetry() throws {
        XCTAssertEqual(
            try XCTUnwrap(policy.delay(
                retryNumber: 1,
                retryAfterHeader: "3",
                jitter: 1
            )),
            3,
            accuracy: 0.001
        )
        XCTAssertNil(
            policy.delay(
                retryNumber: 1,
                retryAfterHeader: "120",
                jitter: 1
            )
        )
    }

    func testRetryAfterHTTPDateAndInvalidValues() throws {
        let now = try XCTUnwrap(httpDate("Sun, 06 Nov 1994 08:49:30 GMT"))
        XCTAssertEqual(
            try XCTUnwrap(policy.delay(
                retryNumber: 1,
                retryAfterHeader: "Sun, 06 Nov 1994 08:49:35 GMT",
                now: now,
                jitter: 1
            )),
            5,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(policy.delay(
                retryNumber: 1,
                retryAfterHeader: "Sun, 06 Nov 1994 08:49:20 GMT",
                now: now,
                jitter: 1
            )),
            0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(policy.delay(
                retryNumber: 1,
                retryAfterHeader: "-3",
                now: now,
                jitter: 1
            )),
            1,
            accuracy: 0.001
        )
        XCTAssertEqual(
            try XCTUnwrap(policy.delay(
                retryNumber: 1,
                retryAfterHeader: "invalid",
                now: now,
                jitter: 1
            )),
            1,
            accuracy: 0.001
        )
    }

    func testRetryBudgetIsTwoRetries() {
        XCTAssertEqual(ReadRequestRetryPolicy.maximumRetryCount, 2)
    }

    func testCoreClassifierMatchesReadPolicyAndRejectsPermanentFailures() {
        XCTAssertTrue(CoreRequestClassifier.shouldRetry(statusCode: 429))
        XCTAssertTrue(CoreRequestClassifier.shouldRetry(statusCode: 503))
        XCTAssertFalse(CoreRequestClassifier.shouldRetry(statusCode: 404))
        XCTAssertTrue(
            CoreRequestClassifier.shouldRetryImageFetch(URLError(.timedOut))
        )
        XCTAssertFalse(
            CoreRequestClassifier.shouldRetryImageFetch(CancellationError())
        )
        XCTAssertFalse(
            CoreRequestClassifier.shouldRetry(
                error: OpenSubsonicError.invalidResponse
            )
        )
    }

    private func httpDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
        return formatter.date(from: value)
    }
}
