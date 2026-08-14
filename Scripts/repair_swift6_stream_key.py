from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected 1 match, found {count}")
    print(f"patched: {label}")
    return text.replace(old, new, 1)


path = Path("BuFi/Playback/AudioEngine.swift")
text = path.read_text()

text = replace_once(
    text,
    '''        LaunchDiagnostics.mark("audio-runtime-ready    private static func preparedPlaybackKey(
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
    }

    func configure(
''',
    '''        LaunchDiagnostics.mark("audio-runtime-ready")
    }

    func configure(
''',
    "restore audio runtime initialization",
)

text = replace_once(
    text,
    '''    private static func preparedPlaybackKey(
        accountScope: String?,
        queueEntryID: UUID,
        streamRevision: String,
        quality: StreamQuality,
        compatibilityFormat: String
    ) -> String {
        [
            accountScope ?? "",
            queueEntryID.uuidString,
            streamRevision,
            quality.rawValue,
            compatibilityFormat.lowercased()
        ]
            .joined(separator: "|")
    }
''',
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
    }
''',
    "replace prepared playback string key",
)

path.write_text(text)
