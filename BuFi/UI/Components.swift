import AVKit
import SwiftUI
import UIKit

enum BuFiTheme {
    static let accent = Color(red: 0.98, green: 0.20, blue: 0.34)
    static let accentSoft = Color(red: 1.00, green: 0.38, blue: 0.46)
    static let deezerGlow = Color(red: 0.56, green: 0.26, blue: 0.98)
    static let background = Color(uiColor: .systemBackground)
    static let elevated = Color(uiColor: .secondarySystemBackground)
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

enum PlayerSeekBarAppearance: String, CaseIterable, Identifiable {
    case classic
    case liquidGlass

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .classic: "클래식"
        case .liquidGlass: "Liquid Glass"
        }
    }

}

enum PlayerAppearance: String, CaseIterable, Identifiable {
    case classic
    case liquidGlass
    case dynamic

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .classic: "클래식"
        case .liquidGlass: "Liquid Glass"
        case .dynamic: "Dynamic"
        }
    }

    static func resolved(_ rawValue: String) -> PlayerAppearance {
        PlayerAppearance(rawValue: rawValue) ?? .liquidGlass
    }

    var seekBarAppearance: PlayerSeekBarAppearance {
        self == .classic ? .classic : .liquidGlass
    }
}

enum PlayerBackgroundAppearance: String, CaseIterable, Identifiable {
    case classic
    case multicolor
    case bright

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .classic: "기본"
        case .multicolor: "다중 컬러"
        case .bright: "밝게"
        }
    }

    static func resolved(_ rawValue: String) -> PlayerBackgroundAppearance {
        PlayerBackgroundAppearance(rawValue: rawValue) ?? .classic
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
        // Floor rather than round so the counter never jumps to the next second
        // early. Clamp conversion to avoid malformed stream metadata overflowing.
        let total = Int(min(floor(self), Double(Int.max)))
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
    @Environment(\.buFiMotionEnabled) private var motionEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && motionEnabled ? 0.972 : 1)
            .brightness(configuration.isPressed ? -0.018 : 0)
            .animation(motionEnabled ? BuFiMotion.tap : .none, value: configuration.isPressed)
    }
}

struct BuFiFilterBar<Item: Identifiable & Equatable>: View {
    let items: [Item]
    @Binding var selection: Item
    var fontSize: CGFloat = 14
    let title: (Item) -> LocalizedStringKey

    @Environment(\.buFiMotionEnabled) private var motionEnabled
    @Namespace private var selectionNamespace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items) { item in
                Button {
                    withAnimation(motionEnabled ? BuFiMotion.content : .none) {
                        selection = item
                    }
                } label: {
                    Text(title(item))
                        .font(.system(size: fontSize, weight: .semibold))
                        .foregroundStyle(
                            selection == item
                                ? Color.white
                                : Color.white.opacity(0.62)
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background {
                            if selection == item {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(Color.white.opacity(0.14))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .stroke(Color.white.opacity(0.13), lineWidth: 0.7)
                                    }
                                    .matchedGeometryEffect(
                                        id: "filter-selection",
                                        in: selectionNamespace
                                    )
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(BuFiPressStyle())
                .accessibilityAddTraits(selection == item ? .isSelected : [])
            }
        }
        .padding(4)
        .frame(height: 50)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.58))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(0.26)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.09), lineWidth: 0.7)
        }
        .buFiGlass(cornerRadius: 16, interactive: true)
        .padding(.horizontal, 16)
    }
}

struct BuFiScreenBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            BuFiTheme.background
            RadialGradient(
                colors: [
                    BuFiTheme.deezerGlow.opacity(colorScheme == .dark ? 0.10 : 0.055),
                    .clear
                ],
                center: UnitPoint(x: 0.12, y: 0.02),
                startRadius: 4,
                endRadius: 430
            )
            RadialGradient(
                colors: [
                    BuFiTheme.accent.opacity(colorScheme == .dark ? 0.12 : 0.065),
                    .clear
                ],
                center: UnitPoint(x: 0.92, y: 0.08),
                startRadius: 8,
                endRadius: 500
            )
            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.025 : 0.14),
                    .clear,
                    Color.black.opacity(colorScheme == .dark ? 0.10 : 0.015),
                    .clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

struct BuFiPageHeader: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let systemImage: String

    var body: some View {
        HStack(alignment: .bottom, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 32, weight: .bold))
                    .tracking(-1.0)
                    .lineLimit(2)
                    .minimumScaleFactor(0.86)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(BuFiTheme.accentSoft)
                .frame(width: 44, height: 44)
                .background(Color.primary.opacity(0.055))
                .buFiGlass(cornerRadius: 22)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 18)
        .accessibilityElement(children: .combine)
    }
}

