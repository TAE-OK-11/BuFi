from pathlib import Path
import re


def replace_once(path: str, old: str, new: str, label: str) -> None:
    file = Path(path)
    text = file.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected 1 match, found {count}")
    file.write_text(text.replace(old, new, 1))
    print(f"patched: {label}")


def replace_regex_once(path: str, pattern: str, replacement: str, label: str) -> None:
    file = Path(path)
    text = file.read_text()
    next_text, count = re.subn(pattern, replacement, text, count=1, flags=re.MULTILINE)
    if count != 1:
        raise SystemExit(f"{label}: expected 1 match, found {count}")
    file.write_text(next_text)
    print(f"patched: {label}")


client = "BuFi/Core/OpenSubsonicClient.swift"
replace_once(
    client,
    '''    private struct ReadRequestKey: Hashable, Sendable {
        let endpoint: String
        let queryItems: [String]
        let cacheRevision: OpenSubsonicCacheRevision

        init(
            endpoint: String,
            queryItems: [URLQueryItem],
            cacheRevision: OpenSubsonicCacheRevision
        ) {
            self.endpoint = endpoint
            self.cacheRevision = cacheRevision
            self.queryItems = queryItems
                .map { "\\($0.name)=\\($0.value ?? \"\")" }
                .sorted()
        }
    }
''',
    '''    private typealias ReadRequestKey = OpenSubsonicReadRequestKey
''',
    "typed OpenSubsonic read request key",
)

audio = "BuFi/Playback/AudioEngine.swift"
replace_once(
    audio,
    '''    private struct PreparedPlaybackAsset {
        let key: String
        let queueEntryID: UUID
''',
    '''    private struct PreparedPlaybackAsset {
        let key: PreparedPlaybackKey
        let queueEntryID: UUID
''',
    "typed prepared playback asset key",
)
replace_once(
    audio,
    '''    private var preparedPlaybackAssets: [String: PreparedPlaybackAsset] = [:]
    private var preparedPlaybackAssetOrder: [String] = []
    private var preparedPlaybackWarmupTasks: [String: Task<Void, Never>] = [:]
''',
    '''    private var preparedPlaybackAssets: [PreparedPlaybackKey: PreparedPlaybackAsset] = [:]
    private var preparedPlaybackAssetOrder: [PreparedPlaybackKey] = []
    private var preparedPlaybackWarmupTasks: [PreparedPlaybackKey: Task<Void, Never>] = [:]
''',
    "typed prepared playback cache containers",
)
replace_regex_once(
    audio,
    r'''    private static func preparedPlaybackKey\(
        accountScope: String\?,
        queueEntryID: UUID,
        streamRevision: String,
        quality: StreamQuality,
        compatibilityFormat: String
    \) -> String \{
        \[
            accountScope \?\? "",
            queueEntryID\.uuidString,
            streamRevision,
            quality\.rawValue,
            compatibilityFormat\.lowercased\(\)
        \]
            \.joined\(separator: "\\|"\)
    \}''',
    '''    private static func preparedPlaybackKey(
        accountScope: String?,
        queueEntryID: UUID,
        streamRevision: String,
        quality: StreamQuality,
        compatibilityFormat: String
    ) -> PreparedPlaybackKey {
        PreparedPlaybackKey(
            accountScope: accountScope,
            queueEntryID: queueEntryID,
            streamRevision: streamRevision,
            quality: quality,
            compatibilityFormat: compatibilityFormat
        )
    }''',
    "typed prepared playback key construction",
)
