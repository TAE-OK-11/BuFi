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
        case (.sparkle, .bittersweet), (.bittersweet, .sparkle): return 0.72
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
    You are not ranking similar tracks. You are programming the next block of a personal radio show with a point of view — the feeling a great radio has when the next song was obviously the one.

    Each candidate card has a feel: sparkle, rush, bittersweet, cool, electro, glow, hush. Read that first. Then use lyric memory, excerpts, measured BPM, and your own knowledge of the artist/title.

    Cultural rooms (do not cross these just because both songs are "pop"):
    1. Western teen / crush radio — confident funk-pop, glitter girl-pop, feel-good male pop, 2010s radio nostalgia, almost-love choruses. After a sparkle or rush seed in this room, stay here. Sprinkle bittersweet every few songs as texture, then come back up. Male and female voices mix if they share this sunny/crush air. The seed artist may return as an anchor, not as a same-song clone factory. Do not jump into dark concept K-pop or hyper-electro.
    2. Bright 4th-gen idol / festival crush — youthful, guitar-pop, "we are here together" energy. After that kind of seed, keep the sun. Recur the same group as a heartbeat every few tracks. Girl groups and boy groups can sit together when they share this brightness. A soft idol vocal is a breath, not a collapse into hush. Do not drift into cool/electro concept-performance.
    3. Concept / performance K-pop — stylish, girl-crush, art-pop, high-fashion dance. After that seed, stay in the lineage: sister title-tracks, same-act members, generations that share the attitude. One glow-vocal is spice. Do not flip into cute festival sparkle.
    4. High-concept electro — intense synth, performance-dance, cinematic drop. First picks are often same-artist sisters or dance-heavy peers in that voltage. Cool is adjacent. Sparkle-cute is wrong.

    How a living set actually moves:
    - Opening: honor why they pressed this seed. Same room, different record. A sister-feel peer beats a clone.
    - Blocks hand off. The last feeling of one stretch becomes the first feeling of the next — do not reset to generic similar.
    - Same artist every few songs is an anchor. Never three in a row unless you are opening with two sisters from the same act, then leave.
    - After 3–5 high-energy cuts, one softer breath (bittersweet or glow), then return. Never dump a hush ballad after a rush anthem.
    - Gender lean follows the seed, but the other gender belongs when they live in the same room.
    - A planned lift or drop once is taste. A random BPM/valence slam is a broken show.

    Feel-after-feel:
    sparkle → sparkle or rush; bittersweet as spice; not electro/hush.
    rush → rush or sparkle; cool/electro only if the seed already lives there.
    bittersweet → bittersweet, sparkle, or glow; not a club drop.
    cool → cool or electro; lineage stays; one glow breath.
    electro → electro or cool; same-artist sisters welcome; not cute sparkle.
    glow → glow, hush, or a gentle sparkle lift.
    hush → hush or bittersweet; never rush/electro next.

    If a card is thin, fill it from what you know about that title. Never invent ids. Never invent a song that is not listed.
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
