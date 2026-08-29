import Foundation
import SwiftUI

extension EnvironmentValues {
    /// A lightweight, app-wide motion policy supplied by the root view.
    ///
    /// Keep the default enabled so previews and independently hosted views retain
    /// their expected motion. The app root can disable it for Reduce Motion, Low
    /// Power Mode, or the in-app motion setting. Thermal pressure does not slow
    /// player animations.
    var buFiMotionEnabled: Bool {
        get { buFiMotionTier != .off }
        set { buFiMotionTier = newValue ? .full : .off }
    }

    var buFiMotionTier: BuFiMotionTier {
        get {
            self[BuFiMotionTierKey.self]
        }
        set {
            self[BuFiMotionTierKey.self] = newValue
        }
    }
}

private struct BuFiMotionTierKey: EnvironmentKey {
    static let defaultValue: BuFiMotionTier = .full
}

/// Motion quality gate. Only `.off` disables animation; thermal pressure does
/// not downgrade curves or player transitions.
enum BuFiMotionTier: Int, Comparable, Sendable {
    case off = 0
    case minimal = 1
    case reduced = 2
    case full = 3

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var enablesAnimation: Bool { self != .off }
    var enablesScrollTransition: Bool { self == .full }
    var enablesDrawingGroup: Bool { self == .full }
    var enablesPaletteExtraction: Bool { self != .minimal }
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
    static let playerEntrance = Animation.spring(duration: 0.40, bounce: 0.034)
    static let screenEntrance = Animation.spring(duration: 0.48, bounce: 0.028)
    /// Fast horizontal text hand-off; smooth curve keeps motion fluid at short duration.
    static let trackText = Animation.smooth(duration: 0.30, extraBounce: 0)
    static let trackPage = Animation.spring(duration: 0.36, bounce: 0.048)
    static let miniTrack = Animation.smooth(duration: 0.30, extraBounce: 0)
    static let artworkTouch = Animation.spring(duration: 0.20, bounce: 0.10)
    static let color = Animation.smooth(duration: 0.34, extraBounce: 0)
    static let page = Animation.smooth(duration: 0.36, extraBounce: 0)
    static let miniLyricsScroll = Animation.smooth(duration: 0.48, extraBounce: 0)
    static let miniLyrics = Animation.smooth(duration: 0.48, extraBounce: 0)
    static let lyricsCard = Animation.spring(duration: 0.40, bounce: 0.028)
    static let lyrics = Animation.smooth(duration: 0.38, extraBounce: 0)
    static let lyricsPanel = Animation.spring(duration: 0.36, bounce: 0.04)
    /// Interpolates between periodic playback ticks (≈4 Hz) without stair-steps.
    static let timeline = Animation.smooth(duration: 0.22, extraBounce: 0)
    /// Mini-player bar: short enough to track audio, long enough to stay fluid.
    static let miniTimeline = Animation.smooth(duration: 0.26, extraBounce: 0)

    static func press(isPressed: Bool, tier: BuFiMotionTier = .full) -> Animation {
        let down = tier == .minimal
            ? Animation.smooth(duration: 0.08, extraBounce: 0)
            : pressDown
        let up = tier <= .reduced
            ? Animation.smooth(duration: 0.22, extraBounce: 0)
            : pressUp
        return isPressed ? down : up
    }

    static func resolveTier(
        userPreference: Bool,
        reduceMotion: Bool,
        lowPowerMode: Bool,
        thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    ) -> BuFiMotionTier {
        _ = thermalState
        guard userPreference, !reduceMotion, !lowPowerMode else { return .off }
        return .full
    }

    static func isEnabled(
        userPreference: Bool,
        reduceMotion: Bool,
        lowPowerMode: Bool,
        thermalState: ProcessInfo.ThermalState
    ) -> Bool {
        resolveTier(
            userPreference: userPreference,
            reduceMotion: reduceMotion,
            lowPowerMode: lowPowerMode,
            thermalState: thermalState
        ).enablesAnimation
    }

    static func trackText(for tier: BuFiMotionTier) -> Animation {
        switch tier {
        case .off, .minimal:
            return .smooth(duration: 0.22, extraBounce: 0)
        case .reduced:
            return .smooth(duration: 0.34, extraBounce: 0)
        case .full:
            return trackText
        }
    }

    static func trackPage(for tier: BuFiMotionTier) -> Animation {
        switch tier {
        case .off, .minimal:
            return .smooth(duration: 0.26, extraBounce: 0)
        case .reduced:
            return .smooth(duration: 0.40, extraBounce: 0)
        case .full:
            return trackPage
        }
    }

