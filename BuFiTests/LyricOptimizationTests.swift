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

    func testRepeatedChorusLinesAreKeptInTheSample() {
        let verse = String(repeating: "verse line about waiting by the window. ", count: 40)
        let chorus = "Call my name across the rain tonight"
        let lyrics = """
        \(verse)
        \(chorus)
        \(verse)
        \(chorus)
        \(String(repeating: "ending line about leaving town now. ", count: 30))
        """
        let sampled = LyricTextSampler.sample(lyrics, limit: 1_200)
        XCTAssertTrue(sampled.contains(chorus))
        XCTAssertTrue(sampled.contains("[chorus]"))
        XCTAssertEqual(
            LyricTextSampler.repeatedLines(in: lyrics),
            [chorus]
        )
    }

    func testLlamaPromptAsksForRankedMoodsAndEmotionalArc() {
        let prompt = LyricModelPrompts.lyricAnalysis(
            lyrics: "I still wait by the door after two weeks with you",
            family: .llama70B
        )
        XCTAssertTrue(prompt.contains("primaryMoods"))
        XCTAssertTrue(prompt.contains("emotionalArc"))
        XCTAssertTrue(prompt.contains("interpretation"))
    }

    func testJSONExtractorReadsFencedAndMultipartChat() {
        let fenced = """
        Sure.
        ```json
        {"ids":["b","a"],"summary":"Walking home in the rain."}
        ```
        """
        XCTAssertEqual(
            LyricJSONExtractor.object(from: fenced),
            #"{"ids":["b","a"],"summary":"Walking home in the rain."}"#
        )
        let chat = """
        {"choices":[{"message":{"content":[{"type":"text","text":"{\\"ids\\":[\\"a\\"]}"}]}}]}
        """
        XCTAssertEqual(
            LyricJSONExtractor.chatContent(from: chat),
            #"{"ids":["a"]}"#
        )
        XCTAssertEqual(
            RecommendationLLMReview.parseIDs(fenced, allowed: ["a", "b"]),
            ["b", "a"]
        )
    }

    func testProviderCircuitOpensAfterRepeatedFailures() {
        LyricProviderCircuit.resetForTests()
        let key = "test-circuit"
        XCTAssertFalse(LyricProviderCircuit.isOpen(key))
        LyricProviderCircuit.recordFailure(key, now: Date(timeIntervalSince1970: 1))
        XCTAssertFalse(LyricProviderCircuit.isOpen(key, now: Date(timeIntervalSince1970: 2)))
        LyricProviderCircuit.recordFailure(key, now: Date(timeIntervalSince1970: 3))
        XCTAssertTrue(LyricProviderCircuit.isOpen(key, now: Date(timeIntervalSince1970: 4)))
        XCTAssertFalse(LyricProviderCircuit.isOpen(key, now: Date(timeIntervalSince1970: 50)))
        LyricProviderCircuit.recordFailure(key, now: Date(timeIntervalSince1970: 51))
        XCTAssertFalse(LyricProviderCircuit.isOpen(key, now: Date(timeIntervalSince1970: 52)))
        LyricProviderCircuit.recordSuccess(key)
        XCTAssertFalse(LyricProviderCircuit.isOpen(key, now: Date(timeIntervalSince1970: 53)))
    }

    func testOrderBlendKeepsStrongLLMHeadButCanPromoteLaneMatches() {
        let songs = [
            Song(id: "a", title: "A", artist: "X", album: "L"),
            Song(id: "b", title: "B", artist: "Y", album: "L"),
            Song(id: "c", title: "C", artist: "Z", album: "L")
        ]
        let blended = LyricOrderBlend.combine(
            llmOrder: ["a", "b", "c"],
            songs: songs,
            laneScores: ["a": 0.1, "b": 1.0, "c": 0.2]
        )
        XCTAssertEqual(blended.first, "a")
        XCTAssertEqual(blended[1], "b")
        let local = LyricOrderBlend.combine(
            llmOrder: [],
            songs: songs,
            laneScores: ["a": 0.2, "b": 0.9, "c": 0.4]
        )
        XCTAssertEqual(local.first, "b")
    }

    func testSimilarityUsesPrimaryMoodAndVocalLane() {
        func signature(
            id: String,
            moods: [String],
            primary: [String],
            vocal: String,
            energy: Double
        ) -> LyricSignature {
            var details = LyricDetailProfile.empty
            details.primaryMoods = primary
            details.vocalGender = vocal
            details.tempo = energy
            details.intimacy = 0.7
            return LyricSignature(
                songID: id,
                lyricsHash: id,
                moods: moods,
                themes: ["memory"],
                energy: energy,
                valence: 0.3,
                embedding: LyricLexicalEmbedding.vector(from: "quiet night rain memory"),
                source: "groq",
                summary: "The narrator waits through the rain and keeps a lost name.",
                details: details
            )
        }
        let seed = signature(
            id: "seed",
            moods: ["yearning"],
            primary: ["yearning"],
            vocal: "female",
            energy: 0.3
        )
        let close = signature(
            id: "close",
            moods: ["yearning"],
            primary: ["yearning"],
            vocal: "female",
            energy: 0.32
        )
        let far = signature(
            id: "far",
            moods: ["euphoric"],
            primary: ["euphoric"],
            vocal: "male",
            energy: 0.9
        )
        XCTAssertGreaterThan(
            LyricLexicalEmbedding.similarity(seed, close),
            LyricLexicalEmbedding.similarity(seed, far)
        )
        let index = LyricSignatureIndex(bySongID: [
            seed.songID: seed,
            close.songID: close,
            far.songID: far
        ])
        XCTAssertEqual(
            index.similarity(between: seed.songID, and: close.songID),
            LyricLexicalEmbedding.similarity(seed, close),
            accuracy: 0.0001
        )
        XCTAssertGreaterThan(
            index.affinity(
                candidateID: close.songID,
                recentIDs: [seed.songID],
                favoriteIDs: []
            ),
            index.affinity(
                candidateID: far.songID,
                recentIDs: [seed.songID],
                favoriteIDs: []
            )
        )
        let maleTwin = signature(
            id: "male",
            moods: ["yearning"],
            primary: ["yearning"],
            vocal: "male",
            energy: 0.3
        )
        XCTAssertGreaterThan(
            LyricLexicalEmbedding.similarity(seed, close),
            LyricLexicalEmbedding.similarity(seed, maleTwin)
        )
    }

    func testReviewMergeKeepsUnreviewedTailInOriginalOrder() {
        let songs = (0..<6).map { index in
            Song(id: "s\(index)", title: "T\(index)", artist: "A", album: "L")
        }
        let merged = RecommendationLLMReview.merged(
            order: ["s1", "s0"],
            songs: songs,
            limit: 6,
            laneScores: ["s0": 0.2, "s1": 0.9]
        )
        XCTAssertEqual(merged.map(\.id), ["s1", "s0", "s2", "s3", "s4", "s5"])
    }

    func testEmbeddingParserAcceptsIntegerComponents() {
        XCTAssertEqual(
            LyricInferenceRuntime.floatVector([1, 0, 0, 1]),
            [1, 0, 0, 1]
        )
        XCTAssertNil(LyricInferenceRuntime.floatVector([Double]()))
        XCTAssertNil(LyricInferenceRuntime.floatVector(["bad", 1]))
    }

    func testHierarchicalSoundLabelsCollapseToInstrumentLane() {
        XCTAssertEqual(
            SoundLabelSpace.canonicalize([
                "music",
                "music > musical instrument",
                "music > musical instrument > guitar",
                "music > musical instrument > guitar > electric guitar"
            ]),
            ["guitar"]
        )
        XCTAssertEqual(
            SoundLabelSpace.canonicalize([
                "music.musical_instrument.guitar",
                "singing",
                "silence",
                "hum"
            ]),
            ["guitar", "singing"]
        )
        XCTAssertGreaterThan(
            SoundLabelSpace.overlap(
                ["music > musical instrument > guitar"],
                ["electric guitar", "music"]
            ),
            SoundLabelSpace.overlap(
                ["music > musical instrument > guitar"],
                ["speech", "silence"]
            )
        )
        let guitar = SoundAnalysisClassifier.embedding(from: [
            "music > musical instrument > guitar": 0.9
        ])
        let electric = SoundAnalysisClassifier.embedding(from: [
            "electric guitar": 0.88,
            "music": 0.4
        ])
        let speech = SoundAnalysisClassifier.embedding(from: [
            "speech": 0.9,
            "silence": 0.5
        ])
        XCTAssertGreaterThan(
            LyricLexicalEmbedding.cosine(guitar, electric),
            LyricLexicalEmbedding.cosine(guitar, speech)
        )
    }

    func testFallbackTargetsSkipThePrimaryProvider() {
        let settings = LyricIntelligenceSettings(
            provider: .groq,
            openAIKey: "sk",
            openRouterKey: "or",
            openRouterModel: "openai/gpt-oss-120b",
            groqKey: "gsk",
            cerebrasKey: "csk"
        )
        let targets = LyricInferenceRuntime.fallbackTargets(settings, excluding: .groq)
        XCTAssertEqual(targets.map(\.source), ["cerebras", "openrouter", "openai"])
        XCTAssertEqual(
            LyricInferenceRuntime.primaryTarget(settings)?.source,
            "groq"
        )
        XCTAssertTrue(
            LyricModelFamily.resolve(model: settings.openRouterModel) == .gptOSS
        )
    }
}
