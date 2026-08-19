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
    @State private var resolvedPersonalizedMixIdentity: SearchMixTaskIdentity?
    @State private var viewportWidth: CGFloat = 0
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        BuFiPageHeader(title: "검색")
                            .id(SearchScrollAnchor.top)
                            .onTapGesture(perform: resignSearchField)
                        searchField
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
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            guard width.isFinite, width > 0, abs(viewportWidth - width) > 0.5 else { return }
            viewportWidth = width
        }
    }

    private var isSearchSession: Bool {
        !normalizedQuery(query).isEmpty
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(isSearchFieldFocused ? BuFiTheme.accentSoft : .secondary)
            TextField(
                "",
                text: $query,
                prompt: Text("어떤 것을 듣고 싶으세요?")
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
            )
            .focused($isSearchFieldFocused)
            .font(.body)
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
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("검색 닫기")
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .frame(minHeight: 58)
        .buFiGlass(cornerRadius: 20, interactive: true)
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(
                    isSearchFieldFocused
                        ? BuFiTheme.accent.opacity(0.78)
                        : BuFiTheme.separator.opacity(0.42),
                    lineWidth: isSearchFieldFocused ? 1.4 : 0.6
                )
        }
        .padding(.horizontal, 16)
        .contentShape(Rectangle())
        .onTapGesture {
            isSearchFieldFocused = true
        }
        .animation(motionEnabled ? BuFiMotion.fade : .none, value: isSearchFieldFocused)
    }

    @ViewBuilder
    private var content: some View {
        ForEach(visibleSurfaces, id: \.self) { surface in
            searchSurface(surface)
                .frame(maxWidth: .infinity, alignment: .top)
                .simultaneousGesture(
                    TapGesture().onEnded(resignSearchField)
                )
        }
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
                    .buttonStyle(.plain)
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
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded(resignSearchField))
                    if album.id != result.albums.last?.id {
                        rowSeparator
                    }
                }
            }
            .padding(.horizontal, 16)
        case .resultSongs:
            resultSection("곡") {
                ForEach(
                    Array(result.songs.enumerated()),
                    id: \.element.id
                ) { index, song in
                    SongRow(
                        song: song,
                        queue: result.songs,
                        queueIndex: index,
                        playbackOrigin: .search,
                        textLineLimit: 2
                    )
                    .padding(.horizontal, 14)
                    .simultaneousGesture(TapGesture().onEnded(resignSearchField))
                    if index < result.songs.count - 1 {
                        rowSeparator
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func artistResultRow(_ artist: Artist) -> some View {
        HStack(spacing: 13) {
            ArtworkView(
                coverArt: artist.coverArt,
                size: 58,
                cornerRadius: 29
            )
            .frame(width: 58, height: 58)
            Text(artist.name)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private func albumResultRow(_ album: Album) -> some View {
        HStack(spacing: 13) {
            ArtworkView(
                coverArt: album.coverArt,
                size: 58,
                cornerRadius: 11
            )
            .frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 4) {
                Text(album.name)
                    .font(.system(size: 17, weight: .semibold))
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
        .padding(.vertical, 7)
    }

    private var browseShortcuts: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10)
            ],
            spacing: 10
        ) {
            ForEach(Self.searchShortcuts) { shortcut in
                Button {
                    resignSearchField()
                    browseMode = shortcut.mode
                } label: {
                    BuFiShortcutCard(
                        title: LocalizedStringKey(shortcut.title),
                        subtitle: shortcut.subtitle,
                        systemImage: shortcut.systemImage,
                        tint: shortcut.tint
                    )
                }
                .buttonStyle(BuFiPressStyle())
            }
        }
        .padding(.horizontal, 16)
    }

    private func recommendedArtistsRail(_ artists: [Artist]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: "추천 아티스트")
                .padding(.horizontal, 16)
                .padding(.top, 2)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(artists.prefix(12)) { artist in
                        NavigationLink(value: MusicRoute.artist(artist)) {
                            VStack(spacing: 8) {
                                ArtworkView(
                                    coverArt: artist.coverArt,
                                    size: 120,
                                    cornerRadius: 60
                                )
                                .frame(width: 120, height: 120)
                                Text(artist.name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(3)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(width: 120)
                        }
                        .buttonStyle(BuFiPressStyle())
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
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        SongRow(
                            song: song,
                            queue: songs,
                            queueIndex: index
                        )
                        .padding(.horizontal, 14)
                        if index < songs.count - 1 {
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
            .buttonStyle(.plain)
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
        let width = viewportWidth > 0 ? viewportWidth : 390
        return max(132, (width - 52) / 2)
    }

    private static let searchShortcuts = [
        SearchShortcut(
            mode: .favoriteSongs,
            title: "좋아요 곡",
            subtitle: String(localized: "저장한 음악"),
            systemImage: "heart.fill",
            tint: BuFiTheme.accent
        ),
        SearchShortcut(
            mode: .favoriteAlbums,
            title: "좋아요 앨범",
            subtitle: String(localized: "보관한 앨범"),
            systemImage: "square.stack.fill",
            tint: Color(red: 0.45, green: 0.33, blue: 0.74)
        ),
        SearchShortcut(
            mode: .algorithmPlaylists,
            title: "맞춤 믹스",
            subtitle: String(localized: "Daylist와 취향 추천"),
            systemImage: "sparkles",
            tint: Color(red: 0.20, green: 0.58, blue: 0.52)
        ),
        SearchShortcut(
            mode: .mostPlayed,
            title: "자주 듣는 곡",
            subtitle: String(localized: "청취 기록 순위"),
            systemImage: "chart.bar.fill",
            tint: Color(red: 0.22, green: 0.50, blue: 0.78)
        )
    ]

    @ViewBuilder
    private func algorithmPlaylistGrid(_ mixes: [PersonalizedMix]) -> some View {
        if resolvedPersonalizedMixIdentity != personalizedMixTaskIdentity {
            HStack {
                Spacer()
                ProgressView("맞춤 믹스 준비 중…")
                Spacer()
            }
            .padding(.top, 32)
        } else if mixes.isEmpty {
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
                        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                            HStack(spacing: 10) {
                                Text("\(index + 1)")
                                    .font(
                                        .system(
                                            size: 14,
                                            weight: index < 3 ? .bold : .medium,
                                            design: .rounded
                                        )
                                    )
                                    .foregroundStyle(
                                        index < 3 ? BuFiTheme.accent : Color.secondary
                                    )
                                    .monospacedDigit()
                                    .frame(width: 24, alignment: .trailing)
                                SongRow(
                                    song: song,
                                    queue: songs,
                                    queueIndex: index,
                                    artworkSize: 52,
                                    textLineLimit: 2
                                )
                            }
                            .padding(.horizontal, 12)
                            if index < songs.count - 1 {
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
        let taskIdentity = personalizedMixTaskIdentity
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
        resolvedPersonalizedMixIdentity = taskIdentity
    }

    private var rowSeparator: some View {
        Divider()
            .padding(.leading, 85)
            .opacity(0.55)
    }

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

private struct SearchShortcut: Identifiable {
    let mode: SearchBrowseMode
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color

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
        let value = PersonalizedMixBuilder.make(
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
