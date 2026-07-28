import SwiftUI

enum MusicRoute: Hashable {
    case album(Album)
    case artist(Artist)
    case playlist(Playlist)
}

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var audio: AudioEngine
    @State private var filter = HomeFilter.all

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    filterBar
                    filteredContent
                }
                .padding(.top, 24)
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
                    quickCarousel
                    albumSection("새로 추가된 음악", albums: model.home.recentAlbums)
                    songSection("다시 들어보세요", songs: Array(model.home.randomSongs.prefix(12)))
                    playlistSection(showEmpty: false)
                    albumSection("내 라이브러리 추천", albums: model.home.randomAlbums)
                    if !model.home.starredAlbums.isEmpty {
                        albumSection("좋아요 표시한 앨범", albums: model.home.starredAlbums)
                    }
                }
            case .music:
                VStack(alignment: .leading, spacing: 28) {
                    quickCarousel
                    albumSection("새로 추가된 음악", albums: model.home.recentAlbums)
                    songSection("다시 들어보세요", songs: Array(model.home.randomSongs.prefix(12)))
                    albumSection("내 라이브러리 추천", albums: model.home.randomAlbums)
                    if !model.home.starredAlbums.isEmpty {
                        albumSection("좋아요 표시한 앨범", albums: model.home.starredAlbums)
                    }
                }
            case .playlists:
                playlistSection(showEmpty: true)
            }
        }
        .id(filter)
        .transition(
            .opacity.combined(with: .scale(scale: 0.995))
        )
    }

    private var quickCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 11) {
                if !model.home.starredSongs.isEmpty {
                    Button {
                        if let first = model.home.starredSongs.first {
                            audio.play(first, in: model.home.starredSongs)
                        }
                    } label: {
                        quickCategoryCard(
                            title: "좋아요 표시한 곡",
                            coverArt: nil,
                            icon: "heart.fill",
                            colors: [
                                Color(red: 0.78, green: 0.16, blue: 0.27),
                                Color(red: 0.47, green: 0.14, blue: 0.45)
                            ]
                        )
                    }
                    .buttonStyle(BuFiPressStyle())
                }

                ForEach(
                    Array(model.home.recentAlbums.prefix(5).enumerated()),
                    id: \.element.id
                ) { index, album in
                    NavigationLink(value: MusicRoute.album(album)) {
                        quickCategoryCard(
                            title: album.name,
                            coverArt: album.coverArt,
                            icon: "square.stack.fill",
                            colors: quickCardColors(index)
                        )
                    }
                    .buttonStyle(BuFiPressStyle())
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func quickCategoryCard(
        title: String,
        coverArt: String?,
        icon: String,
        colors: [Color]
    ) -> some View {
        ZStack(alignment: .bottomTrailing) {
            LinearGradient(
                colors: colors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let coverArt, !coverArt.isEmpty {
                ArtworkView(coverArt: coverArt, size: 66, cornerRadius: 8)
                    .frame(width: 66, height: 66)
                    .rotationEffect(.degrees(6))
                    .shadow(color: .black.opacity(0.28), radius: 8, y: 5)
                    .offset(x: 10, y: 12)
            } else {
                Image(systemName: icon)
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.19))
                    .rotationEffect(.degrees(8))
                    .padding(12)
            }

            Text(LocalizedStringKey(title))
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: 118, maxHeight: .infinity, alignment: .topLeading)
                .padding(13)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 176, height: 92)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.7)
        }
        .shadow(color: colors.first?.opacity(0.16) ?? .clear, radius: 12, y: 6)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func quickCardColors(_ index: Int) -> [Color] {
        switch index % 5 {
        case 0:
            [Color(red: 0.18, green: 0.37, blue: 0.58), Color(red: 0.20, green: 0.18, blue: 0.44)]
        case 1:
            [Color(red: 0.10, green: 0.48, blue: 0.43), Color(red: 0.08, green: 0.27, blue: 0.34)]
        case 2:
            [Color(red: 0.64, green: 0.31, blue: 0.20), Color(red: 0.39, green: 0.18, blue: 0.29)]
        case 3:
            [Color(red: 0.43, green: 0.25, blue: 0.61), Color(red: 0.25, green: 0.16, blue: 0.42)]
        default:
            [Color(red: 0.34, green: 0.39, blue: 0.43), Color(red: 0.18, green: 0.22, blue: 0.28)]
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
            ArtworkView(coverArt: cover, size: 166, cornerRadius: 9)
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
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
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
                        ForEach(albums.prefix(18)) { album in
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
                                    ArtworkView(coverArt: song.coverArt, size: 166, cornerRadius: 7)
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
