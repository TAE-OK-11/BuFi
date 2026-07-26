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
    @Published var showPlayer = false
    @Published var showFullLyrics = false
    @Published var isShuffleEnabled = false
    @Published var repeatMode: RepeatMode = .off
    @Published var quality: StreamQuality {
        didSet { UserDefaults.standard.set(quality.rawValue, forKey: "stream-quality") }
    }

    let player = AVPlayer()

    private var client: OpenSubsonicClient?
    private var itemObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var fallbackIndex = 0
    private let fallbackFormats = ["aac", "mp3"]
    private var wantsPlayback = false
    private var scrobbled = false
    private var queueSaveTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var serverQueueTask: Task<Void, Never>?
    private let queueStorageKey = "native-play-queue"

    override private init() {
        quality = StreamQuality(
            rawValue: UserDefaults.standard.string(forKey: "stream-quality") ?? ""
        ) ?? .automatic
        super.init()
        configureAudioSession()
        installPlayerObservers()
        installRemoteCommands()
        restoreLocalQueue()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func configure(client: OpenSubsonicClient?) {
        serverQueueTask?.cancel()
        self.client = client
        if client == nil {
            pause()
            currentSong = nil
            queue = []
            queueIndex = -1
            lyrics = .empty
            player.replaceCurrentItem(with: nil)
            return
        }

        if let song = currentSong {
            loadCurrentItem(autoplay: false)
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
            self.loadCurrentItem(autoplay: false)
            if let song = self.currentSong { self.loadLyrics(for: song) }
            self.updateNowPlaying()
        }
    }

    func play(_ song: Song, in sourceQueue: [Song], autoplay: Bool = true) {
        let normalizedQueue = sourceQueue.isEmpty ? [song] : sourceQueue
        queue = normalizedQueue
        queueIndex = normalizedQueue.firstIndex(where: { $0.id == song.id }) ?? 0
        currentSong = song
        elapsed = 0
        duration = song.safeDuration
        activeLyricIndex = -1
        lyrics = .empty
        fallbackIndex = 0
        wantsPlayback = autoplay
        scrobbled = false
        showPlayer = true
        loadCurrentItem(autoplay: autoplay)
        loadLyrics(for: song)
        scheduleQueueSave()
        updateNowPlaying()
    }

    func togglePlayback() {
        guard currentSong != nil else { return }
        if isPlaying || player.timeControlStatus == .playing {
            pause()
        } else {
            wantsPlayback = true
            player.play()
        }
    }

    func pause() {
        wantsPlayback = false
        player.pause()
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
            play(song, in: queue)
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
        play(queue[queueIndex], in: queue)
    }

    func previous() {
        if elapsed > 4 {
            seek(to: 0)
            return
        }
        guard !queue.isEmpty else { return }
        queueIndex = queueIndex > 0 ? queueIndex - 1 : (repeatMode == .all ? queue.count - 1 : 0)
        play(queue[queueIndex], in: queue)
    }

    func playQueueItem(at index: Int) {
        guard queue.indices.contains(index) else { return }
        queueIndex = index
        play(queue[index], in: queue)
    }

    func toggleShuffle() {
        isShuffleEnabled.toggle()
        scheduleQueueSave()
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        scheduleQueueSave()
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

    private func loadCurrentItem(autoplay: Bool, compatibilityFormat: String? = nil) {
        guard let song = currentSong else { return }
        isBuffering = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.localOrRemoteURL(
                    for: song,
                    compatibilityFormat: compatibilityFormat
                )
                guard self.currentSong?.id == song.id else { return }
                self.replacePlayerItem(url: url, autoplay: autoplay)
            } catch {
                self.isBuffering = false
                self.handlePlaybackFailure()
            }
        }
    }

    private func replacePlayerItem(url: URL, autoplay: Bool) {
        let position = elapsed
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 12
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false

        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self else { return }
                switch item.status {
                case .readyToPlay:
                    self.isBuffering = false
                    let seconds = item.duration.seconds
                    if seconds.isFinite, seconds > 0 { self.duration = seconds }
                    if position > 0 { self.seek(to: position) }
                    if autoplay || self.wantsPlayback { self.player.play() }
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

    private func handlePlaybackFailure() {
        guard currentSong != nil else { return }
        guard fallbackFormats.indices.contains(fallbackIndex) else {
            wantsPlayback = false
            isPlaying = false
            isBuffering = false
            return
        }
        let format = fallbackFormats[fallbackIndex]
        fallbackIndex += 1
        loadCurrentItem(autoplay: wantsPlayback, compatibilityFormat: format)
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

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playback,
                mode: .default,
                policy: .longFormAudio,
                options: [.allowAirPlay]
            )
            try session.setActive(true)
        } catch {
            // Playback can still be attempted; the UI surfaces AVPlayer failures.
        }
    }

    private func installRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                self?.wantsPlayback = true
                self?.player.play()
            }
            return .success
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        commands.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in self?.seek(to: event.positionTime) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let song = currentSong else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = song.title
        info[MPMediaItemPropertyArtist] = song.artist
        info[MPMediaItemPropertyAlbumTitle] = song.album
        info[MPMediaItemPropertyPlaybackDuration] = duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        guard info[MPMediaItemPropertyArtwork] == nil,
              let coverID = song.coverArt,
              let client else {
            return
        }
        Task {
            guard let url = try? await client.coverURL(id: coverID, size: 600),
                  let image = try? await ArtworkStore.shared.image(for: url, pixelSize: 600),
                  self.currentSong?.id == song.id else {
                return
            }
            var refreshed = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            refreshed[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(
                boundsSize: image.size
            ) { _ in image }
            MPNowPlayingInfoCenter.default().nowPlayingInfo = refreshed
        }
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

    private func scheduleQueueSave() {
        queueSaveTask?.cancel()
        let snapshot = QueueSnapshot(
            queue: queue,
            currentID: currentSong?.id,
            index: queueIndex,
            elapsed: elapsed,
            shuffle: isShuffleEnabled,
            repeatMode: repeatMode
        )
        queueSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
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
