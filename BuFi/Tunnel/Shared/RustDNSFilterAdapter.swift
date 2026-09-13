import Foundation

@_silgen_name("bufi_dns_parse_rules")
private func rustDNSParseRules(
    _ bytes: UnsafePointer<UInt8>?,
    _ count: Int,
    _ defaultAction: UInt8,
    _ maximumRules: Int
) -> OpaquePointer?
@_silgen_name("bufi_dns_parsed_blocked")
private func rustDNSParsedBlocked(
    _ handle: OpaquePointer?,
    _ count: UnsafeMutablePointer<Int>
) -> UnsafePointer<UInt8>?
@_silgen_name("bufi_dns_parsed_allowed")
private func rustDNSParsedAllowed(
    _ handle: OpaquePointer?,
    _ count: UnsafeMutablePointer<Int>
) -> UnsafePointer<UInt8>?
@_silgen_name("bufi_dns_parsed_ignored")
private func rustDNSParsedIgnored(_ handle: OpaquePointer?) -> Int
@_silgen_name("bufi_dns_parsed_reached_limit")
private func rustDNSParsedReachedLimit(_ handle: OpaquePointer?) -> UInt8
@_silgen_name("bufi_dns_parsed_free")
private func rustDNSParsedFree(_ handle: OpaquePointer?)

@_silgen_name("bufi_dns_compiler_create")
private func rustDNSCompilerCreate(_ maximumRules: Int) -> OpaquePointer?
@_silgen_name("bufi_dns_compiler_add")
private func rustDNSCompilerAdd(
    _ handle: OpaquePointer?,
    _ bytes: UnsafePointer<UInt8>?,
    _ count: Int,
    _ usableRuleCount: UnsafeMutablePointer<Int>
) -> Int32
@_silgen_name("bufi_dns_compiler_finish")
private func rustDNSCompilerFinish(
    _ handle: OpaquePointer?,
    _ outputCount: UnsafeMutablePointer<Int>,
    _ outputRuleCount: UnsafeMutablePointer<Int>
) -> UnsafePointer<UInt8>?
@_silgen_name("bufi_dns_compiler_free")
private func rustDNSCompilerFree(_ handle: OpaquePointer?)

@_silgen_name("bufi_dns_filter_create")
private func rustDNSFilterCreate(
    _ blockedBytes: UnsafePointer<UInt8>?,
    _ blockedCount: Int,
    _ allowedBytes: UnsafePointer<UInt8>?,
    _ allowedCount: Int,
    _ subscriptionBytes: UnsafePointer<UInt8>?,
    _ subscriptionCount: Int
) -> OpaquePointer?
@_silgen_name("bufi_dns_filter_blocked_message_end")
private func rustDNSFilterBlockedMessageEnd(
    _ handle: OpaquePointer?,
    _ queryBytes: UnsafePointer<UInt8>?,
    _ queryCount: Int,
    _ subscriptionBytes: UnsafePointer<UInt8>?,
    _ subscriptionCount: Int
) -> Int
@_silgen_name("bufi_dns_filter_free")
private func rustDNSFilterFree(_ handle: OpaquePointer?)

enum RustDNSRuleEngine {
    static func parse(
        _ text: String,
        defaultAction: TunnelDNSRuleParser.DefaultAction,
        maximumRules: Int
    ) -> TunnelDNSRuleParser.Result? {
        parse(
            Data(text.utf8),
            defaultAction: defaultAction,
            maximumRules: maximumRules
        )
    }

    static func parse(
        _ data: Data,
        defaultAction: TunnelDNSRuleParser.DefaultAction,
        maximumRules: Int
    ) -> TunnelDNSRuleParser.Result? {
        let action: UInt8 = switch defaultAction {
        case .block: 0
        case .allow: 1
        }
        let handle = data.withUnsafeBytes { rawBuffer -> OpaquePointer? in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return rustDNSParseRules(
                bytes.baseAddress,
                bytes.count,
                action,
                max(0, maximumRules)
            )
        }
        guard let handle else { return nil }
        defer { rustDNSParsedFree(handle) }

        var blockedCount = 0
        let blockedPointer = rustDNSParsedBlocked(handle, &blockedCount)
        var allowedCount = 0
        let allowedPointer = rustDNSParsedAllowed(handle, &allowedCount)
        return TunnelDNSRuleParser.Result(
            blockedDomains: domains(bytes: blockedPointer, count: blockedCount),
            allowedDomains: domains(bytes: allowedPointer, count: allowedCount),
            ignoredRuleCount: rustDNSParsedIgnored(handle),
            reachedLimit: rustDNSParsedReachedLimit(handle) != 0
        )
    }

