import Foundation
#if canImport(CoreML)
@preconcurrency import CoreML
#endif

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

    static let pairNames: [String] = [
        "energy_gap", "valence_gap", "bpm_gap", "intimacy_gap",
        "kpop_same", "feel_same", "starred", "plays",
        "seed_energy", "cand_energy",
        "seed_feel_sparkle", "seed_feel_rush", "seed_feel_bittersweet",
        "seed_feel_cool", "seed_feel_electro", "seed_feel_glow", "seed_feel_hush",
        "cand_feel_sparkle", "cand_feel_rush", "cand_feel_bittersweet",
        "cand_feel_cool", "cand_feel_electro", "cand_feel_glow", "cand_feel_hush"
    ]

    static func pairVector(
        seed: Song,
        candidate: Song,
        lyricIndex: LyricSignatureIndex
    ) -> [Double] {
        let left = lyricIndex.bySongID[seed.id]
        let right = lyricIndex.bySongID[candidate.id]
        let seedSnap = snapshot(song: seed, signature: left)
        let candSnap = snapshot(song: candidate, signature: right)
        let seedFeel = RadioFeelGrammar.feel(song: seed, signature: left)
        let candFeel = RadioFeelGrammar.feel(song: candidate, signature: right)
        var values: [String: Double] = [
            "energy_gap": abs((seedSnap["energy"] ?? 0) - (candSnap["energy"] ?? 0)),
            "valence_gap": abs((seedSnap["valence"] ?? 0) - (candSnap["valence"] ?? 0)),
            "bpm_gap": abs((seedSnap["bpm"] ?? 0) - (candSnap["bpm"] ?? 0)),
            "intimacy_gap": abs((seedSnap["intimacy"] ?? 0) - (candSnap["intimacy"] ?? 0)),
            "kpop_same": seedSnap["kpop"] == candSnap["kpop"] ? 1 : 0,
            "feel_same": seedFeel == candFeel ? 1 : 0,
            "starred": candSnap["starred"] ?? 0,
            "plays": candSnap["plays"] ?? 0,
            "seed_energy": seedSnap["energy"] ?? 0,
            "cand_energy": candSnap["energy"] ?? 0
        ]
        for feel in RadioFeel.allCases {
            values["seed_feel_\(feel.rawValue)"] = feel == seedFeel ? 1 : 0
            values["cand_feel_\(feel.rawValue)"] = feel == candFeel ? 1 : 0
        }
        return pairNames.map { values[$0] ?? 0 }
    }
}

/// Loads a compiled `BuFiRadioTransition` model when one is bundled.
/// Until that file exists, callers keep using RadioFeelGrammar.
enum RadioCoreMLTransition {
    static let resourceName = "BuFiRadioTransition"

    static var isReady: Bool { store.model != nil }

#if canImport(CoreML)
    private static let store = ModelStore()

    private final class ModelStore: @unchecked Sendable {
        let model: MLModel?

        init() {
            let bundle = Bundle.main
            let url = bundle.url(
                forResource: RadioCoreMLTransition.resourceName,
                withExtension: "mlmodelc"
            ) ?? bundle.url(
                forResource: RadioCoreMLTransition.resourceName,
                withExtension: "mlmodel"
            )
            guard let url else {
                model = nil
                return
            }
            model = try? MLModel(contentsOf: url)
        }
    }
#else
    private static let store = (model: Optional<Any>.none)
#endif

    static func score(
        seed: Song,
        candidate: Song,
        lyricIndex: LyricSignatureIndex
    ) -> Double {
#if canImport(CoreML)
        if let model = store.model,
           let value = predict(
            model,
            features: RadioTransitionFeatures.pairVector(
                seed: seed,
                candidate: candidate,
                lyricIndex: lyricIndex
            )
           ) {
            return max(0, min(1, value))
        }
#endif
        return rank(seed: seed, candidate: candidate, lyricIndex: lyricIndex)
    }

#if canImport(CoreML)
    private static func predict(_ model: MLModel, features: [Double]) -> Double? {
        guard let array = try? MLMultiArray(
            shape: [NSNumber(value: features.count)],
            dataType: .double
        ) else {
            return nil
        }
        for (index, value) in features.enumerated() {
            array[index] = NSNumber(value: value)
        }
        guard let input = try? MLDictionaryFeatureProvider(
            dictionary: ["features": array]
        ),
              let output = try? model.prediction(from: input) else {
            return nil
        }
        if let multi = output.featureValue(for: "score")?.multiArrayValue,
           multi.count > 0 {
            return multi[0].doubleValue
        }
        return output.featureValue(for: "score")?.doubleValue
    }
#endif

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
