import SwiftUI

struct LegacyMiniPlayerView: View {
    @EnvironmentObject private var audio: AudioEngine
    @Environment(\.buFiMotionEnabled) private var motionEnabled
    @State private var palette = ArtworkPalette.fallback

    private let playerHeight: CGFloat = 68
    private let cornerRadius: CGFloat = 12

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
                            size: 56,
                            cornerRadius: 7,
                            onPalette: { palette = $0 }
                        )
                        .frame(width: 56, height: 56)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(song.title)
                                .font(.system(size: 15, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)

                            ZStack(alignment: .leading) {
                                if let lyric = activeMiniLyric {
                                    Text(lyric.text)
                                        .id("\(song.id)-\(lyric.id)")
                                        .transition(miniLyricTransition)
                                } else {
                                    Text(song.artist)
                                        .id("\(song.id)-artist")
                                        .transition(miniLyricTransition)
                                }
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.78))
                            .lineLimit(1)
                            .minimumScaleFactor(0.76)
                            .frame(maxWidth: .infinity, minHeight: 17, maxHeight: 17)
                            .clipped()
                            .animation(
                                motionEnabled ? BuFiMotion.miniLyrics : .none,
                                value: miniLyricAnimationID
                            )
                        }
                        .frame(maxWidth: .infinity, minHeight: 42, maxHeight: 42)
                        .clipped()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .allowsHitTesting(false)

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

    private var activeMiniLyric: LyricLine? {
        guard audio.lyrics.lines.indices.contains(audio.activeLyricIndex) else {
            return nil
        }
        let line = audio.lyrics.lines[audio.activeLyricIndex]
        return line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : line
    }

    private var miniLyricAnimationID: String {
        guard let songID = audio.currentSong?.id else { return "empty" }
        return "\(songID)-\(activeMiniLyric?.id ?? -1)"
    }

    private var miniLyricTransition: AnyTransition {
        guard motionEnabled else { return .opacity }
        return .asymmetric(
            insertion: .offset(y: 3).combined(with: .opacity),
            removal: .offset(y: -3).combined(with: .opacity)
        )
    }
}
