import CryptoKit
import Foundation
import Network

enum TunnelDNSMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case system
    case plain
    case https
    case tls
    case quic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: String(localized: "System / Default")
        case .plain: String(localized: "Plain DNS")
        case .https: String(localized: "DNS-over-HTTPS")
        case .tls: String(localized: "DNS-over-TLS")
        case .quic: String(localized: "DNS-over-QUIC")
        }
    }
}

enum TunnelDNSProtectionPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case balanced
    case family

    var id: String { rawValue }

    var title: String {
        switch self {
        case .balanced: String(localized: "Balanced")
        case .family: String(localized: "Family protection")
        }
    }

    var detail: String {
        switch self {
        case .balanced: String(localized: "Blocks ads, trackers, phishing, and malicious domains with low breakage risk.")
        case .family: String(localized: "Also blocks adult content and enables Safe Search where supported.")
        }
    }

    var resolver: TunnelDNSConfiguration {
        switch self {
        case .balanced:
            TunnelDNSConfiguration(
                mode: .https,
                servers: [
                    "94.140.14.14", "94.140.15.15",
                    "2a10:50c0::ad1:ff", "2a10:50c0::ad2:ff"
                ],
                resolverEndpoint: "https://dns.adguard-dns.com/dns-query",
                serverName: "dns.adguard-dns.com",
                port: 443
            )
        case .family:
            TunnelDNSConfiguration(
                mode: .https,
                servers: [
                    "94.140.14.15", "94.140.15.16",
                    "2a10:50c0::bad1:ff", "2a10:50c0::bad2:ff"
                ],
                resolverEndpoint: "https://family.adguard-dns.com/dns-query",
                serverName: "family.adguard-dns.com",
                port: 443
            )
        }
    }

    /// Local custom rules need plaintext DNS at the resolver boundary. DoQ
    /// keeps that boundary inside the Packet Tunnel while the upstream remains encrypted.
    var locallyFilteredResolver: TunnelDNSConfiguration {
        let secure = resolver
        return TunnelDNSConfiguration(
            mode: .quic,
            servers: secure.servers,
            resolverEndpoint: secure.servers.first ?? "",
            serverName: secure.serverName,
            port: 853
        )
    }
}

struct TunnelDNSProtectionConfiguration: Codable, Equatable, Sendable {
    static let maximumCustomRules = 4_096
    var isEnabled = false
    var preset: TunnelDNSProtectionPreset = .balanced
    var blockedDomains: [String] = []
    var allowedDomains: [String] = []

    init(
        isEnabled: Bool = false,
        preset: TunnelDNSProtectionPreset = .balanced,
        blockedDomains: [String] = [],
        allowedDomains: [String] = []
    ) {
        self.isEnabled = isEnabled
        self.preset = preset
        self.blockedDomains = blockedDomains
        self.allowedDomains = allowedDomains
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, preset, blockedDomains, allowedDomains
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        preset = try container.decodeIfPresent(TunnelDNSProtectionPreset.self, forKey: .preset) ?? .balanced
        blockedDomains = try container.decodeIfPresent([String].self, forKey: .blockedDomains) ?? []
        allowedDomains = try container.decodeIfPresent([String].self, forKey: .allowedDomains) ?? []
    }

    static let disabled = TunnelDNSProtectionConfiguration()

    var hasCustomRules: Bool {
        !blockedDomains.isEmpty
    }
}

enum TunnelSecretScope: String, Codable, Equatable, Sendable {
    /// Available only when both signed targets possess the same explicit
    /// Keychain access-group entitlement.
    case sharedAccessGroup
    /// Safe profile creation fallback for re-signed/free-provisioned builds.
    /// The Packet Tunnel must never attempt to read this app-local secret.
    case mainAppOnly
}

struct TunnelDNSConfiguration: Codable, Equatable, Sendable {
    var mode: TunnelDNSMode = .system
    /// Bootstrap or plain resolver IP addresses. Names are intentionally not
    /// accepted here to avoid recursive resolution while the tunnel starts.
    var servers: [String] = []
    /// HTTPS URL for DoH, or upstream hostname/IP for DoT and DoQ.
    var resolverEndpoint: String = ""
    var serverName: String = ""
    var port: UInt16 = 53
    /// Optional keeps profiles created before DNS protection source-compatible.
    /// The user's resolver remains untouched and is restored when protection is disabled.
    var protection: TunnelDNSProtectionConfiguration?

    static let system = TunnelDNSConfiguration()

    var effectiveProtection: TunnelDNSProtectionConfiguration {
        protection ?? .disabled
    }

    var effectiveResolver: TunnelDNSConfiguration {
        guard effectiveProtection.isEnabled else { return self }
        return effectiveProtection.hasCustomRules
            ? effectiveProtection.preset.locallyFilteredResolver
            : effectiveProtection.preset.resolver
    }
}

