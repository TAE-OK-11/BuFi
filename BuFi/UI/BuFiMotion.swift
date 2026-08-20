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
    // Each motion has one job. Fast compression followed by a slightly longer
    // spring release makes controls tactile, while layout and color changes use
    // restrained curves so repeated updates never wobble or compete.
    static let pressDown = Animation.snappy(duration: 0.11, extraBounce: 0)
    static let pressUp = Animation.spring(duration: 0.32, bounce: 0.24)
    static let symbol = Animation.spring(duration: 0.34, bounce: 0.22)
    static let selection = Animation.spring(duration: 0.38, bounce: 0.16)
    static let scrub = Animation.spring(duration: 0.28, bounce: 0.18)
    static let fade = Animation.smooth(duration: 0.28, extraBounce: 0)
    static let reveal = Animation.spring(duration: 0.44, bounce: 0.08)
    static let content = Animation.spring(duration: 0.44, bounce: 0.10)
    static let trackText = Animation.spring(duration: 0.44, bounce: 0.12)
    static let trackArtwork = Animation.spring(duration: 0.50, bounce: 0.10)
    static let trackPage = Animation.spring(duration: 0.50, bounce: 0.10)
    static let color = Animation.smooth(duration: 0.62, extraBounce: 0)
    static let page = Animation.spring(duration: 0.46, bounce: 0.10)
    static let miniLyrics = Animation.spring(duration: 0.50, bounce: 0.08)
    static let lyrics = Animation.spring(duration: 0.42, bounce: 0.10)
    static let lyricsPanel = Animation.spring(duration: 0.50, bounce: 0.12)
    static let timeline = Animation.linear(duration: 0.24)
    static let miniTimeline = Animation.linear(duration: 0.95)

    static func press(isPressed: Bool) -> Animation {
        isPressed ? pressDown : pressUp
    }

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

enum BuFiTransition {
    static let scene = AnyTransition.asymmetric(
        insertion: .opacity.combined(with: .scale(scale: 0.992)),
        removal: .opacity
    )

    static let section = AnyTransition.asymmetric(
        insertion: .opacity
            .combined(with: .offset(y: 10))
            .combined(with: .scale(scale: 0.996, anchor: .top)),
        removal: .opacity.combined(with: .offset(y: -4))
    )

    static let artworkReveal = AnyTransition.opacity.combined(
        with: .scale(scale: 0.992)
    )

    static let miniPlayer = AnyTransition.asymmetric(
        insertion: .move(edge: .bottom)
            .combined(with: .opacity)
            .combined(with: .scale(scale: 0.98, anchor: .bottom)),
        removal: .move(edge: .bottom).combined(with: .opacity)
    )
}

private struct BuFiHorizontalScrollMotionModifier: ViewModifier {
    @Environment(\.buFiMotionEnabled) private var motionEnabled

    @ViewBuilder
    func body(content: Content) -> some View {
        if motionEnabled {
            content.scrollTransition(.interactive, axis: .horizontal) { view, phase in
                view
                    .scaleEffect(phase.isIdentity ? 1 : 0.972)
                    .opacity(phase.isIdentity ? 1 : 0.88)
                    .offset(y: phase.isIdentity ? 0 : 5)
            }
        } else {
            content
        }
    }
}

extension View {
    func buFiHorizontalScrollMotion() -> some View {
        modifier(BuFiHorizontalScrollMotionModifier())
    }
}
