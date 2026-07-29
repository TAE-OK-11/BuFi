import SwiftUI
import UIKit

struct SearchView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.buFiMotionEnabled) private var motionEnabled

    @State private var query = ""
    @State private var browseMode = SearchBrowseMode.main
    @FocusState private var focused: Bool

    private let categories: [(String, Color, String)] = [
        (
            "좋아요 표시한 곡",
            Color(red: 0.78, green: 0.16, blue: 0.27),
            "heart.fill"
        ),
        (
            "좋아요 표시한 앨범",
            Color(red: 0.38, green: 0.24, blue: 0.62),
            "square.stack.fill"
        )
    ]

    var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        BuFiPageHeader(
                            title: "검색",
                            subtitle: "서버의 음악과 내 컬렉션을 빠르게 찾기",
                            systemImage: "magnifyingglass"
                        )
                        searchField
                            .id(SearchScrollAnchor.top)
                        Group {
                            if isSearchSession {
                                searchSessionContent
                            } else {
                                browse
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            focused = false
                        }
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
        focused || !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                        ? LinearGradient(
                            colors: [BuFiTheme.accentSoft, BuFiTheme.deezerGlow],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        : LinearGradient(
                            colors: [
                                BuFiTheme.separator.opacity(0.55),
                                BuFiTheme.separator.opacity(0.55)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                    lineWidth: focused ? 1.4 : 0.6
                )
        }
        .padding(.horizontal, 16)
        .onTapGesture { focused = true }
        .animation(motionEnabled ? BuFiMotion.fade : .none, value: focused)
    }

    @ViewBuilder
    private var searchSessionContent: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text("검색어를 입력하세요")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 54)
        } else {
            results
        }
    }

    @ViewBuilder
    private var browse: some View {
        switch browseMode {
        case .main:
            browseMain
        case .favoriteSongs:
            browseCollectionHeader("좋아요 표시한 곡")
            if model.home.starredSongs.isEmpty {
                ContentUnavailableView(
                    "좋아요 표시한 곡이 없습니다",
                    systemImage: "heart"
                )
                .padding(.top, 32)
            } else {
                BuFiGroupedSurface {
                    VStack(spacing: 0) {
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
            browseCollectionHeader("좋아요 표시한 앨범")
            if model.home.starredAlbums.isEmpty {
                ContentUnavailableView(
                    "저장한 앨범이 없습니다",
                    systemImage: "square.stack"
                )
                .padding(.top, 32)
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 20
                ) {
                    ForEach(model.home.starredAlbums) { album in
                        NavigationLink(value: MusicRoute.album(album)) {
                            AlbumCard(album: album, width: collectionCardWidth)
                        }
                        .buttonStyle(BuFiPressStyle())
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var browseMain: some View {
        VStack(alignment: .leading, spacing: 22) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(categories.indices, id: \.self) { index in
                    let category = categories[index]
                    Button {
                        withAnimation(motionEnabled ? BuFiMotion.content : .none) {
                            browseMode = index == 0 ? .favoriteSongs : .favoriteAlbums
                        }
                    } label: {
                        BuFiFeatureCard(
                            title: LocalizedStringKey(category.0),
                            subtitle: categoryCount(index),
                            systemImage: category.2,
                            tint: category.1,
                            expandsHorizontally: true,
                            trailingSystemImage: "chevron.right"
                        )
                    }
                    .buttonStyle(BuFiPressStyle())
                }
            }
            .padding(.horizontal, 16)

            if !model.home.recentAlbums.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle(title: "앨범 둘러보기")
                        .padding(.horizontal, 16)
                        .padding(.top, 2)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 15) {
                            ForEach(model.home.recentAlbums) { album in
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
                    .background(Color.primary.opacity(0.05))
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

    private func categoryCount(_ index: Int) -> String {
        let count = index == 0
            ? model.home.starredSongs.count
            : model.home.starredAlbums.count
        return String(format: String(localized: "%d개 항목"), count)
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
}

private enum SearchScrollAnchor: Hashable {
    case top
}
