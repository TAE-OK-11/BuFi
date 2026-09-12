import Foundation

struct ImportedTunnelConfiguration: Sendable {
    var name: String
    var privateKey: Data
    var addresses: [String]
    var mtu: UInt16?
    var dnsServers: [String]
    var peers: [ImportedPeer]

    struct ImportedPeer: Sendable {
        var publicKey: String
        var presharedKey: Data?
        var endpointHost: String
        var endpointPort: UInt16
        var allowedIPs: [String]
        var persistentKeepalive: UInt16?
    }
}

enum WireGuardConfigParserError: LocalizedError, Sendable {
    case invalidLine(Int)
    case missingInterface
    case missingPrivateKey
    case invalidPrivateKey
    case invalidPeer(Int)

    var errorDescription: String? {
        switch self {
        case .invalidLine(let line): "Invalid WireGuard configuration at line \(line)."
        case .missingInterface: "The configuration has no [Interface] section."
        case .missingPrivateKey: "The configuration has no interface PrivateKey."
        case .invalidPrivateKey: "The imported interface PrivateKey is invalid."
        case .invalidPeer(let index): "Peer \(index + 1) is incomplete or invalid."
        }
    }
}

enum WireGuardConfigParser {
    static func parse(_ text: String, suggestedName: String = "Imported Tunnel") throws
        -> ImportedTunnelConfiguration {
        enum Section { case none, interface, peer(Int) }
        var section = Section.none
        var interface: [String: String] = [:]
        var peers: [[String: String]] = []

        for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.split(separator: "#", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !line.isEmpty else { continue }
            if line.caseInsensitiveCompare("[Interface]") == .orderedSame {
                section = .interface
                continue
            }
            if line.caseInsensitiveCompare("[Peer]") == .orderedSame {
                peers.append([:])
                section = .peer(peers.count - 1)
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { throw WireGuardConfigParserError.invalidLine(offset + 1) }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            switch section {
            case .none:
                throw WireGuardConfigParserError.missingInterface
            case .interface:
                interface[key] = merge(interface[key], value)
            case .peer(let index):
                peers[index][key] = merge(peers[index][key], value)
            }
        }
        guard !interface.isEmpty else { throw WireGuardConfigParserError.missingInterface }
        guard let privateKeyString = interface["privatekey"] else {
            throw WireGuardConfigParserError.missingPrivateKey
        }
        guard let privateKey = Data(base64Encoded: privateKeyString), privateKey.count == 32 else {
            throw WireGuardConfigParserError.invalidPrivateKey
        }
        let importedPeers = try peers.enumerated().map { index, values in
            guard let publicKey = values["publickey"],
                  Data(base64Encoded: publicKey)?.count == 32,
                  let endpoint = values["endpoint"].flatMap(parseEndpoint),
                  let allowed = values["allowedips"].map(csv), !allowed.isEmpty else {
                throw WireGuardConfigParserError.invalidPeer(index)
            }
            let psk = values["presharedkey"].flatMap(Data.init(base64Encoded:))
            guard psk == nil || psk?.count == 32 else {
                throw WireGuardConfigParserError.invalidPeer(index)
            }
            return ImportedTunnelConfiguration.ImportedPeer(
                publicKey: publicKey,
                presharedKey: psk,
                endpointHost: endpoint.host,
                endpointPort: endpoint.port,
                allowedIPs: allowed,
                persistentKeepalive: values["persistentkeepalive"].flatMap(UInt16.init)
            )
        }
        guard !importedPeers.isEmpty else { throw WireGuardConfigParserError.invalidPeer(0) }
        let addresses = interface["address"].map(csv) ?? []
        let dns = interface["dns"].map(csv) ?? []
        return ImportedTunnelConfiguration(
            name: suggestedName,
            privateKey: privateKey,
            addresses: addresses,
            mtu: interface["mtu"].flatMap(UInt16.init),
            dnsServers: dns,
            peers: importedPeers
        )
    }

    private static func merge(_ existing: String?, _ value: String) -> String {
        existing.map { "\($0),\(value)" } ?? value
    }

    private static func csv(_ value: String) -> [String] {
        value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func parseEndpoint(_ value: String) -> (host: String, port: UInt16)? {
        if value.hasPrefix("[") {
            guard let closing = value.firstIndex(of: "]"),
                  value.index(after: closing) < value.endIndex,
                  value[value.index(after: closing)] == ":",
                  let port = UInt16(value[value.index(closing, offsetBy: 2)...]) else { return nil }
            return (String(value[value.index(after: value.startIndex)..<closing]), port)
        }
        guard let colon = value.lastIndex(of: ":"),
              let port = UInt16(value[value.index(after: colon)...]) else { return nil }
        return (String(value[..<colon]), port)
    }
}

