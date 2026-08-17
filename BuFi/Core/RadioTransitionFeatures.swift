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
        let energy = finiteUnit(
            SoundFeatureExtractor.energy(song: song, signature: signature),
            fallback: 0.5
        )
        let valence = finiteUnit(signature?.valence ?? 0.5, fallback: 0.5)
        let intimacy = finiteUnit(details?.intimacy ?? 0.5, fallback: 0.5)
        let feel = RadioFeelGrammar.feel(song: song, signature: signature)
        let vocal = RadioContinuity.vocalGender(song: song, signature: signature)
        let plays = Double(song.playCount ?? 0)
        var values: [String: Double] = [
            "bpm": finiteUnit(bpm / 200),
            "energy": energy,
            "valence": valence,
            "intimacy": intimacy,
            "audioEnergy": finiteUnit(details?.audioEnergy ?? 0),
            "audioBrightness": finiteUnit(details?.audioBrightness ?? 0),
            "audioPulse": finiteUnit(details?.audioPulse ?? 0),
            "audioMeasured": details?.audioMeasured == true ? 1 : 0,
            "kpop": RadioContinuity.isKPop(song: song, signature: signature) ? 1 : 0,
            "starred": song.isStarred ? 1 : 0,
            "plays": finiteUnit(log(1 + max(0, plays)) / 5)
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
        return names.map { finite(values[$0] ?? 0) }
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
        return pairNames.map { finite(values[$0] ?? 0) }
    }

    private static func finite(_ value: Double, fallback: Double = 0) -> Double {
        value.isFinite ? value : fallback
    }

    private static func finiteUnit(_ value: Double, fallback: Double = 0) -> Double {
        min(1, max(0, finite(value, fallback: fallback)))
    }
}

/// Loads the Create ML item recommender and the pair ranker.
enum RadioCoreMLTransition {
    static let resourceName = "BuFiRadioRecommender"
    static let rankerResourceName = "BuFiRadioTransition"

    static var isReady: Bool { store.recommender != nil || store.ranker != nil }

#if canImport(CoreML)
    private static let store = ModelStore()

    private final class ModelStore: @unchecked Sendable {
        let recommender: MLModel?
        let ranker: MLModel?
        private let stateLock = NSLock()
        private let predictionLock = NSLock()
        private var rankerDisabled = false
        private var consecutiveRankerFailures = 0

        init() {
            recommender = Self.load(
                RadioCoreMLTransition.resourceName,
                computeUnits: .all
            )
            // This model is only one 24-value inner product. Sending hundreds
            // of tiny predictions through GPU/ANE adds scheduling risk without
            // a useful speed win. CPU-only is deterministic and effectively
            // free at this size.
            ranker = Self.load(
                RadioCoreMLTransition.rankerResourceName,
                computeUnits: .cpuOnly
            )
        }

        func usableRanker() -> MLModel? {
            stateLock.lock()
            defer { stateLock.unlock() }
            return rankerDisabled ? nil : ranker
        }

        func predictRanker(
            _ model: MLModel,
            input: MLFeatureProvider
        ) throws -> MLFeatureProvider {
            // Autoplay requests can overlap while an old queue is winding down.
            // Serializing this tiny model avoids concurrent Core ML execution on
            // one MLModel instance and costs less than another accelerator hop.
            predictionLock.lock()
            defer { predictionLock.unlock() }
            return try model.prediction(from: input)
        }

        func noteRankerSuccess() {
            stateLock.lock()
            consecutiveRankerFailures = 0
            stateLock.unlock()
        }

        /// Returns true only when the model should be disabled for this process.
        /// A single Core ML runtime hiccup falls back for one pair and the next
        /// candidate is still allowed to use the learned ranker.
        func noteRankerFailure(permanent: Bool) -> Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            guard !rankerDisabled else { return true }
            if permanent {
                rankerDisabled = true
                return true
            }
            consecutiveRankerFailures += 1
            if consecutiveRankerFailures >= 3 {
                rankerDisabled = true
            }
            return rankerDisabled
        }

        private static func load(
            _ name: String,
            computeUnits: MLComputeUnits
        ) -> MLModel? {
            let bundle = Bundle.main
            let url = bundle.url(forResource: name, withExtension: "mlmodelc")
                ?? bundle.url(forResource: name, withExtension: "mlmodel")
            guard let url else { return nil }
            let configuration = MLModelConfiguration()
            configuration.computeUnits = computeUnits
            return try? MLModel(contentsOf: url, configuration: configuration)
        }
    }
#else
    private static let store = (recommender: Optional<Any>.none, ranker: Optional<Any>.none)
