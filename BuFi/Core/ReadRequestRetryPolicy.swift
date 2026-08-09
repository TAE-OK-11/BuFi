import Foundation

/// Retry decisions for idempotent OpenSubsonic reads.
///
/// Mutating endpoints never use this policy. Keeping the decision logic free of
/// URLSession state also makes the retry contract deterministic and testable.
struct ReadRequestRetryPolicy: Sendable {
    static let maximumRetryCount = 2
    static let maximumServerDelay: TimeInterval = 10

    private let baseDelay: TimeInterval

    init(baseDelay: TimeInterval = 0.35) {
        self.baseDelay = max(0, baseDelay)
    }

    func shouldRetry(statusCode: Int) -> Bool {
        statusCode == 408
            || statusCode == 425
            || statusCode == 429
            || (500...599).contains(statusCode)
    }

    func shouldRetry(error: Error) -> Bool {
        if error is CancellationError { return false }

        let value = error as NSError
        guard value.domain == NSURLErrorDomain else {
            return false
        }
        let transientCodes: Set<Int> = [
            URLError.Code.timedOut.rawValue,
            URLError.Code.cannotFindHost.rawValue,
            URLError.Code.cannotConnectToHost.rawValue,
            URLError.Code.networkConnectionLost.rawValue,
            URLError.Code.dnsLookupFailed.rawValue,
            URLError.Code.notConnectedToInternet.rawValue,
            URLError.Code.resourceUnavailable.rawValue
        ]
        // Cancellation, authentication, TLS, malformed responses, and
        // content-decoding failures require caller or server intervention.
        return transientCodes.contains(value.code)
    }

    /// Returns a server-directed delay when present, otherwise a jittered
    /// exponential delay. `retryNumber` is one-based.
    func delay(
        retryNumber: Int,
        retryAfterHeader: String?,
        now: Date = Date(),
        jitter: Double
    ) -> TimeInterval? {
        if let retryAfterHeader {
            let value = retryAfterHeader.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            if let retryAfter = Self.retryAfterDelay(
                value: value,
                now: now
            ) {
                guard retryAfter <= Self.maximumServerDelay else {
                    // Waiting minutes inside a foreground API operation is
                    // wasteful, while retrying sooner would violate the
                    // server's explicit back-pressure instruction.
                    return nil
                }
                return max(0, retryAfter)
            }
        }

        let boundedRetry = min(
            max(1, retryNumber),
            Self.maximumRetryCount
        )
        let multiplier = boundedRetry == 1 ? 1.0 : 2.0
        let boundedJitter = min(1.25, max(0.75, jitter))
        return min(
            Self.maximumServerDelay,
            baseDelay * multiplier * boundedJitter
        )
    }

    private static func retryAfterDelay(
        value: String,
        now: Date
    ) -> TimeInterval? {
        guard !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) {
            return seconds.isFinite && seconds >= 0 ? seconds : nil
        }

        // IMF-fixdate is the current HTTP-date representation used by
        // Retry-After. A formatter is created per rare retry response because
        // DateFormatter is mutable and not Sendable.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}
