import SwiftUI

struct PersonalizedMixArtwork: View {
    let mix: PersonalizedMix
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            coverBackground

            if !showsMosaic {
                coverTypography
            } else {
                mosaicScrim
                coverTypography
            }
        }
        .frame(width: size, height: size)
        .buFiSurface(
            cornerRadius: cornerRadius,
            fill: .clear,
            stroke: BuFiTheme.separator.opacity(0.26),
            clipsContent: true
        )
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var coverBackground: some View {
        if mix.kind == .artist, let coverArt = mix.artworkCoverArt {
            ArtworkView(
                coverArt: coverArt,
                size: size,
                cornerRadius: 0
            )
            .frame(width: size, height: size)
        } else if showsMosaic {
            MixArtworkMosaic(coverArts: mosaicCoverArts, size: size)
        } else {
            softSolidFill
        }
    }

    private var softSolidFill: some View {
        LinearGradient(
            colors: softFillColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var softFillColors: [Color] {
        switch mix.kind {
        case .favorites:
            return [
                BuFiTheme.accentSoft.opacity(0.92),
                BuFiTheme.accent
            ]
        case .ranking:
            return [
                Color(red: 0.16, green: 0.38, blue: 0.68).opacity(0.94),
                Color(red: 0.22, green: 0.50, blue: 0.78)
            ]
        case .daylist:
            return [
                Color(red: 0.32, green: 0.28, blue: 0.62).opacity(0.94),
                Color(red: 0.42, green: 0.34, blue: 0.78)
            ]
        case .repeatListening:
            return [
                Color(red: 0.10, green: 0.42, blue: 0.72).opacity(0.94),
                Color(red: 0.14, green: 0.52, blue: 0.78)
            ]
        case .listenAgain:
            return [
                Color(red: 0.72, green: 0.38, blue: 0.18).opacity(0.94),
                Color(red: 0.86, green: 0.48, blue: 0.22)
            ]
        case .genre:
            return [
                Color(red: 0.18, green: 0.48, blue: 0.32).opacity(0.94),
                Color(red: 0.28, green: 0.58, blue: 0.38)
            ]
        case .mood:
            return [
                Color(red: 0.52, green: 0.28, blue: 0.58).opacity(0.94),
                Color(red: 0.62, green: 0.34, blue: 0.68)
            ]
        case .artist:
            return [
                Color(red: 0.28, green: 0.14, blue: 0.28).opacity(0.94),
                Color(red: 0.42, green: 0.18, blue: 0.36)
            ]
        }
    }

    private var mosaicScrim: some View {
        LinearGradient(
            colors: [
                .black.opacity(0.10),
                .clear,
                .black.opacity(0.62)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var coverTypography: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)

            Text(coverLabel)
                .font(coverFont)
                .tracking(-size * 0.004)
                .lineLimit(3)
                .minimumScaleFactor(0.72)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.28), radius: 6, y: 2)
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .bottomLeading
        )
        .padding(max(12, size * 0.072))
    }

    private var coverLabel: String {
        switch mix.kind {
        case .favorites:
            return String(localized: "좋아요")
        case .ranking:
            return String(localized: "자주 들은")
        case .daylist:
            return mix.title
        case .repeatListening:
            return String(localized: "반복 듣기")
        case .listenAgain:
            return String(localized: "한 번 더")
        case .artist:
            return mix.title
                .replacingOccurrences(of: " Mix", with: "")
        case .genre, .mood:
            return mix.title
        }
    }

    private var coverFont: Font {
        let fontSize = max(17, size * (mix.kind == .artist ? 0.10 : 0.112))
        return .system(size: fontSize, weight: .bold, design: .rounded)
    }

    private var mosaicCoverArts: [String] {
        var seen = Set<String>()
        var arts: [String] = []
        for song in mix.songs {
            guard let art = song.coverArt?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ), !art.isEmpty else { continue }
            guard seen.insert(art).inserted else { continue }
            arts.append(art)
            if arts.count == 4 { break }
        }
        return arts
    }

    private var showsMosaic: Bool {
        mix.kind != .artist && mosaicCoverArts.count >= 1
    }
}

private struct MixArtworkMosaic: View {
    let coverArts: [String]
    let size: CGFloat

