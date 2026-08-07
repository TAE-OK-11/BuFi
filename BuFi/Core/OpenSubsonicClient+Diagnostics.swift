import Foundation

extension OpenSubsonicClient {
    /// Measures the real authenticated OpenSubsonic request path instead of an
    /// ICMP echo. The result therefore includes DNS/connection reuse, TLS,
    /// HTTP/3 or fallback transport, and the server's `ping.view` handling.
    func measuredServerLatency(sampleCount: Int = 3) async throws -> Double {
        let targetCount = min(max(sampleCount, 1), 5)
        let minimumSuccessfulSamples = min(targetCount, 2)
        let maximumAttempts = targetCount + 2
        let configuration = ModernNetworkPolicy.makeEphemeralConfiguration(
            requestTimeout: 8,
            resourceTimeout: 12,
            maximumConnectionsPerHost: 2,
            allowsExpensiveNetworkAccess: true,
            allowsConstrainedNetworkAccess: true
        )
        let session = URLSession(
            configuration: configuration,
            delegate: HTTPSOnlyURLSessionDelegate(),
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        var samples: [Double] = []
        samples.reserveCapacity(targetCount)
        var lastError: Error?
        var attempts = 0

        while samples.count < targetCount, attempts < maximumAttempts {
            try Task.checkCancellation()
            do {
                samples.append(
                    try await measuredServerLatencySample(
                        session: session,
                        acceptsZstandard: true,
                        transientRetriesRemaining: 1
                    )
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
            attempts += 1
            if samples.count < targetCount, attempts < maximumAttempts {
                try await Task.sleep(for: .milliseconds(80))
            }
        }

        guard samples.count >= minimumSuccessfulSamples else {
            throw lastError ?? URLError(.cannotConnectToHost)
        }

        // Median suppresses one-off DNS/radio scheduling spikes and also lets a
        // single transient request failure avoid turning the Settings badge red.
        let ordered = samples.sorted()
        return ordered[ordered.count / 2]
    }

    private func measuredServerLatencySample(
        session: URLSession,
        acceptsZstandard: Bool,
        transientRetriesRemaining: Int
    ) async throws -> Double {
        do {
            try Task.checkCancellation()
            // Generate fresh OpenSubsonic authentication material for every
            // attempt, matching normal API request behavior rather than reusing
            // the same salt/token across diagnostics or a compatibility retry.
            let url = try endpointURL("ping")
            var request = URLRequest(url: url)
            ModernNetworkPolicy.prepareHealthCheckRequest(
                &request,
                acceptsZstandard: acceptsZstandard
            )

            let startedAt = ContinuousClock.now
            let (encodedData, response) = try await session.data(for: request)
            let elapsed = startedAt.duration(to: .now)
            try Task.checkCancellation()

            guard encodedData.count <= 2 * 1_024 * 1_024 else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            guard let http = response as? HTTPURLResponse else {
                throw OpenSubsonicError.invalidResponse
            }
            guard http.url?.scheme?.lowercased() == "https" else {
                throw OpenSubsonicError.insecureServerURL
            }
            guard (200..<300).contains(http.statusCode) else {
                if transientRetriesRemaining > 0,
                   NetworkResiliencePolicy.shouldRetryHTTPStatus(http.statusCode) {
                    try await Task.sleep(
                        for: NetworkResiliencePolicy.retryDelay(
                            afterAttempt: 1 - transientRetriesRemaining
                        )
                    )
                    return try await measuredServerLatencySample(
                        session: session,
                        acceptsZstandard: acceptsZstandard,
                        transientRetriesRemaining: transientRetriesRemaining - 1
                    )
                }
                throw OpenSubsonicError.http(http.statusCode)
            }

            do {
                let data = try HTTPContentDecoder.decode(
                    encodedData,
                    contentEncoding: http.value(forHTTPHeaderField: "Content-Encoding")
                )
                guard data.count <= 2 * 1_024 * 1_024 else {
                    throw URLError(.dataLengthExceedsMaximum)
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
                return elapsed.timeInterval * 1_000
            } catch let error as URLError
                where acceptsZstandard && error.code == .cannotDecodeContentData {
                try Task.checkCancellation()
                return try await measuredServerLatencySample(
                    session: session,
                    acceptsZstandard: false,
                    transientRetriesRemaining: transientRetriesRemaining
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard transientRetriesRemaining > 0,
                  NetworkResiliencePolicy.shouldRetry(error) else {
                throw error
            }
            try await Task.sleep(
                for: NetworkResiliencePolicy.retryDelay(
                    afterAttempt: 1 - transientRetriesRemaining
                )
            )
            return try await measuredServerLatencySample(
                session: session,
                acceptsZstandard: acceptsZstandard,
                transientRetriesRemaining: transientRetriesRemaining - 1
            )
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
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
