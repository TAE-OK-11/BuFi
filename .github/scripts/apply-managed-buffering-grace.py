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
    '''    static func shouldForceImmediatePlayback(\n        timeControlStatus: AVPlayer.TimeControlStatus,\n        waitingReason: AVPlayer.WaitingReason?\n    ) -> Bool {\n        guard timeControlStatus == .waitingToPlayAtSpecifiedRate else {\n            return true\n        }\n        return waitingReason != .toMinimizeStalls\n            && waitingReason != .evaluatingBufferingRate\n    }\n''',
    '''    static func isManagedBufferingWait(\n        timeControlStatus: AVPlayer.TimeControlStatus,\n        waitingReason: AVPlayer.WaitingReason?\n    ) -> Bool {\n        guard timeControlStatus == .waitingToPlayAtSpecifiedRate else {\n            return false\n        }\n        return waitingReason == .toMinimizeStalls\n            || waitingReason == .evaluatingBufferingRate\n    }\n\n    static func shouldForceImmediatePlayback(\n        timeControlStatus: AVPlayer.TimeControlStatus,\n        waitingReason: AVPlayer.WaitingReason?\n    ) -> Bool {\n        !isManagedBufferingWait(\n            timeControlStatus: timeControlStatus,\n            waitingReason: waitingReason\n        )\n    }\n''',
)

replace_exact(
    audio,
    '''            if item.status == .readyToPlay,\n               self.currentSong?.externalStreamURL == nil,\n               !self.isSeekInFlight,\n               self.pendingSeekPosition == nil,\n               let target = PlaybackRecoveryPolicy.startupNudgeTarget(\n''',
    '''            if item.status == .readyToPlay,\n               self.currentSong?.externalStreamURL == nil,\n               !self.isSeekInFlight,\n               self.pendingSeekPosition == nil,\n               !PlaybackRecoveryPolicy.isManagedBufferingWait(\n                    timeControlStatus: self.player.timeControlStatus,\n                    waitingReason: self.player.reasonForWaitingToPlay\n               ),\n               let target = PlaybackRecoveryPolicy.startupNudgeTarget(\n''',
)

replace_exact(
    audio,
    '''            if self.player.timeControlStatus == .playing,\n               PlaybackRecoveryPolicy.hasMeaningfulProgress(\n                    from: progressBaseline,\n                    to: self.currentPlayerPosition()\n               ) {\n                return\n            }\n\n            self.recoveryAttempt += 1\n''',
    '''            if self.player.timeControlStatus == .playing,\n               PlaybackRecoveryPolicy.hasMeaningfulProgress(\n                    from: progressBaseline,\n                    to: self.currentPlayerPosition()\n               ) {\n                return\n            }\n\n            if PlaybackRecoveryPolicy.isManagedBufferingWait(\n                timeControlStatus: self.player.timeControlStatus,\n                waitingReason: self.player.reasonForWaitingToPlay\n            ) {\n                // AVPlayer has deliberately paused to build a safer buffer.\n                // Give that buffer time to fill instead of throwing away the\n                // partially loaded item and restarting the HTTP media request.\n                do {\n                    try await Task.sleep(for: .seconds(4))\n                } catch {\n                    return\n                }\n                guard !Task.isCancelled, self.wantsPlayback,\n                      self.networkPathIsSatisfied,\n                      !self.isSeekInFlight,\n                      self.pendingSeekPosition == nil,\n                      self.player.currentItem === item else { return }\n                if self.player.timeControlStatus == .playing,\n                   PlaybackRecoveryPolicy.hasMeaningfulProgress(\n                        from: progressBaseline,\n                        to: self.currentPlayerPosition()\n                   ) {\n                    return\n                }\n            }\n\n            self.recoveryAttempt += 1\n''',
)

replace_exact(
    tests,
    '''    func testAutomaticBufferingWaitIsNotForcedImmediately() {\n        XCTAssertFalse(PlaybackRecoveryPolicy.shouldForceImmediatePlayback(\n            timeControlStatus: .waitingToPlayAtSpecifiedRate,\n            waitingReason: .toMinimizeStalls\n        ))\n        XCTAssertFalse(PlaybackRecoveryPolicy.shouldForceImmediatePlayback(\n            timeControlStatus: .waitingToPlayAtSpecifiedRate,\n            waitingReason: .evaluatingBufferingRate\n        ))\n        XCTAssertTrue(PlaybackRecoveryPolicy.shouldForceImmediatePlayback(\n            timeControlStatus: .paused,\n            waitingReason: nil\n        ))\n    }\n''',
    '''    func testAutomaticBufferingWaitIsNotForcedImmediately() {\n        XCTAssertTrue(PlaybackRecoveryPolicy.isManagedBufferingWait(\n            timeControlStatus: .waitingToPlayAtSpecifiedRate,\n            waitingReason: .toMinimizeStalls\n        ))\n        XCTAssertTrue(PlaybackRecoveryPolicy.isManagedBufferingWait(\n            timeControlStatus: .waitingToPlayAtSpecifiedRate,\n            waitingReason: .evaluatingBufferingRate\n        ))\n        XCTAssertFalse(PlaybackRecoveryPolicy.shouldForceImmediatePlayback(\n            timeControlStatus: .waitingToPlayAtSpecifiedRate,\n            waitingReason: .toMinimizeStalls\n        ))\n        XCTAssertFalse(PlaybackRecoveryPolicy.shouldForceImmediatePlayback(\n            timeControlStatus: .waitingToPlayAtSpecifiedRate,\n            waitingReason: .evaluatingBufferingRate\n        ))\n        XCTAssertFalse(PlaybackRecoveryPolicy.isManagedBufferingWait(\n            timeControlStatus: .paused,\n            waitingReason: nil\n        ))\n        XCTAssertTrue(PlaybackRecoveryPolicy.shouldForceImmediatePlayback(\n            timeControlStatus: .paused,\n            waitingReason: nil\n        ))\n    }\n''',
)

text = Path(audio).read_text()
if "isManagedBufferingWait" not in text:
    raise SystemExit("managed buffering classifier missing")
if "try await Task.sleep(for: .seconds(4))" not in text:
    raise SystemExit("managed buffering grace missing")
if text.count("playImmediately(atRate: 1)") != 1:
    raise SystemExit("playImmediately must remain watchdog-only")

print("managed buffering grace applied")
