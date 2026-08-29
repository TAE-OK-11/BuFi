import SwiftUI
import UIKit

struct ArtistHeroArtwork: View {
    private struct LoadedArtwork {
        let requestIdentity: ArtworkLoadRequestIdentity
        let image: UIImage
    }

    @EnvironmentObject private var model: AppModel
    @Environment(\.buFiMotionEnabled) private var motionEnabled
    @Environment(\.displayScale) private var displayScale

    let coverArt: String?
    var artistName: String? = nil
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
                    .allowsHitTesting(false)

                Rectangle()
                    .fill(.black.opacity(0.08))
                    .allowsHitTesting(false)

                Image(uiImage: loadedArtwork.image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(
                        BuFiTransition.artworkReveal.animation(
                            motionEnabled ? BuFiMotion.reveal : .none
                        )
                    )
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: artworkLoadTaskID) {
            await loadImage(requestID: artworkRequestIdentity)
        }
        .accessibilityHidden(true)
    }

    @MainActor
    private func loadImage(requestID: ArtworkLoadRequestIdentity) async {
        guard UIRenderPolicy.shouldReloadArtwork(
            loadedIdentity: loadedArtwork?.requestIdentity,
            requestedIdentity: requestID
        ) else {
            return
        }

        if let sourceURL = await model.artworkURL(
            id: normalizedCoverArt,
            size: ArtworkRequestSizing.serverRequestSize(
                for: requestedPixelSize
            )
        ),
           await storeLoadedImage(
               from: sourceURL,
               requestID: requestID,
               revision: cacheRevision
           ) {
            return
        }

        if let artistName,
           let sourceURL = await model.artistImageURL(name: artistName),
           await storeLoadedImage(
               from: sourceURL,
               requestID: requestID,
               revision: nil
           ) {
            return
        }

        guard !Task.isCancelled,
              artworkRequestIdentity == requestID else { return }
        onPalette?(.fallback)
    }

    @MainActor
    private func storeLoadedImage(
        from sourceURL: URL,
        requestID: ArtworkLoadRequestIdentity,
        revision: String?
    ) async -> Bool {
        let coverURL = ArtworkStore.cacheURL(
            for: sourceURL,
            revision: revision
        )
        guard let loaded = try? await ArtworkStore.shared.image(
                  for: coverURL,
                  pixelSize: requestedPixelSize
              ),
              !Task.isCancelled,
              artworkRequestIdentity == requestID else {
            return false
        }

        loadedArtwork = LoadedArtwork(
            requestIdentity: requestID,
            image: loaded.value
        )
        guard let onPalette else { return true }
        let palette = await ArtworkStore.shared.palette(
            for: coverURL,
            image: loaded
        )
        guard !Task.isCancelled,
              artworkRequestIdentity == requestID else { return false }
        onPalette(palette)
        return true
    }

    private var artworkLoadTaskID: String {
        let artistKey = artistName.map(ArtistPersonaResolver.normalized) ?? ""
        return "\(artworkRequestIdentity)-\(artistKey)"
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
