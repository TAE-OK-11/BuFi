import Foundation

enum EngineConfigurationBuilder {
    struct Result: Sendable {
        let engine: RustEngineConfiguration
        let firstEndpointIP: String
    }

    struct EndpointRefresh: Sendable {
        let endpoints: RustEndpointConfiguration
        let firstEndpointIP: String?
        let unresolvedHosts: [String]
    }

    static func make(
        profile: TunnelProfile,
        strategy: EndpointResolver.Strategy = .initial
    ) throws -> Result {
        guard profile.effectiveSecretScope == .sharedAccessGroup else {
            throw TunnelKeychainError.sharedAccessGroupUnavailable
        }
        let keychain = TunnelKeychain()
        let privateKey = try keychain.load(
            reference: profile.privateKeyReference,
            scope: .sharedAccessGroup
        )
        var presharedKeys: [UUID: Data] = [:]
        presharedKeys.reserveCapacity(profile.peers.count)
        for peer in profile.peers {
            if let reference = peer.presharedKeyReference {
                presharedKeys[peer.id] = try keychain.load(
                    reference: reference,
                    scope: .sharedAccessGroup
                )
            }
        }
        return try make(
            profile: profile,
            privateKey: privateKey,
            presharedKeys: presharedKeys,
            strategy: strategy
        )
    }

    /// Used by the manual-connect fallback when only the main app's normal
    /// Keychain is available. Secret bytes arrive in the launch IPC and remain
    /// in memory; this builder never persists or logs them.
    static func make(
        profile: TunnelProfile,
        privateKey: Data,
        presharedKeys: [UUID: Data],
        strategy: EndpointResolver.Strategy = .initial
    ) throws -> Result {
        try TunnelProfileValidator.validate(profile, privateKey: privateKey)
        guard try TunnelKeyPair.publicKey(for: privateKey) == profile.publicKey else {
            throw TunnelLaunchOptionsError.invalidPrivateKey
        }
        var firstEndpointIP: String?
        let peers = try profile.peers.enumerated().map { index, peer in
            let endpointIP = try EndpointResolver.resolve(
                host: peer.endpointHost,
                port: peer.endpointPort,
                strategy: strategy
            )
            if firstEndpointIP == nil { firstEndpointIP = endpointIP }
            let presharedKey: String?
            if peer.presharedKeyReference != nil {
                guard let secret = presharedKeys[peer.id], secret.count == 32 else {
                    throw TunnelLaunchOptionsError.invalidPresharedKey(peer: index)
                }
                presharedKey = secret.base64EncodedString()
            } else {
                presharedKey = nil
            }
            return RustPeerConfiguration(
                publicKey: peer.publicKey,
                presharedKey: presharedKey,
                endpointIP: endpointIP,
                endpointPort: peer.endpointPort,
                allowedIPs: peer.allowedIPs,
                persistentKeepalive: peer.persistentKeepalive
            )
        }
        guard let firstEndpointIP else { throw TunnelValidationError.missingPeer }
        return Result(
            engine: RustEngineConfiguration(
                privateKey: privateKey.base64EncodedString(),
                mtu: profile.mtu ?? 1280,
                peers: peers
            ),
            firstEndpointIP: firstEndpointIP
        )
    }

    /// Refreshes endpoints independently so one temporarily broken DNS record
    /// cannot prevent every other peer from recovering. No Keychain access is
    /// performed and no secret is included in the FFI payload.
    static func makeEndpointRefresh(profile: TunnelProfile) -> EndpointRefresh {
        var firstEndpointIP: String?
        var endpoints: [RustPeerEndpointConfiguration] = []
        var unresolvedHosts: [String] = []
        endpoints.reserveCapacity(profile.peers.count)
        unresolvedHosts.reserveCapacity(profile.peers.count)

        for peer in profile.peers {
            do {
                let endpointIP = try EndpointResolver.resolve(
                    host: peer.endpointHost,
                    port: peer.endpointPort,
                    strategy: .networkChange
                )
                if firstEndpointIP == nil { firstEndpointIP = endpointIP }
                endpoints.append(RustPeerEndpointConfiguration(
                    publicKey: peer.publicKey,
                    endpointIP: endpointIP,
                    endpointPort: peer.endpointPort
                ))
            } catch {
                unresolvedHosts.append(peer.endpointHost)
            }
        }
        return EndpointRefresh(
            endpoints: RustEndpointConfiguration(peers: endpoints),
            firstEndpointIP: firstEndpointIP,
            unresolvedHosts: unresolvedHosts
        )
    }
}
