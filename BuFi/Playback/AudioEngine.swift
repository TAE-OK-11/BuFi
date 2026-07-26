import AVFoundation
import Combine
import MediaPlayer
import UIKit

@MainActor
final class AudioEngine: NSObject, ObservableObject {
    static let shared = AudioEngine()

    @Published private(set) var currentSong: Song?
    @Published private(set) var queue: [Song] = []
    @Published private(set) var queueIndex = -1
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var lyrics = LyricsDocument.empty
    @Published private(set) var activeLyricIndex = -1
    @Published var playbackError: String?
    @Published var showPlayer = false
    @Published var showFullLyrics = false
    @Published var isShuffleEnabled = false
    @Published var repeatMode: RepeatMode = .off
    @Published var quality: StreamQuality {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "stream-quality") }
    }

    let player = AVPlayer()

    private var nowPlayingSession: MPNowPlayingSession?
    private var client: OpenSubsonicClient?
    private var songFavoriteChangeHandler: ((Song, Bool) -> Void)?
    private var itemObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var itemObservers: [NSObjectProtocol] = []
    private var systemObservers: [NSObjectProtocol] = []
    private var fallbackIndex = 0
    private let fallbackFormats = ["aac", "mp3"]
    private var wantsPlayback = false
    private var scrobbled = false
    private var queueSaveTask: Task<Void, Never>?
    private var itemLoadTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var serverQueueTask: Task<Void, Never>?
    private var nowPlayingArtworkTask: Task<Void, Never>?
    private var nowPlayingSongID: String?
    private var nowPlayingArtworkSongID: String?
    private var resumeAfterInterruption = false
    private var activeCompatibilityFormat: String?
    private var recoveryTask: Task<Void, Never>?
    private var recoveryAttempt = 0
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var lastQueueSaveRequest = Date.distantPast
    private let queueStorageKey = "native-play-queue"

    override private init() {
        quality = StreamQuality(
            rawValue: UserDefaults.standard.string(forKey: "stream-quality") ?? ""
        ) ?? .automatic
        super.init()
        player.automaticallyWaitsToMinimizeStalling = true
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        nowPlayingSession = MPNowPlayingSession(players: [player])
        nowPlayingSession?.automaticallyPublishesNowPlayingInfo = false
        configureAudioSession()
        installPlayerObservers()
        installSystemObservers()
        installRemoteCommands()
        restoreLocalQueue()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        itemObservers.forEach(NotificationCenter.default.removeObserver)
        systemObservers.forEach(NotificationCenter.default.removeObserver)
        recoveryTask?.cancel()
        itemLoadTask?.cancel()
        nowPlayingArtworkTask?.cancel()
        endBackgroundBridge()
    }

    func configure(
        client: OpenSubsonicClient?,
        songFavoriteChangeHandler: ((Song, Bool) -> Void)? = nil
    ) {
        serverQueueTask?.cancel()
        self.client = client
        self.songFavoriteChangeHandler = songFavoriteChangeHandler
        if client == nil {
            queueSaveTask?.cancel()
            recoveryTask?.cancel()
            itemLoadTask?.cancel()
            UserDefaults.standard.removeObject(forKey: queueStorageKey)
            pause()
            currentSong = nil
            queue = []
            queueIndex = -1
            lyrics = .empty
            player.replaceCurrentItem(with: nil)
            updateNowPlaying()
            return
        }

        if let song = currentSong {
            loadCurrentItem()
            loadLyrics(for: song)
        }

        serverQueueTask = Task { [weak self] in
            guard let self,
                  let serverQueue = try? await client?.playQueue(),
                  !Task.isCancelled,
                  !serverQueue.songs.isEmpty,
                  !self.isPlaying else {
                return
            }
            self.queue = serverQueue.songs
            self.queueIndex = serverQueue.songs.firstIndex {
                $0.id == serverQueue.currentID
            } ?? 0
            self.currentSong = serverQueue.songs[self.queueIndex]
            self.elapsed = max(0, serverQueue.position)
            self.duration = self.currentSong?.safeDuration ?? 0
            self.lyrics = .empty
            self.activeLyricIndex = -1
            self.loadCurrentItem()
            if let song = self.currentSong { self.loadLyrics(for: song) }
            self.updateNowPlaying()
        }
    }

    func play(_ song: Song, in sourceQueue: [Song], autoplay: Bool = true) {
        startPlayback(song, in: sourceQueue, preferredIndex: nil, autoplay: autoplay)
    }

    private func startPlayback(
        _ song: Song,
        in sourceQueue: [Song],
        preferredIndex: Int?,
        autoplay: Bool = true
    ) {
        let normalizedQueue = sourceQueue.isEmpty ? [song] : sourceQueue
        queue = normalizedQueue
        if let preferredIndex, normalizedQueue.indices.contains(preferredIndex) {
            queueIndex = preferredIndex
        } else {
            queueIndex = normalizedQueue.firstIndex(where: { $0.id == song.id }) ?? 0
        }
        player.pause()
        itemObservation = nil
        itemObservers.forEach(NotificationCenter.default.removeObserver)
        itemObservers.removeAll()
        player.replaceCurrentItem(with: nil)
        currentSong = song
        elapsed = 0
        duration = song.safeDuration
        activeLyricIndex = -1
        lyrics = .empty
        fallbackIndex = 0
        recoveryAttempt = 0
        activeCompatibilityFormat = nil
        playbackError = nil
        wantsPlayback = autoplay
        scrobbled = false
        showPlayer = true
        loadCurrentItem()
        loadLyrics(for: song)
        scheduleQueueSave()
        updateNowPlaying()
    }

    func togglePlayback() {
        guard currentSong != nil else { return }
        if isPlaying || player.timeControlStatus == .playing {
            pause()
        } else {
            resumePlayback()
        }
    }

    func resumePlayback() {
        guard currentSong != nil else { return }
        configureAudioSession()
        wantsPlayback = true
        playbackError = nil
        player.isMuted = false
        player.volume = 1
        nowPlayingSession?.becomeActiveIfPossible()
        player.playImmediately(atRate: 1)
        updateNowPlaying()
    }

    func pause() {
        wantsPlayback = false
        player.pause()
        scheduleQueueSave(immediate: true)
    }

    func seek(to seconds: TimeInterval) {
        let target = max(0, min(seconds, duration))
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        elapsed = target
        updateActiveLyric()
        updateNowPlaying()
        scheduleQueueSave()
    }

    func next() {
        guard !queue.isEmpty else { return }
        if repeatMode == .one, let song = currentSong {
            startPlayback(song, in: queue, preferredIndex: queueIndex)
            return
        }

        if isShuffleEnabled, queue.count > 1 {
            var nextIndex = queueIndex
            while nextIndex == queueIndex {
                nextIndex = Int.random(in: queue.indices)
            }
            queueIndex = nextIndex
        } else if queueIndex < queue.count - 1 {
            queueIndex += 1
        } else if repeatMode == .all {
            queueIndex = 0
        } else {
            pause()
            return
        }
        startPlayback(queue[queueIndex], in: queue, preferredIndex: queueIndex)
    }

    func previous() {
        if elapsed > 4 {
            seek(to: 0)
            return
        }
        guard !queue.isEmpty else { return }
        queueIndex = queueIndex > 0 ? queueIndex - 1 : (repeatMode == .all ? queue.count - 1 : 0)
        startPlayback(queue[queueIndex], in: queue, preferredIndex: queueIndex)
    }

    func playQueueItem(at index: Int) {
        guard queue.indices.contains(index) else { return }
        queueIndex = index
        startPlayback(queue[index], in: queue, preferredIndex: index)
    }

    func removeQueueItem(at index: Int) {
        guard queue.indices.contains(index) else { return }
        if index == queueIndex {
            excludeCurrentAndAdvance()
            return
        }
        queue.remove(at: index)
        if index < queueIndex { queueIndex -= 1 }
        updateRemoteCommands()
        updateNowPlaying()
        scheduleQueueSave(immediate: true)
    }

    func excludeCurrentAndAdvance() {
        guard queue.indices.contains(queueIndex) else { return }
        let removedIndex = queueIndex
        queue.remove(at: removedIndex)
        guard !queue.isEmpty else {
            pause()
            currentSong = nil
            queueIndex = -1
            lyrics = .empty
            activeLyricIndex = -1
            player.replaceCurrentItem(with: nil)
            updateNowPlaying()
            scheduleQueueSave(immediate: true)
            return
        }
        queueIndex = min(removedIndex, queue.count - 1)
        startPlayback(queue[queueIndex], in: queue, preferredIndex: queueIndex)
    }

    func toggleShuffle() {
        isShuffleEnabled.toggle()
        updateRemoteCommands()
        scheduleQueueSave()
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        updateRemoteCommands()
        scheduleQueueSave()
    }

    func updateStarred(songID: String, enabled: Bool) {
        let value = enabled ? ISO8601DateFormatter().string(from: Date()) : nil
        if currentSong?.id == songID { currentSong?.starred = value }
        queue = queue.map { song in
            guard song.id == songID else { return song }
            var updated = song
            updated.starred = value
            return updated
        }
        let updatedCurrent = currentSong?.id == songID ? currentSong : nil
        if let updated = updatedCurrent ?? queue.first(where: { $0.id == songID }) {
            songFavoriteChangeHandler?(updated, enabled)
        }
        updateRemoteCommands()
        updateNowPlaying()
        scheduleQueueSave()
    }

    func toggleCurrentStar() async {
        guard let song = currentSong, let client else { return }
        let enabled = !song.isStarred
        do {
            try await client.star(id: song.id, target: .song, enabled: enabled)
            updateStarred(songID: song.id, enabled: enabled)
        } catch {
            playbackError = error.localizedDescription
        }
    }

    func localOrRemoteURL(for song: Song, compatibilityFormat: String? = nil) async throws -> URL {
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

    func downloadCurrent() async throws -> URL {
        guard let song = currentSong, let client else {
            throw OpenSubsonicError.invalidResponse
        }
        return try await OfflineStore.shared.download(song: song, client: client)
    }

    private func loadCurrentItem(compatibilityFormat: String? = nil) {
        guard let song = currentSong else { return }
        itemLoadTask?.cancel()
        activeCompatibilityFormat = compatibilityFormat
        isBuffering = true
        itemLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.localOrRemoteURL(
                    for: song,
                    compatibilityFormat: compatibilityFormat
                )
                guard !Task.isCancelled, self.currentSong?.id == song.id else { return }
                let mimeType: String?
                switch compatibilityFormat {
                case "aac": mimeType = "audio/aac"
                case "mp3": mimeType = "audio/mpeg"
                default: mimeType = song.contentType
                }
                self.replacePlayerItem(url: url, mimeType: mimeType)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.isBuffering = false
                self.handlePlaybackFailure()
            }
        }
    }

    private func replacePlayerItem(url: URL, mimeType: String?) {
        let position = elapsed
        // Amperfy uses an out-of-band MIME hint before handing Subsonic
        // streams to its player. Some servers omit or generalize Content-Type,
        // so applying the same GPLv3-covered compatibility pattern keeps
        // Core AVFoundation from rejecting an otherwise valid audio stream.
        let options: [String: Any] = mimeType.map {
            ["AVURLAssetOutOfBandMIMETypeKey": $0]
        } ?? [:]
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: options))
        item.preferredForwardBufferDuration = 20
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        installItemObservers(for: item)

        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.isBuffering = false
                    self.recoveryAttempt = 0
                    let seconds = item.duration.seconds
                    if seconds.isFinite, seconds > 0 { self.duration = seconds }
                    if position > 0 { self.seek(to: position) }
                    if self.wantsPlayback {
                        self.configureAudioSession()
                        self.player.isMuted = false
                        self.player.volume = 1
                        self.nowPlayingSession?.becomeActiveIfPossible()
                        self.player.playImmediately(atRate: 1)
                    }
                case .failed:
                    self.isBuffering = false
                    self.handlePlaybackFailure()
                default:
                    self.isBuffering = true
                }
            }
        }
        player.replaceCurrentItem(with: item)
    }

    private func installItemObservers(for item: AVPlayerItem) {
        itemObservers.forEach(NotificationCenter.default.removeObserver)
        itemObservers.removeAll()
        let center = NotificationCenter.default
        itemObservers.append(center.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.schedulePlaybackRecovery() }
        })
        itemObservers.append(center.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handlePlaybackFailure() }
        })
    }

    private func handlePlaybackFailure() {
        guard currentSong != nil else { return }
        guard fallbackFormats.indices.contains(fallbackIndex) else {
            wantsPlayback = false
            isPlaying = false
            isBuffering = false
            playbackError = String(
                localized: "이 음악을 재생하지 못했습니다. 서버의 스트리밍 형식과 네트워크 상태를 확인해 주세요."
            )
            return
        }
        let format = fallbackFormats[fallbackIndex]
        fallbackIndex += 1
        activeCompatibilityFormat = format
        loadCurrentItem(compatibilityFormat: format)
    }

    private func schedulePlaybackRecovery() {
        guard wantsPlayback, currentSong != nil, recoveryTask == nil else { return }
        isBuffering = true
        recoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self else { return }
            defer { self.recoveryTask = nil }
            guard !Task.isCancelled, self.wantsPlayback else { return }

            self.configureAudioSession()
            self.player.playImmediately(atRate: 1)
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }

            if self.player.timeControlStatus != .playing, self.wantsPlayback {
                self.recoveryAttempt += 1
                if self.recoveryAttempt <= 2 {
                    self.loadCurrentItem(compatibilityFormat: self.activeCompatibilityFormat)
                } else {
                    self.handlePlaybackFailure()
                }
            }
        }
    }

    private func loadLyrics(for song: Song) {
        lyricsTask?.cancel()
        guard let client else { return }
        lyricsTask = Task { [weak self] in
            do {
                let document = try await client.lyrics(songID: song.id)
                guard !Task.isCancelled, self?.currentSong?.id == song.id else { return }
                self?.lyrics = document
                self?.updateActiveLyric()
            } catch {
                guard !Task.isCancelled else { return }
                self?.lyrics = .empty
            }
        }
    }

    private func installPlayerObservers() {
        timeControlObservation = player.observe(
            \.timeControlStatus,
            options: [.initial, .new]
        ) { [weak self] player, _ in
            Task { @MainActor in
                self?.isPlaying = player.timeControlStatus == .playing
                self?.isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                if player.timeControlStatus == .playing {
                    self?.recoveryTask?.cancel()
                    self?.recoveryTask = nil
                    self?.endBackgroundBridge()
                }
                self?.updateRemoteCommands()
                self?.updateNowPlaying()
            }
        }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                let seconds = time.seconds
                if seconds.isFinite { self.elapsed = max(0, seconds) }
                if let itemDuration = self.player.currentItem?.duration.seconds,
                   itemDuration.isFinite,
                   itemDuration > 0 {
                    self.duration = itemDuration
                }
                self.updateActiveLyric()
                self.submitScrobbleIfNeeded()
                if Date().timeIntervalSince(self.lastQueueSaveRequest) >= 15 {
                    self.scheduleQueueSave(immediate: true)
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.next() }
        }
    }

    private func updateActiveLyric() {
        guard lyrics.synced, !lyrics.lines.isEmpty else {
            activeLyricIndex = lyrics.lines.isEmpty ? -1 : 0
            return
        }
        let index = lyrics.lines.lastIndex(where: { $0.start <= elapsed }) ?? -1
        if activeLyricIndex != index { activeLyricIndex = index }
    }

    @discardableResult
    private func configureAudioSession() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playback,
                mode: .default,
                policy: .longFormAudio
            )
            try session.setActive(true)
            player.isMuted = false
            player.volume = 1
            return true
        } catch {
            // A later play attempt and the route/interruption observers retry.
            // Keeping this nonfatal is important while another app owns output.
            return false
        }
    }

    private func installSystemObservers() {
        let center = NotificationCenter.default
        systemObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in self?.handleAudioInterruption(notification) }
        })
        systemObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in self?.handleRouteChange(notification) }
        })
        systemObservers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.configureAudioSession()
                if self.currentSong != nil {
                    self.loadCurrentItem()
                }
            }
        })
        systemObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleDidEnterBackground() }
        })
        systemObservers.append(center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.preserveActivePlayback() }
        })
        systemObservers.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.wantsPlayback else { return }
                self.preserveActivePlayback()
            }
        })
    }

    private func handleDidEnterBackground() {
        scheduleQueueSave(immediate: true)
        guard wantsPlayback else { return }
        beginBackgroundBridge()
        preserveActivePlayback()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self else { return }
            guard self.wantsPlayback,
                  self.player.timeControlStatus != .playing else {
                self.endBackgroundBridge()
                return
            }
            self.schedulePlaybackRecovery()
        }
    }

    private func preserveActivePlayback() {
        guard wantsPlayback, currentSong != nil else { return }
        configureAudioSession()
        player.isMuted = false
        player.volume = 1
        player.playImmediately(atRate: 1)
        updateNowPlaying()
    }

    private func beginBackgroundBridge() {
        endBackgroundBridge()
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "BuFiPlaybackTransition"
        ) { [weak self] in
            Task { @MainActor in self?.endBackgroundBridge() }
        }
    }

    private func endBackgroundBridge() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard let rawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawValue) else {
            return
        }
        switch type {
        case .began:
            resumeAfterInterruption = isPlaying || wantsPlayback
            wantsPlayback = false
            player.pause()
            scheduleQueueSave(immediate: true)
        case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            guard resumeAfterInterruption, options.contains(.shouldResume) else {
                resumeAfterInterruption = false
                return
            }
            resumeAfterInterruption = false
            configureAudioSession()
            wantsPlayback = true
            player.playImmediately(atRate: 1)
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let rawValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawValue) else {
            return
        }
        switch reason {
        case .oldDeviceUnavailable, .newDeviceAvailable, .routeConfigurationChange:
            let shouldContinue = isPlaying || wantsPlayback
            configureAudioSession()
            if shouldContinue {
                wantsPlayback = true
                player.playImmediately(atRate: 1)
            }
        default:
            break
        }
    }

    private func installRemoteCommands() {
        let commands = remoteCommandCenter
        commands.playCommand.isEnabled = true
        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.resumePlayback()
            }
            return .success
        }
        commands.pauseCommand.isEnabled = true
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        commands.togglePlayPauseCommand.isEnabled = true
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayback() }
            return .success
        }
        commands.stopCommand.isEnabled = false

        commands.nextTrackCommand.isEnabled = true
        commands.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        commands.previousTrackCommand.isEnabled = true
        commands.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }

        commands.changeShuffleModeCommand.isEnabled = true
        commands.changeShuffleModeCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangeShuffleModeCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in
                guard let self else { return }
                let requested = event.shuffleType != .off
                if self.isShuffleEnabled != requested { self.toggleShuffle() }
            }
            return .success
        }

        commands.changeRepeatModeCommand.isEnabled = true
        commands.changeRepeatModeCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangeRepeatModeCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in
                guard let self else { return }
                switch event.repeatType {
                case .one: self.repeatMode = .one
                case .all: self.repeatMode = .all
                default: self.repeatMode = .off
                }
                self.scheduleQueueSave()
                self.updateRemoteCommands()
            }
            return .success
        }

        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
        commands.changePlaybackPositionCommand.isEnabled = true

        commands.likeCommand.localizedTitle = String(localized: "좋아요")
        commands.likeCommand.isEnabled = true
        commands.likeCommand.addTarget { [weak self] _ in
            Task { @MainActor in await self?.toggleCurrentStar() }
            return .success
        }

        commands.skipBackwardCommand.isEnabled = false
        commands.skipForwardCommand.isEnabled = false
        commands.changePlaybackRateCommand.isEnabled = false
        updateRemoteCommands()
    }

    private func updateRemoteCommands() {
        let commands = remoteCommandCenter
        let hasSong = currentSong != nil
        commands.playCommand.isEnabled = hasSong && !isPlaying
        commands.pauseCommand.isEnabled = hasSong && isPlaying
        commands.togglePlayPauseCommand.isEnabled = hasSong
        commands.nextTrackCommand.isEnabled = hasSong && queue.count > 1
        commands.previousTrackCommand.isEnabled = hasSong
        commands.changePlaybackPositionCommand.isEnabled = hasSong && duration > 0
        commands.changeShuffleModeCommand.isEnabled = hasSong && queue.count > 1
        commands.changeShuffleModeCommand.currentShuffleType = isShuffleEnabled ? .items : .off
        commands.changeRepeatModeCommand.isEnabled = hasSong
        switch repeatMode {
        case .off: commands.changeRepeatModeCommand.currentRepeatType = .off
        case .all: commands.changeRepeatModeCommand.currentRepeatType = .all
        case .one: commands.changeRepeatModeCommand.currentRepeatType = .one
        }
        commands.likeCommand.isEnabled = hasSong
        commands.likeCommand.isActive = currentSong?.isStarred ?? false
    }

    private func updateNowPlaying() {
        guard let song = currentSong else {
            nowPlayingArtworkTask?.cancel()
            nowPlayingSongID = nil
            nowPlayingArtworkSongID = nil
            nowPlayingInfoCenter.nowPlayingInfo = nil
            return
        }
        let songChanged = nowPlayingSongID != song.id
        if songChanged {
            nowPlayingArtworkTask?.cancel()
            nowPlayingSongID = song.id
            nowPlayingArtworkSongID = nil
        }
        var info = songChanged ? [:] : (nowPlayingInfoCenter.nowPlayingInfo ?? [:])
        info[MPNowPlayingInfoPropertyMediaType] = NSNumber(
            value: MPNowPlayingInfoMediaType.audio.rawValue
        )
        info[MPNowPlayingInfoPropertyServiceIdentifier] = "BuFi"
        info[MPNowPlayingInfoPropertyExternalContentIdentifier] = song.id
        info[MPMediaItemPropertyPersistentID] = persistentID(for: song.id)
        info[MPMediaItemPropertyIsCloudItem] = true
        info[MPMediaItemPropertyTitle] = song.title
        info[MPMediaItemPropertyArtist] = song.artist
        info[MPMediaItemPropertyAlbumTitle] = song.album
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyPlaybackQueueCount] = queue.count
        info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = max(0, queueIndex)
        nowPlayingInfoCenter.nowPlayingInfo = info
        nowPlayingSession?.becomeActiveIfPossible()
        updateRemoteCommands()

        guard nowPlayingArtworkSongID != song.id,
              let coverID = song.coverArt,
              let client else {
            return
        }
        nowPlayingArtworkSongID = song.id
        nowPlayingArtworkTask = Task {
            guard let url = try? await client.coverURL(id: coverID, size: 600),
                  let image = try? await ArtworkStore.shared.image(for: url, pixelSize: 600),
                  !Task.isCancelled,
                  self.currentSong?.id == song.id else {
                return
            }
            var refreshed = self.nowPlayingInfoCenter.nowPlayingInfo ?? [:]
            refreshed[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(
                boundsSize: image.size
            ) { _ in image }
            self.nowPlayingInfoCenter.nowPlayingInfo = refreshed
        }
    }

    private var remoteCommandCenter: MPRemoteCommandCenter {
        nowPlayingSession?.remoteCommandCenter ?? .shared()
    }

    private var nowPlayingInfoCenter: MPNowPlayingInfoCenter {
        nowPlayingSession?.nowPlayingInfoCenter ?? .default()
    }

    private func persistentID(for value: String) -> NSNumber {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return NSNumber(value: hash)
    }

    private func submitScrobbleIfNeeded() {
        guard !scrobbled,
              let song = currentSong,
              elapsed >= min(max(30, duration * 0.5), 240),
              let client else {
            return
        }
        scrobbled = true
        Task { try? await client.scrobble(id: song.id, submission: true) }
    }

    private func scheduleQueueSave(immediate: Bool = false) {
        queueSaveTask?.cancel()
        lastQueueSaveRequest = Date()
        let snapshot = QueueSnapshot(
            queue: queue,
            currentID: currentSong?.id,
            index: queueIndex,
            elapsed: elapsed,
            shuffle: isShuffleEnabled,
            repeatMode: repeatMode
        )
        queueSaveTask = Task {
            if !immediate { try? await Task.sleep(for: .milliseconds(450)) }
            guard !Task.isCancelled,
                  let data = try? JSONEncoder().encode(snapshot) else {
                return
            }
            UserDefaults.standard.set(data, forKey: queueStorageKey)
            guard let client,
                  let current = snapshot.currentID,
                  !snapshot.queue.isEmpty else {
                return
            }
            try? await client.savePlayQueue(
                songIDs: snapshot.queue.map(\.id),
                current: current,
                position: snapshot.elapsed
            )
        }
    }

    private func restoreLocalQueue() {
        guard let data = UserDefaults.standard.data(forKey: queueStorageKey),
              let snapshot = try? JSONDecoder().decode(QueueSnapshot.self, from: data),
              !snapshot.queue.isEmpty else {
            return
        }
        queue = snapshot.queue
        queueIndex = snapshot.queue.indices.contains(snapshot.index) ? snapshot.index : 0
        currentSong = snapshot.queue.first(where: { $0.id == snapshot.currentID }) ?? snapshot.queue[queueIndex]
        elapsed = snapshot.elapsed
        duration = currentSong?.safeDuration ?? 0
        isShuffleEnabled = snapshot.shuffle
        repeatMode = snapshot.repeatMode
    }
}

private struct QueueSnapshot: Codable, Sendable {
    let queue: [Song]
    let currentID: String?
    let index: Int
    let elapsed: TimeInterval
    let shuffle: Bool
    let repeatMode: RepeatMode
}
