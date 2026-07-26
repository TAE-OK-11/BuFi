import SwiftUI
import UIKit

struct SearchView: View {
    @EnvironmentObject private var model: AppModel

    @State private var query = ""
    @State private var browseMode = SearchBrowseMode.main
    @FocusState private var focused: Bool

    private let categories: [(String, Color, String)] = [
        ("음악", .pink, "music.note.list"),
        ("좋아요 표시한 곡", .indigo, "heart.fill"),
        ("새로 나온 음악", .purple, "sparkles"),
        ("차트", .mint, "chart.bar.fill")
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    header
                    searchField
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        browse
                    } else {
                        results
                    }
                }
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(BuFiTheme.background)
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

    private var header: some View {
        HStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [BuFiTheme.accentSoft, BuFiTheme.deezerGlow],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: "music.note")
                        .foregroundStyle(.white)
                        .font(.system(size: 17, weight: .bold))
                }
            Text("검색")
                .font(.system(size: 32, weight: .bold))
                .tracking(-1)
            Spacer()
            Button {
                focused = true
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .background(BuFiTheme.elevated, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("검색")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24, weight: .semibold))
            TextField("어떤 것을 듣고 싶으세요?", text: $query)
                .focused($focused)
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
        .foregroundStyle(.black)
        .padding(.horizontal, 16)
        .frame(height: 58)
        .background(.white, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
        .onTapGesture { focused = true }
    }

    @ViewBuilder
    private var browse: some View {
        switch browseMode {
        case .main:
            browseMain
        case .favorites:
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
        case .newReleases:
            browseCollectionHeader("새로 나온 음악")
            if model.home.recentAlbums.isEmpty {
                ContentUnavailableView(
                    "새로 추가된 앨범이 없습니다",
                    systemImage: "sparkles"
                )
                .padding(.top, 32)
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 20
                ) {
                    ForEach(model.home.recentAlbums) { album in
                        NavigationLink(value: MusicRoute.album(album)) {
                            AlbumCard(album: album, width: newReleaseCardWidth)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        case .charts:
            browseCollectionHeader("차트")
            if chartSongs.isEmpty {
                ContentUnavailableView(
                    "차트에 표시할 곡이 없습니다",
                    systemImage: "chart.bar"
                )
                .padding(.top, 32)
            } else {
                VStack(spacing: 0) {
                    ForEach(chartSongs) { song in
                        SongRow(song: song, queue: chartSongs)
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
                        switch index {
                        case 0:
                            focused = true
                        case 1:
                            browseMode = .favorites
                        case 2:
                            browseMode = .newReleases
                        default:
                            browseMode = .charts
                        }
                    } label: {
                        ZStack(alignment: .bottomTrailing) {
                            category.1
                            Image(systemName: category.2)
                                .font(.system(size: 50, weight: .bold))
                                .foregroundStyle(.white.opacity(0.28))
                                .rotationEffect(.degrees(12))
                                .padding(12)
                            Text(LocalizedStringKey(category.0))
                                .font(.system(size: 19, weight: .bold))
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .padding(15)
                        }
                        .frame(height: 112)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
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
                                .buttonStyle(.plain)
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

    private var chartSongs: [Song] {
        Array(
            model.home.randomSongs
                .sorted {
                    if ($0.playCount ?? 0) == ($1.playCount ?? 0) {
                        return $0.title.localizedStandardCompare($1.title) == .orderedAscending
                    }
                    return ($0.playCount ?? 0) > ($1.playCount ?? 0)
                }
                .prefix(30)
        )
    }

    private var newReleaseCardWidth: CGFloat {
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
    case favorites
    case newReleases
    case charts
}
