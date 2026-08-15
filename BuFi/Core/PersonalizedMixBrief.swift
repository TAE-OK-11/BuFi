import Foundation

/// Creative brief I wrote for each home mix. Song picking and the LLM
/// both stay inside this lane instead of inventing a new mood every time.
struct PersonalizedMixBrief: Hashable, Sendable {
    var mood: String
    var theme: String
    var audioFeel: String
    var tokens: [String]
    var energy: ClosedRange<Double>
    var valence: ClosedRange<Double>
    var vocals: [String]
    var seasons: [String]
    var dayparts: [String]

    func score(
        song: Song,
        signature: LyricSignature?,
        searchableText: String
    ) -> Double {
        var score = 0.0
        let text = LyricLexicalEmbedding.normalized(searchableText)
        let hits = tokens.reduce(into: 0) { count, token in
            if text.contains(LyricLexicalEmbedding.normalized(token)) {
                count += 1
            }
        }
        if !tokens.isEmpty {
            score += min(1, Double(hits) / Double(min(6, tokens.count))) * 0.34
        }
        if let signature {
            let moodHits = Set(signature.moods.map(LyricLexicalEmbedding.normalized))
                .intersection(Set(tokens.map(LyricLexicalEmbedding.normalized)))
            score += min(0.22, Double(moodHits.count) * 0.08)
            let themeHits = Set(signature.themes.map(LyricLexicalEmbedding.normalized))
                .intersection(Set(tokens.map(LyricLexicalEmbedding.normalized)))
            score += min(0.16, Double(themeHits.count) * 0.06)
            if energy.contains(signature.energy) { score += 0.14 }
            else { score -= min(0.12, abs(signature.energy - energy.lowerBound)) }
            if valence.contains(signature.valence) { score += 0.12 }
            if vocals.contains(where: {
                LyricLexicalEmbedding.normalized(signature.details.vocalGender)
                    .contains(LyricLexicalEmbedding.normalized($0))
                    || LyricLexicalEmbedding.normalized(signature.details.vocal)
                        .contains(LyricLexicalEmbedding.normalized($0))
            }) {
                score += 0.10
            }
            if seasons.contains(signature.details.season)
                || signature.details.season == "any" {
                score += 0.06
            }
            if !Set(dayparts).isDisjoint(with: Set(signature.details.dayparts)) {
                score += 0.08
            }
            let sound = signature.soundLabels.joined(separator: " ").lowercased()
            if audioFeel.lowercased().contains("킥"), sound.contains("drum") {
                score += 0.04
            }
            if audioFeel.contains("보컬"),
               sound.contains("sing") || sound.contains("vocal") {
                score += 0.05
            }
        }
        if let genre = song.genre, tokens.contains(where: {
            LyricLexicalEmbedding.normalized(genre)
                .contains(LyricLexicalEmbedding.normalized($0))
        }) {
            score += 0.10
        }
        return max(0, min(1, score))
    }
}

