import XCTest
@testable import BuFi

final class TunnelConfigurationTests: XCTestCase {
    func testImportsStandardDualStackWireGuardConfiguration() throws {
        let privateKey = Data(repeating: 7, count: 32).base64EncodedString()
        let peerKey = Data(repeating: 8, count: 32).base64EncodedString()
        let psk = Data(repeating: 9, count: 32).base64EncodedString()
        let text = """
        [Interface]
        PrivateKey = \(privateKey)
        Address = 10.7.0.2/32, fd00:7::2/128
        DNS = 1.1.1.1, 2606:4700:4700::1111
        MTU = 1380

        [Peer]
        PublicKey = \(peerKey)
        PresharedKey = \(psk)
        Endpoint = [2001:db8::1]:51820
        AllowedIPs = 0.0.0.0/0, ::/0
        PersistentKeepalive = 25
        """

        let imported = try WireGuardConfigParser.parse(text, suggestedName: "Test")

        XCTAssertEqual(imported.addresses, ["10.7.0.2/32", "fd00:7::2/128"])
        XCTAssertEqual(imported.peers.first?.endpointHost, "2001:db8::1")
        XCTAssertEqual(imported.peers.first?.persistentKeepalive, 25)
        XCTAssertEqual(imported.dnsServers.count, 2)
    }

    func testAllowedIPsDetermineSplitAndFullTunnel() {
        let peerKey = Data(repeating: 3, count: 32).base64EncodedString()
        var profile = TunnelProfile(
            name: "Split",
            privateKeyReference: "private-test",
            publicKey: Data(repeating: 2, count: 32).base64EncodedString(),
            addresses: ["10.0.0.2/32"],
            peers: [TunnelPeer(publicKey: peerKey, endpointHost: "vpn.example", allowedIPs: ["10.0.0.0/8"])],
            mtu: 1280,
            dns: .system
        )
        XCTAssertFalse(profile.isFullTunnel)
        profile.peers[0].allowedIPs = ["0.0.0.0/0", "::/0"]
        XCTAssertTrue(profile.isFullTunnel)
    }

    func testValidatorRejectsHostnameAsPlainDNSBootstrap() {
        XCTAssertThrowsError(
            try TunnelProfileValidator.validateDNS(
                TunnelDNSConfiguration(mode: .plain, servers: ["dns.example"], port: 53)
            )
        )
    }

    func testGeneratedKeyPairHasWireGuardSizedKeys() throws {
        let pair = TunnelKeyPair.generate()
        XCTAssertEqual(pair.privateKey.count, 32)
        XCTAssertEqual(Data(base64Encoded: pair.publicKey)?.count, 32)
        XCTAssertEqual(try TunnelKeyPair.publicKey(for: pair.privateKey), pair.publicKey)
    }
}

