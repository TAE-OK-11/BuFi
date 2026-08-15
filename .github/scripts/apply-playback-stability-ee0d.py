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
    '''struct GaplessSuccessorPlan: Equatable, Sendable {\n    let queueIndex: Int\n\n    static func make(\n        queueCount: Int,\n        currentIndex: Int,\n        shuffleEnabled: Bool,\n        repeatMode: RepeatMode\n    ) -> GaplessSuccessorPlan? {\n        guard queueCount > 0,\n              (0..<queueCount).contains(currentIndex),\n              !shuffleEnabled,\n              repeatMode != .one else { return nil }\n        if currentIndex + 1 < queueCount {\n            return GaplessSuccessorPlan(queueIndex: currentIndex + 1)\n        }\n        return repeatMode == .all\n            ? GaplessSuccessorPlan(queueIndex: 0)\n            : nil\n    }\n}\n\nstruct PlaybackResourceRequest: Sendable {\n''',
    '''struct GaplessSuccessorPlan: Equatable, Sendable {\n    let queueIndex: Int\n\n    static func make(\n        queueCount: Int,\n        currentIndex: Int,\n        shuffleEnabled: Bool,\n        repeatMode: RepeatMode\n    ) -> GaplessSuccessorPlan? {\n        guard queueCount > 0,\n              (0..<queueCount).contains(currentIndex),\n              !shuffleEnabled,\n              repeatMode != .one else { return nil }\n        if currentIndex + 1 < queueCount {\n            return GaplessSuccessorPlan(queueIndex: currentIndex + 1)\n        }\n        return repeatMode == .all\n            ? GaplessSuccessorPlan(queueIndex: 0)\n            : nil\n    }\n}\n\nenum PlaybackGaplessPreparationPolicy {\n    static func shouldPrepare(\n        elapsed: TimeInterval,\n        duration: TimeInterval,\n        isBuffering: Bool,\n        isActivelyPlaying: Bool\n    ) -> Bool {\n        guard isActivelyPlaying,\n              !isBuffering,\n              elapsed.isFinite,\n              duration.isFinite,\n              duration > 0 else {\n            return false\n        }\n        let position = min(max(0, elapsed), duration)\n        let remaining = max(0, duration - position)\n        let leadTime = min(20, max(6, duration * 0.12))\n        return remaining <= leadTime\n    }\n}\n\nstruct PlaybackResourceRequest: Sendable {\n''',
)

replace_exact(
    audio,
    '''    private static let preparedPlaybackAssetLimit = 3\n''',
    '''    private static let preparedPlaybackAssetLimit = 1\n''',
)

replace_exact(
    audio,
    '''    private func scheduleGaplessSuccessor() {\n        guard wantsPlayback,\n              player.timeControlStatus == .playing,\n              stagedSuccessorItem == nil,\n              let plan = GaplessSuccessorPlan.make(\n                queueCount: queue.count,\n                currentIndex: queueIndex,\n                shuffleEnabled: isShuffleEnabled,\n                repeatMode: repeatMode\n              ) else {\n            return\n        }\n        preparePlaybackAsset(for: playbackState.entries[plan.queueIndex])\n    }\n''',
    '''    private func scheduleGaplessSuccessor() {\n        let activelyPlaying = player.timeControlStatus == .playing\n        guard wantsPlayback,\n              stagedSuccessorItem == nil,\n              PlaybackGaplessPreparationPolicy.shouldPrepare(\n                elapsed: currentPlayerPosition(),\n                duration: duration,\n                isBuffering: isBuffering,\n                isActivelyPlaying: activelyPlaying\n              ),\n              let plan = GaplessSuccessorPlan.make(\n                queueCount: queue.count,\n                currentIndex: queueIndex,\n                shuffleEnabled: isShuffleEnabled,\n                repeatMode: repeatMode\n              ) else {\n            return\n        }\n        preparePlaybackAsset(for: playbackState.entries[plan.queueIndex])\n    }\n''',
)

replace_exact(
    audio,
    '''        // Prepare the actual AVURLAsset in addition to lyrics and artwork.\n        // The player consumes this same object on skip, so work completed while\n        // the current song is playing is not discarded or repeated.\n        // Opening an AVURLAsset starts real media transport work. Warm only the\n        // immediate successor so skip latency improves without spending radio,\n        // decoder, and server resources on a track that may never be played.\n        let nextIndex = queueIndex + 1\n        if playbackState.entries.indices.contains(nextIndex) {\n            preparePlaybackAsset(for: playbackState.entries[nextIndex])\n        }\n\n''',
    '''        // Keep speculative work light while the active stream is playing.\n        // Opening/staging the next AVURLAsset starts a second media transport and\n        // can compete with the current stream. Gapless media preparation is now\n        // deferred to the final playback window by scheduleGaplessSuccessor().\n\n''',
)

