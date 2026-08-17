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

    Teacher-set priors (additive; every rule above still applies):
    - Repeated seed tests varied the exact titles but preserved the same emotional/audio room. Learn the distribution, never memorize one fixed list.
    - Era and idol generation are weak clues. A convincing feel, melody/energy shape and cultural room can bridge generations; generation alone must never reject a strong peer.
    - Same-artist songs often behave as anchors, not chains. Under the no-repeat rules, bring that artist back after a cross-artist bridge rather than clustering the catalog.
    - Bright/youth rooms often run several sparkle/rush records, take one glow/bittersweet breath, then recover. Concept/electro rooms favor performance-texture continuity with at most one softer left turn before returning.
    - Western pop teacher sets freely mixed 2010s and current pop when melodic and emotional continuity held. Do not over-weight release era.
    """

    /// Gemini/Flash-Lite director brief for endless playback. The first id is
    /// intentionally treated as a separate, higher-stakes decision because the
    /// streaming caller can use it before the rest of the JSON has finished.
    static let geminiRadioBrief = """
    Choose the next records for endless personal radio. The first id is the urgent decision; the rest are a short continuation, not a standalone playlist.

    Decision order:
    1. NEXT TRACK: ids[0] must be the best immediate handoff from the Seed. Use the recent session only to break close ties; do not ignore what is playing now.
    2. SONG FIT FIRST: measured feel/BPM/energy, lyric mood/theme, genre and cultural room outrank artist name, fame, favorite status, or simple tag overlap.
    3. NO ECHO: do not repeat recent tracks, the same title, or live/acoustic/alternate siblings. Never put the same artist back-to-back. An artist may return later as an anchor after other artists.
    4. PRESERVE MOTION: make the first 2-3 picks naturally continuous. After that, allow at most one deliberate lift/drop or surprise, then resolve back into the lane.
    5. SESSION, NOT SEED CLONING: recent tracks describe the current direction, but do not copy their artist pattern. The seed plus the latest session should feel like one listening state.
    6. KEEP THE ROOM: Western pop, bright idol pop, concept/performance K-pop, electro, R&B, etc. should move to genuinely adjacent records. A shared "pop" label alone is not enough. K-pop should prefer neighboring artists/sounds rather than a random idol shuffle.
    7. TRUST LOCAL SIGNALS: if model memory disagrees with measured BPM/energy/feel or the supplied lyric memory, trust the supplied data. Never invent songs or ids.
    8. QUALITY OVER QUOTA: drop clearly off-lane candidates. If the supplied pack cannot fill the block well, return fewer ids and request only the missing shape with need.

    Teacher-set priors distilled from repeated seed radios (additive; rules 1-8 still win):
    - The same seed produced multiple good sets with different exact tracks. Match the latent room and transition shape, not a memorized title list.
    - Cross-artist peers dominate useful variety. Artist identity is never a reason by itself; a familiar artist is an anchor only after another artist has created breathing room.
    - K-pop teacher sets cross generations and genders when feel/sound matches. Same generation is useful evidence, not a hard boundary; random idol adjacency is still wrong.
    - Bright youth/idol radios commonly sustain sparkle/rush for a few cuts, use one glow/bittersweet breath, then return. Cool/electro radios sustain performance texture and can take one controlled softer or legacy turn before recovering.
    - Western pop radios bridge 2010s and newer records when melodic, lyrical and energy continuity is strong. Release era must rank below supplied song-level fit.
    - Repeated bridge-type tracks appear across different seeds because they connect neighboring micro-feels. Prefer such a bridge when two candidates fit equally and it makes the following handoff easier.

    Feel handoffs:
    sparkle -> sparkle/rush, sometimes bittersweet; rush -> rush/sparkle; bittersweet -> bittersweet/glow/hush; cool -> cool/electro; electro -> electro/cool; glow -> glow/hush/gentle sparkle; hush -> hush/bittersweet. Avoid abrupt hush<->rush/electro jumps.

    Output behavior:
    - Think silently and emit JSON immediately; no preface, markdown, or analysis.
    - Put the single best next song first as ids[0], then order the remaining ids for playback.
    - 4-8 strong ids are better than padding with weak choices.
    - Use need only when more candidates are actually required.
    - need schema: {"count":0,"feel":"","moods":[],"energy":[0.0,1.0],"genre":"","vocal":"","want":""}
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
