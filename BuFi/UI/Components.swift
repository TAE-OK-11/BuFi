import AVKit
import SwiftUI
import UIKit

enum BuFiTheme {
    static let accent = Color(red: 0.98, green: 0.20, blue: 0.34)
    static let accentSoft = Color(red: 1.00, green: 0.38, blue: 0.46)
    static let deezerGlow = Color(red: 0.56, green: 0.26, blue: 0.98)
    static let background = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark { return .systemBackground }
        return UIColor(red: 0.969, green: 0.969, blue: 0.980, alpha: 1)
    })
    static let elevated = Color(uiColor: UIColor { traits in
        if traits.userInterfaceStyle == .dark { return .secondarySystemBackground }
        return UIColor(red: 0.997, green: 0.997, blue: 1.000, alpha: 1)
    })
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

enum PlayerSeekBarAppearance {
    case classic
    case liquidGlass
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

private struct BuFiSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    let fill: Color
    let stroke: Color
    let lineWidth: CGFloat
    let clipsContent: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: cornerRadius,
            style: .continuous
        )
        if clipsContent {
            content
                .background(fill, in: shape)
                .clipShape(shape)
                .overlay { shape.stroke(stroke, lineWidth: lineWidth) }
        } else {
            content
                .background(fill, in: shape)
                .overlay { shape.stroke(stroke, lineWidth: lineWidth) }
        }
    }
}

private struct BuFiMiniPlayerContentClearanceModifier: ViewModifier {
    @EnvironmentObject private var currentPlayback: CurrentPlaybackState
    let idle: CGFloat
    let playing: CGFloat

    func body(content: Content) -> some View {
        content.padding(
            .bottom,
            currentPlayback.song == nil ? idle : playing
        )
    }
}

extension View {
    func buFiGlass(cornerRadius: CGFloat, interactive: Bool = false) -> some View {
        modifier(BuFiGlassModifier(cornerRadius: cornerRadius, interactive: interactive))
    }

    func buFiSurface(
        cornerRadius: CGFloat,
        fill: Color = BuFiTheme.elevated.opacity(0.92),
        stroke: Color = BuFiTheme.separator.opacity(0.28),
        lineWidth: CGFloat = 0.7,
        clipsContent: Bool = false
    ) -> some View {
        modifier(
            BuFiSurfaceModifier(
                cornerRadius: cornerRadius,
                fill: fill,
                stroke: stroke,
                lineWidth: lineWidth,
                clipsContent: clipsContent
            )
        )
    }

    /// Keeps the final scrollable content clear of the persistent mini player.
    func buFiMiniPlayerContentClearance(
        idle: CGFloat = 34,
        playing: CGFloat = 110
    ) -> some View {
        modifier(BuFiMiniPlayerContentClearanceModifier(
            idle: idle,
            playing: playing
        ))
    }
}

struct BuFiPressStyle: ButtonStyle {
    @Environment(\.buFiMotionEnabled) private var motionEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && motionEnabled ? 0.972 : 1)
            .brightness(configuration.isPressed ? -0.012 : 0)
            .opacity(configuration.isPressed ? 0.96 : 1)
            .animation(
                motionEnabled
                    ? BuFiMotion.press(isPressed: configuration.isPressed)
                    : .none,
                value: configuration.isPressed
            )
    }
}

struct BuFiFilterBar<Item: Identifiable & Equatable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> LocalizedStringKey

    @Environment(\.buFiMotionEnabled) private var motionEnabled
    @Namespace private var selectionNamespace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items) { item in
                Button {
                    withAnimation(motionEnabled ? BuFiMotion.selection : .none) {
                        selection = item
                    }
                } label: {
                    Text(title(item))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .foregroundStyle(
                            selection == item
                                ? Color.primary
                                : Color.secondary
                        )
                        .scaleEffect(selection == item ? 1 : 0.985)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background {
                            if selection == item {
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .fill(Color.primary.opacity(0.11))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                                            .stroke(
                                                BuFiTheme.separator.opacity(0.28),
                                                lineWidth: 0.7
                                            )
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
        .frame(height: 48)
        .buFiSurface(
            cornerRadius: 17,
            stroke: BuFiTheme.separator.opacity(0.34)
        )
        .padding(.horizontal, 16)
    }
}

struct BuFiScreenBackground: View {
    var body: some View {
        BuFiTheme.background
            .ignoresSafeArea()
    }
}

struct BuFiPageHeader: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.system(size: 34, weight: .bold))
            .tracking(-1.15)
            .lineLimit(2)
            .minimumScaleFactor(0.86)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
    }
}

struct BuFiGroupedSurface<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .buFiSurface(
                cornerRadius: 22,
                stroke: BuFiTheme.separator.opacity(0.26),
                clipsContent: true
            )
    }
}