enum PersonalizedMixCatalog {
    static func brief(
        forKind kind: PersonalizedMix.Kind,
        mixID: String,
        artist: String = "",
        hour: Int = 12,
        month: Int = 6
    ) -> PersonalizedMixBrief {
        switch kind {
        case .daylist:
            return daylist(hour: hour, month: month)
        case .repeatListening:
            return PersonalizedMixBrief(
                mood: "이미 몸이 기억하는 친숙함",
                theme: "습관처럼 손이 가는 곡",
                audioFeel: "완성된 훅, 익숙한 음색, 바로 따라 부를 수 있는 멜로디",
                tokens: ["hook", "chorus", "repeat", "familiar", "favorite", "히트", "후렴"],
                energy: 0.35...0.85,
                valence: 0.30...0.90,
                vocals: ["soft", "powerful"],
                seasons: ["any"],
                dayparts: ["morning", "afternoon", "evening", "night"]
            )
        case .listenAgain:
            return PersonalizedMixBrief(
                mood: "아직 안 식은 여운",
                theme: "최근에 열린 취향의 문을 조금 더 밀어보기",
                audioFeel: "방금 들은 결의 연장 — 비슷한 템포와 보컬 거리",
                tokens: ["recent", "again", "continue", "echo", "잔향", "여운"],
                energy: 0.25...0.80,
                valence: 0.20...0.85,
                vocals: ["soft", "powerful"],
                seasons: ["any"],
                dayparts: dayparts(for: hour)
            )
        case .genre:
            if mixID.contains("k-pop") {
                return PersonalizedMixBrief(
                    mood: "무대 위에서 터지는 텐션",
                    theme: "훅이 보이고 안무가 그려지는 K-Pop",
                    audioFeel: "또렷한 보컬 스택, 전자음과 퍼커션, 섹션이 자주 바뀌는 편곡",
                    tokens: ["k-pop", "kpop", "korean pop", "케이팝", "idol"],
                    energy: 0.45...0.95,
                    valence: 0.35...0.95,
                    vocals: ["powerful", "choir", "soft"],
                    seasons: ["any"],
                    dayparts: ["afternoon", "evening"]
                )
            }
            return PersonalizedMixBrief(
                mood: "또렷하고 열린 기분",
                theme: "라디오에서 살아남는 멜로디",
                audioFeel: "클린 보컬, 4박 팝 드럼, 밝은 기타와 신스",
                tokens: ["pop", "팝", "melody", "radio", "chorus"],
                energy: 0.40...0.85,
                valence: 0.40...0.95,
                vocals: ["soft", "powerful"],
                seasons: ["spring", "summer", "any"],
                dayparts: ["morning", "afternoon"]
            )
        case .artist:
            return PersonalizedMixBrief(
                mood: "그 사람의 중심 음색",
                theme: "\(artist.isEmpty ? "이 아티스트" : artist)의 세계와 맞닿은 곡",
                audioFeel: "같은 보컬 질감, 비슷한 밴드와 프로덕션 결",
                tokens: artist.isEmpty ? ["artist"] : [artist],
                energy: 0.20...0.90,
                valence: 0.15...0.90,
                vocals: ["soft", "powerful", "rap"],
                seasons: ["any"],
                dayparts: ["morning", "afternoon", "evening", "night"]
            )
        case .mood:
            if mixID.hasPrefix("happy") {
                return happy
            }
            if mixID.hasPrefix("upbeat") {
                return upbeat
            }
            if mixID.hasPrefix("love") {
                return love
            }
            return chill
        case .favorites:
            return PersonalizedMixBrief(
                mood: "내가 골라 둔 애정",
                theme: "오래 남을 곡만 모아 둔 서랍",
                audioFeel: "취향의 정수 — 보컬이든 편곡이든 한 번은 마음을 찌른 소리",
                tokens: ["love", "favorite", "heart", "좋아요", "사랑"],
                energy: 0.15...0.95,
                valence: 0.10...0.95,
                vocals: ["soft", "powerful"],
                seasons: ["any"],
                dayparts: ["morning", "afternoon", "evening", "night"]
            )
        case .ranking:
            return PersonalizedMixBrief(
                mood: "반복해서 손이 가는 확신",
                theme: "가장 자주 울린 곡의 순위",
                audioFeel: "바로 재생 버튼이 눌리는 훅과 익숙한 도입부",
                tokens: ["top", "played", "hit", "repeat", "자주"],
                energy: 0.30...0.90,
                valence: 0.25...0.90,
                vocals: ["soft", "powerful"],
                seasons: ["any"],
                dayparts: ["morning", "afternoon", "evening", "night"]
            )
        }
    }

    static let happy = PersonalizedMixBrief(
        mood: "입꼬리가 올라가는 밝음",
        theme: "햇살, 주말, 가벼운 발걸음",
        audioFeel: "메이저 키, 밝은 기타와 신스, 힘 빼지 않은 경쾌한 보컬",
        tokens: ["happy", "smile", "joy", "sunshine", "summer", "disco", "funk", "행복", "여름"],
        energy: 0.50...0.95,
        valence: 0.62...1.00,
        vocals: ["soft", "powerful", "choir"],
        seasons: ["spring", "summer"],
        dayparts: ["morning", "afternoon"]
    )

    static let upbeat = PersonalizedMixBrief(
        mood: "심장이 조금 빨라지는 추진력",
        theme: "운동, 질주, 창문을 열고 달리는 밤",
        audioFeel: "강한 킥, 높은 BPM, 힘 있는 보컬과 전자 베이스",
        tokens: ["dance", "edm", "electronic", "rock", "hip hop", "upbeat", "workout", "댄스"],
        energy: 0.68...1.00,
        valence: 0.40...0.95,
        vocals: ["powerful", "rap"],
        seasons: ["any"],
        dayparts: ["morning", "afternoon", "evening"]
    )

