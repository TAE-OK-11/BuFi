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

/// Small exact/suffix DNS matcher used only for user-owned rules. The large
/// maintained threat and advertising lists remain at the selected upstream.
///
/// Rules are compiled once into a compact label trie. A query then walks its
/// labels from the TLD inward without allocating a new String for every parent
/// suffix (for example, `a.b.example.com`, `b.example.com`, and so on).
struct TunnelDNSMessageFilter: Sendable {
    private let blockedDomains: TunnelDomainSuffixMatcher
    private let allowedDomains: TunnelDomainSuffixMatcher

    init(blockedDomains: [String], allowedDomains: [String]) {
        self.blockedDomains = TunnelDomainSuffixMatcher(rules: blockedDomains)
        self.allowedDomains = TunnelDomainSuffixMatcher(rules: allowedDomains)
    }

    func blockedResponse(for query: Data) -> Data? {
        guard let question = TunnelDNSQuestion.parse(query),
              !allowedDomains.matches(labels: question.labels),
              blockedDomains.matches(labels: question.labels) else { return nil }
        return question.nxdomainResponse(query)
    }
}

private struct TunnelDomainSuffixMatcher: Sendable {
    private struct BuildNode {
        var terminal = false
        var children: [String: Int] = [:]
    }

    private struct Node: Sendable {
        let terminal: Bool
        let edgeStart: Int
        let edgeCount: Int
    }

    private struct Edge: Sendable {
        let label: String
        let child: Int
    }

    private let nodes: [Node]
    private let edges: [Edge]

    init(rules: [String]) {
        var buildNodes = [BuildNode()]
        for rawRule in rules {
            guard let rule = TunnelDNSRuleParser.normalize(rawRule) else { continue }
            var nodeIndex = 0
            for label in rule.split(separator: ".").reversed() {
                let label = String(label)
                if let child = buildNodes[nodeIndex].children[label] {
                    nodeIndex = child
                } else {
                    let child = buildNodes.count
                    buildNodes.append(BuildNode())
                    buildNodes[nodeIndex].children[label] = child
                    nodeIndex = child
                }
            }
            buildNodes[nodeIndex].terminal = true
        }

        var compactNodes: [Node] = []
        var compactEdges: [Edge] = []
        compactNodes.reserveCapacity(buildNodes.count)
        compactEdges.reserveCapacity(max(0, buildNodes.count - 1))
        for node in buildNodes {
            let sortedChildren = node.children.sorted { $0.key < $1.key }
            compactNodes.append(Node(
                terminal: node.terminal,
                edgeStart: compactEdges.count,
                edgeCount: sortedChildren.count
            ))
            for child in sortedChildren {
                compactEdges.append(Edge(label: child.key, child: child.value))
            }
        }
        self.nodes = compactNodes
        self.edges = compactEdges
    }

    func matches(labels: [String]) -> Bool {
        var nodeIndex = 0
        for label in labels.reversed() {
            guard let child = child(of: nodeIndex, matching: label) else { return false }
            nodeIndex = child
            if nodes[nodeIndex].terminal { return true }
        }
        return false
    }

    private func child(of nodeIndex: Int, matching label: String) -> Int? {
        let node = nodes[nodeIndex]
        var lower = node.edgeStart
        var upper = node.edgeStart + node.edgeCount
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if edges[middle].label < label {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower < node.edgeStart + node.edgeCount,
              edges[lower].label == label else { return nil }
        return edges[lower].child
    }
}

private struct TunnelDNSQuestion: Sendable {
    let labels: [String]
    let messageEnd: Int

    static func parse(_ data: Data) -> TunnelDNSQuestion? {
        guard data.count >= 17,
              readUInt16(data, at: 4) == 1,
              let name = readName(data, at: 12, depth: 0),
              name.nextOffset + 4 <= data.count,
              !name.labels.isEmpty else { return nil }
        return TunnelDNSQuestion(
            labels: name.labels,
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
            labels.append(label.lowercased())
            offset += length + 1
        }
        return nil
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }
}
