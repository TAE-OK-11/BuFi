from __future__ import annotations

from pathlib import Path
import re


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{path}: expected one literal match, found {count}: {old[:100]!r}")
    path.write_text(text.replace(old, new, 1))


def sub_once(path: Path, pattern: str, replacement: str, flags: int = 0) -> None:
    text = path.read_text()
    updated, count = re.subn(pattern, replacement, text, count=1, flags=flags)
    if count != 1:
        raise RuntimeError(f"{path}: expected one regex match, found {count}: {pattern[:120]!r}")
    path.write_text(updated)


audio = Path("BuFi/Playback/AudioEngine.swift")

replace_once(
    audio,
    '''    @Published var quality: StreamQuality {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "stream-quality") }
    }
''',
    '''    @Published var quality: StreamQuality {
        didSet {
            UserDefaults.standard.set(quality.rawValue, forKey: "stream-quality")
            guard oldValue != quality, let song = currentSong else { return }
            restartPlaybackPlan(for: song, resumeFrom: elapsed)
        }
    }
''',
)

replace_once(
    audio,
    '''    private static let iso8601Formatter = ISO8601DateFormatter()
''',
    '''    private static let iso8601Formatter = ISO8601DateFormatter()

    private struct PlaybackResource {
        let url: URL
        let mimeType: String?
    }
''',
)

replace_once(
    audio,
    '''    private var fallbackIndex = 0
    private let fallbackFormats = ["aac", "mp3"]
''',
    '''    private var fallbackIndex = 0
    private var fallbackFormats: [String] = []
''',
)

sub_once(
    audio,
    r'''(        if let song = currentSong \{\n)\s*loadCurrentItem\(resumeFrom: elapsed\)''',
    r'''\1            restartPlaybackPlan(for: song, resumeFrom: elapsed)''',
)

replace_once(
    audio,
    '''            self.loadCurrentItem(resumeFrom: self.elapsed)
''',
    '''            self.restartPlaybackPlan(for: self.currentSong!, resumeFrom: self.elapsed)
''',
)

replace_once(
    audio,
    '''        fallbackIndex = 0
        recoveryAttempt = 0
        activeCompatibilityFormat = nil
''',
    '''        fallbackIndex = 0
        fallbackFormats = Self.fallbackFormats(for: quality)
        recoveryAttempt = 0
        activeCompatibilityFormat = Self.initialCompatibilityFormat(for: quality)
''',
)

replace_once(
    audio,
    '''        loadCurrentItem(resumeFrom: 0)
''',
    '''        loadCurrentItem(
            compatibilityFormat: activeCompatibilityFormat,
            resumeFrom: 0
        )
''',
)

sub_once(
    audio,
    r'''    func localOrRemoteURL\(for song: Song, compatibilityFormat: String\? = nil\) async throws -> URL \{.*?\n    \}\n\n(?=    private func scheduleOfflinePrefetch)''',
    '''    func localOrRemoteURL(for song: Song, compatibilityFormat: String? = nil) async throws -> URL {
        if let local = await OfflineStore.shared.localURL(for: song.id) {
            return local
        }
        guard let client else { throw OpenSubsonicError.invalidServerURL }
        return try await client.streamURL(
            songID: song.id,
            quality: quality,
            compatibilityFormat: compatibilityFormat
        )
    }

    private func playbackResource(
        for song: Song,
        compatibilityFormat: String?
    ) async throws -> PlaybackResource {
        // A downloaded source avoids radio use and is attempted once. If the
        // system rejects it, later codec fallbacks bypass the local source.
        if fallbackIndex == 0,
           let local = await OfflineStore.shared.localURL(for: song.id) {
            return PlaybackResource(
                url: local,
                mimeType: Self.sourceMIMEType(for: song)
            )
        }
        guard let client else { throw OpenSubsonicError.invalidServerURL }
        let url = try await client.streamURL(
            songID: song.id,
            quality: quality,
            compatibilityFormat: compatibilityFormat
        )
        return PlaybackResource(
            url: url,
            mimeType: Self.mimeType(
                for: compatibilityFormat,
                sourceSong: song
            )
        )
    }

    private static func initialCompatibilityFormat(for quality: StreamQuality) -> String? {
        switch quality {
        case .automatic, .aac320: "aac"
        case .opus160: "opus"
        case .original: "raw"
        }
    }

    private static func fallbackFormats(for quality: StreamQuality) -> [String] {
        switch quality {
        case .automatic, .aac320:
            ["mp3", "raw"]
        case .opus160:
            ["aac", "mp3", "raw"]
        case .original:
            ["aac", "mp3"]
        }
    }

    private static func mimeType(
        for compatibilityFormat: String?,
        sourceSong song: Song
    ) -> String? {
        switch compatibilityFormat?.lowercased() {
        case "aac": "audio/aac"
        case "mp3": "audio/mpeg"
        case "opus": "audio/ogg; codecs=opus"
        case "raw", nil: sourceMIMEType(for: song)
        default: song.contentType
        }
    }

    private static func sourceMIMEType(for song: Song) -> String? {
        switch song.suffix?.lowercased() {
        case "flac": "audio/flac"
        case "opus": "audio/ogg; codecs=opus"
        case "ogg", "oga": song.contentType ?? "audio/ogg"
        case "mp3": "audio/mpeg"
        case "aac": "audio/aac"
        case "m4a", "m4b", "mp4", "alac": "audio/mp4"
        case "wav", "wave": "audio/wav"
        case "aif", "aiff": "audio/aiff"
        default: song.contentType
        }
    }

''',
    flags=re.DOTALL,
)