replace_exact(
    audio,
    '''                case .readyToPlay:\n                    self.isBuffering = false\n                    self.updateDuration(using: item.duration.seconds)\n                    let targetPosition = self.pendingSeekPosition ?? resumePosition\n                    if targetPosition > 0 {\n                        self.seekPlayer(\n                            to: targetPosition,\n                            persistsQueue: false\n                        )\n                    } else {\n                        self.pendingSeekPosition = nil\n                        self.recomputeTimelineFromPlayer()\n                        self.installNextLyricBoundary(after: self.elapsed)\n                    }\n                    if self.wantsPlayback {\n                        self.configureAudioSession()\n                        self.player.isMuted = false\n                        self.player.volume = 1\n                        self.activateNowPlayingSession()\n                        self.player.playImmediately(atRate: 1)\n                        self.schedulePlaybackRecovery()\n                    }\n''',
    '''                case .readyToPlay:\n                    self.updateDuration(using: item.duration.seconds)\n                    let targetPosition = self.pendingSeekPosition ?? resumePosition\n                    let needsPositioning = targetPosition > 0.05\n                    if needsPositioning {\n                        // Never start a freshly reloaded item at zero and then\n                        // seek it back to the recovery position. Wait for the\n                        // seek completion before resuming audio so a transient\n                        // transport retry cannot produce an audible jump/cut.\n                        self.isBuffering = self.wantsPlayback\n                        self.seekPlayer(\n                            to: targetPosition,\n                            persistsQueue: false,\n                            resumesPlayback: self.wantsPlayback\n                        )\n                    } else {\n                        self.pendingSeekPosition = nil\n                        self.isBuffering = false\n                        self.recomputeTimelineFromPlayer()\n                        self.installNextLyricBoundary(after: self.elapsed)\n                    }\n                    if self.wantsPlayback, !needsPositioning {\n                        self.configureAudioSession()\n                        self.player.isMuted = false\n                        self.player.volume = 1\n                        self.activateNowPlayingSession()\n                        self.player.playImmediately(atRate: 1)\n                        self.schedulePlaybackRecovery()\n                    }\n''',
)

replace_exact(
    audio,
    '''                if item.isPlaybackBufferEmpty, self.wantsPlayback {\n                    self.schedulePlaybackRecovery()\n                }\n''',
    '''                if item.isPlaybackBufferEmpty, self.wantsPlayback {\n                    // The active stream owns bandwidth during a stall. Remove\n                    // any staged successor and cancel optional transfers before\n                    // recovery so they cannot prolong the underrun.\n                    self.invalidateStagedSuccessor(removeFromPlayer: true)\n                    self.suspendSpeculativePrefetch()\n                    self.schedulePlaybackRecovery()\n                }\n''',
)

replace_exact(
    audio,
    '''                guard item.isPlaybackLikelyToKeepUp else { return }\n                if self.wantsPlayback, self.player.timeControlStatus != .playing {\n                    self.configureAudioSession()\n                    self.player.playImmediately(atRate: 1)\n                    self.recomputeTimelineFromPlayer()\n                    self.installNextLyricBoundary(after: self.elapsed)\n                    self.schedulePlaybackRecovery()\n                }\n''',
    '''                guard item.isPlaybackLikelyToKeepUp,\n                      !self.isSeekInFlight,\n                      self.pendingSeekPosition == nil else { return }\n                if self.wantsPlayback, self.player.timeControlStatus != .playing {\n                    self.configureAudioSession()\n                    self.player.playImmediately(atRate: 1)\n                    self.recomputeTimelineFromPlayer()\n                    self.installNextLyricBoundary(after: self.elapsed)\n                    self.schedulePlaybackRecovery()\n                }\n''',
)

replace_exact(
    audio,
    '''                if resumesPlayback, finished, self.wantsPlayback {\n                    self.configureAudioSession()\n                    self.player.playImmediately(atRate: 1)\n                }\n                if persistsQueue, finished {\n''',
    '''                if resumesPlayback, self.wantsPlayback {\n                    if finished {\n                        self.isBuffering = false\n                        self.configureAudioSession()\n                        self.player.playImmediately(atRate: 1)\n                        self.schedulePlaybackRecovery()\n                    } else {\n                        self.isBuffering = true\n                        self.schedulePlaybackRecovery()\n                    }\n                }\n                if persistsQueue, finished {\n''',
)

replace_exact(
    audio,
    '''    private func schedulePlaybackRecovery() {\n        guard wantsPlayback, currentSong != nil, recoveryTask == nil else { return }\n''',
    '''    private func schedulePlaybackRecovery() {\n        guard wantsPlayback,\n              currentSong != nil,\n              recoveryTask == nil,\n              !isSeekInFlight,\n              pendingSeekPosition == nil else { return }\n''',
)