struct BuFiGroupedSurface<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(BuFiTheme.elevated.opacity(0.88))
                    LinearGradient(
                        colors: [Color.white.opacity(0.055), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.09), lineWidth: 0.7)
            }
    }
}

struct BuFiFeatureCard: View {
    let title: LocalizedStringKey
    let subtitle: String
    let systemImage: String
    let tint: Color
    var details: [String] = []
    var expandsHorizontally = false
    var trailingSystemImage = "play.fill"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.16), in: Circle())
                Spacer(minLength: 10)
                Image(systemName: trailingSystemImage)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(width: 32, height: 32)
                    .background(Color.black.opacity(0.18), in: Circle())
            }

            Spacer(minLength: 12)

            Text(title)
                .font(.system(size: 18, weight: .bold))
                .tracking(-0.35)
                .foregroundStyle(.white)
                .lineLimit(2)

            Text(subtitle)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.68))
                .lineLimit(1)

            ForEach(Array(details.prefix(2).enumerated()), id: \.offset) { _, detail in
                Text(detail)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.80))
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(
            width: expandsHorizontally ? nil : 178,
            height: 154,
            alignment: .topLeading
        )
        .frame(maxWidth: expandsHorizontally ? .infinity : nil)
        .background {
            ZStack {
                LinearGradient(
                    colors: [
                        tint.opacity(0.94),
                        BuFiTheme.deezerGlow.opacity(0.70),
                        Color.black.opacity(0.68)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [Color.white.opacity(0.24), .clear],
                    center: UnitPoint(x: 0.18, y: 0.05),
                    startRadius: 2,
                    endRadius: 150
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 0.8)
        }
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct ArtworkView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.buFiMotionEnabled) private var motionEnabled

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
                    .transition(
                        .opacity.animation(
                            motionEnabled ? .easeOut(duration: 0.22) : .none
                        )
                    )
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
                guard let onPalette else { return }
                let palette = await ArtworkStore.shared.palette(
                    for: url,
                    image: loaded
                )
                guard !Task.isCancelled else { return }
                onPalette(palette)
                return
            }
            guard !Task.isCancelled else { return }
            onPalette?(.fallback)
        }
        .accessibilityHidden(true)
    }
}

struct AlbumCard: View {
    let album: Album
    var width: CGFloat = 166
    @Environment(\.buFiMotionEnabled) private var motionEnabled

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
            ArtworkView(coverArt: album.coverArt, size: width, cornerRadius: 14)
                .frame(width: width, height: width)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.6)
                }
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

enum SongRowLayout: Equatable {
    case standard
    case compactAlbum
}