struct BuFiShortcutCard: View {
    let title: LocalizedStringKey
    var subtitle: String? = nil
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .tracking(-0.25)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 13)
        .frame(maxWidth: .infinity, minHeight: 94)
        .buFiSurface(cornerRadius: 18)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct ArtworkLoadRequestIdentity: Hashable, Sendable {
    let context: ArtworkContextIdentity
    let coverArtID: String?
    let cacheRevision: String?
    let pixelSize: Int
}

struct ArtworkView: View {
    private struct LoadedArtwork {
        let requestIdentity: ArtworkLoadRequestIdentity
        let image: UIImage
    }

    @EnvironmentObject private var model: AppModel
    @Environment(\.buFiMotionEnabled) private var motionEnabled
    @Environment(\.displayScale) private var displayScale

    let coverArt: String?
    let size: CGFloat
    let cornerRadius: CGFloat
    var cacheRevision: String? = nil
    var onPalette: ((ArtworkPalette) -> Void)?

    @State private var loadedArtwork: LoadedArtwork?

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

            if let loadedArtwork,
               loadedArtwork.requestIdentity == artworkRequestIdentity {
                Image(uiImage: loadedArtwork.image)
                    .resizable()
                    .scaledToFill()
                    .transition(
                        BuFiTransition.artworkReveal.animation(
                            motionEnabled ? BuFiMotion.reveal : .none
                        )
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: artworkRequestIdentity) {
            let requestID = artworkRequestIdentity
            guard UIRenderPolicy.shouldReloadArtwork(
                loadedIdentity: loadedArtwork?.requestIdentity,
                requestedIdentity: requestID
            ) else {
                return
            }
            if let sourceURL = await model.artworkURL(
                id: normalizedCoverArt,
                size: Int(requestedPixelSize)
            ) {
                guard !Task.isCancelled else { return }
                let coverURL = ArtworkStore.cacheURL(
                    for: sourceURL,
                    revision: cacheRevision
                )
                guard let loaded = try? await ArtworkStore.shared.image(
                    for: coverURL,
                    pixelSize: requestedPixelSize
                ) else {
                    guard !Task.isCancelled,
                          artworkRequestIdentity == requestID else { return }
                    onPalette?(.fallback)
                    return
                }
                guard !Task.isCancelled,
                      artworkRequestIdentity == requestID else { return }
                loadedArtwork = LoadedArtwork(
                    requestIdentity: requestID,
                    image: loaded.value
                )
                guard let onPalette else { return }
                let palette = await ArtworkStore.shared.palette(
                    for: coverURL,
                    image: loaded
                )
                guard !Task.isCancelled,
                      artworkRequestIdentity == requestID else { return }
                onPalette(palette)
                return
            }
            guard !Task.isCancelled,
                  artworkRequestIdentity == requestID else { return }
            onPalette?(.fallback)
        }
        .accessibilityHidden(true)
    }

    private var artworkRequestIdentity: ArtworkLoadRequestIdentity {
        ArtworkLoadRequestIdentity(
            context: model.artworkContextID,
            coverArtID: normalizedCoverArt,
            cacheRevision: cacheRevision,
            pixelSize: Int(requestedPixelSize)
        )
    }

    private var requestedPixelSize: CGFloat {
        ArtworkRequestSizing.pixelSize(
            pointSize: size,
            displayScale: displayScale
        )
    }

    private var normalizedCoverArt: String? {
        guard let value = coverArt?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !value.isEmpty else {
            return nil
        }
        return value
    }
}

struct AlbumCard: View {
    let album: Album
    var width: CGFloat = 166
    var usesHorizontalScrollTransition = true

