import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var filter = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 44, height: 44)
                            .overlay { Text("T").foregroundStyle(.black) }
                        Text("내 라이브러리")
                            .font(.system(size: 30, weight: .bold))
                            .tracking(-1)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)

                    Picker("라이브러리 필터", selection: $filter) {
                        Text("플레이리스트").tag(0)
                        Text("앨범").tag(1)
                        Text("아티스트").tag(2)
                        Text("곡").tag(3)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)

                    content
                }
                .padding(.bottom, 28)
            }
            .background(Color(red: 0.07, green: 0.07, blue: 0.07))
            .refreshable { await model.refresh() }
            .navigationDestination(for: MusicRoute.self) { route in
                MusicDetailView(route: route)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch filter {
        case 0:
            if model.home.playlists.isEmpty {
                empty("플레이리스트가 없습니다", icon: "music.note.list")
            } else {
                ForEach(model.home.playlists) { playlist in
                    NavigationLink(value: MusicRoute.playlist(playlist)) {
                        libraryRow(
                            title: playlist.name,
                            subtitle: "플레이리스트 · \(playlist.songCount ?? 0)곡",
                            cover: playlist.coverArt,
                            circle: false
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        case 1:
            if model.home.starredAlbums.isEmpty {
                empty("저장한 앨범이 없습니다", icon: "square.stack")
            } else {
                ForEach(model.home.starredAlbums) { album in
                    NavigationLink(value: MusicRoute.album(album)) {
                        libraryRow(
                            title: album.name,
                            subtitle: "앨범 · \(album.artist)",
                            cover: album.coverArt,
                            circle: false
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        case 2:
            if model.home.starredArtists.isEmpty {
                empty("팔로우한 아티스트가 없습니다", icon: "person.2")
            } else {
                ForEach(model.home.starredArtists) { artist in
                    NavigationLink(value: MusicRoute.artist(artist)) {
                        libraryRow(
                            title: artist.name,
                            subtitle: "아티스트",
                            cover: artist.coverArt,
                            circle: true
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        default:
            if model.home.starredSongs.isEmpty {
                empty("좋아요 표시한 곡이 없습니다", icon: "heart")
            } else {
                ForEach(model.home.starredSongs) { song in
                    SongRow(song: song, queue: model.home.starredSongs)
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func libraryRow(
        title: String,
        subtitle: String,
        cover: String?,
        circle: Bool
    ) -> some View {
        HStack(spacing: 13) {
            ArtworkView(
                coverArt: cover,
                size: 68,
                cornerRadius: circle ? 34 : 6
            )
            .frame(width: 68, height: 68)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private func empty(_ title: String, icon: String) -> some View {
        ContentUnavailableView(title, systemImage: icon)
            .frame(maxWidth: .infinity)
            .padding(.top, 70)
    }
}

