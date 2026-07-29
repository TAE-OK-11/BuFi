import SwiftUI

enum MusicRoute: Hashable {
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)
}

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var audio: AudioEngine
    @Environment(\.buFiMotionEnabled) private var motionEnabled
    @State private var filter = HomeFilter.all

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    BuFiPageHeader(
                        title: "홈",
                        subtitle: "내 음악과 새로운 추천을 한곳에서",
                        systemImage: "waveform"
                    )
                    filterBar
                    filteredContent
                }
                .padding(.top, 18)
                .padding(.bottom, 34)
            }
            .background(BuFiScreenBackground())
            .refreshable { await model.refresh() }
            .navigationDestination(for: MusicRoute.self) { route in
                MusicDetailView(route: route)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var filterBar: some View {
        BuFiFilterBar(
            items: HomeFilter.allCases,
            selection: $filter,
            fontSize: 14,
            title: { $0.title }
        )
    }

    @ViewBuilder
    private var filteredContent: some View {
        Group {
            switch filter {
            case .all:
                VStack(alignment: .leading, spacing: 28) {
                    musicOverview
                    playlistSection(showEmpty: false)
                    radioSection
                }
            case .music:
                musicOverview
            case .playlists:
                playlistSection(showEmpty: true)
            }
        }
        .id(filter)
        .transition(
            .opacity.combined(with: .offset(y: 6))
        )
        .animation(motionEnabled ? BuFiMotion.content : .none, value: filter)
    }

    private var musicOverview: some View {
        VStack(alignment: .leading, spacing: 28) {
            quickCarousel
            songSection(
                daylistTitle,
                songs: Array(model.home.daylistSongs.prefix(12))
            )
            songSection(
                "오프라인 백업",
                songs: Array(model.home.offlineBackupSongs.prefix(12))
            )
            albumSection(
                "최근 들은 앨범",
                albums: model.home.recentlyPlayedAlbums
            )
            rankedSongSection(
                "많이 들은 곡 순위",
                songs: Array(model.home.mostPlayedSongs.prefix(12))
            )
            artistSection(
                "좋아요 표시한 아티스트",
                artists: model.home.starredArtists
            )
            artistSection(
                "추천 아티스트",
                artists: model.home.recommendedArtists
            )
            albumSection("랜덤 앨범", albums: model.home.randomAlbums)
            albumSection("좋아요 표시한 앨범", albums: model.home.starredAlbums)
            albumSection("자주 들은 앨범", albums: model.home.frequentAlbums)
            albumSection("새로 추가된 음악", albums: model.home.recentAlbums)
        }
    }

    private var daylistTitle: String {
        let now = Date()
        let weekday = now.formatted(.dateTime.weekday(.wide))
        let format: String
        switch Calendar.current.component(.hour, from: now) {
        case 5..<11:
            format = String(localized: "%@ 아침 daylist")
        case 11..<17:
            format = String(localized: "%@ 오후 daylist")
        case 17..<22:
            format = String(localized: "%@ 저녁 daylist")
        default:
            format = String(localized: "%@ 밤 daylist")
        }
        return String(format: format, weekday)
    }

    private var quickCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 11) {
                Button {
                    if let first = model.home.starredSongs.first {
                        audio.play(first, in: model.home.starredSongs)
                    }
                } label: {
                    quickCategoryCard(
                        title: "좋아요 표시한 곡",
                        count: model.home.starredSongs.count,
                        songs: model.home.starredSongs,
                        icon: "heart.fill",
                        tint: BuFiTheme.accent
                    )
                }
                .buttonStyle(BuFiPressStyle())
                .disabled(model.home.starredSongs.isEmpty)

                Button {
                    if let first = model.home.mostPlayedSongs.first {
                        audio.play(first, in: model.home.mostPlayedSongs)
                    }
                } label: {
                    quickCategoryCard(
                        title: "많이 들은 곡 순위",
                        count: model.home.mostPlayedSongs.count,
                        songs: model.home.mostPlayedSongs,
                        icon: "chart.bar.fill",
                        tint: Color(red: 0.20, green: 0.48, blue: 0.70),
                        showsRank: true
                    )
                }
                .buttonStyle(BuFiPressStyle())
                .disabled(model.home.mostPlayedSongs.isEmpty)
            }
            .padding(.horizontal, 16)
        }
    }

    private func quickCategoryCard(
        title: String,
        count: Int,
        songs: [Song],
        icon: String,
        tint: Color,
        showsRank: Bool = false
    ) -> some View {
        BuFiFeatureCard(
            title: LocalizedStringKey(title),
            subtitle: String(
                format: String(localized: "%d곡"),
                count
            ),
            systemImage: icon,
            tint: tint,
            details: Array(songs.prefix(2).enumerated()).map { index, song in
                showsRank ? "\(index + 1). \(song.title)" : song.title
            }
        )
    }

    @ViewBuilder
    private func playlistSection(showEmpty: Bool) -> some View {
        if model.home.playlists.isEmpty {
            if showEmpty {
                ContentUnavailableView(
                    "플레이리스트가 없습니다",
                    systemImage: "music.note.list"
                )
                .frame(maxWidth: .infinity)
                .padding(.top, 44)
            }
        } else {
            VStack(alignment: .leading, spacing: 15) {
                SectionTitle(title: "내 플레이리스트")
                    .padding(.horizontal, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 15) {
                        ForEach(model.home.playlists) { playlist in
                            NavigationLink(value: MusicRoute.playlist(playlist)) {
                                VStack(alignment: .leading, spacing: 8) {
                                    playlistArtwork(playlist)
                                        .frame(width: 166, height: 166)
                                    Text(playlist.name)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    Text(
                                        String(
                                            format: String(localized: "%d곡"),
                                            playlist.songCount ?? 0
                                        )
                                    )
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                }
                                .frame(width: 166, alignment: .leading)
                            }
                            .buttonStyle(BuFiPressStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    @ViewBuilder
    private func playlistArtwork(_ playlist: Playlist) -> some View {
        if let cover = playlist.coverArt, !cover.isEmpty {
            ArtworkView(coverArt: cover, size: 166, cornerRadius: 14)
        } else {
            ZStack {
                LinearGradient(
                    colors: [
                        BuFiTheme.accent.opacity(0.72),
                        BuFiTheme.deezerGlow.opacity(0.82),
                        Color.black.opacity(0.68)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "music.note.list")
                    .font(.system(size: 48, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    @ViewBuilder
    private func artistSection(_ title: String, artists: [Artist]) -> some View {
        if !artists.isEmpty {
            VStack(alignment: .leading, spacing: 15) {
                SectionTitle(title: title, trailing: "라이브러리")
                    .padding(.horizontal, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 16) {
                        ForEach(artists.prefix(12)) { artist in
                            NavigationLink(value: MusicRoute.artist(artist)) {
                                VStack(spacing: 9) {
                                    ArtworkView(
                                        coverArt: artist.coverArt,
                                        size: 132,
                                        cornerRadius: 66
                                    )
                                    .frame(width: 132, height: 132)
                                    Text(artist.name)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(width: 132)
                            }
                            .buttonStyle(BuFiPressStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    @ViewBuilder
    private func rankedSongSection(_ title: String, songs: [Song]) -> some View {
        if !songs.isEmpty {
            VStack(alignment: .leading, spacing: 15) {
                SectionTitle(title: title)
                    .padding(.horizontal, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 15) {
                        ForEach(Array(songs.enumerated()), id: \.element.id) {
                            index, song in
                            Button {
                                audio.play(song, in: songs)
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    ZStack(alignment: .bottomLeading) {
                                        ArtworkView(
                                            coverArt: song.coverArt,
                                            size: 166,
                                            cornerRadius: 14
                                        )
                                        .frame(width: 166, height: 166)
                                        Text("\(index + 1)")
                                            .font(.system(size: 32, weight: .black, design: .rounded))
                                            .foregroundStyle(.white)
                                            .shadow(color: .black.opacity(0.55), radius: 5, y: 2)
                                            .padding(10)
                                    }
                                    Text(song.title)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    Text(song.artist)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(width: 166, alignment: .leading)
                            }
                            .buttonStyle(BuFiPressStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    @ViewBuilder
    private var radioSection: some View {
        if !model.home.radioStations.isEmpty {
            VStack(alignment: .leading, spacing: 15) {
                SectionTitle(title: "인터넷 라디오")
                    .padding(.horizontal, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 15) {
                        ForEach(model.home.radioStations.prefix(12)) { station in
                            Button {
                                model.playInternetRadio(station)
                            } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    ZStack {
                                        LinearGradient(
                                            colors: [
                                                BuFiTheme.accent.opacity(0.88),
                                                BuFiTheme.deezerGlow.opacity(0.76),
                                                Color.black.opacity(0.76)
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                        Image(systemName: "radio.fill")
                                            .font(.system(size: 42, weight: .semibold))
                                            .foregroundStyle(.white.opacity(0.9))
                                    }
                                    .frame(width: 166, height: 112)
                                    .clipShape(
                                        RoundedRectangle(
                                            cornerRadius: 18,
                                            style: .continuous
                                        )
                                    )
                                    Text(station.name)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(2)
                                    Text("라이브 스트림")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(width: 166, alignment: .leading)
                            }
                            .buttonStyle(BuFiPressStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    @ViewBuilder
    private func albumSection(_ title: String, albums: [Album]) -> some View {
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 15) {
                SectionTitle(title: title, trailing: "라이브러리")
                    .padding(.horizontal, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 15) {
                        ForEach(albums.prefix(12)) { album in
                            NavigationLink(value: MusicRoute.album(album)) {
                                AlbumCard(album: album)
                            }
                            .buttonStyle(BuFiPressStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    @ViewBuilder
    private func songSection(_ title: String, songs: [Song]) -> some View {
        if !songs.isEmpty {
            VStack(alignment: .leading, spacing: 15) {
                SectionTitle(title: title)
                    .padding(.horizontal, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 15) {
                        ForEach(songs) { song in
                            Button {
                                audio.play(song, in: songs)
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    ArtworkView(coverArt: song.coverArt, size: 166, cornerRadius: 14)
                                        .frame(width: 166, height: 166)
                                    Text(song.title)
                                        .font(.system(size: 15, weight: .semibold))
                                        .lineLimit(2)
                                    Text(song.artist)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .frame(width: 166, alignment: .leading)
                            }
                            .buttonStyle(BuFiPressStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }
}

private enum HomeFilter: Int, CaseIterable, Identifiable {
    case all
    case music
    case playlists

    var id: Int { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .all: "전체"
        case .music: "음악"
        case .playlists: "플레이리스트"
        }
    }
}
