import SwiftUI
import UIKit

struct SearchView: View {
    @EnvironmentObject private var model: AppModel

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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    searchField
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        browse
                    } else {
                        results
                    }
                }
                .padding(.top, 10)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
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

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .semibold))
            TextField(
                "",
                text: $query,
                prompt: Text("어떤 것을 듣고 싶으세요?")
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
            )
                .focused($focused)
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
        .frame(height: 56)
        .background(
            BuFiTheme.elevated,
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(BuFiTheme.separator.opacity(0.5), lineWidth: 0.5)
        }
        .padding(.horizontal, 16)
        .onTapGesture { focused = true }
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
                VStack(spacing: 0) {
                    ForEach(model.home.starredSongs) { song in
                        SongRow(song: song, queue: model.home.starredSongs)
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
        VStack(alignment: .leading, spacing: 28) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(Array(categories.enumerated()), id: \.offset) { index, category in
                    Button {
                        withAnimation(.interactiveSpring(response: 0.42, dampingFraction: 0.82)) {
                            browseMode = index == 0 ? .favoriteSongs : .favoriteAlbums
                        }
                    } label: {
                        ZStack(alignment: .bottomTrailing) {
                            LinearGradient(
                                colors: [
                                    category.1,
                                    category.1.opacity(0.64),
                                    BuFiTheme.deezerGlow.opacity(index == 0 ? 0.18 : 0.58)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            Image(systemName: category.2)
                                .font(.system(size: 54, weight: .bold))
                                .foregroundStyle(.white.opacity(0.22))
                                .rotationEffect(.degrees(9))
                                .padding(14)
                            Text(LocalizedStringKey(category.0))
                                .font(.system(size: 20, weight: .bold))
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .padding(16)
                        }
                        .foregroundStyle(.white)
                        .frame(height: 128)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .shadow(color: category.1.opacity(0.18), radius: 16, y: 8)
                    }
                    .buttonStyle(BuFiPressStyle())
                }
            }
            .padding(.horizontal, 16)

            if !model.home.recentAlbums.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    SectionTitle(title: "앨범 둘러보기")
                        .padding(.horizontal, 16)
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
                withAnimation(.snappy(duration: 0.24)) { browseMode = .main }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .bold))
                    .frame(width: 38, height: 38)
                    .background(BuFiTheme.elevated, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("검색 둘러보기로 돌아가기")
            Text(LocalizedStringKey(title))
                .font(.system(size: 27, weight: .bold))
                .tracking(-0.7)
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
                    resultHeader("아티스트")
                    ForEach(model.searchResults.artists) { artist in
                        NavigationLink(value: MusicRoute.artist(artist)) {
                            HStack(spacing: 13) {
                                ArtworkView(coverArt: artist.coverArt, size: 62, cornerRadius: 31)
                                    .frame(width: 62, height: 62)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(artist.name).font(.system(size: 17, weight: .semibold))
                                    Text("아티스트").font(.system(size: 13)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !model.searchResults.albums.isEmpty {
                    resultHeader("앨범")
                    ForEach(model.searchResults.albums) { album in
                        NavigationLink(value: MusicRoute.album(album)) {
                            HStack(spacing: 13) {
                                ArtworkView(coverArt: album.coverArt, size: 62, cornerRadius: 6)
                                    .frame(width: 62, height: 62)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(album.name).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                                    Text("앨범 · \(album.artist)")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !model.searchResults.songs.isEmpty {
                    resultHeader("곡")
                    ForEach(model.searchResults.songs) { song in
                        SongRow(song: song, queue: model.searchResults.songs)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func resultHeader(_ title: String) -> some View {
        Text(LocalizedStringKey(title))
            .font(.system(size: 22, weight: .bold))
            .padding(.top, 4)
    }
}

private enum SearchBrowseMode {
    case main
    case favoriteSongs
    case favoriteAlbums
}
