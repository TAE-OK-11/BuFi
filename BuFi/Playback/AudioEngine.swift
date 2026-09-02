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

/// Serializes delayed/network tasks that must not escape an account
/// session. A synchronous `configure` can invalidate work immediately while
/// the drain task provides an awaitable barrier for shutdown and any work
/// scheduled by the replacement session.
@MainActor
final class PlayerTaskLifecycle {
    private(set) var scrobbleTask: Task<Void, Never>?
    private(set) var sessionTransitionTask: Task<Void, Never>?

    private var scrobbleToken: UUID?
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

    /// Cancels session-bound work and returns one task that completes only
    /// after every task owned by the old session has exited.
    @discardableResult
    func beginSessionTransition() -> Task<Void, Never>? {
        let previousTransition = sessionTransitionTask
        let pendingScrobble = scrobbleTask

        scrobbleToken = nil
        pendingScrobble?.cancel()
        scrobbleTask = nil

        guard previousTransition != nil
                || pendingScrobble != nil else {
            sessionTransitionTask = nil
            sessionTransitionToken = nil
            return nil
        }

        let token = UUID()
        sessionTransitionToken = token
        let transition = Task { [weak self] in
            _ = await previousTransition?.value
            _ = await pendingScrobble?.value
            guard let self, self.sessionTransitionToken == token else { return }
            self.sessionTransitionTask = nil
            self.sessionTransitionToken = nil
        }
        sessionTransitionTask = transition
        return transition
    }
}

enum PlaybackTelemetryRetryPolicy {
    static let maximumAttempts = 3

    static func shouldRetry(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let openSubsonicError = error as? OpenSubsonicError,
           case .http(let status) = openSubsonicError {
            return NetworkResiliencePolicy.shouldRetryHTTPStatus(status)
        }
        return NetworkResiliencePolicy.shouldRetry(error)
    }

    static func delay(afterFailedAttempt attempt: Int) -> Duration {
        switch attempt {
        case 1: .milliseconds(400)
        default: .milliseconds(900)
        }
    }
}

struct LyricsLookupIdentity: Equatable, Sendable {
    let artist: String
    let title: String

    init(song: Song) {
        artist = song.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        title = song.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canUseLegacyEndpoint: Bool {
        !artist.isEmpty && !title.isEmpty
    }

    static func shouldReload(
        from previous: Song,
        to canonical: Song,
        lyricsAreAvailable: Bool
    ) -> Bool {
        guard !lyricsAreAvailable else { return false }
        let previousIdentity = LyricsLookupIdentity(song: previous)
        let canonicalIdentity = LyricsLookupIdentity(song: canonical)
        return canonicalIdentity.canUseLegacyEndpoint
            && canonicalIdentity != previousIdentity
    }
}

/// A small latest-state transport buffer replaces the previous linked task
/// chain. Telemetry can wait behind a slow network without retaining every
/// historical transition or affecting player/UI state publication.
@MainActor
final class PlaybackReportDeliveryQueue {
    private struct Request: Sendable {
        let client: OpenSubsonicClient
        let songID: String
        let position: TimeInterval
        let state: String
    }

    private static let maximumPendingReports = 8

    private var pending: [Request] = []
    private var drainToken: UUID?
    private(set) var drainTask: Task<Void, Never>?

    func enqueue(
        client: OpenSubsonicClient,
        songID: String,
        position: TimeInterval,
        state: String
    ) {
        pending.append(Request(
            client: client,
            songID: songID,
            position: position,
            state: state
        ))
        trimPendingReports()
        startDrainIfNeeded()
    }

    private func trimPendingReports() {
        while pending.count > Self.maximumPendingReports {
            let removableIndex = pending.firstIndex {
                $0.state == "playing" || $0.state == "paused"
            } ?? pending.startIndex
            pending.remove(at: removableIndex)
        }
    }

    private func startDrainIfNeeded() {
        guard drainTask == nil else { return }
        let token = UUID()
        drainToken = token
        drainTask = Task { [weak self] in
            await self?.drain(token: token)
        }
    }

    private func drain(token: UUID) async {
        while !Task.isCancelled, !pending.isEmpty {
            let request = pending.removeFirst()
            await deliver(request)
        }
        guard drainToken == token else { return }
        drainToken = nil
        drainTask = nil
    }

    private func deliver(_ request: Request) async {
        for attempt in 1...PlaybackTelemetryRetryPolicy.maximumAttempts {
            do {
                try await request.client.reportPlayback(
                    id: request.songID,
                    position: request.position,
                    state: request.state
                )
                return
            } catch {
                guard !Task.isCancelled,
                      attempt < PlaybackTelemetryRetryPolicy.maximumAttempts,
                      PlaybackTelemetryRetryPolicy.shouldRetry(error) else {
                    return
                }
                do {
                    try await Task.sleep(
                        for: PlaybackTelemetryRetryPolicy.delay(
                            afterFailedAttempt: attempt
                        )
                    )
                } catch {
                    return
                }
            }
        }
    }
}

enum PlaybackTimelineRefreshPolicy {
    static func interval(
        isApplicationActive: Bool,
        showsFullPlayer: Bool,
        lowPowerModeEnabled: Bool,
        thermallyConstrained: Bool
    ) -> TimeInterval {
        // Background playback needs persistence/scrobble maintenance, not UI
        // animation. Two-second ticks cut wakeups by 75% versus the old 2 Hz
        // cadence while keeping 30/180-second maintenance comfortably precise.
        guard isApplicationActive else { return 2.0 }
        // The mini player needs only coarse progress. Reserve 4 Hz for the full
        // player when the system is not asking us to conserve power/thermals.
        guard showsFullPlayer,
              !lowPowerModeEnabled,
              !thermallyConstrained else {
            return 1.0
        }
        return 0.25
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
        handler: @escaping @MainActor @Sendable (CMTime) -> Void
    ) {
        removePeriodicTimeObserver()
        periodicTimeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { time in
            // AVPlayer guarantees this callback is enqueued on the main queue.
            // Bridge that dispatch guarantee directly into MainActor instead
            // of allocating a new Task for every playback progress tick.
            MainActor.assumeIsolated {
                handler(time)
            }
        }
    }

    func removePeriodicTimeObserver() {
        guard let periodicTimeObserver else { return }
        player.removeTimeObserver(periodicTimeObserver)
        self.periodicTimeObserver = nil
    }

    func replaceLyricBoundaryObserver(
        time: CMTime?,
        handler: @escaping @MainActor @Sendable () -> Void
    ) {
        removeLyricBoundaryObserver()
        guard let time else { return }
        lyricBoundaryObserver = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: time)],
            queue: .main
        ) {
            MainActor.assumeIsolated {
                handler()
            }
        }
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
        self.init(
            entries: entries,
            songs: entries.map(\.song),
            index: index,
            accountScope: accountScope,
            playbackGenerationID: playbackGenerationID
        )
    }

    fileprivate init(
        entries: [PlaybackQueueEntry],
        songs: [Song],
        index: Int,
        accountScope: String?,
        playbackGenerationID: UUID?
    ) {
        precondition(entries.count == songs.count)
        self.entries = entries
        self.songs = songs
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

    var currentSong: Song? {
        guard entries.indices.contains(index) else { return nil }
        return entries[index].song
    }

    static func == (lhs: PlaybackSnapshot, rhs: PlaybackSnapshot) -> Bool {
        // Cheap transition identity comes first. `songs` is derived from
        // `entries`, so comparing both arrays would scan the same queue twice.
        lhs.index == rhs.index
            && lhs.accountScope == rhs.accountScope
            && lhs.playbackGenerationID == rhs.playbackGenerationID
            && lhs.entries == rhs.entries
    }
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
        let previous = snapshot
        let entries = previous.entries
        let resolvedIndex = entries.isEmpty
            ? -1
            : min(max(value, 0), entries.count - 1)
        publish(PlaybackSnapshot(
            entries: entries,
            songs: previous.songs,
            index: resolvedIndex,
            accountScope: previous.accountScope,
            playbackGenerationID: renewsPlayback
                ? UUID()
                : previous.playbackGenerationID
        ), entriesChanged: false)
    }

    fileprivate func setAccountScope(_ value: String?) {
        let previous = snapshot
        publish(PlaybackSnapshot(
            entries: previous.entries,
            songs: previous.songs,
            index: previous.index,
            accountScope: value,
            playbackGenerationID: previous.playbackGenerationID
        ), entriesChanged: false)
    }

    fileprivate func replace(
        songs: [Song],
        index: Int,
        accountScope: String?
    ) {
        let entries = songs.map { PlaybackQueueEntry(song: $0) }
        let entriesChanged = snapshot.entries != entries
        publish(PlaybackSnapshot(
            entries: entries,
            songs: songs,
            index: index,
            accountScope: accountScope,
            playbackGenerationID: UUID()
        ), entriesChanged: entriesChanged)
    }

    fileprivate func replace(
        entries: [PlaybackQueueEntry],
        index: Int,
        accountScope: String?,
        renewsPlayback: Bool = false
    ) {
        let previous = snapshot
        let entriesChanged = previous.entries != entries
        let songs = entriesChanged ? entries.map(\.song) : previous.songs
        publish(PlaybackSnapshot(
            entries: entries,
            songs: songs,
            index: index,
            accountScope: accountScope,
            playbackGenerationID: renewsPlayback
                ? UUID()
                : previous.playbackGenerationID
        ), entriesChanged: entriesChanged)
    }

    private func publish(
        _ value: PlaybackSnapshot,
        entriesChanged: Bool
    ) {
        if entriesChanged {
            entriesRevision &+= 1
        } else {
            // Queue storage is shared by construction on this path. Compare
            // only transition scalars and avoid an O(n) queue equality scan.
            guard snapshot.index != value.index
                    || snapshot.accountScope != value.accountScope
                    || snapshot.playbackGenerationID != value.playbackGenerationID else {
                return
            }
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

enum PlaybackShufflePolicy {
    static let recentWindowLimit = 8
    static let fastCandidateAttemptLimit = 4

    static func shouldUseFastCandidatePath(queueCount: Int) -> Bool {
        queueCount > recentWindowLimit * 2
    }

    static func prioritizeFresh(
        _ entries: inout [PlaybackQueueEntry],
        recentSongIDs: Set<String>
    ) {
        guard !recentSongIDs.isEmpty else { return }
        // The input is already shuffled. A linear in-place partition preserves
        // random ordering while moving recent songs behind fresh candidates.
        _ = entries.partition { recentSongIDs.contains($0.song.id) }
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
        isActivelyPlaying: Bool
    ) -> PlaybackPrefetchPlan? {
        let maximumUpcoming = UpcomingPlaybackPrefetchPolicy.upcomingCount(
            queue: queue,
            queueIndex: queueIndex
        )
        return make(
            currentSong: currentSong,
            queue: queue,
            queueIndex: queueIndex,
            quality: quality,
            maximumUpcoming: maximumUpcoming,
            isActivelyPlaying: isActivelyPlaying
        )
    }

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
    case failPermanent
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
        if let status = httpStatusCode(in: value) {
            if NetworkResiliencePolicy.shouldRetryHTTPStatus(status) {
                return .retryTransport
            }
            if status == 406 || status == 415 || status == 501 {
                return .tryCompatibilityFormat
            }
            if (400...599).contains(status) {
                return .failPermanent
            }
        }
        if value.domain == NSURLErrorDomain {
            if NetworkResiliencePolicy.shouldRetry(value) {
                return .retryTransport
            }
            let code = URLError.Code(rawValue: value.code)
            if (-1206 ... -1200).contains(value.code) {
                // TLS/certificate failures cannot be healed by retrying
                // the same stream or by transcoding the media.
                return .failPermanent
            }
            switch code {
            case .internationalRoamingOff, .callIsActive, .dataNotAllowed,
                 .fileDoesNotExist:
                return .failPermanent
            default:
                break
            }
        }
        if value.domain == AVFoundationErrorDomain {
            switch value.code {
            case -11_819, -11_847, -11_850:
                return .retryTransport
            default:
                break
            }
        }
        if depth < 3,
           let underlying = value.userInfo[NSUnderlyingErrorKey] as? Error {
            return disposition(for: underlying, depth: depth + 1)
        }
        return .tryCompatibilityFormat
    }

    private static func httpStatusCode(in error: NSError) -> Int? {
        let keys = [
            "AVErrorHTTPStatusCodeKey",
            "statusCode",
            "HTTPStatusCode"
        ]
        for key in keys {
            if let status = error.userInfo[key] as? Int {
                return status
            }
        }
        return nil
    }
}

enum PlaybackTransportRetryPolicy {
    static let maximumTransportRetries = 2

    static func transportBackoff(
        afterFailedAttempt attempt: Int,
        jitter: Double = 1
    ) -> Duration {
        let base: Double = switch attempt {
        case 1: 0.45
        case 2: 1.0
        default: 1.8
        }
        let boundedJitter = min(1.25, max(0.8, jitter))
        return .milliseconds(Int((base * boundedJitter * 1_000).rounded()))
    }
}

/// Pure decisions used only after AVPlayer reports an actual item/transport
/// failure. Normal buffering and waiting never enter this path.
enum PlaybackRecoveryPolicy {
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
        repeatMode: RepeatMode
    ) -> GaplessSuccessorPlan? {
        guard queueCount > 0,
              (0..<queueCount).contains(currentIndex),
              repeatMode != .one else { return nil }
        if currentIndex + 1 < queueCount {
            return GaplessSuccessorPlan(queueIndex: currentIndex + 1)
        }
        return repeatMode == .all
            ? GaplessSuccessorPlan(queueIndex: 0)
            : nil
    }
}