    @ViewBuilder
    var body: some View {
        if usesHorizontalScrollTransition {
            card.buFiHorizontalScrollMotion()
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
                .frame(height: 38, alignment: .topLeading)
                .foregroundStyle(.primary)
            Text(album.artist)
                .font(.system(size: 13))
                .lineLimit(1)
                .frame(height: 17, alignment: .topLeading)
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

struct SongFavoriteIconButton: View {
    @EnvironmentObject private var model: AppModel

    let song: Song
    var iconSize: CGFloat = 16
    var inactiveForeground: Color = .secondary
    var hitTarget: CGFloat = 32

    var body: some View {
        SongFavoriteIconButtonContent(
            model: model,
            overrideState: model.favoriteOverrideState(for: song),
            song: song,
            iconSize: iconSize,
            inactiveForeground: inactiveForeground,
            hitTarget: hitTarget
        )
    }
}

private struct SongFavoriteIconButtonContent: View {
    @Environment(\.buFiMotionEnabled) private var motionEnabled
    @AppStorage("haptics-enabled") private var hapticsEnabled = true
    let model: AppModel
    @ObservedObject var overrideState: FavoriteOverrideValueState
    let song: Song
    let iconSize: CGFloat
    let inactiveForeground: Color
    let hitTarget: CGFloat

    private var isStarred: Bool {
        overrideState.value ?? song.isStarred
    }

    var body: some View {
        Button {
            Task { await model.toggleStar(song: song) }
        } label: {
            Image(systemName: isStarred ? "heart.fill" : "heart")
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(
                    isStarred ? BuFiTheme.accent : inactiveForeground
                )
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: isStarred)
                .frame(width: hitTarget, height: hitTarget)
        }
        .buttonStyle(BuFiPressStyle())
        .animation(
            motionEnabled ? BuFiMotion.symbol : .none,
            value: isStarred
        )
        .sensoryFeedback(.success, trigger: isStarred) { oldValue, newValue in
            hapticsEnabled && motionEnabled && oldValue != newValue
        }
        .accessibilityLabel(isStarred ? "좋아요 취소" : "좋아요 표시")
    }
}

struct SongFavoriteMenuButton: View {
    @EnvironmentObject private var model: AppModel

    let song: Song

    var body: some View {
        SongFavoriteMenuButtonContent(
            model: model,
            overrideState: model.favoriteOverrideState(for: song),
            song: song
        )
    }
}

private struct SongFavoriteMenuButtonContent: View {
    let model: AppModel
    @ObservedObject var overrideState: FavoriteOverrideValueState
    let song: Song

    private var isStarred: Bool {
        overrideState.value ?? song.isStarred
    }

    var body: some View {
        Button {
            Task { await model.toggleStar(song: song) }
        } label: {
            Label(
                isStarred ? "좋아요 취소" : "좋아요 표시",
                systemImage: isStarred ? "heart.slash" : "heart"
            )
        }
    }
}

struct SongRow: View {
    @EnvironmentObject private var model: AppModel

    private let audio = AudioEngine.shared

    let song: Song
    let queue: [Song]
    var queueIndex: Int? = nil
    var playbackOrigin: PlaybackOrigin = .manual
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
            SongFavoriteMenuButton(song: song)
        }
    }

    private var compactAlbumRow: some View {
        HStack(spacing: 0) {
            Button {
                audio.play(
                    song,
                    in: queue,
                    queueIndex: queueIndex,
                    origin: playbackOrigin
                )
            } label: {
                HStack(spacing: 12) {
                    CompactTrackLeading(
                        songID: song.id,
                        trackNumber: displayedTrackNumber
                    )

                    PlayingSongTitle(
                        songID: song.id,
                        title: song.title,
                        lineLimit: 1,
                        expandsVertically: false
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(durationText)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(minWidth: 38, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(BuFiPressStyle())

            HStack(spacing: 16) {
                SongFavoriteIconButton(song: song)

                if let onMore {
                    Button(action: onMore) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(BuFiPressStyle())
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
        HStack(spacing: 0) {
            Button {
                audio.play(
                    song,
                    in: queue,
                    queueIndex: queueIndex,
                    origin: playbackOrigin
                )
            } label: {
                HStack(spacing: 12) {
                    ArtworkView(
                        coverArt: song.artworkID,
                        size: artworkSize,
                        cornerRadius: max(5, artworkSize * 0.11)
                    )
                    .frame(width: artworkSize, height: artworkSize)
                    VStack(alignment: .leading, spacing: 4) {
                        PlayingSongTitle(
                            songID: song.id,
                            title: song.title,
                            lineLimit: textLineLimit
                        )
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
            .buttonStyle(BuFiPressStyle())

            HStack(spacing: 14) {
                SongFavoriteIconButton(song: song)

                if let onMore {
                    Button(action: onMore) {
                        Image(systemName: "ellipsis")
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(BuFiPressStyle())
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

private struct PlayingSongTitle: View {
    @EnvironmentObject private var currentPlayback: CurrentPlaybackState
    @Environment(\.buFiMotionEnabled) private var motionEnabled
    let songID: String
    let title: String
    var lineLimit = 1
    var expandsVertically = true

    var body: some View {
        Text(title)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(
                currentPlayback.song?.id == songID
                    ? BuFiTheme.accent
                    : Color.primary
            )
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: expandsVertically)
            .animation(
                motionEnabled ? BuFiMotion.symbol : .none,
                value: currentPlayback.song?.id == songID
            )
    }
}

private struct CompactTrackLeading: View {
    @EnvironmentObject private var currentPlayback: CurrentPlaybackState
    @Environment(\.buFiMotionEnabled) private var motionEnabled
    let songID: String
    let trackNumber: Int

    var body: some View {
        Group {
            if currentPlayback.song?.id == songID {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BuFiTheme.accent)
            } else {
                Text(String(format: "%02d", trackNumber))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(width: 28, alignment: .trailing)
        .animation(
            motionEnabled ? BuFiMotion.symbol : .none,
            value: currentPlayback.song?.id == songID
        )
    }
}

struct SectionTitle: View {
    let title: String

    var body: some View {
        Text(LocalizedStringKey(title))
            .font(.system(size: 24, weight: .bold))
            .tracking(-0.6)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            .animation(motionEnabled ? BuFiMotion.scrub : .none, value: isEditing)
            .animation(
                motionEnabled && !isEditing ? BuFiMotion.timeline : .none,
                value: fraction
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
