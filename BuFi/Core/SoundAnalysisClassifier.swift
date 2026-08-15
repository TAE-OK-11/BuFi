import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(SoundAnalysis)
import SoundAnalysis
#endif

/// Apple's built-in Sound Analysis classifier (Core ML, shipped with iOS).
/// Only the first 20 seconds of a local file are scored so playback stays light.
/// Labels and the hashed confidence vector go into SQLite and are not recomputed
/// for the same audio revision.
enum SoundAnalysisClassifier {
    static let dimensions = 64
    private static let analysisDuration: Double = 20

    struct Analysis: Sendable {
        var labels: [String]
        var embedding: [Float]
        var source: String
    }

    static func embedding(from scores: [String: Double]) -> [Float] {
        var buckets = [Float](repeating: 0, count: dimensions)
        guard !scores.isEmpty else { return buckets }
        for (label, confidence) in scores {
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in label.utf8 {
                hash ^= UInt64(byte)
                hash &*= 0x100_0000_01b3
            }
            let index = Int(hash % UInt64(dimensions))
            let sign: Float = hash & 1 == 0 ? 1 : -1
            buckets[index] += sign * Float(max(0, min(confidence, 1)))
        }
        return LyricLexicalEmbedding.l2Normalized(buckets)
    }

    static func topLabels(from scores: [String: Double], limit: Int = 8) -> [String] {
        scores
            .filter { $0.value >= 0.12 }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }

    static func analyzeFile(at url: URL) async -> Analysis? {
        guard url.isFileURL else { return nil }
#if canImport(SoundAnalysis) && canImport(AVFoundation)
        return await Task.detached(priority: .utility) {
            analyzeFileSync(at: url)
        }.value
#else
        return nil
#endif
    }

#if canImport(SoundAnalysis) && canImport(AVFoundation)
    private static func analyzeFileSync(at url: URL) -> Analysis? {
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            guard format.sampleRate > 0, format.channelCount > 0 else { return nil }
            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            let collector = SoundClassificationCollector()
            let analyzer = SNAudioStreamAnalyzer(format: format)
            try analyzer.add(request, withObserver: collector)

            let frameCap = AVAudioFrameCount(min(
                Double(file.length),
                format.sampleRate * analysisDuration
            ))
            guard frameCap > 0 else { return nil }
            let bufferSize: AVAudioFrameCount = 4_096
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: bufferSize
            ) else {
                return nil
            }

            var remaining = frameCap
            var position: AVAudioFramePosition = 0
            while remaining > 0 {
                let frames = min(bufferSize, remaining)
                try file.read(into: buffer, frameCount: frames)
                guard buffer.frameLength > 0 else { break }
                analyzer.analyze(buffer, atAudioFramePosition: position)
                position += AVAudioFramePosition(buffer.frameLength)
                remaining -= buffer.frameLength
            }
            analyzer.completeAnalysis()

            let scores = collector.scores()
            let labels = topLabels(from: scores)
            guard !labels.isEmpty else { return nil }
            return Analysis(
                labels: labels,
                embedding: embedding(from: scores),
                source: "coreml-sound-analysis"
            )
        } catch {
            return nil
        }
    }
#endif
}

#if canImport(SoundAnalysis)
private final class SoundClassificationCollector: NSObject, SNResultsObserving {
    private let lock = NSLock()
    private var values: [String: Double] = [:]

    func scores() -> [String: Double] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        lock.lock()
        for item in result.classifications {
            let current = values[item.identifier] ?? 0
            if item.confidence > current {
                values[item.identifier] = item.confidence
            }
        }
        lock.unlock()
    }
}
#endif
