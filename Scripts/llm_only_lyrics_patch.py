from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected 1 match, got {count}")
    return text.replace(old, new, 1)


path = Path("BuFi/Core/LyricIntelligence.swift")
text = path.read_text()

text = replace_once(
    text,
    '''    var hasStoredLyricAnalysis: Bool {\n        !lyricsHash.isEmpty && !source.isEmpty\n    }''',
    '''    var hasStoredLyricAnalysis: Bool {\n        // Lexical/heuristic output is not a completed lyric analysis. Only an\n        // actual language-model result may satisfy the cache and coverage layer.\n        !lyricsHash.isEmpty && !source.isEmpty && source != "lexical"\n    }''',
    "LLM-only cache policy",
)

text = replace_once(
    text,
    '''        case "lexical":\n            String(localized: "로컬 어휘 (모델 없음)")''',
    '''        case "lexical":\n            String(localized: "이전 로컬 결과 (LLM 재분석 필요)")''',
    "legacy lexical title",
)

text = replace_once(
    text,
    '''        let reused = LyricAnalysisCachePolicy.shouldReuseLyric(\n            existing: signatures[song.id],\n            lyricsHash: hash\n        )\n        await analyze(song: song, lyrics: lyrics, hash: hash)\n        return LyricIntelligenceProbe(\n            reusedCache: reused,\n            signature: signatures[song.id],''',
    '''        // A probe is a real engine test, not a cache test. Remove the in-memory\n        // probe result first and force a fresh LLM request every time.\n        signatures.removeValue(forKey: song.id)\n        await analyze(song: song, lyrics: lyrics, hash: hash, force: true)\n        let fresh = signatures[song.id]\n        return LyricIntelligenceProbe(\n            reusedCache: false,\n            signature: fresh?.hasStoredLyricAnalysis == true ? fresh : nil,''',
    "fresh LLM probe",
)

old_analyze = '''        var signature = signatures[song.id] ?? LyricSignature(\n            songID: song.id,\n            lyricsHash: hash,\n            moods: [],\n            themes: [],\n            energy: 0.5,\n            valence: 0.5,\n            embedding: [],\n            source: "lexical"\n        )\n        signature.lyricsHash = hash\n        signature.embedding = LyricLexicalEmbedding.merge(\n            moods: signature.moods,\n            energy: signature.energy,\n            valence: signature.valence,\n            lyrics: lyrics\n        )\n        if let analyzed = await LyricIntelligenceBackend.analyze(\n            lyrics: lyrics,\n            settings: resolvedSettings\n        ) {\n            signature.moods = analyzed.moods\n            signature.themes = analyzed.themes\n            signature.energy = analyzed.energy\n            signature.valence = analyzed.valence\n            signature.source = analyzed.source\n            if LyricIntelligencePrompt.isContentSummary(analyzed.summary) {\n                signature.summary = analyzed.summary\n            }\n            if analyzed.details.hasExtendedFields || !analyzed.details.moods.isEmpty {\n                signature.details = analyzed.details.withBasics(\n                    moods: analyzed.moods,\n                    themes: analyzed.themes,\n                    energy: analyzed.energy,\n                    valence: analyzed.valence,\n                    summary: analyzed.summary\n                )\n            }\n            if let remote = analyzed.embedding, remote.count >= 8 {\n                signature.embedding = remote\n            } else {\n                signature.embedding = LyricLexicalEmbedding.merge(\n                    moods: analyzed.moods,\n                    energy: analyzed.energy,\n                    valence: analyzed.valence,\n                    lyrics: lyrics\n                )\n            }\n        } else {\n            signature.source = "lexical"\n        }\n        if !signature.hasStoredSummary {\n            signature.summary = await Self.filledSummary(lyrics: lyrics)\n        }\n        if !signature.hasSentenceEmbedding {\n            signature.sentenceEmbedding =\n                await LyricSentenceEmbedding.vector(from: lyrics) ?? []\n        }\n        if let current = signatures[song.id] {\n            if signature.soundLabels.isEmpty {\n                signature.soundLabels = current.soundLabels\n                signature.soundEmbedding = current.soundEmbedding\n                signature.audioRevision = current.audioRevision\n                signature.soundSource = current.soundSource\n            }\n            if signature.sentenceEmbedding.count < 8 {\n                signature.sentenceEmbedding = current.sentenceEmbedding\n            }\n            if !signature.hasStoredSummary {\n                signature.summary = current.summary\n            }\n        }\n        signatures[song.id] = signature\n        await persist(signature)'''