    static func miniTrack(for tier: BuFiMotionTier) -> Animation {
        switch tier {
        case .off, .minimal:
            return .smooth(duration: 0.24, extraBounce: 0)
        case .reduced:
            return .smooth(duration: 0.36, extraBounce: 0)
        case .full:
            return miniTrack
        }
    }

    static func color(for tier: BuFiMotionTier) -> Animation {
        switch tier {
        case .off, .minimal:
            return .smooth(duration: 0.24, extraBounce: 0)
        case .reduced:
            return .smooth(duration: 0.40, extraBounce: 0)
        case .full:
            return color
        }
    }

    static func content(for tier: BuFiMotionTier) -> Animation {
        switch tier {
        case .off:
            return .linear(duration: 0)
        case .minimal:
            return .smooth(duration: 0.20, extraBounce: 0)
        case .reduced:
            return .smooth(duration: 0.30, extraBounce: 0)
        case .full:
            return content
        }
    }

    static func homeEntrance(for tier: BuFiMotionTier) -> Animation {
        switch tier {
        case .off:
            return .linear(duration: 0)
        case .minimal:
            return .smooth(duration: 0.24, extraBounce: 0)
        case .reduced:
            return .smooth(duration: 0.36, extraBounce: 0)
        case .full:
            return homeEntrance
        }
    }

    static func page(for tier: BuFiMotionTier) -> Animation {
        switch tier {
        case .off:
            return .linear(duration: 0)
        case .minimal:
            return .smooth(duration: 0.20, extraBounce: 0)
        case .reduced:
            return .smooth(duration: 0.28, extraBounce: 0)
        case .full:
            return page
        }
    }

    static func fade(for tier: BuFiMotionTier) -> Animation {
        switch tier {
        case .off:
            return .linear(duration: 0)
        case .minimal:
            return .smooth(duration: 0.18, extraBounce: 0)
        case .reduced:
            return .smooth(duration: 0.22, extraBounce: 0)
        case .full:
            return fade
        }
    }

    static func transition(for tier: BuFiMotionTier) -> AnyTransition {
        switch tier {
        case .off:
            return .opacity
        case .minimal:
            return .opacity
        case .reduced, .full:
            return BuFiTransition.scene
        }
    }

    static func miniPlayerTransition(for tier: BuFiMotionTier) -> AnyTransition {
        switch tier {
        case .off, .minimal:
            return .opacity
        case .reduced:
            return .move(edge: .bottom).combined(with: .opacity)
        case .full:
            return BuFiTransition.miniPlayer
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
    @Environment(\.buFiMotionTier) private var motionTier

    @ViewBuilder
    func body(content: Content) -> some View {
        if motionTier.enablesScrollTransition {
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
    @Environment(\.buFiMotionTier) private var motionTier
    @State private var hasAppeared = false

    let delay: TimeInterval
    let offset: CGFloat
    let initialScale: CGFloat

    func body(content: Content) -> some View {
        let enablesMotion = motionTier.enablesAnimation
        content
            .opacity(hasAppeared || !enablesMotion ? 1 : 0)
            .offset(y: hasAppeared || !enablesMotion ? 0 : offset)
            .scaleEffect(
                hasAppeared || !enablesMotion ? 1 : initialScale,
                anchor: .top
            )
            .animation(
                enablesMotion
                    ? BuFiMotion.homeEntrance(for: motionTier).delay(delay)
                    : .none,
                value: hasAppeared
            )
            .task {
                guard !hasAppeared else { return }
                if enablesMotion {
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                }
                hasAppeared = true
            }
    }
}

private struct BuFiVerticalSectionMotionModifier: ViewModifier {
    @Environment(\.buFiMotionTier) private var motionTier

    let delay: TimeInterval

    func body(content: Content) -> some View {
        content
            .modifier(
                BuFiEntranceMotionModifier(
                    delay: delay,
                    offset: 6,
                    initialScale: 0.997
                )
            )
            .modifier(BuFiVerticalScrollTransitionModifier())
    }
}

private struct BuFiVerticalScrollTransitionModifier: ViewModifier {
    @Environment(\.buFiMotionTier) private var motionTier

    @ViewBuilder
    func body(content: Content) -> some View {
        if motionTier.enablesScrollTransition {
            content.scrollTransition(.interactive, axis: .vertical) { view, phase in
                view
                    .opacity(phase.isIdentity ? 1 : 0.97)
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
