import Security
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

    func testSharedKeychainGroupUsesActualSignerPrefix() {
        XCTAssertEqual(
            TunnelConstants.sharedKeychainAccessGroup(
                defaultAccessGroup: "TEAM123.cloud.tae00217.BuFi",
                bundleIdentifier: "cloud.tae00217.BuFi"
            ),
            "TEAM123.cloud.tae00217.BuFi.tunnel"
        )
        XCTAssertEqual(
            TunnelConstants.sharedKeychainAccessGroup(
                defaultAccessGroup: "TEAM123.cloud.tae00217.BuFi.tunnel",
                bundleIdentifier: "cloud.tae00217.BuFi.TunnelExtension"
            ),
            "TEAM123.cloud.tae00217.BuFi.tunnel"
        )
        XCTAssertNil(
            TunnelConstants.sharedKeychainAccessGroup(
                defaultAccessGroup: "TEAM123.unrelated.app",
                bundleIdentifier: "cloud.tae00217.BuFi"
            )
        )
    }

    func testMainAppOnlyQueryDoesNotForceAnAccessGroup() throws {
        let query = try TunnelKeychain().baseQuery(
            reference: "test-reference",
            scope: .mainAppOnly
        )
        XCTAssertNil(query[kSecAttrAccessGroup as String])
    }

    func testMissingEntitlementStatusHasExplicitMapping() {
        XCTAssertEqual(
            TunnelKeychainError.from(status: errSecMissingEntitlement),
            .missingEntitlement
        )
    }

    func testProfileMetadataPreservesSecretOwnershipWithoutSecretBytes() throws {
        let privateKey = Data(repeating: 41, count: 32).base64EncodedString()
        let presharedKey = Data(repeating: 42, count: 32).base64EncodedString()
        let profile = TunnelProfile(
            name: "Local secret",
            privateKeyReference: "private-opaque-reference",
            publicKey: Data(repeating: 43, count: 32).base64EncodedString(),
            addresses: ["10.0.0.2/32"],
            peers: [TunnelPeer(
                publicKey: Data(repeating: 44, count: 32).base64EncodedString(),
                presharedKeyReference: "psk-opaque-reference",
                endpointHost: "vpn.example",
                allowedIPs: ["0.0.0.0/0"]
            )],
            mtu: 1280,
            dns: .system,
            secretScope: .mainAppOnly
        )

        let data = try JSONEncoder().encode(profile)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains(TunnelSecretScope.mainAppOnly.rawValue))
        XCTAssertFalse(json.contains(privateKey))
        XCTAssertFalse(json.contains(presharedKey))
        XCTAssertEqual(try JSONDecoder().decode(TunnelProfile.self, from: data).effectiveSecretScope, .mainAppOnly)
    }

    func testLegacyProfileDefaultsToSharedSecretOwnership() throws {
        let profile = TunnelProfile(
            name: "Legacy",
            privateKeyReference: "private-legacy",
            publicKey: Data(repeating: 45, count: 32).base64EncodedString(),
            addresses: ["10.0.0.2/32"],
            peers: [TunnelPeer(
                publicKey: Data(repeating: 46, count: 32).base64EncodedString(),
                endpointHost: "vpn.example",
                allowedIPs: ["10.0.0.0/8"]
            )],
            mtu: nil,
            dns: .system
        )
        let decoded = try JSONDecoder().decode(
            TunnelProfile.self,
            from: JSONEncoder().encode(profile)
        )
        XCTAssertNil(decoded.secretScope)
        XCTAssertEqual(decoded.effectiveSecretScope, .sharedAccessGroup)
    }
}
