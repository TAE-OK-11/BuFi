import SwiftUI
import UIKit

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: HomeLibraryState
    @Environment(\.buFiMotionEnabled) private var motionEnabled
    @State private var filter = LibraryFilter.playlists
    @State private var artistPresentation = LibraryArtistPresentation.empty
    @State private var artistPresentationInput: LibraryArtistPresentationInput?
    @State private var artistPresentationGeneration: UInt64 = 0
    @State private var artistPresentationTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    BuFiPageHeader(title: "내 라이브러리")
                    filters
                    content
                        .transition(.opacity)
                }
                .padding(.top, 18)
                .buFiMiniPlayerContentClearance(idle: 56, playing: 154)
                .animation(motionEnabled ? BuFiMotion.content : .none, value: filter)
            }
            .background(BuFiScreenBackground())
            .refreshable { await model.refresh() }
            .navigationDestination(for: MusicRoute.self) { route in
                MusicDetailView(route: route)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .onAppear { updateArtistPresentationIfNeeded() }
        .onChange(of: library.revision) { _, _ in
            updateArtistPresentationIfNeeded()
        }
        .onDisappear {
            if artistPresentationTask != nil {
                artistPresentationInput = nil
            }
            artistPresentationTask?.cancel()
            artistPresentationTask = nil
        }
    }

    private var filters: some View {
        BuFiFilterBar(
            items: LibraryFilter.allCases,
            selection: $filter,
            title: { $0.title }
        )
    }

    @ViewBuilder
    private var content: some View {
        switch filter {
        case .playlists:
            if library.snapshot.playlists.isEmpty {
                empty("플레이리스트가 없습니다", icon: "music.note.list")
            } else {
                groupedLibraryRows(library.snapshot.playlists) { playlist in
                    NavigationLink(value: MusicRoute.playlist(playlist)) {
                        libraryRow(
                            title: playlist.name,
                            subtitle: String(
                                format: String(localized: "플레이리스트 · %d곡"),
                                playlist.songCount ?? 0
                            ),
                            cover: playlist.coverArt,
                            placeholderIcon: "music.note.list"
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        case .albums:
            if library.snapshot.starredAlbums.isEmpty {
                empty("저장한 앨범이 없습니다", icon: "square.stack")
            } else {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 14, alignment: .top),
                        GridItem(.flexible(), spacing: 14, alignment: .top)
                    ],
                    alignment: .leading,
                    spacing: 24
                ) {
                    ForEach(library.snapshot.starredAlbums) { album in
                        NavigationLink(value: MusicRoute.album(album)) {
                            AlbumCard(
                                album: album,
                                width: libraryAlbumWidth,
                                usesHorizontalScrollTransition: false
                            )
                            .frame(maxHeight: .infinity, alignment: .topLeading)
                        }
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                        .buttonStyle(BuFiPressStyle())
                    }
                }
                .padding(.horizontal, 16)
            }
        case .artists:
            artistsContent
        case .songs:
            if library.snapshot.starredSongs.isEmpty {
                empty("좋아요 표시한 곡이 없습니다", icon: "heart")
            } else {
                BuFiGroupedSurface {
                    LazyVStack(spacing: 0) {
                        ForEach(library.snapshot.starredSongs.indices, id: \.self) { index in
                            let song = library.snapshot.starredSongs[index]
                            SongRow(
                                song: song,
                                queue: library.snapshot.starredSongs,
                                queueIndex: index
                            )
                                .padding(.horizontal, 14)
                            if index < library.snapshot.starredSongs.count - 1 {
                                rowSeparator
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    @ViewBuilder
    private var artistsContent: some View {
        if artistPresentation.allArtists.isEmpty {
            empty("아티스트가 없습니다", icon: "person.2")
        } else {
            if !artistPresentation.favorites.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    librarySectionTitle("좋아하는 아티스트")
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 16) {
                            ForEach(artistPresentation.favorites) { artist in
                                favoriteArtistCard(artist)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }

            LazyVStack(alignment: .leading, spacing: 12) {
                librarySectionTitle("모든 아티스트")
                ForEach(artistPresentation.sections) { section in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.title)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(BuFiTheme.accentSoft)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)

                        BuFiGroupedSurface {
                            LazyVStack(spacing: 0) {
                                ForEach(section.artists) { artist in
                                    artistRow(artist)
                                    if artist.id != section.artists.last?.id {
                                        rowSeparator
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
        }
    }

    private func favoriteArtistCard(_ artist: Artist) -> some View {
        ZStack(alignment: .topTrailing) {
            NavigationLink(value: MusicRoute.artist(artist)) {
                VStack(spacing: 9) {
                    ArtworkView(
                        coverArt: artist.coverArt,
                        size: 92,
                        cornerRadius: 46
                    )
                    .frame(width: 92, height: 92)
                    Text(artist.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 108)
            }
            .buttonStyle(BuFiPressStyle())

            Button {
                Task { await model.toggleStar(artist: artist) }
            } label: {
                Image(systemName: "heart.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(BuFiTheme.accent, in: Circle())
            }
            .buttonStyle(BuFiPressStyle())
            .accessibilityLabel("좋아요 취소")
        }
        .frame(width: 108, alignment: .top)
    }

    private func artistRow(_ artist: Artist) -> some View {
        HStack(spacing: 8) {
            NavigationLink(value: MusicRoute.artist(artist)) {
                HStack(spacing: 12) {
                    ArtworkView(
                        coverArt: artist.coverArt,
                        size: 56,
                        cornerRadius: 28
                    )
                    .frame(width: 56, height: 56)
                    Text(artist.name)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                Task { await model.toggleStar(artist: artist) }
            } label: {
                Image(systemName: "heart")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(BuFiPressStyle())
            .accessibilityLabel("좋아요 표시")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var libraryAlbumWidth: CGFloat {
        max(132, (UIScreen.main.bounds.width - 46) / 2)
    }

    private func librarySectionTitle(_ title: String) -> some View {
        Text(LocalizedStringKey(title))
            .font(.system(size: 21, weight: .bold))
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .padding(.bottom, 8)
    }

    private func libraryRow(
        title: String,
        subtitle: String,
        cover: String?,
        placeholderIcon: String
    ) -> some View {
        let artworkSize: CGFloat = 64
        return HStack(spacing: 12) {
            libraryArtwork(
                cover: cover,
                size: artworkSize,
                placeholderIcon: placeholderIcon
            )
            .frame(width: artworkSize, height: artworkSize)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func groupedLibraryRows<Item: Identifiable, Row: View>(
        _ items: [Item],
        @ViewBuilder row: @escaping (Item) -> Row
    ) -> some View {
        BuFiGroupedSurface {
            VStack(spacing: 0) {
                ForEach(items) { item in
                    row(item)
                    if item.id != items.last?.id {
                        rowSeparator
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var rowSeparator: some View {
        Divider()
            .padding(.leading, 92)
            .opacity(0.52)
    }

    @ViewBuilder
    private func libraryArtwork(
        cover: String?,
        size: CGFloat,
        placeholderIcon: String
    ) -> some View {
        if let cover, !cover.isEmpty {
            ArtworkView(
                coverArt: cover,
                size: size,
                cornerRadius: 12
            )
        } else {
            ZStack {
                Color.secondary.opacity(0.12)
                Image(systemName: placeholderIcon)
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(BuFiTheme.accentSoft)
            }
            .clipShape(
                RoundedRectangle(
                    cornerRadius: 12,
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

    private func updateArtistPresentationIfNeeded() {
        let input = LibraryArtistPresentationInput(
            artists: library.snapshot.artists,
            starredArtists: library.snapshot.starredArtists
        )
        guard input != artistPresentationInput else { return }
        artistPresentationInput = input
        artistPresentationGeneration &+= 1
        let generation = artistPresentationGeneration
        artistPresentationTask?.cancel()
        artistPresentationTask = Task {
            let work = Task.detached(priority: .userInitiated) {
                LibraryArtistPresentation.make(input: input)
            }
            let next = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled,
                  generation == artistPresentationGeneration,
                  input == artistPresentationInput else { return }
            artistPresentation = next
            artistPresentationTask = nil
        }
    }
}

struct LibraryArtistPresentationInput: Equatable, Sendable {
    let artists: [Artist]
    let starredArtists: [Artist]
}

struct LibraryArtistPresentation: Sendable {
    let allArtists: [Artist]
    let favorites: [Artist]
    let sections: [ArtistSection]

    static let empty = LibraryArtistPresentation(
        allArtists: [],
        favorites: [],
        sections: []
    )

    static func make(input: LibraryArtistPresentationInput) -> LibraryArtistPresentation {
        var values: [String: Artist] = [:]
        for artist in input.artists { values[artist.id] = artist }
        for artist in input.starredArtists {
            var starred = artist
            if starred.starred == nil {
                starred.starred = "starred"
            }
            values[artist.id] = starred
        }
        let artists = values.values.sorted(by: artistSort)
        let favorites = artists.filter(\.isStarred).sorted(by: artistSort)
        let favoriteIDs = Set(favorites.map(\.id))
        let sections = makeArtistSections(
            artists.filter { !favoriteIDs.contains($0.id) }
        )
        return LibraryArtistPresentation(
            allArtists: artists,
            favorites: favorites,
            sections: sections
        )
    }

    private static func makeArtistSections(_ artists: [Artist]) -> [ArtistSection] {
        let grouped = Dictionary(grouping: artists) {
            ArtistSectioning.title(for: $0.name)
        }
        return grouped.keys.sorted(by: ArtistSectioning.sectionSort).map {
            ArtistSection(title: $0, artists: grouped[$0, default: []].sorted(by: artistSort))
        }
    }

    private static func artistSort(_ lhs: Artist, _ rhs: Artist) -> Bool {
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

struct ArtistSection: Identifiable, Sendable {
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
