import SwiftUI

enum MusicRoute: Hashable {
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)
}

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: HomeLibraryState
    @Environment(\.buFiMotionEnabled) private var motionEnabled
    @AppStorage(ArtistMixPreferences.storageKey)
    private var selectedArtistMixes = "[]"
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
            title: { $0.title }
        )
    }

    @ViewBuilder
    private var filteredContent: some View {
        Group {
            switch filter {
            case .all:
                allContent(
                    mixes: personalizedMixes
                )
            case .playlists:
                playlistSection(showEmpty: true)
            case .personalized:
                personalizedContent(
                    personalizedMixes
                )
            }
        }
        .transition(.opacity)
        .animation(motionEnabled ? BuFiMotion.content : .none, value: filter)
    }

    private var personalizedMixes: [PersonalizedMix] {
        PersonalizedMixBuilder.make(
            snapshot: library.snapshot,
            selectedArtists: ArtistMixPreferences.decode(selectedArtistMixes)
        )
    }

    private func allContent(mixes: [PersonalizedMix]) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            shortcuts
            albumSection("오늘 골라본 앨범", albums: library.snapshot.randomAlbums)
            albumSection("좋아하는 앨범", albums: library.snapshot.starredAlbums)
            albumSection("취향을 닮은 앨범", albums: recommendedAlbums)
            artistSection("즐겨 듣는 아티스트", artists: primaryArtists)
            personalizedMixSection(
                "아티스트에서 이어 듣기",
                mixes: mixes.filter { $0.kind == .artist }
            )
            artistSection(
                "놓치면 아쉬운 아티스트",
                artists: featuredArtists
            )
            albumSection(
                "최근 감상",
                albums: library.snapshot.recentlyPlayedAlbums
            )
            albumSection("다시 찾는 앨범", albums: library.snapshot.frequentAlbums)
            albumSection("새로 만나는 음악", albums: library.snapshot.recentAlbums)
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
                    library.snapshot.starredSongs
                )
            ) {
                BuFiShortcutCard(
                    title: "좋아요 표시한 곡",
                    systemImage: "heart.fill",
                    tint: BuFiTheme.accent
                )
            }
            .buttonStyle(BuFiPressStyle())
            .disabled(library.snapshot.starredSongs.isEmpty)

            NavigationLink(
                value: PersonalizedMixBuilder.mostPlayedSongs(
                    library.snapshot.mostPlayedSongs
                )
            ) {
                BuFiShortcutCard(
                    title: "자주 들은 곡",
                    systemImage: "chart.bar.fill",
                    tint: Color(red: 0.22, green: 0.50, blue: 0.78)
                )
            }
            .buttonStyle(BuFiPressStyle())
            .disabled(library.snapshot.mostPlayedSongs.isEmpty)
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
        if library.snapshot.playlists.isEmpty {
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
                SectionTitle(title: "내 플레이리스트")
                    .padding(.horizontal, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 15) {
                        ForEach(library.snapshot.playlists) { playlist in
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
                Image(systemName: "music.note.list")
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(BuFiTheme.accentSoft)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .buFiSurface(cornerRadius: 14, clipsContent: true)
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
        if !library.snapshot.radioStations.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(title: "라이브 라디오")
                    .padding(.horizontal, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 15) {
                        ForEach(library.snapshot.radioStations.prefix(12)) { station in
                            Button {
                                model.playInternetRadio(station)
                            } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    ZStack {
                                        Image(systemName: "radio.fill")
                                            .font(.system(size: 40, weight: .semibold))
                                            .foregroundStyle(BuFiTheme.accentSoft)
                                    }
                                    .frame(width: 166, height: 112)
                                    .buFiSurface(
                                        cornerRadius: 18,
                                        clipsContent: true
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
        if !library.snapshot.starredArtists.isEmpty {
            return library.snapshot.starredArtists
        }
        return Array(library.snapshot.artists.prefix(12))
    }

    private var featuredArtists: [Artist] {
        let songSources =
            library.snapshot.starredSongs +
            library.snapshot.mostPlayedSongs +
            library.snapshot.recommendedSongs +
            library.snapshot.randomSongs
        let artistSources =
            library.snapshot.recommendedArtists +
            library.snapshot.starredArtists +
            library.snapshot.artists

        var taylor = artistSources.first {
            normalizedArtistName($0.name) == "taylor swift"
        }
        if taylor == nil,
           let album = (
               library.snapshot.starredAlbums +
               library.snapshot.randomAlbums +
               library.snapshot.recentAlbums
           ).first(where: {
               normalizedArtistName($0.artist) == "taylor swift"
           }),
           let artistID = album.artistId,
           !artistID.isEmpty {
            taylor = Artist(
                id: artistID,
                name: "Taylor Swift",
                coverArt: album.coverArt,
                albumCount: nil,
                starred: nil
            )
        }
        if taylor == nil,
           let song = songSources.first(where: {
               normalizedArtistName($0.artist) == "taylor swift"
           }),
           let artistID = song.artistId,
           !artistID.isEmpty {
            taylor = Artist(
                id: artistID,
                name: "Taylor Swift",
                coverArt: song.coverArt,
                albumCount: nil,
                starred: nil
            )
        }

        var values: [Artist] = []
        var seen = Set<String>()
        func append(_ artist: Artist?) {
            guard let artist else { return }
            let key = normalizedArtistName(artist.name)
            guard !key.isEmpty, seen.insert(key).inserted else { return }
            values.append(artist)
        }

        append(taylor)
        library.snapshot.starredArtists.forEach { append($0) }
        library.snapshot.recommendedArtists.forEach { append($0) }
        library.snapshot.artists.forEach { append($0) }
        return Array(values.prefix(12))
    }

    private func normalizedArtistName(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var recommendedAlbums: [Album] {
        let sourceAlbums =
            library.snapshot.randomAlbums +
            library.snapshot.recentAlbums +
            library.snapshot.frequentAlbums +
            library.snapshot.recentlyPlayedAlbums +
            library.snapshot.starredAlbums
        var albumsByID: [String: Album] = [:]
        for album in sourceAlbums where albumsByID[album.id] == nil {
            albumsByID[album.id] = album
        }

        var result: [Album] = []
        var seen = Set<String>()
        for song in library.snapshot.recommendedSongs {
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
