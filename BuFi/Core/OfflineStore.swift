import CryptoKit
import Foundation

actor OfflineStore {
    static let shared = OfflineStore()

    private let directory: URL

    init() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = root.appendingPathComponent("OfflineMusic", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
    }

    func localURL(for songID: String) -> URL? {
        let url = fileURL(songID: songID)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func download(song: Song, client: OpenSubsonicClient) async throws -> URL {
        if let existing = localURL(for: song.id) { return existing }
        let remote = try await client.downloadURL(songID: song.id)
        let (temporary, response) = try await URLSession.shared.download(from: remote)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }

        let destination = fileURL(songID: song.id)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: destination.path
        )
        return destination
    }

    func remove(songID: String) throws {
        let url = fileURL(songID: songID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func removeAll() throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for file in files {
            try FileManager.default.removeItem(at: file)
        }
    }

    func totalBytes() -> Int64 {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        return files.reduce(into: Int64(0)) { total, url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
    }

    private func fileURL(songID: String) -> URL {
        let digest = SHA256.hash(data: Data(songID.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appendingPathComponent(digest).appendingPathExtension("audio")
    }
}
