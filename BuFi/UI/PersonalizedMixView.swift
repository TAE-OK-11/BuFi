import SwiftUI

struct PersonalizedMixArtwork: View {
    let mix: PersonalizedMix
    var size: CGFloat = 166
    var cornerRadius: CGFloat = 16

    var body: some View {
        ZStack(alignment: .topLeading) {
            if mix.kind == .artist, let coverArt = mix.artworkCoverArt {
                ArtworkView(
                    coverArt: coverArt,
                    size: size,
                    cornerRadius: 0
                )
                .frame(width: size, height: size)

                LinearGradient(
                    colors: [.clear, .black.opacity(0.48)],
                    startPoint: .center,
                    endPoint: .bottom
                )

                VStack {
                    Spacer()
                    Text(coverTitle)
                        .font(coverFont)
                        .tracking(-size * 0.006)
                        .foregroundStyle(.black)
                        .lineLimit(2)
                        .minimumScaleFactor(0.64)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, max(10, size * 0.06))
                        .padding(.vertical, max(7, size * 0.04))
                        .background(Color(red: 0.77, green: 1.0, blue: 0.28))
                        .padding(.bottom, max(12, size * 0.07))
                }
            } else {
                Image(assetName)
                    .resizable()
                    .scaledToFill()

                VStack(alignment: .leading, spacing: 0) {
                    Text(coverTitle)
                        .font(coverFont)
                        .tracking(-size * 0.006)
                        .lineLimit(3)
                        .minimumScaleFactor(0.70)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)
                }
                .foregroundStyle(foreground)
                .padding(max(13, size * 0.075))
            }
        }
        .frame(width: size, height: size)
        .clipShape(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(BuFiTheme.separator.opacity(0.26), lineWidth: 0.7)
        }
        .accessibilityHidden(true)
    }

    private var assetName: String {
        switch mix.kind {
        case .daylist:
            if mix.id.hasSuffix("-night") {
                "MixMidnightDrive"
            } else if mix.id.hasSuffix("-afternoon") {
                "MixSunset"
            } else {
                "MixDaylist"
            }
        case .repeatListening: "MixRepeat"
        case .listenAgain: "MixListenAgain"
        case .genre: "MixGenre"
        case .artist: "MixArtist"
        case .mood:
            if mix.id.hasPrefix("happy-mix") {
                "MixMoodBoost"
            } else if mix.id.hasPrefix("upbeat-mix") {
                "MixWorkoutEnergy"
            } else if mix.id.hasPrefix("chill-mix") {
                "MixChillWaves"
            } else {
                "MixMood"
            }
        case .favorites: "MixLikedSongs"
        case .ranking: "MixTopTracks"
        }
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

    private var foreground: Color {
        switch assetName {
        case "MixListenAgain", "MixGenre", "MixMood",
             "MixMoodBoost", "MixChillWaves":
            Color(red: 0.08, green: 0.06, blue: 0.15)
        default: .white
        }
    }

    private var coverFont: Font {
        let fontSize = max(18, size * 0.115)
        let supportsUnbounded = coverTitle.unicodeScalars.allSatisfy {
            $0.isASCII
        }
        if supportsUnbounded {
            return .custom("Unbounded-Black", fixedSize: fontSize)
        }
        return .system(
            size: fontSize,
            weight: .black,
            design: .rounded
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
    @EnvironmentObject private var audio: AudioEngine

    let mix: PersonalizedMix

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                hero
                controls
                songs
            }
            .padding(.top, 12)
            .padding(.bottom, audio.currentSong == nil ? 56 : 148)
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
            BuFiGroupedSurface {
                LazyVStack(spacing: 0) {
                    ForEach(Array(mix.songs.enumerated()), id: \.element.id) {
                        index, song in
                        HStack(spacing: mix.showsRanking ? 10 : 2) {
                            if mix.showsRanking {
                                Text("\(index + 1)")
                                    .font(
                                        .system(
                                            size: 14,
                                            weight: index < 3 ? .bold : .medium,
                                            design: .rounded
                                        )
                                    )
                                    .foregroundStyle(
                                        index < 3
                                            ? BuFiTheme.accent
                                            : Color.secondary
                                    )
                                    .monospacedDigit()
                                    .frame(width: 24, alignment: .trailing)
                            }
                            SongRow(
                                song: song,
                                queue: mix.songs,
                                artworkSize: 52,
                                textLineLimit: 2
                            )
                        }
                        .padding(.horizontal, 12)

                        if song.id != mix.songs.last?.id {
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
