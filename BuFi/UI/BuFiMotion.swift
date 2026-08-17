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

/// Artwork views skip a second decode when SwiftUI re-runs the same request.
enum UIRenderPolicy {
    static func shouldReloadArtwork(
        loadedIdentity: ArtworkLoadRequestIdentity?,
        requestedIdentity: ArtworkLoadRequestIdentity
    ) -> Bool {
        loadedIdentity != requestedIdentity
    }
}

enum BuFiMotion {
    // Apple-native interpolating springs. A little extra bounce makes taps and
    // track changes feel tactile without letting the UI overshoot.
    static let micro = Animation.snappy(duration: 0.16, extraBounce: 0.04)
    static let tap = Animation.spring(duration: 0.26, bounce: 0.24)
    static let selection = Animation.smooth(duration: 0.32, extraBounce: 0.07)
    static let fade = Animation.smooth(duration: 0.30, extraBounce: 0)
    static let content = Animation.smooth(duration: 0.36, extraBounce: 0.07)
    static let trackText = Animation.smooth(duration: 0.40, extraBounce: 0.08)
    static let trackPage = Animation.smooth(duration: 0.48, extraBounce: 0.08)
    static let color = Animation.smooth(duration: 0.44, extraBounce: 0)
    static let page = Animation.smooth(duration: 0.38, extraBounce: 0.07)
    static let miniLyrics = Animation.smooth(duration: 0.36, extraBounce: 0.08)
    static let lyrics = Animation.smooth(duration: 0.38, extraBounce: 0.06)
    static let lyricsPanel = Animation.smooth(duration: 0.40, extraBounce: 0.08)

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
}
