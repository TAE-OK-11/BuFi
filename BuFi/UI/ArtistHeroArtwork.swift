import SwiftUI
import UIKit

struct ArtistHeroArtwork: View {
    private struct LoadedArtwork {
        let requestIdentity: String
        let image: UIImage
    }

    @EnvironmentObject private var model: AppModel
    @Environment(\.buFiMotionEnabled) private var motionEnabled
    @Environment(\.displayScale) private var displayScale

    let coverArt: String?
    var cacheRevision: String? = nil
    var onPalette: ((ArtworkPalette) -> Void)?

    private let height: CGFloat = 360
    private let cornerRadius: CGFloat = 24

    @State private var loadedArtwork: LoadedArtwork?

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

            if let loadedArtwork,
               loadedArtwork.requestIdentity == artworkRequestIdentity {
                Image(uiImage: loadedArtwork.image)
                    .resizable()
                    .scaledToFill()
                    .scaleEffect(1.12)
                    .blur(radius: 22)
                    .saturation(0.92)
                    .opacity(0.72)

                Rectangle()
                    .fill(.black.opacity(0.08))

                Image(uiImage: loadedArtwork.image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(
                        .opacity.animation(motionEnabled ? BuFiMotion.fade : .none)
                    )
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: artworkRequestIdentity) {
            await loadImage(requestID: artworkRequestIdentity)
        }
        .accessibilityHidden(true)
    }

    @MainActor
    private func loadImage(requestID: String) async {
        loadedArtwork = nil

        // OpenSubsonic may include third-party artist-image URLs. Fetching those
        // directly would disclose the user's IP address and viewing time to an
        // unrelated image host, so artist art is loaded only through the user's
        // authenticated OpenSubsonic server.
        guard let sourceURL = await model.artworkURL(
                  id: normalizedCoverArt,
                  size: Int(requestedPixelSize)
              ),
              !Task.isCancelled,
              artworkRequestIdentity == requestID else {
            guard !Task.isCancelled,
                  artworkRequestIdentity == requestID else { return }
            onPalette?(.fallback)
            return
        }
        let coverURL = ArtworkStore.cacheURL(
            for: sourceURL,
            revision: cacheRevision
        )
        guard let loaded = try? await ArtworkStore.shared.image(
                  for: coverURL,
                  pixelSize: requestedPixelSize
              ),
              !Task.isCancelled,
              artworkRequestIdentity == requestID else {
            guard !Task.isCancelled,
                  artworkRequestIdentity == requestID else { return }
            onPalette?(.fallback)
            return
        }

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
    }

    private var artworkRequestIdentity: String {
        "\(model.artworkContextID)-\(normalizedCoverArt ?? "")-\(cacheRevision ?? "base")-\(Int(requestedPixelSize))"
    }

    private var requestedPixelSize: CGFloat {
        ArtworkRequestSizing.pixelSize(
            pointSize: height,
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
