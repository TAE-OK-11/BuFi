import Foundation

struct LyricAnalysisEntry: Equatable, Identifiable, Sendable {
    var song: Song
    var sourceTitle: String
    var hasSound: Bool

    var id: String { song.id }
}

struct LyricAnalysisCoverage: Equatable, Sendable {
    var done: [LyricAnalysisEntry]
    var pending: [LyricAnalysisEntry]
    var needsSound: [LyricAnalysisEntry]
    var needsResummary: [LyricAnalysisEntry]

    var known: Int { done.count + pending.count }
    var lyricDone: Int { done.count }
    var soundDone: Int { done.filter(\.hasSound).count }

    var workQueue: [Song] {
        MediaIdentity.uniqueSongs(
            pending.map(\.song) + needsSound.map(\.song) + needsResummary.map(\.song)
        )
    }

    static let empty = LyricAnalysisCoverage(
        done: [],
        pending: [],
        needsSound: [],
        needsResummary: []
    )

    static func make(
        catalog: [Song],
        signatures: [String: LyricSignature]
    ) -> LyricAnalysisCoverage {
        var seen = Set<String>()
        var done: [LyricAnalysisEntry] = []
        var pending: [LyricAnalysisEntry] = []
        var needsSound: [LyricAnalysisEntry] = []
        var needsResummary: [LyricAnalysisEntry] = []
        done.reserveCapacity(catalog.count)
        pending.reserveCapacity(catalog.count)
        needsSound.reserveCapacity(catalog.count)
        needsResummary.reserveCapacity(catalog.count)
        for song in catalog {
            if song.id == LyricIntelligence.probeSongID { continue }
            if song.externalStreamURL != nil { continue }
            guard seen.insert(song.id).inserted else { continue }
            let signature = signatures[song.id]
            if let signature, signature.hasStoredLyricAnalysis {
                let entry = LyricAnalysisEntry(
                    song: song,
                    sourceTitle: signature.sourceTitle,
                    hasSound: signature.hasStoredSoundAnalysis
                )
                done.append(entry)
                if !entry.hasSound {
                    needsSound.append(entry)
                }
                if !signature.hasStoredSummary {
                    needsResummary.append(entry)
                }
            } else {
                pending.append(
                    LyricAnalysisEntry(
                        song: song,
                        sourceTitle: "",
                        hasSound: signature?.hasStoredSoundAnalysis ?? false
                    )
                )
            }
        }
        return LyricAnalysisCoverage(
            done: done,
            pending: pending,
            needsSound: needsSound,
            needsResummary: needsResummary
        )
    }
}

struct LyricBatchProgress: Equatable, Sendable {
    var total: Int
    var processed: Int
    var analyzed: Int
    var cached: Int
    var failed: Int
    var noLyrics: Int
    var soundAnalyzed: Int
    var currentTitle: String
    var isRunning: Bool
    var isCancelled: Bool

    static let idle = LyricBatchProgress(
        total: 0,
        processed: 0,
        analyzed: 0,
        cached: 0,
        failed: 0,
        noLyrics: 0,
        soundAnalyzed: 0,
        currentTitle: "",
        isRunning: false,
        isCancelled: false
    )

    var succeeded: Int { analyzed + cached }

    var isComplete: Bool {
        total > 0 && succeeded == total && failed == 0 && noLyrics == 0
    }

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(succeeded) / Double(total))
    }
}

enum LyricBatchAccounting {
    enum Outcome: Equatable {
        case cached
        case analyzed
        case failed
        case noLyrics
    }

    static func outcome(
        hadLyrics: Bool,
        reusedCache: Bool,
        storedAnalysis: Bool
    ) -> Outcome {
        guard hadLyrics else { return .noLyrics }
        if storedAnalysis {
            return reusedCache ? .cached : .analyzed
        }
        return .failed
    }
}