new_analyze = '''        let previous = signatures[song.id]\n        // Never relabel old fields as a new result. A fresh lyric analysis starts\n        // from a clean record and is committed only after an LLM succeeds.\n        guard let analyzed = await LyricIntelligenceBackend.analyze(\n            lyrics: lyrics,\n            settings: resolvedSettings\n        ) else {\n            // Keep a previously valid LLM result intact. After a full reset there\n            // is nothing valid to keep, so coverage remains pending and retries.\n            return\n        }\n\n        var signature = LyricSignature(\n            songID: song.id,\n            lyricsHash: hash,\n            moods: analyzed.moods,\n            themes: analyzed.themes,\n            energy: analyzed.energy,\n            valence: analyzed.valence,\n            embedding: [],\n            source: analyzed.source,\n            summary: analyzed.summary,\n            details: analyzed.details\n        )\n        if let remote = analyzed.embedding, remote.count >= 8 {\n            signature.embedding = remote\n        } else {\n            signature.embedding = LyricLexicalEmbedding.merge(\n                moods: analyzed.moods,\n                energy: analyzed.energy,\n                valence: analyzed.valence,\n                lyrics: lyrics\n            )\n        }\n        signature.sentenceEmbedding =\n            await LyricSentenceEmbedding.vector(from: lyrics) ?? []\n\n        // Sound analysis is independent from lyric LLM output and may safely be\n        // carried forward. Sentence embeddings can also be reused if generation\n        // was deferred by thermal/low-power policy.\n        if let previous {\n            signature.soundLabels = previous.soundLabels\n            signature.soundEmbedding = previous.soundEmbedding\n            signature.audioRevision = previous.audioRevision\n            signature.soundSource = previous.soundSource\n            if signature.sentenceEmbedding.count < 8 {\n                signature.sentenceEmbedding = previous.sentenceEmbedding\n            }\n            if signature.details.vocalGender.isEmpty {\n                signature.details.vocalGender = previous.details.vocalGender\n            }\n        }\n        signatures[song.id] = signature\n        await persist(signature)'''
text = replace_once(text, old_analyze, new_analyze, "fresh signature commit")

text = replace_once(
    text,
    '''        return LyricIntelligencePrompt.heuristicSummary(from: lyrics)''',
    '''        // Do not manufacture an apparent analysis from copied lyric lines.\n        // Missing LLM output stays missing and remains eligible for retry.\n        return ""''',
    "no heuristic summary fallback",
)

old_backend = '''        guard var analysis = result else {\n            if settings.provider != .off, settings.provider != .groq {\n                return await groqAnalysis(lyrics: lyrics, settings: settings)\n            }\n            return nil\n        }\n        analysis.summary = LyricIntelligencePrompt.resolvedSummary(\n            analysis.summary,\n            lyrics: lyrics\n        )\n        analysis.details.summary = analysis.summary\n        if settings.provider != .groq,\n           !LyricIntelligencePrompt.isContentSummary(analysis.summary),\n           let groq = await groqAnalysis(lyrics: lyrics, settings: settings) {\n            return groq\n        }\n        return analysis'''
new_backend = '''        if let validated = validatedLLMAnalysis(result) {\n            return validated\n        }\n        return await fallbackLLMAnalysis(\n            lyrics: lyrics,\n            settings: settings,\n            excluding: settings.provider\n        )'''
text = replace_once(text, old_backend, new_backend, "validated backend")

