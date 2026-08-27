import SwiftUI
import UIKit

struct PlayerArtworkPageID: Hashable, Sendable {
    let queueEntryID: UUID
    let songID: String
    let coverArtID: String?
    let artworkRevision: String
    let accountScope: String?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.queueEntryID == rhs.queueEntryID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(queueEntryID)
    }
}

struct PlayerPagerSelectionGate {
    private(set) var programmaticDestination: PlayerArtworkPageID?

    mutating func beginProgrammaticMove(to destination: PlayerArtworkPageID?) {
        programmaticDestination = destination
    }

    mutating func beginUserInteraction() {
        programmaticDestination = nil
    }

    mutating func shouldStartPlayback(for selection: PlayerArtworkPageID?) -> Bool {
        guard let destination = programmaticDestination else {
            return selection != nil
        }
        if selection == destination {
            programmaticDestination = nil
        }
        return false
    }
}

private struct PlayerArtworkQueueCacheIdentity: Equatable {
    let entriesRevision: UInt64
    let accountScope: String?
}

private struct PlayerArtworkPagerAlignmentIdentity: Equatable {
    let queueIdentity: PlayerArtworkQueueCacheIdentity
    let pagesRevision: UInt64
    let layoutRevision: UInt64
    let presentationID: UUID
    let viewportWidth: Int
    let artworkEdge: Int
}

private struct PlayerArtworkPagerLayoutIdentity: Hashable {
    let layoutRevision: UInt64
    let presentationID: UUID
    let viewportWidth: Int
    let artworkEdge: Int
}

private struct PlayerArtworkPage: Identifiable, Equatable {
    let id: PlayerArtworkPageID
    let song: Song
    let queueIndex: Int
}

private struct PlayerBackgroundAnimationIdentity: Equatable {
    let palette: ArtworkPalette
    let playerAppearance: PlayerAppearance
    let backgroundAppearance: PlayerBackgroundAppearance
}

private struct PlayerArtworkPressEffect: ViewModifier {
    @GestureState private var isPressed = false

    let enabled: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPressed && enabled ? 1.012 : 1)
            .brightness(isPressed && enabled ? 0.018 : 0)
            .animation(
                enabled ? BuFiMotion.artworkTouch : .none,
                value: isPressed
            )
            .clipShape(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .contentShape(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.01, maximumDistance: 12)
                    .updating($isPressed) { pressed, state, _ in
                        state = pressed
                    }
            )
    }
}

private extension View {
    func playerArtworkPressEffect(
        enabled: Bool,
        cornerRadius: CGFloat
    ) -> some View {
        modifier(PlayerArtworkPressEffect(
            enabled: enabled,
            cornerRadius: cornerRadius
        ))
    }
}

