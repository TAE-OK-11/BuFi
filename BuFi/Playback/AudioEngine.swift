import AVFoundation
import Combine
import MediaPlayer
import Network
import OSLog
import UIKit

/// Owns AVPlayer and NotificationCenter tokens as one lifecycle unit. All
/// mutations are performed by AudioEngine on the main actor.
@MainActor
private final class PlaybackObserverCoordinator {
    private let player: AVPlayer
    private let notificationCenter: NotificationCenter
    private var periodicTimeObserver: Any?
    private var lyricBoundaryObserver: Any?
    private var itemNotifications: [NSObjectProtocol] = []
    private var systemNotifications: [NSObjectProtocol] = []

    init(
        player: AVPlayer,
        notificationCenter: NotificationCenter = .default
    ) {
        self.player = player
        self.notificationCenter = notificationCenter
    }

    func replacePeriodicTimeObserver(
        interval: CMTime,
        handler: @escaping @Sendable (CMTime) -> Void
    ) {
        removePeriodicTimeObserver()
        periodicTimeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main,
            using: handler
        )
    }

    func removePeriodicTimeObserver() {
        guard let periodicTimeObserver else { return }
        player.removeTimeObserver(periodicTimeObserver)
        self.periodicTimeObserver = nil
    }

    func replaceLyricBoundaryObserver(
        time: CMTime?,
        handler: @escaping @Sendable () -> Void
    ) {
        removeLyricBoundaryObserver()
        guard let time else { return }
        lyricBoundaryObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: time)],
            queue: .main,
            using: handler
        )
    }

    func removeLyricBoundaryObserver() {
        guard let lyricBoundaryObserver else { return }
        player.removeTimeObserver(lyricBoundaryObserver)
        self.lyricBoundaryObserver = nil
    }

    func replaceItemNotifications(
        _ install: (NotificationCenter) -> [NSObjectProtocol]
    ) {
        removeItemNotifications()
        itemNotifications = install(notificationCenter)
    }

    func removeItemNotifications() {
        itemNotifications.forEach(notificationCenter.removeObserver)
        itemNotifications.removeAll(keepingCapacity: true)
    }

    func installSystemNotificationsIfNeeded(
        _ install: (NotificationCenter) -> [NSObjectProtocol]
    ) {
        guard systemNotifications.isEmpty else { return }
        systemNotifications = install(notificationCenter)
    }

}

@MainActor
final class PlaybackTimeline: ObservableObject {
    // Kept outside AudioEngine's publisher so a 4 Hz progress tick does not
    // invalidate artwork, palette backgrounds, queue controls, and the app root.
    @Published fileprivate(set) var elapsed: TimeInterval = 0
    @Published fileprivate(set) var duration: TimeInterval = 0
}

@MainActor
final class LyricsPlaybackState: ObservableObject {
    // Lyric highlighting has its own render boundary for the same reason.
    @Published fileprivate(set) var document = LyricsDocument.empty
    @Published fileprivate(set) var activeIndex = -1
}

@MainActor
final class PlaybackItemState: ObservableObject {
    @Published fileprivate(set) var currentSong: Song?

    fileprivate func setCurrentSong(_ value: Song?) {
        guard currentSong != value else { return }
        currentSong = value
    }
}

@MainActor
final class PlaybackActivityState: ObservableObject {
    @Published fileprivate(set) var isPlaying = false

    fileprivate func setPlaying(_ value: Bool) {
        guard isPlaying != value else { return }
        isPlaying = value
    }
}

@MainActor
final class PlaybackControlState: ObservableObject {
    @Published fileprivate(set) var isBuffering = false
    @Published fileprivate(set) var wantsPlayback = false

    fileprivate func setBuffering(_ value: Bool) {
        guard isBuffering != value else { return }
        isBuffering = value
    }

    fileprivate func setWantsPlayback(_ value: Bool) {
        guard wantsPlayback != value else { return }
        wantsPlayback = value
    }
}

@MainActor
final class PlaybackQueueState: ObservableObject {
    @Published fileprivate(set) var songs: [Song] = []
    @Published fileprivate(set) var index = -1

    fileprivate func setSongs(_ value: [Song]) {
        guard songs != value else { return }
        songs = value
    }

    fileprivate func setIndex(_ value: Int) {
        guard index != value else { return }
        index = value
    }
}

@MainActor
final class PlayerPresentationState: ObservableObject {
    @Published var playbackError: String?
    @Published fileprivate(set) var showPlayer = false
    @Published fileprivate(set) var presentationID = UUID()
    @Published var showFullLyrics = false

    func setShowPlayer(_ value: Bool) {
        guard showPlayer != value else { return }
        if value {
            // A new identity prevents SwiftUI from resurrecting the previous
            // full-screen cover's pager state on a later presentation.
            presentationID = UUID()
        } else {
            showFullLyrics = false
        }
        showPlayer = value
    }
}

/// Pure queue snapshot used to keep speculative transfers away from the
/// critical path of starting or recovering the current stream.
struct PlaybackPrefetchPlan: Equatable, Sendable {
    struct Key: Equatable, Sendable {
        let currentSongID: String
        let upcomingSongIDs: [String]
        let quality: String
    }

    let key: Key
    let upcomingSongs: [Song]

    static func make(
        currentSong: Song?,
        queue: [Song],
        queueIndex: Int,
        quality: StreamQuality,
        maximumUpcoming: Int,
        isActivelyPlaying: Bool
    ) -> PlaybackPrefetchPlan? {
        guard isActivelyPlaying,
              maximumUpcoming > 0,
              let currentSong,
              queue.indices.contains(queueIndex),
              queue[queueIndex].id == currentSong.id,
              queueIndex + 1 < queue.count else {
            return nil
        }

        let upcoming = Array(
            queue[(queueIndex + 1)...]
                .lazy
                .filter { $0.externalStreamURL == nil }
                .prefix(maximumUpcoming)
        )
        guard !upcoming.isEmpty else { return nil }
        return PlaybackPrefetchPlan(
            key: Key(
                currentSongID: currentSong.id,
                upcomingSongIDs: upcoming.map(\.id),
                quality: quality.rawValue
            ),
            upcomingSongs: upcoming
        )
    }
}

@MainActor
final class AudioEngine: NSObject, ObservableObject {
    static let shared = AudioEngine()

    let itemState = PlaybackItemState()
    let activityState = PlaybackActivityState()
    let controlState = PlaybackControlState()
    let queueState = PlaybackQueueState()
    let presentation = PlayerPresentationState()
    let timeline = PlaybackTimeline()
    let lyricsState = LyricsPlaybackState()

    private(set) var currentSong: Song? {
        get { itemState.currentSong }
        set { itemState.setCurrentSong(newValue) }
    }

    private(set) var queue: [Song] {
        get { queueState.songs }
        set { queueState.setSongs(newValue) }
    }

    private(set) var queueIndex: Int {
        get { queueState.index }
        set { queueState.setIndex(newValue) }
    }

    private(set) var isPlaying: Bool {
        get { activityState.isPlaying }
        set { activityState.setPlaying(newValue) }
    }

    private(set) var isBuffering: Bool {
        get { controlState.isBuffering }
        set { controlState.setBuffering(newValue) }
    }

    private(set) var wantsPlayback: Bool {
        get { controlState.wantsPlayback }
        set { controlState.setWantsPlayback(newValue) }
    }

    private(set) var elapsed: TimeInterval {
        get { timeline.elapsed }
        set {
            if timeline.elapsed != newValue {
                timeline.elapsed = newValue
            }
        }
    }
    private(set) var duration: TimeInterval {
        get { timeline.duration }
        set {
            if timeline.duration != newValue {
                timeline.duration = newValue
            }
        }
    }
    private(set) var lyrics: LyricsDocument {
        get { lyricsState.document }
        set { lyricsState.document = newValue }
    }
    private(set) var activeLyricIndex: Int {
        get { lyricsState.activeIndex }
        set {
            if lyricsState.activeIndex != newValue {
                lyricsState.activeIndex = newValue
            }
        }
    }
    var playbackError: String? {
        get { presentation.playbackError }
        set {
            guard presentation.playbackError != newValue else { return }
            presentation.playbackError = newValue
        }
    }
    var showPlayer: Bool {
        get { presentation.showPlayer }
        set {
            guard presentation.showPlayer != newValue else { return }
            presentation.setShowPlayer(newValue)
            installPlaybackTimeObserver()
        }
    }
    var showFullLyrics: Bool {
        get { presentation.showFullLyrics }
        set {
            guard presentation.showFullLyrics != newValue else { return }
            presentation.showFullLyrics = newValue
        }
    }
    @Published var isShuffleEnabled = false
    @Published var shuffleStyle: ShuffleStyle {
        didSet {
            UserDefaults.standard.set(
                shuffleStyle.rawValue,
                forKey: "shuffle-style"
            )
        }
    }
    @Published var repeatMode: RepeatMode = .off
    @Published var quality: StreamQuality {
        didSet {
            UserDefaults.standard.set(quality.rawValue, forKey: "stream-quality")
            guard oldValue != quality, currentSong != nil else { return }
            suspendSpeculativePrefetch()
            restartPlaybackPlan(resumeFrom: elapsed)
        }
    }

    let player = AVPlayer()