/// Playback policy is based on the bytes AVPlayer receives, not the encoder
/// brand that produced them. Apple AAC and FDK-AAC are both AAC at decode time;
/// container/bitrate metadata is the useful signal for buffering decisions.
enum PlaybackAudioProfile: Equatable, Sendable {
    case aac
    case compressed
    case lossless
    case unknown

    private static let losslessSuffixes: Set<String> = [
        "flac", "alac", "wav", "wave", "aif", "aiff"
    ]
    private static let compressedSuffixes: Set<String> = [
        "mp3", "opus", "ogg", "oga", "vorbis", "webm"
    ]

    static func estimatedBitRateKbps(for song: Song) -> Double? {
        if let bitRate = song.bitRate, bitRate > 0 {
            return Double(bitRate)
        }
        guard let size = song.size,
              size > 0,
              song.safeDuration > 0 else {
            return nil
        }
        return Double(size) * 8 / song.safeDuration / 1_000
    }

    static func resolve(
        song: Song,
        compatibilityFormat: String?
    ) -> PlaybackAudioProfile {
        let requested = compatibilityFormat?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch requested {
        case "aac": return .aac
        case "mp3", "opus": return .compressed
        default: break
        }

        let suffix = song.suffix?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let fullContentType = song.contentType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let baseContentType = fullContentType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        // Preserve codec parameters such as `audio/mp4; codecs=alac` or
        // `codecs=mp4a.40.2`; stripping everything after `;` would collapse
        // Apple AAC/FDK-AAC and ALAC into the same generic M4A container.
        if suffix == "aac"
            || fullContentType.contains("aac")
            || fullContentType.contains("mp4a") {
            return .aac
        }
        if losslessSuffixes.contains(suffix)
            || fullContentType.contains("alac")
            || fullContentType.contains("flac")
            || fullContentType.contains("lossless") {
            return .lossless
        }
        if compressedSuffixes.contains(suffix)
            || baseContentType.contains("mpeg")
            || fullContentType.contains("opus")
            || fullContentType.contains("vorbis") {
            return .compressed
        }

        if ["m4a", "m4b", "mp4"].contains(suffix) {
            // M4A is a container: Apple AAC, FDK-AAC, and ALAC can all arrive
            // with audio/mp4. Prefer the server bitrate, then derive one from
            // byte size + duration when older servers omit bitRate.
            if let effectiveBitRate = estimatedBitRateKbps(for: song) {
                if effectiveBitRate <= 384 { return .aac }
                if effectiveBitRate >= 512 { return .lossless }
            }
            if (song.bitDepth ?? 0) > 16
                || (song.samplingRate ?? 0) > 48_000 {
                return .lossless
            }
            // A generic audio/mp4 response cannot distinguish AAC from ALAC.
            // When older servers omit every useful signal, classify the raw
            // container conservatively so an unlabelled ALAC stream still gets
            // the no-competing-prefetch stability policy.
            if requested == nil || requested == "raw" {
                return .lossless
            }
        }
        return .unknown
    }
}

/// Leave forward buffering to AVPlayer. A duration of zero is AVFoundation's
/// system-managed policy, which can adapt to route, throughput, and codec cost
/// instead of relying on one fixed window for every server and ALAC file.
enum PlaybackBufferPolicy {
    static func configure(_ item: AVPlayerItem) {
        item.preferredForwardBufferDuration = 0
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
    }
}

/// Manual next/queue taps must not tear down a successor that AVQueuePlayer
/// has already staged. Doing so discards the warmed asset and opens a second
/// stream for the same song.
enum PlaybackSkipPlan {
    static func shouldCommitStagedSuccessor(
        stagedQueueIndex: Int?,
        stagedOccurrenceID: UUID?,
        nextQueueIndex: Int,
        nextOccurrenceID: UUID?
    ) -> Bool {
        guard let stagedQueueIndex,
              let stagedOccurrenceID,
              let nextOccurrenceID else {
            return false
        }
        return stagedQueueIndex == nextQueueIndex
            && stagedOccurrenceID == nextOccurrenceID
    }
}

enum PlaybackGaplessPreparationPolicy {
    static let stablePlaybackWindow: TimeInterval = 2

    static func shouldPrepare(
        elapsed: TimeInterval,
        duration: TimeInterval,
        isBuffering: Bool,
        isActivelyPlaying: Bool,
        profile: PlaybackAudioProfile
    ) -> Bool {
        guard isActivelyPlaying,
              !isBuffering,
              elapsed.isFinite,
              elapsed >= stablePlaybackWindow,
              duration.isFinite,
              duration > 0 else {
            return false
        }
        let position = min(max(0, elapsed), duration)
        let remaining = max(0, duration - position)
        let leadTime: TimeInterval = switch profile {
        case .lossless: min(10, max(5, duration * 0.04))
        case .aac: min(16, max(7, duration * 0.06))
        case .compressed: min(14, max(6, duration * 0.05))
        case .unknown: min(12, max(6, duration * 0.05))
        }
        return remaining <= leadTime
    }

    static func shouldStage(
        elapsed: TimeInterval,
        duration: TimeInterval,
        isBuffering: Bool,
        isActivelyPlaying: Bool,
        profile: PlaybackAudioProfile
    ) -> Bool {
        guard isActivelyPlaying,
              !isBuffering,
              elapsed.isFinite,
              elapsed >= stablePlaybackWindow,
              duration.isFinite,
              duration > 0 else {
            return false
        }
        let position = min(max(0, elapsed), duration)
        let remaining = max(0, duration - position)
        let leadTime: TimeInterval = switch profile {
        case .lossless: min(5, max(2.5, duration * 0.02))
        case .aac: min(7, max(3, duration * 0.025))
        case .compressed, .unknown: min(6, max(3, duration * 0.025))
        }
        return remaining <= leadTime
    }
}

struct PlaybackResourceRequest: Sendable {
    let song: Song
    let quality: StreamQuality
    let compatibilityFormat: String?
    let allowLocalSource: Bool
    let offsetSeconds: Int
}

struct PlaybackResourceDescriptor: Sendable {
    let url: URL
    let mimeType: String?
}

enum PlaybackResourceResolver {
    @concurrent
    static func resolve(
        _ request: PlaybackResourceRequest,
        client: OpenSubsonicClient?
    ) async throws -> PlaybackResourceDescriptor {
        try Task.checkCancellation()
        let song = request.song
        if let value = song.externalStreamURL,
           let url = URL(string: value),
           url.scheme?.lowercased() == "https" {
            return PlaybackResourceDescriptor(
                url: url,
                mimeType: song.contentType
            )
        }
        if request.allowLocalSource,
           request.compatibilityFormat?.lowercased() == "raw",
           let local = await OfflineStore.shared.localURL(for: song) {
            try Task.checkCancellation()
            return PlaybackResourceDescriptor(
                url: local,
                mimeType: sourceMIMEType(for: song)
            )
        }
        guard let client else { throw OpenSubsonicError.invalidServerURL }
        let url = try await client.playbackStreamURL(
            songID: song.id,
            quality: request.quality,
            compatibilityFormat: request.compatibilityFormat,
            offsetSeconds: request.offsetSeconds
        )
        try Task.checkCancellation()
        return PlaybackResourceDescriptor(
            url: url,
            mimeType: mimeType(
                for: request.compatibilityFormat,
                sourceSong: song
            )
        )
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
}

struct NowPlayingVisualIdentity: Hashable, Sendable {
    let accountScope: String?
    let playbackID: UUID
    let metadataRevision: String
    let artworkRevision: String
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
        let currentIndex: Int
        let position: TimeInterval
        let attempt: Int
    }