struct PlayerView: View {
    @EnvironmentObject private var playback: PlaybackState
    @EnvironmentObject private var currentPlayback: CurrentPlaybackState
    @EnvironmentObject private var playerPresentation: PlayerPresentationState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.buFiMotionEnabled) private var motionEnabled

    @State private var palette = ArtworkPalette.fallback
    @State private var showQueue = false
    @State private var transitionDirection: CGFloat = 1
    @State private var artworkPage: PlayerArtworkPageID?
    @State private var pagerSelectionGate = PlayerPagerSelectionGate()
    @State private var artworkPalettes: [PlayerArtworkPageID: ArtworkPalette] = [:]
    @State private var cachedArtworkPages: [PlayerArtworkPage] = []
    @State private var artworkPagesRevision: UInt64 = 0
    @State private var artworkLayoutRevision: UInt64 = 0
    @State private var translationRequestedSongID: String?
    @State private var hasRevealedPlayerContent = false
    @AppStorage("player-seekbar-appearance")
    private var playerAppearance = PlayerAppearance.liquidGlass.rawValue
    @AppStorage("player-background-appearance")
    private var playerBackgroundAppearance = PlayerBackgroundAppearance.classic.rawValue

    private let audio = AudioEngine.shared

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                background

                if let item = currentPlayback.item {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            header(item)
                            nowPlayingContent(
                                item,
                                availableWidth: proxy.size.width,
                                availableHeight: proxy.size.height
                            )
                            progress
                            transport
                            utilityRow()
                            PlayerLyricsCard(
                                lyricsState: audio.lyricsState,
                                primary: playerPrimary,
                                secondary: playerSecondary,
                                onRetry: audio.retryLyrics,
                                onTranslate: {
                                    translationRequestedSongID = item.song.id
                                    audio.showFullLyrics = true
                                },
                                onOpen: {
                                    translationRequestedSongID = nil
                                    audio.showFullLyrics = true
                                }
                            )
                        }
                        .padding(.horizontal, 22)
                        .padding(.bottom, max(proxy.safeAreaInsets.bottom, 18) + 10)
                    }
                    .opacity(
                        playerPresentation.showFullLyrics
                            ? 0
                            : (hasRevealedPlayerContent ? 1 : 0)
                    )
                    .scaleEffect(
                        hasRevealedPlayerContent ? 1 : 0.996,
                        anchor: .center
                    )
                    .offset(y: hasRevealedPlayerContent ? 0 : 7)
                    .animation(
                        allowsMotion ? BuFiMotion.playerEntrance : .none,
                        value: hasRevealedPlayerContent
                    )
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
                        lyricsState: audio.lyricsState,
                        showsTranslations: lyricsTranslationVisibility
                    )
                        .environmentObject(audio)
                        .transition(lyricsPanelTransition)
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
        .onChange(of: currentPlayback.snapshot) { previous, next in
            handleCurrentPlaybackChange(from: previous, to: next)
        }
        .onChange(of: artworkQueueCacheIdentity) { _, _ in
            let next = playback.snapshot
            refreshArtworkPages(from: next, fallback: currentPlayback.item)
            pruneArtworkPalettes(using: next)
            if let currentID = currentArtworkPageID(in: next),
               artworkPage != currentID {
                syncArtworkPage(to: next, animated: false)
            } else if artworkPage != nil,
                      !next.entries.contains(where: { $0.id == artworkPage?.queueEntryID }) {
                syncArtworkPage(to: next, animated: false)
            }
        }
        .onAppear {
            if PlayerAppearance(rawValue: playerAppearance) == nil {
                playerAppearance = PlayerAppearance.liquidGlass.rawValue
            }
            // Full-screen covers may preserve the horizontal scroll view's
            // internal geometry across presentations. Force a fresh layout
            // pass for this presentation before aligning the active item.
            artworkLayoutRevision &+= 1
            artworkPage = nil
            pagerSelectionGate = PlayerPagerSelectionGate()
            refreshArtworkPages(from: playback.snapshot, fallback: currentPlayback.item)
            syncArtworkPage(to: playback.snapshot, animated: false)
        }
        .task(id: playerPresentation.presentationID) {
            hasRevealedPlayerContent = false
            if allowsMotion {
                await Task.yield()
                guard !Task.isCancelled else { return }
            }
            hasRevealedPlayerContent = true
        }
    }

    private func handleCurrentPlaybackChange(
        from previous: CurrentPlaybackSnapshot,
        to next: CurrentPlaybackSnapshot
    ) {
        let indexChanged = previous.index != next.index
        if previous.item?.song.id != next.item?.song.id {
            translationRequestedSongID = nil
        }
        if indexChanged {
            transitionDirection = next.index >= previous.index ? 1 : -1
        }
        syncArtworkPage(to: playback.snapshot, animated: indexChanged)
    }

    private var lyricsTranslationVisibility: Binding<Bool> {
        Binding(
            get: {
                guard let songID = currentPlayback.song?.id else { return false }
                return translationRequestedSongID == songID
            },
            set: { isVisible in
                if isVisible {
                    translationRequestedSongID = currentPlayback.song?.id
                } else {
                    translationRequestedSongID = nil
                }
            }
        )
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
        .animation(
            allowsMotion ? BuFiMotion.color : .none,
            value: PlayerBackgroundAnimationIdentity(
                palette: palette,
                playerAppearance: resolvedPlayerAppearance,
                backgroundAppearance: resolvedBackgroundAppearance
            )
        )
    }

    private func header(_ item: PlaybackMediaItem) -> some View {
        let song = item.song
        return HStack {
            Button {
                audio.showPlayer = false
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(BuFiPressStyle())
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
                .id(item.id)
                .transition(trackTextTransition)
            }
            .frame(maxWidth: 240)
            .animation(allowsMotion ? BuFiMotion.trackText : .none, value: item.id)
            Spacer()

            PlayerOverflowMenu(song: song, foreground: playerPrimary)
        }
        .buttonStyle(.plain)
        .foregroundStyle(playerPrimary)
        .frame(height: 58)
    }

    private func nowPlayingContent(
        _ item: PlaybackMediaItem,
        availableWidth: CGFloat,
        availableHeight: CGFloat
    ) -> some View {
        let viewportWidth = max(240, availableWidth - 44)
        let edge = max(220, min(viewportWidth, max(264, availableHeight * 0.47)))

        return VStack(spacing: 0) {
            artworkPager(
                item,
                availableWidth: availableWidth,
                availableHeight: availableHeight,
                heightPadding: 42
            )

            metadataContent(item, availableWidth: viewportWidth)
                .padding(.bottom, 18)
        }
        .frame(width: viewportWidth)
        .frame(height: edge + 116)
        .contentShape(Rectangle())
    }

    private func metadataContent(
        _ item: PlaybackMediaItem,
        availableWidth: CGFloat
    ) -> some View {
        let song = item.song
        return HStack(spacing: 14) {
            ZStack(alignment: .leading) {
                VStack(alignment: .leading, spacing: 5) {
                    OverflowMarqueeText(
                        text: song.title,
                        font: .system(size: 25, weight: .bold),
                        tracking: -0.7
                    )
                    PlayerArtistLink(song: song, foreground: playerSecondary)
                }
                .id(item.id)
                .transition(trackTextTransition)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(allowsMotion ? BuFiMotion.trackText : .none, value: item.id)
            Spacer(minLength: 4)
            PlayerFavoriteButton(
                song: song,
                iconSize: 27,
                foreground: playerPrimary
            )
        }
        .frame(width: availableWidth)
    }

    private func artworkPager(
        _ item: PlaybackMediaItem,
        availableWidth: CGFloat,
        availableHeight: CGFloat,
        heightPadding: CGFloat
    ) -> some View {
        let viewportWidth = max(240, availableWidth - 44)
        let edge = max(220, min(viewportWidth, max(264, availableHeight * 0.47)))
        let sideInset = max(0, (viewportWidth - edge) / 2)
        let pages = cachedArtworkPages.isEmpty ? artworkPages(fallback: item) : cachedArtworkPages
        let alignmentIdentity = PlayerArtworkPagerAlignmentIdentity(
            queueIdentity: artworkQueueCacheIdentity,
            pagesRevision: artworkPagesRevision,
            layoutRevision: artworkLayoutRevision,
            presentationID: playerPresentation.presentationID,
            viewportWidth: Int(viewportWidth.rounded()),
            artworkEdge: Int(edge.rounded())
        )
        let layoutIdentity = PlayerArtworkPagerLayoutIdentity(
            layoutRevision: artworkLayoutRevision,
            presentationID: playerPresentation.presentationID,
            viewportWidth: Int(viewportWidth.rounded()),
            artworkEdge: Int(edge.rounded())
        )
        let currentPageIndex = pages.first { $0.id == artworkPage }?.queueIndex
            ?? pages.first { $0.id.queueEntryID == item.queueEntryID }?.queueIndex
            ?? 0
        let animatesTransition = allowsMotion
        let pagerPosition = Binding<PlayerArtworkPageID?>(
            get: { artworkPage },
            set: { page in
                let shouldStartPlayback = pagerSelectionGate.shouldStartPlayback(for: page)
                guard artworkPage != page else { return }
                let previousIndex = artworkPage.flatMap(indexForArtworkPage)
                    ?? currentPlayback.index
                artworkPage = page
                guard shouldStartPlayback,
                      let page,
                      let destination = indexForArtworkPage(page),
                      destination != currentPlayback.index else {
                    applyPalette(for: page)
                    return
                }
                transitionDirection = destination >= previousIndex ? 1 : -1
                applyPalette(for: page)
                audio.playQueueItem(at: destination)
            }
        )

        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 18) {
                    ForEach(pages) { page in
                        let extractsPalette = abs(page.queueIndex - currentPageIndex) <= 1
                        ArtworkView(
                            coverArt: page.id.coverArtID,
                            size: edge,
                            cornerRadius: 14,
                            minimumPixelSize: ArtworkRequestSizing.fullPlayerPixelSize,
                            cacheRevision: page.id.artworkRevision,
                            onPalette: extractsPalette
                                ? { nextPalette in
                                    receivePalette(nextPalette, for: page.id)
                                }
                                : nil
                        )
                        .frame(width: edge, height: edge)
                        .playerArtworkPressEffect(
                            enabled: allowsMotion,
                            cornerRadius: 14
                        )
                        .id(page.id)
                        .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                            content
                                .scaleEffect(phase.isIdentity || !animatesTransition ? 1 : 0.978)
                                .opacity(phase.isIdentity || !animatesTransition ? 1 : 0.90)
                                .offset(y: phase.isIdentity || !animatesTransition ? 0 : 3)
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
            .frame(width: viewportWidth)
            .frame(height: edge + heightPadding)
            .contentShape(Rectangle())
            .task(id: alignmentIdentity) {
                await Task.yield()
                guard !Task.isCancelled else { return }
                alignArtworkPager(using: proxy)
            }
        }
        .id(layoutIdentity)
    }

    private func alignArtworkPager(using proxy: ScrollViewProxy) {
        guard let currentPage = currentArtworkPageID(in: playback.snapshot),
              cachedArtworkPages.isEmpty
                || cachedArtworkPages.contains(where: { $0.id == currentPage }) else {
            return
        }
        pagerSelectionGate.beginProgrammaticMove(to: currentPage)
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            artworkPage = currentPage
            proxy.scrollTo(currentPage, anchor: .center)
        }
        applyPalette(for: currentPage)
    }

    private func refreshArtworkPages(
        from snapshot: PlaybackSnapshot,
        fallback item: PlaybackMediaItem?
    ) {
        let pages: [PlayerArtworkPage]
        if snapshot.entries.isEmpty, let item {
            pages = [PlayerArtworkPage(
                id: pageID(for: item),
                song: item.song,
                queueIndex: 0
            )]
        } else {
            pages = snapshot.entries.enumerated().map { index, entry in
                PlayerArtworkPage(
                    id: pageID(for: entry, accountScope: snapshot.accountScope),
                    song: entry.song,
                    queueIndex: index
                )
            }
        }
        if cachedArtworkPages != pages {
            cachedArtworkPages = pages
            artworkPagesRevision &+= 1
        }
    }

    private func artworkPages(fallback item: PlaybackMediaItem) -> [PlayerArtworkPage] {
        if cachedArtworkPages.isEmpty {
            return [PlayerArtworkPage(
                id: pageID(for: item),
                song: item.song,
                queueIndex: 0
            )]
        }
        return cachedArtworkPages
    }

    private func pageID(for item: PlaybackMediaItem) -> PlayerArtworkPageID {
        PlayerArtworkPageID(
            queueEntryID: item.queueEntryID,
            songID: item.song.id,
            coverArtID: item.song.artworkID,
            artworkRevision: item.song.artworkRevision,
            accountScope: item.accountScope
        )
    }

    private func pageID(
        for entry: PlaybackQueueEntry,
        accountScope: String?
    ) -> PlayerArtworkPageID {
        PlayerArtworkPageID(
            queueEntryID: entry.id,
            songID: entry.song.id,
            coverArtID: entry.song.artworkID,
            artworkRevision: entry.song.artworkRevision,
            accountScope: accountScope
        )
    }

    private func currentArtworkPageID(in snapshot: PlaybackSnapshot) -> PlayerArtworkPageID? {
        guard snapshot.entries.indices.contains(snapshot.index) else { return nil }
        let entry = snapshot.entries[snapshot.index]
        return PlayerArtworkPageID(
            queueEntryID: entry.id,
            songID: entry.song.id,
            coverArtID: entry.song.artworkID,
            artworkRevision: entry.song.artworkRevision,
            accountScope: snapshot.accountScope
        )
    }

    private func indexForArtworkPage(_ page: PlayerArtworkPageID) -> Int? {
        if let cachedPage = cachedArtworkPages.first(where: { $0.id == page }),
           playback.entries.indices.contains(cachedPage.queueIndex),
           playback.entries[cachedPage.queueIndex].id == page.queueEntryID {
            return cachedPage.queueIndex
        }
        return playback.entries.firstIndex { $0.id == page.queueEntryID }
    }

    private func syncArtworkPage(to snapshot: PlaybackSnapshot, animated: Bool) {
        guard let currentPage = currentArtworkPageID(in: snapshot) else {
            pagerSelectionGate.beginProgrammaticMove(to: nil)
            artworkPage = nil
            if palette != .fallback { palette = .fallback }
            return
        }
        if artworkPage != currentPage {
            pagerSelectionGate.beginProgrammaticMove(to: currentPage)
        }
        let update = {
            artworkPage = currentPage
        }
        if animated && allowsMotion {
            withAnimation(BuFiMotion.trackPage) { update() }
        } else {
            update()
        }
        applyPalette(for: currentPage)
    }

    private func receivePalette(
        _ nextPalette: ArtworkPalette,
        for page: PlayerArtworkPageID
    ) {
        if artworkPalettes[page] != nextPalette {
            artworkPalettes[page] = nextPalette
        }
        let currentQueueEntryID = currentPlayback.item?.queueEntryID
        if artworkPage == page || currentQueueEntryID == page.queueEntryID {
            if palette != nextPalette {
                palette = nextPalette
            }
        }
    }

    private func applyPalette(for page: PlayerArtworkPageID?) {
        guard let page, let cached = artworkPalettes[page] else {
            if palette != .fallback { palette = .fallback }
            return
        }
        if palette != cached { palette = cached }
    }

    private var artworkQueueCacheIdentity: PlayerArtworkQueueCacheIdentity {
        PlayerArtworkQueueCacheIdentity(
            entriesRevision: playback.entriesRevision,
            accountScope: playback.snapshot.accountScope
        )
    }

    private func pruneArtworkPalettes(using snapshot: PlaybackSnapshot) {
        let validPages = Set(snapshot.entries.map {
            pageID(for: $0, accountScope: snapshot.accountScope)
        })
        let filtered = artworkPalettes.filter { validPages.contains($0.key) }
        if filtered.count != artworkPalettes.count {
            artworkPalettes = filtered
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
        PlayerTransportBar(
            compact: false,
            primary: playerPrimary,
            buttonForeground: playerButtonForeground,
            motionEnabled: allowsMotion
        )
    }

    private func utilityRow(
        includesAirPlay: Bool = true,
        compact: Bool = false
    ) -> some View {
        let itemSize: CGFloat = compact ? 34 : 40
        let queueSize: CGFloat = compact ? 21 : 23

        return HStack(spacing: compact ? 18 : 25) {
            if includesAirPlay {
                AirPlayButton(lightContent: !usesDarkForeground)
                    .frame(width: 32, height: 32)
                    .accessibilityLabel("AirPlay")
            }
            Spacer()
            Button {
                showQueue = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: queueSize, weight: .medium))
                    .frame(width: itemSize, height: itemSize)
            }
            .accessibilityLabel("재생목록")
        }
        .buttonStyle(BuFiPressStyle())
        .foregroundStyle(playerPrimary)
        .padding(.vertical, compact ? 0 : 8)
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
            )
            .combined(with: .scale(scale: 0.995))
            .combined(with: .opacity),
            removal: .offset(
                x: transitionDirection > 0 ? -distance : distance
            )
            .combined(with: .scale(scale: 0.998))
            .combined(with: .opacity)
        )
    }

    private var lyricsPanelTransition: AnyTransition {
        guard allowsMotion else { return .opacity }
        return .asymmetric(
            insertion: .offset(y: 24)
                .combined(with: .scale(scale: 0.992, anchor: .bottom))
                .combined(with: .opacity),
            removal: .offset(y: 18)
                .combined(with: .scale(scale: 0.996, anchor: .bottom))
                .combined(with: .opacity)
        )
    }

    private var allowsMotion: Bool { motionEnabled }

    private var usesDarkForeground: Bool {
        switch resolvedBackgroundAppearance {
        case .classic:
            return colorScheme == .light
        case .multicolor:
            return colorScheme == .light || palettePrefersDarkForeground(palette)
        case .bright:
            return true
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

private struct PlayerTransportBar: View {
    @EnvironmentObject private var audio: AudioEngine

    let compact: Bool
    let primary: Color
    let buttonForeground: Color
    let motionEnabled: Bool

    var body: some View {
        HStack {
            control(
                "shuffle",
                size: compact ? 21 : 24,
                active: audio.isShuffleEnabled,
                label: "셔플",
                action: audio.toggleShuffle
            )
            Spacer()
            control(
                "backward.end.fill",
                size: compact ? 28 : 31,
                label: "이전 곡",
                action: audio.previous
            )
            Spacer()
            PlayerPlaybackButton(
                diameter: compact ? 62 : 70,
                iconSize: compact ? 24 : 27,
                foreground: primary,
                buttonForeground: buttonForeground,
                motionEnabled: motionEnabled,
                action: audio.togglePlayback
            )
            Spacer()
            control(
                "forward.end.fill",
                size: compact ? 28 : 31,
                label: "다음 곡",
                action: { audio.next() }
            )
            Spacer()
            control(
                audio.repeatMode == .one ? "repeat.1" : "repeat",
                size: compact ? 21 : 24,
                active: audio.repeatMode != .off,
                label: "반복",
                action: audio.cycleRepeat
            )
        }
        .frame(height: compact ? 82 : 112)
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
                    .foregroundStyle(active ? BuFiTheme.accent : primary)
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
        .animation(motionEnabled ? BuFiMotion.symbol : .none, value: active)
        .accessibilityLabel(label)
    }
}

private struct PlayerOverflowMenu: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var audio: AudioEngine

    let song: Song
    let foreground: Color

    var body: some View {
        Menu {
            SongFavoriteMenuButton(song: song)
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
                .foregroundStyle(foreground)
                .frame(width: 44, height: 44)
        }
        .accessibilityLabel("더 보기")
    }
}

private struct PlayerFavoriteButton: View {
    let song: Song
    let iconSize: CGFloat
    let foreground: Color

    var body: some View {
        SongFavoriteIconButton(
            song: song,
            iconSize: iconSize,
            inactiveForeground: foreground,
            hitTarget: 44
        )
    }
}

private struct PlayerArtistLink: View {
    let song: Song
    let foreground: Color

    @ViewBuilder
    var body: some View {
        if let route = artistRoute {
            NavigationLink(value: route) {
                HStack(spacing: 5) {
                    Text(song.artist).lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                }
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(foreground)
            }
            .buttonStyle(BuFiPressStyle())
            .accessibilityLabel(
                String(format: String(localized: "%@ 아티스트 페이지 열기"), song.artist)
            )
        } else {
            Text(song.artist)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(foreground)
                .lineLimit(1)
        }
    }

    private var artistRoute: MusicRoute? {
        guard let artistID = song.artistId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !artistID.isEmpty else {
            return nil
        }
        return .artist(
            Artist(
                id: artistID,
                name: song.artist,
                coverArt: nil,
                albumCount: nil,
                starred: nil
            )
        )
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
                        .transition(.opacity.combined(with: .scale(scale: 0.90)))
                } else {
                    Image(systemName: playbackControl.wantsPlayback ? "pause.fill" : "play.fill")
                        .font(.system(size: iconSize, weight: .bold))
                        .foregroundStyle(buttonForeground)
                        .offset(x: playbackControl.wantsPlayback ? 0 : 2)
                        .contentTransition(.symbolEffect(.replace))
                        .transition(.opacity.combined(with: .scale(scale: 0.90)))
                }
            }
        }
        .buttonStyle(BuFiPressStyle())
        .animation(
            motionEnabled ? BuFiMotion.symbol : .none,
            value: playbackControl.wantsPlayback
        )
        .animation(
            motionEnabled ? BuFiMotion.symbol : .none,
            value: playbackControl.isBuffering
        )
        .accessibilityLabel(playbackControl.wantsPlayback ? "일시정지" : "재생")
    }
}

