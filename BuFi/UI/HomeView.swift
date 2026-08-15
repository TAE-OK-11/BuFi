import SwiftUI

enum MusicRoute: Hashable, Sendable {
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
    @State private var presentation = HomePresentation.empty
    @State private var hasLoadedPresentation = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    BuFiPageHeader(title: "홈")
                    filterBar
                    filteredContent
                }
                .padding(.top, 18)
                .buFiMiniPlayerContentClearance()
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
        .task(id: presentationTaskIdentity) {
            await updatePresentation()
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
                    mixes: presentation.personalizedMixes
                )
            case .playlists:
                playlistSection(showEmpty: true)
            case .personalized:
                personalizedContent(
                    presentation.personalizedMixes
                )
            }
        }
        .transition(.opacity)
        .animation(motionEnabled ? BuFiMotion.content : .none, value: filter)
    }

    private func allContent(mixes: [PersonalizedMix]) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            shortcuts
            albumSection("오늘 골라본 앨범", albums: library.snapshot.randomAlbums)
            albumSection("좋아하는 앨범", albums: library.snapshot.starredAlbums)
            albumSection("취향을 닮은 앨범", albums: presentation.recommendedAlbums)
            artistSection("즐겨 듣는 아티스트", artists: presentation.primaryArtists)
            personalizedMixSection(
                "아티스트에서 이어 듣기",
                mixes: mixes.filter { $0.kind == .artist }
            )
            artistSection(
                "놓치면 아쉬운 아티스트",
                artists: presentation.featuredArtists
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
                value: presentation.favoriteSongsMix
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
                value: presentation.mostPlayedSongsMix
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
                                HomeAlbumCard(album: album)
                            }
                            .buttonStyle(BuFiPressStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    private var presentationTaskIdentity: HomePresentationTaskIdentity {
        HomePresentationTaskIdentity(
            revision: library.revision,
            selectedArtists: selectedArtistMixes
        )
    }

    @MainActor
    private func updatePresentation() async {
        let revision = library.revision
        let snapshot = library.snapshot
        let selectedArtistsStorage = selectedArtistMixes
        guard revision == library.revision else { return }

        let input = HomePresentationInput(
            snapshot: snapshot,
            revision: revision,
            selectedArtists: ArtistMixPreferences.decode(selectedArtistsStorage)
        )

        if hasLoadedPresentation {
            do {
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                return
            }
            guard revision == library.revision,
                  selectedArtistsStorage == selectedArtistMixes else { return }
        }

        let next = await HomePresentation.makeConcurrently(input: input)
        guard !Task.isCancelled,
              revision == library.revision,
              selectedArtistsStorage == selectedArtistMixes else { return }
        presentation = next
        hasLoadedPresentation = true
    }

    private func countText(_ count: Int) -> String {
        String(format: String(localized: "%d곡"), count)
    }
}

private struct HomePresentationTaskIdentity: Hashable, Sendable {
    let revision: HomeSnapshotRevision
    let selectedArtists: String
}

struct HomePresentationInput: Equatable, Sendable {
    let snapshot: HomeSnapshot
    let revision: HomeSnapshotRevision
    let selectedArtists: [String]

    init(
        snapshot: HomeSnapshot,
        revision: HomeSnapshotRevision = HomeSnapshotRevision(),
        selectedArtists: [String]
    ) {
        self.snapshot = snapshot
        self.revision = revision
        self.selectedArtists = selectedArtists
    }

    static func == (lhs: HomePresentationInput, rhs: HomePresentationInput) -> Bool {
        lhs.revision == rhs.revision
            && lhs.selectedArtists == rhs.selectedArtists
    }
}

struct HomePresentation: Sendable {
    let personalizedMixes: [PersonalizedMix]
    let favoriteSongsMix: PersonalizedMix
    let mostPlayedSongsMix: PersonalizedMix
    let recommendedAlbums: [Album]
    let primaryArtists: [Artist]
    let featuredArtists: [Artist]

    static let empty = HomePresentation(
        personalizedMixes: [],
        favoriteSongsMix: PersonalizedMixBuilder.favoriteSongs([]),
        mostPlayedSongsMix: PersonalizedMixBuilder.mostPlayedSongs([]),
        recommendedAlbums: [],
        primaryArtists: [],
        featuredArtists: []
    )

