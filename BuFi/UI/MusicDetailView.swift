import SwiftUI

private struct MusicDetailFavoriteButton: View {
    @EnvironmentObject private var model: AppModel

    let route: MusicRoute

    @ViewBuilder
    var body: some View {
        switch route {
        case .album(let album):
            MusicDetailFavoriteButtonContent(
                overrideState: model.favoriteOverrideState(for: album),
                originalState: album.isStarred,
                action: { await model.toggleStar(album: album) }
            )
        case .artist(let artist):
            MusicDetailFavoriteButtonContent(
                overrideState: model.favoriteOverrideState(for: artist),
                originalState: artist.isStarred,
                action: { await model.toggleStar(artist: artist) }
            )
        case .playlist:
            EmptyView()
        }
    }
}

private struct MusicDetailFavoriteButtonContent: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.buFiMotionEnabled) private var motionEnabled
    @ObservedObject var overrideState: FavoriteOverrideValueState
    let originalState: Bool
    let action: @MainActor @Sendable () async -> Void

    private var isFavorite: Bool {
        overrideState.value ?? originalState
    }

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            favoriteIcon
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(
                    colorScheme == .dark
                        ? Color.white.opacity(0.92)
                        : Color.black.opacity(0.78)
                )
                .frame(width: 42, height: 42)
                .shadow(
                    color: .black.opacity(colorScheme == .dark ? 0.12 : 0.045),
                    radius: 8,
                    y: 4
                )
                .buFiGlass(cornerRadius: 21, interactive: true)
        }
        .buttonStyle(BuFiPressStyle())
        .animation(
            motionEnabled ? BuFiMotion.symbol : .none,
            value: isFavorite
        )
        .accessibilityLabel(
            isFavorite ? "라이브러리에서 제거" : "라이브러리에 추가"
        )
    }

    @ViewBuilder
    private var favoriteIcon: some View {
        let image = Image(systemName: isFavorite ? "checkmark" : "plus")
        if motionEnabled {
            image.contentTransition(.symbolEffect(.replace))
        } else {
            image
        }
    }
}

