/// Raw/original requests already have a complete stream specification and
/// never require the server's transcode decision endpoint.
enum PlaybackStreamRoutingPolicy {
    static func requiresTranscodeDecision(
        quality: StreamQuality,
        compatibilityFormat: String?
    ) -> Bool {
        compatibilityFormat?.lowercased() != "raw" && quality != .original
    }
}
