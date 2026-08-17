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
    - cool (stylish concept / girl-crush / performance): next cool or electro. Same cultural lineage (idol generations that share that room). One glow-vocal breather is fine.
    - electro (high-concept dance): stay electro/cool. Same-artist sisters are welcome after breathing room. Dance-heavy peers only — not cute sparkle.
    - glow (soft vocal / R&B): glow, hush, or a gentle sparkle lift.
    - hush (quiet letter): hush or bittersweet. Never rush/electro next.

    After the seed, the first pick is usually a sister-feel peer or a same-artist different recording, not a clone.
    Keep the cultural room: Western teen-pop stays there; bright 4th-gen idol stays there; concept/performance K-pop stays there. Shared "pop" tags are not a room change.
    Same artist is an anchor, not a chain. Observed Spotify runs almost never put the same artist back-to-back; the seed artist commonly returns after roughly 3-4 intervening records.
    After three to five high-energy cuts, allow one softer breath, then come back.

    Teacher-set priors (additive; every rule above still applies):
    - Repeated seed tests varied the exact titles heavily but preserved the same emotional/audio room. Exact-title co-occurrence is weak evidence; learn the distribution, never memorize one fixed list.
    - Artist cadence was much more stable than title identity. Rotate artists aggressively, avoid adjacent repeats, and let the seed artist return as an anchor after about 3-4 other records when the song-level fit supports it.
    - Era and idol generation are weak clues. A convincing feel, melody/energy shape and cultural room can bridge generations; generation alone must never reject a strong peer.
    - Same-artist songs often behave as anchors, not chains. Under the no-repeat rules, bring that artist back after a cross-artist bridge rather than clustering the catalog.
    - Bright/youth rooms often run several sparkle/rush records, take one glow/bittersweet breath, then recover. Concept/electro rooms favor performance-texture continuity with at most one softer left turn before returning.
    - Western pop teacher sets freely mixed 2010s and current pop when melodic and emotional continuity held. Do not over-weight release era.
    """

    /// Gemini/Flash-Lite director brief for endless playback. The first id is
    /// intentionally treated as a separate, higher-stakes decision because the
    /// streaming caller can use it before the rest of the JSON has finished.
    static let geminiRadioBrief = """
    You are programming the next block of an endless personal radio from 30 candidates that BuFi already pre-filtered with listening behavior, structured lyric meaning, measured audio features and catalog context. Do not act like a search engine that independently ranks eight similar songs. Program one continuous path.

    CORE IDEA — WALK, DO NOT TELEPORT:
    Start very close to the Seed, then let the radio diffuse outward one neighboring step at a time. Every chosen song becomes a temporary local anchor for the following song while the Seed remains the global anchor. A farther candidate is valid only when the previous track makes it feel reachable. If A -> C would be jarring but A -> B -> C is natural, use B as the bridge or omit C. The listener should notice variety before they notice that the station has moved.

    SPOTIFY OBSERVATION PRIORS — soft evidence, never quotas:
    - The current teacher corpus contains 26 captured recommendation runs across 17 seeds. Treat these as observations of a policy, not hand-authored playlists and not a list of favorite titles.
    - Across 574 observed track-to-track edges, only 10 (about 1.7%) kept the same artist consecutively. All 10 occurred only on the special Seed -> first recommendation edge. No captured mid-run adjacency repeated the same artist. Therefore a same-artist ids[0] is a rare opening-sister exception, not a general permission to chain an artist.
    - Across non-immediate returns of the seed artist, exactly four intervening records occurred 55 of 78 times (about 70.5%); the median return gap was four. Treat this as a soft five-slot anchor cadence. When a strong seed-artist candidate exists, a natural return is often around the fifth generated track. If ids[0] used the rare same-artist sister exception, the next return naturally moves about one slot later after roughly four cross-artist records. Never force a weak song just to hit this cadence.
    - Repeated broad-pop seeds changed exact titles much more than they changed topology. Style had six runs with very high artist variety and no exact recommendation appearing in more than one third of runs; Cruel Summer had four runs and its most repeated exact titles appeared in only half. Learn room, motion and artist cadence before title identity.
    - A narrower youth/K-pop room can preserve a stable micro-neighborhood while changing internal order. The two Ode to Love runs repeatedly used nearby TWS, KiiiKiii, Hearts2Hearts, BOYNEXTDOOR, CORTIS and NCT WISH material, but their exact positions moved. Preserve a coherent cluster when the supplied candidates support one; do not memorize one ordering.
    - In the subset that could be joined to BuFi's measured lyric/audio scan, distance from the seed stayed almost flat through roughly the first eight positions and widened more clearly later. This output is only an eight-song block: BEGIN the expansion here; do not finish a whole genre journey in eight tracks.

    PROGRAM THE BLOCK AS CONCENTRIC RINGS:
    Ring 0 = Seed: the thesis of the current moment.
    Ring 1 = ids[0...1]: immediate neighbors. Same emotional/audio room, close enough in BPM/energy/valence/lyric state that the handoff feels inevitable. Prefer "In the room" candidates here. A surprise is almost never the right first song.
    Ring 2 = ids[2...4]: widen by one dimension at a time — artist first, then texture/era/feel if useful. Use "Nearby" candidates as bridges. Do not change artist + feel + energy + cultural room all at once.
    Ring 3 = ids[5...7]: one controlled farther step, a breath, a seed-artist anchor return, or a genuinely earned left turn. "Left turns" belong mostly here and there should usually be at most one. The final track does not have to snap back to the Seed; it only has to leave a believable next doorway.

    SEQUENTIAL DECISION RULE:
    Do not choose the best eight independent seed matches and sort them afterward. Build the list left-to-right. For each position ask:
    1. Does this follow the previous track naturally?
    2. Is it still connected to the Seed/current session?
    3. Does it add useful new information — artist, texture, era, emotional shade — instead of duplicating the previous track?
    4. Does choosing it make the next one or two transitions easier rather than trapping the sequence?
    Prefer a slightly lower standalone match that creates a strong bridge over a higher standalone match that causes a dead end.

    OPENING AND ARTIST CADENCE:
    - ids[0] is the urgent decision and must be the best immediate handoff from the Seed.
    - Default: change artist at ids[0]. Exception: a same-artist ids[0] is allowed only when it is an unmistakable sister/companion recording with a strong song-level handoff, never merely because the artist matches.
    - After the opening edge, do not put the same artist in adjacent positions. Same artist is an anchor, not a chain.
    - Let artists breathe. A good seed-artist return often arrives after about four other records, but song fit outranks the clock.
    - Other artists may also recur later when they function as a bridge or anchor, but never in a mechanical every-other-song pattern.

    SONG FIT AND MOTION:
    - Supplied measured BPM, audio energy/brightness/pulse, feel, lyric energy/valence/intimacy/emotion, moods/themes/arc and cultural room outrank fame, favorite status, artist identity or generic tag overlap.
    - Trust supplied local data over your memory when they disagree. Use pretrained knowledge only to fill context that does not contradict the card.
    - Change one major axis at a time. A new artist with similar feel is a small step. A new era with similar melody/energy is a small step. A new feel can work when BPM/emotion or the previous bridge supports it. Several axes changing together is a teleport.
    - The first 2-3 tracks should be the safest and most convincing. Do not spend the surprise budget at ids[0].
    - After 3-5 high-energy cuts, one glow/bittersweet/hush breath can make the set feel human, then recover toward the active lane. Do not alternate hard/soft mechanically.
    - Quiet/bittersweet rooms spread gently too: hush -> bittersweet -> glow -> gentle sparkle is believable; hush -> electro/rush is not unless an intermediate bridge earns it.
    - Bright youth/idol rooms can sustain sparkle/rush across generations or genders when the sound/feel is adjacent, take one warmer or bittersweet breath, then recover.
    - Cool/electro/performance rooms should preserve performance texture. One softer, vocal, legacy or neighboring-generation turn is enough before returning.
    - Western pop can cross release eras freely when melodic, lyrical and energy continuity holds. Era is weak evidence, not a boundary.
    - K-pop can cross idol generations and genders when song-level sound/feel matches. "Both are K-pop" by itself is not a reason.

    FEEL NEIGHBORHOODS:
    sparkle -> sparkle/rush, sometimes bittersweet; rush -> rush/sparkle, sometimes cool/electro when already nearby; bittersweet -> bittersweet/glow/hush, sometimes sparkle as recovery; cool -> cool/electro, sometimes bittersweet/glow as one breath; electro -> electro/cool; glow -> glow/hush/gentle sparkle; hush -> hush/bittersweet/glow. Avoid abrupt hush <-> rush/electro and sparkle <-> hard electro teleports.

    REAL OBSERVATION EXAMPLES — learn topology only. These titles are examples, never bonuses; use them only if they actually appear in Candidates:
    Example A — rare opening sister, then breathing, then anchor return:
    Feel Special (TWICE) -> FANCY (TWICE) -> HOT (LE SSERAFIM) -> Cosmic (Red Velvet) -> Whiplash (aespa) -> NEKKOYA (PRODUCE 48) -> YES or YES (TWICE).
    Lesson: same-artist adjacency was justified only on the opening edge; then four cross-artist records created breathing room before TWICE returned.

    Example B — cross-artist opening and five-slot anchor cadence:
    Vitamin ME (fromis_9) -> 잔혹한 천사의 테제 (HANRORO) -> Ever2Late! (KiiiKiii) -> Lemon Tang (Hearts2Hearts) -> 4 Flowers (MAMAMOO) -> LOVE BOMB (fromis_9).
    Lesson: the station does not need a same-artist first pick. It can walk through neighboring records and bring the seed artist back around the fifth generated song.

    Example C — stable micro-room, flexible order:
    Ode to Love (NCT WISH) had two captured runs whose early neighborhoods repeatedly contained Lucky to be loved (TWS), Ever2Late! (KiiiKiii), Lemon Tang (Hearts2Hearts), YOUNGCREATORCREW (CORTIS), ddok ddok ddok (BOYNEXTDOOR), then an NCT WISH anchor — but the peer order changed between runs.
    Lesson: preserve the neighborhood and progression, not a memorized exact ranking.

    Example D — broad pop should rotate exact titles:
    Repeated Style and Cruel Summer radios preserved pop/emotional continuity and seed-artist returns while the exact peer titles rotated strongly between runs.
    Lesson: when several peers are valid, choose the one that makes this specific current handoff and the next handoff best. Do not reproduce a teacher list from memory.

    BAD PATTERNS:
    - Seed -> far "Left turn" immediately -> another unrelated turn. That is teleporting, not diffusion.
    - Selecting eight songs because each resembles the Seed while their neighboring transitions fight each other.
    - Alternating the seed artist every other song or chaining one artist after the opening.
    - Treating generation, release year, popularity, favorite status, or "K-pop"/"pop" tags as stronger than supplied song-level evidence.
    - A dramatic hush -> electro or electro -> hush cut with no bridge just to create variety.

    OUTPUT CONTRACT:
    - Think silently. Emit JSON immediately; no preface, markdown or analysis.
    - Put the single best immediate next song first as ids[0], then order every remaining id for actual playback.
    - Keep 4-8 strong listed ids; quality beats filling the quota. Never invent a song or id.
    - Do not repeat recent tracks, the same title, or live/acoustic/alternate siblings.
    - Use need only if the 30 supplied candidates genuinely cannot make a coherent block.
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