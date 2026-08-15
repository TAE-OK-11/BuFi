from pathlib import Path


def replace_exact(path: str, old: str, new: str) -> None:
    file = Path(path)
    text = file.read_text()
    if old not in text:
        raise SystemExit(f"missing expected block in {path}: {old[:160]!r}")
    file.write_text(text.replace(old, new, 1))


audio = "BuFi/Playback/AudioEngine.swift"
tests = "BuFiTests/PlaybackPrefetchPlanTests.swift"

replace_exact(
    audio,
    '''    static func nextCompatibilityIndex(\n        in formats: [String],\n''',
    '''    static func shouldForceImmediatePlayback(\n        timeControlStatus: AVPlayer.TimeControlStatus,\n        waitingReason: AVPlayer.WaitingReason?\n    ) -> Bool {\n        guard timeControlStatus == .waitingToPlayAtSpecifiedRate else {\n            return true\n        }\n        return waitingReason != .toMinimizeStalls\n            && waitingReason != .evaluatingBufferingRate\n    }\n\n    static func nextCompatibilityIndex(\n        in formats: [String],\n''',
)

replace_exact(
    audio,
    '''        if !needsReload {\n            player.playImmediately(atRate: 1)\n        }\n''',
    '''        if !needsReload {\n            // Respect AVPlayer's automatic anti-stall buffering policy for\n            // normal resume. playImmediately() is reserved for the watchdog's\n            // bounded force-resume attempt.\n            player.play()\n        }\n''',
)

replace_exact(
    audio,
    '''                        self.player.playImmediately(atRate: 1)\n                        self.schedulePlaybackRecovery()\n''',
    '''                        self.player.play()\n                        self.schedulePlaybackRecovery()\n''',
)

replace_exact(
    audio,
    '''                        self.configureAudioSession()\n                        self.player.playImmediately(atRate: 1)\n                        self.schedulePlaybackRecovery()\n''',
    '''                        self.configureAudioSession()\n                        self.player.play()\n                        self.schedulePlaybackRecovery()\n''',
)

replace_exact(
    audio,
    '''                    self.configureAudioSession()\n                    self.player.playImmediately(atRate: 1)\n                    self.recomputeTimelineFromPlayer()\n''',
    '''                    self.configureAudioSession()\n                    self.player.play()\n                    self.recomputeTimelineFromPlayer()\n''',
)

replace_exact(
    audio,
    '''                    self.configureAudioSession()\n                    self.player.playImmediately(atRate: 1)\n                    self.schedulePlaybackRecovery()\n''',
    '''                    self.configureAudioSession()\n                    self.player.play()\n                    self.schedulePlaybackRecovery()\n''',
)

replace_exact(
    audio,
    '''            self.configureAudioSession()\n            self.player.playImmediately(atRate: 1)\n            self.recomputeTimelineFromPlayer()\n            self.installNextLyricBoundary(after: self.elapsed)\n''',
    '''            if PlaybackRecoveryPolicy.shouldForceImmediatePlayback(\n                timeControlStatus: self.player.timeControlStatus,\n                waitingReason: self.player.reasonForWaitingToPlay\n            ) {\n                self.configureAudioSession()\n                self.player.playImmediately(atRate: 1)\n                self.recomputeTimelineFromPlayer()\n                self.installNextLyricBoundary(after: self.elapsed)\n            }\n''',
)

replace_exact(
    audio,
    '''        configureAudioSession()\n        player.isMuted = false\n        player.volume = 1\n        player.playImmediately(atRate: 1)\n        recomputeTimelineFromPlayer()\n''',
    '''        configureAudioSession()\n        player.isMuted = false\n        player.volume = 1\n        player.play()\n        recomputeTimelineFromPlayer()\n''',
)

replace_exact(
    tests,
    '''    func testNetworkRecoverySkipsRawBeforeTryingLowerBandwidthFormat() {\n''',
    '''    func testAutomaticBufferingWaitIsNotForcedImmediately() {\n        XCTAssertFalse(PlaybackRecoveryPolicy.shouldForceImmediatePlayback(\n            timeControlStatus: .waitingToPlayAtSpecifiedRate,\n            waitingReason: .toMinimizeStalls\n        ))\n        XCTAssertFalse(PlaybackRecoveryPolicy.shouldForceImmediatePlayback(\n            timeControlStatus: .waitingToPlayAtSpecifiedRate,\n            waitingReason: .evaluatingBufferingRate\n        ))\n        XCTAssertTrue(PlaybackRecoveryPolicy.shouldForceImmediatePlayback(\n            timeControlStatus: .paused,\n            waitingReason: nil\n        ))\n    }\n\n    func testNetworkRecoverySkipsRawBeforeTryingLowerBandwidthFormat() {\n''',
)

text = Path(audio).read_text()
if "shouldForceImmediatePlayback" not in text:
    raise SystemExit("buffer-aware recovery policy missing")
if text.count("playImmediately(atRate: 1)") != 1:
    raise SystemExit(f"expected one watchdog-only playImmediately call, found {text.count('playImmediately(atRate: 1)')}")

print("buffer-aware playback patch applied")
