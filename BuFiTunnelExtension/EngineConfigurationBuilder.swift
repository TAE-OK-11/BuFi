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
        var firstEndpointIP: String?
        let peers = try profile.peers.map { peer in
            let endpointIP = try EndpointResolver.resolve(
                host: peer.endpointHost,
                port: peer.endpointPort,
                strategy: strategy
            )
            if firstEndpointIP == nil { firstEndpointIP = endpointIP }
            let presharedKey = try peer.presharedKeyReference.map {
                try keychain.load(reference: $0, scope: .sharedAccessGroup).base64EncodedString()
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
