import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var audio: AudioEngine

    @State private var query = ""
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
            .background(Color(red: 0.07, green: 0.07, blue: 0.07))
            .navigationDestination(for: MusicRoute.self) { route in
                MusicDetailView(route: route)
            }
            .toolbar(.hidden, for: .navigationBar)
            .onChange(of: query) { _, value in
                model.search(value)
            }
        }
    }

    private var header: some View {
        HStack {
            Circle()
                .fill(Color.orange)
                .frame(width: 44, height: 44)
                .overlay { Text("T").foregroundStyle(.black).font(.system(size: 20)) }
            Text("검색")
                .font(.system(size: 32, weight: .bold))
                .tracking(-1)
            Spacer()
            Image(systemName: "camera")
                .font(.system(size: 24, weight: .semibold))
                .accessibilityLabel("카메라 검색")
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
        .background(.white, in: RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 16)
        .onTapGesture { focused = true }
    }

    private var browse: some View {
        VStack(alignment: .leading, spacing: 28) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(Array(categories.enumerated()), id: \.offset) { index, category in
                    Button {
                        switch index {
                        case 0:
                            query = " "
                            model.clearSearch()
                        case 1:
                            if let song = model.home.starredSongs.first {
                                audio.play(song, in: model.home.starredSongs)
                            }
                        case 2:
                            query = String(Calendar.current.component(.year, from: .now))
                        default:
                            if let song = model.home.randomSongs.max(by: {
                                ($0.playCount ?? 0) < ($1.playCount ?? 0)
                            }) {
                                audio.play(song, in: model.home.randomSongs)
                            }
                        }
                    } label: {
                        ZStack(alignment: .bottomTrailing) {
                            category.1
                            Image(systemName: category.2)
                                .font(.system(size: 50, weight: .bold))
                                .foregroundStyle(.white.opacity(0.28))
                                .rotationEffect(.degrees(12))
                                .padding(12)
                            Text(category.0)
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
        Text(title)
            .font(.system(size: 22, weight: .bold))
            .padding(.top, 4)
    }
}

