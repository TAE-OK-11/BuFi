import AVFoundation
import Combine
import MediaPlayer
import Network
import OSLog
import UIKit

/// MediaPlayer retains the request handler and invokes it on its private
/// `*/accessQueue`, not on the actor that creates the artwork. Keeping the
/// immutable CGImage-backed value in an explicitly Sendable provider prevents
/// Swift 6 from inferring MainActor isolation for that callback. The UIImage
/// wrapper is created on MediaPlayer's executor instead of crossing into it.
struct NowPlayingArtworkProvider: Sendable {
    private let image: ArtworkImage

    init(image: ArtworkImage) {
        self.image = image
    }

    func makeArtwork() -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { @Sendable [self] _ in
            image.value
        }
    }
}

/// Serializes the two delayed/network tasks that must not escape an account
/// session. A synchronous `configure` can invalidate work immediately while
/// the drain task provides an awaitable barrier for shutdown and any work
/// scheduled by the replacement session.
@MainActor
final class PlayerTaskLifecycle {
    private(set) var scrobbleTask: Task<Void, Never>?
    private(set) var backgroundRecoveryTask: Task<Void, Never>?
    private(set) var sessionTransitionTask: Task<Void, Never>?

    private var scrobbleToken: UUID?
    private var backgroundRecoveryToken: UUID?
    private var sessionTransitionToken: UUID?

    func scheduleScrobble(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) {
        let previousTask = scrobbleTask
        let transitionTask = sessionTransitionTask
        previousTask?.cancel()

        let token = UUID()
        scrobbleToken = token
        scrobbleTask = Task { [weak self] in
            _ = await transitionTask?.value
            _ = await previousTask?.value
            guard !Task.isCancelled else { return }
            await operation()
            guard let self, self.scrobbleToken == token else { return }
            self.scrobbleTask = nil
            self.scrobbleToken = nil
        }
    }

    func scheduleBackgroundRecovery(
        after delay: Duration,
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) {
        let previousTask = backgroundRecoveryTask
        previousTask?.cancel()

        let token = UUID()
        backgroundRecoveryToken = token
        backgroundRecoveryTask = Task { [weak self] in
            _ = await previousTask?.value
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await operation()
            guard let self, self.backgroundRecoveryToken == token else { return }
            self.backgroundRecoveryTask = nil
            self.backgroundRecoveryToken = nil
        }
    }

    func cancelBackgroundRecovery() {
        backgroundRecoveryToken = nil
        backgroundRecoveryTask?.cancel()
        backgroundRecoveryTask = nil
    }

    /// Cancels session-bound work and returns one task that completes only
    /// after every task owned by the old session has exited.
    @discardableResult
    func beginSessionTransition() -> Task<Void, Never>? {
        let previousTransition = sessionTransitionTask
        let pendingScrobble = scrobbleTask
        let pendingBackgroundRecovery = backgroundRecoveryTask

        scrobbleToken = nil
        backgroundRecoveryToken = nil
        pendingScrobble?.cancel()
        pendingBackgroundRecovery?.cancel()
        scrobbleTask = nil
        backgroundRecoveryTask = nil

        guard previousTransition != nil
                || pendingScrobble != nil
                || pendingBackgroundRecovery != nil else {
            sessionTransitionTask = nil
            sessionTransitionToken = nil
            return nil
        }

        let token = UUID()
        sessionTransitionToken = token
        let transition = Task { [weak self] in
            _ = await previousTransition?.value
            _ = await pendingScrobble?.value
            _ = await pendingBackgroundRecovery?.value
            guard let self, self.sessionTransitionToken == token else { return }
            self.sessionTransitionTask = nil
            self.sessionTransitionToken = nil
        }
        sessionTransitionTask = transition
        return transition
    }
}

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
    enum Status: Equatable, Sendable {
        case idle
        case loading
        case available
        case unavailable
        case failed
    }

    // Lyric highlighting has its own render boundary for the same reason.
    @Published fileprivate(set) var document = LyricsDocument.empty
    @Published fileprivate(set) var activeIndex = -1
    @Published fileprivate(set) var status: Status = .idle
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

struct PlaybackSnapshot: Equatable, Sendable {
    let entries: [PlaybackQueueEntry]
    let songs: [Song]
    let index: Int
    let accountScope: String?
    let playbackGenerationID: UUID?

    static let empty = PlaybackSnapshot(
        entries: [],
        index: -1,
        accountScope: nil,
        playbackGenerationID: nil
    )

    init(
        entries: [PlaybackQueueEntry],
        index: Int,
        accountScope: String?,
        playbackGenerationID: UUID? = nil
    ) {
        self.entries = entries
        songs = entries.map(\.song)
        self.accountScope = accountScope
        if entries.isEmpty {
            self.index = -1
            self.playbackGenerationID = nil
        } else {
            self.index = min(max(index, 0), entries.count - 1)
            self.playbackGenerationID = playbackGenerationID ?? UUID()
        }
    }

    var currentItem: PlaybackMediaItem? {
        guard entries.indices.contains(index),
              let playbackGenerationID else { return nil }
        let entry = entries[index]
        return PlaybackMediaItem(
            song: entry.song,
            accountScope: accountScope,
            queueEntryID: entry.id,
            playbackGenerationID: playbackGenerationID
        )
    }

    var currentSong: Song? { currentItem?.song }
}

struct CurrentPlaybackSnapshot: Equatable, Sendable {
    let item: PlaybackMediaItem?
    let index: Int
    let queueCount: Int

    static let empty = CurrentPlaybackSnapshot(
        item: nil,
        index: -1,
        queueCount: 0
    )

    init(snapshot: PlaybackSnapshot) {
        item = snapshot.currentItem
        index = snapshot.index
        queueCount = snapshot.entries.count
    }

    private init(item: PlaybackMediaItem?, index: Int, queueCount: Int) {
        self.item = item
        self.index = index
        self.queueCount = queueCount
    }

    var song: Song? { item?.song }
}

@MainActor
final class CurrentPlaybackState: ObservableObject {
    @Published fileprivate(set) var snapshot = CurrentPlaybackSnapshot.empty

    var item: PlaybackMediaItem? { snapshot.item }
    var song: Song? { snapshot.song }
    var index: Int { snapshot.index }
    var queueCount: Int { snapshot.queueCount }

    fileprivate func publish(_ value: CurrentPlaybackSnapshot) {
        guard snapshot != value else { return }
        snapshot = value
    }
}

@MainActor
final class PlaybackState: ObservableObject {
    /// Current media, queue contents, selection, and account scope are derived
    /// from one publication. No view can combine revisions from separate
    /// ObservableObjects during a track transition.
    @Published fileprivate(set) var snapshot = PlaybackSnapshot.empty
    let current = CurrentPlaybackState()
    private(set) var entriesRevision: UInt64 = 0

    var entries: [PlaybackQueueEntry] { snapshot.entries }
    var songs: [Song] { snapshot.songs }
    var index: Int { snapshot.index }
    var currentItem: PlaybackMediaItem? { snapshot.currentItem }
    var currentSong: Song? { snapshot.currentSong }

    fileprivate func setIndex(
        _ value: Int,
        renewsPlayback: Bool = true
    ) {
        let entries = snapshot.entries
        let resolvedIndex = entries.isEmpty
            ? -1
            : min(max(value, 0), entries.count - 1)
        publish(PlaybackSnapshot(
            entries: entries,
            index: resolvedIndex,
            accountScope: snapshot.accountScope,
            playbackGenerationID: renewsPlayback
                ? UUID()
                : snapshot.playbackGenerationID
        ))
    }

    fileprivate func setAccountScope(_ value: String?) {
        publish(PlaybackSnapshot(
            entries: snapshot.entries,
            index: snapshot.index,
            accountScope: value,
            playbackGenerationID: snapshot.playbackGenerationID
        ))
    }

    fileprivate func replace(
        songs: [Song],
        index: Int,
        accountScope: String?
    ) {
        publish(PlaybackSnapshot(
            entries: songs.map { PlaybackQueueEntry(song: $0) },
            index: index,
            accountScope: accountScope,
            playbackGenerationID: UUID()
        ))
    }

    fileprivate func replace(
        entries: [PlaybackQueueEntry],
        index: Int,
        accountScope: String?,
        renewsPlayback: Bool = false
    ) {
        publish(PlaybackSnapshot(
            entries: entries,
            index: index,
            accountScope: accountScope,
            playbackGenerationID: renewsPlayback
                ? UUID()
                : snapshot.playbackGenerationID
        ))
    }

    private func publish(_ value: PlaybackSnapshot) {
        guard snapshot != value else { return }
        if snapshot.entries != value.entries {
            entriesRevision &+= 1
        }
        snapshot = value
        current.publish(CurrentPlaybackSnapshot(snapshot: value))
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

enum PlaybackFailureDisposition: Equatable, Sendable {
    case retryTransport
    case tryCompatibilityFormat
}

enum PlaybackFailureClassifier {
    static func disposition(for error: Error?) -> PlaybackFailureDisposition {
        disposition(for: error, depth: 0)
    }

    private static func disposition(
        for error: Error?,
        depth: Int
    ) -> PlaybackFailureDisposition {
        guard let error else { return .tryCompatibilityFormat }
        let value = error as NSError
        guard value.domain == NSURLErrorDomain else {
            if depth < 2,
               let underlying = value.userInfo[NSUnderlyingErrorKey] as? Error {
                return disposition(for: underlying, depth: depth + 1)
            }
            return .tryCompatibilityFormat
        }
        let code = URLError.Code(rawValue: value.code)
        switch code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet,
             .internationalRoamingOff, .callIsActive, .dataNotAllowed,
             .secureConnectionFailed, .cannotLoadFromNetwork:
            return .retryTransport
        default:
            return .tryCompatibilityFormat
        }
    }
}

/// Pure decisions used by the bounded playback watchdog. Keeping these
/// decisions outside AVPlayer makes the zero-position and format-fallback
/// behavior deterministic and regression-testable.
enum PlaybackRecoveryPolicy {
    static func startupNudgeTarget(
        elapsed: TimeInterval,
        duration: TimeInterval,
        alreadyAttempted: Bool
    ) -> TimeInterval? {
        guard !alreadyAttempted,
              elapsed.isFinite,
              elapsed <= 0.1 else {
            return nil
        }
        guard duration.isFinite, duration > 0 else { return nil }
        let preferredTarget = max(0.05, min(0.25, duration * 0.001))
        let latestValidTarget = max(0, duration - 0.01)
        let target = min(
            max(preferredTarget, elapsed + 0.05),
            latestValidTarget
        )
        return target > elapsed ? target : nil
    }

    static func hasMeaningfulProgress(
        from start: TimeInterval,
        to end: TimeInterval
    ) -> Bool {
        start.isFinite && end.isFinite && end >= start + 0.1
    }

    static func nextCompatibilityIndex(
        in formats: [String],
        from startIndex: Int,
        allowsRaw: Bool
    ) -> Int? {
        guard startIndex < formats.count else { return nil }
        return formats.indices.first {
            $0 >= max(0, startIndex)
                && (allowsRaw || formats[$0].lowercased() != "raw")
        }
    }
}

struct GaplessSuccessorPlan: Equatable, Sendable {
    let queueIndex: Int

