import Foundation

enum SoundAnalysisSample {
    static func resolve(for song: Song, client: OpenSubsonicClient?) async -> URL? {
        if let local = await OfflineStore.shared.localURL(for: song) {
            return local
        }
        guard let client else { return nil }
        let stream = await transcodedStream(for: song, client: client)
        guard let stream else { return nil }
        if let file = await client.writeStreamSample(from: stream, songID: song.id) {
            return file
        }
        return await downloadPrefix(from: stream, songID: song.id)
    }

    private static func transcodedStream(
        for song: Song,
        client: OpenSubsonicClient
    ) async -> URL? {
        if let url = try? await client.streamURL(
            songID: song.id,
            quality: .aac320,
            compatibilityFormat: "aac"
        ) {
            return url
        }
        return try? await client.streamURL(
            songID: song.id,
            quality: .automatic,
            compatibilityFormat: "mp3"
        )
    }

    private static func downloadPrefix(from url: URL, songID: String) async -> URL? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        var request = URLRequest(url: url)
        request.setValue("bytes=0-1600000", forHTTPHeaderField: "Range")
        request.timeoutInterval = 20
        ModernNetworkPolicy.prepareMediaRequest(&request)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              data.count > 8_000 else {
            return nil
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("BuFiSound", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        let file = folder.appendingPathComponent("\(songID).m4a")
        do {
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }
}
