@preconcurrency import Network
@preconcurrency import NetworkExtension
import Foundation
import Security

protocol TunnelDNSResolver: AnyObject, Sendable {
    var settings: NEDNSSettings? { get }
    var blockedQueryCount: UInt64 { get }
    func start() throws
    func stop()
}

enum TunnelDNSResolverFactory {
    static func make(_ configuration: TunnelDNSConfiguration) throws -> TunnelDNSResolver {
        let protection = configuration.effectiveProtection
        let effective = configuration.effectiveResolver
        switch effective.mode {
        case .system:
            return NativeDNSResolver(settings: nil)
        case .plain:
            let settings = NEDNSSettings(servers: effective.servers)
            settings.matchDomains = [""]
            return NativeDNSResolver(settings: settings)
        case .https:
            guard let url = URL(string: effective.resolverEndpoint) else {
                throw TunnelValidationError.invalidDNSConfiguration
            }
            let settings = NEDNSOverHTTPSSettings(servers: effective.servers)
            settings.serverURL = url
            settings.matchDomains = [""]
            return NativeDNSResolver(settings: settings)
        case .tls:
            let settings = NEDNSOverTLSSettings(servers: effective.servers)
            settings.serverName = effective.serverName.isEmpty
                ? effective.resolverEndpoint
                : effective.serverName
            settings.matchDomains = [""]
            return NativeDNSResolver(settings: settings)
        case .quic:
            let filter = protection.isEnabled && protection.hasCustomRules
                ? TunnelDNSMessageFilter(
                    blockedDomains: protection.blockedDomains,
                    allowedDomains: protection.allowedDomains
                )
                : nil
            return DoQDNSResolver(configuration: effective, filter: filter)
        }
    }
}

private final class NativeDNSResolver: TunnelDNSResolver, @unchecked Sendable {
    let settings: NEDNSSettings?
    let blockedQueryCount: UInt64 = 0

    init(settings: NEDNSSettings?) { self.settings = settings }
    func start() throws {}
    func stop() {}
}

/// A deliberately isolated RFC 9250 proxy. iOS has native settings classes for
/// DoH and DoT but not DoQ, so system DNS is accepted on loopback port 53 and
/// each DNS message is forwarded on an authenticated QUIC stream using ALPN
/// `doq`. Replacing this class does not affect routing or the WireGuard engine.
private final class DoQDNSResolver: TunnelDNSResolver, @unchecked Sendable {
    let settings: NEDNSSettings?

    private let configuration: TunnelDNSConfiguration
    private let filter: TunnelDNSMessageFilter?
    private let queue = DispatchQueue(label: "cloud.tae00217.BuFi.tunnel.doq", qos: .utility)
    private let state = NSLock()
    private var udpListener: NWListener?
    private var tcpListener: NWListener?
    private var upstreams: [UUID: NWConnection] = [:]
    private var blockedQueries: UInt64 = 0

    var blockedQueryCount: UInt64 { state.locked { blockedQueries } }

    init(configuration: TunnelDNSConfiguration, filter: TunnelDNSMessageFilter?) {
        self.configuration = configuration
        self.filter = filter
        let dns = NEDNSSettings(servers: ["127.0.0.1"])
        dns.matchDomains = [""]
        settings = dns
    }

    func start() throws {
        let port = NWEndpoint.Port(rawValue: 53)!
        let udpParameters = NWParameters.udp
        udpParameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        let tcpParameters = NWParameters.tcp
        tcpParameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        let udp = try NWListener(using: udpParameters)
        let tcp = try NWListener(using: tcpParameters)
        udp.newConnectionHandler = { [weak self] connection in self?.acceptUDP(connection) }
        tcp.newConnectionHandler = { [weak self] connection in self?.acceptTCP(connection) }
        try startAndWait(udp)
        do {
            try startAndWait(tcp)
        } catch {
            udp.cancel()
            throw error
        }
        state.locked {
            udpListener = udp
            tcpListener = tcp
        }
    }

    func stop() {
        let values: (NWListener?, NWListener?, [NWConnection]) = state.locked {
            let values = (udpListener, tcpListener, Array(upstreams.values))
            udpListener = nil
            tcpListener = nil
            upstreams.removeAll()
            return values
        }
        values.0?.cancel()
        values.1?.cancel()
        values.2.forEach { $0.cancel() }
    }

