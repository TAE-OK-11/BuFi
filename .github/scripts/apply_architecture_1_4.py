from pathlib import Path


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    if old not in text:
        raise SystemExit(f"pattern missing in {path}: {old[:120]!r}")
    path.write_text(text.replace(old, new, 1))


# MARK: Project dependencies and release metadata
project = Path("project.yml")
text = project.read_text()
if "SwiftSonic:" not in text:
    text = text.replace(
        "packages:\n",
        "packages:\n"
        "  SwiftSonic:\n"
        "    url: https://github.com/CassetteLab/swiftsonic.git\n"
        "    from: 0.8.3\n"
        "  Nuke:\n"
        "    url: https://github.com/kean/Nuke.git\n"
        "    from: 13.0.0\n",
        1,
    )
if "product: SwiftSonic" not in text:
    text = text.replace(
        "    dependencies:\n",
        "    dependencies:\n"
        "      - package: SwiftSonic\n"
        "        product: SwiftSonic\n"
        "      - package: Nuke\n"
        "        product: Nuke\n"
        "      - package: Nuke\n"
        "        product: NukeUI\n",
        1,
    )
for old, new in [
    ('CFBundleShortVersionString: "1.3.0"', 'CFBundleShortVersionString: "1.4.0"'),
    ('CFBundleShortVersionString: "1.3.1"', 'CFBundleShortVersionString: "1.4.0"'),
    ('CFBundleVersion: "13"', 'CFBundleVersion: "15"'),
    ('CFBundleVersion: "14"', 'CFBundleVersion: "15"'),
    ('MARKETING_VERSION: "1.3.0"', 'MARKETING_VERSION: "1.4.0"'),
    ('MARKETING_VERSION: "1.3.1"', 'MARKETING_VERSION: "1.4.0"'),
    ('CURRENT_PROJECT_VERSION: "13"', 'CURRENT_PROJECT_VERSION: "15"'),
    ('CURRENT_PROJECT_VERSION: "14"', 'CURRENT_PROJECT_VERSION: "15"'),
]:
    text = text.replace(old, new)
project.write_text(text)


# MARK: SwiftSonic bridge for auth, retry and media URL generation
client = Path("BuFi/Core/OpenSubsonicClient.swift")
replace_once(
    client,
    "import Foundation\n",
    "import Foundation\nimport SwiftSonic\n",
)
replace_once(
    client,
    "    private let decoder: JSONDecoder\n",
    "    private let decoder: JSONDecoder\n"
    "    private let swiftSonic: SwiftSonicClient\n",
)
replace_once(
    client,
    """        self.credentials = ServerCredentials(
            serverURL: normalized.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            username: credentials.username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: credentials.password
        )

        let configuration = URLSessionConfiguration.ephemeral
""",
    """        let username = credentials.username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.credentials = ServerCredentials(
            serverURL: normalized.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            username: username,
            password: credentials.password
        )
        self.swiftSonic = SwiftSonicClient(
            configuration: ServerConfiguration(
                serverURL: normalized,
                username: username,
                password: credentials.password,
                reusesSalt: false,
                clientName: Self.clientName,
                apiVersion: Self.apiVersion,
                requestTimeout: 18,
                resourceTimeout: 60
            )
        )

        let configuration = URLSessionConfiguration.ephemeral
""",
)
replace_once(
    client,
    """    func ping() async throws -> StatusBody {
        let url = try endpointURL("ping")
""",
    """    func ping() async throws -> StatusBody {
        // SwiftSonic owns the hardened salted-token authentication and transient retry path.
        // The lightweight BuFi decode below is kept only to preserve server version metadata.
        try await swiftSonic.ping()
        let url = try endpointURL("ping")
""",
)
stream_start = client.read_text().index("    func streamURL(")
stream_end = client.read_text().index("    enum StarTarget", stream_start)
client_text = client.read_text()
media_helpers = '''    func streamURL(
        songID: String,
        quality: StreamQuality,
        compatibilityFormat: String? = nil
    ) throws -> URL {
        let requestedFormat = compatibilityFormat ?? quality.parameters["format"]
        let requestedBitRate: Int?
        if compatibilityFormat != nil {
            requestedBitRate = 320
        } else if let value = quality.parameters["maxBitRate"], let bitRate = Int(value), bitRate > 0 {
            requestedBitRate = bitRate
        } else {
            requestedBitRate = nil
        }
        guard let url = swiftSonic.streamURL(
            id: songID,
            maxBitRate: requestedBitRate,
            format: requestedFormat,
            estimateContentLength: true
        ) else {
            throw OpenSubsonicError.invalidServerURL
        }
        return url
    }

    func coverURL(id: String, size: Int = 600) throws -> URL {
        guard let url = swiftSonic.coverArtURL(id: id, size: size) else {
            throw OpenSubsonicError.invalidServerURL
        }
        return url
    }

    func downloadURL(songID: String) throws -> URL {
        guard let url = swiftSonic.downloadURL(id: songID) else {
            throw OpenSubsonicError.invalidServerURL
        }
        return url
    }

'''
client.write_text(client_text[:stream_start] + media_helpers + client_text[stream_end:])


