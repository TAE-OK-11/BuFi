@preconcurrency import NetworkExtension
import Foundation
import Network

enum TunnelNetworkSettingsBuilder {
    static func make(profile: TunnelProfile, endpointIP: String) throws -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: endpointIP)
        settings.mtu = NSNumber(value: profile.mtu ?? 1280)

        let addresses = profile.addresses.compactMap(TunnelProfileValidator.parseCIDR)
        let ipv4 = addresses.filter { !$0.isIPv6 }
        if !ipv4.isEmpty {
            let value = NEIPv4Settings(
                addresses: ipv4.map(\.address),
                subnetMasks: ipv4.map { ipv4Mask(prefix: $0.prefix) }
            )
            value.includedRoutes = routes4(profile: profile)
            settings.ipv4Settings = value
        }
        let ipv6 = addresses.filter(\.isIPv6)
        if !ipv6.isEmpty {
            let value = NEIPv6Settings(
                addresses: ipv6.map(\.address),
                networkPrefixLengths: ipv6.map { NSNumber(value: min(120, $0.prefix)) }
            )
            value.includedRoutes = routes6(profile: profile)
            settings.ipv6Settings = value
        }
        return settings
    }

    private static func routes4(profile: TunnelProfile) -> [NEIPv4Route] {
        profile.peers.flatMap(\.allowedIPs)
            .compactMap(TunnelProfileValidator.parseCIDR)
            .filter { !$0.isIPv6 }
            .map { NEIPv4Route(destinationAddress: $0.address, subnetMask: ipv4Mask(prefix: $0.prefix)) }
    }

    private static func routes6(profile: TunnelProfile) -> [NEIPv6Route] {
        profile.peers.flatMap(\.allowedIPs)
            .compactMap(TunnelProfileValidator.parseCIDR)
            .filter(\.isIPv6)
            .map { NEIPv6Route(destinationAddress: $0.address, networkPrefixLength: NSNumber(value: $0.prefix)) }
    }

    private static func ipv4Mask(prefix: Int) -> String {
        let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << (32 - UInt32(prefix))
        return "\((mask >> 24) & 255).\((mask >> 16) & 255).\((mask >> 8) & 255).\(mask & 255)"
    }
}