private struct PlayerProgressView: View {
    @ObservedObject var timeline: PlaybackTimeline

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
            PlayerElapsedLabels(
                elapsed: elapsed,
                remaining: remaining,
                hasDuration: duration > 0,
                secondary: secondary
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

private struct PlayerElapsedLabels: View {
    @Environment(\.buFiMotionEnabled) private var motionEnabled
    let elapsed: Double
    let remaining: Double
    let hasDuration: Bool
    let secondary: Color

    var body: some View {
        let elapsedText = elapsed.playbackText
        let remainingText = hasDuration ? "-\(remaining.playbackText)" : "--:--"
        HStack {
            Text(elapsedText)
                .contentTransition(.numericText(countsDown: false))
                .animation(
                    motionEnabled ? BuFiMotion.symbol : .none,
                    value: elapsedText
                )
            Spacer()
            Text(remainingText)
                .contentTransition(.numericText(countsDown: true))
                .animation(
                    motionEnabled ? BuFiMotion.symbol : .none,
                    value: remainingText
                )
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(secondary)
        .monospacedDigit()
    }
}

private struct PlayerLyricsCard: View {
    @ObservedObject var lyricsState: LyricsPlaybackState
    @Environment(\.buFiMotionEnabled) private var motionEnabled

    let primary: Color
    let secondary: Color
    let onRetry: () -> Void
    let onTranslate: () -> Void
    let onOpen: () -> Void

    @State private var canOfferTranslation = false

    @ViewBuilder
    var body: some View {
        Group {
            if hasLyrics {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("가사")
                            .font(.system(size: 20, weight: .bold))
                        Spacer()
                        if canOfferTranslation {
                            Button(action: onTranslate) {
                                Image(systemName: "translate")
                                    .font(.system(size: 15, weight: .bold))
                                    .frame(width: 38, height: 38)
                                    .background(.black.opacity(0.22), in: Circle())
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(BuFiPressStyle())
                            .transition(.scale(scale: 0.90).combined(with: .opacity))
                            .accessibilityLabel("가사 번역")
                            .accessibilityHint("전체 화면 가사를 열고 번역을 표시합니다.")
                        }
                        Button(action: onOpen) {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 15, weight: .bold))
                                .frame(width: 38, height: 38)
                                .background(.black.opacity(0.22), in: Circle())
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(BuFiPressStyle())
                        .accessibilityLabel("전체 화면 가사")
                    }
                    .animation(
                        motionEnabled ? BuFiMotion.lyricsCard : .none,
                        value: canOfferTranslation
                    )

                    Button(action: onOpen) {
                        miniLyricsWindow
                            .frame(maxWidth: .infinity)
                            .frame(height: 186, alignment: .top)
                            .clipped()
                    }
                    .buttonStyle(BuFiPressStyle())
                    .accessibilityLabel("전체 화면 가사 열기")
                    .accessibilityHint("현재 곡의 가사를 전체 화면으로 표시합니다.")
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
                .transition(lyricsCardTransition)
                .task(id: translationEligibilityIdentity) {
                    let isEligible = LyricsTranslationEligibility
                        .shouldOfferTranslation(lines: lyricsState.document.lines)
                    guard !Task.isCancelled else { return }
                    canOfferTranslation = isEligible
                }
            } else {
                lyricsPlaceholder
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 18)
                    .transition(.opacity.combined(with: .offset(y: 4)))
            }
        }
        .animation(
            motionEnabled ? BuFiMotion.lyricsCard : .none,
            value: hasLyrics
        )
    }

    private var hasLyrics: Bool {
        !lyricsState.document.lines.isEmpty
    }

    private var lyricsCardTransition: AnyTransition {
        guard motionEnabled else { return .opacity }
        return .opacity
            .combined(with: .offset(y: 8))
            .combined(with: .scale(scale: 0.995, anchor: .top))
    }

    private var translationEligibilityIdentity:
        LyricsTranslationEligibilityIdentity {
        LyricsTranslationEligibilityIdentity(lines: lyricsState.document.lines)
    }

    @ViewBuilder
    private var lyricsPlaceholder: some View {
        switch lyricsState.status {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                    .tint(primary)
                Text("가사를 불러오는 중…")
            }
            .accessibilityElement(children: .combine)
        case .failed:
            HStack(spacing: 12) {
                Text("가사를 불러오지 못했습니다.")
                Spacer()
                Button("다시 시도", action: onRetry)
                    .fontWeight(.bold)
                    .buttonStyle(BuFiPressStyle())
                    .foregroundStyle(primary)
            }
        case .idle, .unavailable, .available:
            Text("이 곡에는 표시할 가사가 없습니다.")
        }
    }

