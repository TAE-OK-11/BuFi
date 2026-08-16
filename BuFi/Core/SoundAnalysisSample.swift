import Foundation

enum SoundAnalysisSample {
    static func resolve(
        for song: Song,
        client: OpenSubsonicClient?,
        paced: Bool = false
    ) async -> URL? {
        if let local = await OfflineStore.shared.localURL(for: song) {
            return await isolatedCopy(of: local, songID: song.id, paced: paced)
        }
        guard let client else { return nil }
        let stream = await analysisStream(for: song, client: client)
        guard let stream else { return nil }
        return await downloadPrefix(from: stream, songID: song.id, paced: paced)
    }

    /// Copy a short prefix so AVAudioFile seeking does not share the file
    /// AVPlayer may still be reading.
    private static func isolatedCopy(
        of url: URL,
        songID: String,
        paced: Bool
    ) async -> URL? {
        await Task.detached(priority: paced ? .background : .utility) {
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                return url
            }
            defer { try? handle.close() }
            let limit = paced ? 512_000 : 1_200_000
            var data = Data()
            data.reserveCapacity(limit)
            while data.count < limit {
                let chunkSize = paced ? 24_576 : 65_536
                guard let chunk = try? handle.read(upToCount: chunkSize),
                      !chunk.isEmpty else {
                    break
                }
                data.append(chunk)
                if paced, data.count < limit {
                    Thread.sleep(forTimeInterval: 0.003)
                }
            }
            guard data.count > 8_000 else { return url }
            return writeSample(data, songID: songID, ext: url.pathExtension)
        }.value
    }

    private static func analysisStream(
        for song: Song,
        client: OpenSubsonicClient
    ) async -> URL? {
        if let url = try? await client.streamURL(
            songID: song.id,
            quality: .opus160,
            compatibilityFormat: "mp3"
        ) {
            return url
        }
        return try? await client.streamURL(
            songID: song.id,
            quality: .automatic,
            compatibilityFormat: "mp3"
        )
    }

    private static func downloadPrefix(
        from url: URL,
        songID: String,
        paced: Bool
    ) async -> URL? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        let maxBytes = paced ? 512_000 : 800_000
        var request = URLRequest(url: url)
        request.setValue("bytes=0-\(maxBytes - 1)", forHTTPHeaderField: "Range")
        request.timeoutInterval = paced ? 18 : 12
        ModernNetworkPolicy.prepareAnalysisMediaRequest(&request)
        guard let (data, response) = try? await analysisSession.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              data.count > 8_000 else {
            return nil
        }
        return writeSample(data, songID: songID, ext: "m4a")
    }

    private static let analysisSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 18
        configuration.timeoutIntervalForResource = 24
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.waitsForConnectivity = false
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        configuration.httpShouldUsePipelining = false
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    private static func writeSample(_ data: Data, songID: String, ext: String) -> URL? {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("BuFiSound", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        let safe = String(
            songID.unicodeScalars
                .filter { CharacterSet.alphanumerics.contains($0) }
                .prefix(48)
        )
        let suffix = ext.isEmpty ? "m4a" : ext
        let file = folder.appendingPathComponent("\(safe).\(suffix)")
        do {
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }
}
