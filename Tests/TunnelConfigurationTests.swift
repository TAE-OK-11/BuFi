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

    func testBalancedAdBlockingUsesNativeDoHResolverConfiguration() throws {
        var dns = TunnelDNSConfiguration.system
        dns.protection = TunnelDNSProtectionConfiguration(
            isEnabled: true,
            preset: .balanced
        )

        let effective = dns.effectiveResolver
        XCTAssertEqual(effective.mode, .https)
        XCTAssertEqual(effective.resolverEndpoint, "https://dns.adguard-dns.com/dns-query")
        XCTAssertEqual(effective.serverName, "dns.adguard-dns.com")
        XCTAssertTrue(effective.servers.contains("94.140.14.14"))
        XCTAssertTrue(effective.servers.contains("2a10:50c0::ad1:ff"))
        XCTAssertNoThrow(try TunnelProfileValidator.validateDNS(dns))
    }

    func testDisablingAdBlockingRestoresCustomResolver() {
        var dns = TunnelDNSConfiguration(
            mode: .tls,
            servers: ["1.1.1.1"],
            resolverEndpoint: "one.one.one.one",
            serverName: "one.one.one.one",
            port: 853,
            protection: TunnelDNSProtectionConfiguration(isEnabled: true, preset: .family)
        )
        XCTAssertEqual(dns.effectiveResolver.resolverEndpoint, "https://family.adguard-dns.com/dns-query")

        dns.protection?.isEnabled = false
        XCTAssertEqual(dns.effectiveResolver.mode, .tls)
        XCTAssertEqual(dns.effectiveResolver.resolverEndpoint, "one.one.one.one")
    }

    func testCustomDNSRulesUseEncryptedLocalFilteringBoundary() {
        var dns = TunnelDNSConfiguration.system
        dns.protection = TunnelDNSProtectionConfiguration(
            isEnabled: true,
            preset: .balanced,
            blockedDomains: ["ads.example"],
            allowedDomains: ["music.ads.example"]
        )

        XCTAssertEqual(dns.effectiveResolver.mode, .quic)
        XCTAssertEqual(dns.effectiveResolver.resolverEndpoint, "94.140.14.14")
        XCTAssertEqual(dns.effectiveResolver.serverName, "dns.adguard-dns.com")
        XCTAssertEqual(dns.effectiveResolver.port, 853)
    }

    func testDNSRuleParserAcceptsDomainsHostsAndBasicAdGuardRules() {
        let parsed = TunnelDNSRuleParser.parse(
            """
            ads.example
            0.0.0.0 tracker.example # hosts rule
            ||metrics.example^
            ADS.EXAMPLE
            not a valid domain
            """
        )
        XCTAssertEqual(parsed, ["ads.example", "metrics.example", "tracker.example"])
    }

    func testCustomDNSFilterBlocksSubdomainsAndHonorsAllowRules() {
        let filter = TunnelDNSMessageFilter(
            blockedDomains: ["example.com"],
            allowedDomains: ["music.example.com"]
        )
        let blockedQuery = dnsQuery(domain: "ads.example.com")
        let allowedQuery = dnsQuery(domain: "music.example.com")

        let response = filter.blockedResponse(for: blockedQuery)
        XCTAssertNotNil(response)
        XCTAssertEqual((response?[2] ?? 0) & 0x80, 0x80)
        XCTAssertEqual((response?[3] ?? 0) & 0x0f, 3)
        XCTAssertNil(filter.blockedResponse(for: allowedQuery))
    }

    func testEarlierProtectionConfigurationDecodesWithoutCustomRuleFields() throws {
        let data = try XCTUnwrap(
            """
            {
              "isEnabled": true,
              "preset": "balanced"
            }
            """.data(using: .utf8)
        )
        let protection = try JSONDecoder().decode(TunnelDNSProtectionConfiguration.self, from: data)
        XCTAssertTrue(protection.isEnabled)
        XCTAssertEqual(protection.preset, .balanced)
        XCTAssertTrue(protection.blockedDomains.isEmpty)
        XCTAssertTrue(protection.allowedDomains.isEmpty)
    }

    func testCustomDNSRuleLimitProtectsExtensionMemoryBudget() {
        var dns = TunnelDNSConfiguration.system
        dns.protection = TunnelDNSProtectionConfiguration(
            isEnabled: true,
            blockedDomains: (0...TunnelDNSProtectionConfiguration.maximumCustomRules).map {
                "blocked-\($0).example"
            }
        )
        XCTAssertThrowsError(try TunnelProfileValidator.validateDNS(dns)) { error in
            XCTAssertEqual(error as? TunnelValidationError, .tooManyCustomDNSRules)
        }
    }

    func testLegacyDNSConfigurationDefaultsToProtectionDisabled() throws {
        let data = try XCTUnwrap(
            """
            {
              "mode": "plain",
              "servers": ["1.1.1.1"],
              "resolverEndpoint": "",
              "serverName": "",
              "port": 53
            }
            """.data(using: .utf8)
        )
        let dns = try JSONDecoder().decode(TunnelDNSConfiguration.self, from: data)
        XCTAssertFalse(dns.effectiveProtection.isEnabled)
        XCTAssertEqual(dns.effectiveResolver, dns)
    }

    func testGeneratedKeyPairHasWireGuardSizedKeys() throws {
        let pair = TunnelKeyPair.generate()
        XCTAssertEqual(pair.privateKey.count, 32)
        XCTAssertEqual(Data(base64Encoded: pair.publicKey)?.count, 32)
        XCTAssertEqual(try TunnelKeyPair.publicKey(for: pair.privateKey), pair.publicKey)
    }

    func testSharedKeychainGroupUsesActualSignerPrefix() {
        XCTAssertEqual(
            TunnelConstants.keychainAccessGroupCandidates(
                defaultAccessGroup: "TEAM123.cloud.tae00217.BuFi",
                bundleIdentifier: "cloud.tae00217.BuFi"
            ),
            ["group.cloud.tae00217.BuFi", "TEAM123.cloud.tae00217.BuFi.tunnel"]
        )
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

    func testOpenSubsonicEndpointChoosesTunnelAddressOnlyWhileActive() {
        let configuration = OpenSubsonicEndpointConfiguration(
            primaryURL: "https://music.example.com",
            alternateURLs: ["https://192.0.2.10"],
            tunnelURL: "https://10.10.0.2"
        )
        XCTAssertEqual(
            configuration.serverURL(tunnelActive: false),
            "https://music.example.com"
        )
        XCTAssertEqual(
            configuration.serverURL(tunnelActive: true),
            "https://10.10.0.2"
        )
    }

    func testOpenSubsonicAccountScopeIsStableAcrossServerRoutes() {
        let configuration = OpenSubsonicEndpointConfiguration(
            primaryURL: "https://music.example.com",
            alternateURLs: ["https://192.0.2.10"],
            tunnelURL: "https://10.10.0.2"
        )
        let publicRoute = ServerCredentials(
            serverURL: "https://music.example.com",
            username: "listener",
            password: "secret",
            authMethod: .password,
            accountServerURL: "https://music.example.com",
            endpointConfiguration: configuration
        )
        var tunnelRoute = publicRoute
        tunnelRoute.serverURL = "https://10.10.0.2"
        XCTAssertEqual(
            AccountScope.identifier(for: publicRoute),
            AccountScope.identifier(for: tunnelRoute)
        )
    }

    func testLegacyCredentialsDecodeWithoutEndpointMetadata() throws {
        let data = try XCTUnwrap(
            """
            {
              "serverURL": "https://music.example.com",
              "username": "listener",
              "password": "secret",
              "authMethod": "password"
            }
            """.data(using: .utf8)
        )
        let credentials = try JSONDecoder().decode(ServerCredentials.self, from: data)
        XCTAssertNil(credentials.endpointConfiguration)
        XCTAssertEqual(
            credentials.resolvedEndpointConfiguration.primaryURL,
            "https://music.example.com"
        )
    }


    private func dnsQuery(domain: String) -> Data {
        var data = Data([
            0x12, 0x34, 0x01, 0x00,
            0x00, 0x01, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00
        ])
        for label in domain.split(separator: ".") {
            data.append(UInt8(label.utf8.count))
            data.append(contentsOf: label.utf8)
        }
        data.append(contentsOf: [0x00, 0x00, 0x01, 0x00, 0x01])
        return data
    }
}
