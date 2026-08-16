import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Onset-envelope tempo and loudness features used by both local ranking
/// and the radio prompt. Apple Sound Analysis does not emit BPM, so this
/// is measured from the same audio we already classify.
enum SoundFeatureExtractor {
    struct Features: Equatable, Sendable {
        var bpm: Int
        var energy: Double
        var brightness: Double
        var pulse: Double

        static let empty = Features(bpm: 0, energy: 0, brightness: 0, pulse: 0)

        var isMeasured: Bool { bpm > 0 || pulse > 0 || energy > 0 }
    }

    static func measure(
        envelope: [Float],
        hopSeconds: Double,
        brightness: Double = 0
    ) -> Features {
        guard envelope.count >= 24, hopSeconds > 0 else { return .empty }
        let energy = normalizedEnergy(envelope)
        let onset = onsetTempo(envelope: envelope, hopSeconds: hopSeconds)
        let auto = autocorrelationTempo(envelope: envelope, hopSeconds: hopSeconds)
        let (bpm, pulse) = combine(onset: onset, auto: auto)
        return Features(
            bpm: bpm,
            energy: energy,
            brightness: min(max(brightness, 0), 1),
            pulse: pulse
        )
    }

#if canImport(AVFoundation)
    static func estimateFile(at url: URL) -> Features? {
        guard url.isFileURL else { return nil }
        return readEnvelope(at: url).flatMap { envelope, hop, brightness in
            let features = measure(
                envelope: envelope,
                hopSeconds: hop,
                brightness: brightness
            )
            return features.isMeasured ? features : nil
        }
    }

    private static func readEnvelope(
        at url: URL
    ) -> (envelope: [Float], hopSeconds: Double, brightness: Double)? {
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            guard format.sampleRate > 0, file.length > 0 else { return nil }
            let hop = 512
            let hopSeconds = Double(hop) / format.sampleRate
            let window = AVAudioFramePosition(format.sampleRate * 12)
            let start = max(0, (file.length - window) / 2)
            file.framePosition = start
            let bufferSize: AVAudioFrameCount = 4_096
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: bufferSize
            ) else {
                return nil
            }
            var envelope: [Float] = []
            envelope.reserveCapacity(1_200)
            var leftover: [Float] = []
            var remaining = AVAudioFrameCount(min(window, file.length - start))
            var highEnergy = 0.0
            var allEnergy = 0.0
            while remaining > 0 {
                let frames = min(bufferSize, remaining)
                try file.read(into: buffer, frameCount: frames)
                guard buffer.frameLength > 0 else { break }
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
            let brightness = allEnergy > 0 ? highEnergy / allEnergy : 0
            return envelope.count >= 24
                ? (envelope, hopSeconds, brightness)
                : nil
        } catch {
            return nil
        }
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
                allEnergy += Double(sample * sample)
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

    static func bpm(song: Song, signature: LyricSignature?) -> Int {
        if let value = song.bpm, value > 0 { return value }
        let measured = signature?.details.audioBPM ?? 0
        return measured > 0 ? measured : 0
    }

    static func energy(song _: Song, signature: LyricSignature?) -> Double {
        let measured = signature?.details.audioEnergy ?? 0
        if measured > 0 { return measured }
        return signature?.energy ?? 0
    }

    static func closeness(left: Int, right: Int) -> Double {
        guard left > 0, right > 0 else { return 0 }
        let delta = abs(left - right)
        return switch delta {
        case ...4: 1
        case ...8: 0.82
        case ...14: 0.58
        case ...22: 0.32
        case ...36: 0.12
        default: 0
        }
    }

    static func transitionScore(
        from: Song,
        to: Song,
        lyricIndex: LyricSignatureIndex
    ) -> Double {
        let left = lyricIndex.bySongID[from.id]
        let right = lyricIndex.bySongID[to.id]
        var score = 0.0
        score += closeness(
            left: bpm(song: from, signature: left),
            right: bpm(song: to, signature: right)
        ) * 0.38
        if left != nil, right != nil {
            score += lyricIndex.similarity(between: from.id, and: to.id) * 0.34
        }
        if let left, let right {
            score += SoundLabelSpace.overlap(left.soundLabels, right.soundLabels) * 0.16
            score += (1 - min(1, abs(left.energy - right.energy))) * 0.12
        }
        return min(1, score)
    }