# MARK: Nuke-backed image pipeline preserving the existing ArtworkStore API
artwork = Path("BuFi/Core/ArtworkStore.swift")
old_artwork = artwork.read_text()
components_index = old_artwork.index("    private static func components")
dominant_index = old_artwork.index("    private static func dominantColor", components_index)
hash_index = old_artwork.index("    private static func hash", dominant_index)
components = old_artwork[components_index:dominant_index]
dominant = old_artwork[dominant_index:hash_index]
palette_box = old_artwork[old_artwork.index("private final class PaletteBox"):]
new_artwork = '''import Foundation
import Nuke
import UIKit

struct RGBAColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    static let fallbackTop = RGBAColor(red: 0.26, green: 0.34, blue: 0.30, alpha: 1)
    static let fallbackBottom = RGBAColor(red: 0.08, green: 0.09, blue: 0.09, alpha: 1)
}

struct ArtworkPalette: Equatable, Sendable {
    let top: RGBAColor
    let bottom: RGBAColor

    static let fallback = ArtworkPalette(top: .fallbackTop, bottom: .fallbackBottom)
}

actor ArtworkStore {
    static let shared = ArtworkStore()

    private let pipeline: ImagePipeline
    private let paletteMemory = NSCache<NSString, PaletteBox>()

    init() {
        var configuration = ImagePipeline.Configuration.withDataCache(
            name: "cloud.tae00217.BuFi.Artwork",
            sizeLimit: 384 * 1_024 * 1_024
        )
        configuration.isTaskCoalescingEnabled = true
        configuration.isProgressiveDecodingEnabled = true
        configuration.dataCachePolicy = .automatic
        let delegate = ArtworkPipelineDelegate()
        self.pipeline = ImagePipeline(configuration: configuration, delegate: delegate)
        paletteMemory.countLimit = 160
    }

    func image(for url: URL, pixelSize: CGFloat) async throws -> UIImage {
        let requestedPixelSize = min(max(pixelSize, 64), 1_536)
        let request = ImageRequest(
            url: url,
            processors: [.resize(width: requestedPixelSize)]
        )
        return try await pipeline.image(for: request)
    }

    func prefetch(urls: [URL], pixelSize: CGFloat) async {
        guard !urls.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for url in urls.prefix(6) {
                group.addTask(priority: .utility) { [pipeline] in
                    let request = ImageRequest(
                        url: url,
                        processors: [.resize(width: min(max(pixelSize, 64), 1_536))],
                        priority: .low
                    )
                    _ = try? await pipeline.image(for: request)
                }
            }
        }
    }

    func palette(for url: URL, image: UIImage? = nil) async -> ArtworkPalette {
        let key = ArtworkPipelineDelegate.normalizedCacheKey(for: url) as NSString
        if let cached = paletteMemory.object(forKey: key) { return cached.value }

        let source: UIImage
        if let providedImage = image {
            source = providedImage
        } else {
            let loadedImage = try? await self.image(for: url, pixelSize: 96)
            guard let loadedImage else { return .fallback }
            source = loadedImage
        }

        guard let base = Self.dominantColor(in: source) else { return .fallback }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 1
        base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        let top = UIColor(
            hue: hue,
            saturation: min(max(saturation * 1.05, 0.24), 0.76),
            brightness: min(max(brightness * 0.78, 0.28), 0.58),
            alpha: 1
        )
        let bottom = UIColor(
            hue: hue,
            saturation: min(max(saturation * 0.74, 0.16), 0.56),
            brightness: min(max(brightness * 0.30, 0.065), 0.20),
            alpha: 1
        )

        let value = ArtworkPalette(top: Self.components(top), bottom: Self.components(bottom))
        paletteMemory.setObject(PaletteBox(value), forKey: key)
        return value
    }

    func clearMemory() async {
        await pipeline.cache.removeAll(caches: [.memory])
        paletteMemory.removeAllObjects()
    }

    func clearAll() async {
        await pipeline.cache.removeAll(caches: [.all])
        paletteMemory.removeAllObjects()
    }

''' + components + dominant + '''}

private final class ArtworkPipelineDelegate: ImagePipeline.Delegate, @unchecked Sendable {
    func cacheKey(for request: ImageRequest, pipeline: ImagePipeline) -> String? {
        guard let url = request.url else { return nil }
        let processors = request.processors.map(\\.identifier).joined(separator: "|")
        return Self.normalizedCacheKey(for: url) + "#" + processors
    }

    static func normalizedCacheKey(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        let authenticationFields: Set<String> = [
            "u", "s", "t", "p", "apiKey", "v", "c", "f"
        ]
        components.queryItems = components.queryItems?
            .filter { !authenticationFields.contains($0.name) }
            .sorted {
                if $0.name == $1.name { return ($0.value ?? "") < ($1.value ?? "") }
                return $0.name < $1.name
            }
        return components.string ?? url.absoluteString
    }
}

''' + palette_box
artwork.write_text(new_artwork)