replace_exact(
    audio,
    '''            guard !Task.isCancelled, self.wantsPlayback,\n                  let item = self.player.currentItem else { return }\n''',
    '''            guard !Task.isCancelled, self.wantsPlayback,\n                  !self.isSeekInFlight,\n                  self.pendingSeekPosition == nil,\n                  let item = self.player.currentItem else { return }\n''',
)

replace_exact(
    audio,
    '''            guard !Task.isCancelled, self.wantsPlayback,\n                  self.networkPathIsSatisfied,\n                  self.player.currentItem === item else { return }\n''',
    '''            guard !Task.isCancelled, self.wantsPlayback,\n                  self.networkPathIsSatisfied,\n                  !self.isSeekInFlight,\n                  self.pendingSeekPosition == nil,\n                  self.player.currentItem === item else { return }\n''',
)

replace_exact(
    audio,
    '''                } else {\n                    self.recoveryStabilityTask?.cancel()\n                    self.recoveryStabilityTask = nil\n                    // A buffering or recovery transition must give the active\n                    // stream sole use of the radio and server connection.\n                    self.suspendSpeculativePrefetch()\n                    self.schedulePlaybackRecovery()\n                }\n''',
    '''                } else {\n                    self.recoveryStabilityTask?.cancel()\n                    self.recoveryStabilityTask = nil\n                    // A buffering or recovery transition must give the active\n                    // stream sole use of the radio and server connection. A\n                    // queued successor can itself keep a second media request\n                    // alive, so remove it until the current stream is healthy.\n                    self.invalidateStagedSuccessor(removeFromPlayer: true)\n                    self.suspendSpeculativePrefetch()\n                    self.schedulePlaybackRecovery()\n                }\n''',
)

replace_exact(
    audio,
    '''                    if let itemDuration = self.player.currentItem?.duration.seconds {\n                        self.updateDuration(using: itemDuration)\n                    }\n                    self.submitScrobbleIfNeeded()\n''',
    '''                    if let itemDuration = self.player.currentItem?.duration.seconds {\n                        self.updateDuration(using: itemDuration)\n                    }\n                    // Re-evaluate once per playback second. The policy keeps\n                    // the next media transport closed until the final window,\n                    // then preserves gapless hand-off without long-lived dual\n                    // stream contention.\n                    self.scheduleGaplessSuccessor()\n                    self.submitScrobbleIfNeeded()\n''',
)

replace_exact(
    tests,
    '''    private func song(\n''',
    '''    func testGaplessPreparationDoesNotOpenSecondStreamEarly() {\n        XCTAssertFalse(PlaybackGaplessPreparationPolicy.shouldPrepare(\n            elapsed: 30,\n            duration: 180,\n            isBuffering: false,\n            isActivelyPlaying: true\n        ))\n        XCTAssertTrue(PlaybackGaplessPreparationPolicy.shouldPrepare(\n            elapsed: 162,\n            duration: 180,\n            isBuffering: false,\n            isActivelyPlaying: true\n        ))\n    }\n\n    func testGaplessPreparationStopsDuringBuffering() {\n        XCTAssertFalse(PlaybackGaplessPreparationPolicy.shouldPrepare(\n            elapsed: 175,\n            duration: 180,\n            isBuffering: true,\n            isActivelyPlaying: true\n        ))\n        XCTAssertFalse(PlaybackGaplessPreparationPolicy.shouldPrepare(\n            elapsed: 175,\n            duration: 180,\n            isBuffering: false,\n            isActivelyPlaying: false\n        ))\n    }\n\n    func testGaplessPreparationRequiresKnownFiniteDuration() {\n        XCTAssertFalse(PlaybackGaplessPreparationPolicy.shouldPrepare(\n            elapsed: 10,\n            duration: 0,\n            isBuffering: false,\n            isActivelyPlaying: true\n        ))\n        XCTAssertFalse(PlaybackGaplessPreparationPolicy.shouldPrepare(\n            elapsed: 10,\n            duration: .infinity,\n            isBuffering: false,\n            isActivelyPlaying: true\n        ))\n    }\n\n    private func song(\n''',
)

text = Path(audio).read_text()
if "preparedPlaybackAssetLimit = 1" not in text:
    raise SystemExit("prepared asset limit was not reduced")
if "resumesPlayback: self.wantsPlayback" not in text:
    raise SystemExit("reload seek does not resume only after positioning")
if "PlaybackGaplessPreparationPolicy.shouldPrepare" not in text:
    raise SystemExit("gapless preparation policy missing")
if "let nextIndex = queueIndex + 1" in text[text.find("private func scheduleNetworkPrefetch"):text.find("private func scheduleOfflinePrefetch")]:
    raise SystemExit("network prefetch still opens the next media asset early")

print("playback stability patch applied")