    private static func normalizedEnergy(_ envelope: [Float]) -> Double {
        guard !envelope.isEmpty else { return 0 }
        var sum: Double = 0
        var peak: Float = 0
        for value in envelope {
            sum += Double(value)
            if value > peak { peak = value }
        }
        let mean = sum / Double(envelope.count)
        let scale = max(Double(peak), 0.0001)
        return min(1, (mean / scale) * 2.2)
    }

    private static func combine(
        onset: (Int, Double),
        auto: (Int, Double)
    ) -> (Int, Double) {
        if onset.0 > 0, auto.0 > 0 {
            if abs(onset.0 - auto.0) <= 6 {
                return ((onset.0 + auto.0) / 2, max(onset.1, auto.1))
            }
            if onset.1 + 0.04 >= auto.1 { return onset }
            return auto
        }
        if onset.0 > 0 { return onset }
        return auto
    }

    private static func onsetTempo(
        envelope: [Float],
        hopSeconds: Double
    ) -> (Int, Double) {
        guard envelope.count >= 32 else { return (0, 0) }
        var flux = [Float](repeating: 0, count: envelope.count)
        var mean: Double = 0
        for index in 1..<envelope.count {
            let value = max(0, envelope[index] - envelope[index - 1])
            flux[index] = value
            mean += Double(value)
        }
        mean /= Double(flux.count)
        var variance: Double = 0
        for value in flux {
            let delta = Double(value) - mean
            variance += delta * delta
        }
        let threshold = Float(mean + (variance / Double(flux.count)).squareRoot() * 1.15)
        let minGap = max(1, Int((0.26 / hopSeconds).rounded()))
        var peaks: [Int] = []
        var index = 2
        while index < flux.count - 2 {
            let value = flux[index]
            if value >= threshold,
               value >= flux[index - 1],
               value >= flux[index + 1] {
                if let last = peaks.last, index - last < minGap {
                    if value > flux[last] { peaks[peaks.count - 1] = index }
                } else {
                    peaks.append(index)
                }
                index += minGap
                continue
            }
            index += 1
        }
        guard peaks.count >= 4 else { return (0, 0) }
        var votes: [Int: Double] = [:]
        for left in 0..<(peaks.count - 1) {
            for right in (left + 1)..<min(peaks.count, left + 4) {
                let interval = Double(peaks[right] - peaks[left]) * hopSeconds
                guard interval >= 0.32, interval <= 0.90 else { continue }
                let bpm = foldBPM(60.0 / interval)
                guard bpm >= 70, bpm <= 168 else { continue }
                votes[bpm, default: 0] += 1
            }
        }
        guard let best = votes.max(by: {
            if $0.value == $1.value { return $0.key < $1.key }
            return $0.value < $1.value
        }) else {
            return (0, 0)
        }
        let pulse = min(1, best.value / Double(max(peaks.count - 1, 1)))
        return pulse >= 0.18 ? (best.key, pulse) : (0, pulse)
    }

    private static func autocorrelationTempo(
        envelope: [Float],
        hopSeconds: Double
    ) -> (Int, Double) {
        var bestBPM = 0
        var bestScore = 0.0
        for bpm in stride(from: 70, through: 168, by: 1) {
            let lag = (60.0 / Double(bpm)) / hopSeconds
            let score = autocorrelation(envelope, lag: lag)
            if score > bestScore {
                bestScore = score
                bestBPM = bpm
            }
        }
        return (bestScore >= 0.12 ? bestBPM : 0, min(1, bestScore))
    }

    private static func foldBPM(_ value: Double) -> Int {
        var bpm = value
        while bpm < 70 { bpm *= 2 }
        while bpm > 168 { bpm /= 2 }
        return Int(bpm.rounded())
    }

    private static func autocorrelation(_ values: [Float], lag: Double) -> Double {
        let whole = Int(lag.rounded())
        guard whole >= 1, whole < values.count / 2 else { return 0 }
        var num: Double = 0
        var left: Double = 0
        var right: Double = 0
        let count = values.count - whole
        for index in 0..<count {
            let a = Double(values[index])
            let b = Double(values[index + whole])
            num += a * b
            left += a * a
            right += b * b
        }
        let denom = (left * right).squareRoot()
        guard denom > 0 else { return 0 }
        return max(0, num / denom)
    }
}
