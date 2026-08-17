import Foundation

enum ArtistPersonaGender: String, Sendable {
    case male
    case female
    case mixed
    case unknown
}

enum ArtistPersonaFormation: String, Sendable {
    case solo
    case group
    case unknown
}

struct ArtistPersona: Equatable, Sendable {
    var gender: ArtistPersonaGender
    var formation: ArtistPersonaFormation

    static let unknown = ArtistPersona(gender: .unknown, formation: .unknown)

    var isMaleLeaning: Bool { gender == .male }
    var isFemaleLeaning: Bool { gender == .female }

    var complementaryGender: ArtistPersonaGender? {
        switch gender {
        case .male: .female
        case .female: .male
        case .mixed, .unknown: nil
        }
    }
}

enum ArtistPersonaResolver {
    static func infer(
        artist: String,
        genres: [String] = [],
        moods: [String] = [],
        tags: [String] = []
    ) -> ArtistPersona {
        let tokens = (tags + genres + moods + [artist])
            .map(normalized)
            .filter { !$0.isEmpty }
        let blob = tokens.joined(separator: " ")
        let padded = " \(blob) "

        var maleHits = tokenHits(
            blob,
            [
                "boy group", "boygroup", "boy band", "boyband",
                "male vocalist", "male vocalists", "k-pop boy",
                "namdol", "보이그룹", "남돌", "남자아이돌", "남자 아이돌"
            ]
        )
        var femaleHits = tokenHits(
            blob,
            [
                "girl group", "girlgroup", "girl band", "girlband",
                "female vocalist", "female vocalists", "k-pop girl",
                "yeodol", "걸그룹", "여돌", "여자아이돌", "여자 아이돌"
            ]
        )
        if padded.contains(" male ") { maleHits += 2 }
        if padded.contains(" female ") { femaleHits += 2 }
        let groupHits = tokenHits(
            blob,
            ["group", "band", "그룹", "밴드", "아이돌", "idol"]
        )
        let soloHits = tokenHits(
            blob,
            ["solo", "singer-songwriter", "솔로"]
        )

        let gender: ArtistPersonaGender
        if maleHits > femaleHits + 0 {
            gender = maleHits >= 1 ? .male : .unknown
        } else if femaleHits > maleHits {
            gender = .female
        } else if maleHits > 0, femaleHits > 0 {
            gender = .mixed
        } else {
            gender = .unknown
        }

        let formation: ArtistPersonaFormation
        if groupHits > soloHits, groupHits > 0 {
            formation = .group
        } else if soloHits > groupHits, soloHits > 0 {
            formation = .solo
        } else if maleHits + femaleHits > 0, blob.contains("group")
                    || blob.contains("그룹") {
            formation = .group
        } else {
            formation = .unknown
        }
        return ArtistPersona(gender: gender, formation: formation)
    }

    static func dominantLane(from songs: [Song]) -> ArtistPersona {
        var male = 0
        var female = 0
        var group = 0
        var solo = 0
        for song in songs.prefix(16) {
            let persona = ArtistPersonaCache.shared.resolved(
                artist: song.artist,
                genres: ([song.genre].compactMap { $0 }
                    + (song.genres ?? []).map(\.name)),
                moods: song.moods ?? []
            )
            if persona.isMaleLeaning { male += 1 }
            if persona.isFemaleLeaning { female += 1 }
            if persona.formation == .group { group += 1 }
            if persona.formation == .solo { solo += 1 }
        }
        let gender: ArtistPersonaGender
        if male >= female + 2 {
            gender = .male
        } else if female >= male + 2 {
            gender = .female
        } else if male + female == 0 {
            gender = .unknown
        } else {
            gender = .mixed
        }
        return ArtistPersona(
            gender: gender,
            formation: group > solo ? .group : (solo > group ? .solo : .unknown)
        )
    }

    private static func tokenHits(_ blob: String, _ needles: [String]) -> Int {
        needles.reduce(0) { count, needle in
            blob.contains(normalized(needle)) ? count + 1 : count
        }
    }

    static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Process-local Last.fm / heuristic persona cache. Mix scoring stays
/// synchronous, so network-fetched tags land here before the next rank pass.
final class ArtistPersonaCache: @unchecked Sendable {
    static let shared = ArtistPersonaCache()

    private let lock = NSLock()
    private var values: [String: ArtistPersona] = [:]

    func resolved(
        artist: String,
        genres: [String] = [],
        moods: [String] = []
    ) -> ArtistPersona {
        let key = ArtistPersonaResolver.normalized(artist)
        guard !key.isEmpty else { return .unknown }
        lock.lock()
        if let stored = values[key] {
            lock.unlock()
            return stored
        }
        lock.unlock()
        let inferred = ArtistPersonaResolver.infer(
            artist: artist,
            genres: genres,
            moods: moods
        )
        if inferred != .unknown {
            store(inferred, for: artist)
        }
        return inferred
    }

    func store(_ persona: ArtistPersona, for artist: String) {
        let key = ArtistPersonaResolver.normalized(artist)
        guard !key.isEmpty, persona != .unknown else { return }
        lock.lock()
        if let existing = values[key] {
            values[key] = ArtistPersona(
                gender: persona.gender == .unknown ? existing.gender : persona.gender,
                formation: persona.formation == .unknown
                    ? existing.formation
                    : persona.formation
            )
        } else {
            values[key] = persona
        }
        lock.unlock()
    }
}
