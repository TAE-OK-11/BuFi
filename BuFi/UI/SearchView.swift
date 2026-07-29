import SwiftUI
import UIKit

struct SearchView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.buFiMotionEnabled) private var motionEnabled

    @State private var query = ""
    @State private var browseMode = SearchBrowseMode.main
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        BuFiPageHeader(title: "검색")
                            .id(SearchScrollAnchor.top)
                        searchField
                        Group {
                            if isSearchSession {
                                searchSessionContent
                            } else {
                                browse
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                        .contentShape(Rectangle())
                        .simultaneousGesture(
                            TapGesture().onEnded { focused = false }
                        )
                    }
                    .padding(.top, 18)
                    .padding(.bottom, 34)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: browseMode) { _, _ in
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
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    browseMode = .main
                }
                model.search(value)
            }
        }
    }

    private var isSearchSession: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(focused ? BuFiTheme.accentSoft : .secondary)
            TextField(
                "",
                text: $query,
                prompt: Text("어떤 것을 듣고 싶으세요?")
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
            )
            .focused($focused)
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
                Button {
                    query = ""
                    model.clearSearch()
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("검색어 지우기")
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .frame(minHeight: 58)
        .background(Color.primary.opacity(0.05))
        .buFiGlass(cornerRadius: 20, interactive: true)
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(
                    focused
                        ? BuFiTheme.accent.opacity(0.78)
                        : BuFiTheme.separator.opacity(0.42),
                    lineWidth: focused ? 1.4 : 0.6
                )
        }
        .padding(.horizontal, 16)
        .onTapGesture { focused = true }
        .animation(motionEnabled ? BuFiMotion.fade : .none, value: focused)
    }

    private var searchSessionContent: some View {
        results
    }

    @ViewBuilder
    private var browse: some View {
        switch browseMode {
        case .main:
            browseMain
        case .favoriteSongs:
            browseCollectionHeader("좋아요 곡")
            if model.home.starredSongs.isEmpty {
                ContentUnavailableView(
                    "좋아요 표시한 곡이 없습니다",
                    systemImage: "heart"
                )
                .padding(.top, 32)
            } else {
                BuFiGroupedSurface {
                    LazyVStack(spacing: 0) {
                        ForEach(model.home.starredSongs) { song in
                            SongRow(song: song, queue: model.home.starredSongs)
                                .padding(.horizontal, 14)
                            if song.id != model.home.starredSongs.last?.id {
                                rowSeparator
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        case .favoriteAlbums:
            browseCollectionHeader("좋아요 앨범")
            if model.home.starredAlbums.isEmpty {
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
                    ForEach(model.home.starredAlbums) { album in
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
        case .algorithmPlaylists:
            algorithmPlaylists(
                PersonalizedMixBuilder.make(snapshot: model.home)
            )
        case .mostPlayed:
            browseCollectionHeader("자주 들은 곡")
            rankedSongs
        }
    }

    private var browseMain: some View {
        VStack(alignment: .leading, spacing: 22) {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 10),
                    GridItem(.flexible(), spacing: 10)
                ],
                spacing: 10
            ) {
                ForEach(searchShortcuts) { shortcut in
                    Button {
                        withAnimation(motionEnabled ? BuFiMotion.content : .none) {
                            browseMode = shortcut.mode
                            focused = false
                        }
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

            if !model.home.recommendedArtists.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle(title: "추천 아티스트")
                        .padding(.horizontal, 16)
                        .padding(.top, 2)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 16) {
                            ForEach(model.home.recommendedArtists.prefix(12)) {
                                artist in
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
                                            .fixedSize(
                                                horizontal: false,
                                                vertical: true
                                            )
                                    }
                                    .frame(width: 120)
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

    private func browseCollectionHeader(_ title: String) -> some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(motionEnabled ? BuFiMotion.content : .none) {
                    browseMode = .main
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 38, height: 38)
                    .background(Color.primary.opacity(0.05), in: Circle())
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
        max(132, (UIScreen.main.bounds.width - 52) / 2)
    }

    @ViewBuilder
    private var results: some View {
        if model.isSearching {
            HStack {
                Spacer()
                ProgressView("검색 중…")
                Spacer()
            }
            .padding(.top, 48)
        } else if model.searchResults.isEmpty {
            ContentUnavailableView.search(text: query)
                .padding(.top, 42)
        } else {
            VStack(alignment: .leading, spacing: 22) {
                if !model.searchResults.artists.isEmpty {
                    resultSection("아티스트") {
                        ForEach(model.searchResults.artists) { artist in
                            NavigationLink(value: MusicRoute.artist(artist)) {
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
                            .buttonStyle(.plain)
                            if artist.id != model.searchResults.artists.last?.id {
                                rowSeparator
                            }
                        }
                    }
                }
                if !model.searchResults.albums.isEmpty {
                    resultSection("앨범") {
                        ForEach(model.searchResults.albums) { album in
                            NavigationLink(value: MusicRoute.album(album)) {
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
                            .buttonStyle(.plain)
                            if album.id != model.searchResults.albums.last?.id {
                                rowSeparator
                            }
                        }
                    }
                }
                if !model.searchResults.songs.isEmpty {
                    resultSection("곡") {
                        ForEach(model.searchResults.songs) { song in
                            SongRow(
                                song: song,
                                queue: model.searchResults.songs,
                                playbackOrigin: .search,
                                textLineLimit: 2
                            )
                            .padding(.horizontal, 14)
                            if song.id != model.searchResults.songs.last?.id {
                                rowSeparator
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var searchShortcuts: [SearchShortcut] {
        [
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
    }

    @ViewBuilder
    private func algorithmPlaylists(
        _ mixes: [PersonalizedMix]
    ) -> some View {
        browseCollectionHeader("맞춤 믹스")
        if mixes.isEmpty {
            ContentUnavailableView(
                "추천 플레이리스트를 만들 음악이 없습니다",
                systemImage: "sparkles"
            )
            .padding(.top, 32)
        } else {
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
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
        Group {
            if model.home.mostPlayedSongs.isEmpty {
                ContentUnavailableView(
                    "청취 순위가 아직 없습니다",
                    systemImage: "chart.bar"
                )
                .padding(.top, 32)
            } else {
                BuFiGroupedSurface {
                    LazyVStack(spacing: 0) {
                        ForEach(
                            Array(model.home.mostPlayedSongs.enumerated()),
                            id: \.element.id
                        ) { index, song in
                            HStack(spacing: 2) {
                                Text("\(index + 1)")
                                    .font(
                                        .system(
                                            size: 14,
                                            weight: index < 3 ? .bold : .medium,
                                            design: .rounded
                                        )
                                    )
                                    .foregroundStyle(
                                        index < 3
                                            ? BuFiTheme.accent
                                            : Color.secondary
                                    )
                                    .monospacedDigit()
                                    .frame(width: 28, alignment: .trailing)
                                SongRow(
                                    song: song,
                                    queue: model.home.mostPlayedSongs,
                                    artworkSize: 52,
                                    textLineLimit: 2
                                )
                            }
                            .padding(.horizontal, 12)
                            if song.id != model.home.mostPlayedSongs.last?.id {
                                Divider()
                                    .padding(.leading, 106)
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
                VStack(spacing: 0) {
                    content()
                }
            }
        }
    }

    private var rowSeparator: some View {
        Divider()
            .padding(.leading, 85)
            .opacity(0.55)
    }
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
