import SwiftUI
import UIKit

struct ArtistHeroArtwork: View {
    @EnvironmentObject private var model: AppModel

    let coverArt: String?
    let remoteURL: String?
    var height: CGFloat = 360
    var cornerRadius: CGFloat = 24
    var onPalette: ((ArtworkPalette) -> Void)?

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.white.opacity(0.12),
                    Color.black.opacity(0.38)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Image(systemName: "person.crop.square")
                .font(.system(size: 72, weight: .semibold))
                .foregroundStyle(.white.opacity(0.25))

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(1.12)
                    .blur(radius: 22)
                    .saturation(0.92)
                    .opacity(0.72)

                Rectangle()
                    .fill(.black.opacity(0.08))

                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.animation(.easeOut(duration: 0.24)))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: "\(coverArt ?? "")-\(remoteURL ?? "")-\(Int(height))") {
            await loadImage()
        }
        .accessibilityHidden(true)
    }

    @MainActor
    private func loadImage() async {
        image = nil
        var candidates: [URL] = []

        if let remoteURL,
           let url = URL(string: remoteURL),
           url.scheme?.lowercased() == "https" {
            candidates.append(url)
        }

        if let coverURL = await model.artworkURL(id: coverArt, size: 1200) {
            candidates.append(coverURL)
        }

        for url in candidates {
            guard !Task.isCancelled else { return }
            guard let loaded = try? await ArtworkStore.shared.image(
                for: url,
                pixelSize: max(height * UIScreen.main.scale, 480)
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
