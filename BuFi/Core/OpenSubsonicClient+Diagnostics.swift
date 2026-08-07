import Foundation

extension OpenSubsonicClient {
    /// Measures the real authenticated OpenSubsonic request path instead of an
    /// ICMP echo. The result therefore includes DNS/connection reuse, TLS,
    /// HTTP/3 or fallback transport, and the server's `ping.view` handling.
    func measuredServerLatency(sampleCount: Int = 3) async throws -> Double {
        let count = min(max(sampleCount, 1), 5)
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
        samples.reserveCapacity(count)

        for index in 0..<count {
            samples.append(
                try await measuredServerLatencySample(
                    session: session,
                    acceptsZstandard: true
                )
            )
            if index + 1 < count {
                try await Task.sleep(for: .milliseconds(80))
            }
        }

        // Median suppresses a one-off DNS/radio scheduling spike while still
        // reflecting the path the app actually uses.
        let ordered = samples.sorted()
        return ordered[ordered.count / 2]
    }

    private func measuredServerLatencySample(
        session: URLSession,
        acceptsZstandard: Bool
    ) async throws -> Double {
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

        let startedAt = Date()
        let (encodedData, response) = try await session.data(for: request)
        let elapsed = Date().timeIntervalSince(startedAt) * 1_000
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
            return elapsed
        } catch let error as URLError
            where acceptsZstandard && error.code == .cannotDecodeContentData {
            try Task.checkCancellation()
            return try await measuredServerLatencySample(
                session: session,
                acceptsZstandard: false
            )
        }
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