    private func acceptUDP(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveUDP(on: connection)
    }

    private func startAndWait(_ listener: NWListener) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let result = ListenerStartResult()
        listener.stateUpdateHandler = { listenerState in
            let didComplete: Bool
            switch listenerState {
            case .ready:
                didComplete = result.complete(error: nil)
            case .failed(let error):
                didComplete = result.complete(error: error)
            default:
                didComplete = false
            }
            if didComplete { semaphore.signal() }
        }
        listener.start(queue: queue)
        guard semaphore.wait(timeout: .now() + .seconds(2)) == .success else {
            listener.cancel()
            throw TunnelDNSProxyError.listenerTimeout
        }
        if let startError = result.error { throw startError }
    }

    private func receiveUDP(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] content, _, _, error in
            guard let self, let connection else { return }
            if let content, !content.isEmpty {
                self.forward(content) { response in
                    guard let response else { return }
                    connection.send(content: response, completion: .contentProcessed { _ in })
                }
            }
            if error == nil { self.receiveUDP(on: connection) }
        }
    }

    private func acceptTCP(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveTCPFrame(on: connection)
    }

    private func receiveTCPFrame(on connection: NWConnection) {
        receiveExactly(2, on: connection) { [weak self, weak connection] prefix in
            guard let self, let connection, let prefix, prefix.count == 2 else { return }
            let length = (UInt16(prefix[prefix.startIndex]) << 8)
                | UInt16(prefix[prefix.index(after: prefix.startIndex)])
            guard length > 0 else { connection.cancel(); return }
            self.receiveExactly(Int(length), on: connection) { query in
                guard let query else { connection.cancel(); return }
                self.forward(query) { response in
                    guard let response else { connection.cancel(); return }
                    var framed = Data()
                    var count = UInt16(response.count).bigEndian
                    withUnsafeBytes(of: &count) { framed.append(contentsOf: $0) }
                    framed.append(response)
                    connection.send(content: framed, completion: .contentProcessed { _ in
                        self.receiveTCPFrame(on: connection)
                    })
                }
            }
        }
    }

    private func receiveExactly(
        _ count: Int,
        on connection: NWConnection,
        accumulated: Data = Data(),
        completion: @escaping @Sendable (Data?) -> Void
    ) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: count - accumulated.count
        ) { [weak self, weak connection] data, _, _, error in
            guard let self, let connection, error == nil else { completion(nil); return }
            var accumulated = accumulated
            if let data { accumulated.append(data) }
            if accumulated.count == count {
                completion(accumulated)
            } else if accumulated.count < count {
                self.receiveExactly(count, on: connection, accumulated: accumulated, completion: completion)
            } else {
                completion(nil)
            }
        }
    }

    private func forward(_ query: Data, completion: @escaping @Sendable (Data?) -> Void) {
        if let response = filter?.blockedResponse(for: query) {
            state.locked { blockedQueries &+= 1 }
            completion(response)
            return
        }
        forwardOverQUIC(query) { [weak self] response in
            guard let self else { completion(nil); return }
            if let response {
                completion(response)
            } else {
                self.forwardOverTLS(query, completion: completion)
            }
        }
    }

    private func forwardOverQUIC(
        _ query: Data,
        completion: @escaping @Sendable (Data?) -> Void
    ) {
        let quic = NWProtocolQUIC.Options()
        let tls = quic.securityProtocolOptions
        let tlsName = configuration.serverName.isEmpty
            ? configuration.resolverEndpoint
            : configuration.serverName
        tlsName.withCString { sec_protocol_options_set_tls_server_name(tls, $0) }
        "doq".withCString { sec_protocol_options_add_tls_application_protocol(tls, $0) }
        let parameters = NWParameters(quic: quic)
        let id = UUID()
        let connection = NWConnection(
            host: NWEndpoint.Host(configuration.resolverEndpoint),
            port: NWEndpoint.Port(rawValue: configuration.port)!,
            using: parameters
        )
        state.locked { upstreams[id] = connection }
        connection.stateUpdateHandler = { [weak self, weak connection] connectionState in
            guard let self, let connection else { return }
            switch connectionState {
            case .ready:
                connection.stateUpdateHandler = nil
                var framed = Data()
                var count = UInt16(query.count).bigEndian
                withUnsafeBytes(of: &count) { framed.append(contentsOf: $0) }
                framed.append(query)
                connection.send(content: framed, completion: .contentProcessed { error in
                    if error == nil {
                        self.receiveDoQResponse(on: connection) { response in
                            self.finish(
                                id: id,
                                connection: connection,
                                response: response,
                                completion: completion
                            )
                        }
                    } else {
                        self.finish(id: id, connection: connection, response: nil, completion: completion)
                    }
                })
            case .failed, .cancelled:
                self.finish(id: id, connection: connection, response: nil, completion: completion)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + .seconds(4)) { [weak self, weak connection] in
            guard let self, let connection else { return }
            let isPending = self.state.locked { self.upstreams[id] != nil }
            if isPending {
                self.finish(id: id, connection: connection, response: nil, completion: completion)
            }
        }
    }

    private func forwardOverTLS(
        _ query: Data,
        completion: @escaping @Sendable (Data?) -> Void
    ) {
        let tlsOptions = NWProtocolTLS.Options()
        let tlsName = configuration.serverName.isEmpty
            ? configuration.resolverEndpoint
            : configuration.serverName
        tlsName.withCString {
            sec_protocol_options_set_tls_server_name(tlsOptions.securityProtocolOptions, $0)
        }
        let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        let id = UUID()
        let connection = NWConnection(
            host: NWEndpoint.Host(configuration.resolverEndpoint),
            port: 853,
            using: parameters
        )
        state.locked { upstreams[id] = connection }
        connection.stateUpdateHandler = { [weak self, weak connection] connectionState in
            guard let self, let connection else { return }
            switch connectionState {
            case .ready:
                connection.stateUpdateHandler = nil
                var framed = Data()
                var count = UInt16(query.count).bigEndian
                withUnsafeBytes(of: &count) { framed.append(contentsOf: $0) }
                framed.append(query)
                connection.send(content: framed, completion: .contentProcessed { error in
                    guard error == nil else {
                        self.finish(id: id, connection: connection, response: nil, completion: completion)
                        return
                    }
                    self.receiveDoQResponse(on: connection) { response in
                        self.finish(
                            id: id,
                            connection: connection,
                            response: response,
                            completion: completion
                        )
                    }
                })
            case .failed, .cancelled:
                self.finish(id: id, connection: connection, response: nil, completion: completion)
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + .seconds(6)) { [weak self, weak connection] in
            guard let self, let connection else { return }
            let isPending = self.state.locked { self.upstreams[id] != nil }
            if isPending {
                self.finish(id: id, connection: connection, response: nil, completion: completion)
            }
        }
    }

    private func receiveDoQResponse(
        on connection: NWConnection,
        completion: @escaping @Sendable (Data?) -> Void
    ) {
        receiveExactly(2, on: connection) { [weak self, weak connection] prefix in
            guard let self, let connection, let prefix, prefix.count == 2 else {
                completion(nil)
                return
            }
            let length = (UInt16(prefix[prefix.startIndex]) << 8)
                | UInt16(prefix[prefix.index(after: prefix.startIndex)])
            guard length > 0 else { completion(nil); return }
            self.receiveExactly(Int(length), on: connection, completion: completion)
        }
    }

    private func finish(
        id: UUID,
        connection: NWConnection,
        response: Data?,
        completion: @escaping @Sendable (Data?) -> Void
    ) {
        let wasPending = state.locked { upstreams.removeValue(forKey: id) != nil }
        guard wasPending else { return }
        connection.cancel()
        completion(response)
    }

    deinit { stop() }
}

private enum TunnelDNSProxyError: LocalizedError {
    case listenerTimeout

    var errorDescription: String? { "The local DNS proxy did not become ready." }
}

private final class ListenerStartResult: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private var storedError: NWError?

    var error: NWError? { lock.locked { storedError } }

    func complete(error: NWError?) -> Bool {
        lock.locked {
            guard !completed else { return false }
            completed = true
            storedError = error
            return true
        }
    }
}

private extension NSLock {
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
