from pathlib import Path


def replace_exact(path: str, old: str, new: str) -> None:
    file = Path(path)
    text = file.read_text()
    if old not in text:
        raise SystemExit(f"missing expected block in {path}: {old[:180]!r}")
    file.write_text(text.replace(old, new, 1))


audio = "BuFi/Playback/AudioEngine.swift"
tests = "BuFiTests/PlaybackPrefetchPlanTests.swift"

replace_exact(
    audio,
    '''        let leadTime = min(20, max(6, duration * 0.12))\n        return remaining <= leadTime\n    }\n}\n''',
    '''        let leadTime = min(20, max(6, duration * 0.12))\n        return remaining <= leadTime\n    }\n\n    static func shouldStage(\n        elapsed: TimeInterval,\n        duration: TimeInterval,\n        isBuffering: Bool,\n        isActivelyPlaying: Bool\n    ) -> Bool {\n        guard isActivelyPlaying,\n              !isBuffering,\n              elapsed.isFinite,\n              duration.isFinite,\n              duration > 0 else {\n            return false\n        }\n        let position = min(max(0, elapsed), duration)\n        let remaining = max(0, duration - position)\n        let leadTime = min(8, max(3, duration * 0.04))\n        return remaining <= leadTime\n    }\n}\n''',
)

replace_exact(
    audio,
    '''        guard stagedSuccessorItem == nil,\n              !isShuffleEnabled,\n              repeatMode != .one,\n              wantsPlayback,\n              let currentItem = player.currentItem,\n''',
    '''        guard stagedSuccessorItem == nil,\n              !isShuffleEnabled,\n              repeatMode != .one,\n              wantsPlayback,\n              PlaybackGaplessPreparationPolicy.shouldStage(\n                elapsed: currentPlayerPosition(),\n                duration: duration,\n                isBuffering: isBuffering,\n                isActivelyPlaying: player.timeControlStatus == .playing\n              ),\n              let currentItem = player.currentItem,\n''',
)

replace_exact(
    audio,
    '''                        Self.logger.warning(\n                            "Playback stalled; scheduling bounded recovery"\n                        )\n                        self.schedulePlaybackRecovery()\n''',
    '''                        Self.logger.warning(\n                            "Playback stalled; prioritizing active stream recovery"\n                        )\n                        self.invalidateStagedSuccessor(removeFromPlayer: true)\n                        self.suspendSpeculativePrefetch()\n                        self.schedulePlaybackRecovery()\n''',
)

replace_exact(
    tests,
    '''    func testGaplessPreparationStopsDuringBuffering() {\n''',
    '''    func testGaplessStagingWaitsUntilFinalPlaybackWindow() {\n        XCTAssertFalse(PlaybackGaplessPreparationPolicy.shouldStage(\n            elapsed: 170,\n            duration: 180,\n            isBuffering: false,\n            isActivelyPlaying: true\n        ))\n        XCTAssertTrue(PlaybackGaplessPreparationPolicy.shouldStage(\n            elapsed: 174,\n            duration: 180,\n            isBuffering: false,\n            isActivelyPlaying: true\n        ))\n        XCTAssertFalse(PlaybackGaplessPreparationPolicy.shouldStage(\n            elapsed: 179,\n            duration: 180,\n            isBuffering: true,\n            isActivelyPlaying: true\n        ))\n    }\n\n    func testGaplessPreparationStopsDuringBuffering() {\n''',
)

text = Path(audio).read_text()
if "PlaybackGaplessPreparationPolicy.shouldStage" not in text:
    raise SystemExit("two-stage gapless staging guard missing")
if "prioritizing active stream recovery" not in text:
    raise SystemExit("stall active-stream prioritization missing")
if text.count("playImmediately(atRate: 1)") != 1:
    raise SystemExit("playImmediately must remain watchdog-only")

print("two-stage gapless patch applied")