old_groq = '''        analysis.summary = LyricIntelligencePrompt.resolvedSummary(\n            analysis.summary,\n            lyrics: lyrics\n        )\n        analysis.details.summary = analysis.summary\n        return analysis'''
new_groq = '''        return validatedLLMAnalysis(analysis)'''
text = replace_once(text, old_groq, new_groq, "validate Groq output")

old_ondevice_tail = '''        if let groq = await groqAnalysis(lyrics: lyrics, settings: settings) {\n            return groq\n        }\n        if !settings.openRouterKey.isEmpty,\n           let gemma = await remote(\n            lyrics: lyrics,\n            endpoint: URL(string: "https://openrouter.ai/api/v1/chat/completions"),\n            embeddingEndpoint: nil,\n            key: settings.openRouterKey,\n            model: "google/gemma-3-270m-it",\n            embeddingModel: "openai/text-embedding-3-small",\n            source: "gemma-3-270m"\n           ) {\n            return gemma\n        }\n        return Analysis(\n            moods: heuristicMoods(in: lyrics),\n            themes: [],\n            energy: 0.5,\n            valence: 0.5,\n            summary: LyricIntelligencePrompt.heuristicSummary(from: lyrics),\n            embedding: nil,\n            source: "lexical"\n        )\n    }\n\n    private static func heuristicMoods(in lyrics: String) -> [String] {\n        let text = LyricLexicalEmbedding.normalized(lyrics)\n        var moods: [String] = []\n        let lexicon: [(String, [String])] = [\n            ("sad", ["cry", "tears", "lonely", "grief", "슬픔", "눈물"]),\n            ("happy", ["smile", "dance", "joy", "sunshine", "행복", "웃"]),\n            ("calm", ["quiet", "slow", "ocean", "sleep", "잔잔", "밤"]),\n            ("angry", ["hate", "rage", "fight", "fire", "화나"]),\n            ("romantic", ["love", "heart", "kiss", "사랑", "마음"])\n        ]\n        for (mood, tokens) in lexicon where tokens.contains(where: text.contains) {\n            moods.append(mood)\n        }\n        return moods.isEmpty ? ["neutral"] : moods\n    }'''
new_ondevice_tail = '''        return nil\n    }\n\n    private static func validatedLLMAnalysis(_ candidate: Analysis?) -> Analysis? {\n        guard var analysis = candidate else { return nil }\n        analysis.summary = LyricIntelligencePrompt.normalizedSummary(analysis.summary)\n        guard LyricIntelligencePrompt.isContentSummary(analysis.summary) else {\n            return nil\n        }\n        analysis.details.summary = analysis.summary\n        return analysis\n    }\n\n    private static func fallbackLLMAnalysis(\n        lyrics: String,\n        settings: LyricIntelligenceSettings,\n        excluding provider: LyricIntelligenceProviderKind\n    ) async -> Analysis? {\n        if provider != .groq,\n           let groq = await groqAnalysis(lyrics: lyrics, settings: settings) {\n            return groq\n        }\n        if provider != .cerebras, !settings.cerebrasKey.isEmpty,\n           let cerebras = validatedLLMAnalysis(await remote(\n            lyrics: lyrics,\n            endpoint: URL(string: "https://api.cerebras.ai/v1/chat/completions"),\n            embeddingEndpoint: nil,\n            key: settings.cerebrasKey,\n            model: settings.cerebrasModel,\n            embeddingModel: "",\n            source: "cerebras"\n           )) {\n            return cerebras\n        }\n        if provider != .openRouter, !settings.openRouterKey.isEmpty,\n           let openRouter = validatedLLMAnalysis(await remote(\n            lyrics: lyrics,\n            endpoint: URL(string: "https://openrouter.ai/api/v1/chat/completions"),\n            embeddingEndpoint: nil,\n            key: settings.openRouterKey,\n            model: settings.openRouterModel,\n            embeddingModel: "",\n            source: "openrouter"\n           )) {\n            return openRouter\n        }\n        if provider != .openAI, !settings.openAIKey.isEmpty,\n           let openAI = validatedLLMAnalysis(await remote(\n            lyrics: lyrics,\n            endpoint: URL(string: "https://api.openai.com/v1/chat/completions"),\n            embeddingEndpoint: nil,\n            key: settings.openAIKey,\n            model: "gpt-4o-mini",\n            embeddingModel: "",\n            source: "openai"\n           )) {\n            return openAI\n        }\n        return nil\n    }'''
text = replace_once(text, old_ondevice_tail, new_ondevice_tail, "remove lexical backend")

