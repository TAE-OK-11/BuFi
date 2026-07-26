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

    private let columns = [
        GridItem(.flexible(), spacing: 9),
        GridItem(.flexible(), spacing: 9)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 30) {
                    header
                    filteredContent
                }
                .padding(.bottom, 28)
            }
            .background(BuFiScreenBackground())
            .refreshable { await model.refresh() }
            .navigationDestination(for: MusicRoute.self) { route in
                MusicDetailView(route: route)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(greeting)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("홈")
                        .font(.system(size: 34, weight: .bold))
                        .tracking(-1.1)
                }
                Spacer()
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [BuFiTheme.accentSoft, BuFiTheme.deezerGlow],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 40, height: 40)
                    .overlay {
                        Text("T")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                Button {
                    Task { await model.refresh() }
                } label: {
                    if model.isRefreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 40, height: 40)
                            .background(BuFiTheme.elevated, in: Circle())
                    }
                }
                .buttonStyle(BuFiPressStyle())
                .accessibilityLabel("라이브러리 새로고침")
            }

            HStack(spacing: 8) {
                ForEach(HomeFilter.allCases) { item in
                    filterPill(item)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    @ViewBuilder
    private var filteredContent: some View {
        switch filter {
        case .all:
            quickGrid
            albumSection("새로 추가된 음악", albums: model.home.recentAlbums)
            songSection("다시 들어보세요", songs: Array(model.home.randomSongs.prefix(12)))
            playlistSection(showEmpty: false)
            albumSection("내 라이브러리 추천", albums: model.home.randomAlbums)
            if !model.home.starredAlbums.isEmpty {
                albumSection("좋아요 표시한 앨범", albums: model.home.starredAlbums)
            }
        case .music:
            quickGrid
            albumSection("새로 추가된 음악", albums: model.home.recentAlbums)
            songSection("다시 들어보세요", songs: Array(model.home.randomSongs.prefix(12)))
            albumSection("내 라이브러리 추천", albums: model.home.randomAlbums)
            if !model.home.starredAlbums.isEmpty {
                albumSection("좋아요 표시한 앨범", albums: model.home.starredAlbums)
            }
        case .playlists:
            playlistSection(showEmpty: true)
        }
    }

    private var quickGrid: some View {
        LazyVGrid(columns: columns, spacing: 9) {
            if !model.home.starredSongs.isEmpty {
                Button {
                    if let first = model.home.starredSongs.first {
                        audio.play(first, in: model.home.starredSongs)
                    }
                } label: {
                    quickCard(title: "좋아요 표시한 곡", coverArt: model.home.starredSongs.first?.coverArt)
                }
                .buttonStyle(BuFiPressStyle())
            }
            ForEach(Array(model.home.recentAlbums.prefix(7))) { album in
                NavigationLink(value: MusicRoute.album(album)) {
                    quickCard(title: album.name, coverArt: album.coverArt)
                }
                .buttonStyle(BuFiPressStyle())
            }
        }
        .padding(.horizontal, 16)
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
                                    ArtworkView(
                                        coverArt: playlist.coverArt,
                                        size: 166,
                                        cornerRadius: 9
                                    )
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

    private func quickCard(title: String, coverArt: String?) -> some View {
        HStack(spacing: 0) {
            ArtworkView(coverArt: coverArt, size: 60, cornerRadius: 4)
                .frame(width: 60, height: 60)
            Text(LocalizedStringKey(title))
                .font(.system(size: 14, weight: .bold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 60)
        .background(
            BuFiTheme.elevated,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(BuFiTheme.separator.opacity(0.35), lineWidth: 0.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private func albumSection(_ title: String, albums: [Album]) -> some View {
        if !albums.isEmpty {
            VStack(alignment: .leading, spacing: 15) {
                SectionTitle(title: title, trailing: "라이브러리")
                    .padding(.horizontal, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 15) {
                        ForEach(Array(albums.prefix(18))) { album in
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

    private func filterPill(_ item: HomeFilter) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.24)) { filter = item }
        } label: {
            Text(item.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(filter == item ? .white : .primary)
                .padding(.horizontal, 16)
                .frame(height: 34)
                .background(
                    filter == item ? BuFiTheme.accent : BuFiTheme.elevated,
                    in: Capsule()
                )
        }
        .buttonStyle(BuFiPressStyle())
    }

    private var greeting: LocalizedStringKey {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "좋은 아침이에요"
        case 12..<18: "좋은 오후예요"
        default: "좋은 저녁이에요"
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
