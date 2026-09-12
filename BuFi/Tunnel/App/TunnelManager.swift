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
    var canConnect: Bool { isEnabled && status == .disconnected }

    func bootstrap() async {
        await perform {
            profiles = try await repository.all()
            let loaded = try await NETunnelProviderManager.loadAllFromPreferences()
            managers = Dictionary(uniqueKeysWithValues: loaded.compactMap { manager in
                guard let identifier = Self.profileID(from: manager) else { return nil }
                return (identifier, manager)
            })
            if selectedProfileID == nil || !profiles.contains(where: { $0.id == selectedProfileID }) {
                selectedProfileID = profiles.first?.id
            }
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
            if let privateKey {
                try keychain.save(privateKey, reference: profile.privateKeyReference)
                let derived = try TunnelKeyPair.publicKey(for: privateKey)
                guard derived == profile.publicKey else { throw TunnelValidationError.invalidPrivateKey }
            } else {
                _ = try keychain.load(reference: profile.privateKeyReference)
            }
            for peer in profile.peers {
                guard let secret = presharedKeys[peer.id] else { continue }
                let reference = peer.presharedKeyReference ?? "psk-\(profile.id.uuidString)-\(peer.id.uuidString)"
                try keychain.save(secret, reference: reference)
                if let index = profile.peers.firstIndex(where: { $0.id == peer.id }) {
                    profile.peers[index].presharedKeyReference = reference
                }
            }
            try await repository.save(profile)
            let manager = try await configuredManager(for: profile)
            managers[profile.id] = manager
            profiles = try await repository.all()
            selectedProfileID = profile.id
            refreshStatus()
            return true
        } catch {
            errorMessage = error.localizedDescription
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
            errorMessage = error.localizedDescription
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
            try? keychain.delete(reference: profile.privateKeyReference)
            for peer in profile.peers {
                if let reference = peer.presharedKeyReference {
                    try? keychain.delete(reference: reference)
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
            errorMessage = error.localizedDescription
        }
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

    var errorDescription: String? { "Enable this tunnel profile before connecting." }
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
