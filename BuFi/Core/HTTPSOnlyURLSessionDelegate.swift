import Foundation
#if DEBUG
import OSLog
#endif

/// Allows HTTP and HTTPS servers while preventing an authenticated HTTPS
/// request from being redirected down to cleartext HTTP.
///
/// OpenSubsonic credentials are carried in query parameters, so an HTTPS -> HTTP
/// downgrade is still rejected before URLSession follows it. HTTP -> HTTP,
/// HTTP -> HTTPS, and HTTPS -> HTTPS redirects remain allowed.
///
/// The legacy type name is retained to avoid unnecessary churn at call sites.
/// `@unchecked Sendable` is retained because `NSObject` is not Sendable while
/// `URLSession` requires its delegate to cross executors. The type is immutable
/// after init (no stored mutable state), so the annotation is a language/bridge
/// concession rather than a concurrency hole.
final class HTTPSOnlyURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
#if DEBUG
    private static let metricsLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BuFi",
        category: "NetworkTransport"
    )
#endif

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let targetScheme = request.url?.scheme?.lowercased(),
              targetScheme == "http" || targetScheme == "https" else {
            completionHandler(nil)
            return
        }

        let sourceRequest = task.currentRequest ?? task.originalRequest
        let sourceScheme = sourceRequest?.url?.scheme?.lowercased()
        if sourceScheme == "https" && targetScheme == "http" {
            completionHandler(nil)
            return
        }

        var redirectedRequest = request
        ModernNetworkPolicy.prepareRedirect(
            &redirectedRequest,
            inheriting: sourceRequest
        )
        completionHandler(redirectedRequest)
    }

#if DEBUG
    /// Exposes the transport selected by CFNetwork without adding release-build
    /// logging or retaining per-task metrics. A capable origin reports `h3`;
    /// blocked or unsupported paths remain visible as their negotiated fallback.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        guard let transaction = metrics.transactionMetrics.last else { return }
        let host = transaction.request.url?.host ?? "unknown"
        let negotiatedProtocol = transaction.networkProtocolName ?? "unknown"
        Self.metricsLogger.debug(
            "host=\(host, privacy: .public) protocol=\(negotiatedProtocol, privacy: .public) reused=\(transaction.isReusedConnection)"
        )
    }
#endif
}