enum TunnelDNSRuleParser {
    static func parse(_ text: String) -> [String] {
        var domains = Set<String>()
        let limit = TunnelDNSProtectionConfiguration.maximumCustomRules + 1
        domains.reserveCapacity(min(
            limit,
            text.count / 16
        ))
        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            for rawValue in rawLine.split(separator: ",") {
                if let domain = normalize(String(rawValue)) { domains.insert(domain) }
                // Keep pasted filter text from allocating without bound. One
                // item beyond the limit is retained so validation can still
                // report the correct error instead of silently truncating.
                if domains.count >= limit { return domains.sorted() }
            }
        }
        return domains.sorted()
    }

    static func normalize(_ rawValue: String) -> String? {
        var value = rawValue
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard !value.isEmpty else { return nil }

        if value.hasPrefix("@@") { value.removeFirst(2) }
        if value.hasPrefix("||") { value.removeFirst(2) }
        if let option = value.firstIndex(of: "^") { value = String(value[..<option]) }
        if let slash = value.firstIndex(of: "/") { value = String(value[..<slash]) }
        let hostsParts = value.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if hostsParts.count >= 2,
           (IPv4Address(String(hostsParts[0])) != nil
               || IPv6Address(String(hostsParts[0])) != nil) {
            value = String(hostsParts[1])
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: ".|"))
        guard value.count <= 253,
              !value.isEmpty,
              value.split(separator: ".").allSatisfy({ label in
                  !label.isEmpty && label.count <= 63
                      && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
                      && label.first != "-" && label.last != "-"
              }) else { return nil }
        return value
    }
}

struct TunnelPeer: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var publicKey: String = ""
    var presharedKeyReference: String?
    var endpointHost: String = ""
    var endpointPort: UInt16 = 51820
    var allowedIPs: [String] = []
    var persistentKeepalive: UInt16?
}

struct TunnelProfile: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var privateKeyReference: String
    var publicKey: String
    var addresses: [String]
    var peers: [TunnelPeer]
    var mtu: UInt16?
    var dns: TunnelDNSConfiguration
    /// `nil` preserves compatibility with v1 profiles, which were written to
    /// the explicitly shared group before scope metadata was introduced.
    var secretScope: TunnelSecretScope?
    var createdAt = Date()
    var updatedAt = Date()

    var effectiveSecretScope: TunnelSecretScope {
        secretScope ?? .sharedAccessGroup
    }

    var isFullTunnel: Bool {
        peers.flatMap(\.allowedIPs).contains { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized == "0.0.0.0/0" || normalized == "::/0"
        }
    }
}

struct TunnelKeyPair: Sendable {
    let privateKey: Data
    let publicKey: String

    static func generate() -> TunnelKeyPair {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return TunnelKeyPair(
            privateKey: key.rawRepresentation,
            publicKey: key.publicKey.rawRepresentation.base64EncodedString()
        )
    }

    static func publicKey(for privateKey: Data) throws -> String {
        guard privateKey.count == 32 else { throw TunnelValidationError.invalidPrivateKey }
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        return key.publicKey.rawRepresentation.base64EncodedString()
    }
}

enum TunnelValidationError: LocalizedError, Equatable, Sendable {
    case emptyName
    case invalidPrivateKey
    case invalidPublicKey(peer: Int)
    case duplicatePublicKey(peer: Int)
    case missingAddress
    case invalidAddress(String)
    case missingPeer
    case missingEndpoint(peer: Int)
    case missingAllowedIPs(peer: Int)
    case invalidAllowedIP(String)
    case invalidMTU
    case invalidDNSServer(String)
    case invalidDNSConfiguration
    case tooManyCustomDNSRules

    var errorDescription: String? {
        switch self {
        case .emptyName: String(localized: "Profile name is required.")
        case .invalidPrivateKey: String(localized: "The interface private key must be a 32-byte WireGuard key.")
        case .invalidPublicKey(let peer): String(
            format: String(localized: "Peer %d has an invalid public key."),
            locale: .current,
            peer + 1
        )
        case .duplicatePublicKey(let peer): String(
            format: String(localized: "Peer %d duplicates another WireGuard public key."),
            locale: .current,
            peer + 1
        )
        case .missingAddress: String(localized: "At least one client IP address is required.")
        case .invalidAddress(let value): String(
            format: String(localized: "Invalid client address: %@"),
            locale: .current,
            value
        )
        case .missingPeer: String(localized: "At least one WireGuard peer is required.")
        case .missingEndpoint(let peer): String(
            format: String(localized: "Peer %d needs an endpoint and port."),
            locale: .current,
            peer + 1
        )
        case .missingAllowedIPs(let peer): String(
            format: String(localized: "Peer %d needs at least one AllowedIP."),
            locale: .current,
            peer + 1
        )
        case .invalidAllowedIP(let value): String(
            format: String(localized: "Invalid AllowedIP: %@"),
            locale: .current,
            value
        )
        case .invalidMTU: String(localized: "MTU must be between 576 and 9,000 (and at least 1,280 for IPv6).")
        case .invalidDNSServer(let value): String(
            format: String(localized: "DNS server must be an IPv4 or IPv6 address: %@"),
            locale: .current,
            value
        )
        case .invalidDNSConfiguration: String(localized: "The encrypted DNS resolver endpoint is incomplete or invalid.")
        case .tooManyCustomDNSRules: String(
            format: String(localized: "Custom DNS protection supports up to %d block and allow rules."),
            locale: .current,
            TunnelDNSProtectionConfiguration.maximumCustomRules
        )
        }
    }
}

