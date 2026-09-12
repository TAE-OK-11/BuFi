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

struct TunnelDNSConfiguration: Codable, Equatable, Sendable {
    var mode: TunnelDNSMode = .system
    /// Bootstrap or plain resolver IP addresses. Names are intentionally not
    /// accepted here to avoid recursive resolution while the tunnel starts.
    var servers: [String] = []
    /// HTTPS URL for DoH, or upstream hostname/IP for DoT and DoQ.
    var resolverEndpoint: String = ""
    var serverName: String = ""
    var port: UInt16 = 53

    static let system = TunnelDNSConfiguration()
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
    var createdAt = Date()
    var updatedAt = Date()

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
    case missingAddress
    case invalidAddress(String)
    case missingPeer
    case missingEndpoint(peer: Int)
    case missingAllowedIPs(peer: Int)
    case invalidAllowedIP(String)
    case invalidMTU
    case invalidDNSServer(String)
    case invalidDNSConfiguration

    var errorDescription: String? {
        switch self {
        case .emptyName: String(localized: "Profile name is required.")
        case .invalidPrivateKey: String(localized: "The interface private key must be a 32-byte WireGuard key.")
        case .invalidPublicKey(let peer): String(
            format: String(localized: "Peer %d has an invalid public key."),
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
        for (index, peer) in profile.peers.enumerated() {
            guard Data(base64Encoded: peer.publicKey)?.count == 32 else {
                throw TunnelValidationError.invalidPublicKey(peer: index)
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
    var latestError: String?
    var updatedAt = Date()
}

enum TunnelProviderMessage: String, Codable, Sendable {
    case diagnostics
}
