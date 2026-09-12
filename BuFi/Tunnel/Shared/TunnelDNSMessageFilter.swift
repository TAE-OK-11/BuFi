import Foundation

/// Small exact/suffix DNS matcher used only for user-owned rules. The large
/// maintained threat and advertising lists remain at the selected upstream.
struct TunnelDNSMessageFilter: Sendable {
    private let blockedDomains: Set<String>
    private let allowedDomains: Set<String>

    init(blockedDomains: [String], allowedDomains: [String]) {
        self.blockedDomains = Set(blockedDomains.compactMap(TunnelDNSRuleParser.normalize))
        self.allowedDomains = Set(allowedDomains.compactMap(TunnelDNSRuleParser.normalize))
    }

    func blockedResponse(for query: Data) -> Data? {
        guard let question = TunnelDNSQuestion.parse(query),
              !matches(question.domain, in: allowedDomains),
              matches(question.domain, in: blockedDomains) else { return nil }
        return question.nxdomainResponse(query)
    }

    private func matches(_ domain: String, in rules: Set<String>) -> Bool {
        var candidate = domain
        while true {
            if rules.contains(candidate) { return true }
            guard let dot = candidate.firstIndex(of: ".") else { return false }
            candidate = String(candidate[candidate.index(after: dot)...])
        }
    }
}

private struct TunnelDNSQuestion: Sendable {
    let domain: String
    let messageEnd: Int

    static func parse(_ data: Data) -> TunnelDNSQuestion? {
        guard data.count >= 17,
              readUInt16(data, at: 4) == 1,
              let name = readName(data, at: 12, depth: 0),
              name.nextOffset + 4 <= data.count,
              !name.labels.isEmpty else { return nil }
        return TunnelDNSQuestion(
            domain: name.labels.joined(separator: ".").lowercased(),
            messageEnd: name.nextOffset + 4
        )
    }

    func nxdomainResponse(_ query: Data) -> Data {
        var response = Data(query.prefix(messageEnd))
        let queryFlags = Self.readUInt16(response, at: 2)
        let flags = (queryFlags & 0x7900) | 0x8083 // response + recursion available + NXDOMAIN
        response[2] = UInt8(flags >> 8)
        response[3] = UInt8(flags & 0xff)
        for offset in 6...11 { response[offset] = 0 }
        return response
    }

    private static func readName(
        _ data: Data,
        at start: Int,
        depth: Int
    ) -> (labels: [String], nextOffset: Int)? {
        guard depth < 8 else { return nil }
        var labels: [String] = []
        var offset = start
        while offset < data.count {
            let length = Int(data[offset])
            if length == 0 { return (labels, offset + 1) }
            if length & 0xc0 == 0xc0 {
                guard offset + 1 < data.count else { return nil }
                let pointer = ((length & 0x3f) << 8) | Int(data[offset + 1])
                guard pointer < data.count,
                      let pointed = readName(data, at: pointer, depth: depth + 1) else { return nil }
                labels.append(contentsOf: pointed.labels)
                return (labels, offset + 2)
            }
            guard length <= 63, offset + 1 + length <= data.count,
                  let label = String(
                    data: data[(offset + 1)..<(offset + 1 + length)],
                    encoding: .utf8
                  ) else { return nil }
            labels.append(label)
            offset += length + 1
        }
        return nil
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }
}
