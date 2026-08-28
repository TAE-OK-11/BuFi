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
    // Springs use restrained bounce so controls feel tactile without wobble.
    // Smooth curves carry layout, color, and progress interpolation between
    // infrequent state updates.
    static let pressDown = Animation.smooth(duration: 0.10, extraBounce: 0)
    static let pressUp = Animation.spring(duration: 0.28, bounce: 0.08)
    static let symbol = Animation.spring(duration: 0.30, bounce: 0.08)
    static let selection = Animation.spring(duration: 0.32, bounce: 0.08)
    static let scrub = Animation.spring(duration: 0.22, bounce: 0.08)
    static let fade = Animation.smooth(duration: 0.22, extraBounce: 0)
    static let reveal = Animation.smooth(duration: 0.32, extraBounce: 0)
    static let content = Animation.smooth(duration: 0.34, extraBounce: 0)
    static let homeEntrance = Animation.spring(duration: 0.52, bounce: 0.032)
    static let homeRefresh = Animation.smooth(duration: 0.38, extraBounce: 0)
    static let playerEntrance = Animation.spring(duration: 0.52, bounce: 0.028)
    static let screenEntrance = Animation.spring(duration: 0.48, bounce: 0.028)
    static let trackText = Animation.smooth(duration: 0.36, extraBounce: 0)
    static let trackPage = Animation.smooth(duration: 0.46, extraBounce: 0)
    static let trackBackground = Animation.smooth(duration: 0.64, extraBounce: 0)
    static let miniTrack = Animation.smooth(duration: 0.40, extraBounce: 0)
    static let artworkTouch = Animation.spring(duration: 0.24, bounce: 0.10)
    static let color = Animation.smooth(duration: 0.48, extraBounce: 0)
    static let page = Animation.smooth(duration: 0.36, extraBounce: 0)
    static let miniLyricsScroll = Animation.smooth(duration: 0.48, extraBounce: 0)
    static let miniLyrics = Animation.smooth(duration: 0.48, extraBounce: 0)
    static let lyricsCard = Animation.spring(duration: 0.40, bounce: 0.028)
    static let lyrics = Animation.smooth(duration: 0.38, extraBounce: 0)
    static let lyricsPanel = Animation.spring(duration: 0.44, bounce: 0.05)
    /// Interpolates between periodic playback ticks (≈4 Hz) without stair-steps.
    static let timeline = Animation.smooth(duration: 0.30, extraBounce: 0)
    /// Mini-player bar: short enough to track audio, long enough to stay fluid.
    static let miniTimeline = Animation.smooth(duration: 0.40, extraBounce: 0)

    static func press(isPressed: Bool) -> Animation {
        isPressed ? pressDown : pressUp
    }

    /// Horizontal slide matching the artwork pager direction.
    static func trackSlideTransition(
        direction: CGFloat,
        enabled: Bool,
        distance: CGFloat = 28
    ) -> AnyTransition {
        guard enabled else { return .opacity }
        return .asymmetric(
            insertion: .offset(x: distance * direction)
                .combined(with: .opacity),
            removal: .offset(x: -distance * 0.68 * direction)
                .combined(with: .opacity)
        )
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
    static var scene: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.994)),
            removal: .opacity
        )
    }

    static var section: AnyTransition {
        .asymmetric(
            insertion: .opacity
                .combined(with: .offset(y: 8))
                .combined(with: .scale(scale: 0.997, anchor: .top)),
            removal: .opacity.combined(with: .offset(y: -3))
        )
    }

    static var artworkReveal: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.994))
    }

    static var miniPlayer: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .bottom)
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.985, anchor: .bottom)),
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
                    .opacity(phase.isIdentity ? 1 : 0.94)
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
                    offset: 6,
                    initialScale: 0.997
                )
            )
            .scrollTransition(.interactive, axis: .vertical) { view, phase in
                view
                    .opacity(phase.isIdentity || !enablesMotion ? 1 : 0.97)
            }
    }
}

extension View {
    func buFiHorizontalScrollMotion() -> some View {
        modifier(BuFiHorizontalScrollMotionModifier())
    }

    func buFiEntranceMotion(
        delay: TimeInterval = 0,
        offset: CGFloat = 6,
        initialScale: CGFloat = 0.997
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
