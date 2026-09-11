import SwiftUI
import UIKit

struct SearchView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: HomeLibraryState
    @EnvironmentObject private var searchContent: SearchContentState
    @Environment(\.buFiMotionEnabled) private var motionEnabled
    @AppStorage(ArtistMixPreferences.storageKey)
    private var selectedArtistMixes = "[]"

    @State private var query = ""
    @State private var browseMode = SearchBrowseMode.main
    @State private var personalizedMixes: [PersonalizedMix] = []
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        BuFiPageHeader(title: "검색")
                            .id(SearchScrollAnchor.top)
                            .onTapGesture(perform: resignSearchField)
                            .buFiEntranceMotion()
                        searchField
                            .buFiEntranceMotion(delay: 0.035)
                        content
                            .frame(maxWidth: .infinity, alignment: .top)
                            .contentShape(Rectangle())
                            .onTapGesture(perform: resignSearchField)
                    }
                    .padding(.top, 18)
                    .buFiMiniPlayerContentClearance()
                }
                .scrollDismissesKeyboard(.immediately)
                .onChange(of: browseMode) { _, _ in
                    resignSearchField()
                    withAnimation(motionEnabled ? BuFiMotion.content : .none) {
                        scrollProxy.scrollTo(SearchScrollAnchor.top, anchor: .top)
                    }
                }
            }
            .background(BuFiScreenBackground())
            .navigationDestination(for: MusicRoute.self) { route in
                MusicDetailView(route: route)
            }
            .navigationDestination(for: PersonalizedMix.self) { mix in
                PersonalizedMixDetailView(mix: mix)
            }
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: query) { _, value in
                if !normalizedQuery(value).isEmpty {
                    browseMode = .main
                }
                model.search(value)
            }
            .onChange(of: isSearchFieldFocused) { _, focused in
                if !focused {
                    resignFirstResponder()
                }
            }
            .task(id: personalizedMixTaskIdentity) {
                await updatePersonalizedMixesIfNeeded()
            }
        }
    }

    private var isSearchSession: Bool {
        !normalizedQuery(query).isEmpty
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isSearchFieldFocused ? BuFiTheme.accentSoft : .secondary)
            TextField(
                "",
                text: $query,
                prompt: Text("어떤 것을 듣고 싶으세요?")
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
            )
            .focused($isSearchFieldFocused)
            .font(.system(size: 16, weight: .regular))
            .textFieldStyle(.plain)
            .frame(maxWidth: .infinity)
            .layoutPriority(1)
            .foregroundStyle(.primary)
            .submitLabel(.search)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .onSubmit {
                Task { await model.searchImmediately(query) }
            }
            if !query.isEmpty {
                Button(action: exitSearchSession) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(BuFiPressStyle())
                .transition(.opacity)
                .accessibilityLabel("검색 닫기")
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 14)
        .frame(minHeight: 50, maxHeight: 52)
        .buFiGlass(cornerRadius: 16, interactive: true)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    isSearchFieldFocused
                        ? BuFiTheme.accent.opacity(0.48)
                        : BuFiTheme.separator.opacity(0.34),
                    lineWidth: isSearchFieldFocused ? 1.0 : 0.5
                )
        }
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .onTapGesture {
            isSearchFieldFocused = true
        }
        .animation(motionEnabled ? BuFiMotion.fade : .none, value: isSearchFieldFocused)
        .animation(motionEnabled ? BuFiMotion.symbol : .none, value: query.isEmpty)
    }

    @ViewBuilder
    private var content: some View {
        let surfaces = visibleSurfaces
        ForEach(Array(surfaces.enumerated()), id: \.element) { index, surface in
            searchSurface(surface)
                .frame(maxWidth: .infinity, alignment: .top)
                .buFiVerticalSectionMotion(
                    delay: min(Double(index) * 0.022, 0.08)
                )
                .transition(motionEnabled ? BuFiTransition.section : .opacity)
                .simultaneousGesture(
                    TapGesture().onEnded(resignSearchField)
                )
        }
        .animation(
            motionEnabled ? BuFiMotion.content : .none,
            value: surfaces
        )
    }

    private var visibleSurfaces: [SearchSurface] {
        if isSearchSession {
            let result = searchContent.results
            if result.isEmpty && searchContent.isSearching {
                return [.resultLoading]
            }
            if result.isEmpty {
                return [.resultEmpty]
            }
            var surfaces: [SearchSurface] = []
            if searchContent.isSearching {
                surfaces.append(.resultProgress)
            } else if searchContent.isLocalFallback {
                surfaces.append(.resultLocalFallback)
            }
            if !result.artists.isEmpty { surfaces.append(.resultArtists) }
            if !result.albums.isEmpty { surfaces.append(.resultAlbums) }
            if !result.songs.isEmpty { surfaces.append(.resultSongs) }
            return surfaces
        }

        switch browseMode {
        case .main:
            return library.snapshot.recommendedArtists.isEmpty
                ? [.browseShortcuts]
                : [.browseShortcuts, .browseRecommendedArtists]
        case .favoriteSongs:
            return [.browseFavoriteSongsHeader, .browseFavoriteSongs]
        case .favoriteAlbums:
            return [.browseFavoriteAlbumsHeader, .browseFavoriteAlbums]
        case .algorithmPlaylists:
            return [.browseMixesHeader, .browseMixes]
        case .mostPlayed:
            return [.browseMostPlayedHeader, .browseMostPlayed]
        }
    }

    @ViewBuilder
    private func searchSurface(_ surface: SearchSurface) -> some View {
        let snapshot = library.snapshot
        let result = searchContent.results
        switch surface {
        case .browseShortcuts:
            browseShortcuts
        case .browseRecommendedArtists:
            recommendedArtistsRail(snapshot.recommendedArtists)
        case .browseFavoriteSongsHeader:
            browseCollectionHeader("좋아요 곡")
        case .browseFavoriteSongs:
            starredSongList(snapshot.starredSongs)
        case .browseFavoriteAlbumsHeader:
            browseCollectionHeader("좋아요 앨범")
        case .browseFavoriteAlbums:
            starredAlbumGrid(snapshot.starredAlbums)
        case .browseMixesHeader:
            browseCollectionHeader("맞춤 믹스")
        case .browseMixes:
            algorithmPlaylistGrid(personalizedMixes)
        case .browseMostPlayedHeader:
            browseCollectionHeader("자주 들은 곡")
        case .browseMostPlayed:
            rankedSongs
        case .resultLoading:
            HStack {
                Spacer()
                ProgressView("검색 중…")
                Spacer()
            }
            .padding(.top, 48)
        case .resultEmpty:
            ContentUnavailableView.search(text: query)
                .padding(.top, 42)
        case .resultProgress:
            HStack(spacing: 8) {
                ProgressView()
                Text("검색 중…")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
        case .resultLocalFallback:
            Text("라이브러리에서 찾은 결과")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
        case .resultArtists:
            resultSection("아티스트") {
                ForEach(result.artists) { artist in
                    NavigationLink(value: MusicRoute.artist(artist)) {
                        artistResultRow(artist)
                    }
                    .buttonStyle(BuFiPressStyle())
                    .simultaneousGesture(TapGesture().onEnded(resignSearchField))
                    if artist.id != result.artists.last?.id {
                        rowSeparator
                    }
                }
            }
            .padding(.horizontal, 16)
        case .resultAlbums:
            resultSection("앨범") {
                ForEach(result.albums) { album in
                    NavigationLink(value: MusicRoute.album(album)) {
                        albumResultRow(album)
                    }
                    .buttonStyle(BuFiPressStyle())
                    .simultaneousGesture(TapGesture().onEnded(resignSearchField))
                    if album.id != result.albums.last?.id {
                        rowSeparator
                    }
                }
            }
            .padding(.horizontal, 16)
        case .resultSongs:
            resultSection("곡") {
                ForEach(IndexedSongRow.makeRows(from: result.songs)) { row in
                    SongRow(
                        song: row.song,
                        queue: result.songs,
                        queueIndex: row.index,
                        playbackOrigin: .search,
                        artworkSize: Self.resultArtworkSize,
                        textLineLimit: 2
                    )
                    .padding(.horizontal, 14)
                    .simultaneousGesture(TapGesture().onEnded(resignSearchField))
                    if row.index < result.songs.count - 1 {
                        rowSeparator
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func artistResultRow(_ artist: Artist) -> some View {
        HStack(spacing: 12) {
            ArtworkView(
                coverArt: artist.coverArt,
                size: Self.resultArtworkSize,
                cornerRadius: Self.resultArtworkSize / 2
            )
            .frame(width: Self.resultArtworkSize, height: Self.resultArtworkSize)
            Text(artist.name)
                .font(.system(size: 16, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private func albumResultRow(_ album: Album) -> some View {
        HStack(spacing: 12) {
            ArtworkView(
                coverArt: album.coverArt,
                size: Self.resultArtworkSize,
                cornerRadius: max(5, Self.resultArtworkSize * 0.11)
            )
            .frame(width: Self.resultArtworkSize, height: Self.resultArtworkSize)
            VStack(alignment: .leading, spacing: 3) {
                Text(album.name)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("앨범 · \(album.artist)")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    private var browseShortcuts: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ],
            spacing: 8
        ) {
            ForEach(browseQuickItems) { item in
                Button {
                    resignSearchField()
                    browseMode = item.mode
                } label: {
                    HomeQuickAccessCard(title: item.title, leading: item.leading)
                }
                .buttonStyle(BuFiPressStyle())
            }
        }
        .padding(.horizontal, 16)
    }

    private var browseQuickItems: [SearchBrowseQuickItem] {
        let snapshot = library.snapshot
        return [
            SearchBrowseQuickItem(
                mode: .favoriteSongs,
                title: "좋아요 곡",
                leading: .heartGradient
            ),
            SearchBrowseQuickItem(
                mode: .favoriteAlbums,
                title: "좋아요 앨범",
                leading: snapshot.starredAlbums.first.map {
                    HomeQuickAccessLeading.coverArt($0.coverArt)
                } ?? .albumStackGradient
            ),
            SearchBrowseQuickItem(
                mode: .algorithmPlaylists,
                title: "맞춤 믹스",
                leading: snapshot.starredAlbums.dropFirst().first.map {
                    HomeQuickAccessLeading.coverArt($0.coverArt)
                } ?? snapshot.frequentAlbums.first.map {
                    HomeQuickAccessLeading.coverArt($0.coverArt)
                } ?? .mixSparklesGradient
            ),
            SearchBrowseQuickItem(
                mode: .mostPlayed,
                title: "자주 들은 곡",
                leading: snapshot.mostPlayedSongs.first?.artworkID.map {
                    HomeQuickAccessLeading.coverArt($0)
                } ?? .chartGradient
            )
        ]
    }

    private func recommendedArtistsRail(_ artists: [Artist]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: "추천 아티스트")
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(artists.prefix(12)) { artist in
                        NavigationLink(value: MusicRoute.artist(artist)) {
                            VStack(spacing: 8) {
                                ArtworkView(
                                    coverArt: artist.coverArt,
                                    size: 118,
                                    cornerRadius: 59
                                )
                                .frame(width: 118, height: 118)
                                Text(artist.name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(width: 118)
                        }
                        .buttonStyle(BuFiPressStyle())
                        .buFiHorizontalScrollMotion()
                        .simultaneousGesture(TapGesture().onEnded(resignSearchField))
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    @ViewBuilder
    private func starredSongList(_ songs: [Song]) -> some View {
        if songs.isEmpty {
            ContentUnavailableView(
                "좋아요 표시한 곡이 없습니다",
                systemImage: "heart"
            )
            .padding(.top, 32)
        } else {
            BuFiGroupedSurface {
                LazyVStack(spacing: 0) {
                    ForEach(IndexedSongRow.makeRows(from: songs)) { row in
                        SongRow(
                            song: row.song,
                            queue: songs,
                            queueIndex: row.index
                        )
                        .padding(.horizontal, 14)
                        if row.index < songs.count - 1 {
                            rowSeparator
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    @ViewBuilder
    private func starredAlbumGrid(_ albums: [Album]) -> some View {
        if albums.isEmpty {
            ContentUnavailableView(
                "저장한 앨범이 없습니다",
                systemImage: "square.stack"
            )
            .padding(.top, 32)
        } else {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 14, alignment: .top),
                    GridItem(.flexible(), spacing: 14, alignment: .top)
                ],
                alignment: .leading,
                spacing: 20
            ) {
                ForEach(albums) { album in
                    NavigationLink(value: MusicRoute.album(album)) {
                        AlbumCard(
                            album: album,
                            width: collectionCardWidth,
                            usesHorizontalScrollTransition: false
                        )
                    }
                    .buttonStyle(BuFiPressStyle())
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func browseCollectionHeader(_ title: String) -> some View {
        HStack(spacing: 10) {
            Button {
                resignSearchField()
                withAnimation(motionEnabled ? BuFiMotion.content : .none) {
                    browseMode = .main
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 38, height: 38)
                    .buFiGlass(cornerRadius: 19, interactive: true)
            }
            .buttonStyle(BuFiPressStyle())
            .accessibilityLabel("검색 둘러보기로 돌아가기")
            Text(LocalizedStringKey(title))
                .font(.system(size: 27, weight: .bold))
                .tracking(-0.7)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    private var collectionCardWidth: CGFloat {
        max(132, (UIScreen.main.bounds.width - 52) / 2)
    }

    @ViewBuilder
    private func algorithmPlaylistGrid(_ mixes: [PersonalizedMix]) -> some View {
        if mixes.isEmpty {
            ContentUnavailableView(
                "추천 플레이리스트를 만들 음악이 없습니다",
                systemImage: "sparkles"
            )
            .padding(.top, 32)
        } else {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), alignment: .top),
                    GridItem(.flexible(), alignment: .top)
                ],
                alignment: .leading,
                spacing: 20
            ) {
                ForEach(mixes) { mix in
                    NavigationLink(value: mix) {
                        PersonalizedMixCard(
                            mix: mix,
                            width: collectionCardWidth
                        )
                    }
                    .buttonStyle(BuFiPressStyle())
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var rankedSongs: some View {
        let songs = library.snapshot.mostPlayedSongs
        return Group {
            if songs.isEmpty {
                ContentUnavailableView(
                    "청취 순위가 아직 없습니다",
                    systemImage: "chart.bar"
                )
                .padding(.top, 32)
            } else {
                BuFiGroupedSurface {
                    LazyVStack(spacing: 0) {
                        ForEach(IndexedSongRow.makeRows(from: songs)) { row in
                            HStack(spacing: 10) {
                                Text("\(row.index + 1)")
                                    .font(
                                        .system(
                                            size: 14,
                                            weight: row.index < 3 ? .bold : .medium,
                                            design: .rounded
                                        )
                                    )
                                    .foregroundStyle(
                                        row.index < 3 ? BuFiTheme.accent : Color.secondary
                                    )
                                    .monospacedDigit()
                                    .frame(width: 24, alignment: .trailing)
                                SongRow(
                                    song: row.song,
                                    queue: songs,
                                    queueIndex: row.index,
                                    artworkSize: 52,
                                    textLineLimit: 2
                                )
                            }
                            .padding(.horizontal, 12)
                            if row.index < songs.count - 1 {
                                Divider()
                                    .padding(.leading, 112)
                                    .opacity(0.50)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func resultSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            SectionTitle(title: title)
            BuFiGroupedSurface {
                LazyVStack(spacing: 0) {
                    content()
                }
            }
        }
    }

    private var personalizedMixTaskIdentity: SearchMixTaskIdentity {
        SearchMixTaskIdentity(
            revision: library.revision,
            selectedArtists: selectedArtistMixes,
            isVisible: browseMode == .algorithmPlaylists
        )
    }

    @MainActor
    private func updatePersonalizedMixesIfNeeded() async {
        guard browseMode == .algorithmPlaylists else { return }
        let revision = library.revision
        let snapshot = library.snapshot
        let selectedArtistsStorage = selectedArtistMixes
        guard revision == library.revision else { return }
        let next = await SearchPersonalizedMixWork.make(
            snapshot: snapshot,
            revision: revision,
            selectedArtists: ArtistMixPreferences.decode(selectedArtistsStorage)
        )
        guard !Task.isCancelled,
              browseMode == .algorithmPlaylists,
              revision == library.revision,
              selectedArtistsStorage == selectedArtistMixes else {
            return
        }
        personalizedMixes = next
    }

    private var rowSeparator: some View {
        Divider()
            .padding(.leading, 14 + Self.resultArtworkSize + 12)
            .opacity(0.55)
    }

    private static let resultArtworkSize: CGFloat = 54

    private func resignSearchField() {
        guard isSearchFieldFocused else { return }
        isSearchFieldFocused = false
        resignFirstResponder()
    }

    private func exitSearchSession() {
        query = ""
        model.clearSearch()
        browseMode = .main
        resignSearchField()
    }

    private func normalizedQuery(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resignFirstResponder() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}

private enum SearchSurface: Hashable {
    case browseShortcuts
    case browseRecommendedArtists
    case browseFavoriteSongsHeader
    case browseFavoriteSongs
    case browseFavoriteAlbumsHeader
    case browseFavoriteAlbums
    case browseMixesHeader
    case browseMixes
    case browseMostPlayedHeader
    case browseMostPlayed
    case resultLoading
    case resultEmpty
    case resultProgress
    case resultLocalFallback
    case resultArtists
    case resultAlbums
    case resultSongs
}

private enum SearchBrowseMode {
    case main
    case favoriteSongs
    case favoriteAlbums
    case algorithmPlaylists
    case mostPlayed
}

private struct SearchBrowseQuickItem: Identifiable {
    let mode: SearchBrowseMode
    let title: String
    let leading: HomeQuickAccessLeading

    var id: String { title }
}

private enum SearchScrollAnchor: Hashable {
    case top
}

private enum SearchPersonalizedMixWork {
    @concurrent
    static func make(
        snapshot: HomeSnapshot,
        revision: HomeSnapshotRevision,
        selectedArtists: [String]
    ) async -> [PersonalizedMix] {
        guard !Task.isCancelled else { return [] }
        let value = await PersonalizedMixBuilder.makeConcurrently(
            snapshot: snapshot,
            snapshotRevision: revision,
            selectedArtists: selectedArtists
        )
        return Task.isCancelled ? [] : value
    }
}

private struct SearchMixTaskIdentity: Hashable, Sendable {
    let revision: HomeSnapshotRevision
    let selectedArtists: String
    let isVisible: Bool
}