    private static let serverQueueLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BuFi",
        category: "ServerQueue"
    )

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
        pruneShuffleSession()
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

    private struct PreparedPlaybackAsset {
        let key: PreparedPlaybackKey
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
        (@MainActor (
            Song,
            Set<String>,
            @escaping @MainActor (Song) -> Void
        ) async -> [Song])?
    private var songChangeHandler: (@MainActor (Song) -> Void)?
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
    private var playbackContextStartTask: Task<Void, Never>?
    private var pendingPlaybackContextSong: Song?
    private var serverQueueTask: Task<Void, Never>?
    private var serverQueueSaveTask: Task<Void, Never>?
    private var pendingServerQueueSave: ServerQueueSaveRequest?
    private var latestServerQueueSaveRevision: UInt64 = 0
    private var nowPlayingArtworkTask: Task<Void, Never>?
    private var offlinePrefetchTask: Task<Void, Never>?
    private var visualPrefetchTask: Task<Void, Never>?
    private var speculativePrefetchStartTask: Task<Void, Never>?
    private var speculativePrefetchStartToken: UUID?
    private var visualPrefetchToken: UUID?
    private var offlinePrefetchToken: UUID?
    private var lastVisualPrefetchKey: PlaybackPrefetchPlan.Key?
    private var lastOfflinePrefetchKey: PlaybackPrefetchPlan.Key?
    private var playbackPrefetchInFlightSongIDs: Set<String> = []
    private var playbackPrefetchCompletedSongIDs: Set<String> = []
    private var upcomingMetadataPrefetchTask: Task<[Song], Never>?
    private var upcomingMetadataPrefetchKey: PlaybackPrefetchPlan.Key?
    private var preparedPlaybackAssets: [PreparedPlaybackKey: PreparedPlaybackAsset] = [:]
    private var preparedPlaybackAssetOrder: [PreparedPlaybackKey] = []
    private var preparedPlaybackWarmupTasks: [PreparedPlaybackKey: Task<Void, Never>] = [:]
    private var preparedPlaybackWarmupTokens: [PreparedPlaybackKey: UUID] = [:]
    private weak var stagedSuccessorItem: AVPlayerItem?
    private var stagedSuccessorSong: Song?
    private var stagedSuccessorQueueIndex: Int?
    private var stagedSuccessorOccurrenceID: UUID?
    private var autoplayTask: Task<Void, Never>?
    private var historyMutationTask: Task<Void, Never>?
    private let playbackReportDelivery = PlaybackReportDeliveryQueue()
    private var nowPlayingVisualKey: NowPlayingVisualIdentity?
    private var nowPlayingArtworkKey: NowPlayingVisualIdentity?
    private var nowPlayingArtworkRequestKey: NowPlayingVisualIdentity?
    private var resumeAfterInterruption = false
    private var activeCompatibilityFormat: String?
    private var recoveryStabilityTask: Task<Void, Never>?
    private var prolongedStallRecoveryTask: Task<Void, Never>?
    private var audioSessionActivationTask: Task<Void, Never>?
    private var audioSessionActivationToken: UUID?
    private var audioSessionDeactivationTask: Task<Void, Never>?
    private var audioSessionCommandEpoch: UInt64 = 0
    private var nowPlayingActivationTask: Task<Void, Never>?
    private let audioSessionController = AudioSessionController()
    private weak var handledFailedItem: AVPlayerItem?
    private var recoveryAttempt = 0
    private var itemLoadGeneration: UInt64 = 0
    private var lyricsLoadGeneration: UInt64 = 0
    private var songMetadataGeneration: UInt64 = 0
    private var seekGeneration: UInt64 = 0
    private var itemObserverGeneration: UInt64 = 0
    private var timelineObserverGeneration: UInt64 = 0
    private var timelineRefreshInterval: TimeInterval?
    private var lyricBoundaryGeneration: UInt64 = 0
    private var autoplayGeneration: UInt64 = 0
    private var isSeekInFlight = false
    private var autoplayShouldAdvance = false
    private var recentShuffleIDs: [String] = []
    private var shuffleSessionPlayedEntryIDs: Set<UUID> = []
    private var pendingSeekPosition: TimeInterval?
    /// Absolute playback position when the active stream URL already encodes a
    /// server-side offset. AVPlayer time stays relative to the partial stream.
    private var streamBaseOffset: TimeInterval = 0
    private static let streamURLOffsetThreshold: TimeInterval = 5
    private var lastQueueSaveRequest = Date.distantPast
    private var lastServerQueueSaveRequest = Date.distantPast
    private var lastMaintenanceSecond = -1
    private var behaviorStartRecordedForSongID: String?
    private var lastPlaybackReportSongID: String?
    private var lastPlaybackReportState: String?
    private var playbackStartupRequestedAt: TimeInterval?
    private var playbackItemInstalledAt: TimeInterval?
    private let queueStorageKey = "native-play-queue"
    private var queueRestoreTask: Task<Void, Never>?
    private var queueRestoreToken: UUID?
    private var queueSaveRevision: UInt64 = 0
    private var lastPersistedEntriesRevision: UInt64?
    private var allowsSpeculativeNetworkPrefetch = false
    private var networkPathIsSatisfied = true
    private var networkPathIsExpensive = false
    private var networkPathIsConstrained = false
    private var networkLinkQualityIsMinimal = false
    private var playbackStallCount = 0
    private var runtimeIsActive = false
    private var applicationIsActive = true
    private let trackChangeHapticGenerator = UIImpactFeedbackGenerator(style: .soft)

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
        applicationIsActive = UIApplication.shared.applicationState == .active
        LaunchDiagnostics.mark("audio-runtime-starting")
        LaunchDiagnostics.mark("audio-player-creating")
        player.automaticallyWaitsToMinimizeStalling = true
        player.actionAtItemEnd = .advance
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        prepareAudioSessionConfiguration()
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
            (@MainActor (
                Song,
                Set<String>,
                @escaping @MainActor (Song) -> Void
            ) async -> [Song])? = nil,
        songChangeHandler: (@MainActor (Song) -> Void)? = nil
    ) {
        playbackSessionGeneration &+= 1
        let sessionGeneration = playbackSessionGeneration
        playerTaskLifecycle.beginSessionTransition()
        let previousAccountScope = currentAccountScope
        serverQueueTask?.cancel()
        serverQueueTask = nil
        playbackContextStartTask?.cancel()
        playbackContextStartTask = nil
        pendingPlaybackContextSong = nil
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
        self.songChangeHandler = songChangeHandler
        if client == nil {
            finalizeCurrentPlayback(reason: .stopped)
            historySessionToken = nil
            let pendingQueueSave = queueSaveTask
            queueSaveTask?.cancel()
            queueSaveTask = nil
            suspendSpeculativePrefetch()
            itemLoadTask?.cancel()
            itemLoadTask = nil
            prolongedStallRecoveryTask?.cancel()
            prolongedStallRecoveryTask = nil
            playbackStallCount = 0
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
            queueRestoreToken = nil
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
            let restoredIndex = serverQueue.currentIndex
                ?? serverQueue.songs.firstIndex { $0.id == serverQueue.currentID }
                ?? 0
            self.replacePlayback(serverQueue.songs, index: restoredIndex)
            self.queueMutationGeneration &+= 1
            self.behaviorStartRecordedForSongID = nil
            self.duration = self.currentSong?.safeDuration ?? 0
            let restoredPosition = max(0, serverQueue.position)
            self.elapsed = self.duration > 0 ? min(restoredPosition, self.duration) : restoredPosition
            self.applyLyricsDocument(.empty)
            self.updateNowPlaying()
            if let restoredSong = self.currentSong {
                self.loadLyrics(for: restoredSong)
                self.refreshCanonicalMetadata(for: restoredSong)
            }
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
        let finalPlaybackReport = playbackReportDelivery.drainTask
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
        transitionReason: PlaybackEndReason = .replaced,
        reusesCurrentQueue: Bool = false
    ) {
        playbackStartupRequestedAt = ProcessInfo.processInfo.systemUptime
        playbackItemInstalledAt = nil
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
        if !reusesCurrentQueue {
            resetPlaybackPrefetchTracking()
        }
        let previousSongID = currentSong?.id
        finalizeCurrentPlayback(reason: transitionReason)
        var normalizedEntries = sourceEntries.isEmpty
            ? [PlaybackQueueEntry(song: song)]
            : sourceEntries
        let resolvedIndex: Int
        if reusesCurrentQueue,
           let preferredIndex,
           normalizedEntries.indices.contains(preferredIndex) {
            // Internal next/previous/queue-selection calls already carry the
            // authoritative queue occurrence. Trust that stable index instead
            // of scanning the queue for the same song again.
            resolvedIndex = preferredIndex
        } else if let preferredIndex, normalizedEntries.indices.contains(preferredIndex) {
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
        if !reusesCurrentQueue,
           normalizedEntries[resolvedIndex].song.id == song.id {
            // The tapped row is the freshest metadata source. Replacing the
            // matching queue entry atomically prevents an older coverArt value
            // from becoming the visual now-playing source for this transition.
            normalizedEntries[resolvedIndex].song = song
        }
        let selectedSong = normalizedEntries[resolvedIndex].song
        // Current media, queue entries, selection, and account scope publish as
        // one snapshot. Existing-queue transitions can renew playback identity
        // without copy-on-write or queue equality scans.
        if reusesCurrentQueue {
            playbackState.setIndex(resolvedIndex, renewsPlayback: true)
        } else {
            replacePlayback(normalizedEntries, index: resolvedIndex)
        }
        queueMutationGeneration &+= 1
        player.pause()
        isPlaying = false
        playbackContextStartTask?.cancel()
        playbackContextStartTask = nil
        pendingPlaybackContextSong = selectedSong
        lyricsTask?.cancel()
        lyricsTask = nil
        lyricsLoadGeneration &+= 1
        songMetadataTask?.cancel()
        songMetadataTask = nil
        songMetadataGeneration &+= 1
        seekGeneration &+= 1
        removeCurrentItemObservers()
        invalidateStagedSuccessor(removeFromPlayer: true)
        player.replaceCurrentItem(with: nil)
        resetTrackPresentation(
            for: selectedSong,
            origin: origin,
            previousSongID: previousSongID
        )
        recoveryStabilityTask?.cancel()
        recoveryStabilityTask = nil
        wantsPlayback = autoplay
        if autoplay {
            // Negotiate the audio route in parallel with URL and AVAsset
            // preparation instead of serially after the item becomes ready.
            configureAudioSession()
        }
        if !showPlayer {
            let automaticallyOpensPlayer =
                UserDefaults.standard.object(forKey: "auto-open-player") as? Bool ?? false
            showPlayer = automaticallyOpensPlayer
        }
        loadCurrentItem(
            compatibilityFormat: activeCompatibilityFormat,
            resumeFrom: 0
        )
        // Starting the selected stream owns the critical network path. Any
        // previous speculative transfers are discarded now; the new queue is
        // warmed only after AVPlayer confirms that playback is established.
        suspendSpeculativePrefetch()
        scheduleUpcomingVisualPrefetch()
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

    private func requestPlayback() {
        // `play()` cooperates with automaticallyWaitsToMinimizeStalling. Using
        // playImmediately here repeatedly forced a high-bitrate stream to run
        // before AVPlayer considered its buffer safe.
        player.play()
    }

    private func requestLowLatencyStartup() {
        // This is issued only once for a newly installed remote item. It lets
        // AVPlayer begin with the first decodable media already available,
        // without disabling automatic stall recovery for the rest of the song.
        // readyToPlay repeats a regular play request for AirPlay and for an
        // initially empty transport buffer.
        player.playImmediately(atRate: 1)
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
            requestPlayback()
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
            scheduleSpeculativePrefetchAfterPlaybackStability()
            scheduleUpcomingVisualPrefetch()
            return
        }
        suspendSpeculativePrefetch()
    }

    private func pausePlayback(persistsQueue: Bool) {
        wantsPlayback = false
        playbackStartupRequestedAt = nil
        playbackItemInstalledAt = nil
        player.pause()
        suspendSpeculativePrefetch()
        isPlaying = false
        isBuffering = false
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
        resumesPlayback: Bool = false
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
        let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
        seekGeneration &+= 1
        let generation = seekGeneration
        isSeekInFlight = true
        let playerTarget = streamBaseOffset > 0
            ? max(0, target - streamBaseOffset)
            : target
        player.seek(
            to: CMTime(seconds: playerTarget, preferredTimescale: 600),
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
                if resumesPlayback, self.wantsPlayback {
                    if finished {
                        self.isBuffering = false
                        self.configureAudioSession()
                        self.requestPlayback()
                    } else {
                        self.isBuffering = true
                    }
                }
                if persistsQueue, finished {
                    self.scheduleQueueSave(syncServer: false)
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
                transitionReason: .completed,
                reusesCurrentQueue: true
            )
            return
        }

        let nextIndex: Int
        if isShuffleEnabled, queue.count > 1 {
            if repeatMode == .off,
               !hasRemainingShuffleEntries() {
                requestAutoplayContinuation(advanceWhenReady: true)
                return
            }
            nextIndex = nextShuffleIndex()
        } else if queueIndex < queue.count - 1 {
            nextIndex = queueIndex + 1
        } else if repeatMode == .all || (isAutoAdvance && repeatMode == .one) {
            nextIndex = 0
        } else {
            requestAutoplayContinuation(advanceWhenReady: true)
            return
        }
        if !isAutoAdvance,
           commitStagedSuccessorIfItMatches(
            queueIndex: nextIndex,
            origin: .manual,
            transitionReason: .skipped
           ) {
            return
        }
        startPlayback(
            queue[nextIndex],
            in: playbackState.entries,
            preferredIndex: nextIndex,
            origin: isAutoAdvance ? .autoplay : .manual,
            transitionReason: isAutoAdvance ? .completed : .skipped,
            reusesCurrentQueue: true
        )
    }

    private func scheduleAutoplayContinuationIfNeeded() {
        let remaining = max(0, queue.count - queueIndex - 1)
        guard remaining < 3 else { return }
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
            var streamed = false
            let candidates = await provider(seed, excludedIDs) { song in
                guard let self,
                      generation == self.autoplayGeneration,
                      self.algorithmicAutoplayEnabled else {
                    return
                }
                if self.appendAutoplaySong(song) {
                    streamed = true
                    if self.autoplayShouldAdvance {
                        self.autoplayShouldAdvance = false
                        self.isBuffering = false
                        self.next(isAutoAdvance: true)
                    }
                }
            }
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

            if !additions.isEmpty {
                let appendedEntries = self.playbackState.entries
                    + additions.map { PlaybackQueueEntry(song: $0) }
                self.replaceQueue(appendedEntries, index: self.queueIndex)
                self.updateRemoteCommands()
                self.updateNowPlaying()
                self.scheduleSpeculativePrefetchAfterPlaybackStability()
                self.scheduleUpcomingVisualPrefetch()
                self.scheduleQueueSave(immediate: true)
            }
            if shouldAdvance {
                if streamed || !additions.isEmpty {
                    self.isBuffering = false
                    self.next(isAutoAdvance: true)
                } else {
                    self.pause()
                }
            }
        }
    }

    @discardableResult
    private func appendAutoplaySong(_ song: Song) -> Bool {
        guard song.externalStreamURL == nil,
              !queue.contains(where: { $0.id == song.id }) else {
            return false
        }
        let appendedEntries = playbackState.entries
            + [PlaybackQueueEntry(song: song)]
        replaceQueue(appendedEntries, index: queueIndex)
        updateRemoteCommands()
        updateNowPlaying()
        scheduleSpeculativePrefetchAfterPlaybackStability()
        scheduleUpcomingVisualPrefetch()
        scheduleQueueSave(immediate: true)
        return true
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
            transitionReason: .skipped,
            reusesCurrentQueue: true
        )
    }

    func playQueueItem(at index: Int) {
        reconcilePendingTransportTransition()
        guard queue.indices.contains(index) else { return }
        if commitStagedSuccessorIfItMatches(
            queueIndex: index,
            origin: .queue,
            transitionReason: .replaced
        ) {
            return
        }
        startPlayback(
            queue[index],
            in: playbackState.entries,
            preferredIndex: index,
            origin: .queue,
            transitionReason: .replaced,
            reusesCurrentQueue: true
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
        var reordered = Array(entries[...queueIndex])
        reordered.reserveCapacity(entries.count)
        var upcoming = Array(entries[(queueIndex + 1)...])
        upcoming.shuffle()
        if shuffleStyle == .fewerRepeats {
            let recent = Set(
                recentShuffleIDs.suffix(PlaybackShufflePolicy.recentWindowLimit)
            )
            PlaybackShufflePolicy.prioritizeFresh(
                &upcoming,
                recentSongIDs: recent
            )
        }
        reordered.append(contentsOf: upcoming)
        replaceQueue(reordered, index: queueIndex)
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
        updatedEntries.removeSubrange((queueIndex + 1)..<updatedEntries.count)
        replaceQueue(updatedEntries, index: queueIndex)
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
        if isShuffleEnabled {
            shuffleSessionPlayedEntryIDs.removeAll(keepingCapacity: true)
            if let currentID = playbackState.currentItem?.queueEntryID {
                shuffleSessionPlayedEntryIDs.insert(currentID)
            }
        }
        invalidateStagedSuccessor(removeFromPlayer: true)
        updateRemoteCommands()
        scheduleQueueSave()
        if !isShuffleEnabled { scheduleAutoplayContinuationIfNeeded() }
        scheduleGaplessSuccessor()
    }

    private func hasRemainingShuffleEntries() -> Bool {
        playbackState.entries.contains { entry in
            !shuffleSessionPlayedEntryIDs.contains(entry.id)
        }
    }

    private func nextShuffleIndex() -> Int {
        let songs = playbackState.songs
        let entries = playbackState.entries
        let currentIndex = queueIndex
        guard songs.count > 1,
              songs.indices.contains(currentIndex) else {
            return currentIndex
        }
        let remaining = entries.indices.filter { index in
            index != currentIndex
                && (repeatMode != .off
                    || !shuffleSessionPlayedEntryIDs.contains(entries[index].id))
        }
        guard !remaining.isEmpty else {
            return Self.randomNonCurrentQueueIndex(
                queueCount: songs.count,
                currentIndex: currentIndex
            )
        }
        guard shuffleStyle == .fewerRepeats else {
            return remaining.randomElement() ?? currentIndex
        }
        let recent = Set(
            recentShuffleIDs.suffix(
                min(
                    PlaybackShufflePolicy.recentWindowLimit,
                    max(1, songs.count - 1)
                )
            )
        )

        if PlaybackShufflePolicy.shouldUseFastCandidatePath(
            queueCount: songs.count
        ) {
            // Rejection sampling is uniform over fresh candidates and makes
            // the common large-queue path O(1) on average. If recent songs
            // dominate unexpectedly, the reservoir scan below is the bounded
            // correctness fallback.
            for _ in 0..<PlaybackShufflePolicy.fastCandidateAttemptLimit {
                guard let candidate = remaining.randomElement() else { break }
                if !recent.contains(songs[candidate].id) {
                    return candidate
                }
            }
        }

        var freshSelection: Int?
        var freshCount = 0
        for index in remaining
            where !recent.contains(songs[index].id) {
            freshCount += 1
            if Int.random(in: 0..<freshCount) == 0 {
                freshSelection = index
            }
        }
        return freshSelection ?? remaining.randomElement() ?? currentIndex
    }

    private static func randomNonCurrentQueueIndex(
        queueCount: Int,
        currentIndex: Int
    ) -> Int {
        guard queueCount > 1,
              (0..<queueCount).contains(currentIndex) else {
            return currentIndex
        }
        let compressedIndex = Int.random(in: 0..<(queueCount - 1))
        return compressedIndex >= currentIndex
            ? compressedIndex + 1
            : compressedIndex
    }

    private func rememberShuffleSelection(_ songID: String) {
        recentShuffleIDs.removeAll { $0 == songID }
        recentShuffleIDs.append(songID)
        if recentShuffleIDs.count > 12 {
            recentShuffleIDs.removeFirst(recentShuffleIDs.count - 12)
        }
        if let entryID = playbackState.currentItem?.queueEntryID {
            shuffleSessionPlayedEntryIDs.insert(entryID)
        }
    }

    private func pruneShuffleSession() {
        let liveIDs = Set(playbackState.entries.map(\.id))
        shuffleSessionPlayedEntryIDs = shuffleSessionPlayedEntryIDs.intersection(liveIDs)
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
        scheduleSpeculativePrefetchAfterPlaybackStability()
        scheduleUpcomingVisualPrefetch()
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
        let shouldDisableIdleTimer =
            keepAwake
            && isPlaying
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
        guard UIApplication.shared.isIdleTimerDisabled
                != shouldDisableIdleTimer else { return }
        UIApplication.shared.isIdleTimerDisabled = shouldDisableIdleTimer
    }

    func toggleCurrentStar() async {
        guard let song = currentSong, let songFavoriteMutationHandler else { return }
        _ = await songFavoriteMutationHandler(song)
    }


    private func playbackResource(
        for song: Song,
        compatibilityFormat: String?,
        allowLocalSource: Bool = true,
        offsetSeconds: Int = 0
    ) async throws -> PlaybackResourceDescriptor {
        let request = PlaybackResourceRequest(
            song: song,
            quality: quality,
            compatibilityFormat: compatibilityFormat,
            allowLocalSource: allowLocalSource,
            offsetSeconds: offsetSeconds
        )
        return try await PlaybackResourceResolver.resolve(
            request,
            client: client
        )
    }

    private func streamOffsetSeconds(
        for song: Song,
        resumePosition: TimeInterval,
        compatibilityFormat: String?,
        allowLocalSource: Bool
    ) -> Int {
        guard resumePosition >= Self.streamURLOffsetThreshold,
              song.externalStreamURL == nil else {
            return 0
        }
        if allowLocalSource,
           compatibilityFormat?.lowercased() == "raw" {
            // Local offline files seek efficiently after install.
            return 0
        }
        return max(0, Int(resumePosition.rounded(.down)))
    }

    private func currentPlaybackAudioProfile() -> PlaybackAudioProfile {
        guard let song = currentSong else { return .unknown }
        return PlaybackAudioProfile.resolve(
            song: song,
            compatibilityFormat: activeCompatibilityFormat
        )
    }

    private var isRemoteLosslessPlayback: Bool {
        guard currentPlaybackAudioProfile() == .lossless else { return false }
        let item = player.currentItem ?? logicalCurrentItem
        guard let url = (item?.asset as? AVURLAsset)?.url else {
            // Treat an unresolved lossless source as remote until the item is
            // installed so speculative work cannot race initial ALAC startup.
            return true
        }
        return !url.isFileURL
    }

    private static func initialCompatibilityFormat(
        for quality: StreamQuality,
        song: Song
    ) -> String {
        switch quality {
        case .automatic:
            automaticCompatibilityFormat(for: song)
        case .aac320:
            canPassThroughAAC(song, maximumBitRate: 320) ? "raw" : "aac"
        case .opus160: "opus"
        case .original: "raw"
        }
    }

    private static func canPassThroughAAC(
        _ song: Song,
        maximumBitRate: Double
    ) -> Bool {
        guard PlaybackAudioProfile.resolve(
            song: song,
            compatibilityFormat: "raw"
        ) == .aac,
        let bitRate = PlaybackAudioProfile.estimatedBitRateKbps(for: song) else {
            return false
        }
        // Size-derived rates include MP4 container overhead, so keep a small
        // tolerance around a nominal 320 kbps encode rather than re-encoding
        // an already compliant Apple AAC / FDK-AAC file.
        return bitRate <= maximumBitRate * 1.03
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
            initialCompatibilityFormat(for: quality, song: song) == "raw"
                ? ["aac", "mp3"]
                : ["mp3", "raw"]
        case .opus160:
            ["aac", "mp3", "raw"]
        case .original:
            ["aac", "mp3"]
        }
    }

    /// Automatic quality follows the user's current network policy without
    /// replacing AVPlayer's throughput and buffering decisions. Explicit
    /// quality selections are never changed behind the user's back.
    private func preferredCompatibilityFormat(for song: Song) -> String {
        let standardFormat = Self.initialCompatibilityFormat(
            for: quality,
            song: song
        )
        guard quality == .automatic,
              song.externalStreamURL == nil else {
            return standardFormat
        }

        let rawProfile = PlaybackAudioProfile.resolve(
            song: song,
            compatibilityFormat: "raw"
        )
        if networkPathIsConstrained || networkLinkQualityIsMinimal {
            // Preserve an already efficient source. Re-encoding a modest AAC
            // or MP3 would spend server CPU without materially reducing the
            // transfer, while lossless and high-rate sources benefit from the
            // stable 160 kbps ceiling used by the existing Opus mode.
            if rawProfile == .aac || rawProfile == .compressed,
               let bitRate = PlaybackAudioProfile.estimatedBitRateKbps(for: song),
               bitRate <= 192 {
                return "raw"
            }
            return "opus"
        }
        if networkPathIsExpensive, rawProfile == .lossless {
            // Cellular and personal-hotspot paths should not start an ALAC or
            // other lossless transfer in Automatic mode. AAC remains broadly
            // hardware-decoded by Apple devices and avoids an aggressive
            // quality reduction on an otherwise healthy metered connection.
            return "aac"
        }
        return standardFormat
    }

    private func compatibilityFallbackFormats(
        for song: Song,
        startingWith initialFormat: String
    ) -> [String] {
        guard quality == .automatic,
              song.externalStreamURL == nil else {
            return Self.fallbackFormats(for: quality, song: song)
        }
        return switch initialFormat.lowercased() {
        case "raw": networkPathIsConstrained
            || networkPathIsExpensive
            || networkLinkQualityIsMinimal
            ? ["opus", "aac", "mp3"]
            : ["aac", "opus", "mp3"]
        case "aac": ["opus", "mp3", "raw"]
        case "opus": ["aac", "mp3", "raw"]
        case "mp3": ["opus", "aac", "raw"]
        default: ["opus", "aac", "mp3", "raw"]
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

    private func installNetworkPathMonitor() {
        networkPathMonitor.pathUpdateHandler = { @Sendable [weak self] path in
            let isSatisfied = path.status == .satisfied
            let isExpensive = path.isExpensive
            let isConstrained = path.isConstrained
            let linkQualityIsMinimal: Bool
            if #available(iOS 27.0, *) {
                linkQualityIsMinimal = path.linkQuality == .minimal
            } else {
                linkQualityIsMinimal = false
            }
            let allowsPrefetch = path.status == .satisfied
                && !isExpensive
                && !isConstrained
            Task { @MainActor [weak self] in
                guard let self else { return }
                let connectivityChanged = self.networkPathIsSatisfied != isSatisfied
                let prefetchChanged = self.allowsSpeculativeNetworkPrefetch != allowsPrefetch
                let pathPolicyChanged = self.networkPathIsExpensive != isExpensive
                    || self.networkPathIsConstrained != isConstrained
                    || self.networkLinkQualityIsMinimal != linkQualityIsMinimal
                self.networkPathIsSatisfied = isSatisfied
                self.networkPathIsExpensive = isExpensive
                self.networkPathIsConstrained = isConstrained
                self.networkLinkQualityIsMinimal = linkQualityIsMinimal
                self.allowsSpeculativeNetworkPrefetch = allowsPrefetch
                if pathPolicyChanged,
                   self.quality == .automatic,
                   let song = self.currentSong,
                   let activeFormat = self.activeCompatibilityFormat {
                    self.fallbackFormats = self.compatibilityFallbackFormats(
                        for: song,
                        startingWith: activeFormat
                    )
                    self.fallbackIndex = 0
                }
                if prefetchChanged, allowsPrefetch {
                    self.scheduleSpeculativePrefetchAfterPlaybackStability()
                } else if prefetchChanged {
                    self.suspendSpeculativePrefetch()
                }
                if isSatisfied {
                    self.scheduleUpcomingVisualPrefetch()
                }
                guard connectivityChanged else { return }
                if !isSatisfied {
                    self.prolongedStallRecoveryTask?.cancel()
                    self.prolongedStallRecoveryTask = nil
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
                    let compatibilityFormat = self.quality == .automatic
                        ? self.currentSong.map {
                            self.preferredCompatibilityFormat(for: $0)
                        }
                        : self.activeCompatibilityFormat
                    self.activeCompatibilityFormat = compatibilityFormat
                    if let song = self.currentSong,
                       let compatibilityFormat {
                        self.fallbackFormats = self.compatibilityFallbackFormats(
                            for: song,
                            startingWith: compatibilityFormat
                        )
                        self.fallbackIndex = 0
                    }
                    self.loadCurrentItem(
                        compatibilityFormat: compatibilityFormat,
                        resumeFrom: self.elapsed
                    )
                } else {
                    guard self.player.timeControlStatus != .playing else { return }
                    self.configureAudioSession()
                    self.requestPlayback()
                }
            }
        }
        networkPathMonitor.start(queue: networkPathQueue)
    }

    private static let preparedPlaybackAssetLimit = 2

    private static func preparedPlaybackKey(
        accountScope: String?,
        queueEntryID: UUID,
        streamRevision: String,
        quality: StreamQuality,
        compatibilityFormat: String
    ) -> PreparedPlaybackKey {
        PreparedPlaybackKey(
            accountScope: accountScope,
            queueEntryID: queueEntryID,
            streamRevision: streamRevision,
            quality: quality,
            compatibilityFormat: compatibilityFormat
        )
    }

    private static func makeURLAsset(
        url: URL,
        mimeType: String?
    ) -> AVURLAsset {
        // Some OpenSubsonic servers omit or generalize Content-Type. Preserve
        // the same out-of-band hint used by active playback while warming the
        // exact asset that will later be handed to AVPlayer.
        var options: [String: Any] = [
            AVURLAssetPreferPreciseDurationAndTimingKey: url.isFileURL
        ]
        if let mimeType {
            options["AVURLAssetOutOfBandMIMETypeKey"] = mimeType
        }
        return AVURLAsset(url: url, options: options)
    }

    private static func makePlayerItem(asset: AVURLAsset) -> AVPlayerItem {
        // Match the transport shape used by TIDAL's AVQueuePlayer backend
        // while using Apple's modern asynchronous asset-loading path.
        // AVFoundation remains responsible for the actual forward-buffer
        // decision and HLS variant startup; these are no-ops for direct files.
        let item = AVPlayerItem(asset: asset)
        item.variantPreferences = .scalabilityToLosslessAudio
        item.startsOnFirstEligibleVariant = true
        PlaybackBufferPolicy.configure(item)
        return item
    }

    private func preparePlaybackAsset(for entry: PlaybackQueueEntry) {
        let song = entry.song
        guard song.externalStreamURL == nil else { return }
        let preparedQuality = quality
        let compatibilityFormat = preferredCompatibilityFormat(for: song)
        let key = Self.preparedPlaybackKey(
            accountScope: currentAccountScope,
            queueEntryID: entry.id,
            streamRevision: song.audioResourceRevision,
            quality: preparedQuality,
            compatibilityFormat: compatibilityFormat
        )
        if let prepared = preparedPlaybackAssets[key] {
            // Active playback may consume an in-flight asset immediately, but
            // gapless staging waits until the speculative isPlayable load has
            // completed so AVQueuePlayer never advances into an unvalidated item.
            if preparedPlaybackWarmupTasks[key] == nil {
                stagePreparedSuccessorIfPossible(prepared)
            }
            return
        }
        guard preparedPlaybackWarmupTasks[key] == nil else {
            return
        }

        let warmupToken = UUID()
        preparedPlaybackWarmupTokens[key] = warmupToken
        let task = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                if self.preparedPlaybackWarmupTokens[key] == warmupToken {
                    self.preparedPlaybackWarmupTokens[key] = nil
                    self.preparedPlaybackWarmupTasks[key] = nil
                }
            }
            do {
                let decisionWarmup = Task(priority: .utility) { [weak self] in
                    guard let client = self?.client else { return }
                    _ = try? await client.transcodeDecision(mediaID: song.id)
                }
                let resource = try await self.playbackResource(
                    for: song,
                    compatibilityFormat: compatibilityFormat,
                    allowLocalSource: true
                )
                _ = await decisionWarmup.value
                guard !Task.isCancelled,
                      self.quality == preparedQuality,
                      self.playbackState.entries.contains(where: {
                          $0.id == entry.id
                              && $0.song.audioResourceRevision
                                  == song.audioResourceRevision
                      }) else {
                    return
                }

                let asset = Self.makeURLAsset(
                    url: resource.url,
                    mimeType: resource.mimeType
                )
                let prepared = PreparedPlaybackAsset(
                    key: key,
                    queueEntryID: entry.id,
                    songID: song.id,
                    streamRevision: song.audioResourceRevision,
                    compatibilityFormat: compatibilityFormat,
                    asset: asset
                )
                // Publish the exact AVURLAsset before transport warmup finishes.
                // If the user skips while `load(.isPlayable)` is still running,
                // active playback can take over this partially warmed asset
                // instead of opening a duplicate request for the same song.
                self.storePreparedPlaybackAsset(prepared)
                do {
                    _ = try await asset.load(.isPlayable)
                    guard !Task.isCancelled else { return }
                    self.stagePreparedSuccessorIfPossible(prepared)
                } catch {
                    // A failed speculative asset must not remain reusable. If
                    // active playback already took ownership, the token was
                    // cleared and AVPlayer's normal failure/fallback path owns it.
                    if self.preparedPlaybackWarmupTokens[key] == warmupToken {
                        self.preparedPlaybackAssets[key] = nil
                        self.preparedPlaybackAssetOrder.removeAll { $0 == key }
                    }
                }
            } catch {
                // Warming is speculative. Active playback retains its normal
                // codec fallback and recovery path if preparation fails.
            }
        }
        preparedPlaybackWarmupTasks[key] = task
    }

    private func scheduleGaplessSuccessor() {
        let activelyPlaying = player.timeControlStatus == .playing
        guard wantsPlayback,
              !isRemoteLosslessPlayback,
              stagedSuccessorItem == nil,
              PlaybackGaplessPreparationPolicy.shouldPrepare(
                elapsed: currentPlayerPosition(),
                duration: duration,
                isBuffering: isBuffering,
                isActivelyPlaying: activelyPlaying,
                profile: currentPlaybackAudioProfile()
              ),
              let plan = GaplessSuccessorPlan.make(
                queueCount: queue.count,
                currentIndex: queueIndex,
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
              !isRemoteLosslessPlayback,
              !isShuffleEnabled,
              repeatMode != .one,
              wantsPlayback,
              PlaybackGaplessPreparationPolicy.shouldStage(
                elapsed: currentPlayerPosition(),
                duration: duration,
                isBuffering: isBuffering,
                isActivelyPlaying: player.timeControlStatus == .playing,
                profile: currentPlaybackAudioProfile()
              ),
              let currentItem = player.currentItem,
              queue.indices.contains(queueIndex),
              currentSong?.id == queue[queueIndex].id else {
            return
        }
        guard let plan = GaplessSuccessorPlan.make(
            queueCount: queue.count,
            currentIndex: queueIndex,
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

        let item = Self.makePlayerItem(asset: prepared.asset)
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
        preparedPlaybackWarmupTokens[prepared.key] = nil
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

    @discardableResult
    private func commitStagedSuccessorIfItMatches(
        queueIndex: Int,
        origin: PlaybackOrigin,
        transitionReason: PlaybackEndReason
    ) -> Bool {
        guard queue.indices.contains(queueIndex),
              PlaybackSkipPlan.shouldCommitStagedSuccessor(
                stagedQueueIndex: stagedSuccessorQueueIndex,
                stagedOccurrenceID: stagedSuccessorOccurrenceID,
                nextQueueIndex: queueIndex,
                nextOccurrenceID: playbackState.entries[queueIndex].id
              ),
              let staged = stagedSuccessorItem else {
            return false
        }
        if player.currentItem !== staged {
            guard player.items().contains(where: { $0 === staged }) else {
                return false
            }
            player.advanceToNextItem()
        }
        guard player.currentItem === staged else { return false }
        activateStagedSuccessor(
            staged,
            origin: origin,
            transitionReason: transitionReason
        )
        return stagedSuccessorItem == nil
    }

    private func storePreparedPlaybackAsset(_ prepared: PreparedPlaybackAsset) {
        preparedPlaybackAssets[prepared.key] = prepared
        preparedPlaybackAssetOrder.removeAll { $0 == prepared.key }
        preparedPlaybackAssetOrder.append(prepared.key)
        while preparedPlaybackAssetOrder.count > Self.preparedPlaybackAssetLimit {
            let evicted = preparedPlaybackAssetOrder.removeFirst()
            preparedPlaybackAssets[evicted] = nil
            preparedPlaybackWarmupTokens[evicted] = nil
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
        preparedPlaybackWarmupTokens[key] = nil
        preparedPlaybackWarmupTasks[key] = nil
        return prepared
    }

    private func discardPreparedPlaybackAssets() {
        preparedPlaybackWarmupTasks.values.forEach { $0.cancel() }
        preparedPlaybackWarmupTasks.removeAll(keepingCapacity: false)
        preparedPlaybackWarmupTokens.removeAll(keepingCapacity: false)
        preparedPlaybackAssets.removeAll(keepingCapacity: false)
        preparedPlaybackAssetOrder.removeAll(keepingCapacity: false)
    }

    private func cancelVisualPrefetch(resetKey: Bool) {
        visualPrefetchTask?.cancel()
        visualPrefetchTask = nil
        visualPrefetchToken = nil
        if resetKey {
            lastVisualPrefetchKey = nil
            cancelUpcomingMetadataPrefetch()
        }
    }

    private func cancelUpcomingMetadataPrefetch() {
        upcomingMetadataPrefetchTask?.cancel()
        upcomingMetadataPrefetchTask = nil
        upcomingMetadataPrefetchKey = nil
    }

    private func prefetchedUpcomingSongs(
        plan: PlaybackPrefetchPlan,
        client: OpenSubsonicClient
    ) async -> [Song] {
        if upcomingMetadataPrefetchKey == plan.key,
           let task = upcomingMetadataPrefetchTask {
            return await task.value
        }
        upcomingMetadataPrefetchTask?.cancel()
        let songs = plan.upcomingSongs
        let task = Task {
            await client.prefetchUpcomingPlaybackContext(songs: songs)
        }
        upcomingMetadataPrefetchKey = plan.key
        upcomingMetadataPrefetchTask = task
        return await task.value
    }

    private func cancelOfflinePrefetch(resetKey: Bool) {
        offlinePrefetchTask?.cancel()
        offlinePrefetchTask = nil
        offlinePrefetchToken = nil
        if resetKey { lastOfflinePrefetchKey = nil }
    }

    private func suspendSpeculativePrefetch() {
        speculativePrefetchStartTask?.cancel()
        speculativePrefetchStartTask = nil
        speculativePrefetchStartToken = nil
        cancelVisualPrefetch(resetKey: true)
        cancelOfflinePrefetch(resetKey: true)
        discardPreparedPlaybackAssets()
    }

    /// Give the active stream an uncontested opening window before optional
    /// artwork, lyrics, and offline preparation begin. Resumes later in a song
    /// skip the delay because AVPlayer already owns a stable connection.
    private func scheduleSpeculativePrefetchAfterPlaybackStability() {
        speculativePrefetchStartTask?.cancel()
        speculativePrefetchStartTask = nil
        speculativePrefetchStartToken = nil
        guard wantsPlayback,
              player.timeControlStatus == .playing else { return }

        let remainingDelay = max(
            0,
            PlaybackGaplessPreparationPolicy.stablePlaybackWindow
                - currentPlayerPosition()
        )
        if remainingDelay <= 0.05 {
            scheduleOfflinePrefetch()
            return
        }

        let token = UUID()
        speculativePrefetchStartToken = token
        speculativePrefetchStartTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(remainingDelay))
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.speculativePrefetchStartToken == token,
                  self.wantsPlayback,
                  self.player.timeControlStatus == .playing else {
                return
            }
            self.speculativePrefetchStartTask = nil
            self.speculativePrefetchStartToken = nil
            self.scheduleOfflinePrefetch()
        }
    }

    private func playbackPrefetchPlan(
        permitsPendingPlayback: Bool = false
    ) -> PlaybackPrefetchPlan? {
        PlaybackPrefetchPlan.make(
            currentSong: currentSong,
            queue: queue,
            queueIndex: queueIndex,
            quality: quality,
            isActivelyPlaying:
                wantsPlayback && (
                    permitsPendingPlayback
                        || player.timeControlStatus == .playing
                )
        )
    }

    private func resetPlaybackPrefetchTracking() {
        playbackPrefetchInFlightSongIDs.removeAll(keepingCapacity: false)
        playbackPrefetchCompletedSongIDs.removeAll(keepingCapacity: false)
    }

    private func shouldPrefetchPlaybackCache(for song: Song) -> Bool {
        guard song.externalStreamURL == nil else { return false }
        if playbackPrefetchCompletedSongIDs.contains(song.id) { return false }
        if playbackPrefetchInFlightSongIDs.contains(song.id) { return false }
        return true
    }

    private func markPlaybackPrefetchStarted(for songID: String) {
        playbackPrefetchInFlightSongIDs.insert(songID)
    }

    private func markPlaybackPrefetchFinished(for songID: String, cached: Bool) {
        playbackPrefetchInFlightSongIDs.remove(songID)
        if cached {
            playbackPrefetchCompletedSongIDs.insert(songID)
        }
    }

    /// Cover art, metadata, lyrics, and palettes for upcoming entries are
    /// presentation-critical even when a user skips several tracks before the
    /// two-second audio stability window. Warm up to five entries (or fewer
    /// when the queue is shorter). Traffic stays background-class; constrained
    /// links run one cover at a time so AVFoundation keeps transport priority.
    private func scheduleUpcomingVisualPrefetch() {
        guard networkPathIsSatisfied,
              wantsPlayback,
              let client,
              let plan = playbackPrefetchPlan(
                  permitsPendingPlayback: true
              ) else {
            cancelVisualPrefetch(resetKey: true)
            return
        }
        let processInfo = ProcessInfo.processInfo
        guard !processInfo.isLowPowerModeEnabled,
              processInfo.thermalState != .serious,
              processInfo.thermalState != .critical else {
            cancelVisualPrefetch(resetKey: true)
            return
        }
        guard lastVisualPrefetchKey != plan.key else { return }
        cancelVisualPrefetch(resetKey: false)
        lastVisualPrefetchKey = plan.key

        let token = UUID()
        let sessionGeneration = playbackSessionGeneration
        let accountScope = currentAccountScope
        let isConstrained = networkPathIsExpensive
            || networkPathIsConstrained
            || networkLinkQualityIsMinimal
        visualPrefetchToken = token
        visualPrefetchTask = Task(priority: .utility) { [weak self] in
            do {
                // Submit the active stream first, then let background artwork
                // share the established connection without extending the old
                // two-second placeholder window.
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.visualPrefetchToken == token,
                  self.playbackSessionGeneration == sessionGeneration,
                  self.currentAccountScope == accountScope,
                  self.wantsPlayback else { return }

            let songs = await self.prefetchedUpcomingSongs(
                plan: plan,
                client: client
            )
            guard !Task.isCancelled,
                  self.visualPrefetchToken == token else { return }

            var coverURLs: [URL] = []
            var seenArtwork = Set<String>()
            for song in songs {
                let revision = song.artworkRevision
                guard let coverID = song.artworkID,
                      seenArtwork.insert("\(coverID)|\(revision)").inserted,
                      let sourceURL = try? client.coverURL(
                          id: coverID,
                          size: nil
                      ) else { continue }
                coverURLs.append(ArtworkStore.cacheURL(
                    for: sourceURL,
                    revision: revision
                ))
            }
            await ArtworkStore.shared.prefetch(
                urls: coverURLs,
                pixelSize: ArtworkRequestSizing.fullPlayerPixelSize,
                concurrencyLimit: isConstrained ? 1 : 3
            )
            guard !Task.isCancelled,
                  self.visualPrefetchToken == token else { return }

            for coverURL in coverURLs.prefix(isConstrained ? 1 : coverURLs.count) {
                guard !Task.isCancelled,
                      self.visualPrefetchToken == token else { return }
                _ = await ArtworkStore.shared.palette(for: coverURL)
            }
        }
    }

    private func scheduleOfflinePrefetch() {
        guard !isRemoteLosslessPlayback else {
            cancelOfflinePrefetch(resetKey: true)
            return
        }
        let thermalState = ProcessInfo.processInfo.thermalState
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled,
              thermalState != .serious,
              thermalState != .critical else {
            cancelOfflinePrefetch(resetKey: true)
            return
        }
        guard allowsSpeculativeNetworkPrefetch,
              let client,
              let plan = playbackPrefetchPlan() else {
            cancelOfflinePrefetch(resetKey: true)
            return
        }
        guard lastOfflinePrefetchKey != plan.key else { return }
        cancelOfflinePrefetch(resetKey: false)
        lastOfflinePrefetchKey = plan.key

        let token = UUID()
        offlinePrefetchToken = token
        offlinePrefetchTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                if self.offlinePrefetchToken == token {
                    self.offlinePrefetchTask = nil
                    self.offlinePrefetchToken = nil
                }
            }
            let candidates = plan.upcomingSongs.filter {
                self.shouldPrefetchPlaybackCache(for: $0)
            }
            guard !candidates.isEmpty else { return }
            for song in candidates {
                guard !Task.isCancelled else { return }
                if await OfflineStore.shared.localURL(for: song) != nil {
                    self.markPlaybackPrefetchFinished(for: song.id, cached: true)
                    continue
                }
                self.markPlaybackPrefetchStarted(for: song.id)
                let cached = await OfflineStore.shared.prefetchPlaybackCache(
                    song: song,
                    client: client
                )
                self.markPlaybackPrefetchFinished(for: song.id, cached: cached)
            }
        }
    }


    private func restartPlaybackPlan(resumeFrom: TimeInterval) {
        guard let song = currentSong else { return }
        recoveryStabilityTask?.cancel()
        recoveryStabilityTask = nil
        prolongedStallRecoveryTask?.cancel()
        prolongedStallRecoveryTask = nil
        playbackStallCount = 0
        recoveryAttempt = 0
        fallbackIndex = 0
        let preferredFormat = preferredCompatibilityFormat(for: song)
        fallbackFormats = compatibilityFallbackFormats(
            for: song,
            startingWith: preferredFormat
        )
        activeCompatibilityFormat = preferredFormat
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
        let resourceOffset = streamOffsetSeconds(
            for: song,
            resumePosition: resumePosition,
            compatibilityFormat: compatibilityFormat,
            allowLocalSource: fallbackIndex == 0
        )
        streamBaseOffset = resourceOffset > 0
            ? TimeInterval(resourceOffset)
            : 0
        prolongedStallRecoveryTask?.cancel()
        prolongedStallRecoveryTask = nil
        itemLoadTask?.cancel()
        itemLoadGeneration &+= 1
        let generation = itemLoadGeneration
        seekGeneration &+= 1
        isSeekInFlight = false
        if resourceOffset == 0,
           pendingSeekPosition == nil,
           resumePosition > 0 {
            pendingSeekPosition = resumePosition
        } else if resourceOffset > 0 {
            pendingSeekPosition = nil
            elapsed = TimeInterval(resourceOffset)
        }
        activeCompatibilityFormat = compatibilityFormat
        isBuffering = wantsPlayback

        if resumePosition <= 0.05,
           resourceOffset == 0,
           let prepared = takePreparedPlaybackAsset(
            for: playbackItem,
            compatibilityFormat: compatibilityFormat
        ) {
            itemLoadTask = nil
            replacePlayerItem(
                asset: prepared.asset,
                resumePosition: resumePosition
            )
            return
        }

        itemLoadTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            defer {
                if self.itemLoadGeneration == generation {
                    self.itemLoadTask = nil
                }
            }
            do {
                let resource = try await self.playbackResource(
                    for: song,
                    compatibilityFormat: compatibilityFormat,
                    allowLocalSource: self.fallbackIndex == 0,
                    offsetSeconds: resourceOffset
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
        removeCurrentItemObservers()
        invalidateStagedSuccessor(removeFromPlayer: true)
        let item = Self.makePlayerItem(asset: asset)
        observeActiveItem(item, resumePosition: resumePosition)
        player.replaceCurrentItem(with: item)
        playbackItemInstalledAt = ProcessInfo.processInfo.systemUptime
        handledFailedItem = nil
        updateActiveLyric(at: elapsed)
        installNextLyricBoundary(after: elapsed)

        let needsPositioning = (pendingSeekPosition ?? resumePosition) > 0.05
        if wantsPlayback, !needsPositioning {
            // Submit play intent as soon as the item enters AVQueuePlayer.
            // AVFoundation can then open the stream and evaluate buffering in
            // parallel instead of BuFi adding a separate readyToPlay gate.
            // The ready observer repeats play for AirPlay routes, which may
            // ignore an early request until their underlying item is ready.
            player.isMuted = false
            player.volume = 1
            activateNowPlayingSession()
            if asset.url.isFileURL {
                requestPlayback()
            } else {
                requestLowLatencyStartup()
            }
        }
        if let pendingSong = pendingPlaybackContextSong,
           pendingSong.id == currentSong?.id {
            pendingPlaybackContextSong = nil
            schedulePlaybackContextLoad(for: pendingSong)
        }
    }

    private func schedulePlaybackContextLoad(for song: Song) {
        playbackContextStartTask?.cancel()
        let playbackItemID = currentPlaybackItem?.id
        playbackContextStartTask = Task { [weak self] in
            do {
                // Let AVPlayer own the first network scheduling slice. The UI
                // already has provisional row metadata and artwork during this
                // short interval, so no visible content is withheld.
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.currentPlaybackItem?.id == playbackItemID,
                  self.currentSong?.id == song.id else { return }
            self.playbackContextStartTask = nil
            self.refreshCanonicalMetadata(for: song)
            self.loadLyrics(for: song)
        }
    }

    private func observeActiveItem(
        _ item: AVPlayerItem,
        resumePosition: TimeInterval
    ) {
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
                    self.updateDuration(using: item.duration.seconds)
                    if self.streamBaseOffset > 0 {
                        self.elapsed = self.streamBaseOffset
                        self.pendingSeekPosition = nil
                        self.isBuffering = false
                        self.recomputeTimelineFromPlayer()
                        self.installNextLyricBoundary(after: self.elapsed)
                        if self.wantsPlayback {
                            self.configureAudioSession()
                            self.player.isMuted = false
                            self.player.volume = 1
                            self.activateNowPlayingSession()
                            self.requestPlayback()
                        }
                        return
                    }
                    let targetPosition = self.pendingSeekPosition ?? resumePosition
                    let needsPositioning = targetPosition > 0.05
                    if needsPositioning {
                        // Never start a freshly reloaded item at zero and then
                        // seek it back to the recovery position. Wait for the
                        // seek completion before resuming audio so a transient
                        // transport retry cannot produce an audible jump/cut.
                        self.isBuffering = self.wantsPlayback
                        self.seekPlayer(
                            to: targetPosition,
                            persistsQueue: false,
                            resumesPlayback: self.wantsPlayback
                        )
                    } else {
                        self.pendingSeekPosition = nil
                        self.isBuffering = false
                        self.recomputeTimelineFromPlayer()
                        self.installNextLyricBoundary(after: self.elapsed)
                    }
                    if self.wantsPlayback, !needsPositioning {
                        self.configureAudioSession()
                        self.player.isMuted = false
                        self.player.volume = 1
                        self.activateNowPlayingSession()
                        self.requestPlayback()
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
        schedulesFollowingSuccessor: Bool = true,
        origin: PlaybackOrigin = .autoplay,
        transitionReason: PlaybackEndReason = .completed
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
        finalizeCurrentPlayback(reason: transitionReason)
        removeCurrentItemObservers()
        stagedSuccessorItem = nil
        stagedSuccessorSong = nil
        stagedSuccessorQueueIndex = nil
        stagedSuccessorOccurrenceID = nil
        stagedSuccessorObservation = nil
        stagedSuccessorObservationID = nil
        playbackState.setIndex(successorIndex, renewsPlayback: true)
        resetTrackPresentation(
            for: song,
            origin: origin,
            previousSongID: previousSongID
        )
        observeActiveItem(item, resumePosition: 0)
        refreshCanonicalMetadata(for: song)
        loadLyrics(for: song)
        scheduleQueueSave(immediate: true)
        updateNowPlaying()
        scheduleAutoplayContinuationIfNeeded()
        if schedulesFollowingSuccessor { scheduleGaplessSuccessor() }
    }

    private func resetTrackPresentation(
        for song: Song,
        origin: PlaybackOrigin,
        previousSongID: String?
    ) {
        recordPlaybackStart(song, origin: origin)
        rememberShuffleSelection(song.id)
        elapsed = 0
        duration = song.safeDuration
        pendingSeekPosition = nil
        isSeekInFlight = false
        applyLyricsDocument(.empty)
        fallbackIndex = 0
        let preferredFormat = preferredCompatibilityFormat(for: song)
        fallbackFormats = compatibilityFallbackFormats(
            for: song,
            startingWith: preferredFormat
        )
        activeCompatibilityFormat = preferredFormat
        prolongedStallRecoveryTask?.cancel()
        prolongedStallRecoveryTask = nil
        playbackStallCount = 0
        recoveryAttempt = 0
        playbackError = nil
        scrobbled = false
        lastMaintenanceSecond = -1
        handledFailedItem = nil
        if previousSongID != song.id {
            provideTrackChangeHaptic()
            songChangeHandler?(song)
        }
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
                    MainActor.assumeIsolated {
                        guard let self,
                              self.itemObserverGeneration == generation,
                              let item = self.logicalCurrentItem,
                              self.player.currentItem === item else {
                            return
                        }
                        Self.logger.warning(
                            "Playback stalled; waiting for AVPlayer to refill"
                        )
                        self.isBuffering = self.wantsPlayback
                        self.suspendSpeculativePrefetch()
                        self.scheduleProlongedStallRecovery(
                            for: item,
                            observerGeneration: generation
                        )
                    }
                },
                center.addObserver(
                    forName: .AVPlayerItemFailedToPlayToEndTime,
                    object: item,
                    queue: .main
                ) { @Sendable [weak self] _ in
                    MainActor.assumeIsolated {
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
                    MainActor.assumeIsolated {
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
                    self.isBuffering = true
                    self.suspendSpeculativePrefetch()
                }
            }
        }
        itemBufferObservations = [empty]
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
        let resolvedError = error ?? failedItem?.error
        guard networkPathIsSatisfied else {
            // Keep playback intent and the current retry budget intact. The
            // path-restoration handler reloads failed items directly.
            isBuffering = wantsPlayback
            return
        }
        let disposition = PlaybackFailureClassifier.disposition(for: resolvedError)
        if disposition == .failPermanent {
            finishPlaybackFailure(
                message: String(
                    localized: "이 음악을 재생하지 못했습니다. 서버의 스트리밍 형식과 네트워크 상태를 확인해 주세요."
                )
            )
            return
        }
        if disposition == .retryTransport {
            recoveryAttempt += 1
            if recoveryAttempt <= PlaybackTransportRetryPolicy.maximumTransportRetries {
                Self.logger.warning(
                    "Playback transport failed; retrying the active format"
                )
                reloadCurrentItemAfterBackoff(
                    attempt: recoveryAttempt,
                    compatibilityFormat: activeCompatibilityFormat
                )
                return
            }
            if let format = takeNextCompatibilityFormat(allowsRaw: false) {
                Self.logger.warning(
                    "Playback transport remained unstable; trying lower-bandwidth format \(format, privacy: .public)"
                )
                recoveryAttempt = 0
                activeCompatibilityFormat = format
                loadCurrentItem(
                    compatibilityFormat: format,
                    resumeFrom: currentPlayerPosition()
                )
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
        reloadCurrentItemAfterBackoff(
            attempt: 1,
            compatibilityFormat: format
        )
    }

    private func scheduleProlongedStallRecovery(
        for item: AVPlayerItem,
        observerGeneration: UInt64
    ) {
        guard quality == .automatic,
              currentSong?.externalStreamURL == nil,
              wantsPlayback,
              networkPathIsSatisfied else {
            return
        }
        playbackStallCount += 1
        let pathNeedsConservativeRecovery = networkPathIsConstrained
            || networkPathIsExpensive
            || networkLinkQualityIsMinimal
        guard pathNeedsConservativeRecovery || playbackStallCount >= 2,
              let format = lowerBandwidthCompatibilityFormat() else {
            return
        }

        prolongedStallRecoveryTask?.cancel()
        let playbackItemID = currentPlaybackItem?.id
        let recoveryDelay: Duration = pathNeedsConservativeRecovery
            ? .seconds(3)
            : .seconds(5)
        prolongedStallRecoveryTask = Task { [weak self, weak item] in
            do {
                try await Task.sleep(for: recoveryDelay)
            } catch {
                return
            }
            guard let self,
                  let item,
                  self.itemObserverGeneration == observerGeneration,
                  self.currentPlaybackItem?.id == playbackItemID,
                  self.player.currentItem === item,
                  self.player.timeControlStatus != .playing,
                  self.wantsPlayback,
                  self.networkPathIsSatisfied,
                  self.quality == .automatic else {
                return
            }
            Self.logger.warning(
                "Playback remained stalled; resuming with lower-bandwidth format \(format, privacy: .public)"
            )
            let position = self.currentPlayerPosition()
            self.prolongedStallRecoveryTask = nil
            self.activeCompatibilityFormat = format
            if let song = self.currentSong {
                self.fallbackFormats = self.compatibilityFallbackFormats(
                    for: song,
                    startingWith: format
                )
            }
            self.fallbackIndex = 0
            self.recoveryAttempt = 0
            self.loadCurrentItem(
                compatibilityFormat: format,
                resumeFrom: position
            )
        }
    }

    private func lowerBandwidthCompatibilityFormat() -> String? {
        switch activeCompatibilityFormat?.lowercased() {
        case "opus": return nil
        case "raw":
            return networkPathIsConstrained
                || networkPathIsExpensive
                || networkLinkQualityIsMinimal
                ? "opus"
                : "aac"
        case "aac", "mp3", .none: return "opus"
        default: return "opus"
        }
    }

    private func reloadCurrentItemAfterBackoff(
        attempt: Int,
        compatibilityFormat: String?
    ) {
        let generation = itemLoadGeneration
        let delay = PlaybackTransportRetryPolicy.transportBackoff(
            afterFailedAttempt: attempt,
            jitter: Double.random(in: 0.8...1.2)
        )
        Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self,
                  self.itemLoadGeneration == generation,
                  self.wantsPlayback,
                  self.currentSong != nil else {
                return
            }
            self.loadCurrentItem(
                compatibilityFormat: compatibilityFormat,
                resumeFrom: self.currentPlayerPosition()
            )
        }
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
        refreshIdleTimerPreference()
        updateNowPlaying()
        scheduleQueueSave(immediate: true)
        playbackError = message
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
            self.playbackStallCount = 0
            self.recoveryStabilityTask = nil
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
                self.isBuffering = self.wantsPlayback && !isPlaying
                if player.timeControlStatus == .playing {
                    self.prolongedStallRecoveryTask?.cancel()
                    self.prolongedStallRecoveryTask = nil
                    if let requestedAt = self.playbackStartupRequestedAt {
                        let now = ProcessInfo.processInfo.systemUptime
                        let total = max(0, now - requestedAt)
                        let itemDelay = self.playbackItemInstalledAt.map {
                            max(0, $0 - requestedAt)
                        } ?? total
                        Self.logger.info(
                            "Playback startup total=\(total, format: .fixed(precision: 3))s item=\(itemDelay, format: .fixed(precision: 3))s"
                        )
                        self.playbackStartupRequestedAt = nil
                        self.playbackItemInstalledAt = nil
                    }
                    self.scheduleRecoveryAttemptReset(for: player.currentItem)
                    self.reportPlaybackState("playing")
                    self.scheduleGaplessSuccessor()
                    self.scheduleSpeculativePrefetchAfterPlaybackStability()
                    self.scheduleUpcomingVisualPrefetch()
                } else if !self.wantsPlayback {
                    self.prolongedStallRecoveryTask?.cancel()
                    self.prolongedStallRecoveryTask = nil
                    self.recoveryStabilityTask?.cancel()
                    self.recoveryStabilityTask = nil
                    self.reportPlaybackState("paused")
                    self.suspendSpeculativePrefetch()
                } else {
                    // Waiting and buffering are AVPlayer-owned states. BuFi
                    // updates presentation only and does not seek, reload, or
                    // force the item back to an immediate playback rate.
                    self.recoveryStabilityTask?.cancel()
                    self.recoveryStabilityTask = nil
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
        let processInfo = ProcessInfo.processInfo
        let thermalState = processInfo.thermalState
        let refreshInterval = PlaybackTimelineRefreshPolicy.interval(
            isApplicationActive: applicationIsActive,
            showsFullPlayer: showPlayer,
            lowPowerModeEnabled: processInfo.isLowPowerModeEnabled,
            thermallyConstrained: thermalState == .serious || thermalState == .critical
        )
        guard timelineRefreshInterval != refreshInterval else { return }
        timelineRefreshInterval = refreshInterval
        timelineObserverGeneration &+= 1
        let generation = timelineObserverGeneration
        playbackObservers.replacePeriodicTimeObserver(
            interval: CMTime(
                seconds: refreshInterval,
                preferredTimescale: 600
            )
        ) { [weak self] time in
            guard let self,
                  self.timelineObserverGeneration == generation else {
                return
            }
            guard let logicalCurrentItem = self.logicalCurrentItem,
                  self.player.currentItem === logicalCurrentItem else { return }
            let seconds = time.seconds
            let relativeSeconds = seconds.isFinite ? max(0, seconds) : 0
            let absoluteSeconds = self.streamBaseOffset + relativeSeconds
            let lyricPosition = seconds.isFinite ? absoluteSeconds : self.elapsed
            if !self.isSeekInFlight,
               self.pendingSeekPosition == nil,
               seconds.isFinite {
                self.elapsed = absoluteSeconds
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
                // Re-evaluate once per playback second. The policy keeps
                // the next media transport closed until the final window,
                // then preserves gapless hand-off without long-lived dual
                // stream contention.
                self.scheduleGaplessSuccessor()
                self.submitScrobbleIfNeeded()
                let now = Date()
                if now.timeIntervalSince(self.lastQueueSaveRequest) >= 30 {
                    let shouldSyncServer = now.timeIntervalSince(
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
                lyricPosition = max(0, streamBaseOffset + seconds)
                elapsed = lyricPosition
                if duration > 0 { elapsed = min(elapsed, duration) }
            }
        }
        updateActiveLyric(at: lyricPosition)
    }

    private func currentPlayerPosition() -> TimeInterval {
        let seconds = player.currentTime().seconds
        return seconds.isFinite
            ? max(0, streamBaseOffset + seconds)
            : max(0, elapsed)
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
            notAfter: position,
            hint: activeLyricIndex
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
            guard let self,
                  self.lyricBoundaryGeneration == generation,
                  self.currentSong?.id == songID,
                  self.player.currentItem != nil,
                  !self.isSeekInFlight,
                  self.pendingSeekPosition == nil else {
                return
            }
            let playerTime = self.currentPlayerPosition()
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

    private func currentLyricPosition(fallback: TimeInterval) -> TimeInterval {
        if let pendingSeekPosition, pendingSeekPosition.isFinite {
            return max(0, pendingSeekPosition)
        }
        let playerTime = player.currentTime().seconds
        if playerTime.isFinite {
            return currentPlayerPosition()
        }
        return max(0, fallback)
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
            notAfter: resolvedPosition,
            hint: activeLyricIndex
        )
        if activeLyricIndex != index { activeLyricIndex = index }
    }

    /// Normal playback stays on one lyric line for many progress callbacks.
    /// Resolve that common case in O(1); seeks and skipped boundaries retain
    /// the O(log n) binary-search fallback.
    private static func lastIndex(
        in lines: [LyricLine],
        notAfter elapsed: TimeInterval,
        hint: Int? = nil
    ) -> Int {
        guard !lines.isEmpty else { return -1 }
        if let hint {
            if hint == -1, elapsed < lines[0].start {
                return -1
            }
            if lines.indices.contains(hint) {
                let lowerBound = lines[hint].start
                let upperBound = lines.indices.contains(hint + 1)
                    ? lines[hint + 1].start
                    : .infinity
                if elapsed >= lowerBound, elapsed < upperBound {
                    return hint
                }
            }
        }

        var low = 0
        var high = lines.count - 1
        var result = -1
        while low <= high {
            let mid = low + (high - low) / 2
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
        // A ready callback commonly arrives while the activation started by
        // the play command is still negotiating. Reuse that system operation
        // instead of cancelling it at the finish line and starting over.
        guard audioSessionActivationTask == nil else { return }
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

    private func prepareAudioSessionConfiguration() {
        // Category negotiation is invariant for the lifetime of the app. Do
        // it after the first scene has mounted, before a user taps Play, while
        // leaving the session inactive so other apps' audio is unaffected.
        let controller = audioSessionController
        let epoch = nextAudioSessionCommandEpoch()
        Task(priority: .utility) {
            await controller.prepare(epoch: epoch)
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
                MainActor.assumeIsolated {
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
                MainActor.assumeIsolated {
                    self?.handleRouteChange(reasonRawValue: reason)
                }
            })
            tokens.append(center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: audioSession,
                queue: .main
            ) { @Sendable [weak self] _ in
                MainActor.assumeIsolated {
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
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.setApplicationActive(false)
                    self.handleDidEnterBackground()
                }
            })
            tokens.append(center.addObserver(
                forName: UIApplication.willResignActiveNotification,
                object: nil,
                queue: .main
            ) { @Sendable [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.setApplicationActive(false)
                    self.preserveActivePlayback()
                }
            })
            tokens.append(center.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { @Sendable [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.setApplicationActive(true)
                    guard self.wantsPlayback else { return }
                    self.preserveActivePlayback()
                }
            })
            return tokens
        }
    }

    private func setApplicationActive(_ value: Bool) {
        guard applicationIsActive != value else { return }
        applicationIsActive = value
        installPlaybackTimeObserver()
    }

    private func handleDidEnterBackground() {
        scheduleQueueSave(immediate: true)
        guard wantsPlayback else {
            scheduleAudioSessionDeactivation(immediate: true)
            return
        }
        // Background audio is owned by the active `.playback` audio session;
        // no additional UIApplication task or recovery timer is required.
        preserveActivePlayback()
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
        recomputeTimelineFromPlayer()
        installNextLyricBoundary(after: elapsed)
        updateNowPlaying()
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
            markAudioSessionInactive()
            player.pause()
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
            defer {
                if let self, self.songMetadataGeneration == generation {
                    self.songMetadataTask = nil
                }
            }
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
            var resolved = canonicalItem.song
            // Favorite state may have changed again while getSong was in
            // flight. Preserve the latest optimistic value on the atomic item.
            resolved.starred = current.starred
            guard resolved != current else { return }
            let shouldReloadLyrics = LyricsLookupIdentity.shouldReload(
                from: current,
                to: resolved,
                lyricsAreAvailable: self.lyricsState.status == .available
            )

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
            self.fallbackFormats = self.compatibilityFallbackFormats(
                for: resolved,
                startingWith: self.activeCompatibilityFormat
                    ?? self.preferredCompatibilityFormat(for: resolved)
            )
            self.fallbackIndex = 0
            if previousStream != resolvedItem.stream,
               !self.isPlaying,
               self.currentPlayerPosition() < 1 {
                // A provisional row can omit or misreport suffix/MIME data.
                // Before meaningful playback begins, rebuild the transport
                // from the same canonical payload used by artwork/metadata.
                self.restartPlaybackPlan(resumeFrom: self.elapsed)
            }
            if shouldReloadLyrics {
                self.loadLyrics(
                    for: resolved,
                    forceRefresh: self.lyricsState.status != .loading
                )
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
        let visualKey = NowPlayingVisualIdentity(
            accountScope: playbackItem.accountScope,
            playbackID: playbackItem.id,
            metadataRevision: playbackItem.metadataRevision,
            artworkRevision: playbackItem.artwork.revision
        )
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
            let artworkPixelSize = ArtworkRequestSizing.pixelSize(
                pointSize: UIScreen.main.bounds.width,
                displayScale: UIScreen.main.scale
            )
            guard let sourceURL = try? client.coverURL(id: coverID) else {
                return
            }
            let url = ArtworkStore.cacheURL(
                for: sourceURL,
                revision: playbackItem.artwork.revision
            )
            guard let image = try? await ArtworkStore.shared.image(
                      for: url,
                      pixelSize: artworkPixelSize
                  ),
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
        trackChangeHapticGenerator.impactOccurred(intensity: 0.62)
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
        playbackReportDelivery.enqueue(
            client: client,
            songID: song.id,
            position: resolvedPosition,
            state: state
        )
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
                    currentIndex: snapshot.index,
                    position: snapshot.elapsed,
                    attempt: 0
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
                        position: request.position,
                        currentIndex: request.currentIndex
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
                    Self.serverQueueLogger.error(
                        "Server queue save failed on attempt \(request.attempt + 1, privacy: .public): \(String(describing: error), privacy: .public)"
                    )
                    guard request.attempt < 2,
                          CoreRequestClassifier.shouldRetry(error: error),
                          request.sessionGeneration == self.playbackSessionGeneration,
                          request.accountScope == self.currentAccountScope,
                          self.client === request.client else {
                        continue
                    }
                    try? await Task.sleep(
                        for: NetworkResiliencePolicy.retryDelay(
                            afterAttempt: request.attempt
                        )
                    )
                    guard !Task.isCancelled else { break }
                    self.pendingServerQueueSave = ServerQueueSaveRequest(
                        client: request.client,
                        accountScope: request.accountScope,
                        sessionGeneration: request.sessionGeneration,
                        revision: request.revision,
                        songIDs: request.songIDs,
                        currentID: request.currentID,
                        currentIndex: request.currentIndex,
                        position: request.position,
                        attempt: request.attempt + 1
                    )
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
        let restoreToken = UUID()
        queueRestoreToken = restoreToken
        queueRestoreTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.queueRestoreToken == restoreToken {
                    self.queueRestoreToken = nil
                    self.queueRestoreTask = nil
                }
            }
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
            refreshCanonicalMetadata(for: restoredSong)
        }
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

    func prepare(epoch: UInt64) {
        guard accept(epoch: epoch) else { return }
        _ = configureIfNeeded()
    }

    func activate(epoch: UInt64) -> Bool {
        guard accept(epoch: epoch) else { return false }
        if isActive { return true }
        guard configureIfNeeded() else { return false }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
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

    private func configureIfNeeded() -> Bool {
        if isConfigured { return true }
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .default,
                policy: .longFormAudio
            )
            isConfigured = true
            return true
        } catch {
            return false
        }
    }

    private func accept(epoch: UInt64) -> Bool {
        guard epoch >= latestCommandEpoch else { return false }
        latestCommandEpoch = epoch
        return true
    }
}
