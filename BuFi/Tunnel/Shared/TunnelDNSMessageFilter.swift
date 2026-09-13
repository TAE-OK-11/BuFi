import Foundation

/// DNS transport framing kept independent from the resolver implementation so
/// protocol details can be regression-tested without starting NetworkExtension.
/// RFC 9250 gives each DoQ stream exactly one raw DNS message, while RFC 7858
/// retains DNS-over-TCP's two-octet length prefix for DoT.
enum TunnelDNSTransportCodec {
    static let maximumMessageLength = Int(UInt16.max)

    static func doQPayload(_ message: Data) -> Data? {
        guard !message.isEmpty, message.count <= maximumMessageLength else { return nil }
        return message
    }

    static func tcpFrame(_ message: Data) -> Data? {
        guard !message.isEmpty, message.count <= maximumMessageLength else { return nil }
        var frame = Data(capacity: message.count + 2)
        var length = UInt16(message.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(message)
        return frame
    }

    static func tcpPayloadLength(_ prefix: Data) -> Int? {
        guard prefix.count == 2 else { return nil }
        let start = prefix.startIndex
        let next = prefix.index(after: start)
        let length = (UInt16(prefix[start]) << 8) | UInt16(prefix[next])
        return length > 0 ? Int(length) : nil
    }
}

/// Rust owns DNS question parsing, custom-rule tries, and subscription suffix
/// matching. The immutable subscription remains memory-mapped by Foundation;
/// each synchronous call lends those bytes to Rust without making a large copy.
struct TunnelDNSMessageFilter: Sendable {
    private let engine: RustDNSFilterHandle?

    init(
        blockedDomains: [String],
        allowedDomains: [String],
        subscriptionData: Data? = nil
    ) {
        engine = RustDNSFilterHandle(
            blockedDomains: blockedDomains,
            allowedDomains: allowedDomains,
            subscriptionData: subscriptionData
        )
    }

    func blockedResponse(for query: Data) -> Data? {
        guard let messageEnd = engine?.blockedMessageEnd(for: query),
              messageEnd >= 12,
              messageEnd <= query.count else { return nil }
        var response = Data(query.prefix(messageEnd))
        let queryFlags = (UInt16(response[2]) << 8) | UInt16(response[3])
        let flags = (queryFlags & 0x7900) | 0x8083
        response[2] = UInt8(flags >> 8)
        response[3] = UInt8(flags & 0xff)
        for offset in 6...11 { response[offset] = 0 }
        return response
    }
}
