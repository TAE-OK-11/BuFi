@preconcurrency import NetworkExtension
import Foundation
import SwiftUI

@MainActor
final class TunnelManager: ObservableObject {
    static let shared = TunnelManager()

    @Published private(set) var profiles: [TunnelProfile] = []
    @Published var selectedProfileID: UUID?
    @Published private(set) var status: NEVPNStatus = .invalid
    @Published private(set) var diagnostics = TunnelDiagnostics()
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?

    private let repository = TunnelProfileRepository.shared
    private let keychain = TunnelKeychain()
    private var managers: [UUID: NETunnelProviderManager] = [:]
    private var statusObserver: NSObjectProtocol?
    private var metricsTask: Task<Void, Never>?
    private var hasBootstrapped = false

    private init() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshStatus() }
        }
    }

    var selectedProfile: TunnelProfile? {
        profiles.first { $0.id == selectedProfileID }
    }

    var selectedManager: NETunnelProviderManager? {
        selectedProfileID.flatMap { managers[$0] }
    }

    var isEnabled: Bool { selectedManager?.isEnabled == true }
    var selectedProfileRequiresSupportedSigning: Bool {
        selectedProfile?.effectiveSecretScope == .mainAppOnly
    }
    var canConnect: Bool {
        !selectedProfileRequiresSupportedSigning && isEnabled && status == .disconnected
    }

    func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        await perform {
            profiles = try await repository.all()
            if keychain.capability().canUseSharedAccessGroup {
                await migrateAppLocalSecretsIfPossible()
                profiles = try await repository.all()
            }
            guard !profiles.isEmpty else {
                managers = [:]
                selectedProfileID = nil
                diagnostics = TunnelDiagnostics()
                refreshStatus()
                return
            }
            if selectedProfileID == nil || !profiles.contains(where: { $0.id == selectedProfileID }) {
                selectedProfileID = profiles.first?.id
            }
            guard profiles.contains(where: { $0.effectiveSecretScope == .sharedAccessGroup }),
                  keychain.capability().canUseSharedAccessGroup else {
                managers = [:]
                diagnostics = TunnelDiagnostics()
                diagnostics.latestError = String(localized: "This installed build cannot use the Bufi App Group for Tunnel Keychain access. The profile remains secure, but the extension cannot read its key.")
                refreshStatus()
                return
            }
            let loaded = try await NETunnelProviderManager.loadAllFromPreferences()
            managers = Dictionary(uniqueKeysWithValues: loaded.compactMap { manager in
                guard let identifier = Self.profileID(from: manager) else { return nil }
                return (identifier, manager)
            })
            refreshStatus()
            await refreshDiagnostics()
        }
    }

    func save(
        profile: TunnelProfile,
        privateKey: Data?,
        presharedKeys: [UUID: Data]
    ) async -> Bool {
        var profile = profile
        profile.updatedAt = Date()
        do {
            try TunnelProfileValidator.validate(profile, privateKey: privateKey)
            let secretScope = profile.secretScope
                ?? (privateKey == nil ? .sharedAccessGroup : keychain.preferredScope())
            profile.secretScope = secretScope
            if let privateKey {
                let derived = try TunnelKeyPair.publicKey(for: privateKey)
                guard derived == profile.publicKey else { throw TunnelValidationError.invalidPrivateKey }
                try keychain.save(
                    privateKey,
                    reference: profile.privateKeyReference,
                    scope: secretScope
                )
            } else {
                _ = try keychain.load(
                    reference: profile.privateKeyReference,
                    scope: secretScope
                )
            }
            for peer in profile.peers {
                guard let secret = presharedKeys[peer.id] else { continue }
                let reference = peer.presharedKeyReference ?? "psk-\(profile.id.uuidString)-\(peer.id.uuidString)"
                try keychain.save(secret, reference: reference, scope: secretScope)
                if let index = profile.peers.firstIndex(where: { $0.id == peer.id }) {
                    profile.peers[index].presharedKeyReference = reference
                }
            }
            try await repository.save(profile)
            profiles = try await repository.all()
            selectedProfileID = profile.id

            guard secretScope == .sharedAccessGroup else {
                managers[profile.id]?.connection.stopVPNTunnel()
                managers.removeValue(forKey: profile.id)
                diagnostics = TunnelDiagnostics()
                diagnostics.latestError = String(localized: "This profile is saved securely in the app Keychain. Bufi App Group Keychain access is unavailable, so Packet Tunnel was not started.")
                try? await repository.saveDiagnostics(diagnostics)
                refreshStatus()
                return true
            }

            let manager = try await configuredManager(for: profile)
            managers[profile.id] = manager
            refreshStatus()
            return true
        } catch {
            errorMessage = userFacingMessage(for: error)
            return false
        }
    }

    func importConfiguration(text: String, name: String) async -> Bool {
        do {
            let imported = try WireGuardConfigParser.parse(text, suggestedName: name)
            let reference = "private-\(UUID().uuidString)"
            let publicKey = try TunnelKeyPair.publicKey(for: imported.privateKey)
            var secrets: [UUID: Data] = [:]
            let peers = imported.peers.map { importedPeer -> TunnelPeer in
                let id = UUID()
                if let key = importedPeer.presharedKey { secrets[id] = key }
                return TunnelPeer(
                    id: id,
                    publicKey: importedPeer.publicKey,
                    presharedKeyReference: importedPeer.presharedKey == nil ? nil : "psk-\(UUID().uuidString)",
                    endpointHost: importedPeer.endpointHost,
                    endpointPort: importedPeer.endpointPort,
                    allowedIPs: importedPeer.allowedIPs,
                    persistentKeepalive: importedPeer.persistentKeepalive
                )
            }
            let dns = imported.dnsServers.isEmpty
                ? TunnelDNSConfiguration.system
                : TunnelDNSConfiguration(mode: .plain, servers: imported.dnsServers, port: 53)
            let profile = TunnelProfile(
                name: imported.name,
                privateKeyReference: reference,
                publicKey: publicKey,
                addresses: imported.addresses,
                peers: peers,
                mtu: imported.mtu,
                dns: dns
            )
            return await save(profile: profile, privateKey: imported.privateKey, presharedKeys: secrets)
        } catch {
            errorMessage = userFacingMessage(for: error)
            return false
        }
    }

    func delete(_ profile: TunnelProfile) async {
        await perform {
            if let manager = managers[profile.id] {
                manager.connection.stopVPNTunnel()
                try await manager.removeFromPreferences()
            }
            try await repository.delete(id: profile.id)
            try? keychain.delete(
                reference: profile.privateKeyReference,
                scope: profile.effectiveSecretScope
            )
            for peer in profile.peers {
                if let reference = peer.presharedKeyReference {
                    try? keychain.delete(reference: reference, scope: profile.effectiveSecretScope)
                }
            }
            managers.removeValue(forKey: profile.id)
            profiles = try await repository.all()
            selectedProfileID = profiles.first?.id
            refreshStatus()
        }
    }

    func setEnabled(_ enabled: Bool) async {
        guard let profile = selectedProfile else { return }
        await perform {
            let manager = try await configuredManager(for: profile)
            manager.isEnabled = enabled
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
            managers[profile.id] = manager
            refreshStatus()
            objectWillChange.send()
        }
    }

    func connect() async {
        guard let profile = selectedProfile else { return }
        await perform {
            let manager = try await configuredManager(for: profile)
            guard manager.isEnabled else { throw TunnelManagerError.profileDisabled }
            try manager.connection.startVPNTunnel(options: ["profileID": profile.id.uuidString as NSString])
            managers[profile.id] = manager
            refreshStatus()
        }
    }

    func disconnect() {
        selectedManager?.connection.stopVPNTunnel()
        refreshStatus()
    }

    func select(_ profile: TunnelProfile) {
        selectedProfileID = profile.id
        refreshStatus()
        Task { await refreshDiagnostics() }
    }

    func refreshDiagnostics() async {
        guard let session = selectedManager?.connection as? NETunnelProviderSession,
              status == .connected || status == .reasserting || status == .connecting else {
            if let stored = try? await repository.diagnostics() { diagnostics = stored }
            return
        }
        do {
            let request = try JSONEncoder().encode(TunnelProviderMessage.diagnostics)
            guard let response = try await session.sendProviderMessage(request) else { return }
            diagnostics = try JSONDecoder().decode(TunnelDiagnostics.self, from: response)
        } catch {
            diagnostics.latestError = error.localizedDescription
        }
    }

    private func configuredManager(for profile: TunnelProfile) async throws -> NETunnelProviderManager {
        try ensureTunnelCapabilities(for: profile)
        let isNew = managers[profile.id] == nil
        let manager = managers[profile.id] ?? NETunnelProviderManager()
        let tunnelProtocol = (manager.protocolConfiguration as? NETunnelProviderProtocol)
            ?? NETunnelProviderProtocol()
        tunnelProtocol.providerBundleIdentifier = TunnelConstants.providerBundleIdentifier
        tunnelProtocol.serverAddress = profile.peers.first.map {
            "\($0.endpointHost):\($0.endpointPort)"
        } ?? "WireGuard"
        tunnelProtocol.providerConfiguration = ["profileID": profile.id.uuidString]
        tunnelProtocol.disconnectOnSleep = false
        manager.protocolConfiguration = tunnelProtocol
        manager.localizedDescription = "Bufi Tunnel — \(profile.name)"
        if isNew { manager.isEnabled = true }
        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()
        return manager
    }

    private func ensureTunnelCapabilities(for profile: TunnelProfile) throws {
        guard profile.effectiveSecretScope == .sharedAccessGroup,
              keychain.capability().canUseSharedAccessGroup else {
            throw TunnelManagerError.sharedKeychainEntitlementRequired
        }
    }

    private func migrateAppLocalSecretsIfPossible() async {
        for storedProfile in profiles
            where storedProfile.effectiveSecretScope == .mainAppOnly {
            do {
                let privateKey = try keychain.load(
                    reference: storedProfile.privateKeyReference,
                    scope: .mainAppOnly
                )
                var presharedKeys: [(reference: String, secret: Data)] = []
                for peer in storedProfile.peers {
                    guard let reference = peer.presharedKeyReference else { continue }
                    presharedKeys.append((
                        reference,
                        try keychain.load(reference: reference, scope: .mainAppOnly)
                    ))
                }

                try keychain.save(
                    privateKey,
                    reference: storedProfile.privateKeyReference,
                    scope: .sharedAccessGroup
                )
                for item in presharedKeys {
                    try keychain.save(
                        item.secret,
                        reference: item.reference,
                        scope: .sharedAccessGroup
                    )
                }

                var migrated = storedProfile
                migrated.secretScope = .sharedAccessGroup
                migrated.updatedAt = Date()
                try await repository.save(migrated)
                try? keychain.delete(
                    reference: storedProfile.privateKeyReference,
                    scope: .mainAppOnly
                )
                for item in presharedKeys {
                    try? keychain.delete(reference: item.reference, scope: .mainAppOnly)
                }
            } catch {
                // Keep the original scope and item intact. A partial shared
                // copy is harmless and can be overwritten on a later retry.
                continue
            }
        }
    }

    private func refreshStatus() {
        status = selectedManager?.connection.status ?? .invalid
        metricsTask?.cancel()
        guard status == .connected || status == .reasserting || status == .connecting else { return }
        metricsTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshDiagnostics()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func perform(_ operation: () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await operation()
        } catch {
            errorMessage = userFacingMessage(for: error)
        }
    }

    private func userFacingMessage(for error: Error) -> String {
        if let keychainError = error as? TunnelKeychainError {
            switch keychainError {
            case .missingEntitlement, .sharedAccessGroupUnavailable:
                return TunnelManagerError.sharedKeychainEntitlementRequired.localizedDescription
            case .invalidSecret, .keychain:
                break
            }
        }
        let underlying = error as NSError
        if (underlying.domain == "NEVPNErrorDomain" && underlying.code == 5)
            || underlying.localizedDescription.localizedCaseInsensitiveContains("permission denied") {
            return String(localized: "VPN settings permission was denied. Install a build signed with the Packet Tunnel Network Extension entitlement, then try again.")
        }
        return error.localizedDescription
    }

    private static func profileID(from manager: NETunnelProviderManager) -> UUID? {
        guard let tunnelProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol,
              tunnelProtocol.providerBundleIdentifier == TunnelConstants.providerBundleIdentifier,
              let string = tunnelProtocol.providerConfiguration?["profileID"] as? String else {
            return nil
        }
        return UUID(uuidString: string)
    }
}

enum TunnelManagerError: LocalizedError {
    case profileDisabled
    case sharedKeychainEntitlementRequired

    var errorDescription: String? {
        switch self {
        case .profileDisabled:
            String(localized: "Enable this tunnel profile before connecting.")
        case .sharedKeychainEntitlementRequired:
            String(localized: "This build is missing usable Bufi App Group access. Your key is still secure in the app Keychain, but this profile cannot connect until Bufi is correctly signed.")
        }
    }
}

private extension NETunnelProviderSession {
    func sendProviderMessage(_ data: Data) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            do {
                try sendProviderMessage(data) { response in
                    continuation.resume(returning: response)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