struct MusicDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.buFiMotionEnabled) private var motionEnabled
    @AppStorage(ArtistMixPreferences.storageKey)
    private var selectedArtistMixes = "[]"

    let route: MusicRoute
    private let audio = AudioEngine.shared

    @State private var title = ""
    @State private var subtitle = ""
    @State private var coverArt: String?
    @State private var songs: [Song] = []
    @State private var songRowLayout = SongRowLayout.standard
    @State private var albums: [Album] = []
    @State private var isLoading = true
    @State private var selectedSong: Song?
    @State private var palette = ArtworkPalette.fallback
    @State private var artistBiography = ""
    @State private var artistAlbumCount = 0
    @State private var discography = ArtistDiscographyPresentation.empty
    @State private var downloadAllTask: Task<Void, Never>?
    @State private var isDownloadingAll = false
    @State private var loadError: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                hero
                    .buFiEntranceMotion(offset: 10)
                if isArtist, !isLoading {
                    artistMixControl
                        .buFiVerticalSectionMotion(delay: 0.025)
                }
                if isLoading {
                    ProgressView("불러오는 중…")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                        .buFiEntranceMotion(delay: 0.03)
                        .transition(
                            motionEnabled ? BuFiTransition.section : .opacity
                        )
                } else if let loadError {
                    VStack(spacing: 16) {
                        ContentUnavailableView(
                            "불러오지 못했습니다",
                            systemImage: "exclamationmark.triangle",
                            description: Text(loadError)
                        )
                        Button("다시 시도") {
                            Task { await load() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(BuFiTheme.accent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
                    .buFiEntranceMotion(delay: 0.03)
                } else {
                    controls
                        .buFiVerticalSectionMotion()
                    if isArtist {
                        artistPopularSongs
                            .buFiVerticalSectionMotion(delay: 0.03)
                        if !albums.isEmpty {
                            artistDiscography
                                .buFiVerticalSectionMotion(delay: 0.055)
                        }
                    } else {
                        songList
                            .buFiVerticalSectionMotion(delay: 0.025)
                    }
                    if isArtist, !artistBiography.isEmpty {
                        artistAbout
                            .buFiVerticalSectionMotion(delay: 0.075)
                    }
                }
            }
            // `load()` already wraps the flip out of the loading state in an
            // explicit animation. Repeating it here would also hand that curve
            // to every section mounting underneath, so each one would fade in
            // twice: once under this animation and once under its own entrance.
            .buFiMiniPlayerContentClearance()
        }
        .background(background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onChange(of: coverArt) { _, _ in
            palette = .fallback
        }
        .task(id: route) { await load() }
        .onDisappear {
            downloadAllTask?.cancel()
            downloadAllTask = nil
            isDownloadingAll = false
            model.cancelDetailRequest(for: route)
        }
        .sheet(item: $selectedSong) { song in
            SongActionsSheet(song: song)
                .presentationDetents([.height(335)])
                .presentationDragIndicator(.visible)
        }
    }

    @ViewBuilder
    private var hero: some View {
        if isArtist {
            artistHero
        } else {
            collectionHero
        }
    }

    private var artistHero: some View {
        let identity = MusicDetailArtworkIdentity(route: route, coverArtID: coverArt)
        let stats = String(
            format: String(localized: "%d개 발매작 · %d개 인기곡"),
            max(artistAlbumCount, albums.count),
            songs.count
        )
        return ZStack(alignment: .bottomLeading) {
            ArtistHeroArtwork(
                coverArt: coverArt,
                artistName: currentArtistName,
                cacheRevision: identity.cacheRevision,
                onPalette: { nextPalette in
                    receivePalette(nextPalette, for: identity)
                }
            )

            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear, location: 0.48),
                    .init(color: .black.opacity(0.14), location: 0.68),
                    .init(color: .black.opacity(0.86), location: 1.0)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 7) {
                Text(title.isEmpty ? " " : title)
                    .font(.system(size: 35, weight: .bold))
                    .tracking(-1.2)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .contentTransition(.interpolate)
                Text(stats)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .contentTransition(.interpolate)
            }
            // Keyed on the rendered strings. Watching the album count alone
            // meant the song half of the stats line snapped from zero to its
            // real value while the album half interpolated.
            .animation(
                motionEnabled ? BuFiMotion.content : .none,
                value: MusicDetailHeroText(title: title, detail: stats)
            )
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.bottom, 20)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.13), radius: 20, y: 10)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 18)
    }

    private var collectionHero: some View {
        let identity = MusicDetailArtworkIdentity(route: route, coverArtID: coverArt)
        return VStack(spacing: 19) {
            ArtworkView(
                coverArt: coverArt,
                size: 270,
                cornerRadius: 18,
                cacheRevision: identity.cacheRevision,
                onPalette: { nextPalette in
                    receivePalette(nextPalette, for: identity)
                }
            )
            .frame(width: 270, height: 270)
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.18 : 0.09),
                radius: 12,
                y: 6
            )

            VStack(spacing: 7) {
                Text(title.isEmpty ? " " : title)
                    .font(.system(size: 27, weight: .bold))
                    .tracking(-0.7)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .foregroundStyle(collectionTitleColor)
                    .contentTransition(.interpolate)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(collectionSubtitleColor)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.85)
                        .contentTransition(.interpolate)
                        .transition(.opacity.combined(with: .offset(y: 4)))
                }
            }
            // Canonical metadata usually replaces both lines at once, so one
            // animation covers the pair rather than the title running its own
            // curve underneath the container's.
            .animation(
                motionEnabled ? BuFiMotion.content : .none,
                value: MusicDetailHeroText(title: title, detail: subtitle)
            )
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .buFiSurface(
                cornerRadius: 20,
                fill: BuFiTheme.elevated.opacity(0.90),
                stroke: BuFiTheme.separator.opacity(0.24)
            )
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                if canFavorite {
                    MusicDetailFavoriteButton(route: route)
                }

                Button { downloadAll() } label: {
                    secondaryControl(
                        Group {
                            if isDownloadingAll {
                                ProgressView()
                                    .transition(.opacity.combined(with: .scale(scale: 0.88)))
                            } else {
                                Image(systemName: "arrow.down.circle")
                                    .font(.system(size: 19, weight: .semibold))
                                    .transition(.opacity.combined(with: .scale(scale: 0.88)))
                            }
                        },
                        diameter: 42
                    )
                }
                .buttonStyle(BuFiPressStyle())
                .disabled(songs.isEmpty || isDownloadingAll)
                .animation(
                    motionEnabled ? BuFiMotion.symbol : .none,
                    value: isDownloadingAll
                )
                .accessibilityLabel("모두 오프라인 저장")

                Menu {
                    Button {
                        if let first = songs.first {
                            audio.play(
                                first,
                                in: songs,
                                origin: isArtist ? .manual : .album
                            )
                        }
                    } label: {
                        Label("모두 재생", systemImage: "play.fill")
                    }
                    Button {
                        guard !songs.isEmpty else { return }
                        let shuffled = songs.shuffled()
                        if let first = shuffled.first {
                            audio.play(
                                first,
                                in: shuffled,
                                origin: isArtist ? .manual : .album
                            )
                        }
                    } label: {
                        Label("셔플 재생", systemImage: "shuffle")
                    }
                    Button { downloadAll() } label: {
                        Label("모두 오프라인 저장", systemImage: "arrow.down.circle")
                    }
                    .disabled(songs.isEmpty || isDownloadingAll)
                } label: {
                    secondaryControl(
                        Image(systemName: "ellipsis")
                            .font(.system(size: 20, weight: .semibold)),
                        diameter: 42
                    )
                }
                .buttonStyle(BuFiPressStyle())
                .accessibilityLabel("더 보기")
            }

            Spacer(minLength: 12)

            Button {
                guard !songs.isEmpty else { return }
                let shuffled = songs.shuffled()
                if let first = shuffled.first {
                    audio.play(
                        first,
                        in: shuffled,
                        origin: isArtist ? .manual : .album
                    )
                }
            } label: {
                secondaryControl(
                    Image(systemName: "shuffle")
                        .font(.system(size: 21, weight: .semibold)),
                    diameter: 52
                )
            }
            .buttonStyle(BuFiPressStyle())
            .disabled(songs.isEmpty)
            .accessibilityLabel("셔플 재생")

            Button {
                if let first = songs.first {
                    audio.play(
                        first,
                        in: songs,
                        origin: isArtist ? .manual : .album
                    )
                }
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .background(BuFiTheme.accent, in: Circle())
                    .overlay {
                        Circle().stroke(
                            .white.opacity(colorScheme == .dark ? 0.10 : 0.28),
                            lineWidth: 0.8
                        )
                    }
                    .shadow(color: BuFiTheme.accent.opacity(0.24), radius: 14, y: 7)
                    .offset(x: 1)
            }
            .buttonStyle(BuFiPressStyle())
            .disabled(songs.isEmpty)
            .accessibilityLabel("모두 재생")
        }
        .padding(.horizontal, 22)
        .padding(.top, 2)
        .padding(.bottom, 22)
    }

    private var artistMixControl: some View {
        Button {
            toggleCurrentArtistMix()
        } label: {
            Label {
                Text(hasCurrentArtistMix ? "Artist Mix에 추가됨" : "Artist Mix 만들기")
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .contentTransition(.interpolate)
            } icon: {
                Image(
                    systemName: hasCurrentArtistMix
                        ? "checkmark.circle.fill"
                        : "sparkles.rectangle.stack"
                )
                .contentTransition(.symbolEffect(.replace))
            }
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(
                hasCurrentArtistMix ? Color.primary : BuFiTheme.accentSoft
            )
            .padding(.horizontal, 15)
            .frame(minHeight: 44)
            .buFiSurface(cornerRadius: 22)
        }
        .buttonStyle(BuFiPressStyle())
        .animation(
            motionEnabled ? BuFiMotion.symbol : .none,
            value: hasCurrentArtistMix
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .accessibilityLabel(
            hasCurrentArtistMix
                ? "Artist Mix에서 제거"
                : "Artist Mix 만들기"
        )
        .accessibilityHint(
            hasCurrentArtistMix
                ? "탭하면 이 아티스트를 Artist Mix에서 뺍니다"
                : "최대 4명의 아티스트를 Artist Mix에 고정합니다"
        )
    }

    private var artistAbout: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("아티스트 소개")
                .font(.system(size: 22, weight: .bold))
            Text(artistBiography)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.secondary)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 20)
        .buFiSurface(
            cornerRadius: 20,
            fill: BuFiTheme.elevated,
            stroke: contrastSeparator,
            lineWidth: 0.8
        )
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.08 : 0.035), radius: 12, y: 5)
        .padding(.horizontal, 16)
        .padding(.top, 28)
    }

    private var artistPopularSongs: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("인기곡")
                .font(.system(size: 23, weight: .bold))
                .padding(.horizontal, 16)
            songList
        }
        .padding(.top, 10)
    }

    @ViewBuilder
    private var artistDiscography: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !discography.fullAlbums.isEmpty {
                albumRail("앨범", albums: discography.fullAlbums)
            }
            if !discography.epAlbums.isEmpty {
                albumRail("EP", albums: discography.epAlbums)
            }
            if !discography.singleAlbums.isEmpty {
                albumRail("싱글", albums: discography.singleAlbums)
            }
        }
        .padding(.top, 28)
    }

    private func albumRail(_ heading: LocalizedStringKey, albums: [Album]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(heading)
                .font(.system(size: 23, weight: .bold))
                .padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 15) {
                    ForEach(albums) { album in
                        NavigationLink(value: MusicRoute.album(album)) {
                            AlbumCard(album: album, width: 150)
                        }
                        .buttonStyle(BuFiPressStyle())
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    @ViewBuilder
    private var songList: some View {
        if songs.isEmpty {
            ContentUnavailableView(
                isArtist
                    ? LocalizedStringKey("인기곡이 없습니다")
                    : LocalizedStringKey("수록곡이 없습니다"),
                systemImage: "music.note"
            )
            .frame(maxWidth: .infinity)
            .padding(.top, 34)
        } else {
            BuFiGroupedSurface {
                LazyVStack(spacing: 0) {
                    ForEach(IndexedSong.list(songs)) { item in
                        SongRowCurrentTrackResolver(
                            song: item.song,
                            queue: songs,
                            queueIndex: item.index,
                            playbackOrigin: isArtist ? .manual : .album,
                            artworkSize: isArtist ? 54 : 44,
                            layout: songRowLayout,
                            fallbackTrackNumber: item.index + 1,
                            onMore: { selectedSong = item.song }
                        )
                        .padding(.horizontal, 12)
                        if item.index < songs.count - 1 {
                            Divider()
                                .padding(.leading, isArtist ? 78 : 56)
                                .opacity(0.50)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, isArtist ? 0 : 14)
        }
    }

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(palette.top).opacity(colorScheme == .dark ? 0.92 : 0.18),
                    BuFiTheme.background
                ],
                startPoint: .top,
                endPoint: .init(x: 0.5, y: 0.43)
            )
            if colorScheme == .light {
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.10),
                        Color.white.opacity(0.50),
                        BuFiTheme.background
                    ],
                    startPoint: .top,
                    endPoint: .init(x: 0.5, y: 0.52)
                )
            }
        }
        .ignoresSafeArea()
        // palette가 바뀌는 두 지점(artistHero/collectionHero의 onPalette)에서
        // 이미 withAnimation으로 감싸고 있어서, 여기서 또 .animation(value:)를
        // 걸면 같은 전환이 중복 적용됨 — 제거해서 한 번만 부드럽게 걸리도록 함.
    }

    private func secondaryControl<Content: View>(
        _ content: Content,
        diameter: CGFloat
    ) -> some View {
        content
            .foregroundStyle(detailControlForeground)
            .frame(width: diameter, height: diameter)
            .shadow(
                color: .black.opacity(colorScheme == .dark ? 0.12 : 0.045),
                radius: 8,
                y: 4
            )
            .buFiGlass(cornerRadius: diameter / 2, interactive: true)
            // The glass circle keeps its diameter; the tappable area around it
            // grows to the 44pt minimum.
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }

    private var detailControlForeground: Color {
        colorScheme == .dark ? .white.opacity(0.92) : .black.opacity(0.78)
    }

    private var collectionTitleColor: Color {
        colorScheme == .dark ? .white : .primary
    }

    private var collectionSubtitleColor: Color {
        colorScheme == .dark ? .white.opacity(0.72) : .secondary
    }

    private var contrastSeparator: Color {
        colorScheme == .dark ? .white.opacity(0.10) : .black.opacity(0.12)
    }

    private var allowsMotion: Bool { motionEnabled }

    private var isArtist: Bool {
        if case .artist = route { return true }
        return false
    }

    private var currentArtistName: String? {
        guard case .artist(let artist) = route else { return nil }
        return artist.name
    }

    private var hasCurrentArtistMix: Bool {
        guard let currentArtistName else { return false }
        return ArtistMixPreferences.contains(
            currentArtistName,
            in: selectedArtistMixes
        )
    }

    private func toggleCurrentArtistMix() {
        guard let currentArtistName else { return }
        selectedArtistMixes = ArtistMixPreferences.toggling(
            currentArtistName,
            in: selectedArtistMixes
        )
    }

    private static func songRowLayout(
        for songs: [Song],
        route: MusicRoute
    ) -> SongRowLayout {
        switch route {
        case .artist:
            return .standard
        case .album:
            return songs.isEmpty ? .standard : .compactAlbum
        case .playlist:
            guard !songs.isEmpty else { return .standard }
            let firstAlbumID = songs.first?.albumId
            let firstAlbumName = songs.first?.album
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let isSingleAlbum = songs.allSatisfy { song in
                if let firstAlbumID, !firstAlbumID.isEmpty {
                    return song.albumId == firstAlbumID
                }
                guard let firstAlbumName, !firstAlbumName.isEmpty else { return false }
                return song.album.trimmingCharacters(in: .whitespacesAndNewlines) == firstAlbumName
            }
            let tracksWithNumbers = songs.reduce(into: 0) { count, song in
                if song.track != nil { count += 1 }
            }
            let enoughTrackMetadata = tracksWithNumbers >= max(1, (songs.count * 2) / 3)
            return isSingleAlbum && enoughTrackMetadata ? .compactAlbum : .standard
        }
    }

    private var canFavorite: Bool {
        switch route {
        case .album, .artist: true
        case .playlist: false
        }
    }

    private func downloadAll() {
        guard !songs.isEmpty, downloadAllTask == nil else { return }
        let items = songs
        isDownloadingAll = true
        downloadAllTask = Task {
            defer {
                downloadAllTask = nil
                isDownloadingAll = false
            }
            // The offline URLSession intentionally serializes transfers so an
            // album download cannot starve active lossless playback.
            let maxConcurrent = 1
            await withTaskGroup(of: Void.self) { group in
                var iterator = items.makeIterator()

                func addNext() {
                    guard !Task.isCancelled, let song = iterator.next() else { return }
                    group.addTask { await model.download(song) }
                }

                for _ in 0..<maxConcurrent { addNext() }
                while await group.next() != nil {
                    addNext()
                }
            }
        }
    }

    /// `.task(id: route)`는 라우트가 바뀌면 이전 로드 작업을 자동으로 취소한다.
    /// 취소된 작업이 뒤늦게 catch 블록까지 도달하면 "정상적인 실패"처럼
    /// `model.errorMessage`를 띄우거나, 새 라우트가 이미 로딩을 시작한 뒤에
    /// `isLoading = false`를 덮어써서 스피너가 너무 일찍 사라지는 문제가 있었다.
    /// 그래서 취소된 경우에는 상태를 건드리지 않고 바로 리턴한다.
    @MainActor
    private func load() async {
        let loadingRoute = route
        isLoading = true
        loadError = nil
        palette = .fallback
        title = ""
        subtitle = ""
        coverArt = nil
        albums = []
        songs = []
        songRowLayout = .standard
        artistBiography = ""
        artistAlbumCount = 0
        discography = .empty
        do {
            switch route {
            case .album(let album):
                title = album.name
                subtitle = [
                    String(localized: "앨범"),
                    album.artist,
                    album.year.map(String.init)
                ]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
                coverArt = album.coverArt
                let detail = try await model.album(id: album.id)
                guard !Task.isCancelled, route == loadingRoute else { return }
                if let canonical = detail.album, canonical.id == album.id {
                    title = canonical.name
                    subtitle = [
                        String(localized: "앨범"),
                        canonical.artist,
                        canonical.year.map(String.init)
                    ]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: " · ")
                    coverArt = canonical.coverArt
                }
                songs = detail.songs
                songRowLayout = Self.songRowLayout(for: detail.songs, route: route)
            case .playlist(let playlist):
                title = playlist.name
                subtitle = [
                    String(localized: "플레이리스트"),
                    playlist.owner,
                    playlist.songCount.map {
                        String(format: String(localized: "%d곡"), $0)
                    }
                ]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
                coverArt = playlist.coverArt
                let detail = try await model.playlist(id: playlist.id)
                guard !Task.isCancelled, route == loadingRoute else { return }
                if let canonical = detail.playlist,
                   canonical.id == playlist.id {
                    title = canonical.name
                    subtitle = [
                        String(localized: "플레이리스트"),
                        canonical.owner,
                        canonical.songCount.map {
                            String(format: String(localized: "%d곡"), $0)
                        }
                    ]
                        .compactMap { $0 }
                        .filter { !$0.isEmpty }
                        .joined(separator: " · ")
                    coverArt = canonical.coverArt
                }
                songs = detail.songs
                songRowLayout = Self.songRowLayout(for: detail.songs, route: route)
            case .artist(let artist):
                title = artist.name
                subtitle = String(localized: "아티스트")
                coverArt = artist.coverArt
                artistAlbumCount = artist.albumCount ?? 0
                let detail = try await model.artist(id: artist.id, name: artist.name)
                guard !Task.isCancelled, route == loadingRoute else { return }
                coverArt = detail.artist.coverArt ?? coverArt
                songs = detail.topSongs
                songRowLayout = Self.songRowLayout(for: detail.topSongs, route: route)
                albums = detail.albums
                artistAlbumCount = detail.artist.albumCount ?? detail.albums.count
                let preparedArtistContent = await ArtistDetailPresentation.make(
                    biography: detail.info?.biography ?? "",
                    albums: detail.albums
                )
                guard !Task.isCancelled, route == loadingRoute else { return }
                artistBiography = preparedArtistContent.biography
                discography = preparedArtistContent.discography
            }
        } catch {
            guard !Task.isCancelled, route == loadingRoute else { return }
            loadError = error.localizedDescription
            withAnimation(allowsMotion ? BuFiMotion.reveal : .none) {
                isLoading = false
            }
            return
        }
        guard !Task.isCancelled, route == loadingRoute else { return }
        withAnimation(allowsMotion ? BuFiMotion.reveal : .none) {
            isLoading = false
        }
        await prefetchDetailArtwork()
    }

    private func prefetchDetailArtwork() async {
        var seen = Set<String>()
        var coverIDs: [String] = []
        func append(_ value: String?) {
            guard let value, !value.isEmpty, seen.insert(value).inserted else { return }
            coverIDs.append(value)
        }
        append(coverArt)
        albums.prefix(8).forEach { append($0.coverArt) }
        songs.prefix(8).forEach { append($0.artworkID) }
        guard !coverIDs.isEmpty else { return }

        let pixelSize = ArtworkRequestSizing.pixelSize(
            pointSize: 166,
            displayScale: 3
        )
        var urls: [URL] = []
        await withTaskGroup(of: URL?.self) { group in
            for id in coverIDs.prefix(8) {
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    guard let url = await model.artworkURL(
                        id: id,
                        size: ArtworkRequestSizing.serverRequestSize(for: pixelSize)
                    ) else { return nil }
                    return ArtworkStore.cacheURL(for: url, revision: nil)
                }
            }
            for await url in group {
                if let url {
                    urls.append(url)
                }
            }
        }
        await ArtworkStore.shared.prefetch(urls: urls, pixelSize: pixelSize)
    }

    private func receivePalette(
        _ nextPalette: ArtworkPalette,
        for identity: MusicDetailArtworkIdentity
    ) {
        guard identity.route == route,
              identity.coverArtID == coverArt else { return }
        withAnimation(allowsMotion ? BuFiMotion.color : .none) {
            palette = nextPalette
        }
    }
}

