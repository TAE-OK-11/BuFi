import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject private var audio: AudioEngine
    @State private var palette = ArtworkPalette.fallback
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
                                onPalette: { palette = $0 }
                            )
                            .frame(width: 52, height: 52)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(song.title)
                                    .font(.system(size: 15, weight: .semibold))
                                    .lineLimit(1)
                                    .contentTransition(.interpolate)
                                Text(song.artist)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white.opacity(0.72))
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
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
                    }
                    .buttonStyle(BuFiPressStyle())
                    .accessibilityLabel(audio.isPlaying ? "일시정지" : "재생")
                }
                .padding(.horizontal, 7)
                .frame(height: 62)
                .id(song.id)
                .transition(
                    motionEnabled
                        ? .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        )
                        : .opacity
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
            .animation(
                motionEnabled
                    ? .interactiveSpring(response: 0.46, dampingFraction: 0.82)
                    : .none,
                value: song.id
            )
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
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.13), lineWidth: 0.7)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .buFiGlass(cornerRadius: 16, interactive: true)
            .padding(.horizontal, 9)
            .padding(.bottom, 8)
        }
    }
}
