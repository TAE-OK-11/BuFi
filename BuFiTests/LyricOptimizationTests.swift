import XCTest
@testable import BuFi

final class LyricOptimizationTests: XCTestCase {
    func testLongLyricSamplingKeepsBeginningMiddleAndEnding() {
        let beginning = "BEGIN-UNIQUE " + String(repeating: "a", count: 900)
        let middle = String(repeating: "b", count: 420)
            + " MIDDLE-UNIQUE "
            + String(repeating: "b", count: 420)
        let ending = String(repeating: "c", count: 900) + " END-UNIQUE"

        let sampled = LyricTextSampler.sample(
            beginning + middle + ending,
            limit: 1_000
        )

        XCTAssertLessThanOrEqual(sampled.count, 1_000)
        XCTAssertTrue(sampled.contains("BEGIN-UNIQUE"))
        XCTAssertTrue(sampled.contains("MIDDLE-UNIQUE"))
        XCTAssertTrue(sampled.contains("END-UNIQUE"))
    }

    func testShortLyricsRemainIntactAfterNormalization() {
        let lyrics = "첫 줄  \r\n\r\n  둘째 줄\r\n"
        XCTAssertEqual(
            LyricTextSampler.sample(lyrics, limit: 1_000),
            "첫 줄\n\n둘째 줄"
        )
    }

    func testApplePromptForbidsInventedAudioFacts() {
        let prompt = LyricModelPrompts.lyricAnalysis(
            lyrics: "밤새 창가에서 네 이름을 부른다",
            family: .appleFoundation
        )
        XCTAssertTrue(prompt.contains("Do not invent audio facts"))
        XCTAssertTrue(prompt.contains("vocalGender"))
        XCTAssertTrue(prompt.contains("lyrical intensity"))
    }

    func testApplePromptBudgetIsSmallerThanRemoteHeavyModels() {
        XCTAssertLessThan(
            LyricModelFamily.appleFoundation.lyricCharacterLimit,
            LyricModelFamily.llama70B.lyricCharacterLimit
        )
        XCTAssertLessThan(
            LyricModelFamily.llama70B.lyricCharacterLimit,
            LyricModelFamily.gptOSS.lyricCharacterLimit
        )
    }
}
