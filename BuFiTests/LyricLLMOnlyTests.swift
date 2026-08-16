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
        XCTAssertEqual(
            signature.sourceTitle,
            String(localized: "이전 로컬 결과 (LLM 재분석 필요)")
        )
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

    func testLLMSourceWithoutStoryIsNotCompletedAnalysis() {
        let signature = LyricSignature(
            songID: "empty",
            lyricsHash: "abc",
            moods: ["calm"],
            themes: [],
            energy: 0.2,
            valence: 0.2,
            embedding: [],
            source: "groq",
            summary: "한국어다"
        )
        XCTAssertFalse(signature.hasStoredSummary)
        XCTAssertFalse(signature.hasStoredLyricAnalysis)
        XCTAssertFalse(
            LyricAnalysisCachePolicy.shouldReuseLyric(
                existing: signature,
                lyricsHash: "abc"
            )
        )
    }

    func testBatchProgressCountsOnlyStoredAnalysesAsSuccess() {
        XCTAssertEqual(
            LyricBatchAccounting.outcome(
                hadLyrics: true,
                reusedCache: false,
                storedAnalysis: false
            ),
            .failed
        )
        XCTAssertEqual(
            LyricBatchAccounting.outcome(
                hadLyrics: true,
                reusedCache: true,
                storedAnalysis: true
            ),
            .cached
        )
        XCTAssertEqual(
            LyricBatchAccounting.outcome(
                hadLyrics: false,
                reusedCache: false,
                storedAnalysis: false
            ),
            .noLyrics
        )
        var progress = LyricBatchProgress.idle
        progress.total = 10
        progress.processed = 10
        progress.analyzed = 2
        progress.cached = 1
        progress.failed = 3
        progress.noLyrics = 4
        XCTAssertEqual(progress.succeeded, 3)
        XCTAssertEqual(progress.fraction, 0.3, accuracy: 0.0001)
        XCTAssertFalse(progress.isComplete)
    }
}