    static func make(
        queueCount: Int,
        currentIndex: Int,
        shuffleEnabled: Bool,
        repeatMode: RepeatMode
    ) -> GaplessSuccessorPlan? {
        guard queueCount > 0,
              (0..<queueCount).contains(currentIndex),
              !shuffleEnabled,
              repeatMode != .one else { return nil }
        if currentIndex + 1 < queueCount {
            return GaplessSuccessorPlan(queueIndex: currentIndex + 1)
        }
        return repeatMode == .all
            ? GaplessSuccessorPlan(queueIndex: 0)
            : nil
    }
}

@MainActor
final class AudioEngine: NSObject, ObservableObject {
    private struct ServerQueueSaveRequest: Sendable {
        let client: OpenSubsonicClient
        let accountScope: String
        let sessionGeneration: UInt64
        let revision: UInt64
        let songIDs: [String]
        let currentID: String
        let position: TimeInterval
    }

    static let shared = AudioEngine()

    let playbackState = PlaybackState()
    let activityState = PlaybackActivityState()
    let controlState = PlaybackControlState()
    let presentation = PlayerPresentationState()
    let timeline = PlaybackTimeline()
    let lyricsState = LyricsPlaybackState()

    var currentSong: Song? { playbackState.currentSong }

    private var currentPlaybackItem: PlaybackMediaItem? {
        playbackState.currentItem
    }

    var queue: [Song] { playbackState.songs }

    private var queueIndex: Int { playbackState.index }

    private func replaceQueue(
        _ entries: [PlaybackQueueEntry],
        index: Int
    ) {
        playbackState.replace(
            entries: entries,
            index: index,
            accountScope: currentAccountScope
        )
    }

    private func replacePlayback(
        _ entries: [PlaybackQueueEntry],
        index: Int
    ) {
        playbackState.replace(
            entries: entries,
            index: index,
            accountScope: currentAccountScope,
            renewsPlayback: true
        )
    }

    private func replacePlayback(_ songs: [Song], index: Int) {
        playbackState.replace(
            songs: songs,
            index: index,
            accountScope: currentAccountScope
        )
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

    // The logical queue below remains the source of truth. AVQueuePlayer is
    // used as a two-item transport window so a validated successor can begin
    // without rebuilding the playback pipeline at the track boundary.
    private(set) lazy var player = AVQueuePlayer()

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
        let queueEntryID: UUID
        let songID: String
        let streamRevision: String
        let compatibilityFormat: String
        let asset: AVURLAsset
    }

    private var nowPlayingSession: MPNowPlayingSession?
    private var client: OpenSubsonicClient?
    private var currentAccountScope: String?
    private var historySessionToken: AccountSessionToken?
    private var playbackSessionGeneration: UInt64 = 0
    private var queueMutationGeneration: UInt64 = 0
    private var queueRestorationGeneration: UInt64 = 0
    private var songFavoriteMutationHandler: (@MainActor (Song) async -> Bool)?
    private var autoplayContinuationProvider:
        (@MainActor (Song, Set<String>) async -> [Song])?
    private var itemObservation: NSKeyValueObservation?
    private weak var logicalCurrentItem: AVPlayerItem?
    private var currentItemTransitionObservation: NSKeyValueObservation?
    private var stagedSuccessorObservation: NSKeyValueObservation?
    private var stagedSuccessorObservationID: UUID?
    private var itemBufferObservations: [NSKeyValueObservation] = []
    private var timeControlObservation: NSKeyValueObservation?
    private lazy var playbackObservers = PlaybackObserverCoordinator(
        player: player
    )
    // NWPathMonitor can synchronously connect to system networking services
    // while it is created. Keep even its construction out of App/StateObject
    // initialization and build it with the rest of the playback runtime.
    private lazy var networkPathMonitor = NWPathMonitor()
    private let networkPathQueue = DispatchQueue(
        label: "cloud.tae00217.BuFi.prefetch-network-path",
        qos: .utility
    )
    private var fallbackIndex = 0
    private var fallbackFormats: [String] = []
    private var scrobbled = false
    private let playerTaskLifecycle = PlayerTaskLifecycle()
    private var queueSaveTask: Task<Void, Never>?
    private var queueClearTask: Task<Void, Never>?
    private var itemLoadTask: Task<Void, Never>?
    private var lyricsTask: Task<Void, Never>?
    private var songMetadataTask: Task<Void, Never>?
    private var serverQueueTask: Task<Void, Never>?
    private var serverQueueSaveTask: Task<Void, Never>?
    private var pendingServerQueueSave: ServerQueueSaveRequest?
    private var latestServerQueueSaveRevision: UInt64 = 0
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
    private weak var stagedSuccessorItem: AVPlayerItem?
    private var stagedSuccessorSong: Song?
    private var stagedSuccessorQueueIndex: Int?
    private var stagedSuccessorOccurrenceID: UUID?
    private var autoplayTask: Task<Void, Never>?
    private var historyMutationTask: Task<Void, Never>?
    private var playbackReportTask: Task<Void, Never>?
    private var nowPlayingVisualKey: String?
    private var nowPlayingArtworkKey: String?
    private var nowPlayingArtworkRequestKey: String?
    private var resumeAfterInterruption = false
    private var activeCompatibilityFormat: String?
    private var recoveryTask: Task<Void, Never>?
    private var recoveryStabilityTask: Task<Void, Never>?
    private var audioSessionActivationTask: Task<Void, Never>?
    private var audioSessionActivationToken: UUID?
    private var audioSessionDeactivationTask: Task<Void, Never>?
    private var audioSessionCommandEpoch: UInt64 = 0
    private var nowPlayingActivationTask: Task<Void, Never>?
    private let audioSessionController = AudioSessionController()
    private var recoveryToken: UUID?
    private weak var handledFailedItem: AVPlayerItem?
    private weak var startupNudgedItem: AVPlayerItem?
    private var recoveryAttempt = 0
    private var itemLoadGeneration: UInt64 = 0
    private var lyricsLoadGeneration: UInt64 = 0
    private var songMetadataGeneration: UInt64 = 0
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
    private var lastServerQueueSaveRequest = Date.distantPast
    private var lastMaintenanceSecond = -1
    private var behaviorStartRecordedForSongID: String?
    private var lastPlaybackReportSongID: String?
    private var lastPlaybackReportState: String?
    private let queueStorageKey = "native-play-queue"
    private var queueRestoreTask: Task<Void, Never>?
    private var queueSaveRevision: UInt64 = 0
    private var lastPersistedEntriesRevision: UInt64?
    private var allowsSpeculativeNetworkPrefetch = false
    private var networkPathIsSatisfied = true
    private var runtimeIsActive = false

    override private init() {
        quality = StreamQuality(
            rawValue: UserDefaults.standard.string(forKey: "stream-quality") ?? ""
        ) ?? .automatic
        shuffleStyle = ShuffleStyle(
            rawValue: UserDefaults.standard.string(forKey: "shuffle-style") ?? ""
        ) ?? .fewerRepeats
        super.init()
    }

    /// Installs framework callbacks only after SwiftUI has mounted its first
    /// scene. Besides reducing launch work, this prevents Objective-C media
    /// services from participating in `App`/`StateObject` construction.
    func activateRuntimeIfNeeded() {
        guard !runtimeIsActive else { return }
        runtimeIsActive = true
        LaunchDiagnostics.mark("audio-runtime-starting")
        LaunchDiagnostics.mark("audio-player-creating")
        player.automaticallyWaitsToMinimizeStalling = true
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
            // iOS 27 beta devices have shown pre-framework and MediaPlayer
            // launch instability. This app has one player, so the shared
            // command/info centers preserve lock-screen controls without
            // constructing the optional per-player session on that beta.
            nowPlayingSession = nil
            LaunchDiagnostics.mark("now-playing-session-shared-fallback")
        } else {
            LaunchDiagnostics.mark("now-playing-session-creating")
            nowPlayingSession = MPNowPlayingSession(players: [player])
            nowPlayingSession?.automaticallyPublishesNowPlayingInfo = false
        }
        LaunchDiagnostics.mark("player-observers-installing")
        installPlayerObservers()
        LaunchDiagnostics.mark("system-observers-installing")
        installSystemObservers()
        LaunchDiagnostics.mark("network-monitor-installing")
        installNetworkPathMonitor()
        LaunchDiagnostics.mark("remote-commands-installing")
        installRemoteCommands()
        LaunchDiagnostics.mark("audio-runtime-ready")
    }

    func configure(
        client: OpenSubsonicClient?,
        historySession: AccountSessionToken? = nil,
        songFavoriteMutationHandler: (@MainActor (Song) async -> Bool)? = nil,
        autoplayContinuationProvider:
            (@MainActor (Song, Set<String>) async -> [Song])? = nil
    ) {
        playbackSessionGeneration &+= 1
        let sessionGeneration = playbackSessionGeneration
        playerTaskLifecycle.beginSessionTransition()
        let previousAccountScope = currentAccountScope
        serverQueueTask?.cancel()
        serverQueueTask = nil
        songMetadataTask?.cancel()
        songMetadataTask = nil
        songMetadataGeneration &+= 1
        autoplayTask?.cancel()
        autoplayTask = nil
        autoplayGeneration &+= 1
        autoplayShouldAdvance = false
        self.client = client
        currentAccountScope = client?.accountScope
        if previousAccountScope != currentAccountScope {
            pendingServerQueueSave = nil
            serverQueueSaveTask?.cancel()
            latestServerQueueSaveRevision = 0
            lastServerQueueSaveRequest = .distantPast
            suspendSpeculativePrefetch()
        }
        self.songFavoriteMutationHandler = songFavoriteMutationHandler
        self.autoplayContinuationProvider = autoplayContinuationProvider
        if client == nil {
            finalizeCurrentPlayback(reason: .stopped)
            historySessionToken = nil
            let pendingQueueSave = queueSaveTask
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
            nowPlayingArtworkRequestKey = nil
            itemLoadGeneration &+= 1
            lyricsLoadGeneration &+= 1
            seekGeneration &+= 1
            isSeekInFlight = false
            pendingSeekPosition = nil
            UserDefaults.standard.removeObject(forKey: queueStorageKey)
            lastPersistedEntriesRevision = nil
            queueRestoreTask?.cancel()
            queueRestoreTask = nil
            if let previousAccountScope {
                queueSaveRevision &+= 1
                let clearRevision = queueSaveRevision
                let previousClear = queueClearTask
                queueClearTask = Task {
                    _ = await previousClear?.value
                    _ = await pendingQueueSave?.value
                    await AppDatabase.shared.clearQueue(
                        scope: previousAccountScope,
                        minimumRevision: clearRevision
                    )
                }
            }
            pausePlayback(persistsQueue: false)
            replaceQueue([], index: -1)
            queueMutationGeneration &+= 1
            elapsed = 0
            duration = 0
            isBuffering = false
            playbackError = nil
            showFullLyrics = false
            applyLyricsDocument(.empty)
            removeCurrentItemObservers()
            invalidateStagedSuccessor(removeFromPlayer: true)
            player.replaceCurrentItem(with: nil)
            updateNowPlaying()
            return
        }

        historySessionToken = historySession

        if let song = currentSong {
            if previousAccountScope != currentAccountScope {
                playbackState.setAccountScope(currentAccountScope)
            }
            restartPlaybackPlan(resumeFrom: elapsed)
            loadLyrics(for: song)
            refreshCanonicalMetadata(for: song)
        }

        guard queueRestorationEnabled,
              let accountScope = currentAccountScope else { return }
        let restorationRevision = queueMutationGeneration
        restoreLocalQueue(
            accountScope: accountScope,
            sessionGeneration: sessionGeneration,
            expectedQueueRevision: restorationRevision
        )
        let localRestoreTask = queueRestoreTask
        serverQueueTask = Task { [weak self] in
            _ = await localRestoreTask?.value
            guard let self,
                  !Task.isCancelled,
                  sessionGeneration == self.playbackSessionGeneration,
                  accountScope == self.currentAccountScope,
                  self.queue.isEmpty,
                  self.currentSong == nil else {
                return
            }
            let requestRevision = self.queueMutationGeneration
            guard let serverQueue = try? await client?.playQueue(),
                  !Task.isCancelled,
                  sessionGeneration == self.playbackSessionGeneration,
                  accountScope == self.currentAccountScope,
                  requestRevision == self.queueMutationGeneration,
                  !serverQueue.songs.isEmpty,
                  !self.isPlaying,
                  !self.wantsPlayback else {
                return
            }
            let restoredIndex = serverQueue.songs.firstIndex {
                $0.id == serverQueue.currentID
            } ?? 0
            self.replacePlayback(serverQueue.songs, index: restoredIndex)
            self.queueMutationGeneration &+= 1
            self.behaviorStartRecordedForSongID = nil
            self.duration = self.currentSong?.safeDuration ?? 0
            let restoredPosition = max(0, serverQueue.position)
            self.elapsed = self.duration > 0 ? min(restoredPosition, self.duration) : restoredPosition
            self.applyLyricsDocument(.empty)
            self.updateNowPlaying()
            self.loadLyrics(for: serverQueue.songs[restoredIndex])
            self.refreshCanonicalMetadata(
                for: serverQueue.songs[restoredIndex]
            )
        }
    }

