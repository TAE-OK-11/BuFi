import Foundation
#if DEBUG
import OSLog
#endif

/// Prevents authenticated requests from following an HTTPS-to-HTTP redirect.
/// OpenSubsonic credentials are carried in query parameters, so rejecting a
/// downgrade before URLSession follows it avoids leaking them to cleartext HTTP.
///
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
        guard request.url?.scheme?.lowercased() == "https" else {
            completionHandler(nil)
            return
        }
        var redirectedRequest = request
        ModernNetworkPolicy.prepareRedirect(
            &redirectedRequest,
            inheriting: task.originalRequest ?? task.currentRequest
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
