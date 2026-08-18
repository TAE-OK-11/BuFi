import Foundation

/// Single source of truth for transient backend failures.
///
/// Only idempotent reads and diagnostics should consult this policy. Mutating
/// OpenSubsonic calls deliberately bypass it so a retry can never duplicate a
/// write. TLS/certificate failures are intentionally excluded: retrying them
/// wastes time and can hide a real security/configuration problem.
enum NetworkResiliencePolicy {
    private static let transientURLCodes: Set<URLError.Code> = [
        .timedOut,
        .cannotFindHost,
        .cannotConnectToHost,
        .dnsLookupFailed,
        .networkConnectionLost,
        .notConnectedToInternet,
        .resourceUnavailable,
        .cannotLoadFromNetwork
    ]

    static func shouldRetry(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        guard let urlError = error as? URLError else { return false }
        return transientURLCodes.contains(urlError.code)
    }

    static func shouldRetryHTTPStatus(_ statusCode: Int) -> Bool {
        switch statusCode {
        case 408, 425, 429, 500, 502, 503, 504:
            true
        default:
            false
        }
    }

    /// Small capped backoff for foreground diagnostics and other narrow read
    /// paths that do not have their own Retry-After aware policy.
    static func retryDelay(afterAttempt attempt: Int) -> Duration {
        switch max(0, attempt) {
        case 0: .milliseconds(150)
        case 1: .milliseconds(350)
        default: .milliseconds(750)
        }
    }
}
