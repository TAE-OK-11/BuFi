import Foundation

enum TunnelConstants {
    static let appGroup = "group.cloud.tae00217.BuFi"
    static let providerBundleIdentifier = "cloud.tae00217.BuFi.TunnelExtension"
    static let keychainGroupSuffix = "cloud.tae00217.BuFi.tunnel"
    static let profileStoreKey = "bufi-tunnel-profiles-v1"
    static let diagnosticsKey = "bufi-tunnel-diagnostics-v1"

    static var keychainAccessGroup: String? {
        Bundle.main.object(forInfoDictionaryKey: "BuFiSharedKeychainAccessGroup") as? String
    }
}