    var body: some View {
        let tiles = Array(coverArts.prefix(4))
        let half = size / 2
        Group {
            switch tiles.count {
            case 1:
                tile(tiles[0], side: size)
                    .frame(width: size, height: size)
            case 2:
                HStack(spacing: 0) {
                    tile(tiles[0], side: size)
                        .frame(width: half, height: size)
                        .clipped()
                    tile(tiles[1], side: size)
                        .frame(width: half, height: size)
                        .clipped()
                }
            case 3:
                HStack(spacing: 0) {
                    tile(tiles[0], side: size)
                        .frame(width: half, height: size)
                        .clipped()
                    VStack(spacing: 0) {
                        tile(tiles[1], side: half)
                            .frame(width: half, height: half)
                            .clipped()
                        tile(tiles[2], side: half)
                            .frame(width: half, height: half)
                            .clipped()
                    }
                }
            default:
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        tile(tiles[0], side: half)
                            .frame(width: half, height: half)
                            .clipped()
                        tile(tiles[1], side: half)
                            .frame(width: half, height: half)
                            .clipped()
                    }
                    HStack(spacing: 0) {
                        tile(tiles[2], side: half)
                            .frame(width: half, height: half)
                            .clipped()
                        tile(tiles[3], side: half)
                            .frame(width: half, height: half)
                            .clipped()
                    }
                }
            }
        }
        .frame(width: size, height: size)
    }

    private func tile(_ coverArt: String, side: CGFloat) -> some View {
        ArtworkView(coverArt: coverArt, size: side, cornerRadius: 0)
    }
}

struct PersonalizedMixCard: View {
    let mix: PersonalizedMix
    var width: CGFloat = 166

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PersonalizedMixArtwork(
                mix: mix,
                size: width,
                cornerRadius: 16
            )
            Text(mix.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(height: 38, alignment: .topLeading)
            Text(mix.subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(height: 34, alignment: .topLeading)
        }
        .frame(width: width, height: width + 88, alignment: .topLeading)
        .clipped()
        .accessibilityElement(children: .combine)
    }
}

struct PersonalizedMixDetailView: View {
    let mix: PersonalizedMix
    private let audio = AudioEngine.shared

    private var trackCountText: String {
        String(
            format: String(localized: "%d곡"),
            mix.songs.count
        )
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                hero
                    .buFiEntranceMotion(offset: 10, initialScale: 0.994)
                controls
                    .buFiVerticalSectionMotion(delay: 0.025)
                songs
                    .buFiVerticalSectionMotion(delay: 0.05)
            }
            .padding(.top, 12)
            .buFiMiniPlayerContentClearance(idle: 56, playing: 148)
        }
        .background(BuFiScreenBackground())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private var hero: some View {
        VStack(spacing: 16) {
            PersonalizedMixArtwork(
                mix: mix,
                size: 250,
                cornerRadius: 24
            )
            VStack(spacing: 7) {
                Text(mix.title)
                    .font(.system(size: 29, weight: .bold))
                    .tracking(-0.8)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(trackCountText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if !mix.subtitle.isEmpty, mix.subtitle != trackCountText {
                    Text(mix.subtitle)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Spacer()

            Button {
                play(mix.songs)
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .background(
                        BuFiTheme.elevated,
                        in: Circle()
                    )
            }
            .buttonStyle(BuFiPressStyle())
            .accessibilityLabel("셔플 재생")

            Button {
                guard let first = mix.songs.first else { return }
                audio.play(first, in: mix.songs)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(BuFiTheme.accent, in: Circle())
            }
            .buttonStyle(BuFiPressStyle())
            .accessibilityLabel("전체 재생")
        }
        .padding(.horizontal, 18)
    }

    @ViewBuilder
    private var songs: some View {
        if mix.songs.isEmpty {
            ContentUnavailableView(
                "재생할 곡이 없습니다",
                systemImage: "music.note"
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(IndexedSongRow.makeRows(from: mix.songs)) { row in
                    HStack(spacing: mix.showsRanking ? 10 : 2) {
                        if mix.showsRanking {
                            Text("\(row.index + 1)")
                                .font(
                                    .system(
                                        size: 14,
                                        weight: row.index < 3 ? .bold : .medium,
                                        design: .rounded
                                    )
                                )
                                .foregroundStyle(
                                    row.index < 3
                                        ? BuFiTheme.accent
                                        : Color.secondary
                                )
                                .monospacedDigit()
                                .frame(width: 24, alignment: .trailing)
                        }
                        SongRow(
                            song: row.song,
                            queue: mix.songs,
                            queueIndex: row.index,
                            artworkSize: 52,
                            textLineLimit: 2
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)

                    if row.index < mix.songs.count - 1 {
                        Divider()
                            .padding(.leading, mix.showsRanking ? 100 : 84)
                            .opacity(0.42)
                    }
                }
            }
        }
    }

    private func play(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        var generator = SystemRandomNumberGenerator()
        let shuffled = songs.shuffled(using: &generator)
        guard let first = shuffled.first else { return }
        audio.play(first, in: shuffled)
    }
}
