import Foundation

private enum OpenSubsonicDiagnosticTransport {
    /// Keep one tiny diagnostics connection pool so repeated Settings probes can
    /// reuse DNS/TLS/HTTP state instead of paying cold-start cost every time.
    /// Diagnostics should fail fast when there is no route rather than waiting
    /// behind the normal API connectivity policy.
    static let session: URLSession = {
        let configuration = ModernNetworkPolicy.makeEphemeralConfiguration(
            requestTimeout: 3,
            resourceTimeout: 4,
            maximumConnectionsPerHost: 1,
            allowsExpensiveNetworkAccess: true,
            allowsConstrainedNetworkAccess: true,
            waitsForConnectivity: false
        )
        return URLSession(
            configuration: configuration,
            delegate: HTTPSOnlyURLSessionDelegate(),
            delegateQueue: nil
        )
    }()
}

/// Run the timed network await outside OpenSubsonicClient's actor. If the
/// client's actor is busy publishing metadata or serving another API call, an
/// actor-hop after URLSession completes must not be counted as server latency.
private enum OpenSubsonicLatencyProbe {
    private static let maximumResponseBytes = 256 * 1_024

    static func measure(
        request: URLRequest,
        session: URLSession
    ) async throws -> Double {
        try Task.checkCancellation()
        let clock = ContinuousClock()
        let startedAt = clock.now
        let (data, response) = try await session.data(for: request)
        let elapsed = OpenSubsonicClient.milliseconds(
            from: startedAt.duration(to: clock.now)
        )
        try Task.checkCancellation()

        guard data.count <= maximumResponseBytes else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        guard let http = response as? HTTPURLResponse else {
            throw OpenSubsonicError.invalidResponse
        }
        guard http.url?.scheme?.lowercased() == "https" else {
            throw OpenSubsonicError.insecureServerURL
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenSubsonicError.http(http.statusCode)
        }

        let envelope = try JSONDecoder().decode(
            DiagnosticPingEnvelope.self,
            from: data
        )
        guard envelope.response.status == "ok" else {
            throw OpenSubsonicError.server(
                code: envelope.response.error?.code,
                message: envelope.response.error?.message
                    ?? String(localized: "서버 연결에 실패했습니다.")
            )
        }
        return elapsed
    }
}

extension OpenSubsonicClient {
    /// Measures a representative authenticated OpenSubsonic RTT. iOS does
    /// not expose a general-purpose ICMP ping API to normal apps, so this keeps
    /// the probe on the exact HTTPS route BuFi actually uses while stripping
    /// unrelated client-side work from the timed interval.
    ///
    /// Three back-to-back probes are normally enough: a cold first request can
    /// establish DNS/TLS/QUIC state and the following requests reuse it. The
    /// median reports typical playback-path latency instead of the optimistic
    /// best sample, which hid jitter that actually stalls streams.
    func measuredServerLatency(sampleCount: Int = 3) async throws -> Double {
        let targetCount = min(max(sampleCount, 1), 4)
        let minimumSuccessfulSamples = min(targetCount, 2)
        let maximumAttempts = targetCount + 1
        let session = OpenSubsonicDiagnosticTransport.session

        var samples: [Double] = []
        samples.reserveCapacity(targetCount)
        var lastError: Error?
        var attempts = 0

        while samples.count < targetCount, attempts < maximumAttempts {
            try Task.checkCancellation()
            attempts += 1
            do {
                let request = try latencyProbeRequest()
                let sample = try await OpenSubsonicLatencyProbe.measure(
                    request: request,
                    session: session
                )
                samples.append(sample)

                // If two warm samples already agree, do not spend another RTT
                // merely to produce the same number. A large first/second gap
                // (typical cold connection) still forces the third sample.
                if samples.count >= minimumSuccessfulSamples,
                   samples.count < targetCount,
                   Self.recentLatencySamplesAreStable(samples) {
                    break
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard Self.isRetryableDiagnosticFailure(error) else {
                    throw error
                }
                lastError = error
            }
        }

        guard samples.count >= minimumSuccessfulSamples,
              let baseline = Self.representativeLatency(from: samples) else {
            throw lastError ?? URLError(.cannotConnectToHost)
        }
        return baseline
    }

    static func milliseconds(from duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    /// Median of successful probe samples. The minimum is too optimistic for
    /// a badge that should reflect the path playback actually sees.
    static func representativeLatency(from samples: [Double]) -> Double? {
        let values = samples.filter { $0.isFinite && $0 >= 0 }.sorted()
        guard !values.isEmpty else { return nil }
        let middle = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (values[middle - 1] + values[middle]) / 2
        }
        return values[middle]
    }

    private func latencyProbeRequest() throws -> URLRequest {
        // Authentication generation intentionally happens before timing starts.
        // It validates the real OpenSubsonic route without inflating network RTT
        // with random salt/MD5 work performed locally on the device.
        let url = try endpointURL("ping")
        var request = URLRequest(url: url)
        ModernNetworkPolicy.prepareDiagnosticPingRequest(&request)
        return request
    }

    private static func recentLatencySamplesAreStable(
        _ samples: [Double]
    ) -> Bool {
        guard samples.count >= 2 else { return false }
        let recent = samples.suffix(2)
        guard let low = recent.min(), let high = recent.max() else {
            return false
        }
        // Tight absolute tolerance for low-latency LAN/nearby servers, with a
        // small proportional allowance for normal WAN scheduling variance.
        return high - low <= max(1.5, low * 0.05)
    }

    private static func isRetryableDiagnosticFailure(_ error: Error) -> Bool {
        if NetworkResiliencePolicy.shouldRetry(error) { return true }
        guard let subsonicError = error as? OpenSubsonicError else { return false }
        if case .http(let statusCode) = subsonicError {
            return NetworkResiliencePolicy.shouldRetryHTTPStatus(statusCode)
        }
        return false
    }
}

private struct DiagnosticPingEnvelope: Decodable {
    struct Response: Decodable {
        struct ServerError: Decodable {
            let code: Int?
            let message: String?
        }

        let status: String
        let error: ServerError?
    }

    let response: Response

    private enum CodingKeys: String, CodingKey {
        case response = "subsonic-response"
    }
}
