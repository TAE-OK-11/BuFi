import SwiftUI

struct PersonalizedMixArtwork: View {
    let mix: PersonalizedMix
    var size: CGFloat = 166
    var cornerRadius: CGFloat = 16

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Image(assetName)
                .resizable()
                .scaledToFill()

            LinearGradient(
                colors: [.clear, .black.opacity(0.28)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: max(4, size * 0.022)) {
                    Capsule()
                        .frame(width: max(24, size * 0.16), height: max(3, size * 0.018))
                    Circle()
                        .frame(width: max(3, size * 0.018), height: max(3, size * 0.018))
                }
                .opacity(0.86)

                Spacer(minLength: 0)

                Text(coverTitle)
                    .font(
                        .system(
                            size: max(21, size * 0.125),
                            weight: .black
                        )
                    )
                    .tracking(-size * 0.008)
                    .lineLimit(3)
                    .minimumScaleFactor(0.62)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(.white)
            .padding(max(12, size * 0.065))
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
        case .daylist: "MixDaylist"
        case .repeatListening: "MixRepeat"
        case .listenAgain: "MixListenAgain"
        case .genre: "MixGenre"
        case .artist: "MixArtist"
        case .mood: "MixMood"
        case .favorites: "MixFavorites"
        case .ranking: "MixRanking"
        }
    }

    private var coverTitle: String {
        mix.title
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
                .fixedSize(horizontal: false, vertical: true)
            Text(mix.subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: width, alignment: .leading)
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
                        HStack(spacing: 2) {
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
                                    .frame(width: 28, alignment: .trailing)
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
                                .padding(.leading, mix.showsRanking ? 106 : 78)
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
