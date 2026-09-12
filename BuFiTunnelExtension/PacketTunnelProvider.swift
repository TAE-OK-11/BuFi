@preconcurrency import Network
@preconcurrency import NetworkExtension
import Foundation
import os

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private struct RuntimeState {
        var profile: TunnelProfile?
        var adapter: RustTunnelAdapter?
        var dnsResolver: (any TunnelDNSResolver)?
        var diagnostics = TunnelDiagnostics()
        var pathSignature: String?
        var generation: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: RuntimeState())
    private let pathMonitor = NWPathMonitor()
    private let pathQueue = DispatchQueue(
        label: "cloud.tae00217.BuFi.tunnel.path",
        qos: .utility
    )

    override func startTunnel(options: [String: NSObject]?) async throws {
        guard let tunnelProtocol = protocolConfiguration as? NETunnelProviderProtocol,
              let value = tunnelProtocol.providerConfiguration?["profileID"] as? String,
              let profileID = UUID(uuidString: value),
              let profile = try await TunnelProfileRepository.shared.profile(id: profileID) else {
            throw PacketTunnelProviderError.profileUnavailable
        }
        try TunnelProfileValidator.validate(profile, privateKey: nil)

        updateDiagnostics { diagnostics in
            diagnostics = TunnelDiagnostics(
                state: .connecting,
                currentNetworkPath: "Starting",
                dnsMode: profile.dns.mode,
                dnsResolverEndpoint: Self.dnsEndpoint(profile.dns)
            )
        }

        let resolved = try EngineConfigurationBuilder.make(profile: profile)
        let resolver = try TunnelDNSResolverFactory.make(profile.dns)
        do {
            try resolver.start()
            let settings = try TunnelNetworkSettingsBuilder.make(
                profile: profile,
                endpointIP: resolved.firstEndpointIP
            )
            settings.dnsSettings = resolver.settings
            try await setTunnelNetworkSettings(settings)

            let adapter = RustTunnelAdapter()
            try adapter.start(configuration: resolved.engine)
            state.withLock { runtime in
                runtime.profile = profile
                runtime.adapter = adapter
                runtime.dnsResolver = resolver
                runtime.diagnostics.state = .connected
                runtime.diagnostics.currentEndpoint = resolved.firstEndpointIP
                runtime.diagnostics.latestError = nil
                runtime.diagnostics.updatedAt = Date()
                runtime.generation &+= 1
            }
            persistDiagnostics()
            startPathMonitoring()
        } catch {
            resolver.stop()
            updateDiagnostics { diagnostics in
                diagnostics.state = .error
                diagnostics.latestError = error.localizedDescription
            }
            throw error
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        pathMonitor.cancel()
        let resources = state.withLock { runtime -> (RustTunnelAdapter?, (any TunnelDNSResolver)?) in
            runtime.diagnostics.state = .disconnecting
            runtime.diagnostics.updatedAt = Date()
            let resources = (runtime.adapter, runtime.dnsResolver)
            runtime.adapter = nil
            runtime.dnsResolver = nil
            runtime.profile = nil
            runtime.pathSignature = nil
            return resources
        }
        resources.0?.stop()
        resources.1?.stop()
        try? await setTunnelNetworkSettings(nil)
        updateDiagnostics { diagnostics in diagnostics.state = .disconnected }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        do {
            try state.withLock { runtime in try runtime.adapter?.suspend() }
            updateDiagnostics { diagnostics in diagnostics.state = .waitingForNetwork }
        } catch {
            updateDiagnostics { diagnostics in
                diagnostics.state = .error
                diagnostics.latestError = error.localizedDescription
            }
        }
        completionHandler()
    }

    override func wake() {
        pathQueue.async { [weak self] in self?.restartForNetworkChange(pathDescription: "Wake") }
    }

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)? = nil
    ) {
        guard let message = try? JSONDecoder().decode(TunnelProviderMessage.self, from: messageData),
              message == .diagnostics else {
            completionHandler?(nil)
            return
        }
        refreshEngineStatistics()
        let diagnostics = state.withLock { $0.diagnostics }
        completionHandler?(try? JSONEncoder().encode(diagnostics))
    }

    private func startPathMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path)
        }
        pathMonitor.start(queue: pathQueue)
    }

    private func handlePathUpdate(_ path: NWPath) {
        let signature = Self.describe(path)
        let previous = state.withLock { runtime -> String? in
            let previous = runtime.pathSignature
            runtime.pathSignature = signature
            runtime.diagnostics.currentNetworkPath = signature
            runtime.diagnostics.updatedAt = Date()
            return previous
        }
        guard path.status == .satisfied else {
            let generation = state.withLock { runtime -> UInt64 in
                runtime.generation &+= 1
                runtime.diagnostics.state = .waitingForNetwork
                return runtime.generation
            }
            pathQueue.asyncAfter(deadline: .now() + .milliseconds(400)) { [weak self] in
                guard let self else { return }
                let shouldSuspend = self.state.withLock {
                    $0.generation == generation && $0.pathSignature == signature
                }
                if shouldSuspend { try? self.state.withLock { try $0.adapter?.suspend() } }
                self.persistDiagnostics()
            }
            return
        }
        guard let previous else {
            persistDiagnostics()
            return
        }
        if previous != signature {
            restartForNetworkChange(pathDescription: signature)
        }
    }

    private func restartForNetworkChange(pathDescription: String) {
        guard let profile = state.withLock({ $0.profile }) else { return }
        reasserting = true
        defer { reasserting = false }
        updateDiagnostics { diagnostics in diagnostics.state = .reconnecting }
        do {
            let resolved = try EngineConfigurationBuilder.make(profile: profile)
            let adapter = state.withLock { runtime -> RustTunnelAdapter? in
                let adapter = runtime.adapter
                runtime.adapter = nil
                return adapter
            }
            adapter?.stop()
            let replacement = RustTunnelAdapter()
            try replacement.start(configuration: resolved.engine)
            state.withLock { runtime in
                runtime.adapter = replacement
                runtime.diagnostics.state = .connected
                runtime.diagnostics.currentEndpoint = resolved.firstEndpointIP
                runtime.diagnostics.currentNetworkPath = pathDescription
                runtime.diagnostics.reconnectCount &+= 1
                runtime.diagnostics.latestError = nil
                runtime.diagnostics.updatedAt = Date()
                runtime.generation &+= 1
            }
        } catch {
            updateDiagnostics { diagnostics in
                diagnostics.state = .error
                diagnostics.latestError = error.localizedDescription
            }
        }
        persistDiagnostics()
    }

    private func refreshEngineStatistics() {
        do {
            let statistics = try state.withLock { runtime -> RustEngineStatistics? in
                try runtime.adapter?.statistics()
            }
            guard let statistics else { return }
            updateDiagnostics { diagnostics in
                diagnostics.latestHandshake = statistics.latestHandshake.map {
                    Date(timeIntervalSince1970: TimeInterval($0))
                }
                diagnostics.txBytes = statistics.txBytes
                diagnostics.rxBytes = statistics.rxBytes
                diagnostics.currentEndpoint = statistics.currentEndpoint
            }
        } catch {
            updateDiagnostics { diagnostics in diagnostics.latestError = error.localizedDescription }
        }
    }

    private func updateDiagnostics(_ body: (inout TunnelDiagnostics) -> Void) {
        state.withLock { runtime in
            body(&runtime.diagnostics)
            runtime.diagnostics.updatedAt = Date()
        }
        persistDiagnostics()
    }

    private func persistDiagnostics() {
        let diagnostics = state.withLock { $0.diagnostics }
        Task { try? await TunnelProfileRepository.shared.saveDiagnostics(diagnostics) }
    }

    private static func describe(_ path: NWPath) -> String {
        let interface: String
        if path.usesInterfaceType(.wifi) {
            interface = "Wi-Fi"
        } else if path.usesInterfaceType(.cellular) {
            interface = "Cellular"
        } else if path.usesInterfaceType(.wiredEthernet) {
            interface = "Ethernet"
        } else {
            interface = path.status == .satisfied ? "Other" : "Offline"
        }
        let flags = [path.isExpensive ? "metered" : nil, path.isConstrained ? "constrained" : nil]
            .compactMap { $0 }
            .joined(separator: ", ")
        return flags.isEmpty ? interface : "\(interface) (\(flags))"
    }

    private static func dnsEndpoint(_ dns: TunnelDNSConfiguration) -> String? {
        switch dns.mode {
        case .system: nil
        case .plain: dns.servers.joined(separator: ", ")
        case .https, .tls, .quic: dns.resolverEndpoint
        }
    }
}

enum PacketTunnelProviderError: LocalizedError {
    case profileUnavailable

    var errorDescription: String? { "The selected Bufi Tunnel profile is unavailable." }
}

