import SwiftUI
import UIKit

struct PlayerArtworkPageID: Hashable, Sendable {
    let queueIndex: Int
    let songID: String
    let coverArtID: String?
}

struct PlayerArtworkPagerPage: Identifiable {
    let id: PlayerArtworkPageID
    let song: Song
}

struct PlayerArtworkPagerSnapshot {
    let pages: [PlayerArtworkPagerPage]
    let currentPage: PlayerArtworkPageID

    static func make(
        currentSong: Song,
        queue: [Song],
        queueIndex: Int
    ) -> PlayerArtworkPagerSnapshot {
        let resolvedIndex: Int?
        if queue.indices.contains(queueIndex),
           visuallyMatches(queue[queueIndex], currentSong) {
            resolvedIndex = queueIndex
        } else {
            resolvedIndex = queue.firstIndex {
                visuallyMatches($0, currentSong)
            }
        }

        guard let resolvedIndex else {
            let fallback = PlayerArtworkPageID(
                queueIndex: -1,
                songID: currentSong.id,
                coverArtID: currentSong.artworkID
            )
            return PlayerArtworkPagerSnapshot(
                pages: [PlayerArtworkPagerPage(id: fallback, song: currentSong)],
                currentPage: fallback
            )
        }

        let pages = queue.indices.map { index in
            PlayerArtworkPagerPage(
                id: PlayerArtworkPageID(
                    queueIndex: index,
                    songID: queue[index].id,
                    coverArtID: queue[index].artworkID
                ),
                song: queue[index]
            )
        }
        return PlayerArtworkPagerSnapshot(
            pages: pages,
            currentPage: pages[resolvedIndex].id
        )
    }

    private static func visuallyMatches(_ lhs: Song, _ rhs: Song) -> Bool {
        lhs.id == rhs.id && lhs.artworkID == rhs.artworkID
    }
}

