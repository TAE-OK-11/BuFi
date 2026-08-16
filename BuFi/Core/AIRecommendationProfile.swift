import Foundation

enum AILyricMood: String, CaseIterable, Identifiable, Sendable {
    case joy
    case sadness
    case yearning
    case calm
    case love
    case nostalgic
    case anxious
    case angry
    case hopeful
    case lonely

    var id: String { rawValue }

    var title: String {
        switch self {
        case .joy: String(localized: "행복")
        case .sadness: String(localized: "슬픔")
        case .yearning: String(localized: "그리움")
        case .calm: String(localized: "평온")
        case .love: String(localized: "사랑")
        case .nostalgic: String(localized: "향수")
        case .anxious: String(localized: "불안")
        case .angry: String(localized: "분노")
        case .hopeful: String(localized: "희망")
        case .lonely: String(localized: "외로움")
        }
    }

    var tokens: [String] {
        switch self {
        case .joy: ["happy", "joy", "smile", "행복", "기쁨"]
        case .sadness: ["sad", "sorrow", "눈물", "슬픔"]
        case .yearning: ["yearning", "longing", "그리움", "보고싶"]
        case .calm: ["calm", "quiet", "평온", "잔잔"]
        case .love: ["love", "heart", "사랑"]
        case .nostalgic: ["nostalgic", "memory", "향수", "그때"]
        case .anxious: ["anxious", "fear", "불안"]
        case .angry: ["angry", "resentful", "분노"]
        case .hopeful: ["hope", "light", "희망"]
        case .lonely: ["lonely", "alone", "외로"]
        }
    }
}

enum TaylorPenStyle: String, CaseIterable, Identifiable, Sendable {
    case fountain
    case quill
    case glitter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fountain: String(localized: "만년필")
        case .quill: String(localized: "깃펜")
        case .glitter: String(localized: "글리터 젤펜")
        }
    }

    var subtitle: String {
        switch self {
        case .fountain:
            String(localized: "시적이고 촉촉한 문장. 비, 편지, 늦은 밤.")
        case .quill:
            String(localized: "극적이고 서사적. 운명, 복수, 긴 이야기.")
        case .glitter:
            String(localized: "반짝이는 팝. 설렘, 춤, 낮의 공기.")
        }
    }

    var tokens: [String] {
        switch self {
        case .fountain:
            ["poetic", "rain", "letter", "autumn", "confession", "quiet", "yearning"]
        case .quill:
            ["story", "fate", "revenge", "tragic", "dramatic", "gothic"]
        case .glitter:
            ["crush", "dance", "neon", "summer", "pop", "sparkle", "fun"]
        }
    }

    var energy: ClosedRange<Double> {
        switch self {
        case .fountain: 0.12...0.52
        case .quill: 0.22...0.68
        case .glitter: 0.48...0.95
        }
    }

    var valence: ClosedRange<Double> {
        switch self {
        case .fountain: 0.10...0.55
        case .quill: 0.08...0.48
        case .glitter: 0.45...0.95
        }
    }
}

enum AIEnergyLane: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case low
    case mid
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: String(localized: "지금 곡 따라가기")
        case .low: String(localized: "낮음")
        case .mid: String(localized: "중간")
        case .high: String(localized: "높음")
        }
    }

    var range: ClosedRange<Double>? {
        switch self {
        case .automatic: nil
        case .low: 0.05...0.42
        case .mid: 0.35...0.68
        case .high: 0.62...1.0
        }
    }
}

enum AILyricLanguage: String, CaseIterable, Identifiable, Sendable {
    case any
    case ko
    case en
    case ja

    var id: String { rawValue }

    var title: String {
        switch self {
        case .any: String(localized: "상관없음")
        case .ko: String(localized: "한국어")
        case .en: String(localized: "영어")
        case .ja: String(localized: "일본어")
        }
    }

    var codes: [String] {
        switch self {
        case .any: []
        case .ko: ["ko", "kr", "korean", "한국어"]
        case .en: ["en", "english", "영어"]
        case .ja: ["ja", "jp", "japanese", "일본어"]
        }
    }
}

struct AIRecommendationProfile: Equatable, Codable, Sendable {
    var moods: [String]
    var preferredArtists: [String]
    var avoidedArtists: [String]
    var language: String
    var useListenCount: Bool
    var useFavorites: Bool
    var useFrequent: Bool
    var pens: [String]
    var energyLane: String
    var vocal: String
    var stayOnAlbum: Bool

    static let storageKey = "ai-recommendation-profile"

    static let unset = AIRecommendationProfile(
        moods: [],
        preferredArtists: [],
        avoidedArtists: [],
        language: AILyricLanguage.any.rawValue,
        useListenCount: true,
        useFavorites: true,
        useFrequent: true,
        pens: [],
        energyLane: AIEnergyLane.automatic.rawValue,
        vocal: "",
        stayOnAlbum: true
    )

    static func load(defaults: UserDefaults = .standard) -> AIRecommendationProfile {
        guard let data = defaults.data(forKey: storageKey),
              var value = try? JSONDecoder().decode(AIRecommendationProfile.self, from: data) else {
            return .unset
        }
        value.sanitize()
        return value
    }

