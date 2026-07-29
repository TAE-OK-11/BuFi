import SwiftUI

enum MusicRoute: Hashable {
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)
}

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.buFiMotionEnabled) private var motionEnabled
    @State private var filter = HomeFilter.all

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    BuFiPageHeader(title: "홈")
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
            .navigationDestination(for: PersonalizedMix.self) { mix in
                PersonalizedMixDetailView(mix: mix)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var filterBar: some View {
        BuFiFilterBar(
            items: HomeFilter.allCases,
            selection: $filter,
            fontSize: 13,
            title: { $0.title }
        )
    }

    @ViewBuilder
    private var filteredContent: some View {
        Group {
            switch filter {
            case .all:
                allContent(
                    mixes: PersonalizedMixBuilder.make(snapshot: model.home)
                )
            case .playlists:
                playlistSection(showEmpty: true)
            case .personalized:
                personalizedContent(
                    PersonalizedMixBuilder.make(snapshot: model.home)
                )
            }
        }
        .id(filter)
        .transition(.opacity.combined(with: .offset(y: 5)))
        .animation(motionEnabled ? BuFiMotion.content : .none, value: filter)
    }

    private func allContent(mixes: [PersonalizedMix]) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            shortcuts
            albumSection("랜덤 앨범", albums: model.home.randomAlbums)
            albumSection("좋아요 표시한 앨범", albums: model.home.starredAlbums)
            albumSection("알고리즘 추천 앨범", albums: recommendedAlbums)
            artistSection("아티스트", artists: primaryArtists)
            personalizedMixSection(
                "아티스트 추천 플레이리스트",
                mixes: mixes.filter { $0.kind == .artist }
            )
            artistSection(
                "추천 아티스트",
                artists: model.home.recommendedArtists
            )
            albumSection(
                "최근 들은 앨범",
                albums: model.home.recentlyPlayedAlbums
            )
            albumSection("자주 들은 앨범", albums: model.home.frequentAlbums)
            albumSection("새로 추가된 음악", albums: model.home.recentAlbums)
            playlistSection(showEmpty: false)
            radioSection
        }
    }

    private func personalizedContent(
        _ mixes: [PersonalizedMix]
    ) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            personalizedMixSection(
                "오늘의 믹스",
                mixes: mixes.filter {
                    [.daylist, .repeatListening, .listenAgain, .genre]
                        .contains($0.kind)
                }
            )
            personalizedMixSection(
                "아티스트 믹스",
                mixes: mixes.filter { $0.kind == .artist }
            )
            personalizedMixSection(
                "무드별 믹스",
                mixes: mixes.filter { $0.kind == .mood }
            )
        }
    }

    private var shortcuts: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10)
            ],
            spacing: 10
        ) {
            NavigationLink(
                value: PersonalizedMixBuilder.favoriteSongs(
                    model.home.starredSongs
                )
            ) {
                BuFiShortcutCard(
                    title: "좋아요 표시한 곡",
                    subtitle: countText(model.home.starredSongs.count),
                    systemImage: "heart.fill",
                    tint: BuFiTheme.accent
                )
            }
            .buttonStyle(BuFiPressStyle())
            .disabled(model.home.starredSongs.isEmpty)

            NavigationLink(
                value: PersonalizedMixBuilder.mostPlayedSongs(
                    model.home.mostPlayedSongs
                )
            ) {
                BuFiShortcutCard(
                    title: "많이 들은 곡 순위",
                    subtitle: countText(model.home.mostPlayedSongs.count),
                    systemImage: "chart.bar.fill",
                    tint: Color(red: 0.22, green: 0.50, blue: 0.78)
                )
            }
            .buttonStyle(BuFiPressStyle())
            .disabled(model.home.mostPlayedSongs.isEmpty)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func personalizedMixSection(
        _ title: String,
        mixes: [PersonalizedMix]
    ) -> some View {
        if !mixes.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(title: title)
                    .padding(.horizontal, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 15) {
                        ForEach(mixes) { mix in
                            NavigationLink(value: mix) {
                                PersonalizedMixCard(mix: mix)
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
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(title: "플레이리스트")
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
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(countText(playlist.songCount ?? 0))
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
                BuFiTheme.elevated
                Image(systemName: "music.note.list")
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(BuFiTheme.accentSoft)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(BuFiTheme.separator.opacity(0.28), lineWidth: 0.7)
            }
        }
    }

    @ViewBuilder
    private func artistSection(_ title: String, artists: [Artist]) -> some View {
        if !artists.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(title: title)
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
                                        .fixedSize(horizontal: false, vertical: true)
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
    private var radioSection: some View {
        if !model.home.radioStations.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
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
                                        BuFiTheme.elevated
                                        Image(systemName: "radio.fill")
                                            .font(.system(size: 40, weight: .semibold))
                                            .foregroundStyle(BuFiTheme.accentSoft)
                                    }
                                    .frame(width: 166, height: 112)
                                    .clipShape(
                                        RoundedRectangle(
                                            cornerRadius: 18,
                                            style: .continuous
                                        )
                                    )
                                    .overlay {
                                        RoundedRectangle(
                                            cornerRadius: 18,
                                            style: .continuous
                                        )
                                        .stroke(
                                            BuFiTheme.separator.opacity(0.28),
                                            lineWidth: 0.7
                                        )
                                    }
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
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(title: title)
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

    private var primaryArtists: [Artist] {
        if !model.home.starredArtists.isEmpty {
            return model.home.starredArtists
        }
        return Array(model.home.artists.prefix(12))
    }

    private var recommendedAlbums: [Album] {
        let sourceAlbums =
            model.home.randomAlbums +
            model.home.recentAlbums +
            model.home.frequentAlbums +
            model.home.recentlyPlayedAlbums +
            model.home.starredAlbums
        var albumsByID: [String: Album] = [:]
        for album in sourceAlbums where albumsByID[album.id] == nil {
            albumsByID[album.id] = album
        }

        var result: [Album] = []
        var seen = Set<String>()
        for song in model.home.recommendedSongs {
            guard let albumID = song.albumId,
                  !albumID.isEmpty,
                  seen.insert(albumID).inserted else {
                continue
            }
            if let album = albumsByID[albumID] {
                result.append(album)
            } else if !song.album.isEmpty {
                result.append(
                    Album(
                        id: albumID,
                        name: song.album,
                        artist: song.artist,
                        coverArt: song.coverArt,
                        year: nil,
                        starred: nil,
                        artistId: song.artistId,
                        genre: song.genre
                    )
                )
            }
            if result.count == 12 { break }
        }
        return result
    }

    private func countText(_ count: Int) -> String {
        String(format: String(localized: "%d곡"), count)
    }
}

private enum HomeFilter: Int, CaseIterable, Identifiable {
    case all
    case playlists
    case personalized

    var id: Int { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .all: "전체"
        case .playlists: "플레이리스트"
        case .personalized: "나만의 플레이리스트"
        }
    }
}
