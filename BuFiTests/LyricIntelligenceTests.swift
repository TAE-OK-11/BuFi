import Foundation
import XCTest
@testable import BuFi

final class LyricIntelligenceTests: XCTestCase {
    func testLexicalEmbeddingIsStableAndFindsSimilarLyrics() {
        let first = LyricLexicalEmbedding.vector(
            from: "I walk alone at midnight under the quiet rain"
        )
        let second = LyricLexicalEmbedding.vector(
            from: "Walking alone at midnight in the quiet rain"
        )
        let other = LyricLexicalEmbedding.vector(
            from: "Jump and dance all night under neon lights"
        )

        XCTAssertEqual(first, LyricLexicalEmbedding.vector(
            from: "I walk alone at midnight under the quiet rain"
        ))
        XCTAssertGreaterThan(
            LyricLexicalEmbedding.cosine(first, second),
            LyricLexicalEmbedding.cosine(first, other)
        )
    }

    func testMoodJSONIsParsedFromNoisyModelOutput() {
        let parsed = LyricIntelligencePrompt.parse(
            """
            Sure.
            {"moods":["calm","sad"],"themes":["night","rain"],"energy":0.2,"valence":0.15}
            """
        )

        XCTAssertEqual(parsed?.moods, ["calm", "sad"])
        XCTAssertEqual(parsed?.themes, ["night", "rain"])
        XCTAssertEqual(parsed?.energy ?? 0, 0.2, accuracy: 0.001)
        XCTAssertEqual(parsed?.valence ?? 0, 0.15, accuracy: 0.001)
    }

    func testLyricAffinityPrefersMatchingMoodEmbeddings() {
        let calm = LyricSignature(
            songID: "calm",
            lyricsHash: "a",
            moods: ["calm"],
            themes: ["night"],
            energy: 0.2,
            valence: 0.2,
            embedding: LyricLexicalEmbedding.merge(
                moods: ["calm"],
                energy: 0.2,
                valence: 0.2,
                lyrics: "quiet night rain"
            ),
            source: "test"
        )
        let similar = LyricSignature(
            songID: "similar",
            lyricsHash: "b",
            moods: ["calm"],
            themes: ["rain"],
            energy: 0.25,
            valence: 0.18,
            embedding: LyricLexicalEmbedding.merge(
                moods: ["calm"],
                energy: 0.25,
                valence: 0.18,
                lyrics: "quiet rain at night"
            ),
            source: "test"
        )
        let different = LyricSignature(
            songID: "party",
            lyricsHash: "c",
            moods: ["happy"],
            themes: ["dance"],
            energy: 0.9,
            valence: 0.9,
            embedding: LyricLexicalEmbedding.merge(
                moods: ["happy"],
                energy: 0.9,
                valence: 0.9,
                lyrics: "dance jump party neon"
            ),
            source: "test"
        )
        let index = LyricSignatureIndex(bySongID: [
            calm.songID: calm,
            similar.songID: similar,
            different.songID: different
        ])

        XCTAssertGreaterThan(
            index.affinity(
                candidateID: similar.songID,
                recentIDs: [calm.songID],
                favoriteIDs: []
            ),
            index.affinity(
                candidateID: different.songID,
                recentIDs: [calm.songID],
                favoriteIDs: []
            )
        )
    }
}