enum TunnelProfileValidator {
    static func validate(_ profile: TunnelProfile, privateKey: Data?) throws {
        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TunnelValidationError.emptyName
        }
        if let privateKey, privateKey.count != 32 {
            throw TunnelValidationError.invalidPrivateKey
        }
        guard !profile.addresses.isEmpty else { throw TunnelValidationError.missingAddress }
        for value in profile.addresses where parseCIDR(value) == nil {
            throw TunnelValidationError.invalidAddress(value)
        }
        guard !profile.peers.isEmpty else { throw TunnelValidationError.missingPeer }
        var peerPublicKeys = Set<Data>()
        for (index, peer) in profile.peers.enumerated() {
            guard let publicKey = Data(base64Encoded: peer.publicKey), publicKey.count == 32 else {
                throw TunnelValidationError.invalidPublicKey(peer: index)
            }
            guard peerPublicKeys.insert(publicKey).inserted else {
                throw TunnelValidationError.duplicatePublicKey(peer: index)
            }
            guard !peer.endpointHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  peer.endpointPort > 0 else {
                throw TunnelValidationError.missingEndpoint(peer: index)
            }
            guard !peer.allowedIPs.isEmpty else {
                throw TunnelValidationError.missingAllowedIPs(peer: index)
            }
            for value in peer.allowedIPs where parseCIDR(value) == nil {
                throw TunnelValidationError.invalidAllowedIP(value)
            }
        }
        if let mtu = profile.mtu {
            let hasIPv6 = profile.addresses.contains { parseCIDR($0)?.isIPv6 == true }
            guard mtu >= (hasIPv6 ? 1280 : 576), mtu <= 9000 else {
                throw TunnelValidationError.invalidMTU
            }
        }
        try validateDNS(profile.dns)
    }

    static func validateDNS(_ dns: TunnelDNSConfiguration) throws {
        let customRuleCount = dns.effectiveProtection.blockedDomains.count
            + dns.effectiveProtection.allowedDomains.count
        guard customRuleCount <= TunnelDNSProtectionConfiguration.maximumCustomRules else {
            throw TunnelValidationError.tooManyCustomDNSRules
        }
        try validateResolver(dns)
        if dns.effectiveProtection.isEnabled {
            try validateResolver(dns.effectiveResolver)
        }
    }

    private static func validateResolver(_ dns: TunnelDNSConfiguration) throws {
        for server in dns.servers where IPv4Address(server) == nil && IPv6Address(server) == nil {
            throw TunnelValidationError.invalidDNSServer(server)
        }
        switch dns.mode {
        case .system:
            return
        case .plain:
            guard !dns.servers.isEmpty, dns.port == 53 else {
                throw TunnelValidationError.invalidDNSConfiguration
            }
        case .https:
            guard let url = URL(string: dns.resolverEndpoint),
                  url.scheme?.lowercased() == "https", url.host != nil else {
                throw TunnelValidationError.invalidDNSConfiguration
            }
        case .tls, .quic:
            guard !dns.resolverEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  dns.port > 0 else {
                throw TunnelValidationError.invalidDNSConfiguration
            }
        }
    }

    struct ParsedCIDR: Sendable {
        let address: String
        let prefix: Int
        let isIPv6: Bool
    }

    static func parseCIDR(_ value: String) -> ParsedCIDR? {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]) else { return nil }
        let address = String(parts[0])
        if IPv4Address(address) != nil, (0...32).contains(prefix) {
            return ParsedCIDR(address: address, prefix: prefix, isIPv6: false)
        }
        if IPv6Address(address) != nil, (0...128).contains(prefix) {
            return ParsedCIDR(address: address, prefix: prefix, isIPv6: true)
        }
        return nil
    }
}

struct TunnelDiagnostics: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case disconnected
        case connecting
        case connected
        case reconnecting
        case waitingForNetwork
        case disconnecting
        case error
    }

    var state: State = .disconnected
    var latestHandshake: Date?
    var txBytes: UInt64 = 0
    var rxBytes: UInt64 = 0
    var currentEndpoint: String?
    var reconnectCount: UInt64 = 0
    var currentNetworkPath = "Unknown"
    var dnsMode: TunnelDNSMode = .system
    var dnsResolverEndpoint: String?
    var dnsProtectionEnabled = false
    var dnsProtectionPreset: TunnelDNSProtectionPreset?
    /// Optional preserves decoding of diagnostics written by earlier builds.
    var dnsBlockedQueryCount: UInt64?
    var latestError: String?
    var updatedAt = Date()
}

enum TunnelProviderMessage: String, Codable, Sendable {
    case diagnostics
}
