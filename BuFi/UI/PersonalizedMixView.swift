import SwiftUI

struct PersonalizedMixArtwork: View {
    let mix: PersonalizedMix
    var size: CGFloat = 166
    var cornerRadius: CGFloat = 16

    var body: some View {
        let coverArts = mix.coverArts
        VStack(spacing: 2) {
            HStack(spacing: 2) {
                artworkCell(0, coverArts: coverArts)
                artworkCell(1, coverArts: coverArts)
            }
            HStack(spacing: 2) {
                artworkCell(2, coverArts: coverArts)
                artworkCell(3, coverArts: coverArts)
            }
        }
        .frame(width: size, height: size)
        .background(BuFiTheme.elevated)
        .clipShape(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(BuFiTheme.separator.opacity(0.26), lineWidth: 0.7)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func artworkCell(
        _ index: Int,
        coverArts: [String]
    ) -> some View {
        if coverArts.indices.contains(index) {
            ArtworkView(
                coverArt: coverArts[index],
                size: size / 2,
                cornerRadius: 0
            )
            .frame(width: size / 2 - 1, height: size / 2 - 1)
        } else {
            ZStack {
                Color.secondary.opacity(0.12)
                Image(systemName: fallbackIcon)
                    .font(.system(size: size * 0.095, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: size / 2 - 1, height: size / 2 - 1)
        }
    }

    private var fallbackIcon: String {
        switch mix.kind {
        case .daylist: "sun.horizon.fill"
        case .repeatListening: "repeat"
        case .listenAgain: "clock.arrow.circlepath"
        case .genre: "music.note"
        case .artist: "person.wave.2.fill"
        case .mood: "sparkles"
        case .favorites: "heart.fill"
        case .ranking: "chart.bar.fill"
        }
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
