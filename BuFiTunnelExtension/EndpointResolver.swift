import Foundation

enum EndpointResolverError: LocalizedError {
    case resolutionFailed(String)

    var errorDescription: String? {
        switch self {
        case .resolutionFailed(let host): "Could not resolve WireGuard endpoint \(host)."
        }
    }
}

enum EndpointResolver {
    static func resolve(host: String, port: UInt16) throws -> String {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
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
                return String(decoding: bytes, as: UTF8.self)
            }
            current = info.ai_next
        }
        throw EndpointResolverError.resolutionFailed(host)
    }
}