# MARK: Robust offline audio cache with atomic downloads, coalescing and LRU pruning
offline = Path("BuFi/Core/OfflineStore.swift")
offline.write_text('''import CryptoKit
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
            .map(\\.song)
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
''')


# MARK: Queue-aware offline prefetch in the independent audio manager
audio = Path("BuFi/Playback/AudioEngine.swift")
replace_once(
    audio,
    "    private var nowPlayingArtworkTask: Task<Void, Never>?\n",
    "    private var nowPlayingArtworkTask: Task<Void, Never>?\n"
    "    private var offlinePrefetchTask: Task<Void, Never>?\n",
)
replace_once(
    audio,
    "        nowPlayingArtworkTask?.cancel()\n",
    "        nowPlayingArtworkTask?.cancel()\n"
    "        offlinePrefetchTask?.cancel()\n",
)
replace_once(
    audio,
    """        if client == nil {
            queueSaveTask?.cancel()
""",
    """        if client == nil {
            queueSaveTask?.cancel()
            offlinePrefetchTask?.cancel()
""",
)
replace_once(
    audio,
    """        loadCurrentItem(resumeFrom: 0)
        loadLyrics(for: song)
        scheduleQueueSave()
""",
    """        loadCurrentItem(resumeFrom: 0)
        loadLyrics(for: song)
        scheduleOfflinePrefetch()
        scheduleQueueSave()
""",
)
insert_point = audio.read_text().index("    func downloadCurrent() async throws -> URL {")
audio_text = audio.read_text()
prefetch_method = '''    private func scheduleOfflinePrefetch() {
        offlinePrefetchTask?.cancel()
        guard let client, !queue.isEmpty, queue.indices.contains(queueIndex) else { return }
        let configured = UserDefaults.standard.integer(forKey: "offline-prefetch-count")
        let defaultCount = UserDefaults.standard.object(forKey: "offline-prefetch-count") == nil ? 1 : configured
        let count = ProcessInfo.processInfo.isLowPowerModeEnabled ? min(defaultCount, 1) : defaultCount
        guard count > 0 else { return }

        let start = queueIndex + 1
        let end = min(queue.count, start + count)
        guard start < end else { return }
        let candidates = Array(queue[start..<end])

        offlinePrefetchTask = Task(priority: .utility) {
            for song in candidates {
                guard !Task.isCancelled else { return }
                if await OfflineStore.shared.localURL(for: song.id) == nil {
                    _ = try? await OfflineStore.shared.download(song: song, client: client)
                }
            }
        }
    }

'''
audio.write_text(audio_text[:insert_point] + prefetch_method + audio_text[insert_point:])


