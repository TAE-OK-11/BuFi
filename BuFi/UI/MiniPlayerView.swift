import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject private var playbackItem: PlaybackItemState
    @EnvironmentObject private var playbackControl: PlaybackControlState
    @Environment(\.buFiMotionEnabled) private var motionEnabled
    @Environment(\.colorScheme) private var colorScheme

    private let playerHeight: CGFloat = 60
    private let cornerRadius: CGFloat = 10
    private let audio = AudioEngine.shared

    var body: some View {
        if let song = playbackItem.currentSong {
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
                        ArtworkView(
                            coverArt: song.coverArt,
                            size: 50,
                            cornerRadius: 5
                        )
                        .frame(width: 50, height: 50)

                        ZStack(alignment: .leading) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(song.title)
                                    .font(.system(size: 15, weight: .semibold))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.82)
                                Text(song.artist)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.76)
                            }
                            .id(song.id)
                            .transition(trackTextTransition)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .allowsHitTesting(false)
                        .animation(
                            motionEnabled ? BuFiMotion.trackText : .none,
                            value: song.id
                        )

                        AirPlayButton(lightContent: colorScheme == .dark)
                            .frame(width: 36, height: 36)

                        Button {
                            audio.togglePlayback()
                        } label: {
                            Image(systemName: playbackControl.wantsPlayback ? "pause.fill" : "play.fill")
                                .font(.system(size: 21, weight: .semibold))
                                .frame(width: 40, height: 40)
                        }
                        .buttonStyle(BuFiPressStyle())
                        .accessibilityLabel(playbackControl.wantsPlayback ? "일시정지" : "재생")
                    }
                    .padding(.horizontal, 6)
                    .frame(height: playerHeight - 2)

                    MiniPlayerProgressView(timeline: audio.timeline)
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
            .foregroundStyle(.primary)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(BuFiTheme.elevated)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(BuFiTheme.separator.opacity(0.32), lineWidth: 0.7)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.20 : 0.09),
                radius: colorScheme == .dark ? 12 : 9,
                y: colorScheme == .dark ? 6 : 4
            )
        }
    }

    private var trackTextTransition: AnyTransition {
        guard motionEnabled else { return .opacity }
        return .asymmetric(
            insertion: .offset(y: 5).combined(with: .opacity),
            removal: .offset(y: -4).combined(with: .opacity)
        )
    }
}

private struct MiniPlayerProgressView: View {
    @ObservedObject var timeline: PlaybackTimeline

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Color.secondary.opacity(0.18)
                BuFiTheme.accent
                    .frame(width: proxy.size.width * progress)
            }
        }
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
