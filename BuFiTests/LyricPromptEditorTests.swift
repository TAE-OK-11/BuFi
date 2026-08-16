import XCTest
@testable import BuFi

final class LyricPromptEditorTests: XCTestCase {
    func testGPTOSSParsesRankedMoodsAndGroundedMeaningFields() {
        let parsed = LyricIntelligencePrompt.parse(
            #"{"primaryMoods":["yearning","obsessive"],"secondaryMoods":["resentful"],"themes":["lost relationship","memory"],"energy":0.42,"valence":0.18,"emotion":0.86,"summary":"The narrator revisits a brief relationship and remains fixated on what was lost. The longing hardens into resentment before ending in unresolved desire for contact.","explicitContent":"The narrator recalls a brief relationship and wants renewed contact.","interpretation":"The repeated time references make the attachment feel emotionally frozen.","emotionalArc":"nostalgia -> fixation -> resentment -> unresolved longing","relationship":"former romantic partners"}"#
        )

        XCTAssertEqual(parsed?.details.primaryMoods, ["yearning", "obsessive"])
        XCTAssertEqual(parsed?.details.secondaryMoods, ["resentful"])
        XCTAssertEqual(parsed?.moods, ["yearning", "obsessive", "resentful"])
        XCTAssertEqual(parsed?.themes, ["lost relationship", "memory"])
        XCTAssertEqual(parsed?.details.relationship, "former romantic partners")
        XCTAssertTrue(parsed?.details.explicitContent.contains("brief relationship") == true)
        XCTAssertTrue(parsed?.details.interpretation.contains("emotionally frozen") == true)
        XCTAssertTrue(parsed?.details.emotionalArc.contains("fixation") == true)
        XCTAssertEqual(parsed?.details.emotionIntensity ?? 0, 0.86, accuracy: 0.001)
    }

    func testGPTOSSPromptSeparatesEvidenceFromInterpretation() {
        let prompt = LyricModelPrompts.lyricAnalysis(
            lyrics: "I remember two weeks with you and still wait by the door",
            family: .gptOSS
        )

        XCTAssertTrue(prompt.contains("primaryMoods"))
        XCTAssertTrue(prompt.contains("secondaryMoods"))
        XCTAssertTrue(prompt.contains("explicitContent"))
        XCTAssertTrue(prompt.contains("interpretation"))
        XCTAssertTrue(prompt.contains("emotionalArc"))
        XCTAssertTrue(prompt.contains("Do not call the narrator the artist"))
        XCTAssertTrue(prompt.contains("Never invent biography, production, instrumentation"))
    }

    func testManualCorrectionKeepsOriginalEngineProvenance() {
        let signature = LyricSignature(
            songID: "manual",
            lyricsHash: "hash",
            moods: ["yearning"],
            themes: ["memory"],
            energy: 0.4,
            valence: 0.2,
            embedding: [],
            source: "manual:groq",
            summary: "The narrator remains attached to a lost relationship."
        )

        XCTAssertTrue(signature.hasStoredLyricAnalysis)
        XCTAssertTrue(signature.sourceTitle.contains("사용자 수정"))
        XCTAssertTrue(signature.sourceTitle.contains("Groq"))
    }

    func testOldDetailProfileJSONStillDecodesWithNewFields() throws {
        let data = #"{"moods":["calm","sad"],"themes":["night"],"energy":0.3,"valence":0.2,"summary":"The narrator waits alone at night."}"#.data(using: .utf8)!
        let details = try JSONDecoder().decode(LyricDetailProfile.self, from: data)

        XCTAssertEqual(details.primaryMoods, ["calm", "sad"])
        XCTAssertTrue(details.secondaryMoods.isEmpty)
        XCTAssertTrue(details.explicitContent.isEmpty)
        XCTAssertTrue(details.interpretation.isEmpty)
        XCTAssertTrue(details.emotionalArc.isEmpty)
        XCTAssertTrue(details.relationship.isEmpty)
    }
}