    private var miniLyricsWindow: some View {
        VStack(alignment: .leading, spacing: 13) {
            ForEach(visibleMiniLyrics, id: \.line.id) { item in
                let isActive = item.index == lyricsState.activeIndex
                Text(item.line.text)
                    .font(
                        .system(
                            size: 21,
                            weight: isActive ? .bold : .semibold
                        )
                    )
                    .tracking(-0.12)
                    .lineSpacing(5)
                    .foregroundStyle(lyricColor(for: item.index))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(miniLyricLineTransition)
                    // Highlight snaps instantly; CJK glyphs flash when opacity
                    // or contentTransition animates on the same Text view.
                    .animation(nil, value: lyricsState.activeIndex)
            }
        }
        .padding(.top, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .clipped()
        .animation(
            motionEnabled ? BuFiMotion.miniLyricsScroll : .none,
            value: lyricsState.activeIndex
        )
    }

    /// Active line is always the first visible row; show the next lines below.
    private var visibleMiniLyrics: [(index: Int, line: LyricLine)] {
        let lines = lyricsState.document.lines
        guard !lines.isEmpty else { return [] }
        let active = lyricsState.activeIndex
        let start = active >= 0 ? active : lines.startIndex
        let end = min(lines.endIndex, start + 4)
        guard start < end else { return [] }
        return (start..<end).map { (index: $0, line: lines[$0]) }
    }

    private var miniLyricLineTransition: AnyTransition {
        guard motionEnabled else { return .identity }
        // Push mimics a lyric sheet sliding up without opacity fades on CJK text.
        return .asymmetric(
            insertion: .push(from: .bottom),
            removal: .push(from: .top)
        )
    }

    private func lyricColor(for index: Int) -> Color {
        if index == lyricsState.activeIndex { return primary }
        let distance = max(1, index - lyricsState.activeIndex)
        return primary.opacity(max(0.32, 0.62 - (Double(distance - 1) * 0.10)))
    }
}

private struct FullLyricsView: View {
    @EnvironmentObject private var currentPlayback: CurrentPlaybackState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.buFiMotionEnabled) private var motionEnabled

