import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var audio: AudioEngine
    @State private var filter = LibraryFilter.playlists

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                    filters
                    content
                }
                .padding(.top, 18)
                .padding(.bottom, audio.currentSong == nil ? 56 : 154)
            }
            .background(BuFiScreenBackground())
            .refreshable { await model.refresh() }
            .navigationDestination(for: MusicRoute.self) { route in
                MusicDetailView(route: route)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var filters: some View {
        BuFiFilterBar(
            items: LibraryFilter.allCases,
            selection: $filter,
            fontSize: 13,
            title: { $0.title }
        )
    }

    @ViewBuilder
    private var content: some View {
        switch filter {
        case .playlists:
            if model.home.playlists.isEmpty {
                empty("플레이리스트가 없습니다", icon: "music.note.list")
            } else {
                ForEach(model.home.playlists) { playlist in
                    NavigationLink(value: MusicRoute.playlist(playlist)) {
                        libraryRow(
                            title: playlist.name,
                            subtitle: String(
                                format: String(localized: "플레이리스트 · %d곡"),
                                playlist.songCount ?? 0
                            ),
                            cover: playlist.coverArt,
                            circle: false,
                            placeholderIcon: "music.note.list"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        case .albums:
            if model.home.starredAlbums.isEmpty {
                empty("저장한 앨범이 없습니다", icon: "square.stack")
            } else {
                ForEach(model.home.starredAlbums) { album in
                    NavigationLink(value: MusicRoute.album(album)) {
                        libraryRow(
                            title: album.name,
                            subtitle: String(
                                format: String(localized: "앨범 · %@"),
                                album.artist
                            ),
                            cover: album.coverArt,
                            circle: false,
                            placeholderIcon: "square.stack.fill"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        case .artists:
            artistsContent
        case .songs:
            if model.home.starredSongs.isEmpty {
                empty("좋아요 표시한 곡이 없습니다", icon: "heart")
            } else {
                ForEach(model.home.starredSongs) { song in
                    SongRow(song: song, queue: model.home.starredSongs)
                }
                .padding(.horizontal, 17)
            }
        }
    }

    @ViewBuilder
    private var artistsContent: some View {
        if allArtists.isEmpty {
            empty("아티스트가 없습니다", icon: "person.2")
        } else {
            if !favoriteArtists.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    librarySectionTitle("좋아요 표시한 아티스트", icon: "heart.fill")
                    ForEach(favoriteArtists) { artist in
                        artistRow(artist, favorite: true)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                librarySectionTitle("모든 아티스트", icon: "textformat")
                ForEach(artistSections) { section in
                    Section {
                        ForEach(section.artists) { artist in
                            artistRow(artist, favorite: false)
                        }
                    } header: {
                        Text(section.title)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(BuFiTheme.accentSoft)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 17)
                            .padding(.vertical, 7)
                            .background(BuFiTheme.background.opacity(0.94))
                    }
                }
            }
        }
    }

    private func artistRow(_ artist: Artist, favorite: Bool) -> some View {
        HStack(spacing: 8) {
            NavigationLink(value: MusicRoute.artist(artist)) {
                HStack(spacing: 13) {
                    ArtworkView(coverArt: artist.coverArt, size: 66, cornerRadius: 33)
                        .frame(width: 66, height: 66)
                    Text(artist.name)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                Task { await model.toggleStar(artist: artist) }
            } label: {
                Image(systemName: favorite ? "heart.fill" : "heart")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(
                        favorite ? BuFiTheme.accent : Color.secondary
                    )
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(BuFiPressStyle())
            .accessibilityLabel(favorite ? "좋아요 취소" : "좋아요 표시")
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 4)
    }

    private func librarySectionTitle(_ title: String, icon: String) -> some View {
        Label {
            Text(LocalizedStringKey(title))
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(BuFiTheme.accent)
        }
        .font(.system(size: 21, weight: .bold))
        .padding(.horizontal, 17)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private func libraryRow(
        title: String,
        subtitle: String,
        cover: String?,
        circle: Bool,
        placeholderIcon: String
    ) -> some View {
        HStack(spacing: 13) {
            libraryArtwork(
                cover: cover,
                circle: circle,
                placeholderIcon: placeholderIcon
            )
            .frame(width: 66, height: 66)
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
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func libraryArtwork(
        cover: String?,
        circle: Bool,
        placeholderIcon: String
    ) -> some View {
        if let cover, !cover.isEmpty {
            ArtworkView(
                coverArt: cover,
                size: 66,
                cornerRadius: circle ? 33 : 11
            )
        } else {
            ZStack {
                LinearGradient(
                    colors: [
                        BuFiTheme.accent.opacity(0.74),
                        BuFiTheme.deezerGlow.opacity(0.76),
                        Color.black.opacity(0.72)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: placeholderIcon)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .clipShape(
                RoundedRectangle(
                    cornerRadius: circle ? 33 : 11,
                    style: .continuous
                )
            )
        }
    }

    private func empty(_ title: String, icon: String) -> some View {
        ContentUnavailableView(LocalizedStringKey(title), systemImage: icon)
            .frame(maxWidth: .infinity)
            .padding(.top, 70)
    }

    private var allArtists: [Artist] {
        var values: [String: Artist] = [:]
        for artist in model.home.artists { values[artist.id] = artist }
        for artist in model.home.starredArtists {
            var starred = artist
            if starred.starred == nil {
                starred.starred = ISO8601DateFormatter().string(from: Date())
            }
            values[artist.id] = starred
        }
        return values.values.sorted(by: artistSort)
    }

    private var favoriteArtists: [Artist] {
        allArtists.filter(\.isStarred).sorted(by: artistSort)
    }

    private var artistSections: [ArtistSection] {
        let favoriteIDs = Set(favoriteArtists.map(\.id))
        let grouped = Dictionary(grouping: allArtists.filter { !favoriteIDs.contains($0.id) }) {
            ArtistSectioning.title(for: $0.name)
        }
        return grouped.keys.sorted(by: ArtistSectioning.sectionSort).map {
            ArtistSection(title: $0, artists: grouped[$0, default: []].sorted(by: artistSort))
        }
    }

    private func artistSort(_ lhs: Artist, _ rhs: Artist) -> Bool {
        lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

private enum LibraryFilter: Int, CaseIterable, Identifiable {
    case playlists
    case albums
    case artists
    case songs

    var id: Int { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .playlists: "플레이리스트"
        case .albums: "앨범"
        case .artists: "아티스트"
        case .songs: "곡"
        }
    }

}

private struct ArtistSection: Identifiable {
    let title: String
    let artists: [Artist]
    var id: String { title }
}

private enum ArtistSectioning {
    private static let koreanInitials = [
        "ㄱ", "ㄱ", "ㄴ", "ㄷ", "ㄷ", "ㄹ", "ㅁ", "ㅂ", "ㅂ",
        "ㅅ", "ㅅ", "ㅇ", "ㅈ", "ㅈ", "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"
    ]
    private static let koreanSectionOrder = [
        "ㄱ", "ㄴ", "ㄷ", "ㄹ", "ㅁ", "ㅂ", "ㅅ", "ㅇ", "ㅈ",
        "ㅊ", "ㅋ", "ㅌ", "ㅍ", "ㅎ"
    ]

    static func title(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scalar = trimmed.unicodeScalars.first else { return "#" }
        let value = scalar.value
        if (0xAC00...0xD7A3).contains(value) {
            return koreanInitials[Int((value - 0xAC00) / 588)]
        }
        let folded = trimmed.folding(
            options: [.diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        guard let first = folded.first else { return "#" }
        let upper = String(first).uppercased()
        if upper.range(of: "^[A-Z]$", options: .regularExpression) != nil {
            return upper
        }
        return String(first)
    }

    static func sectionSort(_ lhs: String, _ rhs: String) -> Bool {
        let leftRank = rank(lhs)
        let rightRank = rank(rhs)
        if leftRank != rightRank { return leftRank < rightRank }
        return lhs.localizedStandardCompare(rhs) == .orderedAscending
    }

    private static func rank(_ section: String) -> Int {
        if let scalar = section.unicodeScalars.first,
           scalar.value >= 65,
           scalar.value <= 90 {
            return Int(scalar.value - 65)
        }
        if let index = koreanSectionOrder.firstIndex(of: section) {
            return 100 + index
        }
        return section == "#" ? 1_000 : 500
    }
}