struct MusicDetailArtworkIdentity: Hashable, Sendable {
    let route: MusicRoute
    let coverArtID: String?

    var cacheRevision: String {
        switch route {
        case .album(let album):
            "album-\(album.id)-\(coverArtID ?? "")"
        case .artist(let artist):
            "artist-\(artist.id)-\(coverArtID ?? "")"
        case .playlist(let playlist):
            "playlist-\(playlist.id)-\(coverArtID ?? "")"
        }
    }
}

/// The two hero labels animate as a pair, keyed on what is actually rendered.
private struct MusicDetailHeroText: Equatable {
    let title: String
    let detail: String
}

private struct ArtistDetailPresentation: Sendable {
    let biography: String
    let discography: ArtistDiscographyPresentation

    @concurrent
    static func make(
        biography: String,
        albums: [Album]
    ) async -> ArtistDetailPresentation {
        guard !Task.isCancelled else {
            return ArtistDetailPresentation(
                biography: "",
                discography: .empty
            )
        }
        let value = ArtistDetailPresentation(
            biography: ArtistBiographySanitizer.sanitize(biography),
            discography: ArtistDiscographyPresentation.make(albums)
        )
        if Task.isCancelled {
            return ArtistDetailPresentation(
                biography: "",
                discography: .empty
            )
        }
        return value
    }
}

