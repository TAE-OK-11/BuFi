import Foundation

struct LyricDetailProfile: Codable, Equatable, Sendable {
    var moods: [String] = []
    var themes: [String] = []
    var energy: Double = 0.5
    var valence: Double = 0.5
    var summary: String = ""
    var season: String = ""
    var dayparts: [String] = []
    var style: String = ""
    var content: String = ""
    var setting: String = ""
    var tempo: Double = 0.5
    var intimacy: Double = 0.5
    var narrative: String = ""
    var weather: String = ""
    var social: String = ""
    var color: String = ""
    var vocal: String = ""
    var vocalGender: String = ""
    var genre: String = ""
    var language: String = ""
    var emotionIntensity: Double = 0.5
    var listenContext: String = ""

    enum CodingKeys: String, CodingKey {
        case moods, themes, energy, valence, summary, season, dayparts
        case style, content, setting, tempo, intimacy, narrative, weather
        case social, color, vocal, vocalGender, genre, language
        case emotionIntensity, listenContext
    }

    static let empty = LyricDetailProfile()

    func withBasics(
        moods: [String],
        themes: [String],
        energy: Double,
        valence: Double,
        summary: String
    ) -> LyricDetailProfile {
        var value = self
        if value.moods.isEmpty { value.moods = moods }
        if value.themes.isEmpty { value.themes = themes }
        if value.energy == 0.5 { value.energy = energy }
        if value.valence == 0.5 { value.valence = valence }
        if value.summary.isEmpty { value.summary = summary }
        return value
    }

    var hasExtendedFields: Bool {
        !season.isEmpty
            || !dayparts.isEmpty
            || !style.isEmpty
            || !content.isEmpty
            || !listenContext.isEmpty
    }

    var tagBlob: String {
        [
            moods, themes, dayparts,
            [season, style, content, setting, narrative, weather, social, color, vocal, vocalGender, genre, language, listenContext]
        ]
        .flatMap { $0 }
        .joined(separator: " ")
    }

    func matches(hour: Int, month: Int) -> Double {
        var score = 0.0
        let daypart: String
        switch hour {
        case 5..<11: daypart = "morning"
        case 11..<17: daypart = "afternoon"
        case 17..<21: daypart = "evening"
        default: daypart = "night"
        }
        if dayparts.contains(daypart) { score += 0.62 }
        let currentSeason: String
        switch month {
        case 3...5: currentSeason = "spring"
        case 6...8: currentSeason = "summer"
        case 9...11: currentSeason = "autumn"
        default: currentSeason = "winter"
        }
        if season == "any" || season == currentSeason { score += 0.38 }
        return min(1, score)
    }
}

extension LyricDetailProfile {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        moods = try container.decodeIfPresent([String].self, forKey: .moods) ?? []
        themes = try container.decodeIfPresent([String].self, forKey: .themes) ?? []
        energy = try container.decodeIfPresent(Double.self, forKey: .energy) ?? 0.5
        valence = try container.decodeIfPresent(Double.self, forKey: .valence) ?? 0.5
        summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
        season = try container.decodeIfPresent(String.self, forKey: .season) ?? ""
        dayparts = try container.decodeIfPresent([String].self, forKey: .dayparts) ?? []
        style = try container.decodeIfPresent(String.self, forKey: .style) ?? ""
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        setting = try container.decodeIfPresent(String.self, forKey: .setting) ?? ""
        tempo = try container.decodeIfPresent(Double.self, forKey: .tempo) ?? 0.5
        intimacy = try container.decodeIfPresent(Double.self, forKey: .intimacy) ?? 0.5
        narrative = try container.decodeIfPresent(String.self, forKey: .narrative) ?? ""
        weather = try container.decodeIfPresent(String.self, forKey: .weather) ?? ""
        social = try container.decodeIfPresent(String.self, forKey: .social) ?? ""
        color = try container.decodeIfPresent(String.self, forKey: .color) ?? ""
        vocal = try container.decodeIfPresent(String.self, forKey: .vocal) ?? ""
        vocalGender = try container.decodeIfPresent(String.self, forKey: .vocalGender) ?? ""
        genre = try container.decodeIfPresent(String.self, forKey: .genre) ?? ""
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? ""
        emotionIntensity = try container.decodeIfPresent(
            Double.self,
            forKey: .emotionIntensity
        ) ?? 0.5
        listenContext = try container.decodeIfPresent(
            String.self,
            forKey: .listenContext
        ) ?? ""
    }
}
