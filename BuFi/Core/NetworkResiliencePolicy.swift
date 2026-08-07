import Foundation

/// Centralizes the narrow set of transport failures that are safe to retry for
/// idempotent health checks and metadata reads. Mutating OpenSubsonic calls do
/// not use this policy, which avoids accidentally duplicating writes.
enum NetworkResiliencePolicy {
    private static let transientURLCodes: Set<URLError.Code> = [
        .timedOut,
        .cannotFindHost,
        .cannotConnectToHost,
        .dnsLookupFailed,
        .networkConnectionLost,
        .notConnectedToInternet,
        .internationalRoamingOff,
        .callIsActive,
        .dataNotAllowed,
        .secureConnectionFailed
    ]

    static func shouldRetry(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        guard let urlError = error as? URLError else { return false }
        return transientURLCodes.contains(urlError.code)
    }

    static func shouldRetryHTTPStatus(_ statusCode: Int) -> Bool {
        switch statusCode {
        case 408, 425, 500, 502, 503, 504:
            true
        default:
            false
        }
    }

    static func retryDelay(afterAttempt attempt: Int) -> Duration {
        switch max(0, attempt) {
        case 0: .milliseconds(140)
        case 1: .milliseconds(320)
        default: .milliseconds(700)
        }
    }
}
