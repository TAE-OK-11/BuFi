import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject private var audio: AudioEngine
    @State private var palette = ArtworkPalette.fallback
    @State private var transitionDirection: CGFloat = 1
    @AppStorage("motion-enabled") private var motionEnabled = true

    var body: some View {
        if let song = audio.currentSong {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button {
                        audio.showPlayer = true
                    } label: {
                        HStack(spacing: 10) {
                            ArtworkView(
                                coverArt: song.coverArt,
                                size: 52,
                                cornerRadius: 5,
                                onPalette: { nextPalette in
                                    withAnimation(BuFiMotion.color) {
                                        palette = nextPalette
                                    }
                                }
                            )
                            .frame(width: 52, height: 52)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(song.title)
                                    .font(.system(size: 15, weight: .semibold))
                                    .lineLimit(1)
                                Text(song.artist)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white.opacity(0.72))
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // 곡이 바뀔 때 아트워크+제목만 슬라이드되고, AirPlay/재생 버튼은
                        // 고정된 채로 유지되도록 트랜지션 범위를 여기로 한정한다.
                        .id(song.id)
                        .transition(
                            motionEnabled
                                ? .asymmetric(
                                    insertion: .move(edge: transitionDirection > 0 ? .trailing : .leading).combined(with: .opacity),
                                    removal: .move(edge: transitionDirection > 0 ? .leading : .trailing).combined(with: .opacity)
                                )
                                : .opacity
                        )
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(song.title), \(song.artist)")

                    AirPlayButton(lightContent: true)
                        .frame(width: 37, height: 37)
                    Button {
                        audio.togglePlayback()
                    } label: {
                        Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .frame(width: 42, height: 42)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(BuFiPressStyle())
                    .accessibilityLabel(audio.isPlaying ? "일시정지" : "재생")
                }
                .padding(.horizontal, 7)
                .frame(height: 62)
                .animation(
                    motionEnabled
                        ? .interactiveSpring(response: 0.46, dampingFraction: 0.82)
                        : .none,
                    value: song.id
                )

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Color.white.opacity(0.18)
                        Color.white
                            .frame(
                                width: proxy.size.width *
                                min(max(audio.elapsed / max(audio.duration, 1), 0), 1)
                            )
                    }
                }
                .frame(height: 2)
            }
            .foregroundStyle(.white)
            .background(
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    LinearGradient(
                        colors: [Color(palette.top), Color(palette.bottom)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .opacity(0.72)
                }
                .animation(BuFiMotion.color, value: palette)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.13), lineWidth: 0.7)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .buFiGlass(cornerRadius: 16, interactive: true)
            .padding(.horizontal, 9)
            .padding(.bottom, 8)
            .onChange(of: audio.queueIndex) { oldIndex, newIndex in
                transitionDirection = newIndex >= oldIndex ? 1 : -1
            }
        }
    }
}
