import Foundation

/// Shared energy and thermal gates for background work, motion, and prefetch.
enum EnergyConstraintsPolicy {
    static func allowsBackgroundPreparation(
        lowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled,
        thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    ) -> Bool {
        guard !lowPowerMode else { return false }
        return thermalState == .nominal
    }

    static func allowsExternalRecommendationRefresh(
        lowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled,
        thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    ) -> Bool {
        guard !lowPowerMode else { return false }
        return thermalState == .nominal
    }

    static func shouldCancelBackgroundWork(
        lowPowerMode: Bool,
        thermalState: ProcessInfo.ThermalState
    ) -> Bool {
        guard !lowPowerMode else { return true }
        switch thermalState {
        case .nominal:
            return false
        case .fair, .serious, .critical:
            return true
        @unknown default:
            return true
        }
    }

    static func pausesAutomaticSync(
        lowPowerMode: Bool,
        thermalState: ProcessInfo.ThermalState
    ) -> Bool {
        shouldCancelBackgroundWork(
            lowPowerMode: lowPowerMode,
            thermalState: thermalState
        )
    }

    static func artworkPrefetchConcurrency(
        thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    ) -> Int {
        switch thermalState {
        case .nominal:
            return 4
        case .fair:
            return 2
        case .serious, .critical:
            return 1
        @unknown default:
            return 1
        }
    }
}
