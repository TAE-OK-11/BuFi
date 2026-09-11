import SwiftUI

enum HomeQuickAccessLeading: Equatable, Sendable {
    case heartGradient
    case chartGradient
    case coverArt(String?)
    /// Soft Bufi-adjacent fill for liked albums when cover art is unavailable.
    case albumStackGradient
    /// Soft teal fill for personalized mixes when cover art is unavailable.
    case mixSparklesGradient
}

struct HomeQuickAccessItem: Identifiable, Equatable, Sendable {
    enum Destination: Equatable, Sendable {
        case mix(PersonalizedMix)
        case album(Album)
        case playlist(Playlist)
    }

    let id: String
    let title: String
    let leading: HomeQuickAccessLeading
    let destination: Destination
    var isEnabled: Bool = true
}

struct HomeQuickAccessGrid: View {
    let items: [HomeQuickAccessItem]

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(items) { item in
                quickAccessLink(item)
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func quickAccessLink(_ item: HomeQuickAccessItem) -> some View {
        switch item.destination {
        case .mix(let mix):
            NavigationLink(value: mix) {
                HomeQuickAccessCard(title: item.title, leading: item.leading)
            }
            .buttonStyle(BuFiPressStyle())
            .disabled(!item.isEnabled)
        case .album(let album):
            NavigationLink(value: MusicRoute.album(album)) {
                HomeQuickAccessCard(title: item.title, leading: item.leading)
            }
            .buttonStyle(BuFiPressStyle())
            .disabled(!item.isEnabled)
        case .playlist(let playlist):
            NavigationLink(value: MusicRoute.playlist(playlist)) {
                HomeQuickAccessCard(title: item.title, leading: item.leading)
            }
            .buttonStyle(BuFiPressStyle())
            .disabled(!item.isEnabled)
        }
    }
}

struct HomeQuickAccessCard: View {
    let title: String
    let leading: HomeQuickAccessLeading

    @ScaledMetric(relativeTo: .body) private var cardHeight: CGFloat = 58

    var body: some View {
        let height = min(max(cardHeight, 56), 68)
        return HStack(spacing: 0) {
            leadingView(size: height)
                .frame(width: height, height: height)

            Text(LocalizedStringKey(title))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .minimumScaleFactor(0.9)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height)
        .buFiSurface(
            cornerRadius: 10,
            fill: BuFiTheme.elevated.opacity(0.88),
            stroke: Color.white.opacity(0.06),
            lineWidth: 0.6,
            clipsContent: true
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(LocalizedStringKey(title)))
    }

    @ViewBuilder
    private func leadingView(size: CGFloat) -> some View {
        switch leading {
        case .heartGradient:
            ZStack {
                LinearGradient(
                    colors: [
                        BuFiTheme.accent.opacity(0.92),
                        BuFiTheme.accent
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "heart.fill")
                    .font(.system(size: size * 0.36, weight: .bold))
                    .foregroundStyle(.white)
            }
        case .chartGradient:
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.12, green: 0.32, blue: 0.62),
                        Color(red: 0.22, green: 0.50, blue: 0.78),
                        Color(red: 0.35, green: 0.68, blue: 0.92)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: size * 0.34, weight: .bold))
                    .foregroundStyle(.white)
            }
        case .albumStackGradient:
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.45, green: 0.33, blue: 0.74).opacity(0.92),
                        Color(red: 0.45, green: 0.33, blue: 0.74)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "square.stack.fill")
                    .font(.system(size: size * 0.34, weight: .bold))
                    .foregroundStyle(.white)
            }
        case .mixSparklesGradient:
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.20, green: 0.58, blue: 0.52).opacity(0.92),
                        Color(red: 0.20, green: 0.58, blue: 0.52)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.34, weight: .bold))
                    .foregroundStyle(.white)
            }
        case .coverArt(let coverArt):
            ArtworkView(
                coverArt: coverArt,
                size: size,
                cornerRadius: 0
            )
        }
    }
}
