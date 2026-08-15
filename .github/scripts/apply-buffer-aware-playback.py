from pathlib import Path


def replace_exact(path: str, old: str, new: str) -> None:
    file = Path(path)
    text = file.read_text()
    if old not in text:
        raise SystemExit(f"missing expected block in {path}: {old[:180]!r}")
    file.write_text(text.replace(old, new, 1))


def replace_in_region(path: str, start: str, end: str, old: str, new: str) -> None:
    file = Path(path)
    text = file.read_text()
    start_index = text.find(start)
    if start_index < 0:
        raise SystemExit(f"missing region start in {path}: {start!r}")
    end_index = text.find(end, start_index + len(start))
    if end_index < 0:
        raise SystemExit(f"missing region end in {path}: {end!r}")
    region = text[start_index:end_index]
    if old not in region:
        raise SystemExit(f"missing expected text in region {start!r}: {old!r}")
    region = region.replace(old, new, 1)
    file.write_text(text[:start_index] + region + text[end_index:])


audio = "BuFi/Playback/AudioEngine.swift"
tests = "BuFiTests/PlaybackPrefetchPlanTests.swift"

replace_exact(
    audio,
    '''    static func nextCompatibilityIndex(\n        in formats: [String],\n''',
    '''    static func shouldForceImmediatePlayback(\n        timeControlStatus: AVPlayer.TimeControlStatus,\n        waitingReason: AVPlayer.WaitingReason?\n    ) -> Bool {\n        guard timeControlStatus == .waitingToPlayAtSpecifiedRate else {\n            return true\n        }\n        return waitingReason != .toMinimizeStalls\n            && waitingReason != .evaluatingBufferingRate\n    }\n\n    static func nextCompatibilityIndex(\n        in formats: [String],\n''',
)

replace_in_region(
    audio,
    "    func resumePlayback() {",
    "    func pause() {",
    "player.playImmediately(atRate: 1)",
    "player.play()",
)

replace_in_region(
    audio,
    "    private func seekPlayer(",
    "    /// `isAutoAdvance`",
    "self.player.playImmediately(atRate: 1)",
    "self.player.play()",
)

replace_in_region(
    audio,
    "    private func observeActiveItem(",
    "    private func activateStagedSuccessor(",
    "self.player.playImmediately(atRate: 1)",
    "self.player.play()",
)

replace_in_region(
    audio,
    "    private func installBufferObservers(for item: AVPlayerItem) {",
    "    private func handlePlaybackFailure(",
    "self.player.playImmediately(atRate: 1)",
    "self.player.play()",
)

replace_in_region(
    audio,
    "    private func installNetworkPathMonitor() {",
    "    private static let preparedPlaybackAssetLimit",
    "self.player.playImmediately(atRate: 1)",
    "self.player.play()",
)

replace_in_region(
    audio,
    "    private func preserveActivePlayback() {",
    "    private func beginBackgroundBridge() {",
    "player.playImmediately(atRate: 1)",
    "player.play()",
)

replace_in_region(
    audio,
    "    private func schedulePlaybackRecovery() {",
    "    func retryLyrics() {",
    '''            self.configureAudioSession()\n            self.player.playImmediately(atRate: 1)\n            self.recomputeTimelineFromPlayer()\n            self.installNextLyricBoundary(after: self.elapsed)\n''',
    '''            if PlaybackRecoveryPolicy.shouldForceImmediatePlayback(\n                timeControlStatus: self.player.timeControlStatus,\n                waitingReason: self.player.reasonForWaitingToPlay\n            ) {\n                self.configureAudioSession()\n                self.player.playImmediately(atRate: 1)\n                self.recomputeTimelineFromPlayer()\n                self.installNextLyricBoundary(after: self.elapsed)\n            }\n''',
)

replace_exact(
    tests,
    '''    func testNetworkRecoverySkipsRawBeforeTryingLowerBandwidthFormat() {\n''',
    '''    func testAutomaticBufferingWaitIsNotForcedImmediately() {\n        XCTAssertFalse(PlaybackRecoveryPolicy.shouldForceImmediatePlayback(\n            timeControlStatus: .waitingToPlayAtSpecifiedRate,\n            waitingReason: .toMinimizeStalls\n        ))\n        XCTAssertFalse(PlaybackRecoveryPolicy.shouldForceImmediatePlayback(\n            timeControlStatus: .waitingToPlayAtSpecifiedRate,\n            waitingReason: .evaluatingBufferingRate\n        ))\n        XCTAssertTrue(PlaybackRecoveryPolicy.shouldForceImmediatePlayback(\n            timeControlStatus: .paused,\n            waitingReason: nil\n        ))\n    }\n\n    func testNetworkRecoverySkipsRawBeforeTryingLowerBandwidthFormat() {\n''',
)

text = Path(audio).read_text()
if "shouldForceImmediatePlayback" not in text:
    raise SystemExit("buffer-aware recovery policy missing")
count = text.count("playImmediately(atRate: 1)")
if count != 1:
    raise SystemExit(f"expected one watchdog-only playImmediately call, found {count}")
if text.count("player.play()") < 6:
    raise SystemExit("normal AVPlayer starts were not migrated to play()")

print("buffer-aware playback patch applied")
