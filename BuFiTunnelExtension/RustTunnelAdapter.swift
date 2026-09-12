import Foundation
import os

@_silgen_name("bufi_tunnel_find_utun_fd")
private func rustFindTunnelFileDescriptor() -> Int32
@_silgen_name("bufi_tunnel_start")
private func rustStartTunnel(_ fd: Int32, _ bytes: UnsafePointer<UInt8>, _ count: Int) -> OpaquePointer?
@_silgen_name("bufi_tunnel_stop")
private func rustStopTunnel(_ handle: OpaquePointer?)
@_silgen_name("bufi_tunnel_suspend")
private func rustSuspendTunnel(_ handle: OpaquePointer?) -> Int32
@_silgen_name("bufi_tunnel_resume")
private func rustResumeTunnel(_ handle: OpaquePointer?) -> Int32
@_silgen_name("bufi_tunnel_rebind")
private func rustRebindTunnel(_ handle: OpaquePointer?) -> Int32
@_silgen_name("bufi_tunnel_statistics")
private func rustTunnelStatistics(_ handle: OpaquePointer?) -> UnsafeMutablePointer<CChar>?
@_silgen_name("bufi_tunnel_last_error")
private func rustLastError() -> UnsafeMutablePointer<CChar>?
@_silgen_name("bufi_tunnel_string_free")
private func rustStringFree(_ value: UnsafeMutablePointer<CChar>?)

struct RustPeerConfiguration: Codable, Sendable {
    let publicKey: String
    let presharedKey: String?
    let endpointIP: String
    let endpointPort: UInt16
    let allowedIPs: [String]
    let persistentKeepalive: UInt16?
}

struct RustEngineConfiguration: Codable, Sendable {
    let privateKey: String
    let mtu: UInt16
    let peers: [RustPeerConfiguration]
}

struct RustEngineStatistics: Codable, Sendable {
    let latestHandshake: UInt64?
    let txBytes: UInt64
    let rxBytes: UInt64
    let currentEndpoint: String?
}

enum RustTunnelError: LocalizedError, Sendable {
    case cannotLocateTunnel
    case engine(String)

    var errorDescription: String? {
        switch self {
        case .cannotLocateTunnel: "The NetworkExtension utun descriptor was not found."
        case .engine(let message): message
        }
    }
}

final class RustTunnelAdapter: @unchecked Sendable {
    /// Swift 6.4 intentionally makes raw pointers non-Sendable. The lock stores
    /// only the pointer's integer bit pattern and recreates the opaque pointer
    /// while holding the lock for every FFI call.
    private let handle = OSAllocatedUnfairLock<UInt>(initialState: 0)

    func start(configuration: RustEngineConfiguration) throws {
        let fd = rustFindTunnelFileDescriptor()
        guard fd >= 0 else { throw RustTunnelError.cannotLocateTunnel }
        let data = try JSONEncoder().encode(configuration)
        let started = data.withUnsafeBytes { rawBuffer -> OpaquePointer? in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return nil }
            return rustStartTunnel(fd, bytes, data.count)
        }
        guard let started else { throw RustTunnelError.engine(Self.takeLastError()) }
        let previous = handle.withLock { value -> UInt in
            let previous = value
            value = UInt(bitPattern: started)
            return previous
        }
        if previous != 0 { rustStopTunnel(OpaquePointer(bitPattern: previous)) }
    }

    func stop() {
        let stopped = handle.withLock { value -> UInt in
            let stopped = value
            value = 0
            return stopped
        }
        if stopped != 0 { rustStopTunnel(OpaquePointer(bitPattern: stopped)) }
    }

    func suspend() throws {
        try lifecycle(rustSuspendTunnel)
    }

    func resume() throws {
        try lifecycle(rustResumeTunnel)
    }

    func rebind() throws {
        try lifecycle(rustRebindTunnel)
    }

    func statistics() throws -> RustEngineStatistics {
        try handle.withLock { value in
            guard value != 0, let pointer = OpaquePointer(bitPattern: value) else {
                throw RustTunnelError.engine("GotaTun is not running.")
            }
            guard let string = rustTunnelStatistics(pointer) else {
                throw RustTunnelError.engine(Self.takeLastError())
            }
            defer { rustStringFree(string) }
            guard let data = String(cString: string).data(using: .utf8) else {
                throw RustTunnelError.engine("GotaTun returned invalid statistics.")
            }
            return try JSONDecoder().decode(RustEngineStatistics.self, from: data)
        }
    }

    private func lifecycle(_ operation: (OpaquePointer?) -> Int32) throws {
        try handle.withLock { value in
            guard value != 0, let pointer = OpaquePointer(bitPattern: value) else {
                throw RustTunnelError.engine("GotaTun is not running.")
            }
            guard operation(pointer) == 0 else { throw RustTunnelError.engine(Self.takeLastError()) }
        }
    }

    private static func takeLastError() -> String {
        guard let error = rustLastError() else { return "Unknown GotaTun error." }
        defer { rustStringFree(error) }
        return String(cString: error)
    }

    deinit { stop() }
}
