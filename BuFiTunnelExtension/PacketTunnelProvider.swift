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
        var healthTimer: (any DispatchSourceTimer)?
        var engineConfiguration: RustEngineConfiguration?
        var diagnostics = TunnelDiagnostics()
        var pathFingerprint: String?
        var pathIsSatisfiable: Bool?
        var generation: UInt64 = 0
        var sessionID: UInt64 = 0
        var startedAt = Date()
        var previousStatistics: RustEngineStatistics?
        var stalledHealthSamples = 0
        var autoHealStage = 0
        var lastAutoHeal: Date?
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
        let launchMaterial: TunnelLaunchMaterial?
        do {
            guard let tunnelProtocol = protocolConfiguration as? NETunnelProviderProtocol,
                  let value = tunnelProtocol.providerConfiguration?["profileID"] as? String,
                  let profileID = UUID(uuidString: value) else {
                throw PacketTunnelProviderError.profileUnavailable
            }
            if let material = try TunnelLaunchOptions.decode(options) {
                guard material.profile.id == profileID else {
                    throw PacketTunnelProviderError.profileMismatch
                }
                try TunnelProfileValidator.validate(
                    material.profile,
                    privateKey: material.privateKey
                )
                profile = material.profile
                launchMaterial = material
            } else {
                guard let storedProfile = try await TunnelProfileRepository.shared.profile(
                    id: profileID
                ) else {
                    throw PacketTunnelProviderError.profileUnavailable
                }
                try TunnelProfileValidator.validate(storedProfile, privateKey: nil)
                profile = storedProfile
                launchMaterial = nil
            }
        } catch {
            let message = error.localizedDescription
            updateDiagnostics(for: sessionID) { diagnostics in
                diagnostics.state = .error
                diagnostics.latestError = message
            }
            throw error
        }

        let cachedBlocklistRuleCount = (
            try? TunnelBlocklistCache.metadata(profileID: profile.id)
        )?.ruleCount
        updateDiagnostics(for: sessionID) { diagnostics in
            diagnostics = TunnelDiagnostics(
                state: .connecting,
                currentNetworkPath: "Starting",
                dnsMode: profile.dns.effectiveResolver.mode,
                dnsResolverEndpoint: Self.dnsEndpoint(profile.dns),
                dnsProtectionEnabled: profile.dns.effectiveProtection.isEnabled,
                dnsProtectionPreset: profile.dns.effectiveProtection.isEnabled
                    ? profile.dns.effectiveProtection.preset
                    : nil,
                blocklistRuleCount: cachedBlocklistRuleCount,
                healthState: .observing,
                healthDetail: String(localized: "Waiting for enough traffic to evaluate tunnel health.")
            )
        }

        var resolver: (any TunnelDNSResolver)?
        do {
            let resolved: EngineConfigurationBuilder.Result
            if let launchMaterial {
                resolved = try EngineConfigurationBuilder.make(
                    profile: profile,
                    privateKey: launchMaterial.privateKey,
                    presharedKeys: launchMaterial.presharedKeys
                )
            } else {
                resolved = try EngineConfigurationBuilder.make(profile: profile)
            }
            let configuredResolver = try TunnelDNSResolverFactory.make(
                profile.dns,
                profileID: profile.id
            )
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
                runtime.engineConfiguration = resolved.engine
                runtime.diagnostics.state = .connected
                runtime.diagnostics.currentEndpoint = resolved.firstEndpointIP
                runtime.diagnostics.latestError = nil
                runtime.diagnostics.updatedAt = Date()
                runtime.generation &+= 1
                runtime.startedAt = Date()
                runtime.previousStatistics = nil
                runtime.stalledHealthSamples = 0
                runtime.autoHealStage = 0
                runtime.lastAutoHeal = nil
                return true
            }
            guard installed else {
                adapter.stop()
                throw PacketTunnelProviderError.startupCancelled
            }
            persistDiagnostics()
            startPathMonitoring(sessionID: sessionID)
            startHealthMonitoring(sessionID: sessionID)
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
            runtime -> (
                UInt64,
                NWPathMonitor?,
                DispatchSourceTimer?,
                RustTunnelAdapter?,
                (any TunnelDNSResolver)?
            ) in
            runtime.diagnostics.state = .disconnecting
            runtime.diagnostics.updatedAt = Date()
            runtime.sessionID &+= 1
            let resources = (
                runtime.sessionID,
                runtime.pathMonitor,
                runtime.healthTimer,
                runtime.adapter,
                runtime.dnsResolver
            )
            runtime.pathMonitor = nil
            runtime.healthTimer = nil
            runtime.adapter = nil
            runtime.dnsResolver = nil
            runtime.engineConfiguration = nil
            runtime.profile = nil
            runtime.pathFingerprint = nil
            runtime.pathIsSatisfiable = nil
            runtime.generation &+= 1
            return resources
        }
        resources.1?.cancel()
        resources.2?.cancel()
        resources.3?.stop()
        resources.4?.stop()
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

    private func startHealthMonitoring(sessionID: UInt64) {
        let timer = DispatchSource.makeTimerSource(queue: pathQueue)
        timer.schedule(
            deadline: .now() + .seconds(30),
            repeating: .seconds(30),
            leeway: .seconds(5)
        )
        timer.setEventHandler { [weak self] in
            self?.evaluateHealth(sessionID: sessionID)
        }
        let installed = state.withLock { runtime -> Bool in
            guard runtime.sessionID == sessionID, runtime.adapter != nil else { return false }
            runtime.healthTimer?.cancel()
            runtime.healthTimer = timer
            return true
        }
        timer.activate()
        if !installed { timer.cancel() }
    }

    /// WireGuard can be legitimately idle, so an old handshake alone never
    /// triggers recovery. We require fresh transmitted traffic with no receive
    /// or handshake progress, or three observed failures from the local DNS
    /// proxy. Native encrypted DNS is intentionally reported as unobservable.
    private func evaluateHealth(sessionID: UInt64) {
        let snapshot = state.withLock { runtime in
            (runtime.adapter, runtime.dnsResolver, runtime.pathIsSatisfiable)
        }
        guard snapshot.2 != false, let adapter = snapshot.0 else { return }
        do {
            let statistics = try adapter.statistics()
            let dnsHealth = snapshot.1?.health ?? .unavailable
            let now = Date()
            let stage = state.withLock { runtime -> Int? in
                guard runtime.sessionID == sessionID, runtime.adapter === adapter else { return nil }
                let previous = runtime.previousStatistics
                runtime.previousStatistics = statistics
                runtime.diagnostics.latestHandshake = statistics.latestHandshake.map {
                    Date(timeIntervalSince1970: TimeInterval($0))
                }
                runtime.diagnostics.txBytes = statistics.txBytes
                runtime.diagnostics.rxBytes = statistics.rxBytes
                runtime.diagnostics.currentEndpoint = statistics.currentEndpoint

                let receivedProgress = previous.map { statistics.rxBytes > $0.rxBytes } ?? false
                let handshakeProgress = previous?.latestHandshake != statistics.latestHandshake
                    && statistics.latestHandshake != nil
                if receivedProgress || handshakeProgress {
                    runtime.stalledHealthSamples = 0
                    runtime.autoHealStage = 0
                    runtime.diagnostics.healthState = .healthy
                    runtime.diagnostics.healthDetail = String(localized: "Traffic or handshake progress is healthy.")
                    return nil
                }

                let sentProgress = previous.map { statistics.txBytes > $0.txBytes } ?? false
                let handshakeDate = statistics.latestHandshake.map {
                    Date(timeIntervalSince1970: TimeInterval($0))
                }
                let handshakeIsStale = handshakeDate.map { now.timeIntervalSince($0) > 150 } ?? true
                if sentProgress,
                   handshakeIsStale,
                   now.timeIntervalSince(runtime.startedAt) > 60 {
                    runtime.stalledHealthSamples += 1
                } else if !sentProgress {
                    runtime.stalledHealthSamples = 0
                }
                let dnsFailed = dnsHealth.isObservable && dnsHealth.consecutiveFailures >= 3
                let peerStalled = runtime.stalledHealthSamples >= 2
                guard dnsFailed || peerStalled else {
                    runtime.diagnostics.healthState = .healthy
                    runtime.diagnostics.healthDetail = dnsHealth.isObservable
                        ? String(localized: "Tunnel and local DNS checks are healthy.")
                        : String(localized: "Tunnel traffic is healthy; native DNS health is managed by iOS.")
                    return nil
                }

                runtime.diagnostics.healthState = .degraded
                runtime.diagnostics.healthDetail = dnsFailed
                    ? String(localized: "The local encrypted DNS resolver stopped responding.")
                    : String(localized: "WireGuard sent traffic without peer response or handshake progress.")
                let cooldown: TimeInterval = runtime.autoHealStage >= 3 ? 120 : 30
                if let last = runtime.lastAutoHeal, now.timeIntervalSince(last) < cooldown {
                    return nil
                }
                runtime.autoHealStage = min(3, runtime.autoHealStage + 1)
                runtime.lastAutoHeal = now
                runtime.diagnostics.healthState = .recovering
                runtime.diagnostics.lastAutoHeal = now
                return runtime.autoHealStage
            }
            persistDiagnostics()
            if let stage { performHealthRecovery(stage: stage, sessionID: sessionID, adapter: adapter) }
        } catch {
            let message = error.localizedDescription
            updateDiagnostics(for: sessionID) { diagnostics in
                diagnostics.healthState = .degraded
                diagnostics.healthDetail = message
            }
        }
    }

    private func performHealthRecovery(
        stage: Int,
        sessionID: UInt64,
        adapter: RustTunnelAdapter
    ) {
        guard let profile = state.withLock({ runtime -> TunnelProfile? in
            guard runtime.sessionID == sessionID, runtime.adapter === adapter else { return nil }
            return runtime.profile
        }) else { return }
        reasserting = true
        defer { reasserting = false }
        do {
            switch stage {
            case 1:
                try adapter.rebind()
            case 2:
                let refresh = EngineConfigurationBuilder.makeEndpointRefresh(profile: profile)
                if refresh.endpoints.peers.isEmpty {
                    try adapter.rebind()
                } else {
                    try adapter.reconfigure(endpoints: refresh.endpoints)
                    state.withLock { runtime in
                        if runtime.sessionID == sessionID, runtime.adapter === adapter,
                           let base = runtime.engineConfiguration {
                            runtime.engineConfiguration = Self.applying(refresh.endpoints, to: base)
                        }
                    }
                }
            default:
                try replaceEngine(sessionID: sessionID, adapter: adapter, profile: profile)
            }
            updateDiagnostics(for: sessionID) { diagnostics in
                diagnostics.state = .connected
                diagnostics.healthState = .observing
                diagnostics.autoHealCount = (diagnostics.autoHealCount ?? 0) &+ 1
                diagnostics.healthDetail = switch stage {
                case 1: String(localized: "Auto Heal recycled the WireGuard UDP sockets.")
                case 2: String(localized: "Auto Heal refreshed the peer endpoint and requested a reconnect.")
                default: String(localized: "Auto Heal rebuilt the tunnel engine.")
                }
            }
        } catch {
            let message = error.localizedDescription
            updateDiagnostics(for: sessionID) { diagnostics in
                diagnostics.state = .reconnecting
                diagnostics.healthState = .degraded
                diagnostics.healthDetail = message
            }
        }
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
                    state.withLock { runtime in
                        if runtime.sessionID == sessionID, runtime.adapter === snapshot.1,
                           let base = runtime.engineConfiguration {
                            runtime.engineConfiguration = Self.applying(refresh.endpoints, to: base)
                        }
                    }
                }
            } catch {
                // A failed in-place update may leave sockets suspended. A full
                // replacement is the bounded recovery path, not a retry loop.
                try replaceEngine(
                    sessionID: sessionID,
                    adapter: snapshot.1,
                    profile: snapshot.0
                )
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

    private func replaceEngine(
        sessionID: UInt64,
        adapter: RustTunnelAdapter,
        profile: TunnelProfile
    ) throws {
        let refresh = EngineConfigurationBuilder.makeEndpointRefresh(profile: profile)
        guard let base = state.withLock({ runtime -> RustEngineConfiguration? in
            guard runtime.sessionID == sessionID, runtime.adapter === adapter else { return nil }
            return runtime.engineConfiguration
        }) else { return }
        let configuration = refresh.endpoints.peers.isEmpty
            ? base
            : Self.applying(refresh.endpoints, to: base)
        adapter.stop()
        guard state.withLock({ $0.sessionID == sessionID && $0.profile != nil }) else { return }
        do {
            try adapter.start(configuration: configuration)
        } catch {
            // Keep the previous resolved endpoints as a rollback if a newly
            // resolved address cannot start yet.
            try? adapter.start(configuration: base)
            throw error
        }
        state.withLock { runtime in
            guard runtime.sessionID == sessionID, runtime.adapter === adapter else { return }
            runtime.engineConfiguration = configuration
            runtime.previousStatistics = nil
        }
    }

    private static func applying(
        _ endpoints: RustEndpointConfiguration,
        to configuration: RustEngineConfiguration
    ) -> RustEngineConfiguration {
        let replacements = Dictionary(uniqueKeysWithValues: endpoints.peers.map {
            ($0.publicKey, $0)
        })
        return RustEngineConfiguration(
            privateKey: configuration.privateKey,
            mtu: configuration.mtu,
            peers: configuration.peers.map { peer in
                guard let endpoint = replacements[peer.publicKey] else { return peer }
                return RustPeerConfiguration(
                    publicKey: peer.publicKey,
                    presharedKey: peer.presharedKey,
                    endpointIP: endpoint.endpointIP,
                    endpointPort: endpoint.endpointPort,
                    allowedIPs: peer.allowedIPs,
                    persistentKeepalive: peer.persistentKeepalive
                )
            }
        )
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
    case profileMismatch
    case alreadyRunning
    case startupCancelled

    var errorDescription: String? {
        switch self {
        case .profileUnavailable: String(localized: "The selected Bufi Tunnel profile is unavailable.")
        case .profileMismatch: String(localized: "The in-memory Tunnel profile does not match the selected VPN configuration.")
        case .alreadyRunning: String(localized: "Bufi Tunnel is already running.")
        case .startupCancelled: String(localized: "Bufi Tunnel startup was cancelled.")
        }
    }
}
