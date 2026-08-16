import Foundation

/// Collapses Apple Sound Analysis' 300-class hierarchy into a small set of
/// music-lane tokens. Parent paths ("music > instrument > guitar") and
/// sibling duplicates ("guitar", "electric guitar") become one instrument
/// instead of several hash-scattered labels.
enum SoundLabelSpace {
    static let maxStoredLabels = 5

    static func canonicalize(_ labels: [String]) -> [String] {
        let scored = aggregate(labels.map { ($0, 1.0) })
        return scored.prefix(maxStoredLabels).map(\.token)
    }

    static func tokens(from scores: [String: Double]) -> [(token: String, confidence: Double)] {
        aggregate(scores.map { ($0.key, $0.value) })
    }

    static func embedding(from scores: [String: Double]) -> [Float] {
        vector(from: tokens(from: scores))
    }

    static func embedding(fromLabels labels: [String]) -> [Float] {
        vector(
            from: canonicalize(labels).map { (token: $0, confidence: 0.85) }
        )
    }

    static func vocalGender(from labels: [String]) -> String {
        var female = false
        var male = false
        for raw in labels {
            for part in parts(of: raw) {
                if isFemaleVocal(part) { female = true }
                if isMaleVocal(part) { male = true }
            }
        }
        if female, male { return "mixed" }
        if female { return "female" }
        if male { return "male" }
        return ""
    }

    static func displayNames(_ labels: [String]) -> [String] {
        canonicalize(labels).map(displayName)
    }

    static func displayName(_ token: String) -> String {
        switch token {
        case "singing": String(localized: "보컬")
        case "choir": String(localized: "합창")
        case "speech": String(localized: "말하기")
        case "guitar": String(localized: "기타")
        case "piano": String(localized: "피아노")
        case "drums": String(localized: "드럼")
        case "bass": String(localized: "베이스")
        case "synth": String(localized: "신스")
        case "strings": String(localized: "현악기")
        case "brass": String(localized: "브라스")
        case "wind": String(localized: "관악기")
        case "electronic": String(localized: "전자음")
        case "acoustic": String(localized: "어쿠스틱")
        case "beat": String(localized: "비트")
        case "ambient": String(localized: "앰비언트")
        case "rock": String(localized: "록")
        case "pop": String(localized: "팝")
        case "jazz": String(localized: "재즈")
        case "classical": String(localized: "클래식")
        case "music": String(localized: "음악")
        case "instrument": String(localized: "악기")
        case "rain": String(localized: "빗소리")
        default: token
        }
    }

    static func overlap(_ left: [String], _ right: [String]) -> Double {
        let a = Set(canonicalize(left))
        let b = Set(canonicalize(right))
        guard !a.isEmpty || !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(a.union(b).count)
    }

    static func matches(_ labels: [String], hints: [String]) -> Bool {
        let tokens = Set(canonicalize(labels))
        return hints.contains { tokens.contains($0) }
    }

    private static func aggregate(
        _ scored: [(String, Double)]
    ) -> [(token: String, confidence: Double)] {
        var merged: [String: Double] = [:]
        for (raw, confidence) in scored {
            let value = min(max(confidence, 0), 1)
            guard value >= 0.08 else { continue }
            for token in map(raw) {
                merged[token] = max(merged[token] ?? 0, value)
            }
        }
        dropParents(&merged)
        dropAtmosphere(&merged)
        return merged
            .map { (token: $0.key, confidence: $0.value) }
            .sorted {
                if $0.confidence == $1.confidence { return $0.token < $1.token }
                return $0.confidence > $1.confidence
            }
    }

    private static func map(_ raw: String) -> [String] {
        var tokens = Set<String>()
        for part in parts(of: raw) {
            if let mapped = aliases[part] {
                tokens.insert(mapped)
            }
            for (pattern, token) in fragments where part.contains(pattern) {
                tokens.insert(token)
            }
        }
        return Array(tokens)
    }