#endif

    static func itemKey(for song: Song) -> String {
        "\(normalize(song.title))|\(normalize(song.artist))"
    }

    static func normalize(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
        var stripped = ""
        var skipping = false
        for character in folded {
            if character == "(" {
                skipping = true
                continue
            }
            if character == ")" {
                skipping = false
                continue
            }
            if skipping { continue }
            if character.isLetter || character.isNumber {
                stripped.append(character)
            }
        }
        return stripped
    }

    static func score(
        seed: Song,
        candidate: Song,
        lyricIndex: LyricSignatureIndex
    ) -> Double {
#if canImport(CoreML)
        if let model = store.usableRanker() {
            let started = Date()
            let features = RadioTransitionFeatures.pairVector(
                seed: seed,
                candidate: candidate,
                lyricIndex: lyricIndex
            )
            switch predict(model, features: features) {
            case .value(let value):
                store.noteRankerSuccess()
                let elapsed = Date().timeIntervalSince(started)
                if elapsed >= 0.08 {
                    RecommendationDiagnostics.record(
                        kind: .coreml,
                        level: .delay,
                        title: String(localized: "CoreML 추론이 느렸습니다"),
                        detail: "\(Int(elapsed * 1000))ms"
                    )
                }
                return max(0, min(1, value))
            case .failure(let reason, let permanent):
                let disabled = store.noteRankerFailure(permanent: permanent)
                RecommendationDiagnostics.record(
                    kind: .coreml,
                    level: .error,
                    title: String(localized: "CoreML 단일 추론 실패 · 규칙 점수로 보완"),
                    detail: "\(seed.title) → \(candidate.title) · \(reason)"
                )
                if disabled {
                    RecommendationDiagnostics.record(
                        kind: .coreml,
                        level: .info,
                        title: String(localized: "CoreML ranker를 세션에서 비활성화했습니다"),
                        detail: permanent
                            ? "model contract mismatch"
                            : "3 consecutive runtime failures"
                    )
                }
            }
        }
#endif
        return rank(seed: seed, candidate: candidate, lyricIndex: lyricIndex)
    }