    /// Ends the current account session in a deterministic order. The final
    /// behavior sample is committed before the listening store is detached,
    /// and the queue is cleared only after every older save task is cancelled.
    func shutdownForSessionEnd() async {
        finalizeCurrentPlayback(reason: .stopped)
        let finalHistoryMutation = historyMutationTask
        let pendingQueueSave = queueSaveTask
        let pendingServerQueueSave = serverQueueSaveTask
        let finalPlaybackReport = playbackReportTask
        configure(client: nil)
        let finalPlayerTaskDrain = playerTaskLifecycle.sessionTransitionTask
        let finalQueueClear = queueClearTask
        // Cancellation cannot interrupt a GRDB transaction that has already
        // started. Wait for the old save task before the final delete so a
        // late account-session snapshot can never recreate the queue.
        _ = await pendingQueueSave?.value
        _ = await pendingServerQueueSave?.value
        _ = await finalQueueClear?.value
        _ = await finalHistoryMutation?.value
        _ = await finalPlaybackReport?.value
        _ = await finalPlayerTaskDrain?.value
        historyMutationTask = nil
        playbackReportTask = nil
    }

    func play(
        _ song: Song,
        in sourceQueue: [Song],
        queueIndex: Int? = nil,
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
            preferredIndex: queueIndex,
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
        let songs = sourceQueue.isEmpty ? [song] : sourceQueue
        startPlayback(
            song,
            in: songs.map { PlaybackQueueEntry(song: $0) },
            preferredIndex: preferredIndex,
            autoplay: autoplay,
            origin: origin,
            transitionReason: transitionReason
        )
    }

    private func startPlayback(
        _ song: Song,
        in sourceEntries: [PlaybackQueueEntry],
        preferredIndex: Int?,
        autoplay: Bool = true,
        origin: PlaybackOrigin = .manual,
        transitionReason: PlaybackEndReason = .replaced
    ) {
        activateRuntimeIfNeeded()
        reconcilePendingTransportTransition()
        // Every concrete track transition supersedes an in-flight autoplay
        // request. Keeping this invalidation here (rather than only in the
        // public `play` entry point) also covers queue taps, skips, restores,
        // and repeat transitions.
        autoplayTask?.cancel()
        autoplayTask = nil
        autoplayGeneration &+= 1
        autoplayShouldAdvance = false
        // An explicit selection supersedes a pending server queue restore,
        // including the interval before AVPlayer reaches the playing state.
        serverQueueTask?.cancel()
        cancelPlaybackRecovery()
        let previousSongID = currentSong?.id
        finalizeCurrentPlayback(reason: transitionReason)
        var normalizedEntries = sourceEntries.isEmpty
            ? [PlaybackQueueEntry(song: song)]
            : sourceEntries
        let resolvedIndex: Int
        if let preferredIndex, normalizedEntries.indices.contains(preferredIndex) {
            resolvedIndex = preferredIndex
        } else if let visualMatch = normalizedEntries.firstIndex(where: {
            $0.song.id == song.id && $0.song.artworkID == song.artworkID
        }) {
            resolvedIndex = visualMatch
        } else {
            resolvedIndex = normalizedEntries.firstIndex(where: {
                $0.song.id == song.id
            }) ?? 0
        }
        if normalizedEntries[resolvedIndex].song.id == song.id {
            // The tapped row is the freshest metadata source. Replacing the
            // matching queue entry atomically prevents an older coverArt value
            // from becoming the visual now-playing source for this transition.
            normalizedEntries[resolvedIndex].song = song
        }
        let selectedSong = normalizedEntries[resolvedIndex].song
        // Current media, queue entries, selection, and account scope publish as
        // one snapshot. A fresh playback generation invalidates late artwork
        // and transport work without changing the durable queue-row identity.
        replacePlayback(normalizedEntries, index: resolvedIndex)
        queueMutationGeneration &+= 1
        player.pause()
        isPlaying = false
        seekGeneration &+= 1
        isSeekInFlight = false
        pendingSeekPosition = nil
        removeCurrentItemObservers()
        invalidateStagedSuccessor(removeFromPlayer: true)
        player.replaceCurrentItem(with: nil)
        recordPlaybackStart(selectedSong, origin: origin)
        rememberShuffleSelection(selectedSong.id)
        elapsed = 0
        duration = selectedSong.safeDuration
        applyLyricsDocument(.empty)
        fallbackIndex = 0
        fallbackFormats = Self.fallbackFormats(for: quality, song: selectedSong)
        recoveryAttempt = 0
        recoveryStabilityTask?.cancel()
        recoveryStabilityTask = nil
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
        refreshCanonicalMetadata(for: selectedSong)
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
        activateRuntimeIfNeeded()
        if wantsPlayback || isPlaying || player.timeControlStatus == .playing {
            pause()
        } else {
            resumePlayback()
        }
    }

