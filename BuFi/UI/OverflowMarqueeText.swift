import SwiftUI

/// A single-line now-playing label that remains static when it fits and gently
/// pans only the overflow. The animation task is keyed by geometry, cancels
/// with the view, pauses outside the active scene, and respects Reduce Motion.
@MainActor
struct OverflowMarqueeText: View {
    enum RestingAlignment: Sendable {
        case leading
        case center
    }

    let text: String
    let font: Font
    var tracking: CGFloat = 0
    var restingAlignment: RestingAlignment = .leading

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.buFiMotionEnabled) private var motionEnabled
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.scenePhase) private var scenePhase

    @State private var textSize = CGSize.zero
    @State private var containerSize = CGSize.zero
    @State private var travel: CGFloat = 0

    var body: some View {
        ZStack(alignment: resolvedAlignment) {
            Text(text)
                .font(font)
                .tracking(tracking)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .offset(x: signedOffset)
                .onGeometryChange(for: CGSize.self) { proxy in
                    proxy.size
                } action: { size in
                    textSize = size
                }
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
        .clipped()
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { size in
            containerSize = size
        }
        .task(id: animationIdentity) {
            await runAnimation(distance: overflowDistance)
        }
        .accessibilityLabel(text)
    }

    private var overflowDistance: CGFloat {
        max(0, textSize.width - containerSize.width + 2)
    }

    private var canAnimate: Bool {
        overflowDistance > 1
            && motionEnabled
            && !reduceMotion
            && scenePhase == .active
    }

    private var resolvedAlignment: Alignment {
        guard overflowDistance <= 1 else { return .leading }
        return restingAlignment == .center ? .center : .leading
    }

    private var frameAlignment: Alignment {
        restingAlignment == .center ? .center : .leading
    }

    private var signedOffset: CGFloat {
        layoutDirection == .rightToLeft ? travel : -travel
    }

    private var animationIdentity: AnimationIdentity {
        AnimationIdentity(
            text: text,
            textWidth: textSize.width.rounded(.toNearestOrAwayFromZero),
            containerWidth: containerSize.width.rounded(.toNearestOrAwayFromZero),
            canAnimate: canAnimate
        )
    }

    private func runAnimation(distance: CGFloat) async {
        travel = 0
        guard canAnimate else { return }

        do {
            try await Task.sleep(for: .milliseconds(1_100))
            while !Task.isCancelled {
                let outwardDuration = max(2.8, Double(distance / 28))
                withAnimation(.linear(duration: outwardDuration)) {
                    travel = distance
                }
                try await Task.sleep(for: .seconds(outwardDuration + 1.25))

                let returnDuration = max(1.6, Double(distance / 52))
                withAnimation(.linear(duration: returnDuration)) {
                    travel = 0
                }
                try await Task.sleep(for: .seconds(returnDuration + 1.6))
            }
        } catch {
            travel = 0
        }
    }

    private struct AnimationIdentity: Equatable {
        let text: String
        let textWidth: CGFloat
        let containerWidth: CGFloat
        let canAnimate: Bool
    }
}
