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
        var bpm: Int = 0
        var energy: Double = 0
        var brightness: Double = 0
        var pulse: Double = 0
    }

    static func embedding(from scores: [String: Double]) -> [Float] {
        SoundLabelSpace.embedding(from: scores)
    }

    static func vocalGender(from labels: [String]) -> String {
        SoundLabelSpace.vocalGender(from: labels)
    }

    static func topLabels(from scores: [String: Double], limit: Int = 5) -> [String] {
        Array(SoundLabelSpace.tokens(from: scores).prefix(limit).map(\.token))
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

            let hop = 512
            var envelope: [Float] = []
            envelope.reserveCapacity(2_048)
            var leftover: [Float] = []
            leftover.reserveCapacity(hop)
            var highEnergy = 0.0
            var allEnergy = 0.0
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
                    absorb(
                        buffer,
                        hop: hop,
                        envelope: &envelope,
                        leftover: &leftover,
                        highEnergy: &highEnergy,
                        allEnergy: &allEnergy
                    )
                    remaining -= buffer.frameLength
                }
            }

            analyzer.completeAnalysis()
            let hopSeconds = Double(hop) / format.sampleRate
            let brightness = allEnergy > 0 ? highEnergy / allEnergy : 0
            return finished(
                collector.scores(),
                features: SoundFeatureExtractor.measure(
                    envelope: envelope,
                    hopSeconds: hopSeconds,
                    brightness: brightness
                )
            )
        } catch {
            return nil
        }
    }

    private static func finished(
        _ scores: [String: Double],
        features: SoundFeatureExtractor.Features
    ) -> Analysis? {
        let labels = topLabels(from: scores)
        guard !labels.isEmpty || features.isMeasured else { return nil }
        return Analysis(
            labels: labels,
            embedding: embedding(from: scores),
            source: "coreml-sound-analysis",
            bpm: features.bpm,
            energy: features.energy,
            brightness: features.brightness,
            pulse: features.pulse
        )
    }

    private static func absorb(
        _ buffer: AVAudioPCMBuffer,
        hop: Int,
        envelope: inout [Float],
        leftover: inout [Float],
        highEnergy: inout Double,
        allEnergy: inout Double
    ) {
        let frames = Int(buffer.frameLength)
        guard frames > 0, hop > 0 else { return }
        var mono = leftover
        leftover.removeAll(keepingCapacity: true)
        mono.reserveCapacity(mono.count + frames)
        if let pointer = buffer.floatChannelData?.pointee {
            for index in 0..<frames {
                let sample = pointer[index]
                mono.append(abs(sample))
                let energy = Double(sample * sample)
                allEnergy += energy
                if index % 2 == 1 {
                    let previous = pointer[index - 1]
                    let high = sample - previous
                    highEnergy += Double(high * high)
                }
            }
        } else if let pointer = buffer.int16ChannelData?.pointee {
            for index in 0..<frames {
                let sample = Float(pointer[index]) / 32_768
                mono.append(abs(sample))
                let energy = Double(sample * sample)
                allEnergy += energy
            }
        } else {
            return
        }
        var start = 0
        while start + hop <= mono.count {
            var sum: Float = 0
            for index in start..<(start + hop) {
                sum += mono[index]
            }
            envelope.append(sum / Float(hop))
            start += hop
        }
        if start < mono.count {
            leftover.append(contentsOf: mono[start..<mono.count])
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
