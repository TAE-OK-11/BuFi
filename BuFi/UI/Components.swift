import AVKit
import SwiftUI
import UIKit

enum BuFiTheme {
    static let accent = Color(red: 0.98, green: 0.20, blue: 0.34)
    static let accentSoft = Color(red: 1.00, green: 0.38, blue: 0.46)
    static let deezerGlow = Color(red: 0.56, green: 0.26, blue: 0.98)
    static let background = Color(uiColor: .systemBackground)
    static let elevated = Color(uiColor: .secondarySystemBackground)
    static let tertiary = Color(uiColor: .tertiarySystemBackground)
    static let separator = Color(uiColor: .separator)
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system: "시스템 설정"
        case .light: "라이트"
        case .dark: "다크"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

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

private struct BuFiGlassModifier: ViewModifier {
    let cornerRadius: CGFloat
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(
                interactive ? .regular.interactive() : .regular,
                in: .rect(cornerRadius: cornerRadius)
            )
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(
                    cornerRadius: cornerRadius,
                    style: .continuous
                ))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 0.6)
                }
        }
    }
}

extension View {
    func buFiGlass(cornerRadius: CGFloat, interactive: Bool = false) -> some View {
        modifier(BuFiGlassModifier(cornerRadius: cornerRadius, interactive: interactive))
    }
}

struct BuFiPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .brightness(configuration.isPressed ? -0.025 : 0)
            .animation(
                .interactiveSpring(response: 0.28, dampingFraction: 0.72, blendDuration: 0.08),
                value: configuration.isPressed
            )
    }
}

struct BuFiScreenBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            BuFiTheme.background
            LinearGradient(
                colors: [
                    BuFiTheme.accent.opacity(colorScheme == .dark ? 0.085 : 0.045),
                    BuFiTheme.deezerGlow.opacity(colorScheme == .dark ? 0.035 : 0.018),
                    .clear
                ],
                startPoint: .topLeading,
                endPoint: .init(x: 0.66, y: 0.38)
            )
        }
        .ignoresSafeArea()
    }
}

struct ArtworkView: View {
    @EnvironmentObject private var model: AppModel

    let coverArt: String?
    var remoteURL: String?
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
        .task(id: "\(coverArt ?? "")-\(remoteURL ?? "")-\(Int(size))") {
            image = nil
            var candidates: [URL] = []
            if let remoteURL,
               let url = URL(string: remoteURL),
               url.scheme?.lowercased() == "https" {
                candidates.append(url)
            }
            if let coverURL = await model.artworkURL(id: coverArt, size: Int(size * 2)) {
                candidates.append(coverURL)
            }

            for url in candidates {
                guard !Task.isCancelled else { return }
                guard let loaded = try? await ArtworkStore.shared.image(
                    for: url,
                    pixelSize: max(size * UIScreen.main.scale, 96)
                ) else {
                    continue
                }
                guard !Task.isCancelled else { return }
                image = loaded
                onPalette?(await ArtworkStore.shared.palette(for: url, image: loaded))
                return
            }
            onPalette?(.fallback)
        }
        .accessibilityHidden(true)
    }
}

struct AlbumCard: View {
    let album: Album
    var width: CGFloat = 166
    @AppStorage("motion-enabled") private var motionEnabled = true

    @ViewBuilder
    var body: some View {
        if motionEnabled {
            card
                .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                    content
                        .scaleEffect(phase.isIdentity ? 1 : 0.965)
                        .opacity(phase.isIdentity ? 1 : 0.86)
                }
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkView(coverArt: album.coverArt, size: width, cornerRadius: 7)
                .frame(width: width, height: width)
                .shadow(color: .black.opacity(0.24), radius: 12, y: 7)
            Text(album.name)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2)
                .foregroundStyle(.primary)
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
                    .foregroundStyle(
                        audio.currentSong?.id == song.id ? BuFiTheme.accent : .primary
                    )
                    .lineLimit(1)
                Text([song.artist, song.album].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if song.isStarred {
                Image(systemName: "heart.fill")
                    .foregroundStyle(BuFiTheme.accent)
                    .font(.system(size: 17))
            }
            if let onMore {
                Button(action: onMore) {
                    Image(systemName: "ellipsis")
                        .frame(width: 38, height: 38)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(song.title) 더 보기")
            }
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
            Text(LocalizedStringKey(title))
                .font(.system(size: 24, weight: .bold))
                .tracking(-0.6)
            Spacer()
            if let trailing {
                Text(LocalizedStringKey(trailing))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct InteractiveSeekBar: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var tint: Color = .white
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var isEditing = false

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let fraction = normalized(value)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(tint.opacity(isEditing ? 0.34 : 0.24))
                    .frame(height: isEditing ? 7 : 4)
                Capsule()
                    .fill(tint)
                    .frame(width: max(isEditing ? 7 : 4, width * fraction))
                    .frame(height: isEditing ? 7 : 4)
                Circle()
                    .fill(tint)
                    .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
                    .frame(width: isEditing ? 19 : 14, height: isEditing ? 19 : 14)
                    .offset(
                        x: max(
                            0,
                            min(
                                width - (isEditing ? 19 : 14),
                                width * fraction - (isEditing ? 9.5 : 7)
                            )
                        )
                    )
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isEditing {
                            isEditing = true
                            onEditingChanged(true)
                        }
                        value = denormalized(gesture.location.x / width)
                    }
                    .onEnded { gesture in
                        value = denormalized(gesture.location.x / width)
                        isEditing = false
                        onEditingChanged(false)
                    }
            )
            .animation(
                .interactiveSpring(response: 0.26, dampingFraction: 0.78),
                value: isEditing
            )
        }
        .frame(height: 28)
        .accessibilityElement()
        .accessibilityLabel("재생 위치")
        .accessibilityValue("\(Int(normalized(value) * 100))%")
        .accessibilityAdjustableAction { direction in
            let step = max((range.upperBound - range.lowerBound) * 0.05, 5)
            switch direction {
            case .increment:
                value = min(range.upperBound, value + step)
            case .decrement:
                value = max(range.lowerBound, value - step)
            @unknown default:
                return
            }
            onEditingChanged(false)
        }
    }

    private func normalized(_ value: Double) -> CGFloat {
        let length = max(range.upperBound - range.lowerBound, 0.0001)
        return CGFloat(min(max((value - range.lowerBound) / length, 0), 1))
    }

    private func denormalized(_ fraction: CGFloat) -> Double {
        let clamped = min(max(Double(fraction), 0), 1)
        return range.lowerBound + (range.upperBound - range.lowerBound) * clamped
    }
}

struct AirPlayButton: UIViewRepresentable {
    var lightContent = false

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        view.activeTintColor = .systemPink
        view.tintColor = lightContent ? .white : .label
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = lightContent ? .white : .label
        uiView.activeTintColor = .systemPink
    }
}

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
