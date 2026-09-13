import Foundation

enum TunnelConstants {
    static let configuredAppGroup = "group.cloud.tae00217.BuFi"
    static let configuredProviderBundleIdentifier = "cloud.tae00217.BuFi.TunnelExtension"
    private static let altAppGroupsInfoKey = "ALTAppGroups"
    // This is the exact key used by AltStore/SideStore's Bundle.Info.altBundleID.
    private static let altBundleIdentifierInfoKey = "ALTBundleIdentifier"

    /// AltStore/SideStore append the signing team to App Group identifiers and
    /// place the actually provisioned values in ALTAppGroups. Normal App Store
    /// and Xcode builds do not contain that key and use the configured group.
    static let appGroup: String = resolvedAppGroup(
        configured: configuredAppGroup,
        signedGroups: Bundle.main.object(forInfoDictionaryKey: altAppGroupsInfoKey) as? [String]
            ?? []
    )

    /// Re-signers can also rewrite embedded extension bundle identifiers. Read
    /// the signed appex Info.plist instead of guessing a team-specific suffix.
    static let providerBundleIdentifier: String = {
        guard let plugInsURL = Bundle.main.builtInPlugInsURL,
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: plugInsURL,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              ) else {
            return configuredProviderBundleIdentifier
        }
        for url in urls where url.pathExtension == "appex" {
            guard let bundle = Bundle(url: url),
                  let identifier = bundle.bundleIdentifier else { continue }
            let original = bundle.object(
                forInfoDictionaryKey: altBundleIdentifierInfoKey
            ) as? String
            if original == configuredProviderBundleIdentifier
                || identifier == configuredProviderBundleIdentifier
                || url.lastPathComponent == "BuFiTunnelExtension.appex" {
                return identifier
            }
        }
        return configuredProviderBundleIdentifier
    }()
    static let keychainGroupSuffix = "cloud.tae00217.BuFi.tunnel"
    static let profileStoreKey = "bufi-tunnel-profiles-v1"
    static let diagnosticsKey = "bufi-tunnel-diagnostics-v1"

    static func resolvedAppGroup(
        configured: String,
        signedGroups: [String]
    ) -> String {
        if signedGroups.contains(configured) { return configured }
        let remapped = signedGroups.filter { $0.hasPrefix(configured + ".") }
        return remapped.count == 1 ? remapped[0] : configured
    }

    static func keychainAccessGroupCandidates(
        defaultAccessGroup: String?,
        bundleIdentifier: String
    ) -> [String] {
        var groups = [appGroup]
        if let defaultAccessGroup,
           let legacy = sharedKeychainAccessGroup(
               defaultAccessGroup: defaultAccessGroup,
               bundleIdentifier: bundleIdentifier
           ),
           !groups.contains(legacy) {
            groups.append(legacy)
        }
        return groups
    }

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
