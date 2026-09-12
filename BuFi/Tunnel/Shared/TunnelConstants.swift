import Foundation

enum TunnelConstants {
    static let appGroup = "group.cloud.tae00217.BuFi"
    static let providerBundleIdentifier = "cloud.tae00217.BuFi.TunnelExtension"
    static let keychainGroupSuffix = "cloud.tae00217.BuFi.tunnel"
    static let profileStoreKey = "bufi-tunnel-profiles-v1"
    static let diagnosticsKey = "bufi-tunnel-diagnostics-v1"

    /// Derives the shared group from the access group attached by the *actual*
    /// signer. This deliberately does not trust an Info.plist build-setting
    /// substitution, which is stale when an unsigned IPA is later re-signed.
    static func sharedKeychainAccessGroup(
        defaultAccessGroup: String,
        bundleIdentifier: String
    ) -> String? {
        // If Keychain Sharing makes the declared shared group the process
        // default, Security has already returned the exact expanded value.
        if defaultAccessGroup.hasSuffix(keychainGroupSuffix) {
            return defaultAccessGroup
        }
        guard defaultAccessGroup.hasSuffix(bundleIdentifier) else { return nil }
        let prefix = defaultAccessGroup.dropLast(bundleIdentifier.count)
        guard !prefix.isEmpty else { return nil }
        return prefix + keychainGroupSuffix
    }
}
