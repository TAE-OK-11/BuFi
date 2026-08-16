import XCTest
@testable import BuFi

final class LyricLLMOnlyTests: XCTestCase {
    func testLegacyLexicalResultIsNeverReusableAsCompletedAnalysis() {
        let signature = LyricSignature(
            songID: "legacy",
            lyricsHash: "abc",
            moods: ["sad"],
            themes: [],
            energy: 0.5,
            valence: 0.5,
            embedding: [],
            source: "lexical",
            summary: "copied lyric line that looks like a summary"
        )

        XCTAssertFalse(signature.hasStoredLyricAnalysis)
        XCTAssertFalse(
            LyricAnalysisCachePolicy.shouldReuseLyric(
                existing: signature,
                lyricsHash: "abc"
            )
        )
    }

    func testIncompleteResultWithoutLLMSourceStaysPending() {
        let signature = LyricSignature(
            songID: "pending",
            lyricsHash: "abc",
            moods: [],
            themes: [],
            energy: 0.5,
            valence: 0.5,
            embedding: [],
            source: ""
        )

        XCTAssertFalse(signature.hasStoredLyricAnalysis)
        XCTAssertFalse(
            LyricAnalysisCachePolicy.shouldReuseLyric(
                existing: signature,
                lyricsHash: "abc"
            )
        )
    }

    func testActualLLMResultRemainsReusable() {
        let signature = LyricSignature(
            songID: "llm",
            lyricsHash: "abc",
            moods: ["yearning"],
            themes: ["memory"],
            energy: 0.4,
            valence: 0.3,
            embedding: [],
            source: "apple-intelligence-3b",
            summary: "The narrator revisits a lost relationship and accepts that it is gone."
        )

        XCTAssertTrue(signature.hasStoredLyricAnalysis)
        XCTAssertTrue(
            LyricAnalysisCachePolicy.shouldReuseLyric(
                existing: signature,
                lyricsHash: "abc"
            )
        )
    }
}
