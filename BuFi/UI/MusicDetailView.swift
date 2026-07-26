import SwiftUI

struct MusicDetailView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var audio: AudioEngine

    let route: MusicRoute

    @State private var title = ""
    @State private var subtitle = ""
    @State private var coverArt: String?
    @State private var songs: [Song] = []
    @State private var albums: [Album] = []
    @State private var isLoading = true
    @State private var selectedSong: Song?
    @State private var palette = ArtworkPalette.fallback
    @State private var isFavorite = false
    @State private var artistImageURL: String?
    @State private var artistBiography = ""
    @State private var artistAlbumCount = 0

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                hero
                if isLoading {
                    ProgressView("불러오는 중…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else {
                    controls
                    if !albums.isEmpty { albumRail }
                    songList
                    if isArtist, !artistBiography.isEmpty { artistAbout }
                }
            }
            .padding(.bottom, audio.currentSong == nil ? 48 : 136)
        }
        .background(background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task(id: route) { await load() }
        .sheet(item: $selectedSong) { song in
            SongActionsSheet(song: song)
                .presentationDetents([.height(245)])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var hero: some View {
        if isArtist {
            artistHero
        } else {
            collectionHero
        }
    }

    private var artistHero: some View {
        ZStack(alignment: .bottomLeading) {
            ArtworkView(
                coverArt: coverArt,
                remoteURL: artistImageURL,
                size: 430,
                cornerRadius: 24,
                contentMode: .fit,
                blurredBackdrop: true,
                onPalette: { palette = $0 }
            )
            .frame(maxWidth: .infinity)
            .frame(height: 360)

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.48),
                    .init(color: .black.opacity(0.16), location: 0.68),
                    .init(color: .black.opacity(0.86), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 7) {
                Text(title.isEmpty ? " " : title)
                    .font(.system(size: 35, weight: .bold))
                    .tracking(-1.2)
                    .lineLimit(2)
                Text(
                    String(
                        format: String(localized: "%d개 앨범 · %d개 인기곡"),
                        max(artistAlbumCount, albums.count),
                        songs.count
                    )
                )
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.78))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.bottom, 20)
        }
        .shadow(color: .black.opacity(0.24), radius: 22, y: 12)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 18)
    }

    private var collectionHero: some View {
        VStack(spacing: 19) {
            ArtworkView(
                coverArt: coverArt,
                size: 270,
                cornerRadius: isArtist ? 135 : 10,
                onPalette: { palette = $0 }
            )
            .frame(width: 270, height: 270)
            .shadow(color: .black.opacity(0.34), radius: 24, y: 14)

            VStack(spacing: 7) {
                Text(title.isEmpty ? " " : title)
                    .font(.system(size: 27, weight: .bold))
                    .tracking(-0.7)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .foregroundStyle(.white)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.68))
                        .multilineTextAlignment(.center)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button(action: toggleFavorite) {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(isFavorite ? BuFiTheme.accentSoft : .white)
                    .frame(width: 54, height: 54)
                    .background(.white.opacity(0.10), in: Circle())
                    .buFiGlass(cornerRadius: 27, interactive: true)
            }
            .frame(maxWidth: .infinity)
            .buttonStyle(BuFiPressStyle())
            .opacity(canFavorite ? 1 : 0)
            .disabled(!canFavorite)
            .accessibilityLabel(isFavorite ? "좋아요 취소" : "좋아요 표시")

            Button {
                guard !songs.isEmpty else { return }
                let shuffled = songs.shuffled()
                if let first = shuffled.first {
                    audio.play(first, in: shuffled)
                }
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(.white.opacity(0.10), in: Circle())
                    .buFiGlass(cornerRadius: 27, interactive: true)
            }
            .frame(maxWidth: .infinity)
            .buttonStyle(BuFiPressStyle())
            .disabled(songs.isEmpty)
            .accessibilityLabel("셔플 재생")

            Button {
                if let first = songs.first {
                    audio.play(first, in: songs)
                }
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 62, height: 62)
                    .background(BuFiTheme.accent, in: Circle())
            }
            .frame(maxWidth: .infinity)
            .buttonStyle(BuFiPressStyle())
            .disabled(songs.isEmpty)
            .accessibilityLabel("모두 재생")
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private var artistAbout: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("아티스트 소개")
                .font(.system(size: 22, weight: .bold))
            Text(artistBiography)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .lineLimit(6)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .background(
            BuFiTheme.elevated,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(BuFiTheme.separator.opacity(0.35), lineWidth: 0.5)
        }
        .padding(.horizontal, 16)
        .padding(.top, 28)
    }

    private var albumRail: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("앨범")
                .font(.system(size: 23, weight: .bold))
                .padding(.horizontal, 16)
                .padding(.top, 18)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 15) {
                    ForEach(albums) { album in
                        NavigationLink(value: MusicRoute.album(album)) {
                            AlbumCard(album: album, width: 150)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    @ViewBuilder
    private var songList: some View {
        if songs.isEmpty {
            ContentUnavailableView(
                isArtist
                    ? LocalizedStringKey("인기곡이 없습니다")
                    : LocalizedStringKey("수록곡이 없습니다"),
                systemImage: "music.note"
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 34)
        } else {
            LazyVStack(spacing: 0) {
                ForEach(songs) { song in
                    SongRow(
                        song: song,
                        queue: songs,
                        showsArtwork: isArtist,
                        onMore: { selectedSong = song }
                    )
                    .padding(.horizontal, 16)
                }
            }
            .padding(.top, albums.isEmpty ? 6 : 22)
        }
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color(palette.top).opacity(0.92),
                BuFiTheme.background
            ],
            startPoint: .top,
            endPoint: .init(x: 0.5, y: 0.43)
        )
        .ignoresSafeArea()
    }

    private var isArtist: Bool {
        if case .artist = route { return true }
        return false
    }

    private var canFavorite: Bool {
        switch route {
        case .album, .artist: true
        case .playlist: false
        }
    }

    private func toggleFavorite() {
        guard canFavorite else { return }
        isFavorite.toggle()
        switch route {
        case .album(let album):
            Task { await model.toggleStar(album: album) }
        case .artist(let artist):
            Task { await model.toggleStar(artist: artist) }
        case .playlist:
            break
        }
    }

    @MainActor
    private func load() async {
        isLoading = true
        albums = []
        songs = []
        artistImageURL = nil
        artistBiography = ""
        artistAlbumCount = 0
        do {
            switch route {
            case .album(let album):
                isFavorite = album.isStarred
                title = album.name
                subtitle = [
                    String(localized: "앨범"),
                    album.artist,
                    album.year.map(String.init)
                ]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                coverArt = album.coverArt
                let detail = try await model.album(id: album.id)
                songs = detail.songs
            case .playlist(let playlist):
                isFavorite = false
                title = playlist.name
                subtitle = [
                    String(localized: "플레이리스트"),
                    playlist.owner,
                    playlist.songCount.map {
                        String(format: String(localized: "%d곡"), $0)
                    }
                ]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
                coverArt = playlist.coverArt
                let detail = try await model.playlist(id: playlist.id)
                songs = detail.songs
            case .artist(let artist):
                isFavorite = artist.isStarred
                title = artist.name
                subtitle = String(localized: "아티스트")
                coverArt = artist.coverArt
                artistImageURL = artist.artistImageUrl
                artistAlbumCount = artist.albumCount ?? 0
                let detail = try await model.artist(id: artist.id, name: artist.name)
                isFavorite = detail.artist.isStarred
                coverArt = detail.artist.coverArt ?? coverArt
                songs = detail.topSongs
                albums = detail.albums
                artistAlbumCount = detail.artist.albumCount ?? detail.albums.count
                artistImageURL =
                    detail.artist.artistImageUrl
                    ?? detail.info?.largeImageUrl
                    ?? detail.info?.mediumImageUrl
                artistBiography = (detail.info?.biography ?? "")
                    .replacingOccurrences(
                        of: "<[^>]+>",
                        with: " ",
                        options: .regularExpression
                    )
                    .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            model.errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

private struct SongActionsSheet: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var audio: AudioEngine
    @Environment(\.dismiss) private var dismiss

    let song: Song

    var body: some View {
        VStack(spacing: 4) {
            Capsule()
                .fill(.secondary.opacity(0.45))
                .frame(width: 38, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 9)

            HStack(spacing: 12) {
                ArtworkView(coverArt: song.coverArt, size: 54, cornerRadius: 5)
                    .frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 4) {
                    Text(song.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    Text(song.artist).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 7)

            action(song.isStarred ? "좋아요 취소" : "좋아요 표시", icon: song.isStarred ? "heart.slash" : "heart") {
                Task { await model.toggleStar(song: song) }
                dismiss()
            }
            action("오프라인 저장", icon: "arrow.down.circle") {
                Task { await model.download(song) }
                dismiss()
            }
            action("지금 재생", icon: "play.fill") {
                audio.play(song, in: [song])
                dismiss()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func action(_ title: String, icon: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label {
                Text(LocalizedStringKey(title))
            } icon: {
                Image(systemName: icon)
            }
                .font(.system(size: 16, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 44)
                .padding(.horizontal, 18)
        }
        .buttonStyle(.plain)
    }
}
