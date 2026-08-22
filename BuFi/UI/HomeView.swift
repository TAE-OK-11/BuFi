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
    @State private var hasRevealedContent = false

    var body: some View {
        let sections = visibleSections
        let enablesMotion = motionEnabled

        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    BuFiPageHeader(title: "홈")
                        .opacity(hasRevealedContent ? 1 : 0)
                        .offset(y: hasRevealedContent ? 0 : 7)
                        .animation(
                            motionEnabled ? BuFiMotion.homeEntrance : .none,
                            value: hasRevealedContent
                        )
                    filterBar
                        .opacity(hasRevealedContent ? 1 : 0)
                        .offset(y: hasRevealedContent ? 0 : 8)
                        .animation(
                            motionEnabled
                                ? BuFiMotion.homeEntrance.delay(0.035)
                                : .none,
                            value: hasRevealedContent
                        )
                    ForEach(Array(sections.enumerated()), id: \.element) { index, section in
                        homeSection(section)
                            .padding(.top, section == sections.first ? 0 : 6)
                            .opacity(hasRevealedContent ? 1 : 0)
                            .offset(y: hasRevealedContent ? 0 : 9)
                            .scaleEffect(
                                hasRevealedContent ? 1 : 0.996,
                                anchor: .top
                            )
                            .animation(
                                motionEnabled
                                    ? BuFiMotion.homeEntrance.delay(
                                        min(0.055 + (Double(index) * 0.022), 0.17)
                                    )
                                    : .none,
                                value: hasRevealedContent
                            )
                            .scrollTransition(.interactive, axis: .vertical) { content, phase in
                                content
                                    .scaleEffect(
                                        phase.isIdentity || !enablesMotion ? 1 : 0.994,
                                        anchor: .center
                                    )
                                    .opacity(phase.isIdentity || !enablesMotion ? 1 : 0.94)
                                    .offset(y: phase.isIdentity || !enablesMotion ? 0 : 5)
                            }
                            .transition(
                                motionEnabled ? BuFiTransition.section : .opacity
                            )
                    }
                }
                .animation(
                    motionEnabled ? BuFiMotion.content : .none,
                    value: sections
                )
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
        .task {
            guard !hasRevealedContent else { return }
            if motionEnabled {
                await Task.yield()
                guard !Task.isCancelled else { return }
            }
            hasRevealedContent = true
        }
    }

    private var filterBar: some View {
        BuFiFilterBar(
            items: HomeFilter.allCases,
            selection: $filter,
            title: { $0.title }
        )
    }

    private var visibleSections: [HomeSection] {
        let snapshot = library.snapshot
        let mixes = presentation.personalizedMixes
        switch filter {
        case .all:
            return HomeSection.allCases.filter { section in
                switch section {
                case .shortcuts:
                    true
                case .randomAlbums:
                    !snapshot.randomAlbums.isEmpty
                case .starredAlbums:
                    !snapshot.starredAlbums.isEmpty
                case .recommendedAlbums:
                    !presentation.recommendedAlbums.isEmpty
                case .primaryArtists:
                    !presentation.primaryArtists.isEmpty
                case .artistMixes:
                    mixes.contains { $0.kind == .artist }
                case .featuredArtists:
                    !presentation.featuredArtists.isEmpty
                case .recentlyPlayed:
                    !snapshot.recentlyPlayedAlbums.isEmpty
                case .frequentAlbums:
                    !snapshot.frequentAlbums.isEmpty
                case .recentAlbums:
                    !snapshot.recentAlbums.isEmpty
                case .playlists:
                    !snapshot.playlists.isEmpty
                case .radio:
                    !snapshot.radioStations.isEmpty
                case .daylistMixes, .moodMixes:
                    false
                }
            }
        case .playlists:
            return [.playlists]
        case .personalized:
            return [
                mixes.contains {
                    [.daylist, .repeatListening, .listenAgain, .genre].contains($0.kind)
                } ? HomeSection.daylistMixes : nil,
                mixes.contains { $0.kind == .artist } ? .artistMixes : nil,
                mixes.contains { $0.kind == .mood } ? .moodMixes : nil
            ].compactMap { $0 }
        }
    }

    @ViewBuilder
    private func homeSection(_ section: HomeSection) -> some View {
        let snapshot = library.snapshot
        let mixes = presentation.personalizedMixes
        switch section {
        case .shortcuts:
            shortcuts
        case .randomAlbums:
            albumSection("오늘 골라본 앨범", albums: snapshot.randomAlbums)
        case .starredAlbums:
            albumSection("좋아하는 앨범", albums: snapshot.starredAlbums)
        case .recommendedAlbums:
            albumSection("취향을 닮은 앨범", albums: presentation.recommendedAlbums)
        case .primaryArtists:
            artistSection("즐겨 듣는 아티스트", artists: presentation.primaryArtists)
        case .artistMixes:
            personalizedMixSection(
                filter == .personalized ? "아티스트 믹스" : "아티스트에서 이어 듣기",
                mixes: mixes.filter { $0.kind == .artist }
            )
        case .featuredArtists:
            artistSection("놓치면 아쉬운 아티스트", artists: presentation.featuredArtists)
        case .recentlyPlayed:
            albumSection("최근 감상", albums: snapshot.recentlyPlayedAlbums)
        case .frequentAlbums:
            albumSection("다시 찾는 앨범", albums: snapshot.frequentAlbums)
        case .recentAlbums:
            albumSection("새로 만나는 음악", albums: snapshot.recentAlbums)
        case .playlists:
            playlistSection(showEmpty: filter == .playlists)
        case .radio:
            radioSection
        case .daylistMixes:
            personalizedMixSection(
                "오늘의 믹스",
                mixes: mixes.filter {
                    [.daylist, .repeatListening, .listenAgain, .genre].contains($0.kind)
                }
            )
        case .moodMixes:
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
                            .buFiHorizontalScrollMotion()
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
                            .buFiHorizontalScrollMotion()
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
                            .buFiHorizontalScrollMotion()
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
                            .buFiHorizontalScrollMotion()
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
        withAnimation(motionEnabled ? BuFiMotion.homeRefresh : .none) {
            presentation = next
        }
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
        let value = make(input: input)
        return Task.isCancelled ? .empty : value
    }

    static func make(input: HomePresentationInput) -> HomePresentation {
        let snapshot = input.snapshot
        return HomePresentation(
            personalizedMixes: PersonalizedMixBuilder.make(
                snapshot: snapshot,
                snapshotRevision: input.revision,
                selectedArtists: input.selectedArtists
            ),
            favoriteSongsMix: PersonalizedMixBuilder.favoriteSongs(snapshot.starredSongs),
            mostPlayedSongsMix: PersonalizedMixBuilder.mostPlayedSongs(snapshot.mostPlayedSongs),
            recommendedAlbums: makeRecommendedAlbums(snapshot: snapshot),
            primaryArtists: Array(
                (snapshot.starredArtists.isEmpty
                    ? snapshot.artists
                    : snapshot.starredArtists)
                    .prefix(12)
            ),
            featuredArtists: makeFeaturedArtists(snapshot: snapshot)
        )
    }

    private static func makeFeaturedArtists(snapshot: HomeSnapshot) -> [Artist] {
        let maximumCount = 12
        let artistSources = [
            snapshot.recommendedArtists,
            snapshot.starredArtists,
            snapshot.artists
        ]
        let songSources = [
            snapshot.starredSongs,
            snapshot.mostPlayedSongs,
            snapshot.recommendedSongs,
            snapshot.randomSongs
        ]
        let albumSources = [
            snapshot.starredAlbums,
            snapshot.randomAlbums,
            snapshot.recentAlbums
        ]

        var taylor = firstValue(
            named: "taylor swift",
            in: artistSources,
            name: \.name
        )
        if taylor == nil,
           let album = firstValue(
               named: "taylor swift",
               in: albumSources,
               name: \.artist
           ),
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
           let song = firstValue(
               named: "taylor swift",
               in: songSources,
               name: \.artist
           ),
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
            guard values.count < maximumCount, let artist else { return }
            let key = normalizedArtistName(artist.name)
            guard !key.isEmpty, seen.insert(key).inserted else { return }
            values.append(artist)
        }
        append(taylor)
        for source in [
            snapshot.starredArtists,
            snapshot.recommendedArtists,
            snapshot.artists
        ] {
            for artist in source {
                append(artist)
                if values.count == maximumCount { break }
            }
            if values.count == maximumCount { break }
        }
        return values
    }

    private static func firstValue<Value>(
        named normalizedName: String,
        in sources: [[Value]],
        name: KeyPath<Value, String>
    ) -> Value? {
        for source in sources {
            for value in source {
                if Task.isCancelled { return nil }
                if normalizedArtistName(value[keyPath: name]) == normalizedName {
                    return value
                }
            }
        }
        return nil
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

    private let width: CGFloat = 166

    var body: some View {
        card.buFiHorizontalScrollMotion()
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

private enum HomeSection: Hashable, CaseIterable {
    case shortcuts
    case randomAlbums
    case starredAlbums
    case recommendedAlbums
    case primaryArtists
    case artistMixes
    case featuredArtists
    case recentlyPlayed
    case frequentAlbums
    case recentAlbums
    case playlists
    case radio
    case daylistMixes
    case moodMixes
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