    static let love = PersonalizedMixBrief(
        mood: "가슴이 뜨거워지거나 아려오는 밀착",
        theme: "고백, 그리움, 둘만의 방",
        audioFeel: "숨이 가까운 보컬, 발라드와 R&B, 따뜻한 중역",
        tokens: ["love", "romantic", "romance", "r&b", "soul", "ballad", "heart", "사랑"],
        energy: 0.18...0.65,
        valence: 0.20...0.80,
        vocals: ["soft", "powerful"],
        seasons: ["autumn", "winter", "spring"],
        dayparts: ["evening", "night"]
    )

    static let chill = PersonalizedMixBrief(
        mood: "어깨가 내려가는 고요",
        theme: "비 오는 창가, 늦은 방,  pensively walking",
        audioFeel: "낮은 에너지, 느린 템포, 공간감 있는 리버브와 부드러운 보컬",
        tokens: ["chill", "ambient", "acoustic", "jazz", "lo-fi", "indie", "calm", "잔잔", "밤"],
        energy: 0.08...0.48,
        valence: 0.15...0.70,
        vocals: ["soft"],
        seasons: ["autumn", "winter", "any"],
        dayparts: ["evening", "night"]
    )

    static func daylist(hour: Int, month: Int) -> PersonalizedMixBrief {
        let season: String
        switch month {
        case 3...5: season = "spring"
        case 6...8: season = "summer"
        case 9...11: season = "autumn"
        default: season = "winter"
        }
        if hour >= 5 && hour < 12 {
            return PersonalizedMixBrief(
                mood: "맑고 가벼운 출발",
                theme: "창을 열고 나가는 \(seasonName(season)) 아침",
                audioFeel: "밝은 보컬, 중간 템포, 어쿠스틱과 클린 팝",
                tokens: ["morning", "sunrise", "light", "walk", "coffee", "아침", "산책"],
                energy: 0.35...0.75,
                valence: 0.45...0.90,
                vocals: ["soft", "powerful"],
                seasons: [season, "any"],
                dayparts: ["morning"]
            )
        }
        if hour >= 12 && hour < 17 {
            return PersonalizedMixBrief(
                mood: "따뜻한 집중과 이동",
                theme: "낮의 잔광, 도시 한낮의 \(seasonName(season))",
                audioFeel: "소프트 신스, 또렷한 멜로디, 답답하지 않은 미드템포",
                tokens: ["afternoon", "drive", "sun", "city", "오후", "낮"],
                energy: 0.40...0.80,
                valence: 0.40...0.85,
                vocals: ["soft", "powerful"],
                seasons: [season, "any"],
                dayparts: ["afternoon"]
            )
        }
        if hour >= 17 && hour < 21 {
            return PersonalizedMixBrief(
                mood: "노을 이후의 여운",
                theme: "귀가길과 \(seasonName(season)) 황혼",
                audioFeel: "따뜻한 미드템포, 소프트 일렉, 숨이 조금 가까워지는 보컬",
                tokens: ["evening", "sunset", "gold", "home", "노을", "저녁"],
                energy: 0.28...0.70,
                valence: 0.30...0.80,
                vocals: ["soft", "powerful"],
                seasons: [season, "any"],
                dayparts: ["evening"]
            )
        }
        return PersonalizedMixBrief(
            mood: "고요하고 깊은 밤",
            theme: "불 끈 방, 혼자 남은 \(seasonName(season)) 하루",
            audioFeel: "낮은 볼륨, 느린 템포, 숨 가까운 보컬과 넓은 리버브",
            tokens: ["night", "midnight", "quiet", "rain", "sleep", "밤", "적막"],
            energy: 0.08...0.50,
            valence: 0.12...0.65,
            vocals: ["soft"],
            seasons: [season, "any"],
            dayparts: ["night"]
        )
    }

    private static func dayparts(for hour: Int) -> [String] {
        switch hour {
        case 5..<11: ["morning", "afternoon"]
        case 11..<17: ["afternoon", "evening"]
        case 17..<21: ["evening", "night"]
        default: ["night", "evening"]
        }
    }

    private static func seasonName(_ season: String) -> String {
        switch season {
        case "spring": "봄"
        case "summer": "여름"
        case "autumn": "가을"
        default: "겨울"
        }
    }
}
