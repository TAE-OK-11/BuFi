import SwiftUI
import UIKit

struct ArtistHeroArtwork: View {
    @EnvironmentObject private var model: AppModel

    let coverArt: String?
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
        .task(id: "\(coverArt ?? "")-\(Int(height))") {
            await loadImage()
        }
        .accessibilityHidden(true)
    }

    @MainActor
    private func loadImage() async {
        image = nil

        // OpenSubsonic may include third-party artist-image URLs. Fetching those
        // directly would disclose the user's IP address and viewing time to an
        // unrelated image host, so artist art is loaded only through the user's
        // authenticated OpenSubsonic server.
        guard let coverURL = await model.artworkURL(id: coverArt, size: 1200),
              !Task.isCancelled,
              let loaded = try? await ArtworkStore.shared.image(
                  for: coverURL,
                  pixelSize: max(height * UIScreen.main.scale, 480)
              ),
              !Task.isCancelled else {
            onPalette?(.fallback)
            return
        }

        image = loaded
        onPalette?(await ArtworkStore.shared.palette(for: coverURL, image: loaded))
    }
}
