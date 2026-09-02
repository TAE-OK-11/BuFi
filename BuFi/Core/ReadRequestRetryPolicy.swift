import Foundation

/// Shared Core disposition for idempotent reads, artwork, and offline
/// downloads. Mutations never consult this type. All transport/status
/// classification is delegated to NetworkResiliencePolicy so backend retry
/// behavior cannot drift between OpenSubsonic, diagnostics, and media helpers.
enum CoreRequestClassifier {
    static func shouldRetry(statusCode: Int) -> Bool {
        NetworkResiliencePolicy.shouldRetryHTTPStatus(statusCode)
    }

    static func shouldRetry(error: Error) -> Bool {
        if error is CancellationError { return false }
        if let openSubsonic = error as? OpenSubsonicError {
            if case .http(let status) = openSubsonic {
                return shouldRetry(statusCode: status)
            }
            return false
        }
        return NetworkResiliencePolicy.shouldRetry(error)
    }

    static func shouldRetryImageFetch(_ error: Error) -> Bool {
        shouldRetry(error: error)
    }
}

/// Cached library / session data may be shown only after a transient failure.
/// Auth and address errors stay fail-closed so a bad password cannot reopen
/// the previous account's snapshot.
enum TransientServiceFailurePolicy {
    static func allowsCachedFallback(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let openSubsonic = error as? OpenSubsonicError {
            switch openSubsonic {
            case .http(let status):
                return CoreRequestClassifier.shouldRetry(statusCode: status)
            case .server(let code, _):
                if Self.isAuthenticationFailure(code: code) {
                    return false
                }
                return true
            case .invalidResponse,
                    .staleReadInterrupted:
                return true
            case .invalidServerURL,
                    .insecureServerURL,
                    .credentialsEmbeddedInServerURL,
                    .unsupportedTokenAuthentication,
                    .unsupportedAuthentication,
                    .conflictingAuthenticationParameters,
                    .invalidAPIKey:
                return false
            }
        }
        return CoreRequestClassifier.shouldRetry(error: error)
    }

    static func isAuthenticationFailure(_ error: Error) -> Bool {
        guard let openSubsonic = error as? OpenSubsonicError else { return false }
        switch openSubsonic {
        case .http(let status):
            return status == 401 || status == 403
        case .server(let code, _):
            return isAuthenticationFailure(code: code)
        default:
            return false
        }
    }

    private static func isAuthenticationFailure(code: Int?) -> Bool {
        guard let code else { return false }
        return (40...44).contains(code)
    }
}

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
        CoreRequestClassifier.shouldRetry(statusCode: statusCode)
    }

    func shouldRetry(error: Error) -> Bool {
        CoreRequestClassifier.shouldRetry(error: error)
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
