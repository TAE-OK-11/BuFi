import Foundation
import SwiftUI

private struct BuFiMotionEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// A lightweight, app-wide motion policy supplied by the root view.
    ///
    /// Keep the default enabled so previews and independently hosted views retain
    /// their expected motion. The app root can disable it for Reduce Motion, Low
    /// Power Mode, or elevated thermal pressure.
    var buFiMotionEnabled: Bool {
        get { self[BuFiMotionEnabledKey.self] }
        set { self[BuFiMotionEnabledKey.self] = newValue }
    }
}

enum BuFiMotion {
    // Motion is intentionally quantized in 0.05-second steps so related
    // transitions feel consistent instead of each view inventing a spring.
    static let micro = Animation.easeOut(duration: 0.10)
    static let tap = Animation.spring(duration: 0.20, bounce: 0.18)
    static let selection = Animation.spring(duration: 0.25, bounce: 0.12)
    static let fade = Animation.easeInOut(duration: 0.25)
    static let text = Animation.spring(duration: 0.30, bounce: 0.08)
    static let color = Animation.easeInOut(duration: 0.35)
    static let page = Animation.spring(duration: 0.40, bounce: 0.10)
    static let player = Animation.spring(duration: 0.45, bounce: 0.12)
    static let lyrics = Animation.smooth(duration: 0.46, extraBounce: 0.02)
    static let lyricsPanel = Animation.smooth(duration: 0.56, extraBounce: 0.06)

    static func isEnabled(
        userPreference: Bool,
        reduceMotion: Bool,
        lowPowerMode: Bool,
        thermalState: ProcessInfo.ThermalState
    ) -> Bool {
        guard userPreference, !reduceMotion, !lowPowerMode else { return false }
        switch thermalState {
        case .nominal, .fair:
            return true
        case .serious, .critical:
            return false
        @unknown default:
            return false
        }
    }

    static func isEnabled(userPreference: Bool, reduceMotion: Bool) -> Bool {
        let processInfo = ProcessInfo.processInfo
        return isEnabled(
            userPreference: userPreference,
            reduceMotion: reduceMotion,
            lowPowerMode: processInfo.isLowPowerModeEnabled,
            thermalState: processInfo.thermalState
        )
    }
}
