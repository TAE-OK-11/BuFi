import SwiftUI

struct LegacyMiniPlayerView: View {
    @EnvironmentObject private var audio: AudioEngine
    @Environment(\.buFiMotionEnabled) private var motionEnabled
    @State private var palette = ArtworkPalette.fallback

    private let playerHeight: CGFloat = 60
    private let cornerRadius: CGFloat = 10

    var body: some View {
        if let song = audio.currentSong {
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
                            cornerRadius: 5,
                            onPalette: { palette = $0 }
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
                                    .foregroundStyle(.white.opacity(0.78))
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

                        AirPlayButton(lightContent: true)
                            .frame(width: 36, height: 36)

                        Button {
                            audio.togglePlayback()
                        } label: {
                            Image(systemName: audio.wantsPlayback ? "pause.fill" : "play.fill")
                                .font(.system(size: 21, weight: .semibold))
                                .frame(width: 40, height: 40)
                        }
                        .buttonStyle(BuFiPressStyle())
                        .accessibilityLabel(audio.wantsPlayback ? "일시정지" : "재생")
                    }
                    .padding(.horizontal, 6)
                    .frame(height: playerHeight - 2)

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
                    .allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity)
                .frame(height: playerHeight)
            }
            .frame(maxWidth: .infinity)
            .frame(height: playerHeight)
            .fixedSize(horizontal: false, vertical: true)
            .clipped()
            .foregroundStyle(.white)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(palette.top).opacity(0.78),
                                    Color(palette.bottom).opacity(0.82)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.white.opacity(0.14), lineWidth: 0.6)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.20), radius: 12, y: 6)
            .animation(motionEnabled ? BuFiMotion.color : .none, value: palette)
            .onChange(of: song.id) { _, _ in
                palette = .fallback
            }
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
