import CryptoKit
import Foundation

actor OfflineStore {
    static let shared = OfflineStore()

    private struct Entry: Codable, Sendable {
        var song: Song
        var fileName: String
        var byteCount: Int64
        var downloadedAt: Date
        var lastAccessedAt: Date
    }

    private struct DownloadResult: Sendable {
        let url: URL
        let byteCount: Int64
    }

    private let directory: URL
    private let indexURL: URL
    private var entries: [String: Entry]
    private var inFlight: [String: Task<DownloadResult, Error>] = [:]

    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = root.appendingPathComponent("OfflineMusic", isDirectory: true)
        indexURL = directory.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded.filter { _, entry in
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(entry.fileName).path
                )
            }
        } else {
            entries = [:]
        }
    }

    func localURL(for songID: String) -> URL? {
        if var entry = entries[songID] {
            let url = directory.appendingPathComponent(entry.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else {
                entries[songID] = nil
                try? persistIndex()
                return nil
            }
            if Date().timeIntervalSince(entry.lastAccessedAt) > 3_600 {
                entry.lastAccessedAt = Date()
                entries[songID] = entry
                try? persistIndex()
            }
            return url
        }

        let legacy = legacyFileURL(songID: songID)
        return FileManager.default.fileExists(atPath: legacy.path) ? legacy : nil
    }

    func isDownloaded(songID: String) -> Bool {
        localURL(for: songID) != nil
    }

    func downloadedSongs() -> [Song] {
        entries.values
            .sorted { $0.downloadedAt > $1.downloadedAt }
            .map(\.song)
    }

    func download(song: Song, client: OpenSubsonicClient) async throws -> URL {
        if let existing = localURL(for: song.id) { return existing }
        if let existingTask = inFlight[song.id] { return try await existingTask.value.url }

        let remote = try await client.downloadURL(songID: song.id)
        let fileName = Self.fileName(for: song)
        let destination = directory.appendingPathComponent(fileName)
        let wifiOnly = UserDefaults.standard.object(forKey: "offline-wifi-only") as? Bool ?? true

        let task = Task<DownloadResult, Error>(priority: .utility) {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60 * 60
            configuration.waitsForConnectivity = true
            configuration.httpMaximumConnectionsPerHost = 2
            configuration.allowsExpensiveNetworkAccess = !wifiOnly
            configuration.allowsConstrainedNetworkAccess = !wifiOnly
            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }

            let (temporary, response) = try await session.download(from: remote)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let values = try temporary.resourceValues(forKeys: [.fileSizeKey])
            let bytes = Int64(values.fileSize ?? 0)
            guard bytes > 0 else { throw URLError(.zeroByteResource) }

            let staging = destination.appendingPathExtension("partial")
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: staging)
            try FileManager.default.moveItem(at: staging, to: destination)
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path
            )
            return DownloadResult(url: destination, byteCount: bytes)
        }
        inFlight[song.id] = task

        do {
            let result = try await task.value
            inFlight[song.id] = nil
            let now = Date()
            entries[song.id] = Entry(
                song: song,
                fileName: fileName,
                byteCount: result.byteCount,
                downloadedAt: now,
                lastAccessedAt: now
            )
            try persistIndex()
            try enforceStorageLimit(keeping: song.id)
            return result.url
        } catch {
            inFlight[song.id] = nil
            try? FileManager.default.removeItem(at: destination.appendingPathExtension("partial"))
            throw error
        }
    }

    func remove(songID: String) throws {
        if let entry = entries.removeValue(forKey: songID) {
            let url = directory.appendingPathComponent(entry.fileName)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        let legacy = legacyFileURL(songID: songID)
        if FileManager.default.fileExists(atPath: legacy.path) {
            try FileManager.default.removeItem(at: legacy)
        }
        try persistIndex()
    }

    func removeAll() throws {
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll()
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for file in files { try FileManager.default.removeItem(at: file) }
        entries.removeAll()
        try persistIndex()
    }

    func totalBytes() -> Int64 {
        let indexed = entries.values.reduce(into: Int64(0)) { $0 += $1.byteCount }
        if indexed > 0 { return indexed }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        return files.reduce(into: Int64(0)) { total, url in
            guard url != indexURL else { return }
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    private func enforceStorageLimit(keeping protectedID: String) throws {
        let configured = UserDefaults.standard.object(forKey: "offline-storage-limit-gb") as? Double ?? 10
        guard configured > 0 else { return }
        let limit = Int64(configured * 1_024 * 1_024 * 1_024)
        var total = entries.values.reduce(into: Int64(0)) { $0 += $1.byteCount }
        guard total > limit else { return }

        let candidates = entries
            .filter { $0.key != protectedID }
            .sorted { $0.value.lastAccessedAt < $1.value.lastAccessedAt }
        for (id, entry) in candidates where total > limit {
            let url = directory.appendingPathComponent(entry.fileName)
            try? FileManager.default.removeItem(at: url)
            entries[id] = nil
            total -= entry.byteCount
        }
        try persistIndex()
    }

    private func persistIndex() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(entries)
        try data.write(to: indexURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func legacyFileURL(songID: String) -> URL {
        directory.appendingPathComponent(Self.digest(songID)).appendingPathExtension("audio")
    }

    private static func fileName(for song: Song) -> String {
        let rawExtension = song.suffix?
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            .lowercased()
        let ext = (rawExtension?.isEmpty == false ? rawExtension : nil) ?? "audio"
        return digest(song.id) + "." + ext
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
