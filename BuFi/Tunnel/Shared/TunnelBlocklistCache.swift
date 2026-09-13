import Foundation

struct TunnelBlocklistUpdateMetadata: Codable, Equatable, Sendable {
    var updatedAt: Date
    var ruleCount: Int
    var sourceCount: Int
}

enum TunnelBlocklistCacheError: LocalizedError, Sendable {
    case appGroupUnavailable
    case invalidSnapshot

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            String(localized: "The shared Tunnel blocklist container is unavailable.")
        case .invalidSnapshot:
            String(localized: "The downloaded blocklist snapshot is invalid.")
        }
    }
}

/// The containing app is the only writer. Packet Tunnel opens the immutable,
/// sorted snapshot with mapped I/O, so a large subscription does not become a
/// graph of Swift strings in the extension's tight memory budget.
enum TunnelBlocklistCache {
    private static let directoryName = "TunnelBlocklists-v1"

    static func save(
        domains: [String],
        profileID: UUID,
        sourceCount: Int
    ) throws -> TunnelBlocklistUpdateMetadata {
        let directory = try directoryURL()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
            ]
        )
        let body = domains.joined(separator: "\n") + (domains.isEmpty ? "" : "\n")
        try Data(body.utf8).write(to: dataURL(profileID, directory: directory), options: .atomic)
        let metadata = TunnelBlocklistUpdateMetadata(
            updatedAt: Date(),
            ruleCount: domains.count,
            sourceCount: sourceCount
        )
        try JSONEncoder().encode(metadata).write(
            to: metadataURL(profileID, directory: directory),
            options: .atomic
        )
        return metadata
    }

    static func snapshot(profileID: UUID) throws -> Data? {
        let url = dataURL(profileID, directory: try directoryURL())
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.isEmpty || data.last == 0x0a else { throw TunnelBlocklistCacheError.invalidSnapshot }
        return data
    }

    static func metadata(profileID: UUID) throws -> TunnelBlocklistUpdateMetadata? {
        let url = metadataURL(profileID, directory: try directoryURL())
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(
            TunnelBlocklistUpdateMetadata.self,
            from: Data(contentsOf: url)
        )
    }

    static func remove(profileID: UUID) throws {
        let directory = try directoryURL()
        for url in [dataURL(profileID, directory: directory), metadataURL(profileID, directory: directory)]
            where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func directoryURL() throws -> URL {
        guard let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: TunnelConstants.appGroup
        ) else { throw TunnelBlocklistCacheError.appGroupUnavailable }
        return root.appendingPathComponent(directoryName, isDirectory: true)
    }

    private static func dataURL(_ id: UUID, directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).domains", isDirectory: false)
    }

    private static func metadataURL(_ id: UUID, directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }
}
