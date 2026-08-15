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

    func testDetailProfileParsesSeasonAndDayparts() {
        let parsed = LyricIntelligencePrompt.parse(
            """
            {"moods":["calm"],"themes":["night"],"energy":0.2,"valence":0.1,\
            "summary":"Quiet streets.\\nRain keeps falling.","season":"autumn",\
            "dayparts":["evening","night"],"style":"ballad","content":"loneliness",\
            "setting":"city","tempo":0.2,"intimacy":0.8,"narrative":"confession",\
            "weather":"rain","social":"alone","color":"blue","vocal":"soft",\
            "language":"en","emotion":0.7,"context":"sleep"}
            """
        )
        XCTAssertEqual(parsed?.details.season, "autumn")
        XCTAssertEqual(parsed?.details.dayparts, ["evening", "night"])
        XCTAssertEqual(parsed?.details.listenContext, "sleep")
        XCTAssertGreaterThan(parsed?.details.matches(hour: 22, month: 10) ?? 0, 0.8)
        XCTAssertTrue(parsed?.details.hasExtendedFields ?? false)
    }

    func testMoodJSONIncludesTwoLineSummary() {
        let parsed = LyricIntelligencePrompt.parse(
            """
            {"moods":["calm"],"themes":["night"],"energy":0.2,"valence":0.1,"summary":"Walking alone after midnight.\\nThe rain keeps your name."}
            """
        )
        XCTAssertEqual(parsed?.summary, "Walking alone after midnight.\nThe rain keeps your name.")
        XCTAssertEqual(
            LyricIntelligencePrompt.normalizedSummary("one\n\ntwo\nthree"),
            "one\ntwo"
        )
    }

    func testReviewKeepsOnlyAllowedIDsAndFillsTheRest() {
        let order = RecommendationLLMReview.parseIDs(
            #"{"ids":["b","missing","a","b"]}"#,
            allowed: ["a", "b", "c"]
        )
        XCTAssertEqual(order, ["b", "a"])
        let songs = [
            Song(id: "a", title: "A", artist: "X", album: "L"),
            Song(id: "b", title: "B", artist: "Y", album: "L"),
            Song(id: "c", title: "C", artist: "Z", album: "L")
        ]
        XCTAssertEqual(
            RecommendationLLMReview.parseIDs(
                #"["c","a"]"#,
                allowed: Set(songs.map(\.id))
            ),
            ["c", "a"]
        )
        XCTAssertNil(
            RecommendationLLMReview.parseIDs(
                #"{"ids":["nope"]}"#,
                allowed: ["a"]
            )
        )
    }

    func testUnifiedEmbeddingUsesSummaryAndSoundTogether() {
        let left = LyricSignature(
            songID: "left",
            lyricsHash: "a",
            moods: ["calm"],
            themes: ["night"],
            energy: 0.2,
            valence: 0.2,
            embedding: LyricLexicalEmbedding.vector(from: "quiet night rain"),
            source: "test",
            sentenceEmbedding: [1, 0, 0, 0, 0, 0, 0, 0],
            soundLabels: ["singing"],
            soundEmbedding: [1, 0, 0, 0, 0, 0, 0, 0],
            audioRevision: "r",
            soundSource: "coreml-sound-analysis",
            summary: "Alone in the rain.\nThe city is quiet."
        )
        let close = LyricSignature(
            songID: "close",
            lyricsHash: "b",
            moods: ["calm"],
            themes: ["rain"],
            energy: 0.22,
            valence: 0.18,
            embedding: LyricLexicalEmbedding.vector(from: "quiet rain"),
            source: "test",
            sentenceEmbedding: [0.9, 0.1, 0, 0, 0, 0, 0, 0],
            soundLabels: ["singing"],
            soundEmbedding: [0.9, 0.1, 0, 0, 0, 0, 0, 0],
            audioRevision: "r",
            soundSource: "coreml-sound-analysis",
            summary: "Walking through rain.\nThe streets stay quiet."
        )
        let far = LyricSignature(
            songID: "far",
            lyricsHash: "c",
            moods: ["happy"],
            themes: ["dance"],
            energy: 0.9,
            valence: 0.9,
            embedding: LyricLexicalEmbedding.vector(from: "dance party neon"),
            source: "test",
            sentenceEmbedding: [0, 1, 0, 0, 0, 0, 0, 0],
            soundLabels: ["speech"],
            soundEmbedding: [0, 1, 0, 0, 0, 0, 0, 0],
            audioRevision: "r",
            soundSource: "coreml-sound-analysis",
            summary: "Everybody jump.\nThe club is loud."
        )
        XCTAssertGreaterThan(
            LyricLexicalEmbedding.similarity(left, close),
            LyricLexicalEmbedding.similarity(left, far)
        )
        XCTAssertFalse(LyricLexicalEmbedding.unified(left).isEmpty)
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

    func testPrivateCloudFallsBackToLocal3BWhenUnavailable() {
        XCTAssertTrue(ApplePrivateCloudStatus.needsIOS27.usesLocal3BFallback)
        XCTAssertTrue(ApplePrivateCloudStatus.deviceNotEligible.usesLocal3BFallback)
        XCTAssertTrue(ApplePrivateCloudStatus.systemNotReady.usesLocal3BFallback)
        XCTAssertTrue(ApplePrivateCloudStatus.quotaReached.usesLocal3BFallback)
        XCTAssertTrue(ApplePrivateCloudStatus.unavailable.usesLocal3BFallback)
        XCTAssertFalse(ApplePrivateCloudStatus.available.usesLocal3BFallback)
        XCTAssertEqual(
            LyricSignature(
                songID: "one",
                lyricsHash: "h",
                moods: ["calm"],
                themes: [],
                energy: 0.2,
                valence: 0.2,
                embedding: [],
                source: "apple-intelligence-3b"
            ).sourceTitle,
            String(localized: "Apple Intelligence 3B (로컬)")
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
        XCTAssertFalse(
            LyricIntelligenceProviderKind.applePrivateCloud.isVisibleInSettings
        )
        XCTAssertEqual(
            LyricIntelligenceSettings.current(defaults: defaults).provider,
            .onDevice
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
                "noise": 0.05,
                "hum": 0.04
            ]),
            ["singing", "music", "noise"]
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

    func testCoverageSeparatesAnalyzedAndPendingSongs() {
        let done = Song(id: "done", title: "Done", artist: "A", album: "X")
        let pending = Song(id: "wait", title: "Wait", artist: "B", album: "Y")
        let radio = Song(
            id: "radio",
            title: "Radio",
            artist: "C",
            album: "Z",
            externalStreamURL: "https://example.test/stream"
        )
        let probe = Song(
            id: LyricIntelligence.probeSongID,
            title: "Probe",
            artist: "BuFi",
            album: "Probe"
        )
        let report = LyricAnalysisCoverage.make(
            catalog: [done, pending, radio, probe, done],
            signatures: [
                "done": LyricSignature(
                    songID: "done",
                    lyricsHash: "hash",
                    moods: ["calm"],
                    themes: ["night"],
                    energy: 0.2,
                    valence: 0.3,
                    embedding: [0.1],
                    source: "apple-intelligence",
                    soundLabels: ["singing"],
                    soundEmbedding: [0.2],
                    audioRevision: "rev",
                    soundSource: "coreml-sound-analysis"
                )
            ]
        )
        XCTAssertEqual(report.known, 2)
        XCTAssertEqual(report.lyricDone, 1)
        XCTAssertEqual(report.soundDone, 1)
        XCTAssertEqual(report.done.map(\.song.id), ["done"])
        XCTAssertEqual(report.pending.map(\.song.id), ["wait"])
        XCTAssertTrue(report.needsSound.isEmpty)
        XCTAssertEqual(report.workQueue.map(\.id), ["wait"])

        let lyricOnly = LyricAnalysisCoverage.make(
            catalog: [done],
            signatures: [
                "done": LyricSignature(
                    songID: "done",
                    lyricsHash: "hash",
                    moods: ["calm"],
                    themes: [],
                    energy: 0.2,
                    valence: 0.3,
                    embedding: [0.1],
                    source: "apple-intelligence-3b"
                )
            ]
        )
        XCTAssertEqual(lyricOnly.needsSound.map(\.song.id), ["done"])
        XCTAssertEqual(lyricOnly.workQueue.map(\.id), ["done"])
        XCTAssertEqual(report.done.first?.sourceTitle, "Apple Intelligence")
        XCTAssertTrue(report.done.first?.hasSound ?? false)
    }

    func testHomeSnapshotKnownSongsDeduplicatesCollections() {
        var snapshot = HomeSnapshot()
        let shared = Song(id: "one", title: "One", artist: "A", album: "X")
        snapshot.starredSongs = [shared]
        snapshot.randomSongs = [shared]
        snapshot.mostPlayedSongs = [
            Song(id: "two", title: "Two", artist: "B", album: "Y")
        ]
        XCTAssertEqual(snapshot.knownSongs().map(\.id), ["one", "two"])
    }

    func testCachePolicyReusesMatchingLyricAndSoundOnly() {
        let stored = LyricSignature(
            songID: "one",
            lyricsHash: "lyrics-a",
            moods: ["calm"],
            themes: ["night"],
            energy: 0.2,
            valence: 0.3,
            embedding: [0.1],
            source: "apple-intelligence",
            sentenceEmbedding: [0.2],
            soundLabels: ["singing"],
            soundEmbedding: [0.4],
            audioRevision: "audio-a",
            soundSource: "coreml-sound-analysis"
        )
        XCTAssertTrue(
            LyricAnalysisCachePolicy.shouldReuseLyric(
                existing: stored,
                lyricsHash: "lyrics-a"
            )
        )
        XCTAssertFalse(
            LyricAnalysisCachePolicy.shouldReuseLyric(
                existing: stored,
                lyricsHash: "lyrics-b"
            )
        )
        XCTAssertTrue(
            LyricAnalysisCachePolicy.shouldReuseSound(
                existing: stored,
                audioRevision: "audio-a"
            )
        )
        XCTAssertFalse(
            LyricAnalysisCachePolicy.shouldReuseSound(
                existing: stored,
                audioRevision: "audio-b"
            )
        )
        XCTAssertEqual(stored.sourceTitle, "Apple Intelligence")
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
