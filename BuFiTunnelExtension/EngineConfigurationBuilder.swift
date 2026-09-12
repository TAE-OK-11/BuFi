import Foundation

enum EngineConfigurationBuilder {
    struct Result: Sendable {
        let engine: RustEngineConfiguration
        let firstEndpointIP: String
    }

    static func make(profile: TunnelProfile) throws -> Result {
        let keychain = TunnelKeychain()
        let privateKey = try keychain.load(reference: profile.privateKeyReference)
        var firstEndpointIP: String?
        let peers = try profile.peers.map { peer in
            let endpointIP = try EndpointResolver.resolve(
                host: peer.endpointHost,
                port: peer.endpointPort
            )
            if firstEndpointIP == nil { firstEndpointIP = endpointIP }
            let presharedKey = try peer.presharedKeyReference.map {
                try keychain.load(reference: $0).base64EncodedString()
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
}

