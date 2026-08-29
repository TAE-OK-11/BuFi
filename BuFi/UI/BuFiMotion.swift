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
    static let playerEntrance = Animation.smooth(duration: 0.20, extraBounce: 0)
    /// One curve carries a whole track change. The artwork page, the header
    /// text, the metadata text, and the mini player all hand off on this
    /// timing, so a skip reads as a single movement rather than as several
    /// independently timed pieces arriving one after another.
    static let trackChange = Animation.smooth(duration: 0.34, extraBounce: 0)
    static let trackText = BuFiMotion.trackChange
    static let trackPage = BuFiMotion.trackChange
    static let miniTrack = BuFiMotion.trackChange
    static let color = Animation.smooth(duration: 0.34, extraBounce: 0)
    static let page = Animation.smooth(duration: 0.36, extraBounce: 0)
    static let miniLyricsScroll = Animation.smooth(duration: 0.48, extraBounce: 0)
    static let lyricsCard = Animation.spring(duration: 0.40, bounce: 0.028)
    static let lyrics = Animation.smooth(duration: 0.38, extraBounce: 0)
    static let lyricsPanel = Animation.spring(duration: 0.36, bounce: 0.04)
    /// Rolls a clock digit without the overshoot a spring would add.
    static let timeText = Animation.smooth(duration: 0.18, extraBounce: 0)

    /// Carries a seek bar from one periodic playback tick to the next.
    ///
    /// Position arrives in discrete steps (4 Hz in the player, 1 Hz behind the
    /// mini player), so the curve joining two steps decides whether playback
    /// looks like motion or like a repeating twitch. An eased curve accelerates
    /// and decelerates inside every step, which at 4 Hz reads as a stutter four
    /// times a second. Spending exactly one tick moving linearly makes
    /// consecutive steps join into constant, uninterrupted travel.
    static func progress(tick: TimeInterval) -> Animation {
        .linear(duration: max(0.05, min(tick, 2.0)))
    }

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

    /// A track change is one movement, so every piece of it shares a timing at
    /// any tier. Only the duration shortens as the tier drops.
    static func trackChange(for tier: BuFiMotionTier) -> Animation {
        switch tier {
        case .off, .minimal:
            return .smooth(duration: 0.22, extraBounce: 0)
        case .reduced:
            return .smooth(duration: 0.28, extraBounce: 0)
        case .full:
            return trackChange
        }
    }

    static func trackText(for tier: BuFiMotionTier) -> Animation {
        trackChange(for: tier)
    }

    static func trackPage(for tier: BuFiMotionTier) -> Animation {
        trackChange(for: tier)
    }

    static func miniTrack(for tier: BuFiMotionTier) -> Animation {
        trackChange(for: tier)
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
    // Sub-percent scale terms read as no movement at all, yet each one puts a
    // transform on content that is already crossfading. These transitions
    // carry only the fade and the travel that are actually visible.
    static var scene: AnyTransition {
        .asymmetric(insertion: .opacity, removal: .opacity)
    }

    static var section: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 8)),
            removal: .opacity.combined(with: .offset(y: -3))
        )
    }

    static var artworkReveal: AnyTransition {
        .opacity
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

    func body(content: Content) -> some View {
        let enablesMotion = motionTier.enablesAnimation
        content
            .opacity(hasAppeared || !enablesMotion ? 1 : 0)
            .offset(y: hasAppeared || !enablesMotion ? 0 : offset)
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
        // Sections fade up once as they mount. They deliberately carry no
        // scroll transition: dimming every section to 0.97 while a finger is
        // on the screen is too slight to read as an effect, yet it runs a
        // transition body for each one on every frame of the scroll.
        content.modifier(
            BuFiEntranceMotionModifier(delay: delay, offset: 6)
        )
    }
}

extension View {
    func buFiHorizontalScrollMotion() -> some View {
        modifier(BuFiHorizontalScrollMotionModifier())
    }

    func buFiEntranceMotion(
        delay: TimeInterval = 0,
        offset: CGFloat = 6
    ) -> some View {
        modifier(BuFiEntranceMotionModifier(delay: delay, offset: offset))
    }

    func buFiVerticalSectionMotion(delay: TimeInterval = 0) -> some View {
        modifier(BuFiVerticalSectionMotionModifier(delay: delay))
    }
}
