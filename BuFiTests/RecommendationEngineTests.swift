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

    func testCacheInvalidatesWhenPreparedRecommendationSourcesChange() {
        RecommendationMixer.invalidateCache()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let firstSong = song(
            id: "prepared-a",
            title: "Prepared A",
            artist: "Artist A"
        )
        let secondSong = song(
            id: "prepared-b",
            title: "Prepared B",
            artist: "Artist B"
        )

        let first = RecommendationMixer.mix(
            snapshot: HomeSnapshot(recommendedSongs: [firstSong]),
            weights: weights(),
            limit: 1,
            date: date
        )
        let second = RecommendationMixer.mix(
            snapshot: HomeSnapshot(recommendedSongs: [secondSong]),
            weights: weights(),
            limit: 1,
            date: date
        )

        XCTAssertEqual(first.map(\.id), [firstSong.id])
        XCTAssertEqual(second.map(\.id), [secondSong.id])
    }

    func testPersonalizedMixesProvideSixDefaultAndFourSelectedArtists() {
        let songs = (0..<12).map { index in
            song(
                id: "artist-track-\(index)",
                title: "Track \(index)",
                artist: "Artist \(index)",
                genre: index.isMultiple(of: 2) ? "Pop" : "Rock"
            )
        }
        let selected = ["Artist 8", "Artist 9", "Artist 10", "Artist 11"]
        let mixes = PersonalizedMixBuilder.make(
            snapshot: HomeSnapshot(randomSongs: songs),
            date: Date(timeIntervalSince1970: 1_800_000_000),
            selectedArtists: selected
        )
        let artistMixes = mixes.filter { $0.kind == .artist }

        XCTAssertEqual(artistMixes.count, 10)
        for artist in selected {
            XCTAssertTrue(artistMixes.contains { $0.title == "\(artist) Mix" })
        }
    }

    func testPersonalizedMixIdentityChangesOnTheNextDay() {
        let songs = (0..<12).map { index in
            song(
                id: "daily-track-\(index)",
                title: "Daily \(index)",
                artist: "Artist \(index % 6)"
            )
        }
        let snapshot = HomeSnapshot(randomSongs: songs)
        let first = PersonalizedMixBuilder.make(
            snapshot: snapshot,
            date: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let nextDay = PersonalizedMixBuilder.make(
            snapshot: snapshot,
            date: Date(timeIntervalSince1970: 1_800_086_400)
        )

        XCTAssertNotEqual(first.map(\.id), nextDay.map(\.id))
    }

    func testPersonalizedMixCacheInvalidatesWithSnapshotContent() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let firstSong = song(
            id: "mix-a",
            title: "Mix A",
            artist: "Artist A"
        )
        let secondSong = song(
            id: "mix-b",
            title: "Mix B",
            artist: "Artist B"
        )

        let first = PersonalizedMixBuilder.make(
            snapshot: HomeSnapshot(randomSongs: [firstSong]),
            date: date,
            songLimit: 1
        )
        let second = PersonalizedMixBuilder.make(
            snapshot: HomeSnapshot(randomSongs: [secondSong]),
            date: date,
            songLimit: 1
        )

        XCTAssertTrue(first.allSatisfy { $0.songs.map(\.id) == [firstSong.id] })
        XCTAssertTrue(second.allSatisfy { $0.songs.map(\.id) == [secondSong.id] })
    }

    func testArtistMixPreferencesDeduplicateAndKeepFourRecentArtists() {
        var encoded = "[]"
        for artist in ["A", "B", "C", "D", "E", "B"] {
            encoded = ArtistMixPreferences.adding(artist, to: encoded)
        }

        XCTAssertEqual(
            ArtistMixPreferences.decode(encoded),
            ["B", "E", "D", "C"]
        )
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
