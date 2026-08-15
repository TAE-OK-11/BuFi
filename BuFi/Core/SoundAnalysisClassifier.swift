import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(SoundAnalysis)
import SoundAnalysis
#endif

/// Apple's built-in Sound Analysis classifier (Core ML, shipped with iOS).
/// Long tracks are sampled at the intro, middle and ending instead of burning
/// the same budget on the first 20 seconds only. The total analyzed audio is
/// capped at about 18 seconds and cached by audio revision.
enum SoundAnalysisClassifier {
    static let dimensions = 64
    private static let segmentDuration: Double = 6

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

    static func vocalGender(from labels: [String]) -> String {
        let text = labels.joined(separator: " ").lowercased()
        let female = text.contains("female") || text.contains("woman")
        let male = (text.contains("male") && !text.contains("female"))
            || text.contains("man") && !text.contains("woman")
        if female, male { return "mixed" }
        if female { return "female" }
        if male { return "male" }
        if text.contains("sing") || text.contains("music") { return "" }
        return ""
    }

    static func topLabels(from scores: [String: Double], limit: Int = 8) -> [String] {
        scores
            .filter { $0.value >= 0.05 }
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map(\.key)
    }

    static func analyzeFile(at url: URL) async -> Analysis? {
        guard url.isFileURL, !shouldDeferForThermals else { return nil }
#if canImport(SoundAnalysis) && canImport(AVFoundation)
        return await Task.detached(priority: .utility) {
            analyzeFileSync(at: url)
        }.value
#else
        return nil
#endif
    }

    private static var shouldDeferForThermals: Bool {
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

#if canImport(SoundAnalysis) && canImport(AVFoundation)
    private static func analyzeFileSync(at url: URL) -> Analysis? {
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            guard format.sampleRate > 0, format.channelCount > 0, file.length > 0 else {
                return nil
            }

            let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
            let collector = SoundClassificationCollector()
            let analyzer = SNAudioStreamAnalyzer(format: format)
            try analyzer.add(request, withObserver: collector)

            let segmentFrames = AVAudioFramePosition(format.sampleRate * segmentDuration)
            guard segmentFrames > 0 else { return nil }
            let starts: [AVAudioFramePosition]
            if file.length <= segmentFrames * 3 {
                starts = [0]
            } else {
                starts = [
                    0,
                    max(0, file.length / 2 - segmentFrames / 2),
                    max(0, file.length - segmentFrames)
                ]
            }

            let bufferSize: AVAudioFrameCount = 4_096
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: bufferSize
            ) else {
                return nil
            }

            var analysisPosition: AVAudioFramePosition = 0
            for start in starts {
                file.framePosition = start
                let available = file.length - start
                let target = starts.count == 1
                    ? available
                    : min(segmentFrames, available)
                var remaining = AVAudioFrameCount(max(0, target))

                while remaining > 0 {
                    let frames = min(bufferSize, remaining)
                    try file.read(into: buffer, frameCount: frames)
                    guard buffer.frameLength > 0 else { break }
                    analyzer.analyze(buffer, atAudioFramePosition: analysisPosition)
                    analysisPosition += AVAudioFramePosition(buffer.frameLength)
                    remaining -= buffer.frameLength
                }
            }

            analyzer.completeAnalysis()
            return finished(collector.scores())
        } catch {
            return nil
        }
    }

    private static func finished(_ scores: [String: Double]) -> Analysis? {
        let labels = topLabels(from: scores)
        guard !labels.isEmpty else { return nil }
        return Analysis(
            labels: labels,
            embedding: embedding(from: scores),
            source: "coreml-sound-analysis"
        )
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
