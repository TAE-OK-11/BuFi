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

    func testTaggingJSONCanOmitEnergy() {
        let parsed = LyricIntelligencePrompt.parse(
            #"{"moods":["calm"],"themes":["night"]}"#
        )
        XCTAssertEqual(parsed?.moods, ["calm"])
        XCTAssertEqual(parsed?.energy ?? -1, 0.5, accuracy: 0.001)
    }

    func testScaleJSONCanOmitMoods() {
        let parsed = LyricIntelligencePrompt.parse(
            #"{"energy":0.8,"valence":0.1}"#
        )
        XCTAssertEqual(parsed?.moods, [])
        XCTAssertEqual(parsed?.energy ?? 0, 0.8, accuracy: 0.001)
        XCTAssertEqual(parsed?.valence ?? 0, 0.1, accuracy: 0.001)
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

    func testApplePrivateCloudIsAnOptInProvider() {
        XCTAssertEqual(
            LyricIntelligenceProviderKind.applePrivateCloud.rawValue,
            "applePrivateCloud"
        )
        XCTAssertEqual(
            LyricIntelligenceProviderKind(rawValue: "applePrivateCloud"),
            .applePrivateCloud
        )
        let suite = "BuFi.LyricIntelligenceTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(
            LyricIntelligenceSettings.current(defaults: defaults).provider,
            .onDevice
        )
        defaults.set(
            LyricIntelligenceProviderKind.applePrivateCloud.rawValue,
            forKey: LyricIntelligenceSettings.providerKey
        )
        XCTAssertEqual(
            LyricIntelligenceSettings.current(defaults: defaults).provider,
            .applePrivateCloud
        )
    }

    func testLegacyLyricSignatureJSONStillDecodes() throws {
        let json = """
        {"songID":"one","lyricsHash":"abc","moods":["calm"],"themes":["night"],\
        "energy":0.2,"valence":0.3,"embedding":[0.1,0.2],"source":"lexical"}
        """.data(using: .utf8)!
        let signature = try JSONDecoder().decode(LyricSignature.self, from: json)
        XCTAssertEqual(signature.songID, "one")
        XCTAssertEqual(signature.moods, ["calm"])
        XCTAssertTrue(signature.sentenceEmbedding.isEmpty)
        XCTAssertTrue(signature.soundLabels.isEmpty)
        XCTAssertTrue(signature.hasStoredLyricAnalysis)
        XCTAssertFalse(signature.hasStoredSoundAnalysis)
    }

    func testSoundEmbeddingIsStableAndUsesLabels() {
        let first = SoundAnalysisClassifier.embedding(from: [
            "singing": 0.91,
            "music": 0.74
        ])
        let second = SoundAnalysisClassifier.embedding(from: [
            "singing": 0.91,
            "music": 0.74
        ])
        let other = SoundAnalysisClassifier.embedding(from: [
            "speech": 0.88,
            "silence": 0.40
        ])
        XCTAssertEqual(first, second)
        XCTAssertGreaterThan(
            LyricLexicalEmbedding.cosine(first, second),
            LyricLexicalEmbedding.cosine(first, other)
        )
        XCTAssertEqual(
            SoundAnalysisClassifier.topLabels(from: [
                "singing": 0.91,
                "music": 0.74,
                "noise": 0.05
            ]),
            ["singing", "music"]
        )
    }

    func testSimilarityUsesSentenceAndSoundEmbeddingsWhenPresent() {
        let seed = LyricSignature(
            songID: "seed",
            lyricsHash: "a",
            moods: ["calm"],
            themes: ["night"],
            energy: 0.2,
            valence: 0.2,
            embedding: LyricLexicalEmbedding.vector(from: "quiet night"),
            source: "test",
            sentenceEmbedding: [1, 0, 0, 0, 0, 0, 0, 0],
            soundLabels: ["singing"],
            soundEmbedding: [1, 0, 0, 0, 0, 0, 0, 0],
            audioRevision: "rev",
            soundSource: "coreml-sound-analysis"
        )
        let close = LyricSignature(
            songID: "close",
            lyricsHash: "b",
            moods: ["calm"],
            themes: ["night"],
            energy: 0.21,
            valence: 0.19,
            embedding: LyricLexicalEmbedding.vector(from: "quiet night rain"),
            source: "test",
            sentenceEmbedding: [0.96, 0.2, 0, 0, 0, 0, 0, 0],
            soundLabels: ["singing"],
            soundEmbedding: [0.95, 0.1, 0, 0, 0, 0, 0, 0],
            audioRevision: "rev",
            soundSource: "coreml-sound-analysis"
        )
        let far = LyricSignature(
            songID: "far",
            lyricsHash: "c",
            moods: ["happy"],
            themes: ["dance"],
            energy: 0.9,
            valence: 0.9,
            embedding: LyricLexicalEmbedding.vector(from: "dance party"),
            source: "test",
            sentenceEmbedding: [0, 1, 0, 0, 0, 0, 0, 0],
            soundLabels: ["speech"],
            soundEmbedding: [0, 1, 0, 0, 0, 0, 0, 0],
            audioRevision: "rev",
            soundSource: "coreml-sound-analysis"
        )
        XCTAssertGreaterThan(
            LyricLexicalEmbedding.similarity(seed, close),
            LyricLexicalEmbedding.similarity(seed, far)
        )
    }

    func testBackendOffDoesNotCallAModel() async {
        let settings = LyricIntelligenceSettings(
            provider: .off,
            openAIKey: "sk",
            openRouterKey: "or",
            openRouterModel: "google/gemma-3-270m-it"
        )
        let result = await LyricIntelligenceBackend.analyze(
            lyrics: "I walk alone at midnight under the quiet rain tonight",
            settings: settings
        )
        XCTAssertNil(result)
    }
}
