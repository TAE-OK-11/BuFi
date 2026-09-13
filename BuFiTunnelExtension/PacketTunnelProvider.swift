@preconcurrency import Network
@preconcurrency import NetworkExtension
import Foundation
import os

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private struct RuntimeState {
        var profile: TunnelProfile?
        var adapter: RustTunnelAdapter?
        var dnsResolver: (any TunnelDNSResolver)?
        var pathMonitor: NWPathMonitor?
        var diagnostics = TunnelDiagnostics()
        var pathFingerprint: String?
        var pathIsSatisfiable: Bool?
        var generation: UInt64 = 0
        var sessionID: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: RuntimeState())
    private let pathQueue = DispatchQueue(
        label: "cloud.tae00217.BuFi.tunnel.path",
        qos: .utility
    )

    override func startTunnel(options: [String: NSObject]?) async throws {
        let sessionID = try state.withLock { runtime -> UInt64 in
            guard runtime.adapter == nil else { throw PacketTunnelProviderError.alreadyRunning }
            runtime.sessionID &+= 1
            return runtime.sessionID
        }
        let profile: TunnelProfile
        do {
            guard let tunnelProtocol = protocolConfiguration as? NETunnelProviderProtocol,
                  let value = tunnelProtocol.providerConfiguration?["profileID"] as? String,
                  let profileID = UUID(uuidString: value),
                  let storedProfile = try await TunnelProfileRepository.shared.profile(id: profileID) else {
                throw PacketTunnelProviderError.profileUnavailable
            }
            try TunnelProfileValidator.validate(storedProfile, privateKey: nil)
            profile = storedProfile
        } catch {
            let message = error.localizedDescription
            updateDiagnostics(for: sessionID) { diagnostics in
                diagnostics.state = .error
                diagnostics.latestError = message
            }
            throw error
        }

        updateDiagnostics(for: sessionID) { diagnostics in
            diagnostics = TunnelDiagnostics(
                state: .connecting,
                currentNetworkPath: "Starting",
                dnsMode: profile.dns.effectiveResolver.mode,
                dnsResolverEndpoint: Self.dnsEndpoint(profile.dns),
                dnsProtectionEnabled: profile.dns.effectiveProtection.isEnabled,
                dnsProtectionPreset: profile.dns.effectiveProtection.isEnabled
                    ? profile.dns.effectiveProtection.preset
                    : nil
            )
        }

        var resolver: (any TunnelDNSResolver)?
        do {
            let resolved = try EngineConfigurationBuilder.make(profile: profile)
            let configuredResolver = try TunnelDNSResolverFactory.make(profile.dns)
            resolver = configuredResolver
            try configuredResolver.start()
            let settings = try TunnelNetworkSettingsBuilder.make(
                profile: profile,
                endpointIP: resolved.firstEndpointIP
            )
            settings.dnsSettings = configuredResolver.settings
            try await setTunnelNetworkSettings(settings)

            let adapter = RustTunnelAdapter()
            try adapter.start(configuration: resolved.engine)
            let installed = state.withLock { runtime -> Bool in
                guard runtime.sessionID == sessionID, runtime.adapter == nil else { return false }
                runtime.profile = profile
                runtime.adapter = adapter
                runtime.dnsResolver = configuredResolver
                runtime.diagnostics.state = .connected
                runtime.diagnostics.currentEndpoint = resolved.firstEndpointIP
                runtime.diagnostics.latestError = nil
                runtime.diagnostics.updatedAt = Date()
                runtime.generation &+= 1
                return true
            }
            guard installed else {
                adapter.stop()
                throw PacketTunnelProviderError.startupCancelled
            }
            persistDiagnostics()
            startPathMonitoring(sessionID: sessionID)
        } catch {
            resolver?.stop()
            let message = error.localizedDescription
            updateDiagnostics(for: sessionID) { diagnostics in
                diagnostics.state = .error
                diagnostics.latestError = message
            }
            throw error
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        let resources = state.withLock {
            runtime -> (UInt64, NWPathMonitor?, RustTunnelAdapter?, (any TunnelDNSResolver)?) in
            runtime.diagnostics.state = .disconnecting
            runtime.diagnostics.updatedAt = Date()
            runtime.sessionID &+= 1
            let resources = (
                runtime.sessionID,
                runtime.pathMonitor,
                runtime.adapter,
                runtime.dnsResolver
            )
            runtime.pathMonitor = nil
            runtime.adapter = nil
            runtime.dnsResolver = nil
            runtime.profile = nil
            runtime.pathFingerprint = nil
            runtime.pathIsSatisfiable = nil
            runtime.generation &+= 1
            return resources
        }
        resources.1?.cancel()
        resources.2?.stop()
        resources.3?.stop()
        try? await setTunnelNetworkSettings(nil)
        let didDisconnect = state.withLock { runtime -> Bool in
            guard runtime.sessionID == resources.0, runtime.profile == nil else { return false }
            runtime.diagnostics.state = .disconnected
            runtime.diagnostics.updatedAt = Date()
            return true
        }
        if didDisconnect { persistDiagnostics() }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        let snapshot = state.withLock { runtime in
            (runtime.sessionID, runtime.adapter)
        }
        guard let adapter = snapshot.1 else {
            completionHandler()
            return
        }
        do {
            try adapter.suspend()
            let shouldPersist = state.withLock { runtime -> Bool in
                guard runtime.sessionID == snapshot.0, runtime.adapter === adapter else { return false }
                runtime.diagnostics.state = .waitingForNetwork
                runtime.diagnostics.updatedAt = Date()
                return true
            }
            if shouldPersist { persistDiagnostics() }
        } catch {
            let message = error.localizedDescription
            updateDiagnostics(for: snapshot.0) { diagnostics in
                diagnostics.state = .error
                diagnostics.latestError = message
            }
        }
        completionHandler()
    }

    override func wake() {
        let snapshot = state.withLock { runtime in
            (runtime.sessionID, runtime.pathIsSatisfiable, runtime.profile != nil)
        }
        guard snapshot.2, snapshot.1 != false else { return }
        pathQueue.async { [weak self] in
            self?.restartForNetworkChange(pathDescription: "Wake", sessionID: snapshot.0)
        }
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

    private func startPathMonitoring(sessionID: UInt64) {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path, sessionID: sessionID)
        }
        let installed = state.withLock { runtime -> Bool in
            guard runtime.sessionID == sessionID, runtime.profile != nil else { return false }
            runtime.pathMonitor?.cancel()
            runtime.pathMonitor = monitor
            monitor.start(queue: pathQueue)
            return true
        }
        if !installed { monitor.cancel() }
    }

    private func handlePathUpdate(_ path: NWPath, sessionID: UInt64) {
        let signature = Self.describe(path)
        let fingerprint = Self.fingerprint(path)
        let isSatisfiable = Self.isSatisfiable(path.status)
        let update = state.withLock { runtime -> (previous: String?, generation: UInt64)? in
            guard runtime.sessionID == sessionID, runtime.profile != nil else { return nil }
            let previous = runtime.pathFingerprint
            runtime.pathFingerprint = fingerprint
            runtime.pathIsSatisfiable = isSatisfiable
            runtime.diagnostics.currentNetworkPath = signature
            runtime.diagnostics.updatedAt = Date()
            return (previous, runtime.generation)
        }
        guard let update else { return }
        guard isSatisfiable else {
            let generation = state.withLock { runtime -> UInt64? in
                guard runtime.sessionID == sessionID, runtime.profile != nil else { return nil }
                runtime.generation &+= 1
                runtime.diagnostics.state = .waitingForNetwork
                runtime.diagnostics.updatedAt = Date()
                return runtime.generation
            }
            guard let generation else { return }
            pathQueue.asyncAfter(deadline: .now() + .milliseconds(400)) { [weak self] in
                guard let self else { return }
                let shouldSuspend = self.state.withLock {
                    $0.sessionID == sessionID
                        && $0.generation == generation
                        && $0.pathFingerprint == fingerprint
                        && $0.pathIsSatisfiable == false
                }
                if shouldSuspend {
                    try? self.state.withLock { try $0.adapter?.suspend() }
                    self.persistDiagnostics()
                }
            }
            return
        }
        guard let previous = update.previous else {
            persistDiagnostics()
            return
        }
        if previous != fingerprint {
            restartForNetworkChange(pathDescription: signature, sessionID: sessionID)
        }
    }

    private func restartForNetworkChange(pathDescription: String, sessionID: UInt64) {
        guard let snapshot = state.withLock({ runtime -> (TunnelProfile, RustTunnelAdapter)? in
            guard runtime.sessionID == sessionID,
                  let profile = runtime.profile,
                  let adapter = runtime.adapter else { return nil }
            return (profile, adapter)
        }) else { return }
        reasserting = true
        defer { reasserting = false }
        guard updateDiagnostics(for: sessionID, { diagnostics in
            diagnostics.state = .reconnecting
        }) else { return }
        do {
            let refresh = EngineConfigurationBuilder.makeEndpointRefresh(profile: snapshot.0)
            do {
                if refresh.endpoints.peers.isEmpty {
                    // DNS may be temporarily unavailable during a handoff. Keep
                    // the last endpoints and still recycle the UDP sockets.
                    try snapshot.1.rebind()
                } else {
                    try snapshot.1.reconfigure(endpoints: refresh.endpoints)
                }
            } catch {
                // A failed in-place update may leave sockets suspended. A full
                // replacement is the bounded recovery path, not a retry loop.
                let resolved = try EngineConfigurationBuilder.make(
                    profile: snapshot.0,
                    strategy: .networkChange
                )
                guard isCurrentSession(sessionID, adapter: snapshot.1) else { return }
                snapshot.1.stop()
                guard state.withLock({ $0.sessionID == sessionID && $0.profile != nil }) else {
                    return
                }
                let replacement = RustTunnelAdapter()
                try replacement.start(configuration: resolved.engine)
                let didInstall = state.withLock { runtime -> Bool in
                    guard runtime.sessionID == sessionID,
                          runtime.adapter === snapshot.1 else { return false }
                    runtime.adapter = replacement
                    return true
                }
                guard didInstall else {
                    replacement.stop()
                    return
                }
            }
            let didRecover = state.withLock { runtime -> Bool in
                guard runtime.sessionID == sessionID, runtime.profile != nil else { return false }
                runtime.diagnostics.state = .connected
                if let endpoint = refresh.firstEndpointIP {
                    runtime.diagnostics.currentEndpoint = endpoint
                }
                runtime.diagnostics.currentNetworkPath = pathDescription
                runtime.diagnostics.reconnectCount &+= 1
                runtime.diagnostics.latestError = refresh.unresolvedHosts.isEmpty
                    ? nil
                    : Self.partialEndpointResolutionMessage(refresh.unresolvedHosts)
                runtime.diagnostics.updatedAt = Date()
                runtime.generation &+= 1
                return true
            }
            guard didRecover else { return }
        } catch {
            guard state.withLock({ $0.sessionID == sessionID && $0.profile != nil }) else { return }
            let message = error.localizedDescription
            updateDiagnostics(for: sessionID) { diagnostics in
                diagnostics.state = .error
                diagnostics.latestError = message
            }
        }
        persistDiagnostics()
    }

    private func isCurrentSession(_ sessionID: UInt64, adapter: RustTunnelAdapter) -> Bool {
        state.withLock {
            $0.sessionID == sessionID && $0.profile != nil && $0.adapter === adapter
        }
    }

    private func refreshEngineStatistics() {
        let snapshot = state.withLock { runtime in
            (runtime.sessionID, runtime.adapter, runtime.dnsResolver)
        }
        guard let adapter = snapshot.1 else { return }
        do {
            let statistics = try adapter.statistics()
            let blockedQueryCount = snapshot.2?.blockedQueryCount ?? 0
            let didUpdate = state.withLock { runtime -> Bool in
                guard runtime.sessionID == snapshot.0, runtime.adapter === adapter else {
                    return false
                }
                var diagnostics = runtime.diagnostics
                diagnostics.latestHandshake = statistics.latestHandshake.map {
                    Date(timeIntervalSince1970: TimeInterval($0))
                }
                diagnostics.txBytes = statistics.txBytes
                diagnostics.rxBytes = statistics.rxBytes
                diagnostics.currentEndpoint = statistics.currentEndpoint
                diagnostics.dnsBlockedQueryCount = blockedQueryCount
                diagnostics.updatedAt = Date()
                runtime.diagnostics = diagnostics
                return true
            }
            if didUpdate { persistDiagnostics() }
        } catch {
            let message = error.localizedDescription
            updateDiagnostics(for: snapshot.0) { diagnostics in
                diagnostics.latestError = message
            }
        }
    }

    @discardableResult
    private func updateDiagnostics(
        for sessionID: UInt64,
        _ body: @Sendable (inout TunnelDiagnostics) -> Void
    ) -> Bool {
        let didUpdate = state.withLock { runtime -> Bool in
            guard runtime.sessionID == sessionID else { return false }
            body(&runtime.diagnostics)
            runtime.diagnostics.updatedAt = Date()
            return true
        }
        if didUpdate { persistDiagnostics() }
        return didUpdate
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
            interface = isSatisfiable(path.status) ? "Other" : "Offline"
        }
        let flags = [path.isExpensive ? "metered" : nil, path.isConstrained ? "constrained" : nil]
            .compactMap { $0 }
            .joined(separator: ", ")
        return flags.isEmpty ? interface : "\(interface) (\(flags))"
    }

    private static func fingerprint(_ path: NWPath) -> String {
        let interfaces = path.availableInterfaces
            .map { "\(interfaceName($0.type)):\($0.name)" }
            .sorted()
            .joined(separator: ",")
        let gateways = path.gateways.map { String(describing: $0) }.sorted().joined(separator: ",")
        return [
            String(describing: path.status),
            interfaces,
            gateways,
            path.supportsIPv4 ? "v4" : "-",
            path.supportsIPv6 ? "v6" : "-",
            path.supportsDNS ? "dns" : "-",
            path.isExpensive ? "expensive" : "-",
            path.isConstrained ? "constrained" : "-"
        ].joined(separator: "|")
    }

    private static func interfaceName(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi: "wifi"
        case .cellular: "cellular"
        case .wiredEthernet: "ethernet"
        case .loopback: "loopback"
        case .other: "other"
        @unknown default: "unknown"
        }
    }

    private static func isSatisfiable(_ status: NWPath.Status) -> Bool {
        switch status {
        case .unsatisfied: false
        case .requiresConnection, .satisfied: true
        @unknown default: true
        }
    }

    private static func partialEndpointResolutionMessage(_ hosts: [String]) -> String {
        String(
            format: String(localized: "Some WireGuard endpoints could not be re-resolved; their last known addresses were retained: %@"),
            locale: .current,
            hosts.joined(separator: ", ")
        )
    }

    private static func dnsEndpoint(_ dns: TunnelDNSConfiguration) -> String? {
        let dns = dns.effectiveResolver
        return switch dns.mode {
        case .system: nil
        case .plain: dns.servers.joined(separator: ", ")
        case .https, .tls, .quic: dns.resolverEndpoint
        }
    }
}

enum PacketTunnelProviderError: LocalizedError {
    case profileUnavailable
    case alreadyRunning
    case startupCancelled

    var errorDescription: String? {
        switch self {
        case .profileUnavailable: String(localized: "The selected Bufi Tunnel profile is unavailable.")
        case .alreadyRunning: String(localized: "Bufi Tunnel is already running.")
        case .startupCancelled: String(localized: "Bufi Tunnel startup was cancelled.")
        }
    }
}
