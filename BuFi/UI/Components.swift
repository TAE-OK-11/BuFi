import AVKit
import SwiftUI
import UIKit

extension Color {
    init(_ rgba: RGBAColor) {
        self.init(
            .sRGB,
            red: rgba.red,
            green: rgba.green,
            blue: rgba.blue,
            opacity: rgba.alpha
        )
    }
}

extension TimeInterval {
    var playbackText: String {
        guard isFinite, self >= 0 else { return "0:00" }
        let total = Int(self)
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}

struct ArtworkView: View {
    @EnvironmentObject private var model: AppModel

    let coverArt: String?
    var size: CGFloat = 300
    var cornerRadius: CGFloat = 8
    var onPalette: ((ArtworkPalette) -> Void)?

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.white.opacity(0.14), Color.black.opacity(0.22)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "music.note")
                .font(.system(size: size * 0.22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.34))

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity.animation(.easeOut(duration: 0.22)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: "\(coverArt ?? "")-\(Int(size))") {
            image = nil
            guard let url = await model.artworkURL(id: coverArt, size: Int(size * 2)) else {
                onPalette?(.fallback)
                return
            }
            let loadedImage = try? await ArtworkStore.shared.image(
                for: url,
                pixelSize: max(size * UIScreen.main.scale, 96)
            )
            if let loaded = loadedImage {
                guard !Task.isCancelled else { return }
                image = loaded
                onPalette?(await ArtworkStore.shared.palette(for: url, image: loaded))
            } else {
                onPalette?(.fallback)
            }
        }
        .accessibilityHidden(true)
    }
}

struct AlbumCard: View {
    let album: Album
    var width: CGFloat = 166

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkView(coverArt: album.coverArt, size: width, cornerRadius: 7)
                .frame(width: width, height: width)
                .shadow(color: .black.opacity(0.24), radius: 12, y: 7)
            Text(album.name)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2)
                .foregroundStyle(.white)
            Text(album.artist)
                .font(.system(size: 13))
                .lineLimit(1)
                .foregroundStyle(.secondary)
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct SongRow: View {
    @EnvironmentObject private var audio: AudioEngine

    let song: Song
    let queue: [Song]
    var showsArtwork = true
    var onMore: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            if showsArtwork {
                ArtworkView(coverArt: song.coverArt, size: 54, cornerRadius: 5)
                    .frame(width: 54, height: 54)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(song.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(audio.currentSong?.id == song.id ? .green : .white)
                    .lineLimit(1)
                Text([song.artist, song.album].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if song.isStarred {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 17))
            }
            Button {
                onMore?()
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 38, height: 38)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(song.title) 더 보기")
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture {
            audio.play(song, in: queue)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            audio.play(song, in: queue)
        }
    }
}

struct SectionTitle: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 24, weight: .bold))
                .tracking(-0.6)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.activeTintColor = .systemGreen
        view.tintColor = .white
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct MiniPlayerView: View {
    @EnvironmentObject private var audio: AudioEngine
    @State private var palette = ArtworkPalette.fallback

    var body: some View {
        if let song = audio.currentSong {
            Button {
                audio.showPlayer = true
            } label: {
                VStack(spacing: 0) {
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
                            Text(song.artist)
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.72))
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        AirPlayButton()
                            .frame(width: 37, height: 37)
                        Button {
                            audio.togglePlayback()
                        } label: {
                            Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .frame(width: 42, height: 42)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(audio.isPlaying ? "일시정지" : "재생")
                    }
                    .padding(.horizontal, 7)
                    .frame(height: 62)

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
                    LinearGradient(
                        colors: [Color(palette.top), Color(palette.bottom)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(.white.opacity(0.1), lineWidth: 0.5)
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
        }
    }
}
