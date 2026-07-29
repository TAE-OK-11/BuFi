import Foundation
import XCTest
@testable import BuFi

final class RecommendationEngineTests: XCTestCase {
    func testCanonicalVersionsAreDeduplicated() {
        let original = song(
            id: "original",
            title: "Midnight Rain",
            artist: "Taylor Swift"
        )
        let remaster = song(
            id: "remaster",
            title: "Midnight Rain (Remastered 2026)",
            artist: "Taylor Swift"
        )
        let snapshot = HomeSnapshot(randomSongs: [original, remaster])

        let result = RecommendationMixer.mix(
            snapshot: snapshot,
            weights: weights(),
            limit: 10,
            date: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(result.count, 1)
    }

    func testExternalConsensusRanksAboveSingleSource() {
        let consensus = song(
            id: "consensus",
            title: "Consensus",
            artist: "Artist A",
            genre: "Pop"
        )
        let singleSource = song(
            id: "single",
            title: "Single",
            artist: "Artist B",
            genre: "Rock"
        )
        let snapshot = HomeSnapshot(
            starredSongs: [
                song(
                    id: "favorite",
                    title: "Favorite",
                    artist: "Favorite Artist",
                    genre: "Pop",
                    starred: "2026-07-29T00:00:00Z"
                )
            ],
            lastFMRecommendedSongs: [singleSource, consensus],
            listenBrainzRecommendedSongs: [consensus]
        )

        let result = RecommendationMixer.mix(
            snapshot: snapshot,
            weights: weights(),
            purpose: .discovery,
            limit: 2,
            date: Date(timeIntervalSince1970: 1_800_000_000)
        )

        XCTAssertEqual(result.first?.id, consensus.id)
    }

    func testLimitAndIdentityDeduplicationAreStable() {
        let repeated = (0..<12).flatMap { index -> [Song] in
            let value = song(
                id: "song-\(index)",
                title: "Track \(index)",
                artist: "Artist \(index % 4)"
            )
            return [value, value]
        }
        let snapshot = HomeSnapshot(
            randomSongs: repeated,
            serverRecommendedSongs: Array(repeated.reversed())
        )
        let date = Date(timeIntervalSince1970: 1_800_000_000)

        let first = RecommendationMixer.mix(
            snapshot: snapshot,
            weights: weights(),
            limit: 8,
            date: date
        )
        let second = RecommendationMixer.mix(
            snapshot: snapshot,
            weights: weights(),
            limit: 8,
            date: date
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 8)
        XCTAssertEqual(Set(first.map(\.id)).count, first.count)
    }

    private func weights() -> RecommendationWeights {
        let defaults = UserDefaults(
            suiteName: "RecommendationEngineTests.\(UUID().uuidString)"
        )!
        return RecommendationWeights.current(defaults)
    }

    private func song(
        id: String,
        title: String,
        artist: String,
        genre: String? = nil,
        starred: String? = nil
    ) -> Song {
        Song(
            id: id,
            title: title,
            artist: artist,
            album: "Album",
            artistId: "artist-\(artist)",
            albumId: "album-\(artist)",
            coverArt: nil,
            duration: 180,
            track: 1,
            suffix: "m4a",
            contentType: "audio/mp4",
            starred: starred,
            genre: genre
        )
    }
}