    private static func parts(of raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let dotted = trimmed.contains(".")
            && !trimmed.contains(" ")
            && !trimmed.contains(">")
        let pieces: [String]
        if dotted {
            pieces = trimmed.split(separator: ".").map {
                String($0).replacingOccurrences(of: "_", with: " ")
            }
        } else {
            pieces = trimmed
                .replacingOccurrences(of: "_", with: " ")
                .components(separatedBy: CharacterSet(charactersIn: ">|/\\"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return pieces.map { LyricLexicalEmbedding.normalized($0) }
    }

    private static func dropParents(_ values: inout [String: Double]) {
        let specificInstruments: Set<String> = [
            "guitar", "piano", "drums", "bass", "synth",
            "strings", "brass", "wind"
        ]
        let musicChildren: Set<String> = specificInstruments.union([
            "singing", "choir", "electronic", "acoustic", "beat",
            "ambient", "rock", "pop", "jazz", "classical", "instrument"
        ])
        if !values.keys.isDisjoint(with: specificInstruments) {
            values.removeValue(forKey: "instrument")
        }
        if !values.keys.isDisjoint(with: musicChildren) {
            values.removeValue(forKey: "music")
        }
        if values["singing"] != nil || values["choir"] != nil {
            values.removeValue(forKey: "speech")
        }
    }

    private static func dropAtmosphere(_ values: inout [String: Double]) {
        let hasMusic = values.keys.contains { token in
            token != "noise" && token != "speech" && token != "rain"
        }
        if hasMusic {
            values.removeValue(forKey: "noise")
        }
    }

    private static func isFemaleVocal(_ part: String) -> Bool {
        part.contains("female") || part.contains("woman") || part.contains("girl")
    }

    private static func isMaleVocal(_ part: String) -> Bool {
        guard !isFemaleVocal(part) else { return false }
        if part.contains("male") { return true }
        let tokens = part.split(whereSeparator: { !$0.isLetter }).map(String.init)
        return tokens.contains("man") || tokens.contains("boy")
    }

    private static let aliases: [String: String] = [
        "singing": "singing",
        "male singing": "singing",
        "female singing": "singing",
        "child singing": "singing",
        "vocal music": "singing",
        "a capella": "singing",
        "acapella": "singing",
        "choir": "choir",
        "choral music": "choir",
        "speech": "speech",
        "male speech": "speech",
        "female speech": "speech",
        "child speech": "speech",
        "conversation": "speech",
        "narration": "speech",
        "guitar": "guitar",
        "electric guitar": "guitar",
        "acoustic guitar": "guitar",
        "bass guitar": "bass",
        "piano": "piano",
        "electric piano": "piano",
        "keyboard musical": "piano",
        "musical keyboard": "piano",
        "organ": "piano",
        "harpsichord": "piano",
        "synthesizer": "synth",
        "synth": "synth",
        "drum": "drums",
        "drums": "drums",
        "drum kit": "drums",
        "drum machine": "drums",
        "snare drum": "drums",
        "bass drum": "drums",
        "cymbal": "drums",
        "hi-hat": "drums",
        "hihat": "drums",
        "percussion": "drums",
        "violin": "strings",
        "cello": "strings",
        "viola": "strings",
        "double bass": "strings",
        "orchestra": "strings",
        "string section": "strings",
        "trumpet": "brass",
        "trombone": "brass",
        "french horn": "brass",
        "brass instrument": "brass",
        "saxophone": "wind",
        "flute": "wind",
        "clarinet": "wind",
        "harmonica": "wind",
        "wind instrument": "wind",
        "electronic music": "electronic",
        "electronica": "electronic",
        "techno": "electronic",
        "house music": "electronic",
        "edm": "electronic",
        "hip hop": "beat",
        "hiphop": "beat",
        "rap": "beat",
        "beatboxing": "beat",
        "rock music": "rock",
        "rock and roll": "rock",
        "pop music": "pop",
        "jazz": "jazz",
        "classical music": "classical",
        "orchestral music": "classical",
        "ambient music": "ambient",
        "music": "music",
        "song": "music",
        "musical instrument": "instrument",
        "instrument": "instrument",
        "acoustic music": "acoustic",
        "rain": "rain",
        "raindrop": "rain",
        "silence": "noise",
        "noise": "noise",
        "hum": "noise",
        "white noise": "noise"
    ]

    private static let fragments: [(String, String)] = [
        ("sing", "singing"),
        ("choir", "choir"),
        ("guitar", "guitar"),
        ("piano", "piano"),
        ("keyboard", "piano"),
        ("synth", "synth"),
        ("drum", "drums"),
        ("cymbal", "drums"),
        ("hi-hat", "drums"),
        ("percussion", "drums"),
        ("bass", "bass"),
        ("violin", "strings"),
        ("cello", "strings"),
        ("orchestra", "strings"),
        ("trumpet", "brass"),
        ("sax", "wind"),
        ("flute", "wind"),
        ("techno", "electronic"),
        ("electronic", "electronic"),
        ("hip hop", "beat"),
        ("hiphop", "beat"),
        ("ambient", "ambient"),
        ("acoustic", "acoustic"),
        ("jazz", "jazz"),
        ("classical", "classical")
    ]

    private enum Axis: Int, CaseIterable {
        case singing
        case choir
        case speech
        case guitar
        case piano
        case drums
        case bass
        case synth
        case strings
        case brass
        case wind
        case electronic
        case acoustic
        case beat
        case ambient
        case rock
        case pop
        case jazz
        case classical
        case rain
    }

    private static func vector(
        from tokens: [(token: String, confidence: Double)]
    ) -> [Float] {
        var buckets = [Float](repeating: 0, count: LyricLexicalEmbedding.dimensions)
        guard !tokens.isEmpty else { return buckets }
        for item in tokens {
            if let axis = axisIndex(for: item.token) {
                buckets[axis] += Float(item.confidence)
                continue
            }
            var hash: UInt64 = 0xcbf2_9ce4_8422_2325
            for byte in item.token.utf8 {
                hash ^= UInt64(byte)
                hash &*= 0x100_0000_01b3
            }
            let reserved = Axis.allCases.count
            let span = max(1, LyricLexicalEmbedding.dimensions - reserved)
            let index = reserved + Int(hash % UInt64(span))
            let sign: Float = hash & 1 == 0 ? 1 : -1
            buckets[index] += sign * Float(item.confidence)
        }
        return LyricLexicalEmbedding.l2Normalized(buckets)
    }

    private static func axisIndex(for token: String) -> Int? {
        switch token {
        case "singing": Axis.singing.rawValue
        case "choir": Axis.choir.rawValue
        case "speech": Axis.speech.rawValue
        case "guitar": Axis.guitar.rawValue
        case "piano": Axis.piano.rawValue
        case "drums": Axis.drums.rawValue
        case "bass": Axis.bass.rawValue
        case "synth": Axis.synth.rawValue
        case "strings": Axis.strings.rawValue
        case "brass": Axis.brass.rawValue
        case "wind": Axis.wind.rawValue
        case "electronic": Axis.electronic.rawValue
        case "acoustic": Axis.acoustic.rawValue
        case "beat": Axis.beat.rawValue
        case "ambient": Axis.ambient.rawValue
        case "rock": Axis.rock.rawValue
        case "pop": Axis.pop.rawValue
        case "jazz": Axis.jazz.rawValue
        case "classical": Axis.classical.rawValue
        case "rain": Axis.rain.rawValue
        default: nil
        }
    }
}
