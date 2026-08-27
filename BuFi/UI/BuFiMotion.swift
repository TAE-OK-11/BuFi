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
    static let pressDown = Animation.smooth(duration: 0.11, extraBounce: 0)
    static let pressUp = Animation.spring(duration: 0.30, bounce: 0.12)
    static let symbol = Animation.spring(duration: 0.32, bounce: 0.10)
    static let selection = Animation.spring(duration: 0.34, bounce: 0.10)
    static let scrub = Animation.spring(duration: 0.24, bounce: 0.10)
    static let fade = Animation.smooth(duration: 0.24, extraBounce: 0)
    static let reveal = Animation.smooth(duration: 0.34, extraBounce: 0)
    static let content = Animation.smooth(duration: 0.36, extraBounce: 0)
    static let homeEntrance = Animation.spring(duration: 0.46, bounce: 0.045)
    static let homeRefresh = Animation.smooth(duration: 0.40, extraBounce: 0)
    static let playerEntrance = Animation.spring(duration: 0.48, bounce: 0.04)
    static let screenEntrance = Animation.spring(duration: 0.44, bounce: 0.035)
    static let trackText = Animation.smooth(duration: 0.38, extraBounce: 0)
    static let trackPage = Animation.spring(duration: 0.46, bounce: 0.06)
    static let miniTrack = Animation.smooth(duration: 0.42, extraBounce: 0)
    static let artworkTouch = Animation.spring(duration: 0.26, bounce: 0.14)
    static let color = Animation.smooth(duration: 0.52, extraBounce: 0)
    static let page = Animation.smooth(duration: 0.38, extraBounce: 0)
    static let miniLyrics = Animation.spring(duration: 0.48, bounce: 0.035)
    static let lyricsCard = Animation.spring(duration: 0.42, bounce: 0.035)
    static let lyrics = Animation.smooth(duration: 0.40, extraBounce: 0)
    static let lyricsPanel = Animation.spring(duration: 0.46, bounce: 0.06)
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
        return thermalState == .nominal
    }
}

enum BuFiTransition {
    static var scene: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.992)),
            removal: .opacity
        )
    }

    static var section: AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .offset(y: 10))
                .combined(with: .scale(scale: 0.996, anchor: .top)),
            removal: .opacity.combined(with: .offset(y: -4))
        )
    }

    static var artworkReveal: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.992))
    }

    static var miniPlayer: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom)
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.98, anchor: .bottom)),
            removal: .move(edge: .bottom).combined(with: .opacity)
        )
    }
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

private struct BuFiEntranceMotionModifier: ViewModifier {
    @Environment(\.buFiMotionEnabled) private var motionEnabled
    @State private var hasAppeared = false

    let delay: TimeInterval
    let offset: CGFloat
    let initialScale: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(hasAppeared || !motionEnabled ? 1 : 0)
            .offset(y: hasAppeared || !motionEnabled ? 0 : offset)
            .scaleEffect(
                hasAppeared || !motionEnabled ? 1 : initialScale,
                anchor: .top
            )
            .animation(
                motionEnabled
                    ? BuFiMotion.screenEntrance.delay(delay)
                    : .none,
                value: hasAppeared
            )
            .task {
                guard !hasAppeared else { return }
                if motionEnabled {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                }
                hasAppeared = true
            }
    }
}

private struct BuFiVerticalSectionMotionModifier: ViewModifier {
    @Environment(\.buFiMotionEnabled) private var motionEnabled

    let delay: TimeInterval

    func body(content: Content) -> some View {
        let enablesMotion = motionEnabled

        content
            .modifier(
                BuFiEntranceMotionModifier(
                    delay: delay,
                    offset: 8,
                    initialScale: 0.996
                )
            )
            .scrollTransition(.interactive, axis: .vertical) { view, phase in
                view
                    .scaleEffect(phase.isIdentity || !enablesMotion ? 1 : 0.995)
                    .opacity(phase.isIdentity || !enablesMotion ? 1 : 0.95)
                    .offset(y: phase.isIdentity || !enablesMotion ? 0 : 4)
            }
    }
}

extension View {
    func buFiHorizontalScrollMotion() -> some View {
        modifier(BuFiHorizontalScrollMotionModifier())
    }

    func buFiEntranceMotion(
        delay: TimeInterval = 0,
        offset: CGFloat = 8,
        initialScale: CGFloat = 0.996
    ) -> some View {
        modifier(BuFiEntranceMotionModifier(
            delay: delay,
            offset: offset,
            initialScale: initialScale
        ))
    }

    func buFiVerticalSectionMotion(delay: TimeInterval = 0) -> some View {
        modifier(BuFiVerticalSectionMotionModifier(delay: delay))
    }
}