# MARK: Settings and attributions
settings = Path("BuFi/UI/SettingsView.swift")
replace_once(
    settings,
    "    @AppStorage(\"server-sync-interval\") private var syncInterval = 30.0\n",
    "    @AppStorage(\"server-sync-interval\") private var syncInterval = 30.0\n"
    "    @AppStorage(\"offline-wifi-only\") private var offlineWiFiOnly = true\n"
    "    @AppStorage(\"offline-prefetch-count\") private var offlinePrefetchCount = 1\n"
    "    @AppStorage(\"offline-storage-limit-gb\") private var offlineStorageLimitGB = 10.0\n",
)
replace_once(
    settings,
    """                Section("저장 공간") {
                    LabeledContent("오프라인 저장 공간") {
""",
    """                Section("오프라인 및 저장 공간") {
                    Toggle(isOn: $offlineWiFiOnly) {
                        Label("Wi-Fi에서만 오프라인 저장", systemImage: "wifi")
                    }
                    Picker("다음 곡 선캐시", selection: $offlinePrefetchCount) {
                        Text("끔").tag(0)
                        Text("1곡").tag(1)
                        Text("3곡").tag(3)
                    }
                    Picker("오프라인 용량 제한", selection: $offlineStorageLimitGB) {
                        Text("5 GB").tag(5.0)
                        Text("10 GB").tag(10.0)
                        Text("25 GB").tag(25.0)
                        Text("제한 없음").tag(0.0)
                    }
                    LabeledContent("오프라인 저장 공간") {
""",
)
replace_once(
    settings,
    """            Section("네트워크 압축") {
""",
    """            Section("SwiftSonic") {
                VStack(alignment: .leading, spacing: 5) {
                    Text("SwiftSonic").font(.headline)
                    Text("MIT License · Copyright © Mathieu Dubart and contributors")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Subsonic/OpenSubsonic 인증, 재시도 및 미디어 URL 생성 경로에 사용합니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Nuke / NukeUI") {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Nuke").font(.headline)
                    Text("MIT License · Copyright © Alexander Grebenyuk and contributors")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("앨범 이미지 다운샘플링, 요청 병합, 메모리 및 디스크 캐싱에 사용합니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Cassette 참고 구조") {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Cassette").font(.headline)
                    Text("MPL-2.0 · 구조와 동작 방식 참고, 소스 파일 직접 복사 없음")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("독립 재생 매니저, 최소 UI 관찰 상태, 오프라인 우선 설계를 참고했습니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("네트워크 압축") {
""",
)
settings_text = settings.read_text()
for old in ['?? "1.2.8"', '?? "1.3.1"', '?? "1.3.0"']:
    settings_text = settings_text.replace(old, '?? "1.4.0"')
for old in ['?? "12"', '?? "13"', '?? "14"']:
    settings_text = settings_text.replace(old, '?? "15"')
settings.write_text(settings_text)

print("1.4.0 architecture patch applied")
