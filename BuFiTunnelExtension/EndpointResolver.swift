import Foundation
import Network

enum EndpointResolverError: LocalizedError {
    case resolutionFailed(String)

    var errorDescription: String? {
        switch self {
        case .resolutionFailed(let host): "Could not resolve WireGuard endpoint \(host)."
        }
    }
}

enum EndpointResolver {
    enum Strategy: Sendable, Equatable {
        /// Prefer IPv4 at initial startup, matching WireGuard Apple's behavior
        /// and avoiding an unnecessary DNS64 synthesis where native IPv4 works.
        case initial
        /// Preserve resolver ordering after a path change so an IPv6-only path
        /// can return its DNS64-synthesized address first.
        case networkChange
    }

    static func resolve(
        host: String,
        port: UInt16,
        strategy: Strategy = .initial
    ) throws -> String {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if IPv4Address(host) != nil || IPv6Address(host) != nil { return host }

        var hints = addrinfo(
            ai_flags: strategy == .initial ? AI_ALL : 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_DGRAM,
            ai_protocol: IPPROTO_UDP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &result) == 0, let first = result else {
            throw EndpointResolverError.resolutionFailed(host)
        }
        defer { freeaddrinfo(result) }
        var resolved: [(family: Int32, address: String)] = []
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let info = current?.pointee {
            var output = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                info.ai_addr,
                info.ai_addrlen,
                &output,
                socklen_t(output.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 {
                let bytes = output.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                resolved.append((info.ai_family, String(decoding: bytes, as: UTF8.self)))
            }
            current = info.ai_next
        }
        if strategy == .initial,
           let ipv4 = resolved.first(where: { $0.family == AF_INET }) {
            return ipv4.address
        }
        if let first = resolved.first { return first.address }
        throw EndpointResolverError.resolutionFailed(host)
    }
}
