import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// Apple on-device lyric embeddings. Prefers the contextual transformer,
/// then the static sentence embedding. Results are stored in SQLite so a
/// later play never recomputes the same lyrics.
enum LyricSentenceEmbedding {
    static func vector(from text: String) async -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 12 else { return nil }
        let preferStatic = await MainActor.run {
            AudioEngine.shared.wantsPlayback
        }
        return await Task.detached(priority: .utility) {
            vectorSync(from: trimmed, preferStatic: preferStatic)
        }.value
    }

    private static func vectorSync(
        from text: String,
        preferStatic: Bool = false
    ) -> [Float]? {
#if canImport(NaturalLanguage)
        // Use the same representative head/middle/tail sampler as the LLM so
        // long lyrics are not embedded from the first verse only. 1.2K chars
        // also keeps transformer work noticeably below the previous 1.6K path.
        let snippet = LyricTextSampler.sample(text, limit: 1_200)
        if preferStatic || shouldUseLightweightPath {
            return staticSentenceVector(from: snippet)
        }
        if let contextual = contextualVector(from: snippet) {
            return contextual
        }
        return staticSentenceVector(from: snippet)
#else
        _ = text
        return nil
#endif
    }

    private static var shouldUseLightweightPath: Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            return true
        }
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical:
            return true
        case .nominal, .fair:
            return false
        @unknown default:
            return true
        }
    }

#if canImport(NaturalLanguage)
    private static func contextualVector(from text: String) -> [Float]? {
        let recognized = NLLanguageRecognizer.dominantLanguage(for: text)
        var languages: [NLLanguage] = []
        if let recognized {
            languages.append(recognized)
        }
        // Avoid loading Korean/Japanese/English contextual assets one after
        // another for every song. Only try the detected language, then English
        // as a compatibility fallback when it is actually different.
        if recognized != .english {
            languages.append(.english)
        }
        for language in languages {
            guard let embedding = NLContextualEmbedding(language: language) else {
                continue
            }
            do {
                if !embedding.hasAvailableAssets {
                    continue
                }
                try embedding.load()
                defer { embedding.unload() }
                let result = try embedding.embeddingResult(
                    for: text,
                    language: language
                )
                var sum = [Double]()
                var count = 0
                result.enumerateTokenVectors(
                    in: result.string.startIndex..<result.string.endIndex
                ) { vector, _ in
                    if sum.isEmpty {
                        sum = vector
                    } else if vector.count == sum.count {
                        for index in sum.indices {
                            sum[index] += vector[index]
                        }
                    }
                    count += 1
                    return true
                }
                guard count > 0, !sum.isEmpty else { continue }
                return LyricLexicalEmbedding.l2Normalized(
                    sum.map { Float($0 / Double(count)) }
                )
            } catch {
                continue
            }
        }
        return nil
    }

    private static func staticSentenceVector(from text: String) -> [Float]? {
        let recognized = NLLanguageRecognizer.dominantLanguage(for: text) ?? .english
        var languages = [recognized]
        if recognized != .english {
            languages.append(.english)
        }
        for language in languages {
            guard let embedding = NLEmbedding.sentenceEmbedding(for: language),
                  let vector = embedding.vector(for: text),
                  !vector.isEmpty else {
                continue
            }
            return LyricLexicalEmbedding.l2Normalized(vector.map(Float.init))
        }
        return nil
    }
#endif
}

enum LyricLexicalFeatures {
    static func extraTokens(from text: String) -> [String] {
#if canImport(NaturalLanguage)
        let snippet = String(text.prefix(800))
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = snippet
        var tokens: [String] = []
        tagger.enumerateTags(
            in: snippet.startIndex..<snippet.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation]
        ) { tag, range in
            if tag == .personalName || tag == .placeName {
                tokens.append(String(snippet[range]))
            }
            return tokens.count < 8
        }
        return tokens
#else
        _ = text
        return []
#endif
    }
}