struct SongRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var audio: AudioEngine

    let song: Song
    let queue: [Song]
    var showsArtwork = true
    var artworkSize: CGFloat = 54
    var layout: SongRowLayout = .standard
    var fallbackTrackNumber: Int?
    var onMore: (() -> Void)?
    var textLineLimit = 1

    @ViewBuilder
    var body: some View {
        Group {
            if layout == .compactAlbum {
                compactAlbumRow
            } else {
                standardRow
            }
        }
        .contextMenu {
            Button {
                audio.enqueueNext(song)
            } label: {
                Label(
                    "다음에 재생",
                    systemImage: "text.line.first.and.arrowtriangle.forward"
                )
            }
            Button {
                audio.enqueue(song)
            } label: {
                Label("대기목록에 추가", systemImage: "text.badge.plus")
            }
            Button {
                Task { await model.download(song) }
            } label: {
                Label("오프라인 저장", systemImage: "arrow.down.circle")
            }
            Button {
                Task { await model.toggleStar(song: song) }
            } label: {
                Label(
                    model.isStarred(song) ? "좋아요 취소" : "좋아요 표시",
                    systemImage: model.isStarred(song) ? "heart.slash" : "heart"
                )
            }
        }
    }

    private var compactAlbumRow: some View {
        let isCurrentSong = audio.currentSong?.id == song.id
        let isStarred = model.isStarred(song)
        return HStack(spacing: 0) {
            Button {
                audio.play(song, in: queue)
            } label: {
                HStack(spacing: 12) {
                    Group {
                        if isCurrentSong {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(BuFiTheme.accent)
                        } else {
                            Text(String(format: "%02d", displayedTrackNumber))
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .frame(width: 28, alignment: .trailing)

                    Text(song.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(
                            isCurrentSong
                                ? BuFiTheme.accent
                                : Color.primary
                        )
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text(durationText)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(minWidth: 38, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 16) {
                Button {
                    Task { await model.toggleStar(song: song) }
                } label: {
                    Image(systemName: isStarred ? "heart.fill" : "heart")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isStarred ? BuFiTheme.accent : Color.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(BuFiPressStyle())
                .accessibilityLabel(isStarred ? "좋아요 취소" : "좋아요 표시")

                if let onMore {
                    Button(action: onMore) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(song.title) 더 보기")
                }
            }
            .padding(.leading, 14)
        }
        .frame(minHeight: 52)
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
    }

    private var standardRow: some View {
        let isCurrentSong = audio.currentSong?.id == song.id
        let isStarred = model.isStarred(song)
        return HStack(spacing: 0) {
            Button {
                audio.play(song, in: queue)
            } label: {
                HStack(spacing: 12) {
                    if showsArtwork {
                        ArtworkView(
                            coverArt: song.coverArt,
                            size: artworkSize,
                            cornerRadius: max(5, artworkSize * 0.11)
                        )
                        .frame(width: artworkSize, height: artworkSize)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(song.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(
                                isCurrentSong
                                    ? BuFiTheme.accent
                                    : Color.primary
                            )
                            .lineLimit(textLineLimit)
                            .fixedSize(horizontal: false, vertical: true)
                        Text([song.artist, song.album].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .lineLimit(textLineLimit)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(spacing: 14) {
                Button {
                    Task { await model.toggleStar(song: song) }
                } label: {
                    Image(systemName: isStarred ? "heart.fill" : "heart")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isStarred ? BuFiTheme.accent : Color.secondary)
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(BuFiPressStyle())
                .accessibilityLabel(isStarred ? "좋아요 취소" : "좋아요 표시")

                if let onMore {
                    Button(action: onMore) {
                        Image(systemName: "ellipsis")
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(song.title) 더 보기")
                }
            }
            .padding(.leading, 10)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
    }

    private var displayedTrackNumber: Int {
        song.track ?? fallbackTrackNumber ?? 1
    }

    private var durationText: String {
        song.safeDuration > 0 ? song.safeDuration.playbackText : "—:—"
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

struct PlayerSeekBar: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let appearance: PlayerSeekBarAppearance
    var tint: Color = .white
    var onEditingChanged: (Bool) -> Void = { _ in }

    @ViewBuilder
    var body: some View {
        if appearance == .liquidGlass {
            if #available(iOS 26.0, *) {
                NativeLiquidGlassSeekBar(
                    value: $value,
                    range: range,
                    tint: tint,
                    onEditingChanged: onEditingChanged
                )
            } else {
                fallback
            }
        } else {
            fallback
        }
    }

    private var fallback: some View {
        InteractiveSeekBar(
            value: $value,
            range: range,
            tint: tint,
            onEditingChanged: onEditingChanged
        )
    }
}

@available(iOS 26.0, *)
private struct NativeLiquidGlassSeekBar: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let tint: Color
    let onEditingChanged: (Bool) -> Void

    var body: some View {
        // Standard controls adopt Apple's Liquid Glass design automatically on
        // iOS 26, including system interaction, accessibility, and contrast.
        Slider(
            value: clampedValue,
            in: range,
            onEditingChanged: onEditingChanged
        )
        .tint(tint)
        .frame(height: 28)
        .accessibilityLabel("재생 위치")
        .accessibilityValue("\(Int(normalizedValue * 100))%")
    }

    private var clampedValue: Binding<Double> {
        Binding(
            get: {
                clamped(value)
            },
            set: { newValue in
                value = clamped(newValue)
            }
        )
    }

    private var normalizedValue: Double {
        let length = max(range.upperBound - range.lowerBound, 0.0001)
        return min(max((clamped(value) - range.lowerBound) / length, 0), 1)
    }

    private func clamped(_ candidate: Double) -> Double {
        guard candidate.isFinite else { return range.lowerBound }
        return min(max(candidate, range.lowerBound), range.upperBound)
    }
}

struct InteractiveSeekBar: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var tint: Color = .white
    var onEditingChanged: (Bool) -> Void = { _ in }

    @Environment(\.buFiMotionEnabled) private var motionEnabled
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
            .animation(motionEnabled ? BuFiMotion.selection : .none, value: isEditing)
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
        guard value.isFinite else { return 0 }
        return CGFloat(min(max((value - range.lowerBound) / length, 0), 1))
    }

    private func denormalized(_ fraction: CGFloat) -> Double {
        guard fraction.isFinite else { return range.lowerBound }
        let clamped = min(max(Double(fraction), 0), 1)
        return range.lowerBound + (range.upperBound - range.lowerBound) * clamped
    }
}

struct AirPlayButton: UIViewRepresentable {
    var lightContent = false

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.activeTintColor = UIColor(BuFiTheme.accent)
        picker.tintColor = lightContent ? .white : .label
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = lightContent ? .white : .label
    }
}
