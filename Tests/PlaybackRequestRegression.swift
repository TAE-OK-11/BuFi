import Foundation

@main
struct PlaybackRequestRegression {
    static func main() throws {
        let values = [
            URLQueryItem(name: "apiKey", value: "secret+with space&=%"),
            URLQueryItem(name: "id", value: "곡+1"),
            URLQueryItem(name: "id", value: "second/id"),
            URLQueryItem(name: "empty", value: "")
        ]
        let encoded = OpenSubsonicRequestEncoding.query(values)!
        precondition(!encoded.contains("+"))
        var decoded = URLComponents()
        // Model a form parser's plus-to-space conversion before percent decoding.
        decoded.percentEncodedQuery = encoded.replacingOccurrences(of: "+", with: " ")
        precondition(decoded.queryItems == values, "Form values must round trip exactly")

        let url = URL(string: "https://example.test/music/rest/stream.view?id=a+b&token=c%2Bd&name=x%20y")!
        let protected = OpenSubsonicRequestEncoding.protectingLiteralPluses(in: url)
        precondition(protected.absoluteString.contains("id=a%2Bb"))
        precondition(protected.absoluteString.contains("token=c%2Bd"))
        precondition(!protected.absoluteString.contains("%252B"))
        precondition(OpenSubsonicRequestEncoding.protectingLiteralPluses(in: protected) == protected)
        precondition(protected.path == url.path)

        precondition(PlaybackTimelinePolicy.needsSeek(target: 120.75, streamOffset: 120))
        precondition(!PlaybackTimelinePolicy.needsSeek(target: 120, streamOffset: 120))
        precondition(PlaybackTimelinePolicy.needsSeek(target: 45, streamOffset: 120))
        precondition(PlaybackTimelinePolicy.needsSeek(target: 12, streamOffset: 0))
        precondition(!PlaybackTimelinePolicy.needsSeek(target: 0, streamOffset: 0))
        precondition(PlaybackTimelinePolicy.absoluteDuration(playerDuration: 60, streamOffset: 120) == 180)
        precondition(PlaybackTimelinePolicy.absoluteDuration(playerDuration: 180, streamOffset: 0) == 180)
        precondition(PlaybackTimelinePolicy.absoluteDuration(playerDuration: .nan, streamOffset: 120) == 0)
        precondition(PlaybackTimelinePolicy.absoluteDuration(playerDuration: .infinity, streamOffset: 120) == 0)
        print("Playback timeline and request encoding regressions passed")
    }
}
