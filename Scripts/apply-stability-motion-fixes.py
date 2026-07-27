from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    file = Path(path)
    text = file.read_text()
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{path}: expected one match, found {count}")
    file.write_text(text.replace(old, new, 1))


Path("BuFi/UI/BuFiMotion.swift").write_text('''import SwiftUI

enum BuFiMotion {
    // Motion is intentionally quantized in 0.05-second steps so related
    // transitions feel consistent instead of each view inventing a spring.
    static let micro = Animation.easeOut(duration: 0.10)
    static let tap = Animation.spring(duration: 0.20, bounce: 0.18)
    static let selection = Animation.spring(duration: 0.25, bounce: 0.12)
    static let fade = Animation.easeInOut(duration: 0.25)
    static let text = Animation.spring(duration: 0.30, bounce: 0.08)
    static let color = Animation.easeInOut(duration: 0.35)
    static let page = Animation.spring(duration: 0.40, bounce: 0.10)
    static let player = Animation.spring(duration: 0.45, bounce: 0.12)
    static let lyrics = Animation.spring(duration: 0.50, bounce: 0.10)
}
''')

replace_once(
    "BuFi/UI/Components.swift",
    '''extension TimeInterval {
    var playbackText: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let total = Int(self)
        return "\\(total / 60):\\(String(format: "%02d", total % 60))"
    }
}
''',
    '''extension TimeInterval {
    var playbackText: String {
        guard isFinite, self >= 0 else { return "0:00" }
        // Floor rather than round so the counter never jumps to the next second
        // early. Clamp conversion to avoid malformed stream metadata overflowing.
        let total = Int(min(floor(self), Double(Int.max)))
        return "\\(total / 60):\\(String(format: "%02d", total % 60))"
    }
}
'''
)

replace_once(
    "BuFi/UI/Components.swift",
    '''            .animation(
                .interactiveSpring(response: 0.26, dampingFraction: 0.78),
                value: isEditing
            )
''',
    '''            .animation(BuFiMotion.selection, value: isEditing)
'''
)

replace_once(
    "BuFi/UI/PlayerView.swift",
    '''    private var progress: some View {
        VStack(spacing: 0) {
            InteractiveSeekBar(
                value: $scrubValue,
                range: 0...max(audio.duration, 1),
                tint: playerPrimary
            ) { editing in
                isScrubbing = editing
                if !editing { audio.seek(to: scrubValue) }
            }
            HStack {
                Text((isScrubbing ? scrubValue : audio.elapsed).playbackText)
                Spacer()
                Text("-\\(max(0, audio.duration - (isScrubbing ? scrubValue : audio.elapsed)).playbackText)")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(playerSecondary)
            .monospacedDigit()
        }
    }
''',
    '''    private var progress: some View {
        let duration = audio.duration.isFinite ? max(0, audio.duration) : 0
        let rawElapsed = isScrubbing ? scrubValue : audio.elapsed
        let elapsed = min(max(0, rawElapsed.isFinite ? rawElapsed : 0), max(duration, 0))
        let seekUpperBound = max(duration, 1)
        let remaining = max(0, duration - elapsed)

        return VStack(spacing: 0) {
            InteractiveSeekBar(
                value: $scrubValue,
                range: 0...seekUpperBound,
                tint: playerPrimary
            ) { editing in
                isScrubbing = editing
                if !editing { audio.seek(to: min(scrubValue, duration)) }
            }
            HStack {
                Text(elapsed.playbackText)
                Spacer()
                Text(duration > 0 ? "-\\(remaining.playbackText)" : "--:--")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(playerSecondary)
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(motionEnabled ? BuFiMotion.micro : .none, value: Int(elapsed))
        }
    }
'''
)

replace_once(
    "BuFi/Playback/AudioEngine.swift",
    '''                    let seconds = item.duration.seconds
                    if seconds.isFinite, seconds > 0 { self.duration = seconds }
''',
    '''                    guard self.player.currentItem === item else { return }
                    self.updateDuration(using: item.duration.seconds)
'''
)

replace_once(
    "BuFi/Playback/AudioEngine.swift",
    '''                if let itemDuration = self.player.currentItem?.duration.seconds,
                   itemDuration.isFinite,
                   itemDuration > 0 {
                    self.duration = itemDuration
                }
''',
    '''                if let itemDuration = self.player.currentItem?.duration.seconds {
                    self.updateDuration(using: itemDuration)
                }
                if self.duration > 0 {
                    self.elapsed = min(self.elapsed, self.duration)
                }
'''
)

replace_once(
    "BuFi/Playback/AudioEngine.swift",
    '''        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.next(isAutoAdvance: true) }
        }
''',
    '''        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self,
                      let endedItem = notification.object as? AVPlayerItem,
                      self.player.currentItem === endedItem else { return }
                self.next(isAutoAdvance: true)
            }
        }
'''
)

replace_once(
    "BuFi/Playback/AudioEngine.swift",
    '''    private func installItemObservers(for item: AVPlayerItem) {
''',
    '''    private func updateDuration(using playerDuration: TimeInterval) {
        let metadataDuration = currentSong?.safeDuration ?? 0
        let validPlayerDuration = playerDuration.isFinite && playerDuration > 0
        let validMetadataDuration = metadataDuration.isFinite && metadataDuration > 0

        guard validPlayerDuration || validMetadataDuration else {
            duration = 0
            return
        }
        guard validPlayerDuration else {
            duration = metadataDuration
            return
        }
        guard validMetadataDuration else {
            duration = playerDuration
            return
        }

        // Transcoded and malformed streams can report an AVAsset duration based
        // on an incomplete byte range. OpenSubsonic's song duration is stable;
        // accept the player value only when it closely agrees with metadata.
        let tolerance = max(3, metadataDuration * 0.03)
        duration = abs(playerDuration - metadataDuration) <= tolerance
            ? playerDuration
            : metadataDuration
    }

    private func installItemObservers(for item: AVPlayerItem) {
'''
)

replace_once(
    "BuFi/Playback/AudioEngine.swift",
    '''        ) { [weak self] _ in
            Task { @MainActor in self?.schedulePlaybackRecovery() }
        })
''',
    '''        ) { [weak self] notification in
            Task { @MainActor in
                guard let self, self.player.currentItem === notification.object as? AVPlayerItem else { return }
                self.schedulePlaybackRecovery()
            }
        })
'''
)

replace_once(
    "BuFi/Playback/AudioEngine.swift",
    '''        ) { [weak self] _ in
            Task { @MainActor in self?.handlePlaybackFailure() }
        })
''',
    '''        ) { [weak self] notification in
            Task { @MainActor in
                guard let self, self.player.currentItem === notification.object as? AVPlayerItem else { return }
                self.handlePlaybackFailure()
            }
        })
'''
)