    let palette: ArtworkPalette
    let seekBarAppearance: PlayerSeekBarAppearance
    let backgroundAppearance: PlayerBackgroundAppearance
    @ObservedObject var lyricsState: LyricsPlaybackState
    @Binding var showsTranslations: Bool

    @State private var dragOffset: CGFloat = 0
    @State private var translations = [Int: String]()
    @State private var translationPhase = LyricsTranslationPhase.idle
    @State private var canOfferTranslations = false
    private let audio = AudioEngine.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                header
                lyrics
                footer
            }

            if let item = currentPlayback.item {
                LyricsTranslationTaskHost(
                    accountScope: item.accountScope,
                    songID: item.song.id,
                    lines: lyricsState.document.lines,
                    isEnabled: showsTranslations && canOfferTranslations,
                    translations: $translations,
                    phase: $translationPhase
                )
                .frame(width: 1, height: 1)
                .opacity(0.001)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .offset(y: max(0, dragOffset))
        .scaleEffect(dragScale, anchor: .bottom)
        .opacity(dragOpacity)
        .task(id: translationEligibilityIdentity) {
            let isEligible = LyricsTranslationEligibility
                .shouldOfferTranslation(lines: lyricsState.document.lines)
            guard !Task.isCancelled else { return }
            canOfferTranslations = isEligible
            if !isEligible {
                showsTranslations = false
            }
        }
    }

    private var header: some View {
        HStack {
            Button { closeLyrics() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 23, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(BuFiPressStyle())
            Spacer()
            VStack(spacing: 3) {
                OverflowMarqueeText(
                    text: currentPlayback.song?.title ?? "가사",
                    font: .system(size: 15, weight: .bold),
                    restingAlignment: .center
                )
                Text(currentPlayback.song?.artist ?? "")
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
            primary: lyricsPrimary,
            translations: showsTranslations ? translations : [:]
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
            playButtonForeground: playButtonForeground,
            showsTranslations: $showsTranslations,
            translationPhase: translationPhase,
            canOfferTranslations: canOfferTranslations
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
        // The root player owns the show/hide transition. Mutating the state in
        // a second explicit animation would stack two springs on the same frame.
        dragOffset = 0
        audio.showFullLyrics = false
    }

    private var dragProgress: CGFloat { min(max(dragOffset / 420, 0), 1) }
    private var translationEligibilityIdentity:
        LyricsTranslationEligibilityIdentity {
        LyricsTranslationEligibilityIdentity(lines: lyricsState.document.lines)
    }
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
    let translations: [Int: String]
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 25) {
                    Color.clear.frame(height: 22)
                    ForEach(
                        Array(lyricsState.document.lines.enumerated()),
                        id: \.element.id
                    ) { index, line in
                        FullLyricLine(
                            line: line,
                            isActive: index == lyricsState.activeIndex,
                            isPast: index < lyricsState.activeIndex,
                            primary: primary,
                            motionEnabled: motionEnabled,
                            translation: translations[line.id]
                        ) {
                            if lyricsState.document.synced {
                                onSeek(line.start)
                            }
                        }
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
        let lineID = lyricsState.document.lines[index].id
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(
                lineID,
                anchor: UnitPoint(x: 0.5, y: 0.42)
            )
        }
    }

}

private struct FullLyricLine: View {
    let line: LyricLine
    let isActive: Bool
    let isPast: Bool
    let primary: Color
    let motionEnabled: Bool
    let translation: String?
    let onSeek: () -> Void

    var body: some View {
        Button(action: onSeek) {
            VStack(alignment: .leading, spacing: 5) {
                Text(line.text)
                    .font(.system(size: 29, weight: .bold))
                    .tracking(-0.95)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(foreground)

                if let translation,
                   !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   translation != line.text {
                    Text(translation)
                        .font(.system(size: 17, weight: .medium))
                        .tracking(-0.28)
                        .lineSpacing(2)
                        .foregroundStyle(translationForeground)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(
                            .opacity.combined(with: .offset(y: 5))
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(line.id)
        .animation(motionEnabled ? BuFiMotion.lyrics : .none, value: isActive)
        .animation(motionEnabled ? BuFiMotion.fade : .none, value: translation)
    }

    private var foreground: Color {
        if isActive { return primary }
        if isPast { return primary.opacity(0.30) }
        return primary.opacity(0.54)
    }

    private var translationForeground: Color {
        if isActive { return primary.opacity(0.78) }
        if isPast { return primary.opacity(0.24) }
        return primary.opacity(0.44)
    }
}

private struct FullLyricsFooter: View {
    @Environment(\.buFiMotionEnabled) private var motionEnabled
    @AppStorage("haptics-enabled") private var hapticsEnabled = true
    @ObservedObject var timeline: PlaybackTimeline

    let seekBarAppearance: PlayerSeekBarAppearance
    let primary: Color
    let secondary: Color
    let playButtonForeground: Color
    @Binding var showsTranslations: Bool
    let translationPhase: LyricsTranslationPhase
    let canOfferTranslations: Bool
    private let audio = AudioEngine.shared

    var body: some View {
        VStack(spacing: 7) {
            // The translation affordance enters the full screen only through
            // the mini-lyrics translate action. A normal lyrics expansion
            // remains a clean, untranslated view for the whole presentation.
            if canOfferTranslations, showsTranslations {
                translationControls
            }

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

    private var translationControls: some View {
        HStack(spacing: 9) {
            Button {
                showsTranslations.toggle()
            } label: {
                ZStack {
                    Image(systemName: "translate")
                        .font(.system(size: 19, weight: .semibold))
                        .opacity(translationPhase.isWorking ? 0 : 1)
                    if translationPhase.isWorking {
                        ProgressView()
                            .controlSize(.small)
                            .tint(primary)
                    }
                }
                .frame(width: 42, height: 42)
                .background(
                    primary.opacity(showsTranslations ? 0.16 : 0.07),
                    in: Circle()
                )
                .contentShape(Circle())
            }
            .buttonStyle(BuFiPressStyle())
            .sensoryFeedback(.selection, trigger: showsTranslations) {
                oldValue, newValue in
                hapticsEnabled && motionEnabled && oldValue != newValue
            }
            .accessibilityLabel(
                showsTranslations ? "가사 번역 숨기기" : "가사 번역 보기"
            )

            if showsTranslations,
               let statusText = translationPhase.statusText {
                Text(statusText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(secondary)
                    .transition(.opacity)
            }
            Spacer()
        }
        .frame(height: 42)
        .animation(
            motionEnabled ? BuFiMotion.fade : .none,
            value: translationPhase
        )
    }
}

private struct PlayerPaletteBackground: View, Equatable {
    private enum ArtisticFieldStyle {
        case restrained
        case vivid
        case bright

        var baseWeight: Double {
            switch self {
            case .restrained: 1.55
            case .vivid: 0.88
            case .bright: 0.82
            }
        }

        var colorInfluence: Double {
            switch self {
            case .restrained: 0.92
            case .vivid: 1.72
            case .bright: 1.88
            }
        }

        var fallbackOpacity: Double {
            switch self {
            case .restrained: 0.40
            case .vivid: 0.76
            case .bright: 0.82
            }
        }
    }

    let palette: ArtworkPalette
    let playerAppearance: PlayerAppearance
    let appearance: PlayerBackgroundAppearance
    let colorScheme: ColorScheme

    @ViewBuilder
    var body: some View {
        switch appearance {
        case .classic:
            ZStack {
                artisticField(style: .restrained)
                restrainedReadabilityOverlay
            }
        case .multicolor:
            ZStack {
                artisticField(style: .vivid)
                readabilityOverlay
            }
        case .bright:
            ZStack {
                artisticField(style: .bright)
                Color.white.opacity(0.04)
            }
        }
    }

    @ViewBuilder
    private func artisticField(style: ArtisticFieldStyle) -> some View {
        if #available(iOS 18.0, *) {
            MeshGradient(
                width: 3,
                height: 3,
                points: meshPoints,
                colors: meshColors(style: style),
                background: fieldColor(palette.bottom, style: style),
                smoothsColors: true,
                colorSpace: .perceptual
            )
        } else {
            radialArtisticField(style: style)
        }
    }

    private func radialArtisticField(
        style: ArtisticFieldStyle
    ) -> some View {
        let opacity = style.fallbackOpacity
        return ZStack {
            LinearGradient(
                colors: [
                    fieldColor(palette.top, style: style),
                    fieldColor(palette.bottom, style: style)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [
                    fieldColor(palette.accent, style: style).opacity(opacity),
                    .clear
                ],
                center: accentPoint,
                startRadius: 0,
                endRadius: 600
            )
            RadialGradient(
                colors: [
                    fieldColor(palette.secondary, style: style).opacity(opacity * 0.94),
                    .clear
                ],
                center: secondaryPoint,
                startRadius: 0,
                endRadius: 680
            )
            RadialGradient(
                colors: [
                    fieldColor(palette.highlight, style: style).opacity(opacity * 0.82),
                    .clear
                ],
                center: highlightPoint,
                startRadius: 0,
                endRadius: 560
            )
            if let tertiary = palette.tertiary,
               let tertiaryPosition = palette.tertiaryPosition {
                RadialGradient(
                    colors: [
                        fieldColor(tertiary, style: style).opacity(opacity * 0.76),
                        .clear
                    ],
                    center: UnitPoint(
                        x: CGFloat(tertiaryPosition.x),
                        y: CGFloat(tertiaryPosition.y)
                    ),
                    startRadius: 0,
                    endRadius: 520
                )
            }
        }
    }

    private var meshPoints: [SIMD2<Float>] {
        [
            .init(0, 0), .init(0.5, 0), .init(1, 0),
            .init(0, 0.5), .init(0.5, 0.5), .init(1, 0.5),
            .init(0, 1), .init(0.5, 1), .init(1, 1)
        ]
    }

    private func meshColors(style: ArtisticFieldStyle) -> [Color] {
        [
            (0.0, 0.0), (0.5, 0.0), (1.0, 0.0),
            (0.0, 0.5), (0.5, 0.5), (1.0, 0.5),
            (0.0, 1.0), (0.5, 1.0), (1.0, 1.0)
        ].map { point in
            fieldColor(
                mixedPaletteColor(
                    x: point.0,
                    y: point.1,
                    style: style
                ),
                style: style
            )
        }
    }

    private func mixedPaletteColor(
        x: Double,
        y: Double,
        style: ArtisticFieldStyle
    ) -> RGBAColor {
        let base = interpolatedColor(palette.top, palette.bottom, amount: y)
        var red = base.red * style.baseWeight
        var green = base.green * style.baseWeight
        var blue = base.blue * style.baseWeight
        var weight = style.baseWeight
        var positionedColors: [(RGBAColor, PalettePosition, Double)] = [
            (palette.accent, palette.accentPosition, 1.0),
            (palette.secondary, palette.secondaryPosition, 0.96),
            (palette.highlight, palette.highlightPosition, 0.82)
        ]
        if let tertiary = palette.tertiary,
           let tertiaryPosition = palette.tertiaryPosition {
            positionedColors.append((tertiary, tertiaryPosition, 0.76))
        }

        for (color, position, roleStrength) in positionedColors {
            let distance = hypot(x - position.x, y - position.y)
            let falloff = max(0, 1 - distance / 0.92)
            let influence = falloff * falloff
                * style.colorInfluence
                * roleStrength
            red += color.red * influence
            green += color.green * influence
            blue += color.blue * influence
            weight += influence
        }

        return RGBAColor(
            red: min(max(red / weight, 0), 1),
            green: min(max(green / weight, 0), 1),
            blue: min(max(blue / weight, 0), 1),
            alpha: 1
        )
    }

    private func interpolatedColor(
        _ start: RGBAColor,
        _ end: RGBAColor,
        amount: Double
    ) -> RGBAColor {
        let amount = min(max(amount, 0), 1)
        let inverse = 1 - amount
        return RGBAColor(
            red: start.red * inverse + end.red * amount,
            green: start.green * inverse + end.green * amount,
            blue: start.blue * inverse + end.blue * amount,
            alpha: start.alpha * inverse + end.alpha * amount
        )
    }

    private func fieldColor(
        _ color: RGBAColor,
        style: ArtisticFieldStyle
    ) -> Color {
        switch style {
        case .restrained:
            adaptivePaletteColor(
                color,
                lightBrightnessFloor: 0.80,
                lightSaturationCeiling: 0.28
            )
        case .vivid:
            adaptivePaletteColor(
                color,
                lightBrightnessFloor: 0.82,
                lightSaturationCeiling: 0.32
            )
        case .bright:
            brightenedColor(color, brightnessFloor: 0.70)
        }
    }

    @ViewBuilder
    private var restrainedReadabilityOverlay: some View {
        if colorScheme == .light {
            Color.white.opacity(0.20)
        } else {
            LinearGradient(
                colors: [.clear, .clear, .black.opacity(0.06)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    @ViewBuilder
    private var readabilityOverlay: some View {
        if colorScheme == .light || palettePrefersDarkForeground(palette) {
            Color.white.opacity(colorScheme == .light ? 0.18 : 0.42)
        } else {
            LinearGradient(
                colors: [.black.opacity(0.02), .clear, .black.opacity(0.10)],
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

    private var highlightPoint: UnitPoint {
        UnitPoint(
            x: CGFloat(palette.highlightPosition.x),
            y: CGFloat(palette.highlightPosition.y)
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
    let fieldLuminance: Double
    if let tertiary = palette.tertiary {
        fieldLuminance = 0.20 * luminance(palette.top)
            + 0.18 * luminance(palette.accent)
            + 0.17 * luminance(palette.secondary)
            + 0.16 * luminance(palette.highlight)
            + 0.14 * luminance(tertiary)
            + 0.15 * luminance(palette.bottom)
    } else {
        fieldLuminance = 0.24 * luminance(palette.top)
            + 0.22 * luminance(palette.accent)
            + 0.20 * luminance(palette.secondary)
            + 0.18 * luminance(palette.highlight)
            + 0.16 * luminance(palette.bottom)
    }
    return fieldLuminance >= 0.46
}

private struct QueueView: View {
    @EnvironmentObject private var playback: PlaybackState
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false
    private let audio = AudioEngine.shared

    var body: some View {
        let currentQueueEntryID = playback.currentItem?.queueEntryID
        NavigationStack {
            Group {
                if playback.songs.isEmpty {
                    ContentUnavailableView("재생목록이 비어 있습니다", systemImage: "list.bullet")
                } else {
                    List {
                        ForEach(playback.entries) { entry in
                            let song = entry.song
                            let isCurrent = entry.id == currentQueueEntryID
                            Button {
                                playQueueEntry(entry)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    ArtworkView(
                                        coverArt: song.artworkID,
                                        size: 48,
                                        cornerRadius: 5,
                                        cacheRevision: song.artworkRevision
                                    )
                                    .frame(width: 48, height: 48)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(song.title)
                                            .foregroundStyle(isCurrent ? BuFiTheme.accentSoft : Color.primary)
                                            .lineLimit(1)
                                        Text(song.artist)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if isCurrent {
                                        Image(systemName: "speaker.wave.2.fill")
                                            .foregroundStyle(BuFiTheme.accent)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    removeQueueEntry(entry)
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

    private func playQueueEntry(_ entry: PlaybackQueueEntry) {
        guard let index = playback.entries.firstIndex(where: {
            $0.id == entry.id
        }) else { return }
        audio.playQueueItem(at: index)
    }

    private func removeQueueEntry(_ entry: PlaybackQueueEntry) {
        guard let index = playback.entries.firstIndex(where: {
            $0.id == entry.id
        }) else { return }
        audio.removeQueueItem(at: index)
    }
}
