import Foundation
import OSLog

/// Stores only coarse, non-sensitive launch phases. A device crash report can
/// then be correlated with the last phase that completed, including crashes
/// that occur before the first SwiftUI screen becomes interactive.
enum LaunchDiagnostics {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "BuFi",
        category: "Launch"
    )
    private static let phaseKey = "launch-diagnostics-last-phase"
    private static let buildKey = "launch-diagnostics-build"
    private static let previousPhaseKey = "launch-diagnostics-previous-phase"
    private static let previousBuildKey = "launch-diagnostics-previous-build"

    static func beginLaunch() {
        let defaults = UserDefaults.standard
        if let previousPhase = defaults.string(forKey: phaseKey) {
            defaults.set(previousPhase, forKey: previousPhaseKey)
        }
        if let previousBuild = defaults.string(forKey: buildKey) {
            defaults.set(previousBuild, forKey: previousBuildKey)
        }
        mark("app-init-started")
    }

    static func mark(_ phase: String) {
        logger.notice("Launch phase: \(phase, privacy: .public)")
        let defaults = UserDefaults.standard
        defaults.set(phase, forKey: phaseKey)
        defaults.set(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
                as? String ?? "unknown",
            forKey: buildKey
        )
    }
}