replace_once(
    audio,
    '''    private func loadCurrentItem(
''',
    '''    private func restartPlaybackPlan(for song: Song, resumeFrom: TimeInterval) {
        fallbackIndex = 0
        fallbackFormats = Self.fallbackFormats(for: quality)
        activeCompatibilityFormat = Self.initialCompatibilityFormat(for: quality)
        loadCurrentItem(
            compatibilityFormat: activeCompatibilityFormat,
            resumeFrom: resumeFrom
        )
    }

    private func loadCurrentItem(
''',
)

sub_once(
    audio,
    r'''                let url = try await self\.localOrRemoteURL\(.*?                self\.replacePlayerItem\(\n                    url: url,\n                    mimeType: mimeType,\n                    resumePosition: resumePosition\n                \)''',
    '''                let resource = try await self.playbackResource(
                    for: song,
                    compatibilityFormat: compatibilityFormat
                )
                guard !Task.isCancelled, self.currentSong?.id == song.id else { return }
                self.replacePlayerItem(
                    url: resource.url,
                    mimeType: resource.mimeType,
                    resumePosition: resumePosition
                )''',
    flags=re.DOTALL,
)

replace_once(
    audio,
    '''        item.preferredForwardBufferDuration = 20
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
''',
    '''        // Fetch audio in larger contiguous bursts so the radio can return
        // to idle sooner, and never extend the network buffer while paused.
        item.preferredForwardBufferDuration = ProcessInfo.processInfo.isLowPowerModeEnabled
            ? 45
            : 30
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
''',
)

sub_once(
    audio,
    r'''                if self\.currentSong != nil \{\n\s*self\.loadCurrentItem\(resumeFrom: self\.elapsed\)\n\s*\}''',
    '''                if let song = self.currentSong {
                    self.restartPlaybackPlan(for: song, resumeFrom: self.elapsed)
                }''',
)

client = Path("BuFi/Core/OpenSubsonicClient.swift")
sub_once(
    client,
    r'''        let requestedBitRate: Int\?\n        if compatibilityFormat != nil \{\n            requestedBitRate = 320\n        \} else if let value = quality\.parameters\["maxBitRate"\], let bitRate = Int\(value\), bitRate > 0 \{\n            requestedBitRate = bitRate\n        \} else \{\n            requestedBitRate = nil\n        \}''',
    '''        let requestedBitRate: Int?
        if let compatibilityFormat {
            switch compatibilityFormat.lowercased() {
            case "aac":
                requestedBitRate = quality == .aac320 ? 320 : 256
            case "opus":
                requestedBitRate = 160
            case "mp3":
                requestedBitRate = 256
            case "raw":
                requestedBitRate = nil
            default:
                requestedBitRate = 256
            }
        } else if let value = quality.parameters["maxBitRate"], let bitRate = Int(value), bitRate > 0 {
            requestedBitRate = bitRate
        } else {
            requestedBitRate = nil
        }''',
)

settings = Path("BuFi/UI/SettingsView.swift")
sub_once(
    settings,
    r'''(                    Picker\("음질", selection: \$audio\.quality\) \{.*?\n                    \}\n                    \.tint\(Color\(uiColor: \.secondaryLabel\)\))''',
    r'''\1
                    Text("자동 음질은 FLAC·Opus·Vorbis 등 고부하 원본을 서버에서 AAC 256kbps로 변환해 기기 배터리 사용량을 줄입니다. 원본 무손실은 원본 재생을 먼저 시도하고 실패하면 AAC·MP3로 전환합니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)''',
    flags=re.DOTALL,
)

translations = {
    "ko": "자동 음질은 FLAC·Opus·Vorbis 등 고부하 원본을 서버에서 AAC 256kbps로 변환해 기기 배터리 사용량을 줄입니다. 원본 무손실은 원본 재생을 먼저 시도하고 실패하면 AAC·MP3로 전환합니다.",
    "en": "Automatic quality asks the server to convert demanding FLAC, Opus, Vorbis, and similar sources to AAC 256 kbps to reduce device battery use. Original Lossless tries the source first, then falls back to AAC and MP3.",
    "ja": "自動音質では、FLAC・Opus・Vorbis など負荷の高い原音をサーバー側で AAC 256kbps に変換し、端末のバッテリー消費を抑えます。オリジナルロスレスは原音を先に試し、失敗時は AAC・MP3 に切り替えます。",
}
key = translations["ko"]
for locale, value in translations.items():
    path = Path(f"BuFi/Resources/{locale}.lproj/Localizable.strings")
    text = path.read_text()
    entry = f'"{key}" = "{value}";'
    if entry not in text:
        path.write_text(text.rstrip() + "\n" + entry + "\n")
