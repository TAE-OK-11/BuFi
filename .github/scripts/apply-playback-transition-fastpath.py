from pathlib import Path

path = Path('BuFi/Playback/AudioEngine.swift')
text = path.read_text()

def replace_once(old: str, new: str) -> None:
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'expected one block, found {count}: {old[:180]!r}')
    text = text.replace(old, new, 1)

replace_once(
'''    private func startPlayback(\n        _ song: Song,\n        in sourceEntries: [PlaybackQueueEntry],\n        preferredIndex: Int?,\n        autoplay: Bool = true,\n        origin: PlaybackOrigin = .manual,\n        transitionReason: PlaybackEndReason = .replaced\n    ) {\n''',
'''    private func startPlayback(\n        _ song: Song,\n        in sourceEntries: [PlaybackQueueEntry],\n        preferredIndex: Int?,\n        autoplay: Bool = true,\n        origin: PlaybackOrigin = .manual,\n        transitionReason: PlaybackEndReason = .replaced,\n        reusesCurrentQueue: Bool = false\n    ) {\n''')

replace_once(
'''        var normalizedEntries = sourceEntries.isEmpty\n            ? [PlaybackQueueEntry(song: song)]\n            : sourceEntries\n        let resolvedIndex: Int\n        if let preferredIndex, normalizedEntries.indices.contains(preferredIndex) {\n            resolvedIndex = preferredIndex\n        } else if let visualMatch = normalizedEntries.firstIndex(where: {\n            $0.song.id == song.id && $0.song.artworkID == song.artworkID\n        }) {\n            resolvedIndex = visualMatch\n        } else {\n            resolvedIndex = normalizedEntries.firstIndex(where: {\n                $0.song.id == song.id\n            }) ?? 0\n        }\n        if normalizedEntries[resolvedIndex].song.id == song.id {\n            // The tapped row is the freshest metadata source. Replacing the\n            // matching queue entry atomically prevents an older coverArt value\n            // from becoming the visual now-playing source for this transition.\n            normalizedEntries[resolvedIndex].song = song\n        }\n        let selectedSong = normalizedEntries[resolvedIndex].song\n        // Current media, queue entries, selection, and account scope publish as\n        // one snapshot. A fresh playback generation invalidates late artwork\n        // and transport work without changing the durable queue-row identity.\n        replacePlayback(normalizedEntries, index: resolvedIndex)\n''',
'''        var normalizedEntries = sourceEntries.isEmpty\n            ? [PlaybackQueueEntry(song: song)]\n            : sourceEntries\n        let resolvedIndex: Int\n        if reusesCurrentQueue,\n           let preferredIndex,\n           normalizedEntries.indices.contains(preferredIndex) {\n            // Internal next/previous/queue-selection calls already carry the\n            // authoritative queue occurrence. Trust that stable index instead\n            // of scanning the queue for the same song again.\n            resolvedIndex = preferredIndex\n        } else if let preferredIndex, normalizedEntries.indices.contains(preferredIndex) {\n            resolvedIndex = preferredIndex\n        } else if let visualMatch = normalizedEntries.firstIndex(where: {\n            $0.song.id == song.id && $0.song.artworkID == song.artworkID\n        }) {\n            resolvedIndex = visualMatch\n        } else {\n            resolvedIndex = normalizedEntries.firstIndex(where: {\n                $0.song.id == song.id\n            }) ?? 0\n        }\n        if !reusesCurrentQueue,\n           normalizedEntries[resolvedIndex].song.id == song.id {\n            // The tapped row is the freshest metadata source. Replacing the\n            // matching queue entry atomically prevents an older coverArt value\n            // from becoming the visual now-playing source for this transition.\n            normalizedEntries[resolvedIndex].song = song\n        }\n        let selectedSong = normalizedEntries[resolvedIndex].song\n        // Current media, queue entries, selection, and account scope publish as\n        // one snapshot. Existing-queue transitions can renew playback identity\n        // without copy-on-write or queue equality scans.\n        if reusesCurrentQueue {\n            playbackState.setIndex(resolvedIndex, renewsPlayback: true)\n        } else {\n            replacePlayback(normalizedEntries, index: resolvedIndex)\n        }\n''')

# Four internal transitions use the current authoritative queue unchanged.
needles = [
'''                origin: .autoplay,\n                transitionReason: .completed\n            )''',
'''            origin: isAutoAdvance ? .autoplay : .manual,\n            transitionReason: isAutoAdvance ? .completed : .skipped\n        )''',
'''            origin: .manual,\n            transitionReason: .skipped\n        )''',
'''            origin: .queue,\n            transitionReason: .replaced\n        )''',
]
replacements = [
'''                origin: .autoplay,\n                transitionReason: .completed,\n                reusesCurrentQueue: true\n            )''',
'''            origin: isAutoAdvance ? .autoplay : .manual,\n            transitionReason: isAutoAdvance ? .completed : .skipped,\n            reusesCurrentQueue: true\n        )''',
'''            origin: .manual,\n            transitionReason: .skipped,\n            reusesCurrentQueue: true\n        )''',
'''            origin: .queue,\n            transitionReason: .replaced,\n            reusesCurrentQueue: true\n        )''',
]
for old, new in zip(needles, replacements):
    replace_once(old, new)

path.write_text(text)
if text.count('reusesCurrentQueue: true') != 4:
    raise SystemExit('expected four current-queue fast-path call sites')
if 'playbackState.setIndex(resolvedIndex, renewsPlayback: true)' not in text:
    raise SystemExit('missing O(1) current-queue selection path')
print('playback transition fast path applied')