path.write_text(text)

# Update settings copy so the UI matches the new semantics.
path = Path("BuFi/UI/SettingsView.swift")
text = path.read_text()
text = replace_once(
    text,
    '''            settingsDescription("한 번 누르면 지금 고른 엔진으로 샘플 가사를 분석합니다. 같은 버튼을 다시 누르면 캐시에서 읽어야 정상입니다.")''',
    '''            settingsDescription("누를 때마다 지금 고른 엔진으로 새 LLM 세션을 만들어 샘플 가사를 실제 분석합니다. LLM이 모두 실패하면 분석 완료로 저장하지 않습니다.")''',
    "probe copy",
)
text = replace_once(
    text,
    '''        let cache = probe.reusedCache\n            ? String(localized: "캐시에서 읽음 (모델을 다시 호출하지 않음)")\n            : String(localized: "새로 분석함")''',
    '''        let cache = probe.reusedCache\n            ? String(localized: "캐시에서 읽음")\n            : String(localized: "새 LLM 호출")''',
    "probe status copy",
)
text = replace_once(
    text,
    '''            String(localized: "자동은 Apple Intelligence 3B 로컬 모델로 분위기·계절·시간대·스타일·내용 등 20개 항목을 분석합니다. 안 되면 태깅 모델, 그다음 Gemma 3입니다. Privacy Cloud는 지금은 쓰지 않습니다.")''',
    '''            String(localized: "자동은 Apple Intelligence 3B를 곡마다 새 세션으로 호출합니다. 실패하면 저장된 Groq·Cerebras·OpenRouter·OpenAI 키의 LLM으로 순차 대체하며, 모든 LLM이 실패하면 완료 처리하지 않고 재시도 대상으로 남깁니다.")''',
    "engine copy",
)
path.write_text(text)

# Add regression tests that prevent lexical results from becoming valid cache.
test_path = Path("BuFiTests/LyricLLMOnlyTests.swift")
test_path.write_text('''import XCTest\n@testable import BuFi\n\nfinal class LyricLLMOnlyTests: XCTestCase {\n    func testLegacyLexicalResultIsNeverReusableAsCompletedAnalysis() {\n        let signature = LyricSignature(\n            songID: "legacy",\n            lyricsHash: "abc",\n            moods: ["sad"],\n            themes: [],\n            energy: 0.5,\n            valence: 0.5,\n            embedding: [],\n            source: "lexical",\n            summary: "copied lyric line that looks like a summary"\n        )\n\n        XCTAssertFalse(signature.hasStoredLyricAnalysis)\n        XCTAssertFalse(\n            LyricAnalysisCachePolicy.shouldReuseLyric(\n                existing: signature,\n                lyricsHash: "abc"\n            )\n        )\n    }\n\n    func testActualLLMResultRemainsReusable() {\n        let signature = LyricSignature(\n            songID: "llm",\n            lyricsHash: "abc",\n            moods: ["yearning"],\n            themes: ["memory"],\n            energy: 0.4,\n            valence: 0.3,\n            embedding: [],\n            source: "apple-intelligence-3b",\n            summary: "The narrator revisits a lost relationship and accepts that it is gone."\n        )\n\n        XCTAssertTrue(signature.hasStoredLyricAnalysis)\n        XCTAssertTrue(\n            LyricAnalysisCachePolicy.shouldReuseLyric(\n                existing: signature,\n                lyricsHash: "abc"\n            )\n        )\n    }\n}\n''')
