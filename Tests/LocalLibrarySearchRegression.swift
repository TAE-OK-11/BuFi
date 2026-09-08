import Foundation

@main
struct LocalLibrarySearchRegression {
    static func song(_ id: String, _ title: String) throws -> Song {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id, "title": title, "artist": "Artist", "album": "Album"
        ])
        return try JSONDecoder().decode(Song.self, from: data)
    }

    static func expect(_ actual: [Song], _ expected: [String], _ message: String) {
        precondition(actual.map(\.id) == expected, message)
    }

    @MainActor
    static func main() async throws {
        var snapshot = HomeSnapshot.empty
        snapshot.starredSongs = try [
            song("contains", "A Dreaming Night"),
            song("prefix", "Dreamer"),
            song("exact", "Dream"),
            song("multi", "Beautiful Night"),
            song("accent", "Café"),
            song("korean", "별빛이 내리는 밤")
        ]
        let index = LocalLibrarySearchIndex.build(from: snapshot)
        expect(index.results(for: "dream").songs,
               ["exact", "prefix", "contains"],
               "An exact token must not hide prefix or substring matches")
        expect(index.results(for: "beau nig").songs, ["multi"],
               "Multiword partial queries must remain searchable")
        expect(index.results(for: "night dreaming").songs, ["contains"],
               "Reordered tokens must match within the same field")
        expect(index.results(for: "CAFE").songs, ["accent"],
               "Localized matching must preserve accent/case folding")
        expect(index.results(for: "별빛 내리").songs, ["korean"],
               "Korean partial tokens must remain searchable")
        expect(index.results(for: "dream", songLimit: 2).songs,
               ["exact", "prefix"], "Rank before applying the result limit")
        precondition(index.results(for: "   ").isEmpty)
        precondition(index.results(for: "dream", songLimit: 0).songs.isEmpty)

        // Repeated equal-rank results preserve snapshot order, even when the
        // requested result count is smaller than the number of matches.
        snapshot.starredSongs = try (0..<100).map { try song("id-\($0)", "Same title") }
        let ties = LocalLibrarySearchIndex.build(from: snapshot)
        for _ in 0..<10 {
            expect(ties.results(for: "same title", songLimit: 3).songs,
                   ["id-0", "id-1", "id-2"], "Tie order must be deterministic")
        }
        let prepared = try await LocalLibrarySearch.prepare(
            for: "same", snapshot: snapshot, cachedIndex: ties
        )
        precondition(prepared.results == ties.results(for: "same"))
        let cancelled = Task {
            try await LocalLibrarySearch.prepare(
                for: "same", snapshot: snapshot, cachedIndex: nil
            )
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            preconditionFailure("Cancelled search must not publish a result")
        } catch is CancellationError {}
        print("Local search regression checks passed")
    }
}
