import Foundation

/// Numeric features for a future on-device Core ML transition model.
/// Values come from the same signals the live mixer already uses.
enum RadioTransitionFeatures {
    static let names: [String] = [
        "bpm", "energy", "valence", "intimacy",
        "audioEnergy", "audioBrightness", "audioPulse", "audioMeasured",
        "kpop", "starred", "plays",
        "feel_sparkle", "feel_rush", "feel_bittersweet", "feel_cool",
        "feel_electro", "feel_glow", "feel_hush",
        "vox_female", "vox_male", "vox_mixed"
    ]

    static func snapshot(
        song: Song,
        signature: LyricSignature?
    ) -> [String: Double] {
        let details = signature?.details
        let bpm = Double(SoundFeatureExtractor.bpm(song: song, signature: signature))
        let energy = SoundFeatureExtractor.energy(song: song, signature: signature)
        let valence = signature?.valence ?? 0.5
        let intimacy = details?.intimacy ?? 0.5
        let feel = RadioFeelGrammar.feel(song: song, signature: signature)
        let vocal = RadioContinuity.vocalGender(song: song, signature: signature)
        let plays = Double(song.playCount ?? 0)
        var values: [String: Double] = [
            "bpm": min(1, bpm / 200),
            "energy": energy,
            "valence": valence,
            "intimacy": intimacy,
            "audioEnergy": details?.audioEnergy ?? 0,
            "audioBrightness": details?.audioBrightness ?? 0,
            "audioPulse": details?.audioPulse ?? 0,
            "audioMeasured": details?.audioMeasured == true ? 1 : 0,
            "kpop": RadioContinuity.isKPop(song: song, signature: signature) ? 1 : 0,
            "starred": song.isStarred ? 1 : 0,
            "plays": min(1, log(1 + plays) / 5)
        ]
        for name in names where name.hasPrefix("feel_") {
            values[name] = name == "feel_\(feel.rawValue)" ? 1 : 0
        }
        values["vox_female"] = vocal == "female" ? 1 : 0
        values["vox_male"] = vocal == "male" ? 1 : 0
        values["vox_mixed"] = vocal == "mixed" ? 1 : 0
        return values
    }

    static func vector(song: Song, signature: LyricSignature?) -> [Double] {
        let values = snapshot(song: song, signature: signature)
        return names.map { values[$0] ?? 0 }
    }
}

/// Loads a compiled `BuFiRadioTransition` model when one is bundled.
/// Until that file exists, callers keep using RadioFeelGrammar.
enum RadioCoreMLTransition {
    static let resourceName = "BuFiRadioTransition"

    static var isReady: Bool {
        Bundle.main.url(
            forResource: resourceName,
            withExtension: "mlmodelc"
        ) != nil
            || Bundle.main.url(
                forResource: resourceName,
                withExtension: "mlmodel"
            ) != nil
    }

    static func score(
        seed: Song,
        candidate: Song,
        lyricIndex: LyricSignatureIndex
    ) -> Double {
        if isReady {
            // Compiled model will replace this stand-in once trained.
        }
        return rank(seed: seed, candidate: candidate, lyricIndex: lyricIndex)
    }

    static func shortlist(
        seed: Song,
        candidates: [Song],
        lyricIndex: LyricSignatureIndex,
        keep: Int
    ) -> [Song] {
        let unique = TrackWorkIdentity.uniqueRecordings(candidates)
        let ranked = unique.map { song in
            (
                song,
                score(seed: seed, candidate: song, lyricIndex: lyricIndex)
            )
        }.sorted {
            if $0.1 == $1.1 { return $0.0.id < $1.0.id }
            return $0.1 > $1.1
        }
        return Array(ranked.prefix(max(0, keep)).map(\.0))
    }

    /// Stand-in ranker using the same numeric features a Core ML model will
    /// learn. A later compiled model swaps in without changing the 50→30 cut.
    private static func rank(
        seed: Song,
        candidate: Song,
        lyricIndex: LyricSignatureIndex
    ) -> Double {
        let left = lyricIndex.bySongID[seed.id]
        let right = lyricIndex.bySongID[candidate.id]
        let seedFeatures = RadioTransitionFeatures.snapshot(
            song: seed,
            signature: left
        )
        let nextFeatures = RadioTransitionFeatures.snapshot(
            song: candidate,
            signature: right
        )
        var value = RadioFeelGrammar.placement(
            from: seed,
            to: candidate,
            lyricIndex: lyricIndex
        ) * 0.42
        value += SoundFeatureExtractor.transitionScore(
            from: seed,
            to: candidate,
            lyricIndex: lyricIndex
        ) * 0.22
        let energyGap = abs(
            (seedFeatures["energy"] ?? 0.5) - (nextFeatures["energy"] ?? 0.5)
        )
        let valenceGap = abs(
            (seedFeatures["valence"] ?? 0.5) - (nextFeatures["valence"] ?? 0.5)
        )
        let bpmGap = abs((seedFeatures["bpm"] ?? 0) - (nextFeatures["bpm"] ?? 0))
        value += max(0, 0.14 - energyGap * 0.22)
        value += max(0, 0.10 - valenceGap * 0.16)
        value += max(0, 0.10 - bpmGap * 0.35)
        if seedFeatures["kpop"] == nextFeatures["kpop"] {
            value += 0.10
        } else {
            value -= 0.16
        }
        if nextFeatures["starred"] == 1 { value += 0.04 }
        value += (nextFeatures["plays"] ?? 0) * 0.03
        return max(0, min(1, value))
    }
}
