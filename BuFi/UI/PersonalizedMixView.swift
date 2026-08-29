import SwiftUI

struct PersonalizedMixArtwork: View {
    let mix: PersonalizedMix
    let size: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        ZStack {
            if mix.kind == .artist {
                ArtworkView(
                    coverArt: mix.artworkCoverArt,
                    size: size,
                    cornerRadius: 0,
                    artistName: mix.title
                )
                .frame(width: size, height: size)

                LinearGradient(
                    colors: [
                        .black.opacity(0.08),
                        .clear,
                        .black.opacity(0.78)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            } else {
                SmartMixCoverBackground(theme: coverTheme)
            }

            coverTypography
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

    private var coverTypography: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("BUFI SMART")
                .font(.custom("Unbounded_900wght", fixedSize: max(8, size * 0.043)))
                .tracking(size * 0.004)
                .foregroundStyle(.white.opacity(0.88))

            Spacer(minLength: 0)

            Text(coverTitle)
                .font(coverFont)
                .tracking(-size * 0.006)
                .lineLimit(mix.kind == .artist ? 2 : 3)
                .minimumScaleFactor(0.62)
                .fixedSize(horizontal: false, vertical: true)

            Text(coverTheme.signature)
                .font(
                    .system(
                        size: max(8, size * 0.047),
                        weight: .bold,
                        design: .rounded
                    )
                )
                .tracking(size * 0.003)
                .foregroundStyle(.white.opacity(0.68))
                .padding(.top, max(4, size * 0.022))
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .leading
        )
        .foregroundStyle(.white)
        .padding(max(13, size * 0.075))
        .shadow(color: .black.opacity(0.24), radius: 8, y: 3)
    }

    private var coverTitle: String {
        switch mix.kind {
        case .daylist: "DAYLIST"
        case .repeatListening: "REPEAT"
        case .listenAgain: "LISTEN\nAGAIN"
        case .favorites: "FAVORITES"
        case .ranking: "TOP\nTRACKS"
        case .artist:
            mix.title
                .replacingOccurrences(of: " Mix", with: "")
                .uppercased() + " MIX"
        case .genre, .mood: mix.title.uppercased()
        }
    }

    private var coverFont: Font {
        let fontSize = max(18, size * (mix.kind == .artist ? 0.105 : 0.118))
        let supportsUnbounded = coverTitle.unicodeScalars.allSatisfy {
            $0.isASCII
        }
        if supportsUnbounded {
            return .custom("Unbounded_900wght", fixedSize: fontSize)
        }
        return .system(
            size: fontSize,
            weight: .black,
            design: .rounded
        )
    }

    private var coverTheme: SmartMixCoverTheme {
        switch mix.kind {
        case .daylist:
            if mix.id.hasSuffix("-night") {
                return .init(
                    colors: [
                        Color(red: 0.025, green: 0.035, blue: 0.12),
                        Color(red: 0.10, green: 0.18, blue: 0.54),
                        Color(red: 0.28, green: 0.23, blue: 0.60)
                    ],
                    signature: "AFTER DARK"
                )
            }
            if mix.id.hasSuffix("-afternoon") {
                return .init(
                    colors: [
                        Color(red: 0.30, green: 0.04, blue: 0.20),
                        Color(red: 0.92, green: 0.20, blue: 0.32),
                        Color(red: 1.0, green: 0.58, blue: 0.27)
                    ],
                    signature: "GOLDEN HOUR"
                )
            }
            return .init(
                colors: [
                    Color(red: 0.18, green: 0.07, blue: 0.46),
                    Color(red: 0.42, green: 0.20, blue: 0.95),
                    Color(red: 0.92, green: 0.48, blue: 0.82)
                ],
                signature: "RIGHT NOW"
            )
        case .repeatListening:
            return .init(
                colors: [
                    Color(red: 0.02, green: 0.08, blue: 0.22),
                    Color(red: 0.02, green: 0.34, blue: 0.88),
                    Color(red: 0.08, green: 0.66, blue: 0.72)
                ],
                signature: "ON ROTATION"
            )
        case .listenAgain:
            return .init(
                colors: [
                    Color(red: 0.24, green: 0.07, blue: 0.02),
                    Color(red: 0.82, green: 0.27, blue: 0.04),
                    Color(red: 0.98, green: 0.62, blue: 0.20)
                ],
                signature: "BACK IN TIME"
            )
        case .genre:
            return .init(
                colors: [
                    Color(red: 0.03, green: 0.12, blue: 0.08),
                    Color(red: 0.16, green: 0.47, blue: 0.16),
                    Color(red: 0.50, green: 0.70, blue: 0.06)
                ],
                signature: "DEEP CUTS"
            )
        case .artist:
            return .init(
                colors: [.black, Color(red: 0.56, green: 0.12, blue: 0.36)],
                signature: "ARTIST RADIO"
            )
        case .mood:
            if mix.id.hasPrefix("happy-mix") {
                return .init(
                    colors: [
                        Color(red: 0.48, green: 0.14, blue: 0.00),
                        Color(red: 0.98, green: 0.46, blue: 0.02),
                        Color(red: 1.0, green: 0.76, blue: 0.16)
                    ],
                    signature: "PURE JOY"
                )
            }
            if mix.id.hasPrefix("upbeat-mix") {
                return .init(
                    colors: [
                        Color(red: 0.28, green: 0.01, blue: 0.09),
                        Color(red: 0.94, green: 0.05, blue: 0.28),
                        Color(red: 0.98, green: 0.34, blue: 0.12)
                    ],
                    signature: "HIGH ENERGY"
                )
            }
            if mix.id.hasPrefix("chill-mix") {
                return .init(
                    colors: [
                        Color(red: 0.02, green: 0.10, blue: 0.15),
                        Color(red: 0.02, green: 0.40, blue: 0.48),
                        Color(red: 0.25, green: 0.66, blue: 0.66)
                    ],
                    signature: "SLOW FLOW"
                )
            }
            return .init(
                colors: [
                    Color(red: 0.11, green: 0.05, blue: 0.28),
                    Color(red: 0.48, green: 0.13, blue: 0.58),
                    Color(red: 0.88, green: 0.35, blue: 0.62)
                ],
                signature: "FEEL IT"
            )
        case .favorites:
            return .init(
                colors: [
                    Color(red: 0.13, green: 0.02, blue: 0.22),
                    Color(red: 0.46, green: 0.08, blue: 0.72),
                    Color(red: 0.92, green: 0.18, blue: 0.56)
                ],
                signature: "ALL YOURS"
            )
        case .ranking:
            return .init(
                colors: [
                    Color(red: 0.02, green: 0.05, blue: 0.18),
                    Color(red: 0.08, green: 0.24, blue: 0.78),
                    Color(red: 0.30, green: 0.20, blue: 0.92)
                ],
                signature: "YOUR CHART"
            )
        }
    }
}

private struct SmartMixCoverTheme {
    let colors: [Color]
    let signature: String
}

private struct SmartMixCoverBackground: View {
    let theme: SmartMixCoverTheme