enum ArtistBiographySanitizer {
    static func sanitize(_ biography: String) -> String {
        biography
            .replacingOccurrences(
                of: "<[^>]+>",
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum ArtistReleaseGroup: Hashable {
    case album
    case ep
    case single
}

private struct ArtistDiscographyPresentation: Sendable {
    let fullAlbums: [Album]
    let epAlbums: [Album]
    let singleAlbums: [Album]

    static let empty = ArtistDiscographyPresentation(
        fullAlbums: [],
        epAlbums: [],
        singleAlbums: []
    )

    static func make(_ albums: [Album]) -> ArtistDiscographyPresentation {
        var grouped: [ArtistReleaseGroup: [Album]] = [:]
        for album in albums {
            grouped[releaseGroup(for: album), default: []].append(album)
        }
        for key in [ArtistReleaseGroup.album, .ep, .single] {
            grouped[key]?.sort {
                if $0.year != $1.year { return ($0.year ?? 0) > ($1.year ?? 0) }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
        return ArtistDiscographyPresentation(
            fullAlbums: grouped[.album] ?? [],
            epAlbums: grouped[.ep] ?? [],
            singleAlbums: grouped[.single] ?? []
        )
    }

    private static func releaseGroup(for album: Album) -> ArtistReleaseGroup {
        let types = (album.releaseTypes ?? []).map {
            $0.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
        }
        if types.contains(where: { $0 == "single" || $0.contains("single") }) {
            return .single
        }
        if types.contains(where: { $0 == "ep" || $0.contains("extended play") }) {
            return .ep
        }
        let name = album.name.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasSuffix(" - single") || name.hasSuffix(" (single)")
            || name.hasSuffix(" [single]") {
            return .single
        }
        if name.hasSuffix(" - ep") || name.hasSuffix(" (ep)")
            || name.hasSuffix(" [ep]") {
            return .ep
        }
        return .album
    }
}

private struct SongActionsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let song: Song
    private let audio = AudioEngine.shared

    var body: some View {
        VStack(spacing: 4) {
            Capsule()
                .fill(.secondary.opacity(0.45))
                .frame(width: 38, height: 5)
                .padding(.top, 8)
                .padding(.bottom, 9)

            HStack(spacing: 12) {
                ArtworkView(coverArt: song.coverArt, size: 54, cornerRadius: 5)
                    .frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 4) {
                    Text(song.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                    Text(song.artist).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 7)

            action(
                model.isStarred(song) ? "좋아요 취소" : "좋아요 표시",
                icon: model.isStarred(song) ? "heart.slash" : "heart"
            ) {
                Task { await model.toggleStar(song: song) }
                dismiss()
            }
            action("오프라인 저장", icon: "arrow.down.circle") {
                Task { await model.download(song) }
                dismiss()
            }
            action("다음에 재생", icon: "text.line.first.and.arrowtriangle.forward") {
                audio.enqueueNext(song)
                dismiss()
            }
            action("대기목록에 추가", icon: "text.badge.plus") {
                audio.enqueue(song)
                dismiss()
            }
            action("지금 재생", icon: "play.fill") {
                audio.play(song, in: [song])
                dismiss()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func action(_ title: String, icon: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            Label {
                Text(LocalizedStringKey(title))
            } icon: {
                Image(systemName: icon)
            }
                .font(.system(size: 16, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 44)
                .padding(.horizontal, 18)
        }
        .buttonStyle(BuFiPressStyle())
    }
}