    func save(defaults: UserDefaults = .standard) {
        var value = self
        value.sanitize()
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    mutating func sanitize() {
        moods = unique(moods, limit: 3)
        preferredArtists = unique(preferredArtists, limit: 3)
        avoidedArtists = unique(avoidedArtists, limit: 5)
        pens = unique(pens, limit: 3)
        if AILyricLanguage(rawValue: language) == nil {
            language = AILyricLanguage.any.rawValue
        }
        if AIEnergyLane(rawValue: energyLane) == nil {
            energyLane = AIEnergyLane.automatic.rawValue
        }
    }

    var selectedMoods: [AILyricMood] {
        moods.compactMap(AILyricMood.init(rawValue:))
    }

    var selectedPens: [TaylorPenStyle] {
        pens.compactMap(TaylorPenStyle.init(rawValue:))
    }

    var selectedLanguage: AILyricLanguage {
        AILyricLanguage(rawValue: language) ?? .any
    }

    var selectedEnergy: AIEnergyLane {
        AIEnergyLane(rawValue: energyLane) ?? .automatic
    }

    func promptAppendix() -> String {
        var lines: [String] = []
        let moodTitles = selectedMoods.map(\.title)
        if !moodTitles.isEmpty {
            lines.append("Preferred lyric feelings: \(moodTitles.joined(separator: ", "))")
        }
        if !preferredArtists.isEmpty {
            lines.append("Prefer artists: \(preferredArtists.joined(separator: ", "))")
        }
        if !avoidedArtists.isEmpty {
            lines.append("Avoid artists: \(avoidedArtists.joined(separator: ", "))")
        }
        if selectedLanguage != .any {
            lines.append("Prefer language: \(selectedLanguage.title)")
        }
        if !selectedPens.isEmpty {
            lines.append(
                "Taylor writing pens: \(selectedPens.map(\.title).joined(separator: ", "))"
            )
        }
        if selectedEnergy != .automatic {
            lines.append("Energy lane: \(selectedEnergy.title)")
        }
        if !vocal.isEmpty {
            lines.append("Vocal: \(vocal)")
        }
        if stayOnAlbum {
            lines.append("Prefer finishing the current album when the seed still belongs there.")
        }
        return lines.joined(separator: "\n")
    }

    func score(song: Song, signature: LyricSignature?) -> Double {
        var value = 0.0
        let artist = LyricLexicalEmbedding.normalized(song.artist)
        if preferredArtists.contains(where: {
            artist.contains(LyricLexicalEmbedding.normalized($0))
                || LyricLexicalEmbedding.normalized($0).contains(artist)
        }) {
            value += 0.22
        }
        if avoidedArtists.contains(where: {
            artist.contains(LyricLexicalEmbedding.normalized($0))
                || LyricLexicalEmbedding.normalized($0).contains(artist)
        }) {
            value -= 0.55
        }
        if let signature {
            let moodTokens = Set(selectedMoods.flatMap(\.tokens).map(LyricLexicalEmbedding.normalized))
            if !moodTokens.isEmpty {
                let have = Set(signature.moodKeys + signature.themeKeys)
                value += min(0.24, Double(have.intersection(moodTokens).count) * 0.08)
            }
            let penTokens = Set(selectedPens.flatMap(\.tokens).map(LyricLexicalEmbedding.normalized))
            if !penTokens.isEmpty {
                let blob = Set(
                    (signature.moodKeys + signature.themeKeys + [signature.summary])
                        .map(LyricLexicalEmbedding.normalized)
                )
                let hits = penTokens.filter { token in
                    blob.contains { $0.contains(token) }
                }
                value += min(0.18, Double(hits.count) * 0.05)
                if let first = selectedPens.first {
                    if first.energy.contains(signature.energy) { value += 0.06 }
                    if first.valence.contains(signature.valence) { value += 0.05 }
                }
            }
            if let range = selectedEnergy.range {
                if range.contains(signature.energy) { value += 0.08 }
                else { value -= 0.06 }
            }
            if !vocal.isEmpty {
                let have = LyricLexicalEmbedding.normalized(signature.details.vocalGender)
                if have == LyricLexicalEmbedding.normalized(vocal) { value += 0.10 }
                else if !have.isEmpty { value -= 0.06 }
            }
            if selectedLanguage != .any {
                let language = LyricLexicalEmbedding.normalized(signature.details.language)
                if selectedLanguage.codes.contains(where: { language.contains($0) }) {
                    value += 0.10
                } else if !language.isEmpty {
                    value -= 0.08
                }
            }
        }
        return max(-1, min(1, value))
    }

    func applied(to weights: RecommendationWeights) -> RecommendationWeights {
        var next = weights
        if !useFavorites {
            next.favorites = 0
            next.forgottenFavorites = 0
        }
        if !useFrequent {
            next.repeatListening = 0
        }
        if !useListenCount {
            next.history *= 0.18
            next.behavior *= 0.22
            next.completion *= 0.35
        }
        return next
    }

    private func unique(_ values: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = LyricLexicalEmbedding.normalized(trimmed)
            guard !trimmed.isEmpty, seen.insert(key).inserted else { continue }
            result.append(trimmed)
            if result.count == limit { break }
        }
        return result
    }
}
