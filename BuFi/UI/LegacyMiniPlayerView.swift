import SwiftUI

struct LegacyMiniPlayerView: View {
    @EnvironmentObject private var audio: AudioEngine
    @State private var palette = ArtworkPalette.fallback
    @AppStorage("motion-enabled") private var motionEnabled = true

    var body: some View {
        if let song = audio.currentSong {
            ZStack {
                Button {
                    audio.showPlayer = true
                } label: {
                    Color.clear
                        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(song.title), \(song.artist)")

                VStack(spacing: 0) {
                    HStack(spacing: 9) {
                        ArtworkView(
                            coverArt: song.coverArt,
                            size: 50,
                            cornerRadius: 5,
                            onPalette: { palette = $0 }
                        )
                        .frame(width: 50, height: 50)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(song.title)
                                .font(.system(size: 15, weight: .semibold))
                                .lineLimit(1)
                                .contentTransition(.interpolate)
                            Text(song.artist)
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.76))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .allowsHitTesting(false)

                        AirPlayButton(lightContent: true)
                            .frame(width: 36, height: 36)

                        Button {
                            audio.togglePlayback()
                        } label: {
                            Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 21, weight: .semibold))
                                .frame(width: 40, height: 40)
                        }
                        .buttonStyle(BuFiPressStyle())
                        .accessibilityLabel(audio.isPlaying ? "일시정지" : "재생")
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 58)
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
                            Color.white.opacity(0.19)
                            Color.white
                                .frame(
                                    width: proxy.size.width *
                                    min(max(audio.elapsed / max(audio.duration, 1), 0), 1)
                                )
                        }
                    }
                    .frame(height: 2)
                }
            }
            .animation(
                motionEnabled
                    ? .interactiveSpring(response: 0.42, dampingFraction: 0.84)
                    : .none,
                value: song.id
            )
            .foregroundStyle(.white)
            .background(
                LinearGradient(
                    colors: [
                        Color(palette.top).opacity(0.96),
                        Color(palette.bottom).opacity(0.98)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.white.opacity(0.11), lineWidth: 0.6)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.34), radius: 14, y: 7)
        }
    }
}