    @concurrent
    static func makeConcurrently(
        input: HomePresentationInput
    ) async -> HomePresentation {
        guard !Task.isCancelled else { return .empty }
        let lyricIndex = await LyricIntelligence.shared.index()
        let recent = await ListeningHistoryStore.shared.recommendationSnapshot()
            .recentSongs
        guard !Task.isCancelled else { return .empty }
        let value = make(input: input, lyricIndex: lyricIndex)
        let mixes = await PersonalizedMixLLM.apply(
            to: value.personalizedMixes,
            snapshot: input.snapshot,
            recent: recent,
            lyricIndex: lyricIndex
        )
        guard !Task.isCancelled else { return .empty }
        return HomePresentation(
            personalizedMixes: mixes,
            favoriteSongsMix: value.favoriteSongsMix,
            mostPlayedSongsMix: value.mostPlayedSongsMix,
            recommendedAlbums: value.recommendedAlbums,
            primaryArtists: value.primaryArtists,
            featuredArtists: value.featuredArtists
        )
    }

    static func make(
        input: HomePresentationInput,
        lyricIndex: LyricSignatureIndex = .empty
    ) -> HomePresentation {
        let snapshot = input.snapshot
        return HomePresentation(
            personalizedMixes: PersonalizedMixBuilder.make(
                snapshot: snapshot,
                snapshotRevision: input.revision,
                selectedArtists: input.selectedArtists,
                lyricIndex: lyricIndex
            ),
            favoriteSongsMix: PersonalizedMixBuilder.favoriteSongs(snapshot.starredSongs),
            mostPlayedSongsMix: PersonalizedMixBuilder.mostPlayedSongs(snapshot.mostPlayedSongs),
            recommendedAlbums: makeRecommendedAlbums(snapshot: snapshot),
            primaryArtists: snapshot.starredArtists.isEmpty
                ? Array(snapshot.artists.prefix(12))
                : snapshot.starredArtists,
            featuredArtists: makeFeaturedArtists(snapshot: snapshot)
        )
    }

    private static func makeFeaturedArtists(snapshot: HomeSnapshot) -> [Artist] {
        let songSources = snapshot.starredSongs + snapshot.mostPlayedSongs
            + snapshot.recommendedSongs + snapshot.randomSongs
        let artistSources = snapshot.recommendedArtists + snapshot.starredArtists
            + snapshot.artists

        var taylor = artistSources.first {
            normalizedArtistName($0.name) == "taylor swift"
        }
        if taylor == nil,
           let album = (snapshot.starredAlbums + snapshot.randomAlbums + snapshot.recentAlbums)
            .first(where: { normalizedArtistName($0.artist) == "taylor swift" }),
           let artistID = album.artistId,
           !artistID.isEmpty {
            taylor = Artist(
                id: artistID,
                name: "Taylor Swift",
                coverArt: nil,
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
                coverArt: nil,
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
        snapshot.starredArtists.forEach { append($0) }
        snapshot.recommendedArtists.forEach { append($0) }
        snapshot.artists.forEach { append($0) }
        return Array(values.prefix(12))
    }

    private static func normalizedArtistName(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func makeRecommendedAlbums(snapshot: HomeSnapshot) -> [Album] {
        let sourceAlbums = snapshot.randomAlbums + snapshot.recentAlbums
            + snapshot.frequentAlbums + snapshot.recentlyPlayedAlbums
            + snapshot.starredAlbums
        var albumsByID: [String: Album] = [:]
        for album in sourceAlbums where albumsByID[album.id] == nil {
            albumsByID[album.id] = album
        }

        var result: [Album] = []
        var seen = Set<String>()
        for song in snapshot.recommendedSongs {
            guard let albumID = song.albumId,
                  !albumID.isEmpty,
                  seen.insert(albumID).inserted else { continue }
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
}

private struct HomeAlbumCard: View {
    let album: Album

    @Environment(\.buFiMotionEnabled) private var motionEnabled
    private let width: CGFloat = 166

    @ViewBuilder
    var body: some View {
        if motionEnabled {
            card
                .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                    content
                        .scaleEffect(phase.isIdentity ? 1 : 0.985)
                        .opacity(phase.isIdentity ? 1 : 0.94)
                }
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArtworkView(
                coverArt: album.coverArt,
                size: width,
                cornerRadius: 14
            )
            .frame(width: width, height: width)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.6)
            }

            Text(album.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Text(album.artist)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .accessibilityElement(children: .combine)
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
