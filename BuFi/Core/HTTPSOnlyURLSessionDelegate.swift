import Foundation

/// Prevents authenticated requests from following an HTTPS-to-HTTP redirect.
/// OpenSubsonic credentials are carried in query parameters, so rejecting a
/// downgrade before URLSession follows it avoids leaking them to cleartext HTTP.
final class HTTPSOnlyURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard request.url?.scheme?.lowercased() == "https" else {
            completionHandler(nil)
            return
        }
        var redirectedRequest = request
        ModernNetworkPolicy.prepareRedirect(
            &redirectedRequest,
            inheriting: task.currentRequest ?? task.originalRequest
        )
        completionHandler(redirectedRequest)
    }
}