#if canImport(CoreML)
    private enum RankerPrediction {
        case value(Double)
        case failure(String, permanent: Bool)
    }

    private static func predict(_ model: MLModel, features: [Double]) -> RankerPrediction {
        guard features.count == RadioTransitionFeatures.pairNames.count else {
            return .failure(
                "feature-count \(features.count) != \(RadioTransitionFeatures.pairNames.count)",
                permanent: true
            )
        }
        guard features.allSatisfy(\.isFinite) else {
            return .failure("non-finite feature vector", permanent: false)
        }
        guard let inputDescription = model.modelDescription.inputDescriptionsByName["features"],
              let constraint = inputDescription.multiArrayConstraint else {
            return .failure("missing CoreML input features", permanent: true)
        }
        let expectedCount = constraint.shape.reduce(1) { partial, value in
            partial * value.intValue
        }
        guard expectedCount == features.count else {
            return .failure(
                "model-shape \(constraint.shape) expects \(expectedCount), got \(features.count)",
                permanent: true
            )
        }
        do {
            let array = try MLMultiArray(
                shape: constraint.shape,
                dataType: constraint.dataType
            )
            for (index, value) in features.enumerated() {
                array[index] = NSNumber(value: value)
            }
            let input = try MLDictionaryFeatureProvider(
                dictionary: ["features": array]
            )
            let output = try store.predictRanker(model, input: input)
            if let multi = output.featureValue(for: "score")?.multiArrayValue,
               multi.count > 0 {
                let value = multi[0].doubleValue
                return value.isFinite
                    ? .value(value)
                    : .failure("non-finite score output", permanent: false)
            }
            if let feature = output.featureValue(for: "score"), feature.type == .double {
                let value = feature.doubleValue
                return value.isFinite
                    ? .value(value)
                    : .failure("non-finite score output", permanent: false)
            }
            return .failure("missing score output", permanent: true)
        } catch {
            let nsError = error as NSError
            return .failure(
                "\(nsError.domain)#\(nsError.code) \(nsError.localizedDescription)",
                permanent: false
            )
        }
    }

    private static func recommend(
        seed: Song,
        session: [Song],
        candidates: [Song],
        keep: Int
    ) -> [Song]? {
        guard let model = store.recommender else { return nil }
        let byKey = Dictionary(
            candidates.map { (itemKey(for: $0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var query: [AnyHashable: NSNumber] = [:]
        query[itemKey(for: seed)] = 5
        for (index, song) in session.prefix(4).enumerated() {
            query[itemKey(for: song)] = NSNumber(value: max(1, 4 - index))
        }
        let restrict = Array(byKey.keys)
        let started = Date()
        guard let output = predictRecommender(
            model,
            items: query,
            restrict: restrict,
            k: keep
        ) else {
            RecommendationDiagnostics.record(
                kind: .coreml,
                level: .error,
                title: String(localized: "추천 모델 추론 실패"),
                detail: seed.title
            )
            return nil
        }
        let elapsed = Date().timeIntervalSince(started)
        if elapsed >= 0.08 {
            RecommendationDiagnostics.record(
                kind: .coreml,
                level: .delay,
                title: String(localized: "추천 모델이 느렸습니다"),
                detail: "\(Int(elapsed * 1000))ms"
            )
        }
        var picked: [Song] = []
        var seen = Set<String>()
        for key in output {
            guard let song = byKey[key], seen.insert(song.id).inserted else { continue }
            picked.append(song)
            if picked.count == keep { break }
        }
        if picked.count < min(keep, 8) {
            return nil
        }
        if picked.count < keep {
            let rest = candidates.filter { !seen.contains($0.id) }
            let extras = rest.sorted {
                let left = score(seed: seed, candidate: $0, lyricIndex: .empty)
                let right = score(seed: seed, candidate: $1, lyricIndex: .empty)
                return left == right ? $0.id < $1.id : left > right
            }
            for song in extras where seen.insert(song.id).inserted {
                picked.append(song)
                if picked.count == keep { break }
            }
        }
        return picked
    }

    private static func predictRecommender(
        _ model: MLModel,
        items: [AnyHashable: NSNumber],
        restrict: [String],
        k: Int
    ) -> [String]? {
        guard let itemValue = try? MLFeatureValue(dictionary: items) else {
            return nil
        }
        let allowed = Set(restrict)
        let attempts: [[String: Any]] = [
            ["items": itemValue, "k": Int64(max(k, 1))],
            ["items": itemValue, "k": max(k, 1)],
            ["interactions": itemValue, "k": Int64(max(k, 1))]
        ]
        for dictionary in attempts {
            guard let input = try? MLDictionaryFeatureProvider(dictionary: dictionary),
                  let output = try? model.prediction(from: input) else {
                continue
            }
            if let ranked = recommenderIDs(from: output, allowed: allowed),
               !ranked.isEmpty {
                return ranked
            }
        }
        return nil
    }

    private static func recommenderIDs(
        from output: MLFeatureProvider,
        allowed: Set<String>
    ) -> [String]? {
        for name in ["recommendations", "recommended_item_ids", "items"] {
            if let values = output.featureValue(for: name)?.sequenceValue?.stringValues {
                let ranked = values.filter { allowed.contains($0) }
                if !ranked.isEmpty { return ranked }
            }
            if let dictionary = output.featureValue(for: name)?.dictionaryValue {
                let ranked = dictionary
                    .compactMap { key, value -> (String, Double)? in
                        guard let id = key as? String, allowed.contains(id) else {
                            return nil
                        }
                        return (id, value.doubleValue)
                    }
                    .sorted {
                        if $0.1 == $1.1 { return $0.0 < $1.0 }
                        return $0.1 > $1.1
                    }
                    .map(\.0)
                if !ranked.isEmpty { return ranked }
            }
        }
        return nil
    }
#endif

    static func shortlist(
        seed: Song,
        candidates: [Song],
        lyricIndex: LyricSignatureIndex,
        keep: Int,
        session: [Song] = []
    ) -> [Song] {
        if store.recommender == nil, store.ranker == nil {
            RecommendationDiagnostics.record(
                kind: .coreml,
                level: .info,
                title: String(localized: "CoreML 모델 없이 규칙 점수를 씁니다"),
                detail: resourceName
            )
        }
        let unique = TrackWorkIdentity.uniqueRecordings(candidates)
        if let recommended = recommend(
            seed: seed,
            session: session,
            candidates: unique,
            keep: keep
        ) {
            return recommended
        }
        let opening = session.last ?? seed
        let recent = Array(([seed] + session).prefix(4))
        var pairScoreCache: [String: Double] = [:]
        pairScoreCache.reserveCapacity(unique.count * max(2, recent.count))

        func cachedScore(anchor: Song, candidate: Song) -> Double {
            let key = anchor.id + "\u{1F}" + candidate.id
            if let cached = pairScoreCache[key] { return cached }
            let value = score(
                seed: anchor,
                candidate: candidate,
                lyricIndex: lyricIndex
            )
            pairScoreCache[key] = value
            return value
        }

        let ranked = unique.map { song in
            var value = cachedScore(anchor: seed, candidate: song) * 0.38
            let recentMean = recent.reduce(0.0) { total, anchor in
                total + cachedScore(anchor: anchor, candidate: song)
            } / Double(max(recent.count, 1))
            value += recentMean * 0.36
            value += cachedScore(anchor: opening, candidate: song) * 0.26
            return (song, value)
        }.sorted {
            if $0.1 == $1.1 { return $0.0.id < $1.0.id }
            return $0.1 > $1.1
        }
        return Array(ranked.prefix(max(0, keep)).map(\.0))
    }

    /// Stand-in ranker using the same numeric features a Core ML model will
    /// learn. A later compiled model swaps in without changing the 96→30 cut.
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
            value += 0.14
            let seedFeel = RadioFeelGrammar.feel(song: seed, signature: left)
            let candFeel = RadioFeelGrammar.feel(song: candidate, signature: right)
            if seedFeatures["kpop"] == 1,
               (seedFeel == .sparkle || seedFeel == .rush),
               (candFeel == .cool || candFeel == .electro) {
                value -= 0.18
            }
        } else {
            value -= 0.18
        }
        if nextFeatures["starred"] == 1 { value += 0.04 }
        value += (nextFeatures["plays"] ?? 0) * 0.03
        return max(0, min(1, value))
    }
}