    private static func domains(
        bytes: UnsafePointer<UInt8>?,
        count: Int
    ) -> [String] {
        guard let bytes, count > 0 else { return [] }
        return Data(bytes: bytes, count: count)
            .split(separator: 0x0a, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) }
    }
}

enum RustDNSBlocklistAddResult: Sendable {
    case accepted(usableRuleCount: Int)
    case invalidUTF8
    case reachedLimit
    case failed
}

/// Actor-confined incremental compiler. Rust owns all normalized strings and
/// set operations, and Swift receives only the final sorted snapshot.
final class RustDNSBlocklistCompiler {
    private let handle: OpaquePointer

    init?(maximumRules: Int) {
        guard maximumRules >= 0,
              let handle = rustDNSCompilerCreate(maximumRules) else { return nil }
        self.handle = handle
    }

    func add(_ data: Data) -> RustDNSBlocklistAddResult {
        var usableRuleCount = 0
        let status = data.withUnsafeBytes { rawBuffer -> Int32 in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return rustDNSCompilerAdd(
                handle,
                bytes.baseAddress,
                bytes.count,
                &usableRuleCount
            )
        }
        switch status {
        case 0: return .accepted(usableRuleCount: usableRuleCount)
        case 1: return .invalidUTF8
        case 2: return .reachedLimit
        default: return .failed
        }
    }

    func finish() -> (snapshot: Data, ruleCount: Int)? {
        var outputCount = 0
        var ruleCount = 0
        let bytes = rustDNSCompilerFinish(handle, &outputCount, &ruleCount)
        if outputCount == 0 {
            return (Data(), ruleCount)
        }
        guard let bytes else { return nil }
        return (Data(bytes: bytes, count: outputCount), ruleCount)
    }

    deinit {
        rustDNSCompilerFree(handle)
    }
}

/// Immutable Rust matcher handle. The subscription bytes remain owned by the
/// mapped Swift Data value and are borrowed only for each synchronous FFI call;
/// Rust retains just the compact line index and custom-rule tries.
final class RustDNSFilterHandle: @unchecked Sendable {
    private let handle: OpaquePointer
    private let subscriptionData: Data

    init?(
        blockedDomains: [String],
        allowedDomains: [String],
        subscriptionData: Data?
    ) {
        let blockedData = Self.ruleData(blockedDomains)
        let allowedData = Self.ruleData(allowedDomains)
        let subscriptionData = subscriptionData ?? Data()
        let created = blockedData.withUnsafeBytes { blockedBuffer -> OpaquePointer? in
            let blockedBytes = blockedBuffer.bindMemory(to: UInt8.self)
            return allowedData.withUnsafeBytes { allowedBuffer -> OpaquePointer? in
                let allowedBytes = allowedBuffer.bindMemory(to: UInt8.self)
                return subscriptionData.withUnsafeBytes { subscriptionBuffer -> OpaquePointer? in
                    let subscriptionBytes = subscriptionBuffer.bindMemory(to: UInt8.self)
                    return rustDNSFilterCreate(
                        blockedBytes.baseAddress,
                        blockedBytes.count,
                        allowedBytes.baseAddress,
                        allowedBytes.count,
                        subscriptionBytes.baseAddress,
                        subscriptionBytes.count
                    )
                }
            }
        }
        guard let created else { return nil }
        handle = created
        self.subscriptionData = subscriptionData
    }

    func blockedMessageEnd(for query: Data) -> Int? {
        let messageEnd = query.withUnsafeBytes { queryBuffer -> Int in
            let queryBytes = queryBuffer.bindMemory(to: UInt8.self)
            return subscriptionData.withUnsafeBytes { subscriptionBuffer -> Int in
                let subscriptionBytes = subscriptionBuffer.bindMemory(to: UInt8.self)
                return rustDNSFilterBlockedMessageEnd(
                    handle,
                    queryBytes.baseAddress,
                    queryBytes.count,
                    subscriptionBytes.baseAddress,
                    subscriptionBytes.count
                )
            }
        }
        return messageEnd > 0 ? messageEnd : nil
    }

    private static func ruleData(_ domains: [String]) -> Data {
        guard !domains.isEmpty else { return Data() }
        return Data((domains.joined(separator: "\n") + "\n").utf8)
    }

    deinit {
        rustDNSFilterFree(handle)
    }
}