    private static let iso8601Formatter = ISO8601DateFormatter()
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BuFi",
        category: "Playback"
    )

    private struct PlaybackResource {
        let url: URL
        let mimeType: String?
    }

    private struct PreparedPlaybackAsset {
        let key: String
        let songID: String
        let compatibilityFormat: String
        let asset: AVURLAsset
    }

    private var nowPlayingSession: MPNowPlayingSession?
    private var client: OpenSubsonicClient?
    private var songFavoriteMutationHandler: (@MainActor (Song) async -> Bool)?
    private var autoplayContinuationProvider:
        (@MainActor (Song, Set<String>) async -> [Song])?
    private var itemObservation: NSKeyValueObservation?
    private var itemBufferObservations: [NSKeyValueObservation] = []
    private var timeControlObservation: NSKeyValueObservation?
    private lazy var playbackObservers = PlaybackObserverCoordinator(
        player: player
    )
    private let networkPathMonitor = NWPathMonitor()
    private let networkPathQueue = DispatchQueue(
        label: "cloud.tae00217.BuFi.prefetch-network-path",
        qos: .utility
    )
    private var fallbackIndex = 0
    private var fallbackFormats: [String] = []
    private var scrobbled = false
    private var queueSaveTask: Task<Void, Never>?
    private var itemLoadTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var serverQueueTask: Task<Void, Never>?
    private var nowPlayingArtworkTask: Task<Void, Never>?
    private var offlinePrefetchTask: Task<Void, Never>?
    private var networkPrefetchTask: Task<Void, Never>?
    private var networkPrefetchToken: UUID?
    private var offlinePrefetchToken: UUID?
    private var lastNetworkPrefetchKey: PlaybackPrefetchPlan.Key?
    private var lastOfflinePrefetchKey: PlaybackPrefetchPlan.Key?
    private var preparedPlaybackAssets: [String: PreparedPlaybackAsset] = [:]
    private var preparedPlaybackAssetOrder: [String] = []
    private var preparedPlaybackWarmupTasks: [String: Task<Void, Never>] = [:]
    private var autoplayTask: Task<Void, Never>?
    private var historyMutationTask: Task<Void, Never>?
    private var nowPlayingSongID: String?
    private var nowPlayingArtworkKey: String?
    private var resumeAfterInterruption = false
    private var activeCompatibilityFormat: String?
    private var recoveryTask: Task<Void, Never>?
    private var audioSessionActivationTask: Task<Void, Never>?
    private var audioSessionActivationToken: UUID?
    private var audioSessionDeactivationTask: Task<Void, Never>?
    private var audioSessionCommandEpoch: UInt64 = 0
    private var nowPlayingActivationTask: Task<Void, Never>?
    private let audioSessionController = AudioSessionController()
    private var recoveryToken: UUID?
    private weak var handledFailedItem: AVPlayerItem?
    private var recoveryAttempt = 0
    private var itemLoadGeneration: UInt64 = 0
    private var lyricsLoadGeneration: UInt64 = 0
    private var seekGeneration: UInt64 = 0
    private var itemObserverGeneration: UInt64 = 0
    private var timelineObserverGeneration: UInt64 = 0
    private var lyricBoundaryGeneration: UInt64 = 0
    private var autoplayGeneration: UInt64 = 0
    private var isSeekInFlight = false
    private var autoplayShouldAdvance = false
    private var recentShuffleIDs: [String] = []
    private var pendingSeekPosition: TimeInterval?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var lastQueueSaveRequest = Date.distantPast
    private var lastMaintenanceSecond = -1
    private var behaviorStartRecordedForSongID: String?
    private var lastPlaybackReportSongID: String?
    private var lastPlaybackReportState: String?
    private let queueStorageKey = "native-play-queue"
    private var queueRestoreTask: Task<Void, Never>?
    private var lastPersistedQueue: [Song]?
    private var allowsSpeculativeNetworkPrefetch = false

    override private init() {
        quality = StreamQuality(
            rawValue: UserDefaults.standard.string(forKey: "stream-quality") ?? ""
        ) ?? .automatic
        shuffleStyle = ShuffleStyle(
            rawValue: UserDefaults.standard.string(forKey: "shuffle-style") ?? ""
        ) ?? .fewerRepeats
        super.init()
        player.automaticallyWaitsToMinimizeStalling = true
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        nowPlayingSession = MPNowPlayingSession(players: [player])
        nowPlayingSession?.automaticallyPublishesNowPlayingInfo = false
        installPlayerObservers()
        installSystemObservers()
        installNetworkPathMonitor()
        installRemoteCommands()
        if queueRestorationEnabled {
            restoreLocalQueue()
        }
    }

    func configure(
        client: OpenSubsonicClient?,
        songFavoriteMutationHandler: (@MainActor (Song) async -> Bool)? = nil,
        autoplayContinuationProvider:
            (@MainActor (Song, Set<String>) async -> [Song])? = nil
    ) {
        serverQueueTask?.cancel()
        serverQueueTask = nil
        autoplayTask?.cancel()
        autoplayTask = nil
        autoplayGeneration &+= 1
        autoplayShouldAdvance = false
        self.client = client
        self.songFavoriteMutationHandler = songFavoriteMutationHandler
        self.autoplayContinuationProvider = autoplayContinuationProvider
        if client == nil {
            finalizeCurrentPlayback(reason: .stopped)
            queueSaveTask?.cancel()
            queueSaveTask = nil
            suspendSpeculativePrefetch()
            cancelPlaybackRecovery()
            itemLoadTask?.cancel()
            itemLoadTask = nil
            lyricsTask?.cancel()
            lyricsTask = nil
            nowPlayingArtworkTask?.cancel()
            nowPlayingArtworkTask = nil
            itemLoadGeneration &+= 1
            lyricsLoadGeneration &+= 1
            seekGeneration &+= 1
            isSeekInFlight = false
            pendingSeekPosition = nil
            UserDefaults.standard.removeObject(forKey: queueStorageKey)
            lastPersistedQueue = nil
            queueRestoreTask?.cancel()
            queueRestoreTask = nil
            Task { await AppDatabase.shared.clearQueue() }
            pausePlayback(persistsQueue: false)
            currentSong = nil
            queue = []
            queueIndex = -1
            elapsed = 0
            duration = 0
            isBuffering = false
            playbackError = nil
            showFullLyrics = false
            applyLyricsDocument(.empty)
            removeCurrentItemObservers()
            player.replaceCurrentItem(with: nil)
            updateNowPlaying()
            return
        }

        if let song = currentSong {
            restartPlaybackPlan(resumeFrom: elapsed)
            loadLyrics(for: song)
        }

        guard queueRestorationEnabled else { return }
        serverQueueTask = Task { [weak self] in
            guard let self,
                  let serverQueue = try? await client?.playQueue(),
                  !Task.isCancelled,
                  !serverQueue.songs.isEmpty,
                  !self.isPlaying,
                  !self.wantsPlayback else {
                return
            }
            self.queue = serverQueue.songs
            self.queueIndex = serverQueue.songs.firstIndex {
                $0.id == serverQueue.currentID
            } ?? 0
            self.currentSong = serverQueue.songs[self.queueIndex]
            self.behaviorStartRecordedForSongID = nil
            self.duration = self.currentSong?.safeDuration ?? 0
            let restoredPosition = max(0, serverQueue.position)
            self.elapsed = self.duration > 0 ? min(restoredPosition, self.duration) : restoredPosition
            self.applyLyricsDocument(.empty)
            self.restartPlaybackPlan(resumeFrom: self.elapsed)
            if let song = self.currentSong { self.loadLyrics(for: song) }
            self.updateNowPlaying()
        }
    }

    /// Ends the current account session in a deterministic order. The final
    /// behavior sample is committed before the listening store is detached,
    /// and the queue is cleared only after every older save task is cancelled.
    func shutdownForSessionEnd() async {
        finalizeCurrentPlayback(reason: .stopped)
        let finalHistoryMutation = historyMutationTask
        let pendingQueueSave = queueSaveTask
        configure(client: nil)
        // Cancellation cannot interrupt a GRDB transaction that has already
        // started. Wait for the old save task before the final delete so a
        // late account-session snapshot can never recreate the queue.
        _ = await pendingQueueSave?.value
        _ = await finalHistoryMutation?.value
        historyMutationTask = nil
        await AppDatabase.shared.clearQueue()
    }

    func play(
        _ song: Song,
        in sourceQueue: [Song],
        autoplay: Bool = true,
        origin: PlaybackOrigin = .manual
    ) {
        autoplayTask?.cancel()
        autoplayTask = nil
        autoplayGeneration &+= 1
        autoplayShouldAdvance = false
        startPlayback(
            song,
            in: sourceQueue,
            preferredIndex: nil,
            autoplay: autoplay,
            origin: origin,
            transitionReason: .replaced
        )
    }

    private func startPlayback(
        _ song: Song,
        in sourceQueue: [Song],
        preferredIndex: Int?,
        autoplay: Bool = true,
        origin: PlaybackOrigin = .manual,
        transitionReason: PlaybackEndReason = .replaced
    ) {
        // An explicit selection supersedes a pending server queue restore,
        // including the interval before AVPlayer reaches the playing state.
        serverQueueTask?.cancel()
        cancelPlaybackRecovery()
        let previousSongID = currentSong?.id
        finalizeCurrentPlayback(reason: transitionReason)
        let normalizedQueue = sourceQueue.isEmpty ? [song] : sourceQueue
        let resolvedIndex: Int
        if let preferredIndex, normalizedQueue.indices.contains(preferredIndex) {
            resolvedIndex = preferredIndex
        } else {
            resolvedIndex = normalizedQueue.firstIndex(where: { $0.id == song.id }) ?? 0
        }
        let selectedSong = normalizedQueue[resolvedIndex]
        queue = normalizedQueue
        queueIndex = resolvedIndex
        player.pause()
        isPlaying = false
        seekGeneration &+= 1
        isSeekInFlight = false
        pendingSeekPosition = nil
        removeCurrentItemObservers()
        player.replaceCurrentItem(with: nil)
        currentSong = selectedSong
        recordPlaybackStart(selectedSong, origin: origin)
        rememberShuffleSelection(selectedSong.id)
        elapsed = 0
        duration = selectedSong.safeDuration
        applyLyricsDocument(.empty)
        fallbackIndex = 0
        fallbackFormats = Self.fallbackFormats(for: quality, song: selectedSong)
        recoveryAttempt = 0
        activeCompatibilityFormat = Self.initialCompatibilityFormat(
            for: quality,
            song: selectedSong
        )
        playbackError = nil
        wantsPlayback = autoplay
        scrobbled = false
        lastMaintenanceSecond = -1
        let automaticallyOpensPlayer =
            UserDefaults.standard.object(forKey: "auto-open-player") as? Bool ?? false
        showPlayer = showPlayer || automaticallyOpensPlayer
        if previousSongID != selectedSong.id {
            provideTrackChangeHaptic()
        }
        loadCurrentItem(
            compatibilityFormat: activeCompatibilityFormat,
            resumeFrom: 0
        )
        // Starting the selected stream owns the critical network path. Any
        // previous speculative transfers are discarded now; the new queue is
        // warmed only after AVPlayer confirms that playback is established.
        suspendSpeculativePrefetch()
        loadLyrics(for: selectedSong)
        scheduleQueueSave()
        updateNowPlaying()
        scheduleAutoplayContinuationIfNeeded()
    }

    func togglePlayback() {
        guard currentSong != nil else { return }
        if wantsPlayback || isPlaying || player.timeControlStatus == .playing {
            pause()
        } else {
            resumePlayback()
        }
    }

    func resumePlayback() {
        guard currentSong != nil else { return }
        serverQueueTask?.cancel()
        configureAudioSession()
        wantsPlayback = true
        if let currentSong,
           behaviorStartRecordedForSongID != currentSong.id {
            recordPlaybackStart(currentSong, origin: .restored)
        }
        playbackError = nil
        let needsReload =
            player.currentItem == nil
            || player.currentItem?.status == .failed
        if needsReload {
            isBuffering = true
            restartPlaybackPlan(resumeFrom: elapsed)
        } else if duration > 0, elapsed >= max(0, duration - 0.5) {
            seekPlayer(to: 0, persistsQueue: false)
        }
        player.isMuted = false
        player.volume = 1
        activateNowPlayingSession()
        if !needsReload {
            player.playImmediately(atRate: 1)
        }
        recomputeTimelineFromPlayer()
        installNextLyricBoundary(after: elapsed)
        updateNowPlaying()
        scheduleAutoplayContinuationIfNeeded()
    }

    func pause() {
        pausePlayback(persistsQueue: true)
    }

    func handleMemoryPressure() {
        // Preserve the active player item and autoplay continuity. Only
        // speculative work is discarded so playback cannot be interrupted by
        // a system memory warning.
        suspendSpeculativePrefetch()
        if let client {
            Task { await client.trimTransientNetworkCaches() }
        }
        recentShuffleIDs = Array(recentShuffleIDs.suffix(8))
        player.currentItem?.preferredForwardBufferDuration = 0
    }

    func handleEnergyConstraints(
        lowPowerMode: Bool,
        thermalState: ProcessInfo.ThermalState
    ) {
        refreshIdleTimerPreference()
        installPlaybackTimeObserver()
        guard lowPowerMode
                || thermalState == .serious
                || thermalState == .critical else {
            scheduleNetworkPrefetch()
            scheduleOfflinePrefetch()
            return
        }
        suspendSpeculativePrefetch()
    }

    private func pausePlayback(persistsQueue: Bool) {
        wantsPlayback = false
        cancelPlaybackRecovery()
        player.pause()
        suspendSpeculativePrefetch()
        isPlaying = false
        isBuffering = false
        endBackgroundBridge()
        refreshIdleTimerPreference()
        updateNowPlaying()
        scheduleAudioSessionDeactivation()
        if persistsQueue { scheduleQueueSave(immediate: true) }
    }

    func seek(to seconds: TimeInterval) {
        serverQueueTask?.cancel()
        seekPlayer(to: seconds, persistsQueue: true)
    }

    private func seekPlayer(
        to seconds: TimeInterval,
        persistsQueue: Bool
    ) {
        guard seconds.isFinite else { return }
        let itemDuration = player.currentItem?.duration.seconds ?? 0
        let validItemDuration = itemDuration.isFinite && itemDuration > 0 ? itemDuration : 0
        let upperBound = max(duration, validItemDuration)
        let target = upperBound > 0 ? max(0, min(seconds, upperBound)) : max(0, seconds)
        pendingSeekPosition = target
        elapsed = target
        invalidateLyricBoundaryObserver()
        updateActiveLyric(at: target)
        updateNowPlaying()
        if persistsQueue { scheduleQueueSave() }
        guard player.currentItem != nil else {
            isSeekInFlight = false
            return
        }
        let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
        seekGeneration &+= 1
        let generation = seekGeneration
        isSeekInFlight = true
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.seekGeneration == generation else { return }
                self.isSeekInFlight = false
                self.pendingSeekPosition = nil
                self.recomputeTimelineFromPlayer()
                self.installNextLyricBoundary(after: self.elapsed)
                self.updateNowPlaying()
            }
        }
    }

    /// `isAutoAdvance`는 곡의 종료 알림으로 호출된 경우에만 true.
    /// 사용자가 다음곡 버튼/리모컨으로 직접 스킵한 경우는 false — 이 경우엔
    /// "1곡 반복" 모드여도 같은 곡을 재시작하지 않고 실제로 다음 곡으로 넘어가야 함.
    /// (이전에는 이 구분이 없어 수동 스킵도 같은 곡이 반복 재생되는 버그가 있었음.)
    func next(isAutoAdvance: Bool = false) {
        guard !queue.isEmpty else { return }
        if isAutoAdvance, repeatMode == .one, let song = currentSong {
            startPlayback(
                song,
                in: queue,
                preferredIndex: queueIndex,
                origin: .autoplay,
                transitionReason: .completed
            )
            return
        }

        if isShuffleEnabled, queue.count > 1 {
            queueIndex = nextShuffleIndex()
        } else if queueIndex < queue.count - 1 {
            queueIndex += 1
        } else if repeatMode == .all || (isAutoAdvance && repeatMode == .one) {
            queueIndex = 0
        } else {
            requestAutoplayContinuation(advanceWhenReady: true)
            return
        }
        startPlayback(
            queue[queueIndex],
            in: queue,
            preferredIndex: queueIndex,
            origin: isAutoAdvance ? .autoplay : .manual,
            transitionReason: isAutoAdvance ? .completed : .skipped
        )
    }

    private func scheduleAutoplayContinuationIfNeeded() {
        let remaining = max(0, queue.count - queueIndex - 1)
        guard remaining <= 3 else { return }
        requestAutoplayContinuation(advanceWhenReady: false)
    }

    private func requestAutoplayContinuation(advanceWhenReady: Bool) {
        guard repeatMode == .off,
              !isShuffleEnabled,
              algorithmicAutoplayEnabled,
              let seed = currentSong,
              seed.externalStreamURL == nil,
              let provider = autoplayContinuationProvider else {
            if advanceWhenReady { pause() }
            return
        }

        autoplayShouldAdvance = autoplayShouldAdvance || advanceWhenReady
        if advanceWhenReady {
            player.pause()
            isPlaying = false
            isBuffering = true
            updateNowPlaying()
        }
        guard autoplayTask == nil else { return }

        let generation = autoplayGeneration
        let excludedIDs = Set(queue.map(\.id))
        autoplayTask = Task { [weak self] in
            let candidates = await provider(seed, excludedIDs)
            guard let self,
                  !Task.isCancelled,
                  generation == self.autoplayGeneration else {
                return
            }
            guard self.algorithmicAutoplayEnabled else {
                self.autoplayTask = nil
                let shouldAdvance = self.autoplayShouldAdvance
                self.autoplayShouldAdvance = false
                if shouldAdvance { self.pause() }
                return
            }

            let currentIDs = Set(self.queue.map(\.id))
            var appendedIDs = currentIDs
            let additions = candidates.filter {
                appendedIDs.insert($0.id).inserted &&
                    $0.externalStreamURL == nil
            }
            self.autoplayTask = nil
            let shouldAdvance = self.autoplayShouldAdvance
            self.autoplayShouldAdvance = false

            guard !additions.isEmpty else {
                if shouldAdvance { self.pause() }
                return
            }
            self.queue.append(contentsOf: additions)
            self.updateRemoteCommands()
            self.updateNowPlaying()
            self.scheduleNetworkPrefetch()
            self.scheduleOfflinePrefetch()
            self.scheduleQueueSave(immediate: true)
            if shouldAdvance {
                self.isBuffering = false
                self.next(isAutoAdvance: true)
            }
        }
    }

    func previous() {
        if elapsed > 4 {
            seek(to: 0)
            return
        }
        guard !queue.isEmpty else { return }
        queueIndex = queueIndex > 0 ? queueIndex - 1 : (repeatMode == .all ? queue.count - 1 : 0)
        startPlayback(
            queue[queueIndex],
            in: queue,
            preferredIndex: queueIndex,
            origin: .manual,
            transitionReason: .skipped
        )
    }

    func playQueueItem(at index: Int) {
        guard queue.indices.contains(index) else { return }
        queueIndex = index
        startPlayback(
            queue[index],
            in: queue,
            preferredIndex: index,
            origin: .queue,
            transitionReason: .replaced
        )
    }

    func removeQueueItem(at index: Int) {
        guard queue.indices.contains(index) else { return }
        if index == queueIndex {
            excludeCurrentAndAdvance()
            return
        }
        let removedSong = queue[index]
        queue.remove(at: index)
        Task {
            await ListeningHistoryStore.shared.recordQueueRemoval(removedSong)
        }
        if index < queueIndex { queueIndex -= 1 }
        updateRemoteCommands()
        updateNowPlaying()
        scheduleQueueSave(immediate: true)
    }

    func enqueueNext(_ song: Song) {
        guard queue.indices.contains(queueIndex) else {
            play(song, in: [song])
            return
        }
        removeUpcomingOccurrence(of: song.id)
        queue.insert(song, at: min(queueIndex + 1, queue.count))
        queueDidChange()
    }

    func enqueue(_ song: Song) {
        guard queue.indices.contains(queueIndex) else {
            play(song, in: [song])
            return
        }
        removeUpcomingOccurrence(of: song.id)
        queue.append(song)
        queueDidChange()
    }

    func moveQueueItems(from offsets: IndexSet, to destination: Int) {
        guard !offsets.isEmpty else { return }
        let currentID = currentSong?.id
        let moved = offsets.sorted().compactMap { index in
            queue.indices.contains(index) ? queue[index] : nil
        }
        guard moved.count == offsets.count else { return }
        var remaining = queue.enumerated().compactMap { index, song in
            offsets.contains(index) ? nil : song
        }
        let removedBeforeDestination = offsets.lazy.filter {
            $0 < destination
        }.count
        let insertionIndex = min(
            max(0, destination - removedBeforeDestination),
            remaining.count
        )
        remaining.insert(contentsOf: moved, at: insertionIndex)
        queue = remaining
        if let currentID,
           let index = queue.firstIndex(where: { $0.id == currentID }) {
            queueIndex = index
        }
        queueDidChange()
    }

    func reshuffleUpcoming() {
        guard queue.indices.contains(queueIndex),
              queueIndex + 1 < queue.count else {
            return
        }
        let prefix = Array(queue[...queueIndex])
        var upcoming = Array(queue[(queueIndex + 1)...])
        upcoming.shuffle()
        if shuffleStyle == .fewerRepeats {
            let recent = Set(recentShuffleIDs.suffix(8))
            upcoming.sort {
                let lhsRecent = recent.contains($0.id)
                let rhsRecent = recent.contains($1.id)
                return lhsRecent == rhsRecent ? false : !lhsRecent
            }
        }
        queue = prefix + upcoming
        queueDidChange()
    }

    func clearUpcomingQueue() {
        guard queue.indices.contains(queueIndex),
              queueIndex + 1 < queue.count else {
            return
        }
        autoplayTask?.cancel()
        autoplayTask = nil
        autoplayGeneration &+= 1
        autoplayShouldAdvance = false
        let removedSongs = Array(queue[(queueIndex + 1)..<queue.count])
        queue.removeSubrange((queueIndex + 1)..<queue.count)
        Task {
            for song in removedSongs {
                await ListeningHistoryStore.shared.recordQueueRemoval(song)
            }
        }
        queueDidChange()
    }

    func excludeCurrentAndAdvance() {
        guard queue.indices.contains(queueIndex) else { return }
        finalizeCurrentPlayback(reason: .queueRemoved)
        let removedIndex = queueIndex
        queue.remove(at: removedIndex)
        guard !queue.isEmpty else {
            pause()
            itemLoadTask?.cancel()
            cancelPlaybackRecovery()
            lyricsTask?.cancel()
            itemLoadGeneration &+= 1
            lyricsLoadGeneration &+= 1
            seekGeneration &+= 1
            isSeekInFlight = false
            pendingSeekPosition = nil
            currentSong = nil
            queueIndex = -1
            elapsed = 0
            duration = 0
            isBuffering = false
            applyLyricsDocument(.empty)
            showFullLyrics = false
            removeCurrentItemObservers()
            player.replaceCurrentItem(with: nil)
            updateNowPlaying()
            scheduleQueueSave(immediate: true)
            return
        }
        queueIndex = min(removedIndex, queue.count - 1)
        startPlayback(
            queue[queueIndex],
            in: queue,
            preferredIndex: queueIndex,
            origin: .queue,
            transitionReason: .queueRemoved
        )
    }

    func toggleShuffle() {
        isShuffleEnabled.toggle()
        updateRemoteCommands()
        scheduleQueueSave()
        if !isShuffleEnabled { scheduleAutoplayContinuationIfNeeded() }
    }

    private func nextShuffleIndex() -> Int {
        let candidates = queue.indices.filter { $0 != queueIndex }
        guard shuffleStyle == .fewerRepeats else {
            return candidates.randomElement() ?? queueIndex
        }
        let recent = Set(
            recentShuffleIDs.suffix(min(8, max(1, queue.count - 1)))
        )
        let fresh = candidates.filter { !recent.contains(queue[$0].id) }
        return (fresh.isEmpty ? candidates : fresh).randomElement() ?? queueIndex
    }

    private func rememberShuffleSelection(_ songID: String) {
        recentShuffleIDs.removeAll { $0 == songID }
        recentShuffleIDs.append(songID)
        if recentShuffleIDs.count > 12 {
            recentShuffleIDs.removeFirst(recentShuffleIDs.count - 12)
        }
    }

    private func removeUpcomingOccurrence(of songID: String) {
        guard queue.indices.contains(queueIndex),
              queueIndex + 1 < queue.count,
              let index = queue[(queueIndex + 1)...].firstIndex(
                where: { $0.id == songID }
              ) else {
            return
        }
        queue.remove(at: index)
    }

    private func queueDidChange() {
        updateRemoteCommands()
        updateNowPlaying()
        scheduleNetworkPrefetch()
        scheduleOfflinePrefetch()
        scheduleQueueSave(immediate: true)
    }

    func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        updateRemoteCommands()
        scheduleQueueSave()
        if repeatMode == .off { scheduleAutoplayContinuationIfNeeded() }
    }

    func updateStarred(songID: String, enabled: Bool) {
        synchronizeStarredStates([songID: enabled])
    }

    func synchronizeStarredStates(_ states: [String: Bool]) {
        guard !states.isEmpty else { return }

        var updatedCurrentSong = currentSong
        if var song = updatedCurrentSong,
           let enabled = states[song.id],
           song.isStarred != enabled {
            song.starred = enabled ? Self.iso8601Formatter.string(from: Date()) : nil
            updatedCurrentSong = song
        }

        let updatedQueue = queue.map { song in
            guard let enabled = states[song.id],
                  song.isStarred != enabled else {
                return song
            }
            var updated = song
            updated.starred = enabled ? Self.iso8601Formatter.string(from: Date()) : nil
            return updated
        }

        let currentChanged = updatedCurrentSong != currentSong
        let queueChanged = updatedQueue != queue
        guard currentChanged || queueChanged else { return }

        if currentChanged { currentSong = updatedCurrentSong }
        if queueChanged { queue = updatedQueue }
        updateRemoteCommands()
        updateNowPlaying()
        scheduleQueueSave()
    }

    func setQueueRestoration(enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "restore-play-queue")
        if enabled {
            scheduleQueueSave(immediate: true)
        } else {
            queueSaveTask?.cancel()
            UserDefaults.standard.removeObject(forKey: queueStorageKey)
            lastPersistedQueue = nil
            Task { await AppDatabase.shared.clearQueue() }
        }
    }

    func refreshIdleTimerPreference() {
        let keepAwake =
            UserDefaults.standard.object(forKey: "keep-screen-awake") as? Bool ?? false
        UIApplication.shared.isIdleTimerDisabled =
            keepAwake
            && isPlaying
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    func toggleCurrentStar() async {
        guard let song = currentSong, let songFavoriteMutationHandler else { return }
        _ = await songFavoriteMutationHandler(song)
    }


    private func playbackResource(
        for song: Song,
        compatibilityFormat: String?,
        allowLocalSource: Bool = true
    ) async throws -> PlaybackResource {
        if let value = song.externalStreamURL,
           let url = URL(string: value),
           url.scheme?.lowercased() == "https" {
            return PlaybackResource(url: url, mimeType: song.contentType)
        }
        // A downloaded source avoids radio use and is attempted once. If the
        // system rejects it, later codec fallbacks bypass the local source.
        if allowLocalSource,
           compatibilityFormat?.lowercased() == "raw",
           let local = await OfflineStore.shared.localURL(for: song.id) {
            return PlaybackResource(
                url: local,
                mimeType: Self.sourceMIMEType(for: song)
            )
        }
        guard let client else { throw OpenSubsonicError.invalidServerURL }
        let url = try await client.streamURL(
            songID: song.id,
            quality: quality,
            compatibilityFormat: compatibilityFormat
        )
        return PlaybackResource(
            url: url,
            mimeType: Self.mimeType(
                for: compatibilityFormat,
                sourceSong: song
            )
        )
    }

    private static func initialCompatibilityFormat(
        for quality: StreamQuality,
        song: Song
    ) -> String {
        switch quality {
        case .automatic:
            automaticCompatibilityFormat(for: song)
        case .aac320: "aac"
        case .opus160: "opus"
        case .original: "raw"
        }
    }

    private static func fallbackFormats(
        for quality: StreamQuality,
        song: Song
    ) -> [String] {
        if song.externalStreamURL != nil { return [] }
        return switch quality {
        case .automatic:
            automaticCompatibilityFormat(for: song) == "raw"
                ? ["aac", "mp3"]
                : ["mp3", "raw"]
        case .aac320:
            ["mp3", "raw"]
        case .opus160:
            ["aac", "mp3", "raw"]
        case .original:
            ["aac", "mp3"]
        }
    }

    private static func automaticCompatibilityFormat(for song: Song) -> String {
        if song.externalStreamURL != nil { return "raw" }
        let suffix = song.suffix?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let contentType = song.contentType?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        let serverTranscodedSuffixes: Set<String> = [
            "flac", "opus", "ogg", "oga", "vorbis", "webm"
        ]
        let serverTranscodedMIMETypes: Set<String> = [
            "audio/flac", "audio/x-flac",
            "audio/opus", "audio/ogg", "application/ogg",
            "audio/vorbis", "audio/webm"
        ]
        if serverTranscodedSuffixes.contains(suffix) ||
            serverTranscodedMIMETypes.contains(contentType) {
            return "aac"
        }

        // AAC, MP3, ALAC/M4A, WAV, AIFF, CAF, AC-3, and other formats already
        // accepted by AVFoundation stay bit-for-bit original. Unknown formats
        // also try the source first, then use the AAC/MP3 fallback plan.
        return "raw"
    }

    private static func mimeType(
        for compatibilityFormat: String?,
        sourceSong song: Song
    ) -> String? {
        switch compatibilityFormat?.lowercased() {
        case "aac": "audio/aac"
        case "mp3": "audio/mpeg"
        case "opus": "audio/ogg; codecs=opus"
        case "raw", nil: sourceMIMEType(for: song)
        default: song.contentType
        }
    }

    private static func sourceMIMEType(for song: Song) -> String? {
        switch song.suffix?.lowercased() {
        case "flac": "audio/flac"
        case "opus": "audio/ogg; codecs=opus"
        case "ogg", "oga": song.contentType ?? "audio/ogg"
        case "mp3": "audio/mpeg"
        case "aac": "audio/aac"
        case "m4a", "m4b", "mp4", "alac": "audio/mp4"
        case "wav", "wave": "audio/wav"
        case "aif", "aiff": "audio/aiff"
        default: song.contentType
        }
    }

    private func installNetworkPathMonitor() {
        networkPathMonitor.pathUpdateHandler = { [weak self] path in
            let allowsPrefetch = path.status == .satisfied
                && !path.isExpensive
                && !path.isConstrained
            Task { @MainActor [weak self] in
                guard let self,
                      self.allowsSpeculativeNetworkPrefetch != allowsPrefetch else {
                    return
                }
                self.allowsSpeculativeNetworkPrefetch = allowsPrefetch
                if allowsPrefetch {
                    self.scheduleNetworkPrefetch()
                    self.scheduleOfflinePrefetch()
                } else {
                    self.suspendSpeculativePrefetch()
                }
            }
        }
        networkPathMonitor.start(queue: networkPathQueue)
    }

    private static let preparedPlaybackAssetLimit = 3

    private static func preparedPlaybackKey(
        songID: String,
        quality: StreamQuality,
        compatibilityFormat: String
    ) -> String {
        [songID, quality.rawValue, compatibilityFormat.lowercased()]
            .joined(separator: "|")
    }

    private static func makeURLAsset(
        url: URL,
        mimeType: String?
    ) -> AVURLAsset {
        // Some OpenSubsonic servers omit or generalize Content-Type. Preserve
        // the same out-of-band hint used by active playback while warming the
        // exact asset that will later be handed to AVPlayer.
        let options: [String: Any] = mimeType.map {
            ["AVURLAssetOutOfBandMIMETypeKey": $0]
        } ?? [:]
        return AVURLAsset(url: url, options: options)
    }

    private func preparePlaybackAsset(for song: Song) {
        guard song.externalStreamURL == nil else { return }
        let preparedQuality = quality
        let compatibilityFormat = Self.initialCompatibilityFormat(
            for: preparedQuality,
            song: song
        )
        let key = Self.preparedPlaybackKey(
            songID: song.id,
            quality: preparedQuality,
            compatibilityFormat: compatibilityFormat
        )
        guard preparedPlaybackAssets[key] == nil,
              preparedPlaybackWarmupTasks[key] == nil else {
            return
        }

        let task = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let resource = try await self.playbackResource(
                    for: song,
                    compatibilityFormat: compatibilityFormat,
                    allowLocalSource: true
                )
                guard !Task.isCancelled,
                      self.quality == preparedQuality,
                      self.queue.contains(where: { $0.id == song.id }) else {
                    self.preparedPlaybackWarmupTasks[key] = nil
                    return
                }

                let asset = Self.makeURLAsset(
                    url: resource.url,
                    mimeType: resource.mimeType
                )
                self.storePreparedPlaybackAsset(
                    PreparedPlaybackAsset(
                        key: key,
                        songID: song.id,
                        compatibilityFormat: compatibilityFormat,
                        asset: asset
                    )
                )

                do {
                    // This opens the transport, validates the stream response,
                    // and loads enough AVFoundation metadata that a skip can
                    // reuse the same asset during the page transition.
                    _ = try await asset.load(.isPlayable)
                } catch {
                    if self.preparedPlaybackAssets[key]?.asset === asset {
                        self.preparedPlaybackAssets[key] = nil
                        self.preparedPlaybackAssetOrder.removeAll { $0 == key }
                    }
                }
            } catch {
                // Warming is speculative. Active playback retains its normal
                // codec fallback and recovery path if preparation fails.
            }
            self.preparedPlaybackWarmupTasks[key] = nil
        }
        preparedPlaybackWarmupTasks[key] = task
    }

    private func storePreparedPlaybackAsset(_ prepared: PreparedPlaybackAsset) {
        preparedPlaybackAssets[prepared.key] = prepared
        preparedPlaybackAssetOrder.removeAll { $0 == prepared.key }
        preparedPlaybackAssetOrder.append(prepared.key)
        while preparedPlaybackAssetOrder.count > Self.preparedPlaybackAssetLimit {
            let evicted = preparedPlaybackAssetOrder.removeFirst()
            preparedPlaybackAssets[evicted] = nil
            preparedPlaybackWarmupTasks.removeValue(forKey: evicted)?.cancel()
        }
    }

    private func takePreparedPlaybackAsset(
        for song: Song,
        compatibilityFormat: String?
    ) -> PreparedPlaybackAsset? {
        guard let compatibilityFormat else { return nil }
        let key = Self.preparedPlaybackKey(
            songID: song.id,
            quality: quality,
            compatibilityFormat: compatibilityFormat
        )
        guard let prepared = preparedPlaybackAssets.removeValue(forKey: key),
              prepared.songID == song.id,
              prepared.compatibilityFormat == compatibilityFormat else {
            return nil
        }
        preparedPlaybackAssetOrder.removeAll { $0 == key }
        // Do not cancel an in-progress AVAsset warmup after handing that same
        // asset to the active player. Dropping our task handle lets it finish
        // while AVPlayer immediately consumes the partially warmed resource.
        preparedPlaybackWarmupTasks[key] = nil
        return prepared
    }

    private func discardPreparedPlaybackAssets() {
        preparedPlaybackWarmupTasks.values.forEach { $0.cancel() }
        preparedPlaybackWarmupTasks.removeAll(keepingCapacity: false)
        preparedPlaybackAssets.removeAll(keepingCapacity: false)
        preparedPlaybackAssetOrder.removeAll(keepingCapacity: false)
    }

    private func cancelNetworkPrefetch(resetKey: Bool) {
        networkPrefetchTask?.cancel()
        networkPrefetchTask = nil
        networkPrefetchToken = nil
        if resetKey { lastNetworkPrefetchKey = nil }
    }

    private func cancelOfflinePrefetch(resetKey: Bool) {
        offlinePrefetchTask?.cancel()
        offlinePrefetchTask = nil
        offlinePrefetchToken = nil
        if resetKey { lastOfflinePrefetchKey = nil }
    }

    private func suspendSpeculativePrefetch() {
        cancelNetworkPrefetch(resetKey: true)
        cancelOfflinePrefetch(resetKey: true)
        discardPreparedPlaybackAssets()
    }

    private func playbackPrefetchPlan(
        maximumUpcoming: Int
    ) -> PlaybackPrefetchPlan? {
        PlaybackPrefetchPlan.make(
            currentSong: currentSong,
            queue: queue,
            queueIndex: queueIndex,
            quality: quality,
            maximumUpcoming: maximumUpcoming,
            isActivelyPlaying:
                wantsPlayback && player.timeControlStatus == .playing
        )
    }

    private func scheduleNetworkPrefetch() {
        guard allowsSpeculativeNetworkPrefetch,
              let client,
              let plan = playbackPrefetchPlan(maximumUpcoming: 2) else {
            cancelNetworkPrefetch(resetKey: true)
            return
        }

        let processInfo = ProcessInfo.processInfo
        guard !processInfo.isLowPowerModeEnabled,
              processInfo.thermalState != .serious,
              processInfo.thermalState != .critical else {
            cancelNetworkPrefetch(resetKey: true)
            return
        }

        guard lastNetworkPrefetchKey != plan.key else { return }
        cancelNetworkPrefetch(resetKey: false)
        lastNetworkPrefetchKey = plan.key

        // Prepare the actual AVURLAsset in addition to lyrics and artwork.
        // The player consumes this same object on skip, so work completed while
        // the current song is playing is not discarded or repeated.
        // Opening an AVURLAsset starts real media transport work. Warm only the
        // immediate successor so skip latency improves without spending radio,
        // decoder, and server resources on a track that may never be played.
        if let nextSong = plan.upcomingSongs.first {
            preparePlaybackAsset(for: nextSong)
        }

        let token = UUID()
        networkPrefetchToken = token
        networkPrefetchTask = Task(priority: .utility) { [weak self] in
            defer {
                if let self, self.networkPrefetchToken == token {
                    self.networkPrefetchTask = nil
                    self.networkPrefetchToken = nil
                }
            }
            async let lyricsPrefetch: Void = client.prefetchLyrics(
                songIDs: plan.upcomingSongs.map(\.id)
            )

            var coverURLs: [URL] = []
            var seenCoverIDs = Set<String>()
            for song in plan.upcomingSongs {
                guard !Task.isCancelled else { return }
                guard let coverID = song.coverArt,
                      seenCoverIDs.insert(coverID).inserted,
                      let url = try? await client.coverURL(id: coverID, size: 360) else {
                    continue
                }
                coverURLs.append(url)
            }
            await ArtworkStore.shared.prefetch(
                urls: coverURLs,
                pixelSize: 360
            )
            await lyricsPrefetch
            guard !Task.isCancelled else { return }
        }
    }

    private func scheduleOfflinePrefetch() {
        let configured = UserDefaults.standard.integer(forKey: "offline-prefetch-count")
        let defaultCount =
            UserDefaults.standard.object(forKey: "offline-prefetch-count") == nil
                ? 0
                : configured
        let thermalState = ProcessInfo.processInfo.thermalState
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled,
              thermalState != .serious,
              thermalState != .critical else {
            cancelOfflinePrefetch(resetKey: true)
            return
        }
        let cappedCount = min(max(defaultCount, 0), 3)
        guard allowsSpeculativeNetworkPrefetch,
              let client,
              let plan = playbackPrefetchPlan(
                maximumUpcoming: cappedCount
              ) else {
            cancelOfflinePrefetch(resetKey: true)
            return
        }
        guard lastOfflinePrefetchKey != plan.key else { return }
        cancelOfflinePrefetch(resetKey: false)
        lastOfflinePrefetchKey = plan.key

        let token = UUID()
        offlinePrefetchToken = token
        offlinePrefetchTask = Task(priority: .utility) { [weak self] in
            defer {
                if let self, self.offlinePrefetchToken == token {
                    self.offlinePrefetchTask = nil
                    self.offlinePrefetchToken = nil
                }
            }
            for song in plan.upcomingSongs {
                guard !Task.isCancelled else { return }
                if await OfflineStore.shared.localURL(for: song.id) == nil {
                    _ = try? await OfflineStore.shared.download(song: song, client: client)
                }
            }
        }
    }


    private func restartPlaybackPlan(resumeFrom: TimeInterval) {
        guard let song = currentSong else { return }
        cancelPlaybackRecovery()
        fallbackIndex = 0
        fallbackFormats = Self.fallbackFormats(for: quality, song: song)
        activeCompatibilityFormat = Self.initialCompatibilityFormat(
            for: quality,
            song: song
        )
        loadCurrentItem(
            compatibilityFormat: activeCompatibilityFormat,
            resumeFrom: resumeFrom
        )
    }

    private func loadCurrentItem(
        compatibilityFormat: String? = nil,
        resumeFrom requestedPosition: TimeInterval? = nil
    ) {
        guard let song = currentSong else { return }
        let resumePosition = max(0, requestedPosition ?? elapsed)
        itemLoadTask?.cancel()
        itemLoadGeneration &+= 1
        let generation = itemLoadGeneration
        seekGeneration &+= 1
        isSeekInFlight = false
        if pendingSeekPosition == nil, resumePosition > 0 {
            pendingSeekPosition = resumePosition
        }
        activeCompatibilityFormat = compatibilityFormat
        isBuffering = wantsPlayback

        if let prepared = takePreparedPlaybackAsset(
            for: song,
            compatibilityFormat: compatibilityFormat
        ) {
            replacePlayerItem(
                asset: prepared.asset,
                resumePosition: resumePosition
            )
            return
        }

        itemLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let resource = try await self.playbackResource(
                    for: song,
                    compatibilityFormat: compatibilityFormat,
                    allowLocalSource: self.fallbackIndex == 0
                )
                guard !Task.isCancelled,
                      self.itemLoadGeneration == generation,
                      self.currentSong?.id == song.id else {
                    return
                }
                self.replacePlayerItem(
                    url: resource.url,
                    mimeType: resource.mimeType,
                    resumePosition: resumePosition
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, self.itemLoadGeneration == generation else { return }
                self.isBuffering = false
                self.handlePlaybackFailure()
            }
        }
    }

    private func replacePlayerItem(
        url: URL,
        mimeType: String?,
        resumePosition: TimeInterval
    ) {
        replacePlayerItem(
            asset: Self.makeURLAsset(url: url, mimeType: mimeType),
            resumePosition: resumePosition
        )
    }

    private func replacePlayerItem(
        asset: AVURLAsset,
        resumePosition: TimeInterval
    ) {
        cancelPlaybackRecovery()
        removeCurrentItemObservers()
        let item = AVPlayerItem(asset: asset)
        // Let AVFoundation adapt buffering to throughput and decoder cost.
        // Large fixed buffers increase system-resource demand.
        item.preferredForwardBufferDuration = 0
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        installItemObservers(for: item)
        installBufferObservers(for: item)
        let observerGeneration = itemObserverGeneration

        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self,
                      self.itemObserverGeneration == observerGeneration,
                      self.player.currentItem === item else {
                    return
                }
                switch item.status {
                case .readyToPlay:
                    self.isBuffering = false
                    self.recoveryAttempt = 0
                    self.updateDuration(using: item.duration.seconds)
                    let targetPosition = self.pendingSeekPosition ?? resumePosition
                    if targetPosition > 0 {
                        self.seekPlayer(
                            to: targetPosition,
                            persistsQueue: false
                        )
                    } else {
                        self.pendingSeekPosition = nil
                        self.recomputeTimelineFromPlayer()
                        self.installNextLyricBoundary(after: self.elapsed)
                    }
                    if self.wantsPlayback {
                        self.configureAudioSession()
                        self.player.isMuted = false
                        self.player.volume = 1
                        self.activateNowPlayingSession()
                        self.player.playImmediately(atRate: 1)
                    }
                case .failed:
                    self.isBuffering = false
                    self.handlePlaybackFailure(failedItem: item)
                default:
                    self.isBuffering = self.wantsPlayback
                }
            }
        }
        player.replaceCurrentItem(with: item)
        handledFailedItem = nil
        updateActiveLyric(at: elapsed)
        installNextLyricBoundary(after: elapsed)
    }

    private func updateDuration(using playerDuration: TimeInterval) {
        let metadataDuration = currentSong?.safeDuration ?? 0
        let validPlayerDuration = playerDuration.isFinite && playerDuration > 0
        let validMetadataDuration = metadataDuration.isFinite && metadataDuration > 0
        let resolvedDuration: TimeInterval
        if !validPlayerDuration, !validMetadataDuration {
            resolvedDuration = 0
        } else if !validPlayerDuration {
            resolvedDuration = metadataDuration
        } else if !validMetadataDuration {
            resolvedDuration = playerDuration
        } else {
            // Transcoded and malformed streams can report an AVAsset duration
            // based on an incomplete byte range. OpenSubsonic's metadata is
            // stable; accept the player value only when they closely agree.
            let tolerance = max(3, metadataDuration * 0.03)
            resolvedDuration = abs(playerDuration - metadataDuration) <= tolerance
                ? playerDuration
                : metadataDuration
        }
        guard abs(duration - resolvedDuration) > 0.05 else { return }
        duration = resolvedDuration
    }

    private func removeCurrentItemObservers() {
        itemObserverGeneration &+= 1
        itemObservation = nil
        itemBufferObservations.removeAll()
        playbackObservers.removeItemNotifications()
        invalidateLyricBoundaryObserver()
    }

    private func installItemObservers(for item: AVPlayerItem) {
        let generation = itemObserverGeneration
        playbackObservers.replaceItemNotifications { [weak self, weak item] center in
            guard let self, let item else { return [] }
            return [
                center.addObserver(
                    forName: .AVPlayerItemPlaybackStalled,
                    object: item,
                    queue: .main
                ) { [weak self, weak item] _ in
                    Task { @MainActor in
                        guard let self,
                              let item,
                              self.itemObserverGeneration == generation,
                              self.player.currentItem === item else {
                            return
                        }
                        Self.logger.warning(
                            "Playback stalled; scheduling bounded recovery"
                        )
                        self.schedulePlaybackRecovery()
                    }
                },
                center.addObserver(
                    forName: .AVPlayerItemFailedToPlayToEndTime,
                    object: item,
                    queue: .main
                ) { [weak self, weak item] _ in
                    Task { @MainActor in
                        guard let self,
                              let item,
                              self.itemObserverGeneration == generation,
                              self.player.currentItem === item else {
                            return
                        }
                        self.handlePlaybackFailure(failedItem: item)
                    }
                },
                center.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: item,
                    queue: .main
                ) { [weak self, weak item] _ in
                    Task { @MainActor in
                        guard let self,
                              let item,
                              self.itemObserverGeneration == generation,
                              self.player.currentItem === item else {
                            return
                        }
                        self.next(isAutoAdvance: true)
                    }
                }
            ]
        }
    }

    private func installBufferObservers(for item: AVPlayerItem) {
        itemBufferObservations.removeAll()
        let generation = itemObserverGeneration

        let empty = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self,
                      self.itemObserverGeneration == generation,
                      self.player.currentItem === item else {
                    return
                }
                if item.isPlaybackBufferEmpty, self.wantsPlayback {
                    self.schedulePlaybackRecovery()
                }
            }
        }
        let likelyToKeepUp = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self,
                      self.itemObserverGeneration == generation,
                      self.player.currentItem === item else {
                    return
                }
                guard item.isPlaybackLikelyToKeepUp else { return }
                self.cancelPlaybackRecovery()
                self.recoveryAttempt = 0
                if self.wantsPlayback, self.player.timeControlStatus != .playing {
                    self.configureAudioSession()
                    self.player.play()
                    self.recomputeTimelineFromPlayer()
                    self.installNextLyricBoundary(after: self.elapsed)
                }
            }
        }
        itemBufferObservations = [empty, likelyToKeepUp]
    }

    private func handlePlaybackFailure(failedItem: AVPlayerItem? = nil) {
        guard currentSong != nil else { return }
        if let failedItem {
            guard player.currentItem === failedItem,
                  handledFailedItem !== failedItem else {
                return
            }
            handledFailedItem = failedItem
        }
        cancelPlaybackRecovery()
        guard fallbackFormats.indices.contains(fallbackIndex) else {
            Self.logger.error(
                "Playback failed after exhausting compatibility fallbacks"
            )
            wantsPlayback = false
            isPlaying = false
            isBuffering = false
            player.pause()
            endBackgroundBridge()
            refreshIdleTimerPreference()
            updateNowPlaying()
            scheduleQueueSave(immediate: true)
            playbackError = String(
                localized: "이 음악을 재생하지 못했습니다. 서버의 스트리밍 형식과 네트워크 상태를 확인해 주세요."
            )
            return
        }
        let format = fallbackFormats[fallbackIndex]
        fallbackIndex += 1
        Self.logger.warning(
            "Playback failed; trying compatibility fallback \(format, privacy: .public)"
        )
        activeCompatibilityFormat = format
        loadCurrentItem(compatibilityFormat: format, resumeFrom: elapsed)
    }

    private func cancelPlaybackRecovery() {
        recoveryToken = nil
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    private func schedulePlaybackRecovery() {
        guard wantsPlayback, currentSong != nil, recoveryTask == nil else { return }
        isBuffering = true
        let token = UUID()
        recoveryToken = token
        recoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1_250))
            guard let self else { return }
            defer {
                if self.recoveryToken == token {
                    self.recoveryToken = nil
                    self.recoveryTask = nil
                }
            }
            guard !Task.isCancelled, self.wantsPlayback,
                  let item = self.player.currentItem else { return }

            if item.isPlaybackLikelyToKeepUp || !item.isPlaybackBufferEmpty {
                self.configureAudioSession()
                self.player.play()
                self.recomputeTimelineFromPlayer()
                self.installNextLyricBoundary(after: self.elapsed)
                return
            }

            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, self.wantsPlayback,
                  self.player.currentItem === item else { return }
            guard self.player.timeControlStatus != .playing else { return }

            self.recoveryAttempt += 1
            if self.recoveryAttempt <= 2 {
                self.loadCurrentItem(
                    compatibilityFormat: self.activeCompatibilityFormat,
                    resumeFrom: self.elapsed
                )
            } else {
                self.handlePlaybackFailure(failedItem: item)
            }
        }
    }

    private func loadLyrics(for song: Song) {
        lyricsTask?.cancel()
        lyricsLoadGeneration &+= 1
        let generation = lyricsLoadGeneration
        guard song.externalStreamURL == nil else {
            applyLyricsDocument(.empty)
            return
        }
        guard let client else {
            applyLyricsDocument(.empty)
            return
        }
        lyricsTask = Task { [weak self] in
            do {
                let document = try await client.lyrics(songID: song.id)
                guard let self,
                      !Task.isCancelled,
                      self.lyricsLoadGeneration == generation,
                      self.currentSong?.id == song.id else {
                    return
                }
                self.lyricsTask = nil
                self.applyLyricsDocument(document)
            } catch {
                guard let self,
                      !Task.isCancelled,
                      self.lyricsLoadGeneration == generation,
                      self.currentSong?.id == song.id else {
                    return
                }
                self.lyricsTask = nil
                Self.logger.error("Lyrics request failed")
                self.applyLyricsDocument(.empty)
            }
        }
    }

    private func installPlayerObservers() {
        guard timeControlObservation == nil else { return }
        timeControlObservation = player.observe(
            \.timeControlStatus,
            options: [.initial, .new]
        ) { [weak self] player, _ in
            Task { @MainActor in
                guard let self else { return }
                let isPlaying = player.timeControlStatus == .playing
                self.isPlaying = isPlaying
                self.isBuffering =
                    self.wantsPlayback
                    && !isPlaying
                    && (
                        player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                        || player.currentItem?.status != .readyToPlay
                    )
                if player.timeControlStatus == .playing {
                    self.cancelPlaybackRecovery()
                    self.endBackgroundBridge()
                    self.reportPlaybackState("playing")
                    self.scheduleNetworkPrefetch()
                    self.scheduleOfflinePrefetch()
                } else if !self.wantsPlayback {
                    self.reportPlaybackState("paused")
                    self.suspendSpeculativePrefetch()
                } else {
                    // A buffering or recovery transition must give the active
                    // stream sole use of the radio and server connection.
                    self.suspendSpeculativePrefetch()
                }
                self.refreshIdleTimerPreference()
                self.updateRemoteCommands()
                self.updateNowPlaying()
            }
        }

        installPlaybackTimeObserver()
    }

    private func installPlaybackTimeObserver() {
        timelineObserverGeneration &+= 1
        let generation = timelineObserverGeneration
        let processInfo = ProcessInfo.processInfo
        let canUseSmoothRefresh =
            showPlayer
            && !processInfo.isLowPowerModeEnabled
            && processInfo.thermalState != .serious
            && processInfo.thermalState != .critical
        let refreshInterval = canUseSmoothRefresh ? 0.25 : 0.5
        playbackObservers.replacePeriodicTimeObserver(
            interval: CMTime(
                seconds: refreshInterval,
                preferredTimescale: 600
            )
        ) { [weak self] time in
            Task { @MainActor in
                guard let self,
                      self.timelineObserverGeneration == generation else {
                    return
                }
                guard self.player.currentItem != nil else { return }
                let seconds = time.seconds
                let lyricPosition = seconds.isFinite
                    ? max(0, seconds)
                    : self.elapsed
                if !self.isSeekInFlight,
                   self.pendingSeekPosition == nil,
                   seconds.isFinite {
                    self.elapsed = max(0, seconds)
                }
                if self.duration > 0 {
                    self.elapsed = min(self.elapsed, self.duration)
                }
                self.updateActiveLyric(at: lyricPosition)

                // UI progress may need four updates per second while the full
                // player is visible, but duration checks, scrobbling, and
                // persistence do not. Batch those operations to one wakeup per
                // playback second.
                let maintenanceSecond = Int(self.elapsed.rounded(.down))
                if maintenanceSecond != self.lastMaintenanceSecond {
                    self.lastMaintenanceSecond = maintenanceSecond
                    if let itemDuration = self.player.currentItem?.duration.seconds {
                        self.updateDuration(using: itemDuration)
                    }
                    self.submitScrobbleIfNeeded()
                    if Date().timeIntervalSince(self.lastQueueSaveRequest) >= 30 {
                        self.scheduleQueueSave(immediate: true)
                    }
                }
            }
        }
    }

    private func applyLyricsDocument(_ document: LyricsDocument) {
        lyrics = document
        let lyricPosition = currentLyricPosition(fallback: elapsed)
        updateActiveLyric(at: lyricPosition)
        installNextLyricBoundary(after: lyricPosition)
    }

    private func recomputeTimelineFromPlayer() {
        var lyricPosition = pendingSeekPosition ?? elapsed
        if pendingSeekPosition == nil, !isSeekInFlight {
            let seconds = player.currentTime().seconds
            if seconds.isFinite {
                lyricPosition = max(0, seconds)
                elapsed = lyricPosition
                if duration > 0 { elapsed = min(elapsed, duration) }
            }
        }
        updateActiveLyric(at: lyricPosition)
    }

    private func invalidateLyricBoundaryObserver() {
        lyricBoundaryGeneration &+= 1
        playbackObservers.removeLyricBoundaryObserver()
    }

    private func installNextLyricBoundary(after position: TimeInterval) {
        invalidateLyricBoundaryObserver()
        guard player.currentItem != nil,
              lyrics.synced,
              !lyrics.lines.isEmpty,
              position.isFinite,
              let songID = currentSong?.id else {
            return
        }
        let nextIndex = Self.lastIndex(
            in: lyrics.lines,
            notAfter: position
        ) + 1
        guard lyrics.lines.indices.contains(nextIndex) else {
            return
        }

        lyricBoundaryGeneration &+= 1
        let generation = lyricBoundaryGeneration
        let boundary = max(0, lyrics.lines[nextIndex].start)
        guard boundary.isFinite else { return }
        playbackObservers.replaceLyricBoundaryObserver(
            time: CMTime(seconds: boundary, preferredTimescale: 600)
        ) { [weak self] in
            Task { @MainActor in
                guard let self,
                      self.lyricBoundaryGeneration == generation,
                      self.currentSong?.id == songID,
                      self.player.currentItem != nil,
                      !self.isSeekInFlight,
                      self.pendingSeekPosition == nil else {
                    return
                }
                let playerTime = self.player.currentTime().seconds
                let resolved = playerTime.isFinite
                    ? max(boundary, playerTime)
                    : boundary
                self.elapsed = self.duration > 0
                    ? min(max(0, resolved), self.duration)
                    : max(0, resolved)
                self.updateActiveLyric(at: resolved)
                self.installNextLyricBoundary(after: resolved)
            }
        }
    }

    private func currentLyricPosition(fallback: TimeInterval) -> TimeInterval {
        if let pendingSeekPosition, pendingSeekPosition.isFinite {
            return max(0, pendingSeekPosition)
        }
        let playerTime = player.currentTime().seconds
        return playerTime.isFinite ? max(0, playerTime) : max(0, fallback)
    }

    private func updateActiveLyric(at position: TimeInterval) {
        guard lyrics.synced, !lyrics.lines.isEmpty else {
            let nextIndex = lyrics.lines.isEmpty ? -1 : 0
            if activeLyricIndex != nextIndex {
                activeLyricIndex = nextIndex
            }
            return
        }
        let resolvedPosition = position.isFinite ? max(0, position) : 0
        let index = Self.lastIndex(
            in: lyrics.lines,
            notAfter: resolvedPosition
        )
        if activeLyricIndex != index { activeLyricIndex = index }
    }

    /// `lyrics.lines`는 OpenSubsonicClient.lyrics(songID:)에서 항상 시작 시간
    /// 기준으로 정렬되어 반환된다. 경계 observer와 주기적 보정 양쪽에서
    /// 사용하는 탐색을 선형(O(n)) 대신 이진 탐색(O(log n))으로 처리한다.
    private static func lastIndex(in lines: [LyricLine], notAfter elapsed: TimeInterval) -> Int {
        var low = 0
        var high = lines.count - 1
        var result = -1
        while low <= high {
            let mid = (low + high) / 2
            if lines[mid].start <= elapsed {
                result = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return result
    }

    private func configureAudioSession() {
        // AVAudioSession activation may synchronously negotiate with the audio
        // daemon. Serialize it away from MainActor and coalesce repeated calls
        // from ready/buffer/route observers into one operation.
        audioSessionDeactivationTask?.cancel()
        audioSessionDeactivationTask = nil
        audioSessionActivationTask?.cancel()
        let controller = audioSessionController
        let token = UUID()
        let epoch = nextAudioSessionCommandEpoch()
        audioSessionActivationToken = token
        audioSessionActivationTask = Task { [weak self] in
            let activated = await controller.activate(epoch: epoch)
            guard let self else { return }
            guard self.audioSessionActivationToken == token else { return }
            self.audioSessionActivationToken = nil
            self.audioSessionActivationTask = nil
            guard activated else { return }
            self.player.isMuted = false
            self.player.volume = 1
        }
    }

    private func resetAndConfigureAudioSession() {
        audioSessionDeactivationTask?.cancel()
        audioSessionDeactivationTask = nil
        audioSessionActivationTask?.cancel()
        let controller = audioSessionController
        let token = UUID()
        let epoch = nextAudioSessionCommandEpoch()
        audioSessionActivationToken = token
        audioSessionActivationTask = Task { [weak self] in
            let activated = await controller.resetAndActivate(epoch: epoch)
            guard let self else { return }
            guard self.audioSessionActivationToken == token else { return }
            self.audioSessionActivationToken = nil
            self.audioSessionActivationTask = nil
            guard activated else { return }
            self.player.isMuted = false
            self.player.volume = 1
        }
    }

    private func markAudioSessionInactive() {
        audioSessionDeactivationTask?.cancel()
        audioSessionDeactivationTask = nil
        let activationTask = audioSessionActivationTask
        activationTask?.cancel()
        audioSessionActivationToken = nil
        audioSessionActivationTask = nil
        let controller = audioSessionController
        let epoch = nextAudioSessionCommandEpoch()
        Task {
            _ = await activationTask?.value
            await controller.markInactive(epoch: epoch)
        }
    }

    private func scheduleAudioSessionDeactivation(immediate: Bool = false) {
        audioSessionDeactivationTask?.cancel()
        let controller = audioSessionController
        let epoch = nextAudioSessionCommandEpoch()
        audioSessionDeactivationTask = Task { [weak self] in
            if !immediate {
                do {
                    try await Task.sleep(for: .seconds(4))
                } catch {
                    return
                }
            }
            guard !Task.isCancelled,
                  let self,
                  !self.wantsPlayback,
                  self.player.timeControlStatus != .playing else {
                return
            }
            await controller.deactivate(epoch: epoch)
            guard !Task.isCancelled else { return }
            self.audioSessionDeactivationTask = nil
        }
    }

    private func nextAudioSessionCommandEpoch() -> UInt64 {
        audioSessionCommandEpoch &+= 1
        return audioSessionCommandEpoch
    }

    private func installSystemObservers() {
        playbackObservers.installSystemNotificationsIfNeeded { [weak self] center in
            guard let self else { return [] }
            let audioSession = AVAudioSession.sharedInstance()
            var tokens: [NSObjectProtocol] = []
            tokens.append(center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: audioSession,
                queue: .main
            ) { [weak self] notification in
                let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
                Task { @MainActor in
                    self?.handleAudioInterruption(
                        typeRawValue: type,
                        optionsRawValue: options
                    )
                }
            })
            tokens.append(center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: audioSession,
                queue: .main
            ) { [weak self] notification in
                let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                Task { @MainActor in
                    self?.handleRouteChange(reasonRawValue: reason)
                }
            })
            tokens.append(center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: audioSession,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    Self.logger.notice("Audio media services reset; rebuilding playback")
                    self.resetAndConfigureAudioSession()
                    self.invalidateLyricBoundaryObserver()
                    self.updateActiveLyric(
                        at: self.currentLyricPosition(fallback: self.elapsed)
                    )
                    if self.currentSong != nil {
                        self.restartPlaybackPlan(resumeFrom: self.elapsed)
                    }
                }
            })
            tokens.append(center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handleDidEnterBackground() }
            })
            tokens.append(center.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.preserveActivePlayback() }
            })
            tokens.append(center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.wantsPlayback else { return }
                    self.preserveActivePlayback()
                }
            })
            return tokens
        }
    }

    private func handleDidEnterBackground() {
        scheduleQueueSave(immediate: true)
        guard wantsPlayback else {
            scheduleAudioSessionDeactivation(immediate: true)
            return
        }
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
        if player.currentItem == nil || player.currentItem?.status == .failed {
            restartPlaybackPlan(resumeFrom: elapsed)
            updateNowPlaying()
            return
        }
        configureAudioSession()
        player.isMuted = false
        player.volume = 1
        player.playImmediately(atRate: 1)
        recomputeTimelineFromPlayer()
        installNextLyricBoundary(after: elapsed)
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

    private func handleAudioInterruption(
        typeRawValue: UInt?,
        optionsRawValue: UInt?
    ) {
        guard let rawValue = typeRawValue,
              let type = AVAudioSession.InterruptionType(rawValue: rawValue) else {
            return
        }
        switch type {
        case .began:
            resumeAfterInterruption = isPlaying || wantsPlayback
            wantsPlayback = false
            cancelPlaybackRecovery()
            markAudioSessionInactive()
            player.pause()
            endBackgroundBridge()
            scheduleQueueSave(immediate: true)
        case .ended:
            let rawOptions = optionsRawValue ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            guard resumeAfterInterruption, options.contains(.shouldResume) else {
                resumeAfterInterruption = false
                return
            }
            resumeAfterInterruption = false
            resumePlayback()
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reasonRawValue: UInt?) {
        guard let rawValue = reasonRawValue,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawValue) else {
            return
        }
        switch reason {
        case .oldDeviceUnavailable:
            // Avoid unexpectedly moving headphone or Bluetooth playback to
            // the device speaker when the previous output disappears.
            if isPlaying || wantsPlayback { pause() }
        case .newDeviceAvailable, .routeConfigurationChange:
            let shouldContinue = isPlaying || wantsPlayback
            configureAudioSession()
            if shouldContinue {
                resumePlayback()
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
        let canAutoplay = hasSong &&
            client != nil &&
            currentSong?.externalStreamURL == nil &&
            algorithmicAutoplayEnabled
        commands.playCommand.isEnabled = hasSong && !wantsPlayback
        commands.pauseCommand.isEnabled = hasSong && wantsPlayback
        commands.togglePlayPauseCommand.isEnabled = hasSong
        commands.nextTrackCommand.isEnabled =
            hasSong && (queue.count > 1 || canAutoplay)
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
            nowPlayingArtworkKey = nil
            nowPlayingInfoCenter.nowPlayingInfo = nil
            updateRemoteCommands()
            return
        }
        let songChanged = nowPlayingSongID != song.id
        if songChanged {
            nowPlayingArtworkTask?.cancel()
            nowPlayingSongID = song.id
            nowPlayingArtworkKey = nil
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
        activateNowPlayingSession()
        updateRemoteCommands()

        guard let coverID = song.coverArt,
              let client else {
            return
        }
        let artworkKey = "\(song.id)|\(coverID)"
        guard nowPlayingArtworkKey != artworkKey else { return }
        nowPlayingArtworkTask?.cancel()
        nowPlayingArtworkKey = artworkKey
        nowPlayingArtworkTask = Task {
            guard let url = try? await client.coverURL(id: coverID, size: 600),
                  let image = try? await ArtworkStore.shared.image(for: url, pixelSize: 600),
                  !Task.isCancelled,
                  self.currentSong?.id == song.id,
                  self.currentSong?.coverArt == coverID,
                  self.nowPlayingArtworkKey == artworkKey else {
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

    private func activateNowPlayingSession() {
        guard let nowPlayingSession, nowPlayingActivationTask == nil else { return }
        nowPlayingActivationTask = Task { [weak self] in
            _ = await nowPlayingSession.becomeActiveIfPossible()
            guard let self else { return }
            self.nowPlayingActivationTask = nil
        }
    }

    private func persistentID(for value: String) -> NSNumber {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return NSNumber(value: hash)
    }

    private var queueRestorationEnabled: Bool {
        UserDefaults.standard.object(forKey: "restore-play-queue") as? Bool ?? true
    }

    private var algorithmicAutoplayEnabled: Bool {
        UserDefaults.standard.object(forKey: "algorithmic-autoplay-enabled")
            as? Bool ?? true
    }

    private func provideTrackChangeHaptic() {
        let enabled =
            UserDefaults.standard.object(forKey: "haptics-enabled") as? Bool ?? true
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.62)
    }

    private func recordPlaybackStart(
        _ song: Song,
        origin: PlaybackOrigin
    ) {
        guard song.externalStreamURL == nil else {
            behaviorStartRecordedForSongID = nil
            return
        }
        behaviorStartRecordedForSongID = song.id
        reportPlaybackState("starting", song: song, position: 0)
        let previousMutation = historyMutationTask
        historyMutationTask = Task {
            _ = await previousMutation?.value
            await ListeningHistoryStore.shared.recordStart(
                song,
                origin: origin
            )
        }
    }

    private func finalizeCurrentPlayback(reason: PlaybackEndReason) {
        guard let song = currentSong,
              behaviorStartRecordedForSongID == song.id else {
            return
        }
        behaviorStartRecordedForSongID = nil
        let playedSeconds = elapsed
        let resolvedDuration = duration > 0 ? duration : song.safeDuration
        reportPlaybackState(
            "stopped",
            song: song,
            position: playedSeconds
        )
        let previousMutation = historyMutationTask
        historyMutationTask = Task {
            _ = await previousMutation?.value
            await ListeningHistoryStore.shared.recordEnd(
                song,
                playedSeconds: playedSeconds,
                duration: resolvedDuration,
                reason: reason
            )
        }
    }

    private func reportPlaybackState(
        _ state: String,
        song: Song? = nil,
        position: TimeInterval? = nil
    ) {
        guard let client,
              let song = song ?? currentSong,
              song.externalStreamURL == nil else {
            return
        }
        guard lastPlaybackReportSongID != song.id
                || lastPlaybackReportState != state else {
            return
        }
        lastPlaybackReportSongID = song.id
        lastPlaybackReportState = state
        let resolvedPosition = position ?? elapsed
        Task {
            await client.reportPlayback(
                id: song.id,
                position: resolvedPosition,
                state: state
            )
        }
    }

    private func submitScrobbleIfNeeded() {
        guard !scrobbled,
              let song = currentSong,
              song.externalStreamURL == nil,
              elapsed >= min(max(30, duration * 0.5), 240),
              let client else {
            return
        }
        scrobbled = true
        Task {
            try? await client.scrobble(id: song.id, submission: true)
        }
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
        let restorationEnabled = queueRestorationEnabled
        let replacingItems = snapshot.queue != lastPersistedQueue
        queueSaveTask = Task {
            if !immediate { try? await Task.sleep(for: .milliseconds(450)) }
            guard !Task.isCancelled else { return }
            let containsOnlyServerSongs = snapshot.queue.allSatisfy {
                $0.externalStreamURL == nil
            }
            if restorationEnabled && containsOnlyServerSongs {
                let saved = await AppDatabase.shared.saveQueue(
                    snapshot,
                    replacingItems: replacingItems
                )
                guard !Task.isCancelled else { return }
                if saved { lastPersistedQueue = snapshot.queue }
                UserDefaults.standard.removeObject(forKey: queueStorageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: queueStorageKey)
                lastPersistedQueue = nil
                await AppDatabase.shared.clearQueue()
            }
            guard let client,
                  let current = snapshot.currentID,
                  !snapshot.queue.isEmpty,
                  containsOnlyServerSongs else {
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
        queueRestoreTask?.cancel()
        queueRestoreTask = Task { [weak self] in
            guard let self else { return }
            var snapshot = await AppDatabase.shared.loadQueue()
            if snapshot == nil,
               let data = UserDefaults.standard.data(forKey: self.queueStorageKey),
               let legacy = try? JSONDecoder().decode(QueueSnapshot.self, from: data),
               !legacy.queue.isEmpty,
               legacy.queue.allSatisfy({ $0.externalStreamURL == nil }),
               await AppDatabase.shared.saveQueue(legacy) {
                snapshot = legacy
                UserDefaults.standard.removeObject(forKey: self.queueStorageKey)
            }
            guard !Task.isCancelled, let snapshot,
                  !snapshot.queue.isEmpty,
                  snapshot.queue.allSatisfy({ $0.externalStreamURL == nil }),
                  self.queue.isEmpty,
                  self.currentSong == nil else { return }
            self.applyRestoredQueue(snapshot)
            self.queueRestoreTask = nil
        }
    }

    private func applyRestoredQueue(_ snapshot: QueueSnapshot) {
        lastPersistedQueue = snapshot.queue
        queue = snapshot.queue
        queueIndex = snapshot.currentID.flatMap { currentID in
            snapshot.queue.firstIndex(where: { $0.id == currentID })
        } ?? (snapshot.queue.indices.contains(snapshot.index) ? snapshot.index : 0)
        currentSong = snapshot.queue[queueIndex]
        let restoredElapsed = snapshot.elapsed.isFinite ? max(0, snapshot.elapsed) : 0
        let restoredDuration = currentSong?.safeDuration ?? 0
        elapsed = restoredDuration > 0
            ? min(restoredElapsed, restoredDuration)
            : restoredElapsed
        duration = restoredDuration
        isShuffleEnabled = snapshot.shuffle
        repeatMode = snapshot.repeatMode
    }
}

struct QueueSnapshot: Codable, Sendable {
    let queue: [Song]
    let currentID: String?
    let index: Int
    let elapsed: TimeInterval
    let shuffle: Bool
    let repeatMode: RepeatMode
}

private actor AudioSessionController {
    private var isConfigured = false
    private var isActive = false
    private var latestCommandEpoch: UInt64 = 0

    func activate(epoch: UInt64) -> Bool {
        guard accept(epoch: epoch) else { return false }
        if isActive { return true }
        do {
            let session = AVAudioSession.sharedInstance()
            if !isConfigured {
                try session.setCategory(
                    .playback,
                    mode: .default,
                    policy: .longFormAudio
                )
                isConfigured = true
            }
            try session.setActive(true)
            isActive = true
            return true
        } catch {
            // A later ready, route, or interruption event retries activation.
            isActive = false
            return false
        }
    }

    func markInactive(epoch: UInt64) {
        guard accept(epoch: epoch) else { return }
        isActive = false
    }

    func deactivate(epoch: UInt64) {
        guard accept(epoch: epoch) else { return }
        guard isActive else { return }
        defer { isActive = false }
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    func resetAndActivate(epoch: UInt64) -> Bool {
        guard accept(epoch: epoch) else { return false }
        isConfigured = false
        isActive = false
        return activate(epoch: epoch)
    }

    private func accept(epoch: UInt64) -> Bool {
        guard epoch >= latestCommandEpoch else { return false }
        latestCommandEpoch = epoch
        return true
    }
}
