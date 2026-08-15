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

    var known: Int { done.count + pending.count }
    var lyricDone: Int { done.count }
    var soundDone: Int { done.filter(\.hasSound).count }

    static let empty = LyricAnalysisCoverage(done: [], pending: [])

    static func make(
        catalog: [Song],
        signatures: [String: LyricSignature]
    ) -> LyricAnalysisCoverage {
        var seen = Set<String>()
        var done: [LyricAnalysisEntry] = []
        var pending: [LyricAnalysisEntry] = []
        done.reserveCapacity(catalog.count)
        pending.reserveCapacity(catalog.count)
        for song in catalog {
            if song.id == LyricIntelligence.probeSongID { continue }
            if song.externalStreamURL != nil { continue }
            guard seen.insert(song.id).inserted else { continue }
            let signature = signatures[song.id]
            if let signature, signature.hasStoredLyricAnalysis {
                done.append(
                    LyricAnalysisEntry(
                        song: song,
                        sourceTitle: signature.sourceTitle,
                        hasSound: signature.hasStoredSoundAnalysis
                    )
                )
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
        return LyricAnalysisCoverage(done: done, pending: pending)
    }
}

struct LyricBatchProgress: Equatable, Sendable {
    var total: Int
    var processed: Int
    var analyzed: Int
    var cached: Int
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
        noLyrics: 0,
        soundAnalyzed: 0,
        currentTitle: "",
        isRunning: false,
        isCancelled: false
    )

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(processed) / Double(total))
    }
}