    func resumePlayback() {
        guard currentSong != nil else { return }
        activateRuntimeIfNeeded()
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
            recoveryAttempt = 0
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
        // A pause chosen while an audio interruption is active must remain a
        // pause when the interruption ends.
        resumeAfterInterruption = false
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
        persistsQueue: Bool,
        resumesPlayback: Bool = false,
        exactly: Bool = false
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
        guard player.currentItem != nil else {
            isSeekInFlight = false
            if persistsQueue { scheduleQueueSave() }
            return
        }
        let tolerance = exactly
            ? CMTime.zero
            : CMTime(seconds: 0.1, preferredTimescale: 600)
        seekGeneration &+= 1
        let generation = seekGeneration
        isSeekInFlight = true
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        ) { @Sendable [weak self] finished in
            Task { @MainActor in
                guard let self, self.seekGeneration == generation else { return }
                self.isSeekInFlight = false
                self.pendingSeekPosition = nil
                guard self.player.currentItem != nil else { return }
                self.recomputeTimelineFromPlayer()
                self.installNextLyricBoundary(after: self.elapsed)
                self.updateNowPlaying()
                if resumesPlayback, finished, self.wantsPlayback {
                    self.configureAudioSession()
                    self.player.playImmediately(atRate: 1)
                }
                if persistsQueue, finished {
                    self.scheduleQueueSave()
                }
            }
        }
    }

    /// `isAutoAdvance`는 곡의 종료 알림으로 호출된 경우에만 true.
    /// 사용자가 다음곡 버튼/리모컨으로 직접 스킵한 경우는 false — 이 경우엔
    /// "1곡 반복" 모드여도 같은 곡을 재시작하지 않고 실제로 다음 곡으로 넘어가야 함.
    /// (이전에는 이 구분이 없어 수동 스킵도 같은 곡이 반복 재생되는 버그가 있었음.)
    func next(isAutoAdvance: Bool = false) {
        reconcilePendingTransportTransition()
        guard !queue.isEmpty else { return }
        if isAutoAdvance, repeatMode == .one, let song = currentSong {
            startPlayback(
                song,
                in: playbackState.entries,
                preferredIndex: queueIndex,
                origin: .autoplay,
                transitionReason: .completed
            )
            return
        }

        let nextIndex: Int
        if isShuffleEnabled, queue.count > 1 {
            nextIndex = nextShuffleIndex()
        } else if queueIndex < queue.count - 1 {
            nextIndex = queueIndex + 1
        } else if repeatMode == .all || (isAutoAdvance && repeatMode == .one) {
            nextIndex = 0
        } else {
            requestAutoplayContinuation(advanceWhenReady: true)
            return
        }
        startPlayback(
            queue[nextIndex],
            in: playbackState.entries,
            preferredIndex: nextIndex,
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
            let appendedEntries = self.playbackState.entries
                + additions.map { PlaybackQueueEntry(song: $0) }
            self.replaceQueue(appendedEntries, index: self.queueIndex)
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
        reconcilePendingTransportTransition()
        if elapsed > 4 {
            seek(to: 0)
            return
        }
        guard !queue.isEmpty else { return }
        let previousIndex = queueIndex > 0
            ? queueIndex - 1
            : (repeatMode == .all ? queue.count - 1 : 0)
        startPlayback(
            queue[previousIndex],
            in: playbackState.entries,
            preferredIndex: previousIndex,
            origin: .manual,
            transitionReason: .skipped
        )
    }

    func playQueueItem(at index: Int) {
        reconcilePendingTransportTransition()
        guard queue.indices.contains(index) else { return }
        startPlayback(
            queue[index],
            in: playbackState.entries,
            preferredIndex: index,
            origin: .queue,
            transitionReason: .replaced
        )
    }

    func removeQueueItem(at index: Int) {
        reconcilePendingTransportTransition()
        guard queue.indices.contains(index) else { return }
        if index == queueIndex {
            excludeCurrentAndAdvance()
            return
        }
        let removedSong = queue[index]
        var updatedEntries = playbackState.entries
        updatedEntries.remove(at: index)
        let updatedIndex = index < queueIndex ? queueIndex - 1 : queueIndex
        replaceQueue(updatedEntries, index: updatedIndex)
        recordQueueRemovals([removedSong])
        queueDidChange()
    }

    func enqueueNext(_ song: Song) {
        reconcilePendingTransportTransition()
        guard queue.indices.contains(queueIndex) else {
            play(song, in: [song])
            return
        }
        var updatedEntries = entriesRemovingUpcomingOccurrence(of: song.id)
        updatedEntries.insert(
            PlaybackQueueEntry(song: song),
            at: min(queueIndex + 1, updatedEntries.count)
        )
        replaceQueue(updatedEntries, index: queueIndex)
        queueDidChange()
    }

    func enqueue(_ song: Song) {
        reconcilePendingTransportTransition()
        guard queue.indices.contains(queueIndex) else {
            play(song, in: [song])
            return
        }
        var updatedEntries = entriesRemovingUpcomingOccurrence(of: song.id)
        updatedEntries.append(PlaybackQueueEntry(song: song))
        replaceQueue(updatedEntries, index: queueIndex)
        queueDidChange()
    }

    func moveQueueItems(from offsets: IndexSet, to destination: Int) {
        reconcilePendingTransportTransition()
        guard !offsets.isEmpty else { return }
        let currentOriginalIndex = queueIndex
        let entries = playbackState.entries
        let moved = offsets.sorted().compactMap { index in
            entries.indices.contains(index) ? (index, entries[index]) : nil
        }
        guard moved.count == offsets.count else { return }
        var remaining = entries.enumerated().compactMap { index, entry in
            offsets.contains(index) ? nil : (index, entry)
        }
        let removedBeforeDestination = offsets.lazy.filter {
            $0 < destination
        }.count
        let insertionIndex = min(
            max(0, destination - removedBeforeDestination),
            remaining.count
        )
        remaining.insert(contentsOf: moved, at: insertionIndex)
        let reorderedEntries = remaining.map { $0.1 }
        if let index = remaining.firstIndex(where: {
            $0.0 == currentOriginalIndex
        }) {
            replaceQueue(reorderedEntries, index: index)
        } else {
            replaceQueue(reorderedEntries, index: queueIndex)
        }
        queueDidChange()
    }

    func reshuffleUpcoming() {
        reconcilePendingTransportTransition()
        guard queue.indices.contains(queueIndex),
              queueIndex + 1 < queue.count else {
            return
        }
        let entries = playbackState.entries
        let prefix = Array(entries[...queueIndex])
        var upcoming = Array(entries[(queueIndex + 1)...])
        upcoming.shuffle()
        if shuffleStyle == .fewerRepeats {
            let recent = Set(recentShuffleIDs.suffix(8))
            upcoming.sort {
                let lhsRecent = recent.contains($0.song.id)
                let rhsRecent = recent.contains($1.song.id)
                return lhsRecent == rhsRecent ? false : !lhsRecent
            }
        }
        replaceQueue(prefix + upcoming, index: queueIndex)
        queueDidChange()
    }

    func clearUpcomingQueue() {
        reconcilePendingTransportTransition()
        guard queue.indices.contains(queueIndex),
              queueIndex + 1 < queue.count else {
            return
        }
        autoplayTask?.cancel()
        autoplayTask = nil
        autoplayGeneration &+= 1
        autoplayShouldAdvance = false
        var updatedEntries = playbackState.entries
        let removedSongs = updatedEntries[(queueIndex + 1)..<updatedEntries.count]
            .map(\.song)
        updatedEntries.removeSubrange((queueIndex + 1)..<updatedEntries.count)
        replaceQueue(updatedEntries, index: queueIndex)
        recordQueueRemovals(removedSongs)
        queueDidChange()
    }

    func excludeCurrentAndAdvance() {
        reconcilePendingTransportTransition()
        guard queue.indices.contains(queueIndex) else { return }
        finalizeCurrentPlayback(reason: .queueRemoved)
        let removedIndex = queueIndex
        var remainingEntries = playbackState.entries
        remainingEntries.remove(at: removedIndex)
        guard !remainingEntries.isEmpty else {
            queueMutationGeneration &+= 1
            pause()
            itemLoadTask?.cancel()
            cancelPlaybackRecovery()
            lyricsTask?.cancel()
            songMetadataTask?.cancel()
            songMetadataTask = nil
            songMetadataGeneration &+= 1
            itemLoadGeneration &+= 1
            lyricsLoadGeneration &+= 1
            seekGeneration &+= 1
            isSeekInFlight = false
            pendingSeekPosition = nil
            replaceQueue([], index: -1)
            elapsed = 0
            duration = 0
            isBuffering = false
            applyLyricsDocument(.empty)
            showFullLyrics = false
            removeCurrentItemObservers()
            invalidateStagedSuccessor(removeFromPlayer: true)
            player.replaceCurrentItem(with: nil)
            updateNowPlaying()
            scheduleQueueSave(immediate: true)
            return
        }
        let nextIndex = min(removedIndex, remainingEntries.count - 1)
        startPlayback(
            remainingEntries[nextIndex].song,
            in: remainingEntries,
            preferredIndex: nextIndex,
            origin: .queue,
            transitionReason: .queueRemoved
        )
    }

    func toggleShuffle() {
        reconcilePendingTransportTransition()
        isShuffleEnabled.toggle()
        invalidateStagedSuccessor(removeFromPlayer: true)
        updateRemoteCommands()
        scheduleQueueSave()
        if !isShuffleEnabled { scheduleAutoplayContinuationIfNeeded() }
        scheduleGaplessSuccessor()
    }

    private func nextShuffleIndex() -> Int {
        guard queue.count > 1,
              queue.indices.contains(queueIndex) else {
            return queueIndex
        }
        guard shuffleStyle == .fewerRepeats else {
            return randomNonCurrentQueueIndex()
        }
        let recent = Set(
            recentShuffleIDs.suffix(min(8, max(1, queue.count - 1)))
        )
        var freshSelection: Int?
        var freshCount = 0
        for index in queue.indices
            where index != queueIndex && !recent.contains(queue[index].id) {
            freshCount += 1
            if Int.random(in: 0..<freshCount) == 0 {
                freshSelection = index
            }
        }
        return freshSelection ?? randomNonCurrentQueueIndex()
    }

    private func randomNonCurrentQueueIndex() -> Int {
        guard queue.count > 1,
              queue.indices.contains(queueIndex) else {
            return queueIndex
        }
        let compressedIndex = Int.random(in: 0..<(queue.count - 1))
        return compressedIndex >= queueIndex
            ? compressedIndex + 1
            : compressedIndex
    }

    private func rememberShuffleSelection(_ songID: String) {
        recentShuffleIDs.removeAll { $0 == songID }
        recentShuffleIDs.append(songID)
        if recentShuffleIDs.count > 12 {
            recentShuffleIDs.removeFirst(recentShuffleIDs.count - 12)
        }
    }

    private func entriesRemovingUpcomingOccurrence(
        of songID: String
    ) -> [PlaybackQueueEntry] {
        var entries = playbackState.entries
        guard entries.indices.contains(queueIndex),
              queueIndex + 1 < entries.count,
              let index = entries[(queueIndex + 1)...].firstIndex(
                where: { $0.song.id == songID }
              ) else {
            return entries
        }
        entries.remove(at: index)
        return entries
    }

    private func queueDidChange() {
        queueMutationGeneration &+= 1
        invalidateStagedSuccessor(removeFromPlayer: true)
        updateRemoteCommands()
        updateNowPlaying()
        scheduleNetworkPrefetch()
        scheduleOfflinePrefetch()
        scheduleQueueSave(immediate: true)
    }

    func cycleRepeat() {
        let nextMode: RepeatMode
        switch repeatMode {
        case .off: nextMode = .all
        case .all: nextMode = .one
        case .one: nextMode = .off
        }
        setRepeatMode(nextMode)
    }

    private func setRepeatMode(_ mode: RepeatMode) {
        reconcilePendingTransportTransition()
        guard repeatMode != mode else { return }
        repeatMode = mode
        invalidateStagedSuccessor(removeFromPlayer: true)
        updateRemoteCommands()
        scheduleQueueSave()
        if repeatMode == .off { scheduleAutoplayContinuationIfNeeded() }
        scheduleGaplessSuccessor()
    }

    func updateStarred(songID: String, enabled: Bool) {
        synchronizeStarredStates([songID: enabled])
    }

    func synchronizeStarredStates(_ states: [String: Bool]) {
        reconcilePendingTransportTransition()
        guard !states.isEmpty else { return }

        let updatedEntries = playbackState.entries.map { entry in
            guard let enabled = states[entry.song.id],
                  entry.song.isStarred != enabled else {
                return entry
            }
            var updated = entry
            updated.song.starred = enabled
                ? Self.iso8601Formatter.string(from: Date())
                : nil
            return updated
        }

        let queueChanged = updatedEntries != playbackState.entries
        guard queueChanged else { return }

        replaceQueue(updatedEntries, index: queueIndex)
        updateRemoteCommands()
        updateNowPlaying()
        scheduleQueueSave()
    }

    func setQueueRestoration(enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "restore-play-queue")
        queueRestorationGeneration &+= 1
        let generation = queueRestorationGeneration
        if enabled {
            scheduleQueueSave(immediate: true)
        } else {
            let pendingSave = queueSaveTask
            queueSaveTask?.cancel()
            UserDefaults.standard.removeObject(forKey: queueStorageKey)
            lastPersistedEntriesRevision = nil
            if let currentAccountScope {
                queueSaveRevision &+= 1
                let clearRevision = queueSaveRevision
                let previousClear = queueClearTask
                queueClearTask = Task { [weak self] in
                    _ = await previousClear?.value
                    _ = await pendingSave?.value
                    guard let self,
                          generation == self.queueRestorationGeneration,
                          !self.queueRestorationEnabled else { return }
                    let persistedRevision = await AppDatabase.shared.clearQueue(
                        scope: currentAccountScope,
                        minimumRevision: clearRevision
                    )
                    if let persistedRevision,
                       generation == self.queueRestorationGeneration {
                        self.queueSaveRevision = max(
                            self.queueSaveRevision,
                            persistedRevision
                        )
                    }
                }
            }
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
           let local = await OfflineStore.shared.localURL(for: song) {
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
        networkPathMonitor.pathUpdateHandler = { @Sendable [weak self] path in
            let isSatisfied = path.status == .satisfied
            let allowsPrefetch = path.status == .satisfied
                && !path.isExpensive
                && !path.isConstrained
            Task { @MainActor [weak self] in
                guard let self else { return }
                let connectivityChanged = self.networkPathIsSatisfied != isSatisfied
                let prefetchChanged = self.allowsSpeculativeNetworkPrefetch != allowsPrefetch
                self.networkPathIsSatisfied = isSatisfied
                self.allowsSpeculativeNetworkPrefetch = allowsPrefetch
                if prefetchChanged, allowsPrefetch {
                    self.scheduleNetworkPrefetch()
                    self.scheduleOfflinePrefetch()
                } else if prefetchChanged {
                    self.suspendSpeculativePrefetch()
                }
                guard connectivityChanged else { return }
                if !isSatisfied {
                    self.cancelPlaybackRecovery()
                    if self.wantsPlayback {
                        self.isBuffering = true
                    }
                    return
                }
                guard self.wantsPlayback,
                      self.currentSong != nil else {
                    return
                }
                if self.player.currentItem == nil
                    || self.player.currentItem?.status == .failed {
                    self.loadCurrentItem(
                        compatibilityFormat: self.activeCompatibilityFormat,
                        resumeFrom: self.elapsed
                    )
                } else {
                    guard self.player.timeControlStatus != .playing else { return }
                    self.configureAudioSession()
                    self.player.playImmediately(atRate: 1)
                    self.schedulePlaybackRecovery()
                }
            }
        }
        networkPathMonitor.start(queue: networkPathQueue)
    }

    private static let preparedPlaybackAssetLimit = 3

    private static func preparedPlaybackKey(
        accountScope: String?,
        queueEntryID: UUID,
        streamRevision: String,
        quality: StreamQuality,
        compatibilityFormat: String
    ) -> String {
        [
            accountScope ?? "",
            queueEntryID.uuidString,
            streamRevision,
            quality.rawValue,
            compatibilityFormat.lowercased()
        ]
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

    private func preparePlaybackAsset(for entry: PlaybackQueueEntry) {
        let song = entry.song
        guard song.externalStreamURL == nil else { return }
        let preparedQuality = quality
        let compatibilityFormat = Self.initialCompatibilityFormat(
            for: preparedQuality,
            song: song
        )
        let key = Self.preparedPlaybackKey(
            accountScope: currentAccountScope,
            queueEntryID: entry.id,
            streamRevision: song.audioResourceRevision,
            quality: preparedQuality,
            compatibilityFormat: compatibilityFormat
        )
        if let prepared = preparedPlaybackAssets[key] {
            stagePreparedSuccessorIfPossible(prepared)
            return
        }
        guard preparedPlaybackWarmupTasks[key] == nil else {
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
                      self.playbackState.entries.contains(where: {
                          $0.id == entry.id
                              && $0.song.audioResourceRevision
                                  == song.audioResourceRevision
                      }) else {
                    self.preparedPlaybackWarmupTasks[key] = nil
                    return
                }

                let asset = Self.makeURLAsset(
                    url: resource.url,
                    mimeType: resource.mimeType
                )
                do {
                    // This opens the transport, validates the stream response,
                    // and loads enough AVFoundation metadata that a skip can
                    // reuse the same asset during the page transition.
                    _ = try await asset.load(.isPlayable)
                    guard !Task.isCancelled else { return }
                    let prepared = PreparedPlaybackAsset(
                        key: key,
                        queueEntryID: entry.id,
                        songID: song.id,
                        streamRevision: song.audioResourceRevision,
                        compatibilityFormat: compatibilityFormat,
                        asset: asset
                    )
                    self.storePreparedPlaybackAsset(prepared)
                    self.stagePreparedSuccessorIfPossible(prepared)
                } catch {}
            } catch {
                // Warming is speculative. Active playback retains its normal
                // codec fallback and recovery path if preparation fails.
            }
            self.preparedPlaybackWarmupTasks[key] = nil
        }
        preparedPlaybackWarmupTasks[key] = task
    }

    private func scheduleGaplessSuccessor() {
        guard wantsPlayback,
              player.timeControlStatus == .playing,
              stagedSuccessorItem == nil,
              let plan = GaplessSuccessorPlan.make(
                queueCount: queue.count,
                currentIndex: queueIndex,
                shuffleEnabled: isShuffleEnabled,
                repeatMode: repeatMode
              ) else {
            return
        }
        preparePlaybackAsset(for: playbackState.entries[plan.queueIndex])
    }

    private func stagePreparedSuccessorIfPossible(
        _ prepared: PreparedPlaybackAsset
    ) {
        guard stagedSuccessorItem == nil,
              !isShuffleEnabled,
              repeatMode != .one,
              wantsPlayback,
              let currentItem = player.currentItem,
              queue.indices.contains(queueIndex),
              currentSong?.id == queue[queueIndex].id else {
            return
        }
        guard let plan = GaplessSuccessorPlan.make(
            queueCount: queue.count,
            currentIndex: queueIndex,
            shuffleEnabled: isShuffleEnabled,
            repeatMode: repeatMode
        ) else { return }
        let successorIndex = plan.queueIndex
        let successor = queue[successorIndex]
        let successorEntry = playbackState.entries[successorIndex]
        guard successorEntry.id == prepared.queueEntryID,
              successor.id == prepared.songID,
              successor.audioResourceRevision == prepared.streamRevision else {
            return
        }

        let item = AVPlayerItem(asset: prepared.asset)
        item.preferredForwardBufferDuration = 0
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        guard player.canInsert(item, after: currentItem) else { return }
        player.insert(item, after: currentItem)
        stagedSuccessorItem = item
        stagedSuccessorSong = successor
        stagedSuccessorQueueIndex = successorIndex
        stagedSuccessorOccurrenceID = successorEntry.id
        let observationID = UUID()
        stagedSuccessorObservationID = observationID
        stagedSuccessorObservation = item.observe(
            \.status,
            options: [.new]
        ) { @Sendable [weak self] _, _ in
            Task { @MainActor in
                guard let self,
                      self.stagedSuccessorObservationID == observationID,
                      let item = self.stagedSuccessorItem,
                      item.status == .failed else { return }
                if self.player.currentItem === item {
                    // Commit the logical boundary first; the active-item
                    // observer will then run the normal codec fallback plan.
                    self.activateStagedSuccessor(item)
                } else {
                    self.invalidateStagedSuccessor(removeFromPlayer: true)
                }
            }
        }
        preparedPlaybackAssets[prepared.key] = nil
        preparedPlaybackAssetOrder.removeAll { $0 == prepared.key }
        preparedPlaybackWarmupTasks[prepared.key] = nil
    }

    private func invalidateStagedSuccessor(removeFromPlayer: Bool) {
        if let stagedSuccessorItem,
           player.currentItem === stagedSuccessorItem {
            // AVQueuePlayer may have advanced before its KVO callback reaches
            // MainActor. Commit that boundary synchronously so clearing staged
            // metadata can never leave transport and logical state divergent.
            activateStagedSuccessor(
                stagedSuccessorItem,
                schedulesFollowingSuccessor: false
            )
            if self.stagedSuccessorItem === stagedSuccessorItem {
                // The logical queue changed so the staged identity no longer
                // resolves. Restore the authoritative logical item instead.
                self.stagedSuccessorItem = nil
                stagedSuccessorSong = nil
                stagedSuccessorQueueIndex = nil
                stagedSuccessorOccurrenceID = nil
                stagedSuccessorObservation = nil
                stagedSuccessorObservationID = nil
                restartPlaybackPlan(resumeFrom: elapsed)
            }
            return
        }
        if removeFromPlayer,
           let stagedSuccessorItem,
           player.currentItem !== stagedSuccessorItem,
           player.items().contains(where: { $0 === stagedSuccessorItem }) {
            player.remove(stagedSuccessorItem)
        }
        stagedSuccessorItem = nil
        stagedSuccessorSong = nil
        stagedSuccessorQueueIndex = nil
        stagedSuccessorOccurrenceID = nil
        stagedSuccessorObservation = nil
        stagedSuccessorObservationID = nil
    }

    private func reconcilePendingTransportTransition() {
        guard let stagedSuccessorItem,
              player.currentItem === stagedSuccessorItem else { return }
        activateStagedSuccessor(
            stagedSuccessorItem,
            schedulesFollowingSuccessor: false
        )
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
        for playbackItem: PlaybackMediaItem,
        compatibilityFormat: String?
    ) -> PreparedPlaybackAsset? {
        guard let compatibilityFormat else { return nil }
        let song = playbackItem.song
        let key = Self.preparedPlaybackKey(
            accountScope: playbackItem.accountScope,
            queueEntryID: playbackItem.queueEntryID,
            streamRevision: song.audioResourceRevision,
            quality: quality,
            compatibilityFormat: compatibilityFormat
        )
        guard let prepared = preparedPlaybackAssets.removeValue(forKey: key),
              prepared.queueEntryID == playbackItem.queueEntryID,
              prepared.songID == song.id,
              prepared.streamRevision == song.audioResourceRevision,
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
        let nextIndex = queueIndex + 1
        if playbackState.entries.indices.contains(nextIndex) {
            preparePlaybackAsset(for: playbackState.entries[nextIndex])
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

            let screenSize = UIScreen.main.bounds.size
            let artworkEdge = max(
                220,
                min(
                    max(240, screenSize.width - 44),
                    max(264, screenSize.height * 0.47)
                )
            )
            let artworkPixelSize = ArtworkRequestSizing.pixelSize(
                pointSize: artworkEdge,
                displayScale: UIScreen.main.scale
            )
            var coverURLs: [URL] = []
            var seenArtworkRevisions = Set<String>()
            for song in plan.upcomingSongs {
                guard !Task.isCancelled else { return }
                let revision = song.artworkRevision
                guard let coverID = song.artworkID,
                      seenArtworkRevisions.insert("\(coverID)|\(revision)").inserted,
                      let sourceURL = try? await client.coverURL(
                          id: coverID,
                          size: Int(artworkPixelSize)
                      ) else {
                    continue
                }
                coverURLs.append(ArtworkStore.cacheURL(
                    for: sourceURL,
                    revision: revision
                ))
            }
            await ArtworkStore.shared.prefetch(
                urls: coverURLs,
                pixelSize: artworkPixelSize
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
                if await OfflineStore.shared.localURL(for: song) == nil {
                    _ = try? await OfflineStore.shared.download(song: song, client: client)
                }
            }
        }
    }


    private func restartPlaybackPlan(resumeFrom: TimeInterval) {
        guard let song = currentSong else { return }
        cancelPlaybackRecovery()
        recoveryStabilityTask?.cancel()
        recoveryStabilityTask = nil
        recoveryAttempt = 0
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
        guard let playbackItem = currentPlaybackItem else { return }
        let song = playbackItem.song
        let playbackItemID = playbackItem.id
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
            for: playbackItem,
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
                      self.currentPlaybackItem?.id == playbackItemID,
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
                self.handlePlaybackFailure(error: error)
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
        invalidateStagedSuccessor(removeFromPlayer: true)
        let item = AVPlayerItem(asset: asset)
        // Let AVFoundation adapt buffering to throughput and decoder cost.
        // Large fixed buffers increase system-resource demand.
        item.preferredForwardBufferDuration = 0
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
        observeActiveItem(item, resumePosition: resumePosition)
        player.replaceCurrentItem(with: item)
        handledFailedItem = nil
        updateActiveLyric(at: elapsed)
        installNextLyricBoundary(after: elapsed)
    }

    private func observeActiveItem(
        _ item: AVPlayerItem,
        resumePosition: TimeInterval
    ) {
        if startupNudgedItem !== item {
            startupNudgedItem = nil
        }
        logicalCurrentItem = item
        installItemObservers(for: item)
        installBufferObservers(for: item)
        let observerGeneration = itemObserverGeneration

        itemObservation = item.observe(
            \.status,
            options: [.initial, .new]
        ) { @Sendable [weak self] _, _ in
            Task { @MainActor in
                guard let self,
                      self.itemObserverGeneration == observerGeneration,
                      let item = self.logicalCurrentItem,
                      self.player.currentItem === item else {
                    return
                }
                switch item.status {
                case .readyToPlay:
                    self.isBuffering = false
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
                        self.schedulePlaybackRecovery()
                    }
                case .failed:
                    self.isBuffering = false
                    self.handlePlaybackFailure(failedItem: item)
                default:
                    self.isBuffering = self.wantsPlayback
                }
            }
        }
    }

    private func activateStagedSuccessor(
        _ item: AVPlayerItem,
        schedulesFollowingSuccessor: Bool = true
    ) {
        guard item === stagedSuccessorItem,
              let stagedSong = stagedSuccessorSong,
              let successorIndex = stagedSuccessorQueueIndex,
              let successorOccurrenceID = stagedSuccessorOccurrenceID,
              queue.indices.contains(successorIndex),
              queue[successorIndex].id == stagedSong.id,
              playbackState.entries[successorIndex].id
                  == successorOccurrenceID else {
            return
        }
        // Metadata (notably favorite and cover-art state) may have changed
        // while the media asset was staged. Publish the current logical entry.
        let song = queue[successorIndex]

        let previousSongID = currentSong?.id
        if duration > 0 { elapsed = duration }
        finalizeCurrentPlayback(reason: .completed)
        removeCurrentItemObservers()
        stagedSuccessorItem = nil
        stagedSuccessorSong = nil
        stagedSuccessorQueueIndex = nil
        stagedSuccessorOccurrenceID = nil
        stagedSuccessorObservation = nil
        stagedSuccessorObservationID = nil
        playbackState.setIndex(successorIndex, renewsPlayback: true)
        recordPlaybackStart(song, origin: .autoplay)
        rememberShuffleSelection(song.id)
        elapsed = 0
        duration = song.safeDuration
        pendingSeekPosition = nil
        isSeekInFlight = false
        applyLyricsDocument(.empty)
        fallbackIndex = 0
        fallbackFormats = Self.fallbackFormats(for: quality, song: song)
        activeCompatibilityFormat = Self.initialCompatibilityFormat(
            for: quality,
            song: song
        )
        recoveryAttempt = 0
        playbackError = nil
        scrobbled = false
        lastMaintenanceSecond = -1
        handledFailedItem = nil
        observeActiveItem(item, resumePosition: 0)
        refreshCanonicalMetadata(for: song)
        loadLyrics(for: song)
        scheduleQueueSave(immediate: true)
        updateNowPlaying()
        scheduleAutoplayContinuationIfNeeded()
        if previousSongID != song.id { provideTrackChangeHaptic() }
        if schedulesFollowingSuccessor { scheduleGaplessSuccessor() }
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
        logicalCurrentItem = nil
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
                ) { @Sendable [weak self] _ in
                    Task { @MainActor in
                        guard let self,
                              self.itemObserverGeneration == generation,
                              let item = self.logicalCurrentItem,
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
                ) { @Sendable [weak self] _ in
                    Task { @MainActor in
                        guard let self,
                              self.itemObserverGeneration == generation,
                              let item = self.logicalCurrentItem,
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
                ) { @Sendable [weak self] _ in
                    Task { @MainActor in
                        guard let self,
                              self.itemObserverGeneration == generation,
                              let item = self.logicalCurrentItem,
                              (self.player.currentItem === item
                                || self.player.currentItem == nil) else {
                            return
                        }
                        // AVQueuePlayer advances to the staged item without a
                        // replacement. The current-item observer commits that
                        // logical transition; this path is only the fallback
                        // when no successor was ready in time.
                        guard self.stagedSuccessorItem == nil else { return }
                        self.next(isAutoAdvance: true)
                    }
                }
            ]
        }
    }

    private func installBufferObservers(for item: AVPlayerItem) {
        itemBufferObservations.removeAll()
        let generation = itemObserverGeneration

        let empty = item.observe(
            \.isPlaybackBufferEmpty,
            options: [.new]
        ) { @Sendable [weak self] _, _ in
            Task { @MainActor in
                guard let self,
                      self.itemObserverGeneration == generation,
                      let item = self.logicalCurrentItem,
                      self.player.currentItem === item else {
                    return
                }
                if item.isPlaybackBufferEmpty, self.wantsPlayback {
                    self.schedulePlaybackRecovery()
                }
            }
        }
        let likelyToKeepUp = item.observe(
            \.isPlaybackLikelyToKeepUp,
            options: [.new]
        ) { @Sendable [weak self] _, _ in
            Task { @MainActor in
                guard let self,
                      self.itemObserverGeneration == generation,
                      let item = self.logicalCurrentItem,
                      self.player.currentItem === item else {
                    return
                }
                guard item.isPlaybackLikelyToKeepUp else { return }
                if self.wantsPlayback, self.player.timeControlStatus != .playing {
                    self.configureAudioSession()
                    self.player.playImmediately(atRate: 1)
                    self.recomputeTimelineFromPlayer()
                    self.installNextLyricBoundary(after: self.elapsed)
                    self.schedulePlaybackRecovery()
                }
            }
        }
        itemBufferObservations = [empty, likelyToKeepUp]
    }

    private func handlePlaybackFailure(
        failedItem: AVPlayerItem? = nil,
        error: Error? = nil
    ) {
        guard currentSong != nil else { return }
        if let failedItem {
            guard player.currentItem === failedItem,
                  handledFailedItem !== failedItem else {
                return
            }
            handledFailedItem = failedItem
        }
        cancelPlaybackRecovery()
        let resolvedError = error ?? failedItem?.error
        guard networkPathIsSatisfied else {
            // Keep playback intent and the current retry budget intact. The
            // path-restoration handler reloads failed items directly.
            isBuffering = wantsPlayback
            return
        }
        if PlaybackFailureClassifier.disposition(for: resolvedError) == .retryTransport {
            recoveryAttempt += 1
            if recoveryAttempt <= 2 {
                Self.logger.warning(
                    "Playback transport failed; retrying the active format"
                )
                loadCurrentItem(
                    compatibilityFormat: activeCompatibilityFormat,
                    resumeFrom: elapsed
                )
                return
            }
            if let format = takeNextCompatibilityFormat(allowsRaw: false) {
                Self.logger.warning(
                    "Playback transport remained unstable; trying lower-bandwidth format \(format, privacy: .public)"
                )
                recoveryAttempt = 0
                activeCompatibilityFormat = format
                loadCurrentItem(compatibilityFormat: format, resumeFrom: elapsed)
                return
            }
            finishPlaybackFailure(
                message: String(
                    localized: "네트워크 연결이 불안정해 재생을 계속할 수 없습니다. 연결 상태를 확인한 뒤 다시 시도해 주세요."
                )
            )
            return
        }
        guard let format = takeNextCompatibilityFormat(allowsRaw: true) else {
            Self.logger.error(
                "Playback failed after exhausting compatibility fallbacks"
            )
            finishPlaybackFailure(
                message: String(
                    localized: "이 음악을 재생하지 못했습니다. 서버의 스트리밍 형식과 네트워크 상태를 확인해 주세요."
                )
            )
            return
        }
        Self.logger.warning(
            "Playback failed; trying compatibility fallback \(format, privacy: .public)"
        )
        activeCompatibilityFormat = format
        loadCurrentItem(compatibilityFormat: format, resumeFrom: elapsed)
    }

    private func takeNextCompatibilityFormat(allowsRaw: Bool) -> String? {
        guard let index = PlaybackRecoveryPolicy.nextCompatibilityIndex(
            in: fallbackFormats,
            from: fallbackIndex,
            allowsRaw: allowsRaw
        ) else {
            return nil
        }
        fallbackIndex = index + 1
        return fallbackFormats[index]
    }

    private func finishPlaybackFailure(message: String) {
        wantsPlayback = false
        isPlaying = false
        isBuffering = false
        player.pause()
        endBackgroundBridge()
        refreshIdleTimerPreference()
        updateNowPlaying()
        scheduleQueueSave(immediate: true)
        playbackError = message
    }

    private func cancelPlaybackRecovery() {
        playerTaskLifecycle.cancelBackgroundRecovery()
        recoveryToken = nil
        recoveryTask?.cancel()
        recoveryTask = nil
    }

    private func scheduleRecoveryAttemptReset(for item: AVPlayerItem?) {
        recoveryStabilityTask?.cancel()
        guard let item else {
            recoveryStabilityTask = nil
            return
        }
        let stabilityStartPosition = currentPlayerPosition()
        recoveryStabilityTask = Task { [weak self, weak item] in
            do {
                try await Task.sleep(for: .seconds(8))
            } catch {
                return
            }
            guard let self,
                  let item,
                  self.player.currentItem === item,
                  self.player.timeControlStatus == .playing,
                  PlaybackRecoveryPolicy.hasMeaningfulProgress(
                    from: stabilityStartPosition,
                    to: self.currentPlayerPosition()
                  ) else {
                return
            }
            self.recoveryAttempt = 0
            self.recoveryStabilityTask = nil
        }
    }

    private func schedulePlaybackRecovery() {
        guard wantsPlayback, currentSong != nil, recoveryTask == nil else { return }
        if player.timeControlStatus != .playing {
            isBuffering = true
        }
        guard networkPathIsSatisfied else { return }
        let recoveryStartPosition = currentPlayerPosition()
        let token = UUID()
        recoveryToken = token
        recoveryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(1_250))
            } catch {
                return
            }
            guard let self else { return }
            defer {
                if self.recoveryToken == token {
                    self.recoveryToken = nil
                    self.recoveryTask = nil
                }
            }
            guard !Task.isCancelled, self.wantsPlayback,
                  let item = self.player.currentItem else { return }
            var progressBaseline = recoveryStartPosition
            let positionBeforeAttempt = self.currentPlayerPosition()
            if self.player.timeControlStatus == .playing,
               PlaybackRecoveryPolicy.hasMeaningfulProgress(
                    from: recoveryStartPosition,
                    to: positionBeforeAttempt
               ) {
                return
            }

            self.configureAudioSession()
            self.player.playImmediately(atRate: 1)
            self.recomputeTimelineFromPlayer()
            self.installNextLyricBoundary(after: self.elapsed)

            if item.status == .readyToPlay,
               self.currentSong?.externalStreamURL == nil,
               !self.isSeekInFlight,
               self.pendingSeekPosition == nil,
               let target = PlaybackRecoveryPolicy.startupNudgeTarget(
                    elapsed: positionBeforeAttempt,
                    duration: self.duration,
                    alreadyAttempted: self.startupNudgedItem === item
               ),
               self.canSeek(item, to: target) {
                self.startupNudgedItem = item
                progressBaseline = target
                self.seekPlayer(
                    to: target,
                    persistsQueue: false,
                    resumesPlayback: true,
                    exactly: true
                )
            }

            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard !Task.isCancelled, self.wantsPlayback,
                  self.networkPathIsSatisfied,
                  self.player.currentItem === item else { return }
            if self.player.timeControlStatus == .playing,
               PlaybackRecoveryPolicy.hasMeaningfulProgress(
                    from: progressBaseline,
                    to: self.currentPlayerPosition()
               ) {
                return
            }

            self.recoveryAttempt += 1
            if self.recoveryAttempt <= 2 {
                self.loadCurrentItem(
                    compatibilityFormat: self.activeCompatibilityFormat,
                    resumeFrom: self.elapsed
                )
            } else if let format = self.takeNextCompatibilityFormat(allowsRaw: false) {
                Self.logger.warning(
                    "Playback watchdog exhausted transport retries; trying \(format, privacy: .public)"
                )
                self.recoveryAttempt = 0
                self.activeCompatibilityFormat = format
                self.loadCurrentItem(
                    compatibilityFormat: format,
                    resumeFrom: self.elapsed
                )
            } else {
                self.finishPlaybackFailure(
                    message: String(
                        localized: "네트워크 연결이 불안정해 재생을 계속할 수 없습니다. 연결 상태를 확인한 뒤 다시 시도해 주세요."
                    )
                )
            }
        }
    }

    func retryLyrics() {
        guard let song = currentSong else { return }
        loadLyrics(for: song, forceRefresh: true)
    }

    private func loadLyrics(
        for song: Song,
        forceRefresh: Bool = false
    ) {
        lyricsTask?.cancel()
        lyricsLoadGeneration &+= 1
        let generation = lyricsLoadGeneration
        let playbackItemID = currentPlaybackItem?.id
        guard song.externalStreamURL == nil else {
            applyLyricsDocument(.empty, status: .unavailable)
            return
        }
        guard let client else {
            applyLyricsDocument(.empty, status: .failed)
            return
        }
        applyLyricsDocument(.empty, status: .loading)
        lyricsTask = Task { [weak self] in
            for attempt in 0...2 {
                do {
                    let document = try await client.lyrics(
                        songID: song.id,
                        artist: song.artist,
                        title: song.title,
                        forceRefresh: forceRefresh || attempt > 0
                    )
                    guard let self,
                          !Task.isCancelled,
                          self.lyricsLoadGeneration == generation,
                          self.currentPlaybackItem?.id == playbackItemID,
                          self.currentSong?.id == song.id else {
                        return
                    }
                    if document.lines.isEmpty, attempt < 2 {
                        try await Task.sleep(
                            for: attempt == 0
                                ? .milliseconds(650)
                                : .seconds(2)
                        )
                        continue
                    }
                    self.lyricsTask = nil
                    self.applyLyricsDocument(
                        document,
                        status: document.lines.isEmpty ? .unavailable : .available
                    )
                    return
                } catch is CancellationError {
                    return
                } catch {
                    guard let self,
                          !Task.isCancelled,
                          self.lyricsLoadGeneration == generation,
                          self.currentPlaybackItem?.id == playbackItemID,
                          self.currentSong?.id == song.id else {
                        return
                    }
                    if attempt < 2 {
                        do {
                            try await Task.sleep(
                                for: attempt == 0
                                    ? .milliseconds(650)
                                    : .seconds(2)
                            )
                        } catch {
                            return
                        }
                        continue
                    }
                    self.lyricsTask = nil
                    Self.logger.error("Lyrics request failed after retry")
                    self.applyLyricsDocument(.empty, status: .failed)
                }
            }
        }
    }

    private func installPlayerObservers() {
        guard timeControlObservation == nil else { return }
        currentItemTransitionObservation = player.observe(
            \.currentItem,
            options: [.new]
        ) { @Sendable [weak self] _, _ in
            Task { @MainActor in
                guard let self, let item = self.player.currentItem else { return }
                self.activateStagedSuccessor(item)
            }
        }
        timeControlObservation = player.observe(
            \.timeControlStatus,
            options: [.initial, .new]
        ) { @Sendable [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                let player = self.player
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
                    // A player can claim `.playing` while its media clock is
                    // frozen. Let the watchdog confirm real time progress
                    // before it clears itself.
                    self.schedulePlaybackRecovery()
                    self.scheduleRecoveryAttemptReset(for: player.currentItem)
                    self.endBackgroundBridge()
                    self.reportPlaybackState("playing")
                    self.scheduleGaplessSuccessor()
                    self.scheduleNetworkPrefetch()
                    self.scheduleOfflinePrefetch()
                } else if !self.wantsPlayback {
                    self.recoveryStabilityTask?.cancel()
                    self.recoveryStabilityTask = nil
                    self.reportPlaybackState("paused")
                    self.suspendSpeculativePrefetch()
                } else {
                    self.recoveryStabilityTask?.cancel()
                    self.recoveryStabilityTask = nil
                    // A buffering or recovery transition must give the active
                    // stream sole use of the radio and server connection.
                    self.suspendSpeculativePrefetch()
                    self.schedulePlaybackRecovery()
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
                guard let logicalCurrentItem = self.logicalCurrentItem,
                      self.player.currentItem === logicalCurrentItem else { return }
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
                        let shouldSyncServer = Date().timeIntervalSince(
                            self.lastServerQueueSaveRequest
                        ) >= 180
                        self.scheduleQueueSave(
                            immediate: true,
                            syncServer: shouldSyncServer
                        )
                    }
                }
            }
        }
    }

    private func applyLyricsDocument(
        _ document: LyricsDocument,
        status: LyricsPlaybackState.Status? = nil
    ) {
        lyrics = document
        lyricsState.status = status ?? (
            document.lines.isEmpty ? .idle : .available
        )
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

    private func currentPlayerPosition() -> TimeInterval {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? max(0, seconds) : max(0, elapsed)
    }

    private func canSeek(_ item: AVPlayerItem, to seconds: TimeInterval) -> Bool {
        guard seconds.isFinite else { return false }
        return item.seekableTimeRanges.contains { value in
            let range = value.timeRangeValue
            let start = range.start.seconds
            let end = CMTimeRangeGetEnd(range).seconds
            return start.isFinite
                && end.isFinite
                && seconds >= start
                && seconds <= end
        }
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
            ) { @Sendable [weak self] notification in
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
            ) { @Sendable [weak self] notification in
                let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                Task { @MainActor in
                    self?.handleRouteChange(reasonRawValue: reason)
                }
            })
            tokens.append(center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: audioSession,
                queue: .main
            ) { @Sendable [weak self] _ in
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
            ) { @Sendable [weak self] _ in
                Task { @MainActor in self?.handleDidEnterBackground() }
            })
            tokens.append(center.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { @Sendable [weak self] _ in
                Task { @MainActor in self?.preserveActivePlayback() }
            })
            tokens.append(center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { @Sendable [weak self] _ in
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
            playerTaskLifecycle.cancelBackgroundRecovery()
            scheduleAudioSessionDeactivation(immediate: true)
            return
        }
        beginBackgroundBridge()
        preserveActivePlayback()
        guard let playbackItem = currentPlaybackItem else {
            playerTaskLifecycle.cancelBackgroundRecovery()
            endBackgroundBridge()
            return
        }
        let sessionGeneration = playbackSessionGeneration
        let accountScope = currentAccountScope
        let playbackGenerationID = playbackItem.id
        let queueEntryID = playbackItem.queueEntryID
        playerTaskLifecycle.scheduleBackgroundRecovery(
            after: .seconds(4)
        ) { [weak self] in
            guard let self,
                  sessionGeneration == self.playbackSessionGeneration,
                  accountScope == self.currentAccountScope,
                  self.currentPlaybackItem?.id == playbackGenerationID,
                  self.currentPlaybackItem?.queueEntryID == queueEntryID,
                  self.wantsPlayback else {
                return
            }
            guard self.player.timeControlStatus != .playing else {
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
        ) { @Sendable [weak self] in
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
        commands.playCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor in
                self?.resumePlayback()
            }
            return .success
        }
        commands.pauseCommand.isEnabled = true
        commands.pauseCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        commands.togglePlayPauseCommand.isEnabled = true
        commands.togglePlayPauseCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor in self?.togglePlayback() }
            return .success
        }
        commands.stopCommand.isEnabled = false

        commands.nextTrackCommand.isEnabled = true
        commands.nextTrackCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        commands.previousTrackCommand.isEnabled = true
        commands.previousTrackCommand.addTarget { @Sendable [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }

        commands.changeShuffleModeCommand.isEnabled = true
        commands.changeShuffleModeCommand.addTarget { @Sendable [weak self] event in
            guard let event = event as? MPChangeShuffleModeCommandEvent else {
                return .commandFailed
            }
            let requested = event.shuffleType != .off
            Task { @MainActor in
                guard let self else { return }
                if self.isShuffleEnabled != requested { self.toggleShuffle() }
            }
            return .success
        }

        commands.changeRepeatModeCommand.isEnabled = true
        commands.changeRepeatModeCommand.addTarget { @Sendable [weak self] event in
            guard let event = event as? MPChangeRepeatModeCommandEvent else {
                return .commandFailed
            }
            let requested: RepeatMode
            switch event.repeatType {
            case .one: requested = .one
            case .all: requested = .all
            default: requested = .off
            }
            Task { @MainActor in
                self?.setRepeatMode(requested)
            }
            return .success
        }

        commands.changePlaybackPositionCommand.addTarget { @Sendable [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            let position = event.positionTime
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }
        commands.changePlaybackPositionCommand.isEnabled = true

        commands.likeCommand.localizedTitle = String(localized: "좋아요")
        commands.likeCommand.isEnabled = true
        commands.likeCommand.addTarget { @Sendable [weak self] _ in
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

    private func refreshCanonicalMetadata(for selectedSong: Song) {
        songMetadataTask?.cancel()
        songMetadataTask = nil
        songMetadataGeneration &+= 1
        guard selectedSong.externalStreamURL == nil,
              let selectedItemID = currentPlaybackItem?.id,
              let selectedQueueEntryID = currentPlaybackItem?.queueEntryID,
              let client else { return }

        let generation = songMetadataGeneration
        let sessionGeneration = playbackSessionGeneration
        let accountScope = currentAccountScope
        songMetadataTask = Task(priority: .utility) { [weak self] in
            let canonicalItem: PlaybackMediaItem
            do {
                canonicalItem = try await client.playbackMedia(
                    for: selectedSong,
                    queueEntryID: selectedQueueEntryID,
                    playbackGenerationID: selectedItemID
                )
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  generation == self.songMetadataGeneration,
                  sessionGeneration == self.playbackSessionGeneration,
                  accountScope == self.currentAccountScope,
                  self.currentPlaybackItem?.id == selectedItemID,
                  self.currentPlaybackItem?.queueEntryID == selectedQueueEntryID,
                  let current = self.currentSong,
                  current.id == selectedSong.id else {
                return
            }
            self.songMetadataTask = nil

            var resolved = canonicalItem.song
            // Favorite state may have changed again while getSong was in
            // flight. Preserve the latest optimistic value on the atomic item.
            resolved.starred = current.starred
            guard resolved != current else { return }

            let previousStream = self.currentPlaybackItem?.stream
            var resolvedItem = canonicalItem
            resolvedItem.song = resolved
            var updatedEntries = self.playbackState.entries
            guard updatedEntries.indices.contains(self.queueIndex),
                  updatedEntries[self.queueIndex].id == selectedQueueEntryID else {
                return
            }
            var queueSong = resolved
            queueSong.starred = current.starred
            updatedEntries[self.queueIndex] = PlaybackQueueEntry(
                song: queueSong,
                queueEntryID: selectedQueueEntryID
            )
            self.playbackState.replace(
                entries: updatedEntries,
                index: self.queueIndex,
                accountScope: self.currentAccountScope
            )
            if self.duration <= 0 || self.duration == current.safeDuration {
                self.duration = resolved.safeDuration
            }
            self.fallbackFormats = Self.fallbackFormats(
                for: self.quality,
                song: resolved
            )
            if previousStream != resolvedItem.stream,
               !self.isPlaying,
               self.currentPlayerPosition() < 1 {
                // A provisional row can omit or misreport suffix/MIME data.
                // Before meaningful playback begins, rebuild the transport
                // from the same canonical payload used by artwork/metadata.
                self.restartPlaybackPlan(resumeFrom: self.elapsed)
            }
            self.updateNowPlaying()
            self.scheduleQueueSave()

            let previousMutation = self.historyMutationTask
            let historySession = self.historySessionToken
            self.historyMutationTask = Task {
                _ = await previousMutation?.value
                guard let historySession else { return }
                await ListeningHistoryStore.shared.refreshMetadata(
                    resolved,
                    session: historySession
                )
            }
        }
    }

    private func updateNowPlaying() {
        guard let playbackItem = currentPlaybackItem else {
            nowPlayingArtworkTask?.cancel()
            nowPlayingVisualKey = nil
            nowPlayingArtworkKey = nil
            nowPlayingArtworkRequestKey = nil
            nowPlayingInfoCenter.nowPlayingInfo = nil
            updateRemoteCommands()
            return
        }
        let song = playbackItem.song
        let visualKey = [
            playbackItem.accountScope ?? "",
            playbackItem.id.uuidString,
            playbackItem.metadataRevision,
            playbackItem.artwork.revision
        ].joined(separator: "|")
        let visualChanged = nowPlayingVisualKey != visualKey
        if visualChanged {
            nowPlayingArtworkTask?.cancel()
            nowPlayingVisualKey = visualKey
            nowPlayingArtworkKey = nil
            nowPlayingArtworkRequestKey = nil
        }
        var info = visualChanged ? [:] : (nowPlayingInfoCenter.nowPlayingInfo ?? [:])
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

        guard let coverID = song.artworkID,
              let client else {
            return
        }
        let artworkKey = visualKey
        guard nowPlayingArtworkKey != artworkKey,
              nowPlayingArtworkRequestKey != artworkKey else { return }
        nowPlayingArtworkTask?.cancel()
        nowPlayingArtworkRequestKey = artworkKey
        nowPlayingArtworkTask = Task {
            defer {
                if self.nowPlayingArtworkRequestKey == artworkKey {
                    self.nowPlayingArtworkRequestKey = nil
                    self.nowPlayingArtworkTask = nil
                }
            }
            guard let sourceURL = try? await client.coverURL(id: coverID, size: 600) else {
                return
            }
            let url = ArtworkStore.cacheURL(
                for: sourceURL,
                revision: playbackItem.artwork.revision
            )
            guard let image = try? await ArtworkStore.shared.image(for: url, pixelSize: 600),
                  !Task.isCancelled,
                  self.currentPlaybackItem?.id == playbackItem.id,
                  self.currentSong?.id == song.id,
                  self.currentSong?.artworkID == coverID,
                  self.nowPlayingArtworkRequestKey == artworkKey else {
                return
            }
            let artworkProvider = NowPlayingArtworkProvider(image: image)
            var refreshed = self.nowPlayingInfoCenter.nowPlayingInfo ?? [:]
            refreshed[MPMediaItemPropertyArtwork] = artworkProvider.makeArtwork()
            self.nowPlayingInfoCenter.nowPlayingInfo = refreshed
            self.nowPlayingArtworkKey = artworkKey
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
        guard let historySession = historySessionToken else { return }
        let previousMutation = historyMutationTask
        historyMutationTask = Task {
            _ = await previousMutation?.value
            await ListeningHistoryStore.shared.recordStart(
                song,
                origin: origin,
                session: historySession
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
        guard let historySession = historySessionToken else { return }
        let previousMutation = historyMutationTask
        historyMutationTask = Task {
            _ = await previousMutation?.value
            await ListeningHistoryStore.shared.recordEnd(
                song,
                playedSeconds: playedSeconds,
                duration: resolvedDuration,
                reason: reason,
                session: historySession
            )
        }
    }

    private func recordQueueRemovals(_ songs: [Song]) {
        guard !songs.isEmpty,
              let historySession = historySessionToken else { return }
        let previousMutation = historyMutationTask
        historyMutationTask = Task {
            _ = await previousMutation?.value
            for song in songs {
                await ListeningHistoryStore.shared.recordQueueRemoval(
                    song,
                    session: historySession
                )
            }
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
        let previousReport = playbackReportTask
        playbackReportTask = Task {
            _ = await previousReport?.value
            guard !Task.isCancelled else { return }
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
        let sessionGeneration = playbackSessionGeneration
        let accountScope = currentAccountScope
        playerTaskLifecycle.scheduleScrobble { [weak self] in
            guard let self,
                  !Task.isCancelled,
                  sessionGeneration == self.playbackSessionGeneration,
                  accountScope == self.currentAccountScope,
                  self.client === client else {
                return
            }
            try? await client.scrobble(id: song.id, submission: true)
        }
    }

    private func scheduleQueueSave(
        immediate: Bool = false,
        syncServer: Bool = true
    ) {
        queueSaveTask?.cancel()
        lastQueueSaveRequest = Date()
        guard let accountScope = currentAccountScope else { return }
        queueSaveRevision &+= 1
        let saveRevision = queueSaveRevision
        let entriesRevision = playbackState.entriesRevision
        let entries = playbackState.entries
        let sessionGeneration = playbackSessionGeneration
        let snapshot = QueueSnapshot(
            entries: entries,
            currentID: currentSong?.id,
            currentQueueEntryID: currentPlaybackItem?.queueEntryID,
            index: queueIndex,
            elapsed: elapsed,
            shuffle: isShuffleEnabled,
            repeatMode: repeatMode,
            revision: saveRevision
        )
        let restorationEnabled = queueRestorationEnabled
        let restorationGeneration = queueRestorationGeneration
        let pendingClear = queueClearTask
        let replacingItems = entriesRevision != lastPersistedEntriesRevision
        queueSaveTask = Task {
            if !immediate { try? await Task.sleep(for: .milliseconds(450)) }
            _ = await pendingClear?.value
            guard !Task.isCancelled else { return }
            guard restorationGeneration == queueRestorationGeneration else { return }
            let containsOnlyServerSongs = snapshot.queue.allSatisfy {
                $0.externalStreamURL == nil
            }
            if restorationEnabled && containsOnlyServerSongs {
                let saved = await AppDatabase.shared.saveQueue(
                    snapshot,
                    scope: accountScope,
                    replacingItems: replacingItems
                )
                guard !Task.isCancelled,
                      sessionGeneration == playbackSessionGeneration,
                      accountScope == currentAccountScope else { return }
                if saved {
                    lastPersistedEntriesRevision = entriesRevision
                }
                UserDefaults.standard.removeObject(forKey: queueStorageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: queueStorageKey)
                lastPersistedEntriesRevision = nil
                let persistedRevision = await AppDatabase.shared.clearQueue(
                    scope: accountScope,
                    minimumRevision: saveRevision
                )
                guard sessionGeneration == playbackSessionGeneration,
                      accountScope == currentAccountScope else { return }
                if let persistedRevision {
                    queueSaveRevision = max(
                        queueSaveRevision,
                        persistedRevision
                    )
                }
            }
            guard let client,
                  syncServer,
                  client.accountScope == accountScope,
                  sessionGeneration == playbackSessionGeneration,
                  let current = snapshot.currentID,
                  !snapshot.queue.isEmpty,
                  containsOnlyServerSongs else {
                return
            }
            enqueueServerQueueSave(
                ServerQueueSaveRequest(
                    client: client,
                    accountScope: accountScope,
                    sessionGeneration: sessionGeneration,
                    revision: saveRevision,
                    songIDs: snapshot.queue.map(\.id),
                    currentID: current,
                    position: snapshot.elapsed
                )
            )
        }
    }

    /// Serializes mutable server queue writes and retains only the newest
    /// snapshot that arrives while a request is in flight. This prevents a
    /// slow, older response from overwriting a newer queue on the server.
    private func enqueueServerQueueSave(_ request: ServerQueueSaveRequest) {
        guard request.sessionGeneration == playbackSessionGeneration,
              request.accountScope == currentAccountScope,
              client === request.client,
              request.revision > latestServerQueueSaveRevision else {
            return
        }
        latestServerQueueSaveRevision = request.revision
        pendingServerQueueSave = request
        startServerQueueSaveDrainIfNeeded()
    }

    private func startServerQueueSaveDrainIfNeeded() {
        guard serverQueueSaveTask == nil,
              pendingServerQueueSave != nil else { return }
        serverQueueSaveTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled,
                  let request = self.pendingServerQueueSave {
                self.pendingServerQueueSave = nil
                do {
                    try await request.client.savePlayQueue(
                        songIDs: request.songIDs,
                        current: request.currentID,
                        position: request.position
                    )
                    guard !Task.isCancelled,
                          request.sessionGeneration == self.playbackSessionGeneration,
                          request.accountScope == self.currentAccountScope,
                          self.client === request.client else {
                        continue
                    }
                    self.lastServerQueueSaveRequest = Date()
                } catch {
                    if Task.isCancelled { break }
                }
            }
            self.serverQueueSaveTask = nil
            self.startServerQueueSaveDrainIfNeeded()
        }
    }

    private func restoreLocalQueue(
        accountScope: String,
        sessionGeneration: UInt64,
        expectedQueueRevision: UInt64
    ) {
        queueRestoreTask?.cancel()
        queueRestoreTask = Task { [weak self] in
            guard let self else { return }
            let snapshot = await AppDatabase.shared.loadQueue(scope: accountScope)
            // The old UserDefaults queue has no account owner and must never
            // be adopted into an authenticated scope.
            UserDefaults.standard.removeObject(forKey: self.queueStorageKey)
            guard !Task.isCancelled,
                  sessionGeneration == self.playbackSessionGeneration,
                  accountScope == self.currentAccountScope else { return }
            if let snapshot {
                self.queueSaveRevision = max(
                    self.queueSaveRevision,
                    snapshot.revision
                )
            }
            guard let snapshot,
                  expectedQueueRevision == self.queueMutationGeneration,
                  !snapshot.queue.isEmpty,
                  snapshot.queue.allSatisfy({ $0.externalStreamURL == nil }),
                  self.queue.isEmpty,
                  self.currentSong == nil else { return }
            self.applyRestoredQueue(snapshot)
            self.queueRestoreTask = nil
        }
    }

    private func applyRestoredQueue(_ snapshot: QueueSnapshot) {
        let restoredIndex: Int
        if let queueEntryID = snapshot.currentQueueEntryID,
           let occurrenceIndex = snapshot.entries.firstIndex(where: {
               $0.id == queueEntryID
           }) {
            restoredIndex = occurrenceIndex
        } else if snapshot.queue.indices.contains(snapshot.index),
           (snapshot.currentID == nil
                || snapshot.queue[snapshot.index].id == snapshot.currentID) {
            // The saved occurrence is authoritative when duplicate song IDs
            // exist. currentID alone would always collapse to the first row.
            restoredIndex = snapshot.index
        } else {
            restoredIndex = snapshot.currentID.flatMap { currentID in
                snapshot.queue.firstIndex(where: { $0.id == currentID })
            } ?? 0
        }
        playbackState.replace(
            entries: snapshot.entries,
            index: restoredIndex,
            accountScope: currentAccountScope
        )
        // v4 rows migrate with revision zero and no occurrence IDs. Force one
        // item rewrite so generated UUIDs become durable after the first load.
        lastPersistedEntriesRevision = snapshot.revision == 0
            ? nil
            : playbackState.entriesRevision
        let restoredElapsed = snapshot.elapsed.isFinite ? max(0, snapshot.elapsed) : 0
        let restoredDuration = currentSong?.safeDuration ?? 0
        elapsed = restoredDuration > 0
            ? min(restoredElapsed, restoredDuration)
            : restoredElapsed
        duration = restoredDuration
        isShuffleEnabled = snapshot.shuffle
        repeatMode = snapshot.repeatMode
        queueMutationGeneration &+= 1
        applyLyricsDocument(.empty)
        if let restoredSong = currentSong {
            loadLyrics(for: restoredSong)
        }
        refreshCanonicalMetadata(for: snapshot.queue[restoredIndex])
    }
}

struct QueueSnapshot: Sendable {
    let entries: [PlaybackQueueEntry]
    let queue: [Song]
    let currentID: String?
    let currentQueueEntryID: UUID?
    let index: Int
    let elapsed: TimeInterval
    let shuffle: Bool
    let repeatMode: RepeatMode
    let revision: UInt64

    init(
        queue: [Song],
        currentID: String?,
        index: Int,
        elapsed: TimeInterval,
        shuffle: Bool,
        repeatMode: RepeatMode,
        revision: UInt64 = 0
    ) {
        let entries = queue.map { PlaybackQueueEntry(song: $0) }
        self.init(
            entries: entries,
            currentID: currentID,
            currentQueueEntryID: entries.indices.contains(index)
                ? entries[index].id
                : nil,
            index: index,
            elapsed: elapsed,
            shuffle: shuffle,
            repeatMode: repeatMode,
            revision: revision
        )
    }

    init(
        entries: [PlaybackQueueEntry],
        currentID: String?,
        currentQueueEntryID: UUID?,
        index: Int,
        elapsed: TimeInterval,
        shuffle: Bool,
        repeatMode: RepeatMode,
        revision: UInt64
    ) {
        self.entries = entries
        queue = entries.map(\.song)
        self.currentID = currentID
        self.currentQueueEntryID = currentQueueEntryID
        self.index = index
        self.elapsed = elapsed
        self.shuffle = shuffle
        self.repeatMode = repeatMode
        self.revision = revision
    }
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
