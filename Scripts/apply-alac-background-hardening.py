from pathlib import Path
import re

p = Path("BuFi/Playback/AudioEngine.swift")
s = p.read_text()
if "case background\n        case successor" in s:
    print("ALAC background hardening already applied")
    raise SystemExit(0)


def one(old: str, new: str, label: str) -> None:
    global s
    if old not in s:
        raise SystemExit(f"missing {label}")
    s = s.replace(old, new, 1)


def rx(pattern: str, repl: str, label: str) -> None:
    global s
    s2, n = re.subn(pattern, repl, s, count=1, flags=re.S | re.M)
    if n != 1:
        raise SystemExit(f"missing regex {label}: {n}")
    s = s2


one(
    "        case constrained\n        case successor",
    "        case constrained\n        case background\n        case successor",
    "phase",
)
one(
    """        case .constrained:
            return switch profile {
            case .aac: 10
            case .compressed: 9
            case .unknown: 9
            case .lossless: 10
            }
        case .successor:""",
    """        case .constrained:
            return switch profile {
            case .aac: 10
            case .compressed: 9
            case .unknown: 9
            case .lossless: 10
            }
        case .background:
            return switch profile {
            case .aac: 20
            case .compressed: 18
            case .unknown: 18
            case .lossless: 32
            }
        case .successor:""",
    "buffer",
)
one(
    "    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid",
    """    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var backgroundBridgeBaselinePosition: TimeInterval?
    private var backgroundBridgePlaybackID: UUID?
    private var backgroundTransitionVerificationTask: Task<Void, Never>?
    private var backgroundTransitionVerificationToken: UUID?""",
    "state",
)

s = s.replace("self.playLatencyOptimized()", "self.resumeTransportForCurrentContext()")
s = s.replace("            playLatencyOptimized()\n", "            resumeTransportForCurrentContext()\n")
s = s.replace("        playLatencyOptimized()\n", "        resumeTransportForCurrentContext()\n")
rx(
    r"(    private func playLatencyOptimized\(\) \{.*?^    \})\n",
    r"""\1

    private func resumeTransportForCurrentContext() {
        if !applicationIsActive,
           currentPlaybackAudioProfile() == .lossless {
            player.play()
            return
        }
        playLatencyOptimized()
    }
""",
    "resume helper",
)

rx(
    r"^    private func expandSettledForwardBufferIfNeeded\(\) \{.*?^    \}\n\n    private func cancelStallConfirmation",
    """    private func expandSettledForwardBufferIfNeeded() {
        guard let item = player.currentItem ?? logicalCurrentItem else { return }
        let isLocal = (item.asset as? AVURLAsset)?.url.isFileURL == true
        let profile = currentPlaybackAudioProfile()
        let phase: PlaybackBufferPolicy.Phase = applicationIsActive ? .settled : .background
        let target = PlaybackBufferPolicy.forwardBufferDuration(
            isLocalFile: isLocal,
            profile: profile,
            phase: phase
        )
        guard item.preferredForwardBufferDuration + 0.01 < target else { return }
        PlaybackBufferPolicy.configure(
            item,
            isLocalFile: isLocal,
            profile: profile,
            phase: phase
        )
    }

    private func cancelStallConfirmation""",
    "buffer expansion",
)

one(
    """    private func scheduleGaplessSuccessor() {
        let activelyPlaying = player.timeControlStatus == .playing
        guard wantsPlayback,""",
    """    private func scheduleGaplessSuccessor() {
        let activelyPlaying = player.timeControlStatus == .playing
        let profile = currentPlaybackAudioProfile()
        guard applicationIsActive || profile != .lossless else { return }
        guard wantsPlayback,""",
    "gapless gate",
)
one(
    """                profile: currentPlaybackAudioProfile()
              ),
              let plan = GaplessSuccessorPlan.make(""",
    """                profile: profile
              ),
              let plan = GaplessSuccessorPlan.make(""",
    "gapless profile",
)