    var body: some View {
        LinearGradient(
            colors: theme.colors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
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

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                hero
                    .buFiEntranceMotion(offset: 10)
                controls
                    .buFiVerticalSectionMotion(delay: 0.025)
                songs
                    .buFiVerticalSectionMotion(delay: 0.05)
            }
            .padding(.top, 12)
            .buFiMiniPlayerContentClearance()
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
                Text(mix.subtitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Text(
                String(
                    format: String(localized: "%d곡"),
                    mix.songs.count
                )
            )
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)

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
            .disabled(mix.songs.isEmpty)
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
            .disabled(mix.songs.isEmpty)
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
            BuFiGroupedSurface {
                LazyVStack(spacing: 0) {
                    ForEach(IndexedSong.list(mix.songs)) { item in
                        HStack(spacing: mix.showsRanking ? 10 : 2) {
                            if mix.showsRanking {
                                Text("\(item.index + 1)")
                                    .font(
                                        .system(
                                            size: 14,
                                            weight: item.index < 3 ? .bold : .medium,
                                            design: .rounded
                                        )
                                    )
                                    .foregroundStyle(
                                        item.index < 3
                                            ? BuFiTheme.accent
                                            : Color.secondary
                                    )
                                    .monospacedDigit()
                                    .frame(width: 24, alignment: .trailing)
                            }
                            SongRowCurrentTrackResolver(
                                song: item.song,
                                queue: mix.songs,
                                queueIndex: item.index,
                                artworkSize: 52,
                                textLineLimit: 2
                            )
                        }
                        .padding(.horizontal, 12)

                        if item.index < mix.songs.count - 1 {
                            Divider()
                                .padding(.leading, mix.showsRanking ? 112 : 78)
                                .opacity(0.50)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
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
