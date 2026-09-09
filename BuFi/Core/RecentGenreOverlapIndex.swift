/// Each bit represents one of the last six songs, rather than one genre.
/// Combining genre masks counts a matching song once even if it shares several
/// genres with the candidate. This is equivalent to the previous nested scan.
struct RecentGenreOverlapIndex: Sendable {
    private var masks: [String: UInt8] = [:]

    init(_ recentGenres: [[String]]) {
        for (index, genres) in recentGenres.suffix(6).enumerated() {
            let bit = UInt8(1) << index
            for genre in genres {
                masks[genre, default: 0] |= bit
            }
        }
    }

    func count(matching genres: [String]) -> Int {
        var matched: UInt8 = 0
        for genre in genres {
            matched |= masks[genre, default: 0]
        }
        return matched.nonzeroBitCount
    }
}