one(
    "    private func scheduleNetworkPrefetch() {\n        let metadataPrefetchCount",
    """    private func scheduleNetworkPrefetch() {
        guard applicationIsActive else {
            cancelNetworkPrefetch(resetKey: true)
            return
        }
        let metadataPrefetchCount""",
    "network prefetch",
)
one(
    "    private func scheduleOfflinePrefetch() {\n        let configured",
    """    private func scheduleOfflinePrefetch() {
        guard applicationIsActive else {
            cancelOfflinePrefetch(resetKey: true)
            return
        }
        let configured""",
    "offline prefetch",
)

s = s.replace(
    '                    self.endBackgroundBridge()\n                    self.reportPlaybackState("playing")',
    '                    self.completeBackgroundBridgeIfPlaybackProgressed()\n                    self.reportPlaybackState("playing")',
    1,
)
one(
    """            if self.duration > 0 {
                self.elapsed = min(self.elapsed, self.duration)
            }
            self.updateActiveLyric(at: lyricPosition)""",
    """            if self.duration > 0 {
                self.elapsed = min(self.elapsed, self.duration)
            }
            self.completeBackgroundBridgeIfPlaybackProgressed()
            self.updateActiveLyric(at: lyricPosition)""",
    "clock bridge",
)

rx(
    r"^    private func setApplicationActive\(_ value: Bool\) \{.*?^    \}\n\n    private func handleDidEnterBackground",
    """    private func setApplicationActive(_ value: Bool) {
        guard applicationIsActive != value else { return }
        applicationIsActive = value
        if value {
            cancelBackgroundTransitionVerification()
            endBackgroundBridge()
        } else if wantsPlayback {
            prepareForBackgroundTransition()
        }
        installPlaybackTimeObserver()
        if value, wantsPlayback, player.timeControlStatus == .playing {
            scheduleNetworkPrefetch()
            scheduleOfflinePrefetch()
            scheduleGaplessSuccessor()
        }
    }

    private func handleDidEnterBackground""",
    "activity",
)

s = s.replace(
    "                    self.setApplicationActive(false)\n                    self.preserveActivePlayback()",
    "                    self.setApplicationActive(false)\n                    // Keep an already healthy transport untouched here.",
    1,
)

