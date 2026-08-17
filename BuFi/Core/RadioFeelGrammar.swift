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

        // The scan corpus showed that a raw `synth` label is far too common to
        // mean "electro" by itself. Require explicit electronic language, or a
        // genuinely high-energy synth + performance texture. This keeps normal
        // synth-pop from collapsing into one giant electro bucket.
        let explicitElectro = matches(
            blob,
            ["electro", "hyperpop", "cyber", "edm", "techno", "industrial"]
        )
        let synthTexture = matches(blob, ["synth", "synthesizer"])
        let performanceTexture = matches(
            blob,
            ["concept", "attitude", "swagger", "performance", "rapping", "dancefloor"]
        )
        if explicitElectro
            || (synthTexture && performanceTexture && energy >= 0.86 && intimacy < 0.62) {
            return .electro
        }

        if matches(
            blob,
            ["girlcrush", "girl crush", "concept", "attitude", "swagger", "y2k", "defiant", "rebell"]
        ) || (kpop && energy >= 0.64 && valence <= 0.48 && intimacy < 0.65) {
            return .cool
        }

        // Intimate lyrics are not automatically quiet music. Only let intimacy
        // force hush when the measured energy is actually soft.
        if energy <= 0.32
            || (intimacy >= 0.86 && energy < 0.50)
            || matches(blob, ["ballad", "whisper"]) {
            return .hush
        }

        let wounded = matches(
            blob,
            ["yearning", "breakup", "그리움", "이별", "lonely", "bittersweet", "melanch", "heartbreak", "sorrow"]
        )
        if valence <= 0.34 || (wounded && valence <= 0.52 && energy < 0.82) {
            return energy >= 0.44 ? .bittersweet : .hush
        }

        if energy >= 0.80
            || matches(blob, ["hype", "anthem", "festival", "workout", "euphoric"]) {
            return .rush
        }
        if matches(blob, ["vocal", "r&b", "rnb", "soul", "warm", "tender"])
            && energy <= 0.64 {
            return .glow
        }
        if kpop && energy >= 0.50 {
            return valence >= 0.55 ? .sparkle : .cool
        }
        if energy >= 0.50 && valence >= 0.50 {
            return .sparkle
        }
        return energy >= 0.66 ? .rush : .glow
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
    - cool (stylish concept / girl-crush / performance): next cool or electro. Same cultural lineage can cross idol generations. One glow-vocal breather is fine.
    - electro (high-concept dance): stay electro/cool. Same-artist sisters are welcome after breathing room. Dance-heavy peers only — not cute sparkle.
    - glow (soft vocal / R&B): glow, hush, or a gentle sparkle lift.
    - hush (quiet letter): hush or bittersweet. Never rush/electro next.

    Walk outward gradually. The next record should be reachable from the previous record, not merely similar to the original seed.
    Same artist is an anchor, not a chain. In the captured Spotify runs, mid-run adjacent same-artist placement was essentially absent; a strong same-artist first recommendation is a special opening exception. A seed artist often returns after about four intervening records.
    Exact titles vary strongly between repeated runs, so learn room, motion and artist cadence rather than one fixed list.
    """

    /// Gemini/Flash-Lite director brief for endless playback. This is purposely
    /// detailed: Gemini receives a 50-track feature-rich pack and programs a
    /// 20-track chapter while carrying the previous chat turn forward.
    static let geminiRadioBrief = """
    You are the music director of an ENDLESS personal radio. BuFi has already reduced the library to 50 plausible candidates using listening behavior, lyric analysis, measured audio features, freshness and catalog context. Your job is not to search the whole library. Your job is to choose and ORDER 20 of these candidates as the next continuous chapter.

    If the API message history contains the previous radio turn, this is the SAME station and the SAME conversation. Do not restart your reasoning from zero and do not snap back to the original seed. Continue the trajectory you established previously, using the newest Recent Playback and Current Seed as the local state of that same radio session.

    CORE IDEA — DIFFUSE, DO NOT TELEPORT:
    The radio should slowly spread away from what the listener is hearing. Start close. Move through neighboring songs. Let one song create permission for the next. A farther song can be excellent even if it is not a direct seed match, but only when the track before it makes the move natural. If A -> C is abrupt but A -> B -> C is convincing, B is the bridge. Diversity should emerge gradually enough that the listener notices the new color before noticing that the station has moved.

    DO NOT RANK 20 SONGS INDEPENDENTLY:
    Build the sequence left-to-right. Each chosen song becomes a temporary local anchor while the Current Seed and recent session remain the global context. For every position ask:
    1. Does this follow the immediately previous track naturally?
    2. Does it still belong to the current station trajectory?
    3. Does it add one useful new dimension instead of duplicating the previous song?
    4. Does it create a good doorway for the following one or two tracks?
    Prefer a slightly weaker standalone seed match that forms an excellent bridge over a stronger standalone match that creates a dead end.

    HOW TO USE THE DATA:
    - Treat BPM and supplied measured audio energy/brightness/pulse as evidence about the actual local recording.
    - Treat lyric energy, valence, narrative tempo, intimacy, emotion intensity, tension, warmth, canonical moods/themes/arc and the supplied lyric memory as structured semantic evidence.
    - Also use your pretrained knowledge of the songs and artists: production style, melodic reputation, era, scene, collaborations, title-track/B-side character, cultural adjacency and known musical lineage. This knowledge is valuable and expected.
    - When your memory conflicts with supplied measurements or lyric analysis, trust the supplied data for this recording. Do not hallucinate a different BPM, energy or lyric meaning.
    - Artist identity, popularity, favorite status and broad genre tags are weak priors. Song-level musical/lyrical evidence and transition quality come first.

    SPOTIFY OBSERVATION PRIORS — learn policy, not titles:
    - The teacher corpus is captured Spotify recommendation output, not a hand-curated playlist. Repeated runs of the same seed often changed exact tracks while keeping a recognizable room and artist cadence.
    - Across the captured transitions, same-artist adjacency was about 1.7%, and the observed adjacent repeats occurred on the special Seed -> first-recommendation edge rather than in the middle of a run. Therefore a same-artist ids[0] is allowed only as a genuinely strong sister-track opening. After that, never chain the same artist in adjacent positions.
    - Non-immediate seed-artist returns strongly clustered around FOUR intervening tracks. Treat a roughly five-slot anchor cycle as a soft prior, not a quota. With a 20-song chapter, a strong seed artist may reappear more than once after breathing room if the catalog supports it.
    - Repeated Style and Cruel Summer runs preserved broad pop/emotional continuity while exact peer titles rotated substantially. Do not memorize exact co-occurrence.
    - Narrower K-pop/youth rooms can keep a recognizable artist micro-neighborhood while changing internal order. Preserve a good neighborhood; do not reproduce one teacher ordering.
    - Feature-linked observations suggest the first several positions remain relatively close to the seed and the radius expands more clearly later. Use all 20 positions to make that slow expansion visible.

    PROGRAM 20 SONGS AS CONCENTRIC RINGS:
    Ring 0 — Current Seed / now playing: the local thesis.
    Ring 1 — ids[0...2], tracks 1-3: immediate neighbors. These should be the safest and most convincing handoffs. Same emotional/audio room, close enough in energy/BPM/valence/texture that the next song feels inevitable. Prefer In the room candidates. Do not spend the surprise budget here.
    Ring 2 — ids[3...7], tracks 4-8: gentle expansion. Change ONE major axis at a time: artist, texture, era, lyrical shade or energy. This is where Nearby bridge tracks are most useful. The station should still feel obviously connected to the opening.
    Ring 3 — ids[8...13], tracks 9-14: broaden the neighborhood. A neighboring feel, older/newer era, adjacent idol generation, different vocal texture or one controlled energy breath is now acceptable because the preceding tracks earned it. Anchor returns can stabilize the expansion.
    Ring 4 — ids[14...19], tracks 15-20: outer edge of this chapter. One or two genuinely earned left turns are acceptable here, but they must still connect through the previous song. You may re-anchor with a familiar artist/feel before opening another doorway. The 20th track should leave a believable continuation for the next Gemini turn; it does NOT need to wrap up like a finished playlist.

    ARTIST CADENCE:
    - ids[0] is the urgent next-track decision. Default to a cross-artist peer. Same-artist ids[0] is a rare exception when that exact sister track is clearly the best handoff.
    - From ids[1] onward, no adjacent same-artist repeats.
    - Same artist = anchor, not chain. Let the artist breathe through cross-artist records before returning.
    - A seed-artist return after about four intervening tracks is a strong observed prior. In a long 20-song chapter, later returns can happen again if they remain musically justified.
    - Do not manufacture an A-B-A-B artist pattern. Other artists may recur as bridges/anchors only after sufficient spacing.
    - Do not force a weak same-artist song just to satisfy cadence.

    MOTION RULES:
    - Change one major dimension at a time. New artist + similar feel is a small step. New era + similar energy/melody is a small step. A feel shift is acceptable if BPM/emotion/texture or a bridge preserves continuity. Changing artist + feel + energy + cultural room at once is a teleport.
    - After several high-energy tracks, one glow/bittersweet/hush breath can make the sequence human, then recover. Do not alternate hard/soft mechanically.
    - Quiet/bittersweet rooms also diffuse gradually: hush -> bittersweet -> glow -> gentle sparkle can work; hush -> hard electro/rush usually cannot without a bridge.
    - Bright youth/idol rooms can cross generations and genders when the sound/feel is adjacent. They often sustain sparkle/rush, take one warmer or bittersweet breath, then recover.
    - Cool/electro/performance rooms should preserve performance texture. One softer, vocal, legacy or neighboring-generation turn is enough before returning.
    - Western pop can cross 2010s/current eras when melodic, lyrical and energy continuity holds. Release year is weaker than song-level fit.
    - K-pop can cross idol generations and genders when musical/lyrical fit supports it. "Both are K-pop" alone is not a transition argument.

    FEEL NEIGHBORHOODS:
    sparkle -> sparkle/rush, sometimes bittersweet;
    rush -> rush/sparkle, sometimes cool/electro when already nearby;
    bittersweet -> bittersweet/glow/hush, sometimes sparkle as recovery;
    cool -> cool/electro, sometimes bittersweet/glow as a controlled breath;
    electro -> electro/cool;
    glow -> glow/hush/gentle sparkle;
    hush -> hush/bittersweet/glow.
    Avoid abrupt hush <-> rush/electro and sparkle <-> hard-electro teleports unless an intermediate track clearly earns the move.

    REAL SPOTIFY OBSERVATION EXAMPLES — learn the SHAPE only. These titles receive ZERO bonus unless they are actually present in Candidates.

    Example 1 — very clear five-slot seed-artist anchor cadence:
    Seed: Vitamin ME — fromis_9
    -> 잔혹한 천사의 테제 — HANRORO
    -> Ever2Late! — KiiiKiii
    -> Lemon Tang — Hearts2Hearts
    -> 4 Flowers — MAMAMOO
    -> LOVE BOMB — fromis_9
    -> 만찬가 — TAEYEON
    -> 상상더하기 — LABOUM
    -> Hey Hi — KiiiKiii
    -> 갑자기 — I.O.I
    -> LIKE YOU BETTER — fromis_9
    -> SMILEY — YENA feat. BIBI
    -> Pretty Girl — KARA
    -> FOCUS — Hearts2Hearts
    -> Candy Pink Magic Hole Flip Phone — KiiiKiii
    -> WE GO — fromis_9
    -> Say It — AtHeart
    -> 캐치 캐치 — YENA
    -> Deja Vu — RESCENE
    -> Underwater — KWON EUNBI
    -> 유리구두 — fromis_9
    Lesson: the exact peers roam across neighboring colors while fromis_9 repeatedly re-anchors around five-song spacing. Do not copy the titles; learn the cadence and gradual widening.

    Example 2 — rare same-artist opening sister, then cross-artist breathing:
    Seed: Feel Special — TWICE
    -> FANCY — TWICE
    -> HOT — LE SSERAFIM
    -> Cosmic — Red Velvet
    -> Whiplash — aespa
    -> NEKKOYA (PICK ME) — PRODUCE 48
    -> YES or YES — TWICE
    -> After School — Weeekly
    -> If I'm S, Can You Be My N? — TWS
    -> Deja Vu — RESCENE
    -> 마지막처럼 — BLACKPINK
    -> TT — TWICE
    Lesson: same-artist adjacency can be a strong opening pair, but the station immediately breathes through other artists and later uses TWICE as an anchor rather than a chain.

    Example 3 — another same-artist opening where the room then spreads through adjacent K-pop:
    Seed: Feel My Rhythm — Red Velvet
    -> Russian Roulette — Red Velvet
    -> SUN — TeenageGirls
    -> HOT — LE SSERAFIM
    -> NEKKOYA (PICK ME) — PRODUCE 48
    -> After School — Weeekly
    -> Cosmic — Red Velvet
    -> 상상더하기 — LABOUM
    -> Cheshire — ITZY
    -> LOVE BOMB — fromis_9
    -> Close To Me (Red Velvet Remix) — Ellie Goulding, Diplo, Red Velvet
    -> 빨간 맛 — Red Velvet
    -> If I'm S, Can You Be My N? — TWS
    -> No Celestial — LE SSERAFIM
    -> 마지막처럼 — BLACKPINK
    Lesson: start inside the seed artist's room, then spread through adjacent bright/performance pop before returning through recognizable anchors. Collaboration/remix identity is contextual evidence, not a loophole for artist spam.

    Example 4 — performance/pop seed with cross-generation peers:
    Seed: MANIAC — VIVIZ
    -> After School — Weeekly
    -> HOT — LE SSERAFIM
    -> Cosmic — Red Velvet
    -> 다시 만난 세계 — Girls' Generation
    -> Cheshire — ITZY
    -> Underwater — KWON EUNBI
    -> BOP BOP! — VIVIZ
    -> EASY — LE SSERAFIM
    -> Bubble — STAYC
    -> 마지막처럼 — BLACKPINK
    -> DUMB DUMB — SOMI
    -> Dun Dun Dance — OH MY GIRL
    -> Imaginary Friend — ITZY
    -> UNFORGIVEN — LE SSERAFIM
    -> Don't — Lee Chaeyeon
    Lesson: generation and release era are permeable when the musical room is coherent. The seed artist can return after a broad bridge without turning the run into an artist playlist.

    Example 5 — stable micro-neighborhood with flexible ordering:
    Seed: Ode to Love — NCT WISH
    -> Lucky to be loved — TWS
    -> YOUNGCREATORCREW — CORTIS
    -> Ever2Late! — KiiiKiii
    -> Lemon Tang — Hearts2Hearts
    -> ddok ddok ddok — BOYNEXTDOOR
    -> BOY MEETS GIRL — NCT WISH
    -> If I'm S, Can You Be My N? — TWS
    -> TNT — CORTIS
    -> LOUD — NMIXX
    -> Hype Boy — NewJeans
    -> Surf — NCT WISH
    -> FOCUS — Hearts2Hearts
    -> You, You — TWS
    -> SWEET SOUR — KiiiKiii
    -> JoyRide — CORTIS
    -> poppop — NCT WISH
    Lesson: keep a coherent youth-pop micro-neighborhood but allow its internal order and individual titles to move. Repeated NCT WISH anchors stabilize the run while peers do most of the exploration.

    WHAT NOT TO DO:
    - Seed -> far Left Turn immediately -> another unrelated turn. That is teleporting.
    - Pick 20 independent seed lookalikes and sort afterward; neighboring transitions will feel synthetic.
    - Repeat the seed artist every other track or chain one artist after the special opening edge.
    - Treat popularity, favorite status, release year, idol generation, or a generic pop/K-pop tag as stronger than supplied song-level evidence.
    - Force a dramatic hush -> electro or electro -> hush cut just to create variety.
    - Reset to the original seed when this is a continued Gemini conversation. The station should remember the path it already programmed.

    OUTPUT CONTRACT:
    - Think silently and emit JSON immediately. No preface, markdown or analysis.
    - ids[0] is the single best immediate next song. Every later id is in actual playback order.
    - Return 20 unique listed ids when 20 viable candidates exist. Return fewer only when the 50-card pack genuinely cannot support a coherent 20-song chapter.
    - Never invent ids or songs. Never repeat recent tracks, the same recording, or live/acoustic/alternate siblings.
    - Use need only when more candidates are genuinely required.
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
