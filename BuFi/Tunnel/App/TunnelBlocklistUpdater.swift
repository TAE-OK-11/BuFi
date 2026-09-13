import Foundation

enum TunnelBlocklistUpdateError: LocalizedError, Sendable {
    case invalidResponse
    case downloadTooLarge
    case invalidText
    case tooManyRules
    case noUsableRules(String)
    case rustEngineUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse: String(localized: "A blocklist server returned an invalid response.")
        case .downloadTooLarge: String(localized: "A blocklist download exceeded the 12 MB safety limit.")
        case .invalidText: String(localized: "A blocklist is not valid UTF-8 text.")
        case .tooManyRules: String(localized: "The combined blocklist exceeded the 250,000-domain safety limit.")
        case .noUsableRules(let name): String(
            format: String(localized: "The blocklist %@ did not contain usable DNS domain rules."),
            locale: .current,
            name
        )
        case .rustEngineUnavailable:
            String(localized: "The Rust DNS filter engine could not compile the blocklist.")
        }
    }
}

actor TunnelBlocklistUpdater {
    static let shared = TunnelBlocklistUpdater()
    static let refreshInterval: TimeInterval = 24 * 60 * 60
    private static let maximumDownloadBytes = 12 * 1_024 * 1_024
    private static let maximumCombinedRules = 250_000

    func update(profile: TunnelProfile, force: Bool) async throws -> TunnelBlocklistUpdateMetadata? {
        let protection = profile.dns.effectiveProtection
        let sources = Self.sources(protection)
        guard protection.isEnabled, !sources.isEmpty else {
            try? TunnelBlocklistCache.remove(profileID: profile.id)
            return nil
        }
        if !force,
           let metadata = try? TunnelBlocklistCache.metadata(profileID: profile.id),
           Date().timeIntervalSince(metadata.updatedAt) < Self.refreshInterval {
            return metadata
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        guard let compiler = RustDNSBlocklistCompiler(
            maximumRules: Self.maximumCombinedRules
        ) else {
            throw TunnelBlocklistUpdateError.rustEngineUnavailable
        }
        for source in sources {
            var request = URLRequest(url: source.url)
            request.setValue("text/plain", forHTTPHeaderField: "Accept")
            request.setValue("BuFi-Tunnel/1", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200...299).contains(response.statusCode) else {
                throw TunnelBlocklistUpdateError.invalidResponse
            }
            guard data.count <= Self.maximumDownloadBytes else {
                throw TunnelBlocklistUpdateError.downloadTooLarge
            }
            let usableRuleCount: Int
            switch compiler.add(data) {
            case .accepted(let count):
                usableRuleCount = count
            case .invalidUTF8:
                throw TunnelBlocklistUpdateError.invalidText
            case .reachedLimit:
                throw TunnelBlocklistUpdateError.tooManyRules
            case .failed:
                throw TunnelBlocklistUpdateError.rustEngineUnavailable
            }
            guard usableRuleCount > 0 else {
                throw TunnelBlocklistUpdateError.noUsableRules(source.name)
            }
        }
        guard let compiled = compiler.finish() else {
            throw TunnelBlocklistUpdateError.rustEngineUnavailable
        }
        return try TunnelBlocklistCache.save(
            snapshot: compiled.snapshot,
            ruleCount: compiled.ruleCount,
            profileID: profile.id,
            sourceCount: sources.count
        )
    }

    private struct Source: Sendable {
        let name: String
        let url: URL
    }

    private static func sources(_ protection: TunnelDNSProtectionConfiguration) -> [Source] {
        let builtIn = protection.enabledBuiltInBlocklists.map {
            Source(name: $0.title, url: $0.sourceURL)
        }
        let custom = protection.customSubscriptions.compactMap { subscription -> Source? in
            guard subscription.isEnabled, let url = URL(string: subscription.url) else { return nil }
            return Source(name: subscription.name, url: url)
        }
        return builtIn + custom
    }
}
