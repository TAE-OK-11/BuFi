import Foundation

/// Secret material delivered only with `startVPNTunnel(options:)` when a
/// re-signed build cannot share a Keychain access group. Nothing in this type
/// is written to providerConfiguration, UserDefaults, a database, or a file.
struct TunnelLaunchMaterial: Sendable {
    let profile: TunnelProfile
    let privateKey: Data
    let presharedKeys: [UUID: Data]
}

enum TunnelLaunchOptionsError: LocalizedError, Equatable, Sendable {
    case invalidProfile
    case profileTooLarge
    case invalidPrivateKey
    case invalidPresharedKey(peer: Int)

    var errorDescription: String? {
        switch self {
        case .invalidProfile:
            String(localized: "The in-memory Tunnel profile is invalid.")
        case .profileTooLarge:
            String(localized: "The Tunnel profile is too large for secure in-memory delivery.")
        case .invalidPrivateKey:
            String(localized: "The in-memory WireGuard private key is invalid.")
        case .invalidPresharedKey(let peer):
            String(
                format: String(localized: "Peer %d is missing a valid in-memory preshared key."),
                locale: .current,
                peer + 1
            )
        }
    }
}

enum TunnelLaunchOptions {
    private static let deliveryKey = "bufi.tunnel.secret-delivery"
    private static let deliveryValue = "memory-v1"
    private static let profileKey = "bufi.tunnel.profile"
    private static let privateKeyKey = "bufi.tunnel.private-key"
    private static let presharedKeyPrefix = "bufi.tunnel.preshared-key."
    static let maximumProfileBytes = 2 * 1_024 * 1_024

    static func encode(_ material: TunnelLaunchMaterial) throws -> [String: NSObject] {
        try validate(material)
        let profileData = try JSONEncoder().encode(material.profile)
        guard profileData.count <= maximumProfileBytes else {
            throw TunnelLaunchOptionsError.profileTooLarge
        }
        var options: [String: NSObject] = [
            deliveryKey: deliveryValue as NSString,
            profileKey: profileData as NSData,
            privateKeyKey: material.privateKey as NSData
        ]
        for peer in material.profile.peers where peer.presharedKeyReference != nil {
            if let secret = material.presharedKeys[peer.id] {
                options[presharedKey(for: peer.id)] = secret as NSData
            }
        }
        return options
    }

    /// Returns nil for a normal shared-Keychain launch. If the memory-delivery
    /// marker is present, malformed or partial options fail closed.
    static func decode(_ options: [String: NSObject]?) throws -> TunnelLaunchMaterial? {
        guard let options,
              let delivery = options[deliveryKey] as? NSString else { return nil }
        guard delivery as String == deliveryValue,
              let profileData = options[profileKey] as? NSData,
              profileData.length <= maximumProfileBytes,
              let profile = try? JSONDecoder().decode(TunnelProfile.self, from: profileData as Data),
              let privateKey = options[privateKeyKey] as? NSData else {
            throw TunnelLaunchOptionsError.invalidProfile
        }
        var presharedKeys: [UUID: Data] = [:]
        for peer in profile.peers where peer.presharedKeyReference != nil {
            if let secret = options[presharedKey(for: peer.id)] as? NSData {
                presharedKeys[peer.id] = secret as Data
            }
        }
        let material = TunnelLaunchMaterial(
            profile: profile,
            privateKey: privateKey as Data,
            presharedKeys: presharedKeys
        )
        try validate(material)
        return material
    }

    private static func validate(_ material: TunnelLaunchMaterial) throws {
        guard material.privateKey.count == 32,
              (try? TunnelKeyPair.publicKey(for: material.privateKey)) == material.profile.publicKey else {
            throw TunnelLaunchOptionsError.invalidPrivateKey
        }
        for (index, peer) in material.profile.peers.enumerated()
            where peer.presharedKeyReference != nil {
            guard material.presharedKeys[peer.id]?.count == 32 else {
                throw TunnelLaunchOptionsError.invalidPresharedKey(peer: index)
            }
        }
    }

    private static func presharedKey(for peerID: UUID) -> String {
        presharedKeyPrefix + peerID.uuidString.lowercased()
    }
}
