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
        return await Task.detached(priority: .utility) {
            vectorSync(from: trimmed)
        }.value
    }

    private static func vectorSync(from text: String) -> [Float]? {
#if canImport(NaturalLanguage)
        let snippet = String(text.prefix(1_600))
        if let contextual = contextualVector(from: snippet) {
            return contextual
        }
        return staticSentenceVector(from: snippet)
#else
        _ = text
        return nil
#endif
    }

#if canImport(NaturalLanguage)
    private static func contextualVector(from text: String) -> [Float]? {
        let recognized = NLLanguageRecognizer.dominantLanguage(for: text)
        let languages = [recognized, .english, .korean, .japanese].compactMap { $0 }
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
        for language in [recognized, .english] {
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
