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

    func testRadioBriefParsesLaneAndFillsFifteenPlusFive() {
        let brief = RadioLLMDirector.parseBrief(
            """
            ```json
            {"moods":["yearning"],"themes":["rain"],"energy":[0.2,0.45],"valence":[0.1,0.4],"vocal":"female","genre":"ballad","sound":["guitar","singing"],"avoid":["euphoric"],"want":"stay in the late night rain lane"}
            ```
            """
        )
        XCTAssertEqual(brief?.moods, ["yearning"])
        XCTAssertEqual(brief?.vocal, "female")
        XCTAssertEqual(brief?.energy.lowerBound ?? -1, 0.2, accuracy: 0.001)
        XCTAssertEqual(brief?.energy.upperBound ?? -1, 0.45, accuracy: 0.001)
        XCTAssertEqual(brief?.sound, ["guitar", "singing"])

        let seed = Song(id: "seed", title: "Seed", artist: "A", album: "L")
        var closeDetails = LyricDetailProfile.empty
        closeDetails.primaryMoods = ["yearning"]
        closeDetails.vocalGender = "female"
        let close = LyricSignature(
            songID: "c1",
            lyricsHash: "h",
            moods: ["yearning"],
            themes: ["rain"],
            energy: 0.3,
            valence: 0.2,
            embedding: [],
            source: "groq",
            soundLabels: ["guitar", "singing"],
            summary: "The narrator waits in the rain.",
            details: closeDetails
        )
        var partyDetails = LyricDetailProfile.empty
        partyDetails.primaryMoods = ["euphoric"]
        let party = LyricSignature(
            songID: "p1",
            lyricsHash: "h",
            moods: ["euphoric"],
            themes: ["dance"],
            energy: 0.9,
            valence: 0.9,
            embedding: [],
            source: "groq",
            soundLabels: ["drums"],
            summary: "Everybody jump.",
            details: partyDetails
        )
        let songs = (0..<30).map { index in
            Song(
                id: index < 18 ? "c\(index)" : "p\(index)",
                title: "T\(index)",
                artist: "Artist \(index % 7)",
                album: "L"
            )
        }
        var signatures: [String: LyricSignature] = [:]
        for song in songs {
            signatures[song.id] = song.id.hasPrefix("c") ? close : party
        }
        let pack = RadioLLMDirector.fillPack(
            brief: brief ?? .open,
            algorithm: songs,
            lyricIndex: LyricSignatureIndex(bySongID: signatures)
        )
        XCTAssertEqual(pack.count, RadioLLMDirector.packSize)
        XCTAssertGreaterThanOrEqual(
            pack.filter { $0.id.hasPrefix("c") }.count,
            12
        )
        XCTAssertEqual(LyricIntelligenceSettings.defaultGroqModel, "openai/gpt-oss-120b")
        XCTAssertEqual(
            LyricIntelligenceSettings.radioFallbackModel,
            "openai/gpt-oss-20b"
        )
        XCTAssertEqual(
            LyricInferenceRuntime.radioTargets(
                LyricIntelligenceSettings(
                    provider: .groq,
                    openAIKey: "",
                    openRouterKey: "",
                    openRouterModel: "",
                    groqKey: "gsk",
                    groqModel: "openai/gpt-oss-120b"
                )
            ).map(\.model),
            [
                LyricIntelligenceSettings.radioPrimaryModel,
                LyricIntelligenceSettings.radioSecondaryModel,
                LyricIntelligenceSettings.radioFallbackModel
            ]
        )
        let radioTargets = LyricInferenceRuntime.radioTargets(
            LyricIntelligenceSettings(
                provider: .groq,
                openAIKey: "",
                openRouterKey: "",
                openRouterModel: "",
                groqKey: "gsk",
                groqModel: "openai/gpt-oss-120b"
            )
        )
        XCTAssertEqual(radioTargets.map(\.model), [
            "openai/gpt-oss-120b",
            "qwen/qwen3.6-27b",
            "openai/gpt-oss-20b"
        ])
        XCTAssertEqual(radioTargets[0].reasoningEffort, "low")
        XCTAssertEqual(radioTargets[1].reasoningEffort, "none")
        XCTAssertEqual(radioTargets[2].reasoningEffort, "low")
        XCTAssertEqual(radioTargets.first?.timeout, 8)
        XCTAssertEqual(radioTargets.first?.allowRetries, false)
        XCTAssertEqual(radioTargets.last?.timeout, 1.4)
        XCTAssertEqual(
            LyricModelFamily.resolve(model: "qwen/qwen3.6-27b"),
            .gptOSS
        )
        let heuristic = RadioLLMDirector.heuristicBrief(
            seed: seed,
            lyricIndex: LyricSignatureIndex(bySongID: ["seed": close])
        )
        XCTAssertEqual(heuristic.moods, ["yearning"])
        XCTAssertEqual(heuristic.vocal, "female")
        let suite = "BuFi.RadioLLM.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("keep it rainy", forKey: LyricIntelligenceSettings.userPromptKey)
        XCTAssertEqual(
            LyricIntelligenceSettings.current(defaults: defaults).userPrompt,
            "keep it rainy"
        )
    }

    func testRadioContinuityKeepsKPopAndMixesGender() {
        let seed = Song(
            id: "seed",
            title: "아이돌",
            artist: "NewJeans",
            album: "Get Up",
            genre: "K-Pop"
        )
        var female = LyricDetailProfile.empty
        female.vocalGender = "female"
        female.genre = "k-pop"
        female.language = "ko"
        var male = LyricDetailProfile.empty
        male.vocalGender = "male"
        male.genre = "k-pop"
        male.language = "ko"
        var western = LyricDetailProfile.empty
        western.vocalGender = "male"
        western.genre = "rock"
        western.language = "en"
        func signature(
            id: String,
            details: LyricDetailProfile,
            energy: Double
        ) -> LyricSignature {
            LyricSignature(
                songID: id,
                lyricsHash: "h",
                moods: ["euphoric"],
                themes: ["dance"],
                energy: energy,
                valence: 0.7,
                embedding: [],
                source: "groq",
                summary: "dance",
                details: details
            )
        }
        let seedSignature = signature(id: "seed", details: female, energy: 0.7)
        XCTAssertTrue(RadioContinuity.isKPop(song: seed, signature: seedSignature))
        XCTAssertEqual(
            RadioContinuity.vocalGender(song: seed, signature: seedSignature),
            "female"
        )

        let hangul = Song(
            id: "h1",
            title: "슈퍼샤이",
            artist: "뉴진스",
            album: "Get Up",
            genre: "Pop"
        )
        XCTAssertTrue(RadioContinuity.isKPop(song: hangul, signature: nil))

        let songs: [Song] = (0..<8).map { index in
            if index < 6 {
                return Song(
                    id: "f\(index)",
                    title: "Girl \(index)",
                    artist: "Idol \(index)",
                    album: "K",
                    genre: "K-Pop"
                )
            }
            return Song(
                id: "m\(index)",
                title: "Boy \(index)",
                artist: "Group \(index)",
                album: "K",
                genre: "K-Pop"
            )
        } + [
            Song(id: "rock", title: "West", artist: "Band", album: "W", genre: "Rock")
        ]
        var signatures: [String: LyricSignature] = ["seed": seedSignature]
        for song in songs {
            if song.id.hasPrefix("f") {
                signatures[song.id] = signature(id: song.id, details: female, energy: 0.7)
            } else if song.id.hasPrefix("m") {
                signatures[song.id] = signature(id: song.id, details: male, energy: 0.7)
            } else {
                signatures[song.id] = signature(id: song.id, details: western, energy: 0.6)
            }
        }
        let index = LyricSignatureIndex(bySongID: signatures)
        let balanced = RadioContinuity.balance(
            songs,
            seed: seed,
            lyricIndex: index,
            limit: 6
        )
        let genders = Set(balanced.map {
            RadioContinuity.vocalGender(song: $0, signature: index.bySongID[$0.id])
        })
        XCTAssertTrue(genders.contains("female"))
        XCTAssertTrue(genders.contains("male"))
        XCTAssertGreaterThan(
            balanced.filter {
                RadioContinuity.isKPop(song: $0, signature: index.bySongID[$0.id])
            }.count,
            balanced.count / 2
        )
        XCTAssertGreaterThan(
            RadioContinuity.laneScore(
                candidate: songs[0],
                seed: seed,
                lyricIndex: index
            ),
            RadioContinuity.laneScore(
                candidate: songs.last!,
                seed: seed,
                lyricIndex: index
            )
        )
    }

    func testAIProfileAppliedDropsListenSignalsWithoutLegacyWeights() {
        var profile = AIRecommendationProfile.unset
        profile.useFrequent = false
        profile.useListenCount = false
        var weights = RecommendationWeights.current(
            UserDefaults(suiteName: "BuFi.AIProfileApplied.\(UUID().uuidString)")!
        )
        weights.history = 1
        weights.behavior = 1
        let applied = profile.applied(to: weights)
        XCTAssertLessThan(applied.history, 0.2)
        XCTAssertLessThan(applied.behavior, 0.1)
    }

    func testAIProfileDefaultsNeedNoSetupAndRespectAvoidedArtists() {
        let profile = AIRecommendationProfile.unset
        XCTAssertTrue(profile.useListenCount)
        XCTAssertTrue(profile.useFavorites)
        XCTAssertTrue(profile.useFrequent)
        XCTAssertTrue(profile.stayOnAlbum)
        XCTAssertTrue(profile.moods.isEmpty)
        XCTAssertEqual(profile.promptAppendix(), "")

        var tuned = profile
        tuned.avoidedArtists = ["Limp Bizkit"]
        tuned.preferredArtists = ["Taylor Swift"]
        tuned.moods = ["yearning", "calm"]
        tuned.pens = ["fountain"]
        tuned.sanitize()
        let taylor = Song(id: "t", title: "Exile", artist: "Taylor Swift", album: "Folklore")
        let limp = Song(id: "l", title: "Break Stuff", artist: "Limp Bizkit", album: "SO")
        XCTAssertGreaterThan(
            tuned.score(song: taylor, signature: nil),
            tuned.score(song: limp, signature: nil)
        )
        XCTAssertLessThan(tuned.score(song: taylor, signature: nil), 0.12)
        XCTAssertGreaterThan(tuned.score(song: taylor, signature: nil), 0)
        XCTAssertTrue(
            tuned.promptAppendix().contains("잔잔한 밤")
                || tuned.promptAppendix().contains("Taylor")
        )
        XCTAssertEqual(TaylorPenStyle.allCases.count, 3)
        XCTAssertEqual(AILyricMood.allCases.count, 10)
    }

    func testLyricToolkitReadsAnalysisAndRejectsUnknownIDs() async {
        let song = Song(id: "c1", title: "Rain", artist: "A", album: "L")
        var details = LyricDetailProfile.empty
        details.primaryMoods = ["yearning"]
        let signature = LyricSignature(
            songID: "c1",
            lyricsHash: "h",
            moods: ["yearning"],
            themes: ["rain"],
            energy: 0.3,
            valence: 0.2,
            embedding: [],
            source: "groq",
            summary: "The narrator waits in the rain.",
            details: details
        )
        let toolkit = LyricModelToolkit(
            songsByID: [song.id: song],
            lyricIndex: LyricSignatureIndex(bySongID: [song.id: signature]),
            seed: song,
            lyricsProvider: { _ in "I wait by the window in the quiet rain tonight" }
        )
        let lyrics = await toolkit.invoke(
            name: "get_lyrics",
            argumentsJSON: #"{"song_id":"c1"}"#
        )
        XCTAssertTrue(lyrics.contains("quiet rain"))
        let missing = await toolkit.invoke(
            name: "get_lyrics",
            argumentsJSON: #"{"song_id":"nope"}"#
        )
        XCTAssertTrue(missing.contains("unknown"))
        let analysis = await toolkit.invoke(
            name: "get_analysis",
            argumentsJSON: #"{"song_id":"c1"}"#
        )
        XCTAssertTrue(analysis.contains("yearning"))
        let reply = LyricJSONExtractor.chatReply(
            from: #"{"choices":[{"message":{"tool_calls":[{"id":"1","function":{"name":"get_lyrics","arguments":"{\"song_id\":\"c1\"}"}}]}}]}"#
        )
        if case .tools(let calls) = reply {
            XCTAssertEqual(calls.first?.name, "get_lyrics")
        } else {
            XCTFail("expected tool call")
        }
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
        let geminiSettings = LyricIntelligenceSettings(
            provider: .googleAI,
            openAIKey: "",
            openRouterKey: "",
            openRouterModel: "",
            geminiKey: "ai-studio",
            geminiModel: LyricIntelligenceSettings.geminiFlashLiteModel
        )
        XCTAssertEqual(
            LyricInferenceRuntime.primaryTarget(geminiSettings)?.model,
            "gemini-3.6-flash-lite"
        )
        XCTAssertEqual(
            LyricInferenceRuntime.primaryTarget(geminiSettings)?.source,
            "google-ai"
        )
        XCTAssertEqual(
            LyricInferenceRuntime.primaryTarget(settings)?.source,
            "groq"
        )
        XCTAssertTrue(
            LyricModelFamily.resolve(model: settings.openRouterModel) == .gptOSS
        )
    }

    func testAsyncDeadlineReturnsFastValueAndTimesOut() async {
        let immediate = await AsyncDeadline.first(seconds: 1) {
            "ready"
        }
        XCTAssertEqual(immediate, "ready")
        let missed = await AsyncDeadline.first(seconds: 0.05) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            return "late"
        }
        XCTAssertNil(missed)
        XCTAssertEqual(RadioLLMDirector.streamWaitDeadline, 1.5, accuracy: 0.01)
        XCTAssertEqual(RadioLLMDirector.firstPickDeadline, 3.0, accuracy: 0.01)
        XCTAssertEqual(RadioLLMDirector.mixerLimit, 30)
        XCTAssertEqual(RadioLLMDirector.reviewKeep, 15)
        XCTAssertEqual(RadioLLMDirector.packSize, 30)
    }

    func testRadioIDStreamYieldsIdsAsTextArrives() {
        var already = Set<String>()
        let allowed: Set<String> = ["a1", "b2", "c3", "d4"]
        let first = RadioIDStream.newIDs(
            in: #"{"ids":["a1","b"#,
            allowed: allowed,
            already: already
        )
        XCTAssertEqual(first, ["a1"])
        already.formUnion(first)
        let second = RadioIDStream.newIDs(
            in: #"{"ids":["a1","b2","c3"]}"#,
            allowed: allowed,
            already: already
        )
        XCTAssertEqual(second, ["b2", "c3"])
    }

    func testSoundFeatureExtractorFindsPulseBPM() {
        var envelope = [Float](repeating: 0.04, count: 400)
        for index in stride(from: 0, to: 400, by: 50) {
            envelope[index] = 1
            if index + 1 < 400 { envelope[index + 1] = 0.55 }
        }
        let features = SoundFeatureExtractor.measure(
            envelope: envelope,
            hopSeconds: 0.01,
            brightness: 0.4
        )
        XCTAssertEqual(features.bpm, 120)
        XCTAssertGreaterThan(features.pulse, 0.15)
        XCTAssertTrue(features.isMeasured)
        let seed = Song(id: "s", title: "S", artist: "A", album: "L", bpm: 122)
        var details = LyricDetailProfile.empty
        details.audioBPM = 118
        details.audioMeasured = true
        let signature = LyricSignature(
            songID: "c",
            lyricsHash: "h",
            moods: [],
            themes: [],
            energy: 0.5,
            valence: 0.5,
            embedding: [],
            source: "groq",
            details: details
        )
        XCTAssertEqual(
            SoundFeatureExtractor.bpm(song: seed, signature: signature),
            122
        )
        XCTAssertEqual(
            SoundFeatureExtractor.bpm(
                song: Song(id: "c", title: "C", artist: "A", album: "L"),
                signature: signature
            ),
            118
        )
        XCTAssertGreaterThan(
            SoundFeatureExtractor.closeness(left: 120, right: 124),
            SoundFeatureExtractor.closeness(left: 120, right: 160)
        )
    }
}