block = """    private func handleDidEnterBackground() {
        scheduleQueueSave(immediate: true, syncServer: false)
        guard wantsPlayback else {
            cancelBackgroundTransitionVerification()
            scheduleAudioSessionDeactivation(immediate: true)
            return
        }
        prepareForBackgroundTransition()
        guard let playbackItem = currentPlaybackItem else {
            cancelBackgroundTransitionVerification()
            endBackgroundBridge()
            return
        }
        let baselinePosition = currentPlayerPosition()
        beginBackgroundBridge(playbackItem: playbackItem, baselinePosition: baselinePosition)
        preserveActivePlayback()
        scheduleBackgroundTransitionVerification(
            playbackItem: playbackItem,
            baselinePosition: baselinePosition
        )
    }

    private func prepareForBackgroundTransition() {
        guard wantsPlayback, currentSong != nil else { return }
        suspendSpeculativePrefetch()
        if currentPlaybackAudioProfile() == .lossless,
           let stagedSuccessorItem,
           player.currentItem !== stagedSuccessorItem {
            invalidateStagedSuccessor(removeFromPlayer: true)
        }
        expandSettledForwardBufferIfNeeded()
    }

    private func preserveActivePlayback() {
        guard wantsPlayback, currentSong != nil else { return }
        if player.currentItem == nil || player.currentItem?.status == .failed {
            restartPlaybackPlan(resumeFrom: elapsed)
            updateNowPlaying()
            return
        }
        if player.timeControlStatus != .playing {
            configureAudioSession()
            player.isMuted = false
            player.volume = 1
            resumeTransportForCurrentContext()
        }
        if let item = player.currentItem {
            ensurePlaybackClockLivenessWatchdog(for: item)
        }
        recomputeTimelineFromPlayer()
        installNextLyricBoundary(after: elapsed)
        updateNowPlaying()
    }

    private func scheduleBackgroundTransitionVerification(
        playbackItem: PlaybackMediaItem,
        baselinePosition: TimeInterval
    ) {
        cancelBackgroundTransitionVerification()
        let token = UUID()
        backgroundTransitionVerificationToken = token
        let sessionGeneration = playbackSessionGeneration
        let accountScope = currentAccountScope
        backgroundTransitionVerificationTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(2_500)) }
            catch { return }
            guard let self,
                  !Task.isCancelled,
                  self.backgroundTransitionVerificationToken == token else { return }
            defer {
                if self.backgroundTransitionVerificationToken == token {
                    self.backgroundTransitionVerificationToken = nil
                    self.backgroundTransitionVerificationTask = nil
                }
            }
            guard sessionGeneration == self.playbackSessionGeneration,
                  accountScope == self.currentAccountScope,
                  self.wantsPlayback else { return }
            guard self.currentPlaybackItem?.id == playbackItem.id,
                  self.currentPlaybackItem?.queueEntryID == playbackItem.queueEntryID else {
                if self.player.timeControlStatus == .playing { self.endBackgroundBridge() }
                return
            }
            let position = self.currentPlayerPosition()
            if PlaybackRecoveryPolicy.hasMeaningfulProgress(from: baselinePosition, to: position) {
                self.endBackgroundBridge()
                return
            }
            guard self.networkPathIsSatisfied else {
                self.isBuffering = true
                return
            }
            self.isBuffering = true
            guard let item = self.player.currentItem else {
                self.loadCurrentItem(
                    compatibilityFormat: self.activeCompatibilityFormat,
                    resumeFrom: position
                )
                return
            }
            if item.status == .readyToPlay,
               self.player.timeControlStatus == .playing {
                self.recoverFrozenPlaybackClock(item: item, position: position)
            } else {
                self.configureAudioSession()
                self.resumeTransportForCurrentContext()
                self.schedulePlaybackRecovery(mode: .stall)
            }
        }
    }

    private func cancelBackgroundTransitionVerification() {
        backgroundTransitionVerificationToken = nil
        backgroundTransitionVerificationTask?.cancel()
        backgroundTransitionVerificationTask = nil
    }

    private func beginBackgroundBridge(
        playbackItem: PlaybackMediaItem,
        baselinePosition: TimeInterval
    ) {
        endBackgroundBridge()
        backgroundBridgePlaybackID = playbackItem.id
        backgroundBridgeBaselinePosition = baselinePosition
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "BuFiPlaybackTransition"
        ) { @Sendable [weak self] in
            Task { @MainActor in self?.endBackgroundBridge() }
        }
    }

    private func completeBackgroundBridgeIfPlaybackProgressed() {
        guard !applicationIsActive,
              backgroundTaskID != .invalid,
              let bridgePlaybackID = backgroundBridgePlaybackID,
              let baselinePosition = backgroundBridgeBaselinePosition,
              let playbackItem = currentPlaybackItem else { return }
        if playbackItem.id != bridgePlaybackID {
            if player.timeControlStatus == .playing { endBackgroundBridge() }
            return
        }
        if PlaybackRecoveryPolicy.hasMeaningfulProgress(
            from: baselinePosition,
            to: currentPlayerPosition()
        ) {
            endBackgroundBridge()
        }
    }

    private func endBackgroundBridge() {
        backgroundBridgePlaybackID = nil
        backgroundBridgeBaselinePosition = nil
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

"""
rx(
    r"^    private func handleDidEnterBackground\(\) \{.*?(?=^    private func handleAudioInterruption)",
    block,
    "background lifecycle",
)

one(
    "    private func pausePlayback(persistsQueue: Bool) {\n        wantsPlayback = false\n        cancelPlaybackRecovery()",
    "    private func pausePlayback(persistsQueue: Bool) {\n        wantsPlayback = false\n        cancelBackgroundTransitionVerification()\n        cancelPlaybackRecovery()",
    "pause",
)
one(
    "            wantsPlayback = false\n            cancelPlaybackRecovery()\n            markAudioSessionInactive()",
    "            wantsPlayback = false\n            cancelBackgroundTransitionVerification()\n            cancelPlaybackRecovery()\n            markAudioSessionInactive()",
    "interruption",
)
one(
    "    ) {\n        playbackSessionGeneration &+= 1\n        let sessionGeneration = playbackSessionGeneration",
    "    ) {\n        cancelBackgroundTransitionVerification()\n        playbackSessionGeneration &+= 1\n        let sessionGeneration = playbackSessionGeneration",
    "session",
)

p.write_text(s)
print("patched AudioEngine.swift")
