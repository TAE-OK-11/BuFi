import Foundation

/// AVPlayer time is relative to the requested server stream offset, while the
/// queue, lyrics, and user seeks use absolute positions in the original song.
enum PlaybackTimelinePolicy {
    static func needsSeek(target: TimeInterval, streamOffset: TimeInterval) -> Bool {
        abs(target - streamOffset) > 0.05
    }

    static func absoluteDuration(
        playerDuration: TimeInterval,
        streamOffset: TimeInterval
    ) -> TimeInterval {
        guard playerDuration.isFinite, playerDuration > 0 else { return 0 }
        return max(0, streamOffset) + playerDuration
    }
}
