import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject private var currentPlayback: CurrentPlaybackState
    @Environment(\.buFiMotionEnabled) private var motionEnabled
    @Environment(\.colorScheme) private var colorScheme
    @State private var palette: ArtworkPalette?
    @State private var paletteArtworkIdentity: PlayerArtworkIdentity?
    @State private var transitionDirection: CGFloat = 1

    private let playerHeight: CGFloat = 60
    private let cornerRadius: CGFloat = 10
    private let audio = AudioEngine.shared

    var body: some View {
        if let item = currentPlayback.item {
            let song = item.song
            let artworkIdentity = item.artworkIdentity
            ZStack {
                Button {
                    audio.showPlayer = true
                } label: {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.clear)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .contentShape(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(song.title), \(song.artist)")
                .accessibilityHint("전체 플레이어 열기")

                VStack(spacing: 0) {
                    HStack(spacing: 9) {
                        ZStack {
                            ArtworkView(
                                coverArt: song.artworkID,
                                size: 50,
                                cornerRadius: 5,
                                cacheRevision: artworkIdentity.artworkRevision,
                                onPalette: { nextPalette in
                                    guard currentPlayback.item?.artworkIdentity == artworkIdentity else {
                                        return
                                    }
                                    if nextPalette == .fallback {
                                        palette = nil
                                        paletteArtworkIdentity = nil
                                    } else {
                                        palette = nextPalette
                                        paletteArtworkIdentity = artworkIdentity
                                    }
                                }
                            )
                            .id(artworkIdentity)
                            .transition(trackArtworkTransition)
                        }
                        .frame(width: 50, height: 50)
                        .animation(
                            motionEnabled ? BuFiMotion.trackArtwork : .none,
                            value: artworkIdentity
                        )

                        ZStack(alignment: .leading) {
                            VStack(alignment: .leading, spacing: 3) {
                                OverflowMarqueeText(
                                    text: song.title,
                                    font: .system(size: 15, weight: .semibold)
                                )
                                Text(song.artist)
                                    .font(.system(size: 13))
                                    .foregroundStyle(miniPlayerForeground.opacity(0.72))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.76)
                            }
                            .id(item.id)
                            .transition(trackTextTransition)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                        .allowsHitTesting(false)
                        .animation(
                            motionEnabled ? BuFiMotion.trackText : .none,
                            value: item.id
                        )

                        AirPlayButton(lightContent: !usesDarkForeground)
                            .frame(width: 36, height: 36)
                            .zIndex(2)

                        MiniPlayerPlaybackButton {
                            audio.togglePlayback()
                        }
                        .zIndex(2)
                    }
                    .padding(.horizontal, 6)
                    .frame(height: playerHeight - 2)

                    MiniPlayerProgressView(
                        timeline: audio.timeline,
                        tint: miniPlayerForeground
                    )
                    .frame(height: 2)
                    .allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity)
                .frame(height: playerHeight)
            }
            .frame(maxWidth: .infinity)
            .frame(height: playerHeight)
            .fixedSize(horizontal: false, vertical: true)
            .clipped()
            .foregroundStyle(miniPlayerForeground)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(miniPlayerBackground)
                    .animation(motionEnabled ? BuFiMotion.color : .none, value: resolvedPalette)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(miniPlayerForeground.opacity(0.16), lineWidth: 0.7)
                    .animation(motionEnabled ? BuFiMotion.color : .none, value: resolvedPalette)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.20 : 0.09),
                radius: colorScheme == .dark ? 12 : 9,
                y: colorScheme == .dark ? 6 : 4
            )
            .onChange(of: currentPlayback.index) { previous, next in
                transitionDirection = next >= previous ? 1 : -1
            }
        }
    }

    private var miniPlayerBackground: Color {
        resolvedPalette.map { Color($0.top) } ?? BuFiTheme.elevated
    }

    private var miniPlayerForeground: Color {
        usesDarkForeground ? .black.opacity(0.86) : .white
    }

    private var usesDarkForeground: Bool {
        guard let palette = resolvedPalette else { return colorScheme == .light }
        return relativeLuminance(palette.top) >= 0.18
    }

    private var resolvedPalette: ArtworkPalette? {
        guard paletteArtworkIdentity == currentArtworkIdentity else { return nil }
        return palette
    }

    private var currentArtworkIdentity: PlayerArtworkIdentity? {
        currentPlayback.item?.artworkIdentity
    }

    private func relativeLuminance(_ color: RGBAColor) -> Double {
        func linear(_ component: Double) -> Double {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.red)
            + 0.7152 * linear(color.green)
            + 0.0722 * linear(color.blue)
    }

    private var trackTextTransition: AnyTransition {
        guard motionEnabled else { return .opacity }
        return .asymmetric(
            insertion: .offset(x: 18 * transitionDirection).combined(with: .opacity),
            removal: .offset(x: -14 * transitionDirection).combined(with: .opacity)
        )
    }

    private var trackArtworkTransition: AnyTransition {
        guard motionEnabled else { return .opacity }
        return .asymmetric(
            insertion: .offset(x: 14 * transitionDirection)
                .combined(with: .opacity),
            removal: .offset(x: -12 * transitionDirection)
                .combined(with: .opacity)
        )
    }
}

private struct MiniPlayerPlaybackButton: View {
    @EnvironmentObject private var playbackControl: PlaybackControlState
    @Environment(\.buFiMotionEnabled) private var motionEnabled
    @AppStorage("haptics-enabled") private var hapticsEnabled = true

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if playbackControl.isBuffering {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: playbackControl.wantsPlayback ? "pause.fill" : "play.fill")
                        .font(.system(size: 21, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(BuFiPressStyle())
        .animation(
            motionEnabled ? BuFiMotion.symbol : .none,
            value: playbackControl.wantsPlayback
        )
        .sensoryFeedback(.selection, trigger: playbackControl.wantsPlayback) {
            oldValue, newValue in
            hapticsEnabled && motionEnabled && oldValue != newValue
        }
        .accessibilityLabel(playbackControl.wantsPlayback ? "일시정지" : "재생")
    }
}

private struct MiniPlayerProgressView: View {
    @EnvironmentObject private var playbackControl: PlaybackControlState
    @Environment(\.buFiMotionEnabled) private var motionEnabled
    @ObservedObject var timeline: PlaybackTimeline
    let tint: Color

    var body: some View {
        let resolvedProgress = progress
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                tint.opacity(0.18)
                tint.opacity(0.94)
                    .frame(width: proxy.size.width * resolvedProgress)
            }
        }
        .animation(
            motionEnabled && playbackControl.wantsPlayback
                ? BuFiMotion.miniTimeline
                : .none,
            value: resolvedProgress
        )
    }

    private var progress: CGFloat {
        guard timeline.elapsed.isFinite,
              timeline.duration.isFinite,
              timeline.duration > 0 else {
            return 0
        }
        return CGFloat(min(max(timeline.elapsed / timeline.duration, 0), 1))
    }
}