struct PlayerView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var library: HomeLibraryState
    @EnvironmentObject private var favoriteOverrides: FavoriteOverrideState
    @EnvironmentObject private var audio: AudioEngine
    @EnvironmentObject private var playbackItem: PlaybackItemState
    @EnvironmentObject private var playbackQueue: PlaybackQueueState
    @EnvironmentObject private var playerPresentation: PlayerPresentationState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.buFiMotionEnabled) private var motionEnabled

    @State private var palette = ArtworkPalette.fallback
    @State private var showQueue = false
    @State private var artworkPage: PlayerArtworkPageID?
    @State private var pendingUserArtworkPage: PlayerArtworkPageID?
    @State private var pagerSelectionGate = PlayerPagerSelectionGate()
    @State private var artworkPalettes: [PlayerArtworkPageID: ArtworkPalette] = [:]
    @State private var transitionDirection: CGFloat = 1
    @State private var artworkPrefetchTask: Task<Void, Never>?
    @AppStorage("player-seekbar-appearance")
    private var playerAppearance = PlayerAppearance.liquidGlass.rawValue
    @AppStorage("player-background-appearance")
    private var playerBackgroundAppearance = PlayerBackgroundAppearance.classic.rawValue

    init(initialArtworkPage: PlayerArtworkPageID? = nil) {
        _artworkPage = State(initialValue: initialArtworkPage)
    }

    var body: some View {
        let _ = favoriteOverrides.values
        GeometryReader { proxy in
            ZStack {
                background

                if let song = playbackItem.currentSong {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            header(song)
                            if resolvedPlayerAppearance == .dynamic {
                                dynamicPlayer(
                                    song,
                                    availableWidth: proxy.size.width,
                                    availableHeight: proxy.size.height
                                )
                            } else {
                                nowPlayingPager(
                                    song,
                                    availableWidth: proxy.size.width,
                                    availableHeight: proxy.size.height
                                )
                                progress
                                transport
                                utilityRow(song)
                            }
                            PlayerLyricsCard(
                                lyricsState: audio.lyricsState,
                                song: song,
                                primary: playerPrimary,
                                secondary: playerSecondary
                            ) {
                                audio.showFullLyrics = true
                            }
                        }
                        .padding(.horizontal, 22)
                        .padding(.bottom, max(proxy.safeAreaInsets.bottom, 18) + 10)
                    }
                    .opacity(playerPresentation.showFullLyrics ? 0 : 1)
                    .allowsHitTesting(!playerPresentation.showFullLyrics)
                    .accessibilityHidden(playerPresentation.showFullLyrics)
                } else {
                    ContentUnavailableView("재생 중인 곡이 없습니다", systemImage: "music.note")
                }

                if playerPresentation.showFullLyrics {
                    FullLyricsView(
                        palette: palette,
                        seekBarAppearance: resolvedSeekBarAppearance,
                        backgroundAppearance: resolvedBackgroundAppearance,
                        lyricsState: audio.lyricsState
                    )
                        .environmentObject(audio)
                        .transition(.opacity)
                        .zIndex(20)
                }
            }
            .animation(allowsMotion ? BuFiMotion.lyricsPanel : .none, value: playerPresentation.showFullLyrics)
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showQueue) {
            QueueView()
                .environmentObject(audio)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: playbackQueue.index) { oldIndex, index in
            transitionDirection = index >= oldIndex ? 1 : -1
            // Keep a user's selected page visible until currentSong confirms
            // the transition instead of snapping back during synchronization.
            if pendingUserArtworkPage?.queueIndex != index {
                pendingUserArtworkPage = nil
                applyCachedPalette(at: index)
                syncArtworkPage(to: index, animated: true)
            }
            prefetchUpcomingArtwork(after: index)
        }
        .onChange(of: playbackItem.currentSong.map { [$0.id, $0.artworkID ?? ""] }) { _, _ in
            // Queue and current-item state are published independently. Always
            // re-anchor the pager when the visual now-playing identity changes.
            pendingUserArtworkPage = nil
            syncArtworkPage(to: playbackQueue.index, animated: false)
            applyCachedPalette(at: playbackQueue.index)
        }
        .onChange(of: playbackQueue.songs.map { [$0.id, $0.artworkID ?? ""] }) { _, _ in
            pruneArtworkPalettes()
            let pendingPageIsStillValid: Bool
            if let pendingPage = pendingUserArtworkPage,
               playbackQueue.songs.indices.contains(pendingPage.queueIndex) {
                let pendingSong = playbackQueue.songs[pendingPage.queueIndex]
                pendingPageIsStillValid = pendingSong.id == pendingPage.songID
                    && pendingSong.artworkID == pendingPage.coverArtID
            } else {
                pendingPageIsStillValid = false
            }
            if !pendingPageIsStillValid {
                // Preserve a valid in-flight swipe until currentSong is
                // published, but discard it after a real queue replacement.
                pendingUserArtworkPage = nil
                syncArtworkPage(to: playbackQueue.index, animated: false)
            }
            prefetchUpcomingArtwork(after: playbackQueue.index)
        }
        .onAppear {
            applyCachedPalette(at: playbackQueue.index)
            syncArtworkPage(to: playbackQueue.index, animated: false)
            prefetchUpcomingArtwork(after: playbackQueue.index)
        }
        .onDisappear {
            artworkPrefetchTask?.cancel()
            artworkPrefetchTask = nil
        }
    }

    private var background: some View {
        PlayerPaletteBackground(
            palette: palette,
            playerAppearance: resolvedPlayerAppearance,
            appearance: resolvedBackgroundAppearance,
            colorScheme: colorScheme
        )
        .equatable()
        .ignoresSafeArea()
        .animation(allowsMotion ? BuFiMotion.color : .none, value: palette)
        .animation(allowsMotion ? BuFiMotion.color : .none, value: resolvedBackgroundAppearance)
    }

    private func header(_ song: Song) -> some View {
        HStack {
            Button {
                audio.showPlayer = false
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("플레이어 닫기")

            Spacer()
            ZStack {
                VStack(spacing: 2) {
                    Text(song.album.isEmpty ? String(localized: "지금 재생 중") : song.album)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(song.artist)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(playerSecondary)
                        .lineLimit(1)
                }
                .id(song.id)
                .transition(trackTextTransition)
            }
            .frame(maxWidth: 240)
            .animation(allowsMotion ? BuFiMotion.trackText : .none, value: song.id)
            Spacer()

            Menu {
                Button {
                    Task { await model.toggleStar(song: song) }
                } label: {
                    Label(
                        model.isStarred(song)
                            ? String(localized: "좋아요 취소")
                            : String(localized: "좋아요 표시"),
                        systemImage: "heart"
                    )
                }
                Button {
                    Task { await model.download(song) }
                } label: {
                    Label("오프라인 저장", systemImage: "arrow.down.circle")
                }
                Button {
                    audio.enqueueNext(song)
                } label: {
                    Label(
                        "다음에 재생",
                        systemImage: "text.line.first.and.arrowtriangle.forward"
                    )
                }
                Button {
                    audio.enqueue(song)
                } label: {
                    Label("대기목록에 추가", systemImage: "text.badge.plus")
                }
                Button {
                    Task { await model.playRadio(from: song) }
                } label: {
                    Label("곡으로 라디오 시작", systemImage: "dot.radiowaves.left.and.right")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("더 보기")
        }
        .buttonStyle(.plain)
        .foregroundStyle(playerPrimary)
        .frame(height: 58)
    }

    private func nowPlayingPager(_ song: Song, availableWidth: CGFloat, availableHeight: CGFloat) -> some View {
        let viewportWidth = max(240, availableWidth - 44)
        let edge = max(220, min(viewportWidth, max(264, availableHeight * 0.47)))

        return VStack(spacing: 0) {
            artworkPager(
                song,
                availableWidth: availableWidth,
                availableHeight: availableHeight,
                heightPadding: 42
            )

            metadataContent(song)
                .padding(.bottom, 18)
        }
        .frame(height: edge + 116)
        .contentShape(Rectangle())
    }

    private func metadataContent(_ song: Song) -> some View {
        HStack(spacing: 14) {
            ZStack(alignment: .leading) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(song.title)
                        .font(.system(size: 25, weight: .bold))
                        .tracking(-0.7)
                        .lineLimit(1)
                    if let route = artistRoute(for: song) {
                        NavigationLink(value: route) {
                            HStack(spacing: 5) {
                                Text(song.artist).lineLimit(1)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(playerSecondary)
                        }
                        .buttonStyle(BuFiPressStyle())
                        .accessibilityLabel(String(format: String(localized: "%@ 아티스트 페이지 열기"), song.artist))
                    } else {
                        Text(song.artist)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(playerSecondary)
                            .lineLimit(1)
                    }
                }
                .id(song.id)
                .transition(trackTextTransition)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(allowsMotion ? BuFiMotion.trackText : .none, value: song.id)
            Spacer(minLength: 4)
            Button {
                Task { await model.toggleStar(song: song) }
            } label: {
                Image(systemName: model.isStarred(song) ? "heart.fill" : "heart")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(model.isStarred(song) ? BuFiTheme.accent : playerPrimary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(BuFiPressStyle())
            .accessibilityLabel(model.isStarred(song) ? "좋아요 취소" : "좋아요 표시")
        }
    }

    private func dynamicPlayer(
        _ song: Song,
        availableWidth: CGFloat,
        availableHeight: CGFloat
    ) -> some View {
        VStack(spacing: 10) {
            dynamicArtworkPager(
                song,
                availableWidth: availableWidth,
                availableHeight: availableHeight
            )

            VStack(spacing: 2) {
                dynamicMetadataContent(song)
                    .padding(.bottom, 4)
                progress
                    .padding(.horizontal, 2)
                dynamicTransport
                utilityRow(song, includesAirPlay: false, compact: true)
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .background {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Color.white.opacity(0.24))
                    .overlay {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .stroke(.white.opacity(0.30), lineWidth: 0.8)
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .buFiGlass(cornerRadius: 26, interactive: true)
        }
        .padding(.bottom, 6)
    }

    private func dynamicArtworkPager(
        _ song: Song,
        availableWidth: CGFloat,
        availableHeight: CGFloat
    ) -> some View {
        artworkPager(
            song,
            availableWidth: availableWidth,
            availableHeight: availableHeight,
            heightPadding: 26
        )
    }

    private func artworkPager(
        _ song: Song,
        availableWidth: CGFloat,
        availableHeight: CGFloat,
        heightPadding: CGFloat
    ) -> some View {
        let viewportWidth = max(240, availableWidth - 44)
        let edge = max(220, min(viewportWidth, max(264, availableHeight * 0.47)))
        let sideInset = max(0, (viewportWidth - edge) / 2)
        let snapshot = PlayerArtworkPagerSnapshot.make(
            currentSong: song,
            queue: playbackQueue.songs,
            queueIndex: playbackQueue.index
        )
        let pagerPosition = Binding<PlayerArtworkPageID?>(
            get: { artworkPage },
            set: { page in
                if page != artworkPage,
                   pagerSelectionGate.programmaticDestination == nil {
                    // The binding setter runs before the next body pass, so an
                    // intentional swipe cannot be covered for one frame by the
                    // current-song mismatch overlay.
                    pendingUserArtworkPage = page
                }
                artworkPage = page
            }
        )
        let animatesTransition = allowsMotion

        return ZStack {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 18) {
                    ForEach(snapshot.pages) { page in
                        ArtworkView(
                            coverArt: page.song.artworkID,
                            size: edge,
                            cornerRadius: 14,
                            onPalette: { nextPalette in
                                receivePalette(
                                    nextPalette,
                                    for: page.id
                                )
                            }
                        )
                        .frame(width: edge, height: edge)
                        .id(page.id)
                        .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                            content
                                .scaleEffect(phase.isIdentity || !animatesTransition ? 1 : 0.97)
                                .opacity(phase.isIdentity || !animatesTransition ? 1 : 0.86)
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .contentMargins(.horizontal, sideInset, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: pagerPosition, anchor: .center)
            .simultaneousGesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { _ in
                        pagerSelectionGate.beginUserInteraction()
                    }
            )

            if artworkPage != snapshot.currentPage,
               artworkPage != pendingUserArtworkPage {
                ArtworkView(
                    coverArt: song.artworkID,
                    size: edge,
                    cornerRadius: 14,
                    onPalette: { nextPalette in
                        receiveCurrentPalette(
                            nextPalette,
                            for: snapshot.currentPage,
                            song: song
                        )
                    }
                )
                .frame(width: edge, height: edge)
                .id("active-\(song.id)-\(song.artworkID ?? "")")
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .frame(height: edge + heightPadding)
        .contentShape(Rectangle())
        .onChange(of: artworkPage) { oldPage, page in
            guard pagerSelectionGate.shouldStartPlayback(for: page) else { return }
            guard let page,
                  playbackQueue.songs.indices.contains(page.queueIndex),
                  playbackQueue.songs[page.queueIndex].id == page.songID,
                  playbackQueue.songs[page.queueIndex].artworkID == page.coverArtID else {
                return
            }
            let index = page.queueIndex
            let oldIndex = oldPage?.queueIndex ?? playbackQueue.index
            transitionDirection = index >= oldIndex ? 1 : -1
            guard index != playbackQueue.index,
                  playbackQueue.songs.indices.contains(index) else { return }
            pendingUserArtworkPage = page
            audio.playQueueItem(at: index)
        }
    }

    private func dynamicMetadataContent(_ song: Song) -> some View {
        ZStack {
            VStack(spacing: 4) {
                Text(song.title)
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.55)
                    .lineLimit(1)
                Text(song.artist)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(playerSecondary)
                    .lineLimit(1)
            }
            .id(song.id)
            .transition(trackTextTransition)
            .padding(.horizontal, 52)
            .animation(allowsMotion ? BuFiMotion.trackText : .none, value: song.id)

            HStack {
                Spacer()
                Button {
                    Task { await model.toggleStar(song: song) }
                } label: {
                    Image(systemName: model.isStarred(song) ? "heart.fill" : "heart")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(model.isStarred(song) ? BuFiTheme.accent : playerPrimary)
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(BuFiPressStyle())
                .accessibilityLabel(model.isStarred(song) ? "좋아요 취소" : "좋아요 표시")
            }
        }
    }

    private var progress: some View {
        PlayerProgressView(
            timeline: audio.timeline,
            appearance: resolvedSeekBarAppearance,
            tint: playerPrimary,
            secondary: playerSecondary
        )
        .environmentObject(audio)
    }

    private var transport: some View {
        transportControls(compact: false)
    }

    private var dynamicTransport: some View {
        transportControls(compact: true)
    }

    private func transportControls(compact: Bool) -> some View {
        HStack {
            control(
                "shuffle",
                size: compact ? 21 : 24,
                active: audio.isShuffleEnabled,
                label: "셔플"
            ) {
                audio.toggleShuffle()
            }
            Spacer()
            control(
                "backward.end.fill",
                size: compact ? 28 : 31,
                label: "이전 곡"
            ) {
                audio.previous()
            }
            Spacer()
            PlayerPlaybackButton(
                diameter: compact ? 62 : 70,
                iconSize: compact ? 24 : 27,
                foreground: playerPrimary,
                buttonForeground: playerButtonForeground,
                motionEnabled: allowsMotion
            ) {
                audio.togglePlayback()
            }
            Spacer()
            control(
                "forward.end.fill",
                size: compact ? 28 : 31,
                label: "다음 곡"
            ) {
                audio.next()
            }
            Spacer()
            control(
                audio.repeatMode == .one ? "repeat.1" : "repeat",
                size: compact ? 21 : 24,
                active: audio.repeatMode != .off,
                label: "반복"
            ) {
                audio.cycleRepeat()
            }
        }
        .frame(height: compact ? 82 : 112)
    }

    private func utilityRow(
        _ song: Song,
        includesAirPlay: Bool = true,
        compact: Bool = false
    ) -> some View {
        let itemSize: CGFloat = compact ? 34 : 40
        let shareSize: CGFloat = compact ? 20 : 22
        let queueSize: CGFloat = compact ? 21 : 23

        return HStack(spacing: compact ? 18 : 25) {
            if includesAirPlay {
                AirPlayButton(lightContent: !usesDarkForeground)
                    .frame(width: 32, height: 32)
                    .accessibilityLabel("AirPlay")
            }
            Spacer()
            ShareLink(item: "\(song.title) — \(song.artist)") {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: shareSize, weight: .medium))
                    .frame(width: itemSize, height: itemSize)
            }
            Button {
                showQueue = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: queueSize, weight: .medium))
                    .frame(width: itemSize, height: itemSize)
            }
            .accessibilityLabel("재생목록")
        }
        .buttonStyle(.plain)
        .foregroundStyle(playerPrimary)
        .padding(.vertical, compact ? 0 : 8)
    }


    private func control(
        _ icon: String,
        size: CGFloat,
        active: Bool = false,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack(alignment: .bottom) {
                Image(systemName: icon)
                    .font(.system(size: size, weight: .semibold))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(active ? BuFiTheme.accent : playerPrimary)
                    .frame(width: 48, height: 48)
                    .contentTransition(.symbolEffect(.replace))
                if active {
                    Circle()
                        .fill(BuFiTheme.accentSoft)
                        .frame(width: 4, height: 4)
                        .offset(y: 2)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .buttonStyle(BuFiPressStyle())
        .animation(allowsMotion ? BuFiMotion.tap : .none, value: active)
        .accessibilityLabel(label)
    }

    private func artistRoute(for song: Song) -> MusicRoute? {
        let artists = library.snapshot.starredArtists + library.snapshot.artists
        if let artistID = song.artistId {
            let artist = artists.first(where: { $0.id == artistID }) ?? Artist(
                id: artistID,
                name: song.artist,
                coverArt: nil,
                albumCount: nil,
                starred: nil
            )
            return .artist(artist)
        }
        guard let artist = artists.first(where: {
            $0.name.localizedCaseInsensitiveCompare(song.artist) == .orderedSame
        }) else {
            return nil
        }
        return .artist(artist)
    }

    private func syncArtworkPage(to index: Int, animated: Bool) {
        guard let currentSong = playbackItem.currentSong else {
            artworkPage = nil
            pendingUserArtworkPage = nil
            palette = .fallback
            return
        }
        let page = PlayerArtworkPagerSnapshot.make(
            currentSong: currentSong,
            queue: playbackQueue.songs,
            queueIndex: index
        ).currentPage
        guard pagerSelectionGate.prepareProgrammaticChange(
            from: artworkPage,
            to: page
        ) else { return }
        if animated && allowsMotion {
            withAnimation(BuFiMotion.trackPage) {
                artworkPage = page
            }
        } else {
            artworkPage = page
        }
    }

    private func receivePalette(
        _ nextPalette: ArtworkPalette,
        for page: PlayerArtworkPageID
    ) {
        artworkPalettes[page] = nextPalette
        guard page == artworkPage,
              page == pendingUserArtworkPage || page == currentVisualArtworkPage else {
            return
        }
        if palette != nextPalette {
            palette = nextPalette
        }
    }

    private var currentVisualArtworkPage: PlayerArtworkPageID? {
        guard let currentSong = playbackItem.currentSong else { return nil }
        return PlayerArtworkPagerSnapshot.make(
            currentSong: currentSong,
            queue: playbackQueue.songs,
            queueIndex: playbackQueue.index
        ).currentPage
    }

    private func receiveCurrentPalette(
        _ nextPalette: ArtworkPalette,
        for page: PlayerArtworkPageID,
        song: Song
    ) {
        artworkPalettes[page] = nextPalette
        guard playbackItem.currentSong?.id == song.id,
              playbackItem.currentSong?.artworkID == song.artworkID else {
            return
        }
        if palette != nextPalette {
            palette = nextPalette
        }
    }

    private func applyCachedPalette(at index: Int) {
        guard let currentSong = playbackItem.currentSong else {
            palette = .fallback
            return
        }

        let page = PlayerArtworkPagerSnapshot.make(
            currentSong: currentSong,
            queue: playbackQueue.songs,
            queueIndex: index
        ).currentPage
        if let cached = artworkPalettes[page] {
            if palette != cached { palette = cached }
        } else if palette != .fallback {
            palette = .fallback
        }
    }

    private func pruneArtworkPalettes() {
        var activePages = Set(playbackQueue.songs.indices.map {
            PlayerArtworkPageID(
                queueIndex: $0,
                songID: playbackQueue.songs[$0].id,
                coverArtID: playbackQueue.songs[$0].artworkID
            )
        })
        if let currentSong = playbackItem.currentSong {
            activePages.insert(
                PlayerArtworkPagerSnapshot.make(
                    currentSong: currentSong,
                    queue: playbackQueue.songs,
                    queueIndex: playbackQueue.index
                ).currentPage
            )
        }
        artworkPalettes = artworkPalettes.filter { activePages.contains($0.key) }
    }

    private func prefetchUpcomingArtwork(after index: Int) {
        artworkPrefetchTask?.cancel()
        let thermalState = ProcessInfo.processInfo.thermalState
        guard !playbackQueue.songs.isEmpty,
              !ProcessInfo.processInfo.isLowPowerModeEnabled,
              thermalState != .serious,
              thermalState != .critical else {
            artworkPrefetchTask = nil
            return
        }
        let start = max(index + 1, 0)
        // Warming one successor's artwork data and palette is enough to hide a
        // normal track transition. Fetching two large covers keeps the network
        // radio and image decoder active longer without improving the
        // immediately visible animation.
        let end = min(playbackQueue.songs.count, start + 1)
        guard start < end else {
            artworkPrefetchTask = nil
            return
        }
        let upcoming = (start..<end).map { index in
            (
                page: PlayerArtworkPageID(
                    queueIndex: index,
                    songID: playbackQueue.songs[index].id,
                    coverArtID: playbackQueue.songs[index].artworkID
                ),
                song: playbackQueue.songs[index]
            )
        }

        artworkPrefetchTask = Task(priority: .utility) {
            for item in upcoming {
                guard !Task.isCancelled,
                      let url = await model.artworkURL(id: item.song.artworkID, size: 600) else {
                    continue
                }
                guard let image = try? await ArtworkStore.shared.image(
                    for: url,
                    pixelSize: 600
                ) else {
                    continue
                }
                let nextPalette = await ArtworkStore.shared.palette(
                    for: url,
                    image: image
                )
                guard !Task.isCancelled,
                      playbackQueue.songs.indices.contains(item.page.queueIndex),
                      playbackQueue.songs[item.page.queueIndex].id == item.page.songID,
                      playbackQueue.songs[item.page.queueIndex].artworkID == item.page.coverArtID else {
                    return
                }
                artworkPalettes[item.page] = nextPalette
            }
        }
    }

    private var resolvedSeekBarAppearance: PlayerSeekBarAppearance {
        resolvedPlayerAppearance.seekBarAppearance
    }

    private var resolvedPlayerAppearance: PlayerAppearance {
        PlayerAppearance.resolved(playerAppearance)
    }

    private var resolvedBackgroundAppearance: PlayerBackgroundAppearance {
        PlayerBackgroundAppearance.resolved(playerBackgroundAppearance)
    }

    private var trackTextTransition: AnyTransition {
        guard allowsMotion else { return .opacity }
        let distance: CGFloat = 10
        return .asymmetric(
            insertion: .offset(
                x: transitionDirection > 0 ? distance : -distance
            ).combined(with: .opacity),
            removal: .offset(
                x: transitionDirection > 0 ? -distance : distance
            ).combined(with: .opacity)
        )
    }

    private var allowsMotion: Bool { motionEnabled }

    private var usesDarkForeground: Bool {
        switch resolvedBackgroundAppearance {
        case .classic:
            colorScheme == .light
        case .multicolor:
            colorScheme == .light || palettePrefersDarkForeground(palette)
        case .bright:
            true
        }
    }

    private var playerPrimary: Color {
        usesDarkForeground ? .black.opacity(0.86) : .white
    }

    private var playerSecondary: Color {
        playerPrimary.opacity(0.64)
    }

    private var playerButtonForeground: Color {
        usesDarkForeground ? .white : Color(palette.bottom)
    }
}

struct PlayerPagerSelectionGate {
    private(set) var programmaticDestination: PlayerArtworkPageID?

    mutating func prepareProgrammaticChange(
        from current: PlayerArtworkPageID?,
        to destination: PlayerArtworkPageID
    ) -> Bool {
        guard current != destination else {
            if programmaticDestination != destination {
                programmaticDestination = nil
            }
            return false
        }
        programmaticDestination = destination
        return true
    }

    mutating func shouldStartPlayback(for selection: PlayerArtworkPageID?) -> Bool {
        if let programmaticDestination {
            if selection == programmaticDestination {
                self.programmaticDestination = nil
            }
            return false
        }
        return selection != nil
    }

    mutating func beginUserInteraction() {
        programmaticDestination = nil
    }
}

private struct PlayerPlaybackButton: View {
    @EnvironmentObject private var playbackControl: PlaybackControlState

    let diameter: CGFloat
    let iconSize: CGFloat
    let foreground: Color
    let buttonForeground: Color
    let motionEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(foreground)
                    .frame(width: diameter, height: diameter)
                if playbackControl.isBuffering {
                    ProgressView()
                        .tint(buttonForeground)
                } else {
                    Image(systemName: playbackControl.wantsPlayback ? "pause.fill" : "play.fill")
                        .font(.system(size: iconSize, weight: .bold))
                        .foregroundStyle(buttonForeground)
                        .offset(x: playbackControl.wantsPlayback ? 0 : 2)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
        }
        .buttonStyle(BuFiPressStyle())
        .animation(
            motionEnabled ? BuFiMotion.tap : .none,
            value: playbackControl.wantsPlayback
        )
        .accessibilityLabel(playbackControl.wantsPlayback ? "일시정지" : "재생")
    }
}

private struct PlayerProgressView: View {
    @ObservedObject var timeline: PlaybackTimeline
    @Environment(\.buFiMotionEnabled) private var motionEnabled

    let appearance: PlayerSeekBarAppearance
    let tint: Color
    let secondary: Color

    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false
    private let audio = AudioEngine.shared

    var body: some View {
        let duration = timeline.duration.isFinite ? max(0, timeline.duration) : 0
        let elapsed = displayedElapsed(duration: duration)
        let remaining = max(0, duration - elapsed)

        VStack(spacing: 0) {
            PlayerSeekBar(
                value: seekBinding(duration: duration),
                range: 0...max(duration, 1),
                appearance: appearance,
                tint: tint
            ) { editing in
                if editing, !isScrubbing {
                    scrubValue = elapsed
                }
                isScrubbing = editing
                if !editing {
                    audio.seek(to: min(scrubValue, duration))
                }
            }
            HStack {
                Text(elapsed.playbackText)
                Spacer()
                Text(duration > 0 ? "-\(remaining.playbackText)" : "--:--")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(secondary)
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(
                motionEnabled ? BuFiMotion.micro : .none,
                value: Int(elapsed)
            )
        }
    }

    private func displayedElapsed(duration: Double) -> Double {
        let raw = isScrubbing ? scrubValue : timeline.elapsed
        let finite = raw.isFinite ? raw : 0
        return min(max(0, finite), max(duration, 0))
    }

    private func seekBinding(duration: Double) -> Binding<Double> {
        Binding(
            get: { displayedElapsed(duration: duration) },
            set: { scrubValue = $0 }
        )
    }
}

private struct PlayerLyricsCard: View {
    @ObservedObject var lyricsState: LyricsPlaybackState
    @Environment(\.buFiMotionEnabled) private var motionEnabled

    let song: Song
    let primary: Color
    let secondary: Color
    let onOpen: () -> Void

    @ViewBuilder
    var body: some View {
        if !lyricsState.document.lines.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("가사")
                        .font(.system(size: 20, weight: .bold))
                    Spacer()
                    ShareLink(item: "\(song.title) — \(song.artist)") {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 38, height: 38)
                            .background(.black.opacity(0.22), in: Circle())
                    }
                    .accessibilityLabel("가사 공유")
                    Button(action: onOpen) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 38, height: 38)
                            .background(.black.opacity(0.22), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("전체 화면 가사")
                }

                Button(action: onOpen) {
                    miniLyricsWindow
                        .frame(maxWidth: .infinity)
                        .frame(height: 178, alignment: .top)
                        .clipped()
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .foregroundStyle(primary)
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [primary.opacity(0.19), primary.opacity(0.10)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .buFiGlass(cornerRadius: 24, interactive: true)
            .padding(.top, 10)
        } else {
            Text("이 곡에는 표시할 가사가 없습니다.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 18)
        }
    }

    private var miniLyricsWindow: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let activeLyric {
                ZStack(alignment: .topLeading) {
                    Text(activeLyric.line.text)
                        .font(.system(size: 20, weight: .bold))
                        .tracking(-0.40)
                        .foregroundStyle(primary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                        .id("\(song.id)-\(activeLyric.line.id)")
                        .transition(miniLyricsTransition)
                        .zIndex(1)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            ForEach(upcomingLyrics, id: \.line.id) { item in
                Text(item.line.text)
                    .font(.system(size: 20, weight: .bold))
                    .tracking(-0.40)
                    .foregroundStyle(lyricColor(for: item.index))
                    .scaleEffect(
                        motionEnabled ? 0.99 : 1,
                        anchor: .leading
                    )
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .clipped()
        .animation(
            motionEnabled ? BuFiMotion.miniLyrics : .none,
            value: lyricsState.activeIndex
        )
    }

    private var activeLyric: (index: Int, line: LyricLine)? {
        let lines = lyricsState.document.lines
        guard lines.indices.contains(lyricsState.activeIndex) else { return nil }
        let index = lyricsState.activeIndex
        return (index: index, line: lines[index])
    }

    private var upcomingLyrics: [(index: Int, line: LyricLine)] {
        let lines = lyricsState.document.lines
        let start = activeLyric.map { $0.index + 1 } ?? lines.startIndex
        let end = min(lines.endIndex, start + 6)
        guard start < end else { return [] }
        return (start..<end).map { (index: $0, line: lines[$0]) }
    }

    private func lyricColor(for index: Int) -> Color {
        if index == lyricsState.activeIndex { return primary }
        if index < lyricsState.activeIndex { return primary.opacity(0.28) }
        let distance = max(1, index - lyricsState.activeIndex)
        return primary.opacity(max(0.26, 0.62 - (Double(distance - 1) * 0.12)))
    }

    private var miniLyricsTransition: AnyTransition {
        guard motionEnabled else { return .opacity }
        return .asymmetric(
            insertion: .offset(y: 3).combined(with: .opacity),
            removal: .offset(y: -2).combined(with: .opacity)
        )
    }
}

private struct FullLyricsView: View {
    @EnvironmentObject private var playbackItem: PlaybackItemState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.buFiMotionEnabled) private var motionEnabled

    let palette: ArtworkPalette
    let seekBarAppearance: PlayerSeekBarAppearance
    let backgroundAppearance: PlayerBackgroundAppearance
    let lyricsState: LyricsPlaybackState

    @State private var dragOffset: CGFloat = 0
    private let audio = AudioEngine.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            lyrics
            footer
        }
        .offset(y: max(0, dragOffset))
        .scaleEffect(dragScale, anchor: .bottom)
        .opacity(dragOpacity)
    }

    private var header: some View {
        HStack {
            Button { closeLyrics() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 23, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            Spacer()
            VStack(spacing: 3) {
                Text(playbackItem.currentSong?.title ?? "가사")
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
                Text(playbackItem.currentSong?.artist ?? "")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(lyricsSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: 250)
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .foregroundStyle(lyricsPrimary)
        .contentShape(Rectangle())
        .simultaneousGesture(dismissGesture)
    }

    private var lyrics: some View {
        FullLyricsList(
            lyricsState: lyricsState,
            primary: lyricsPrimary
        ) { start in
            audio.seek(to: start)
        }
    }

    private var footer: some View {
        FullLyricsFooter(
            timeline: audio.timeline,
            seekBarAppearance: seekBarAppearance,
            primary: lyricsPrimary,
            secondary: lyricsSecondary,
            playButtonForeground: playButtonForeground
        )
        .environmentObject(audio)
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard value.translation.height > 0,
                      abs(value.translation.height) > abs(value.translation.width) else { return }
                dragOffset = value.translation.height * 0.72
            }
            .onEnded { value in
                let shouldDismiss = value.translation.height > 100 || value.predictedEndTranslation.height > 180
                if shouldDismiss {
                    closeLyrics()
                } else {
                    withAnimation(allowsMotion ? BuFiMotion.lyricsPanel : .none) {
                        dragOffset = 0
                    }
                }
            }
    }

    private func closeLyrics() {
        dragOffset = 0
        audio.showFullLyrics = false
    }

    private var dragProgress: CGFloat { min(max(dragOffset / 420, 0), 1) }
    private var dragScale: CGFloat { allowsMotion ? 1 - (dragProgress * 0.018) : 1 }
    private var dragOpacity: Double { allowsMotion ? 1 - Double(dragProgress * 0.08) : 1 }
    private var allowsMotion: Bool { motionEnabled }
    private var usesDarkForeground: Bool {
        switch backgroundAppearance {
        case .classic:
            colorScheme == .light
        case .multicolor:
            colorScheme == .light || palettePrefersDarkForeground(palette)
        case .bright:
            true
        }
    }
    private var lyricsPrimary: Color { usesDarkForeground ? .black.opacity(0.86) : .white }
    private var lyricsSecondary: Color { lyricsPrimary.opacity(0.66) }
    private var playButtonForeground: Color { usesDarkForeground ? .white : Color(palette.bottom) }
}

private struct FullLyricsList: View {
    @ObservedObject var lyricsState: LyricsPlaybackState
    @Environment(\.buFiMotionEnabled) private var motionEnabled
    @AppStorage("lyrics-auto-scroll") private var autoScroll = true

    let primary: Color
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 25) {
                    Color.clear.frame(height: 22)
                    ForEach(
                        lyricsState.document.lines.indices,
                        id: \.self
                    ) { index in
                        let line = lyricsState.document.lines[index]
                        Button {
                            if lyricsState.document.synced {
                                onSeek(line.start)
                            }
                        } label: {
                            Text(line.text)
                                .font(.system(size: 29, weight: .bold))
                                .tracking(-0.95)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(color(for: index))
                                .scaleEffect(
                                    motionEnabled
                                        ? (index == lyricsState.activeIndex ? 1.015 : 0.995)
                                        : 1,
                                    anchor: .leading
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(line.id)
                        .animation(
                            motionEnabled ? BuFiMotion.lyrics : .none,
                            value: index == lyricsState.activeIndex
                        )
                    }
                    Color.clear.frame(height: 180)
                }
                .padding(.horizontal, 24)
            }
            .onChange(of: lyricsState.activeIndex) { _, index in
                guard autoScroll,
                      lyricsState.document.lines.indices.contains(index) else {
                    return
                }
                withAnimation(motionEnabled ? BuFiMotion.lyrics : .none) {
                    proxy.scrollTo(
                        lyricsState.document.lines[index].id,
                        anchor: UnitPoint(x: 0.5, y: 0.42)
                    )
                }
            }
            .onAppear {
                if autoScroll {
                    scrollToCurrentLine(using: proxy)
                }
            }
        }
    }

    private func scrollToCurrentLine(using proxy: ScrollViewProxy) {
        let index = lyricsState.activeIndex
        guard lyricsState.document.lines.indices.contains(index) else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(
                lyricsState.document.lines[index].id,
                anchor: UnitPoint(x: 0.5, y: 0.42)
            )
        }
    }

    private func color(for index: Int) -> Color {
        if index == lyricsState.activeIndex { return primary }
        if index < lyricsState.activeIndex { return primary.opacity(0.30) }
        return primary.opacity(0.54)
    }
}

private struct FullLyricsFooter: View {
    @Environment(\.buFiMotionEnabled) private var motionEnabled
    @ObservedObject var timeline: PlaybackTimeline

    let seekBarAppearance: PlayerSeekBarAppearance
    let primary: Color
    let secondary: Color
    let playButtonForeground: Color
    private let audio = AudioEngine.shared

    var body: some View {
        VStack(spacing: 7) {
            PlayerProgressView(
                timeline: timeline,
                appearance: seekBarAppearance,
                tint: primary,
                secondary: secondary
            )
            .environmentObject(audio)

            PlayerPlaybackButton(
                diameter: 72,
                iconSize: 29,
                foreground: primary,
                buttonForeground: playButtonForeground,
                motionEnabled: motionEnabled
            ) {
                audio.togglePlayback()
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .buFiGlass(cornerRadius: 28)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }
}

private struct PlayerPaletteBackground: View, Equatable {
    let palette: ArtworkPalette
    let playerAppearance: PlayerAppearance
    let appearance: PlayerBackgroundAppearance
    let colorScheme: ColorScheme

    @ViewBuilder
    var body: some View {
        switch appearance {
        case .classic:
            if playerAppearance == .dynamic {
                ZStack {
                    LinearGradient(
                        colors: [
                            adaptivePaletteColor(
                                palette.top,
                                lightBrightnessFloor: 0.82,
                                lightSaturationCeiling: 0.28
                            ),
                            adaptivePaletteColor(
                                palette.bottom,
                                lightBrightnessFloor: 0.74,
                                lightSaturationCeiling: 0.22
                            )
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    RadialGradient(
                        colors: [
                            adaptivePaletteColor(
                                palette.secondary,
                                lightBrightnessFloor: 0.80,
                                lightSaturationCeiling: 0.26
                            ).opacity(colorScheme == .light ? 0.14 : 0.18),
                            .clear
                        ],
                        center: secondaryPoint,
                        startRadius: 8,
                        endRadius: 540
                    )
                    RadialGradient(
                        colors: [
                            adaptivePaletteColor(
                                palette.accent,
                                lightBrightnessFloor: 0.80,
                                lightSaturationCeiling: 0.28
                            ).opacity(colorScheme == .light ? 0.13 : 0.16),
                            .clear
                        ],
                        center: accentPoint,
                        startRadius: 12,
                        endRadius: 620
                    )
                    if colorScheme == .light {
                        LinearGradient(
                            colors: [.white.opacity(0.18), .white.opacity(0.38)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    } else {
                        LinearGradient(
                            colors: [.white.opacity(0.13), .clear, .black.opacity(0.24)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                }
            } else {
                ZStack {
                    adaptivePaletteColor(
                        palette.top,
                        lightBrightnessFloor: 0.86,
                        lightSaturationCeiling: 0.20
                    )
                    if colorScheme == .light {
                        Color.white.opacity(0.26)
                    } else {
                        Color.black.opacity(0.18)
                    }
                }
            }
        case .multicolor:
            ZStack {
                LinearGradient(
                    colors: [
                        adaptivePaletteColor(
                            palette.top,
                            lightBrightnessFloor: 0.84,
                            lightSaturationCeiling: 0.30
                        ),
                        adaptivePaletteColor(
                            palette.bottom,
                            lightBrightnessFloor: 0.82,
                            lightSaturationCeiling: 0.22
                        )
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                RadialGradient(
                    colors: [
                        adaptivePaletteColor(
                            palette.top,
                            lightBrightnessFloor: 0.84,
                            lightSaturationCeiling: 0.30
                        ).opacity(colorScheme == .light ? 0.30 : 0.46),
                        .clear
                    ],
                    center: UnitPoint(x: 0.50, y: 0.12),
                    startRadius: 0,
                    endRadius: 760
                )
                RadialGradient(
                    colors: [
                        adaptivePaletteColor(
                            palette.secondary,
                            lightBrightnessFloor: 0.82,
                            lightSaturationCeiling: 0.30
                        ).opacity(colorScheme == .light ? 0.28 : 0.78),
                        .clear
                    ],
                    center: secondaryPoint,
                    startRadius: 0,
                    endRadius: 620
                )
                RadialGradient(
                    colors: [
                        adaptivePaletteColor(
                            palette.accent,
                            lightBrightnessFloor: 0.82,
                            lightSaturationCeiling: 0.32
                        ).opacity(colorScheme == .light ? 0.26 : 0.72),
                        .clear
                    ],
                    center: accentPoint,
                    startRadius: 0,
                    endRadius: 560
                )
                readabilityOverlay
            }
        case .bright:
            ZStack {
                LinearGradient(
                    colors: [
                        brightenedColor(palette.top, brightnessFloor: 0.72),
                        brightenedColor(palette.bottom, brightnessFloor: 0.58)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                RadialGradient(
                    colors: [
                        brightenedColor(palette.top, brightnessFloor: 0.76)
                            .opacity(0.46),
                        .clear
                    ],
                    center: UnitPoint(x: 0.50, y: 0.12),
                    startRadius: 0,
                    endRadius: 760
                )
                RadialGradient(
                    colors: [
                        brightenedColor(palette.secondary, brightnessFloor: 0.70)
                            .opacity(0.76),
                        .clear
                    ],
                    center: secondaryPoint,
                    startRadius: 0,
                    endRadius: 620
                )
                RadialGradient(
                    colors: [
                        brightenedColor(palette.accent, brightnessFloor: 0.72)
                            .opacity(0.70),
                        .clear
                    ],
                    center: accentPoint,
                    startRadius: 0,
                    endRadius: 560
                )
                Color.white.opacity(0.04)
            }
        }
    }

    @ViewBuilder
    private var readabilityOverlay: some View {
        if colorScheme == .light || palettePrefersDarkForeground(palette) {
            Color.white.opacity(colorScheme == .light ? 0.18 : 0.42)
        } else {
            LinearGradient(
                colors: [.black.opacity(0.06), .clear, .black.opacity(0.24)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private func brightenedColor(
        _ color: RGBAColor,
        brightnessFloor: CGFloat
    ) -> Color {
        let source = UIColor(
            red: CGFloat(color.red),
            green: CGFloat(color.green),
            blue: CGFloat(color.blue),
            alpha: CGFloat(color.alpha)
        )
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 1

        if source.getHue(
            &hue,
            saturation: &saturation,
            brightness: &brightness,
            alpha: &alpha
        ) {
            let liftedSaturation: CGFloat
            if saturation < 0.05 {
                // Preserve intentional white, black, and gray artwork. A minimum
                // saturation here would manufacture a red hue that is not in the
                // cover because UIKit reports hue zero for neutral colors.
                liftedSaturation = saturation
            } else if colorScheme == .light {
                liftedSaturation = min(saturation * 0.72, 0.34)
            } else {
                liftedSaturation = min(saturation * 1.06, 0.82)
            }
            let resolvedBrightnessFloor = colorScheme == .light
                ? max(brightnessFloor, 0.78)
                : brightnessFloor
            return Color(
                hue: Double(hue),
                saturation: Double(liftedSaturation),
                brightness: Double(min(max(brightness * 1.16, resolvedBrightnessFloor), 0.94)),
                opacity: Double(alpha)
            )
        }

        let resolvedBrightnessFloor = colorScheme == .light
            ? max(brightnessFloor, 0.78)
            : brightnessFloor
        let brightnessCeiling: CGFloat = colorScheme == .light ? 0.94 : 0.92
        let red = min(max(CGFloat(color.red) * 1.12, resolvedBrightnessFloor), brightnessCeiling)
        let green = min(max(CGFloat(color.green) * 1.12, resolvedBrightnessFloor), brightnessCeiling)
        let blue = min(max(CGFloat(color.blue) * 1.12, resolvedBrightnessFloor), brightnessCeiling)
        return Color(
            red: Double(red),
            green: Double(green),
            blue: Double(blue),
            opacity: color.alpha
        )
    }

    private func adaptivePaletteColor(
        _ color: RGBAColor,
        lightBrightnessFloor: CGFloat,
        lightSaturationCeiling: CGFloat
    ) -> Color {
        guard colorScheme == .light else { return Color(color) }
        let source = UIColor(
            red: CGFloat(color.red),
            green: CGFloat(color.green),
            blue: CGFloat(color.blue),
            alpha: CGFloat(color.alpha)
        )
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 1
        guard source.getHue(
            &hue,
            saturation: &saturation,
            brightness: &brightness,
            alpha: &alpha
        ) else {
            return BuFiTheme.background
        }
        return Color(
            hue: Double(hue),
            saturation: Double(min(saturation * 0.70, lightSaturationCeiling)),
            brightness: Double(min(max(brightness, lightBrightnessFloor), 0.96)),
            opacity: Double(alpha)
        )
    }

    private var accentPoint: UnitPoint {
        UnitPoint(
            x: CGFloat(palette.accentPosition.x),
            y: CGFloat(palette.accentPosition.y)
        )
    }

    private var secondaryPoint: UnitPoint {
        UnitPoint(
            x: CGFloat(palette.secondaryPosition.x),
            y: CGFloat(palette.secondaryPosition.y)
        )
    }
}

private func palettePrefersDarkForeground(_ palette: ArtworkPalette) -> Bool {
    func linear(_ component: Double) -> Double {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }
    func luminance(_ color: RGBAColor) -> Double {
        0.2126 * linear(color.red)
            + 0.7152 * linear(color.green)
            + 0.0722 * linear(color.blue)
    }
    let fieldLuminance = 0.30 * luminance(palette.top)
        + 0.25 * luminance(palette.accent)
        + 0.25 * luminance(palette.secondary)
        + 0.20 * luminance(palette.bottom)
    return fieldLuminance >= 0.46
}

private struct QueueView: View {
    @EnvironmentObject private var playbackQueue: PlaybackQueueState
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false
    private let audio = AudioEngine.shared

    var body: some View {
        NavigationStack {
            Group {
                if playbackQueue.songs.isEmpty {
                    ContentUnavailableView("재생목록이 비어 있습니다", systemImage: "list.bullet")
                } else {
                    List {
                        ForEach(Array(playbackQueue.songs.enumerated()), id: \.offset) { index, song in
                            Button {
                                audio.playQueueItem(at: index)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    ArtworkView(coverArt: song.artworkID, size: 48, cornerRadius: 5)
                                        .frame(width: 48, height: 48)
                                        .id("\(index)-\(song.id)-\(song.artworkID ?? "")")
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(song.title)
                                            .foregroundStyle(index == playbackQueue.index ? BuFiTheme.accentSoft : Color.primary)
                                            .lineLimit(1)
                                        Text(song.artist)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if index == playbackQueue.index {
                                        Image(systemName: "speaker.wave.2.fill")
                                            .foregroundStyle(BuFiTheme.accent)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    audio.removeQueueItem(at: index)
                                } label: {
                                    Label("목록에서 제거", systemImage: "trash")
                                }
                            }
                        }
                        .onMove { offsets, destination in
                            audio.moveQueueItems(
                                from: offsets,
                                to: destination
                            )
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("재생 대기 목록")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            audio.reshuffleUpcoming()
                        } label: {
                            Label("다시 섞기", systemImage: "shuffle")
                        }
                        Button(role: .destructive) {
                            confirmClear = true
                        } label: {
                            Label(
                                "다음 곡 모두 지우기",
                                systemImage: "trash"
                            )
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
            .confirmationDialog(
                "다음 곡을 모두 지울까요?",
                isPresented: $confirmClear,
                titleVisibility: .visible
            ) {
                Button("모두 지우기", role: .destructive) {
                    audio.clearUpcomingQueue()
                }
                Button("취소", role: .cancel) {}
            }
        }
    }
}
