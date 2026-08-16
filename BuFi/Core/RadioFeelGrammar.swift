import Foundation

/// Distilled from observed personal-radio sets: after a seed of one feel,
/// the next tracks stay in that cultural room and walk related feels.
/// This is a placement grammar, not a song list.
enum RadioFeel: String, CaseIterable, Sendable {
    case sparkle
    case rush
    case bittersweet
    case cool
    case electro
    case glow
    case hush
}

enum RadioFeelGrammar {
    static func feel(
        song: Song,
        signature: LyricSignature?
    ) -> RadioFeel {
        let energy = SoundFeatureExtractor.energy(song: song, signature: signature)
        let valence = signature?.valence ?? 0.5
        let intimacy = signature?.details.intimacy ?? 0.5
        let blob = blob(song: song, signature: signature)
        let kpop = RadioContinuity.isKPop(song: song, signature: signature)
        if matches(blob, ["electro", "hyperpop", "synth", "whiplash", "cyber", "edm"]) {
            return .electro
        }
        if matches(blob, ["girlcrush", "girl crush", "concept", "attitude", "swagger", "y2k"])
            || (kpop && energy >= 0.55 && valence <= 0.55 && intimacy < 0.55) {
            return .cool
        }
        if energy <= 0.32 || intimacy >= 0.78 || matches(blob, ["ballad", "letter", "whisper"]) {
            return .hush
        }
        if valence <= 0.38 || matches(
            blob,
            ["yearning", "breakup", "그리움", "이별", "nostalg", "lonely", "bittersweet"]
        ) {
            return energy >= 0.42 ? .bittersweet : .hush
        }
        if energy >= 0.72 || matches(blob, ["hype", "anthem", "festival", "workout"]) {
            return .rush
        }
        if matches(blob, ["vocal", "r&b", "rnb", "soul"]) && energy <= 0.55 {
            return .glow
        }
        if kpop && energy >= 0.48 {
            return valence >= 0.55 ? .sparkle : .cool
        }
        if energy >= 0.48 && valence >= 0.48 {
            return .sparkle
        }
        return energy >= 0.58 ? .rush : .glow
    }

    /// After `from`, how right `to` feels as the next record.
    static func placement(
        from: Song,
        to: Song,
        lyricIndex: LyricSignatureIndex
    ) -> Double {
        let left = lyricIndex.bySongID[from.id]
        let right = lyricIndex.bySongID[to.id]
        let a = feel(song: from, signature: left)
        let b = feel(song: to, signature: right)
        var value = nextScore(from: a, to: b)
        if RadioContinuity.isKPop(song: from, signature: left)
            != RadioContinuity.isKPop(song: to, signature: right) {
            value -= 0.28
        }
        let bpm = SoundFeatureExtractor.closeness(
            left: SoundFeatureExtractor.bpm(song: from, signature: left),
            right: SoundFeatureExtractor.bpm(song: to, signature: right)
        )
        value += bpm * 0.12
        return max(0, min(1, value))
    }

    static func nextScore(from: RadioFeel, to: RadioFeel) -> Double {
        if from == to { return 0.78 }
        switch (from, to) {
        case (.sparkle, .rush), (.rush, .sparkle): return 0.86
        case (.sparkle, .bittersweet), (.bittersweet, .sparkle): return 0.80
        case (.sparkle, .glow), (.glow, .sparkle): return 0.58
        case (.rush, .cool), (.cool, .rush): return 0.64
        case (.rush, .electro), (.electro, .rush): return 0.70
        case (.bittersweet, .glow), (.glow, .bittersweet): return 0.80
        case (.bittersweet, .hush), (.hush, .bittersweet): return 0.82
        case (.cool, .electro), (.electro, .cool): return 0.88
        case (.cool, .bittersweet), (.bittersweet, .cool): return 0.60
        case (.glow, .hush), (.hush, .glow): return 0.76
        case (.sparkle, .cool), (.cool, .sparkle): return 0.42
        case (.sparkle, .electro), (.electro, .sparkle): return 0.28
        case (.hush, .rush), (.rush, .hush): return 0.12
        case (.hush, .electro), (.electro, .hush): return 0.08
        case (.glow, .electro), (.electro, .glow): return 0.34
        default: return 0.36
        }
    }

    /// Compact English grammar for shorter models.
    static let promptAppendix = """
    Placement grammar (feel after feel — not similar-song matching):
    - sparkle (bright crush/teen pop): next sparkle or rush. A bittersweet cut every few songs is texture, then return. Do not slam electro or hush.
    - rush (anthem/festival): stay rush or sparkle. Cool/electro only if the seed already lives there.
    - bittersweet (almost-love, night pop): another bittersweet or back to sparkle/glow. Not a club drop.
    - cool (stylish concept / girl-crush / performance): next cool or electro. Same cultural lineage (idol generations that share that room). One glow-vocal breather is fine.
    - electro (high-concept dance): stay electro/cool. Same-artist sisters are welcome. Dance-heavy peers only — not cute sparkle.
    - glow (soft vocal / R&B): glow, hush, or a gentle sparkle lift.
    - hush (quiet letter): hush or bittersweet. Never rush/electro next.

    After the seed, the first pick is usually a sister-feel peer or a same-artist different recording, not a clone.
    Keep the cultural room: Western teen-pop stays there; bright 4th-gen idol stays there; concept/performance K-pop stays there. Shared "pop" tags are not a room change.
    Same artist can return every few songs as an anchor. Do not run three in a row.
    After three to five high-energy cuts, allow one softer breath, then come back.
    """

    /// Longer Gemini director brief. Teaches rooms and handoffs from observed
    /// personal-radio sets without naming those catalogs as a playlist to copy.
    static let geminiRadioBrief = """
    Program a short personal radio block. You have taste and freedom inside these rules only.

    Rules:
    1. Sequence a listen, not a similarity list. The next song should feel inevitable, not copied.
    2. Stay in the seed's cultural room (Western pop radio vs bright idol crush vs concept/performance K-pop vs high-concept electro). "Pop" as a tag is not a room change.
    3. K-pop walks to similar adjacent artists — same generation or neighboring sound — not a random idol shuffle.
    4. Use feel, lyric memory, excerpts, BPM, and your own knowledge of the titles. Thin cards: infer from what you know. Never invent ids.
    5. Same artist+title is one recording. Do not park live/acoustic next to the original. Same artist may return later; do not run three in a row.
    6. You may lift, drop, or surprise once if it still belongs. Do not jerk the body or flip the story for no reason.
    7. Drop off-lane candidates. If you still need songs, ask with need weights. Fewer than the requested count is fine.

    need example:
    {"ids":["id"],"need":{"count":3,"feel":"sparkle","moods":["yearning"],"energy":[0.4,0.7],"genre":"k-pop","vocal":"female","want":"adjacent artists in the same room"}}
    """

    private static func blob(song: Song, signature: LyricSignature?) -> String {
        LyricLexicalEmbedding.normalized(
            [
                song.title,
                song.genre,
                song.genres?.map(\.name).joined(separator: " "),
                signature?.moods.joined(separator: " "),
                signature?.themes.joined(separator: " "),
                signature?.details.tagBlob,
                signature?.soundLabels.joined(separator: " "),
                signature?.summary
            ].compactMap { $0 }.joined(separator: " ")
        )
    }

    private static func matches(_ blob: String, _ tokens: [String]) -> Bool {
        tokens.contains { blob.contains(LyricLexicalEmbedding.normalized($0)) }
    }
}
