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
    var contentMode: ContentMode = .fill
    var blurredBackdrop = false
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
                if blurredBackdrop {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .scaleEffect(1.08)
                        .blur(radius: 20)
                        .saturation(0.9)
                        .opacity(0.72)
                }

                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.animation(.easeOut(duration: 0.22)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
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
    }
}
