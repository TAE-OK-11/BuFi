import SwiftUI

struct PlayerView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var audio: AudioEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.buFiMotionEnabled) private var motionEnabled

    @State private var palette = ArtworkPalette.fallback
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false
    @State private var showQueue = false
    @State private var artworkPage: Int?
    @State private var transitionDirection: CGFloat = 1
    @State private var artworkPrefetchTask: Task<Void, Never>?
    @Namespace private var lyricsMorph
    @AppStorage("player-seekbar-appearance")
    private var playerAppearance = PlayerAppearance.liquidGlass.rawValue
    @AppStorage("player-background-appearance")
    private var playerBackgroundAppearance = PlayerBackgroundAppearance.classic.rawValue

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                background

                if let song = audio.currentSong {
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
                            lyricsCard
                        }
                        .padding(.horizontal, 22)
                        .padding(.bottom, max(proxy.safeAreaInsets.bottom, 18) + 10)
                    }
                    .allowsHitTesting(!audio.showFullLyrics)
                    .accessibilityHidden(audio.showFullLyrics)
                } else {
                    ContentUnavailableView("재생 중인 곡이 없습니다", systemImage: "music.note")
                }

                if audio.showFullLyrics {
                    FullLyricsView(
                        palette: palette,
                        namespace: lyricsMorph,
                        playerAppearance: resolvedPlayerAppearance,
                        seekBarAppearance: resolvedSeekBarAppearance,
                        backgroundAppearance: resolvedBackgroundAppearance
                    )
                        .environmentObject(audio)
                        .transition(
                            allowsMotion
                                ? .scale(scale: 0.985, anchor: .bottom).combined(with: .opacity)
                                : .opacity
                        )
                        .zIndex(20)
                }
            }
            .animation(allowsMotion ? BuFiMotion.lyricsPanel : .none, value: audio.showFullLyrics)
        }
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showQueue) {
            QueueView()
                .environmentObject(audio)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: audio.elapsed) { _, value in
            if !isScrubbing { scrubValue = value }
        }
        .onChange(of: audio.queueIndex) { oldIndex, index in
            transitionDirection = index >= oldIndex ? 1 : -1
            syncArtworkPage(to: index, animated: true)
            prefetchUpcomingArtwork(after: index)
        }
        .onChange(of: audio.queue.map(\.id)) { _, _ in
            syncArtworkPage(to: audio.queueIndex, animated: false)
            prefetchUpcomingArtwork(after: audio.queueIndex)
        }
        .onAppear {
            scrubValue = audio.elapsed
            syncArtworkPage(to: audio.queueIndex, animated: false)
            prefetchUpcomingArtwork(after: audio.queueIndex)
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
                .transition(
                    allowsMotion
                        ? .asymmetric(
                            insertion: .move(edge: transitionDirection > 0 ? .trailing : .leading).combined(with: .opacity),
                            removal: .move(edge: transitionDirection > 0 ? .leading : .trailing).combined(with: .opacity)
                        )
                        : .opacity
                )
            }
            .frame(maxWidth: 240)
            .animation(allowsMotion ? BuFiMotion.text : .none, value: song.id)
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
        let sideInset = max(0, (viewportWidth - edge) / 2)
        let songs = audio.queue.isEmpty ? [song] : audio.queue
        let animatesTransition = allowsMotion

        return VStack(spacing: 0) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 18) {
                    ForEach(songs.indices, id: \.self) { index in
                        let item = songs[index]
                        ArtworkView(
                            coverArt: item.coverArt,
                            size: edge,
                            cornerRadius: 14,
                            onPalette: { nextPalette in
                                guard index == artworkPage else { return }
                                withAnimation(allowsMotion ? BuFiMotion.color : .none) {
                                    palette = nextPalette
                                }
                            }
                        )
                        .frame(width: edge, height: edge)
                        .id(index)
                        .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                            content
                                .scaleEffect(phase.isIdentity || !animatesTransition ? 1 : 0.94)
                                .opacity(phase.isIdentity || !animatesTransition ? 1 : 0.72)
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .contentMargins(.horizontal, sideInset, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $artworkPage)
            .frame(height: edge + 42)

            metadataContent(song)
                .id(song.id)
                .transition(
                    allowsMotion
                        ? .asymmetric(
                            insertion: .move(
                                edge: transitionDirection > 0 ? .trailing : .leading
                            ).combined(with: .opacity),
                            removal: .move(
                                edge: transitionDirection > 0 ? .leading : .trailing
                            ).combined(with: .opacity)
                        )
                        : .opacity
                )
                .animation(allowsMotion ? BuFiMotion.text : .none, value: song.id)
                .padding(.bottom, 18)
        }
        .frame(height: edge + 116)
        .contentShape(Rectangle())
        .onChange(of: artworkPage) { oldPage, page in
            guard let index = page else { return }
            let oldIndex = oldPage ?? audio.queueIndex
            transitionDirection = index >= oldIndex ? 1 : -1
            guard index != audio.queueIndex, audio.queue.indices.contains(index) else { return }
            audio.playQueueItem(at: index)
        }
    }

    private func metadataContent(_ song: Song) -> some View {
        HStack(spacing: 14) {
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
        VStack(spacing: 14) {
            dynamicArtworkPager(
                song,
                availableWidth: availableWidth,
                availableHeight: availableHeight
            )

            VStack(spacing: 4) {
                dynamicMetadataContent(song)
                    .padding(.bottom, 8)
                progress
                    .padding(.horizontal, 2)
                transport
                utilityRow(song, includesAirPlay: false)
                    .padding(.vertical, 0)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)
            .background {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Color.white.opacity(0.24))
                    .overlay {
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .stroke(.white.opacity(0.30), lineWidth: 0.8)
                    }
            }
            .contentShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .buFiGlass(cornerRadius: 30, interactive: true)
        }
        .padding(.bottom, 8)
    }

    private func dynamicArtworkPager(
        _ song: Song,
        availableWidth: CGFloat,
        availableHeight: CGFloat
    ) -> some View {
        let viewportWidth = max(240, availableWidth - 44)
        let edge = max(220, min(viewportWidth, max(264, availableHeight * 0.47)))
        let sideInset = max(0, (viewportWidth - edge) / 2)
        let songs = audio.queue.isEmpty ? [song] : audio.queue
        let animatesTransition = allowsMotion

        return ScrollView(.horizontal) {
            LazyHStack(spacing: 18) {
                ForEach(songs.indices, id: \.self) { index in
                    let item = songs[index]
                    ArtworkView(
                        coverArt: item.coverArt,
                        size: edge,
                        cornerRadius: 14,
                        onPalette: { nextPalette in
                            guard index == artworkPage else { return }
                            withAnimation(allowsMotion ? BuFiMotion.color : .none) {
                                palette = nextPalette
                            }
                        }
                    )
                    .frame(width: edge, height: edge)
                    .id(index)
                    .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                        content
                            .scaleEffect(phase.isIdentity || !animatesTransition ? 1 : 0.94)
                            .opacity(phase.isIdentity || !animatesTransition ? 1 : 0.72)
                    }
                }
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .contentMargins(.horizontal, sideInset, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned)
        .scrollPosition(id: $artworkPage)
        .frame(height: edge + 26)
        .contentShape(Rectangle())
        .onChange(of: artworkPage) { oldPage, page in
            guard let index = page else { return }
            let oldIndex = oldPage ?? audio.queueIndex
            transitionDirection = index >= oldIndex ? 1 : -1
            guard index != audio.queueIndex, audio.queue.indices.contains(index) else { return }
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
            .padding(.horizontal, 52)

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
        let duration = audio.duration.isFinite ? max(0, audio.duration) : 0
        let rawElapsed = isScrubbing ? scrubValue : audio.elapsed
        let elapsed = min(max(0, rawElapsed.isFinite ? rawElapsed : 0), max(duration, 0))
        let seekUpperBound = max(duration, 1)
        let remaining = max(0, duration - elapsed)

        return VStack(spacing: 0) {
            PlayerSeekBar(
                value: $scrubValue,
                range: 0...seekUpperBound,
                appearance: resolvedSeekBarAppearance,
                tint: playerPrimary
            ) { editing in
                isScrubbing = editing
                if !editing { audio.seek(to: min(scrubValue, duration)) }
            }
            HStack {
                Text(elapsed.playbackText)
                Spacer()
                Text(duration > 0 ? "-\(remaining.playbackText)" : "--:--")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(playerSecondary)
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(allowsMotion ? BuFiMotion.micro : .none, value: Int(elapsed))
        }
    }

    private var transport: some View {
        classicTransport
            .frame(height: 112)
    }

    private var classicTransport: some View {
        HStack {
            control("shuffle", size: 24, active: audio.isShuffleEnabled, label: "셔플") {
                audio.toggleShuffle()
            }
            Spacer()
            control("backward.end.fill", size: 31, label: "이전 곡") {
                audio.previous()
            }
            Spacer()
            classicPlayButton
            Spacer()
            control("forward.end.fill", size: 31, label: "다음 곡") {
                audio.next()
            }
            Spacer()
            control(
                audio.repeatMode == .one ? "repeat.1" : "repeat",
                size: 24,
                active: audio.repeatMode != .off,
                label: "반복"
            ) { audio.cycleRepeat() }
        }
    }

    private var classicPlayButton: some View {
        Button {
            audio.togglePlayback()
        } label: {
            ZStack {
                Circle().fill(playerPrimary).frame(width: 70, height: 70)
                if audio.isBuffering {
                    ProgressView().tint(playerButtonForeground)
                } else {
                    Image(systemName: audio.wantsPlayback ? "pause.fill" : "play.fill")
                        .font(.system(size: 27, weight: .bold))
                        .foregroundStyle(playerButtonForeground)
                        .offset(x: audio.wantsPlayback ? 0 : 2)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
        }
        .buttonStyle(BuFiPressStyle())
        .animation(allowsMotion ? BuFiMotion.tap : .none, value: audio.wantsPlayback)
        .accessibilityLabel(audio.wantsPlayback ? "일시정지" : "재생")
    }

    private func utilityRow(_ song: Song, includesAirPlay: Bool = true) -> some View {
        HStack(spacing: 25) {
            if includesAirPlay {
                AirPlayButton(lightContent: !usesDarkForeground)
                    .frame(width: 32, height: 32)
                    .accessibilityLabel("AirPlay")
            }
            Spacer()
            ShareLink(item: "\(song.title) — \(song.artist)") {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 40, height: 40)
            }
            Button {
                showQueue = true
            } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 23, weight: .medium))
                    .frame(width: 40, height: 40)
            }
            .accessibilityLabel("재생목록")
        }
        .buttonStyle(.plain)
        .foregroundStyle(playerPrimary)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var lyricsCard: some View {
        if !audio.lyrics.lines.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("가사")
                        .font(.system(size: 20, weight: .bold))
                    Spacer()
                    if let song = audio.currentSong {
                        ShareLink(item: "\(song.title) — \(song.artist)") {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 15, weight: .bold))
                                .frame(width: 38, height: 38)
                                .background(.black.opacity(0.22), in: Circle())
                        }
                        .accessibilityLabel("가사 공유")
                    }
                    Button {
                        openFullLyrics()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 15, weight: .bold))
                            .frame(width: 38, height: 38)
                            .background(.black.opacity(0.22), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("전체 화면 가사")
                }

                Button {
                    openFullLyrics()
                } label: {
                    ZStack(alignment: .topLeading) {
                        miniLyricsWindow
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 205, alignment: .top)
                    .clipped()
                    .id(audio.currentSong?.id)
                    .transition(
                        allowsMotion
                            ? .asymmetric(
                                insertion: .move(edge: transitionDirection > 0 ? .trailing : .leading).combined(with: .opacity),
                                removal: .move(edge: transitionDirection > 0 ? .leading : .trailing).combined(with: .opacity)
                            )
                            : .opacity
                    )
                    .animation(allowsMotion ? BuFiMotion.lyrics : .none, value: audio.activeLyricIndex)
                    .animation(allowsMotion ? BuFiMotion.player : .none, value: audio.currentSong?.id)
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .foregroundStyle(playerPrimary)
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [playerPrimary.opacity(0.19), playerPrimary.opacity(0.10)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .matchedGeometryEffect(
                        id: "lyrics-surface",
                        in: lyricsMorph,
                        isSource: !audio.showFullLyrics
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .buFiGlass(cornerRadius: 24, interactive: true)
            .padding(.top, 10)
        } else {
            Text("이 곡에는 표시할 가사가 없습니다.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(playerSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 18)
        }
    }

    private var miniLyricsWindow: some View {
        VStack(alignment: .leading, spacing: 13) {
            ForEach(visibleLyrics, id: \.line.id) { item in
                Text(item.line.text)
                    .font(.system(size: 23, weight: .bold))
                    .tracking(-0.55)
                    .foregroundStyle(lyricColor(index: item.index))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(item.index == audio.activeLyricIndex ? 1 : 0)
                    .scaleEffect(
                        allowsMotion && item.index != audio.activeLyricIndex ? 0.975 : 1,
                        anchor: .leading
                    )
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(
                        allowsMotion
                            ? .asymmetric(
                                insertion: .offset(y: 12).combined(with: .opacity),
                                removal: .offset(y: -8).combined(with: .opacity)
                            )
                            : .opacity
                    )
            }
        }
        .animation(allowsMotion ? BuFiMotion.lyrics : .none, value: audio.activeLyricIndex)
    }

    private var visibleLyrics: [(index: Int, line: LyricLine)] {
        let lines = audio.lyrics.lines
        guard !lines.isEmpty else { return [] }
        let active = lines.indices.contains(audio.activeLyricIndex) ? audio.activeLyricIndex : 0
        let end = min(lines.count, active + 5)
        return (active..<end).map { (index: $0, line: lines[$0]) }
    }

    private func lyricColor(index: Int) -> Color {
        index == audio.activeLyricIndex ? playerPrimary : playerPrimary.opacity(0.56)
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
        let artists = model.home.starredArtists + model.home.artists
        if let artistID = song.artistId {
            let artist = artists.first(where: { $0.id == artistID }) ?? Artist(
                id: artistID,
                name: song.artist,
                coverArt: song.coverArt,
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

    private func openFullLyrics() {
        withAnimation(allowsMotion ? BuFiMotion.lyricsPanel : .none) {
            audio.showFullLyrics = true
        }
    }

    private func syncArtworkPage(to index: Int, animated: Bool) {
        let resolved = audio.queue.indices.contains(index) ? index : 0
        if animated && allowsMotion {
            withAnimation(BuFiMotion.player) {
                artworkPage = resolved
            }
        } else {
            artworkPage = resolved
        }
    }

    private func prefetchUpcomingArtwork(after index: Int) {
        artworkPrefetchTask?.cancel()
        guard !audio.queue.isEmpty else {
            artworkPrefetchTask = nil
            return
        }
        let start = max(index + 1, 0)
        let end = min(audio.queue.count, start + 2)
        guard start < end else {
            artworkPrefetchTask = nil
            return
        }
        let upcoming = Array(audio.queue[start..<end])

        artworkPrefetchTask = Task(priority: .utility) {
            for song in upcoming {
                guard !Task.isCancelled,
                      let url = await model.artworkURL(id: song.coverArt, size: 900) else {
                    continue
                }
                _ = try? await ArtworkStore.shared.image(for: url, pixelSize: 900)
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

    private var allowsMotion: Bool { motionEnabled }

    private var usesDarkForeground: Bool {
        colorScheme == .light
            || resolvedBackgroundAppearance == .bright
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

private struct FullLyricsView: View {
    @EnvironmentObject private var audio: AudioEngine
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.buFiMotionEnabled) private var motionEnabled

    let palette: ArtworkPalette
    let namespace: Namespace.ID
    let playerAppearance: PlayerAppearance
    let seekBarAppearance: PlayerSeekBarAppearance
    let backgroundAppearance: PlayerBackgroundAppearance

    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false
    @State private var dragOffset: CGFloat = 0
    @AppStorage("lyrics-auto-scroll") private var autoScroll = true

    var body: some View {
        ZStack {
            PlayerPaletteBackground(
                palette: palette,
                playerAppearance: playerAppearance,
                appearance: backgroundAppearance,
                colorScheme: colorScheme
            )
                .clipShape(RoundedRectangle(cornerRadius: dragCornerRadius, style: .continuous))
                .matchedGeometryEffect(id: "lyrics-surface", in: namespace, isSource: true)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                lyrics
                footer
            }
        }
        .offset(y: max(0, dragOffset))
        .scaleEffect(dragScale, anchor: .bottom)
        .opacity(dragOpacity)
        .onAppear { scrubValue = audio.elapsed }
        .onChange(of: audio.elapsed) { _, value in
            if !isScrubbing { scrubValue = value }
        }
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
                Text(audio.currentSong?.title ?? "가사")
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
                Text(audio.currentSong?.artist ?? "")
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
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 25) {
                    Color.clear.frame(height: 22)
                    ForEach(Array(audio.lyrics.lines.enumerated()), id: \.element.id) { index, line in
                        Button {
                            if audio.lyrics.synced { audio.seek(to: line.start) }
                        } label: {
                            Text(line.text)
                                .font(.system(size: 29, weight: .bold))
                                .tracking(-0.95)
                                .lineLimit(nil)
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(color(for: index))
                                .scaleEffect(
                                    allowsMotion
                                        ? (index == audio.activeLyricIndex ? 1.045 : 0.985)
                                        : 1,
                                    anchor: .leading
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(line.id)
                    }
                    Color.clear.frame(height: 180)
                }
                .padding(.horizontal, 24)
                .animation(allowsMotion ? BuFiMotion.lyrics : .none, value: audio.activeLyricIndex)
            }
            .onChange(of: audio.activeLyricIndex) { _, index in
                guard autoScroll, audio.lyrics.lines.indices.contains(index) else { return }
                withAnimation(allowsMotion ? BuFiMotion.lyrics : .none) {
                    proxy.scrollTo(
                        audio.lyrics.lines[index].id,
                        anchor: UnitPoint(x: 0.5, y: 0.42)
                    )
                }
            }
            .onAppear {
                let index = audio.activeLyricIndex
                guard audio.lyrics.lines.indices.contains(index) else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(
                        audio.lyrics.lines[index].id,
                        anchor: UnitPoint(x: 0.5, y: 0.42)
                    )
                }
            }
        }
    }

    private var footer: some View {
        let duration = audio.duration.isFinite ? max(0, audio.duration) : 0
        let rawElapsed = isScrubbing ? scrubValue : audio.elapsed
        let elapsed = min(max(0, rawElapsed.isFinite ? rawElapsed : 0), duration)

        return VStack(spacing: 7) {
            PlayerSeekBar(
                value: $scrubValue,
                range: 0...max(duration, 1),
                appearance: seekBarAppearance,
                tint: lyricsPrimary
            ) { editing in
                isScrubbing = editing
                if !editing { audio.seek(to: min(scrubValue, duration)) }
            }
            HStack {
                Text(elapsed.playbackText)
                Spacer()
                Text(duration > 0 ? "-\(max(0, duration - elapsed).playbackText)" : "--:--")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(lyricsSecondary)
            .monospacedDigit()

            Button { audio.togglePlayback() } label: {
                ZStack {
                    Circle()
                        .fill(lyricsPrimary)
                        .frame(width: 72, height: 72)
                    if audio.isBuffering {
                        ProgressView()
                            .tint(playButtonForeground)
                    } else {
                        Image(systemName: audio.wantsPlayback ? "pause.fill" : "play.fill")
                            .font(.system(size: 29, weight: .bold))
                            .foregroundStyle(playButtonForeground)
                            .offset(x: audio.wantsPlayback ? 0 : 2)
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
            }
            .buttonStyle(BuFiPressStyle())
            .animation(allowsMotion ? BuFiMotion.tap : .none, value: audio.wantsPlayback)
            .accessibilityLabel(audio.wantsPlayback ? "일시정지" : "재생")
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .buFiGlass(cornerRadius: 28)
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
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
        withAnimation(allowsMotion ? BuFiMotion.lyricsPanel : .none) {
            dragOffset = 0
            audio.showFullLyrics = false
        }
    }

    private func color(for index: Int) -> Color {
        if index == audio.activeLyricIndex { return lyricsPrimary }
        if index < audio.activeLyricIndex { return lyricsPrimary.opacity(0.30) }
        return lyricsPrimary.opacity(0.54)
    }

    private var dragProgress: CGFloat { min(max(dragOffset / 420, 0), 1) }
    private var dragScale: CGFloat { allowsMotion ? 1 - (dragProgress * 0.055) : 1 }
    private var dragOpacity: Double { allowsMotion ? 1 - Double(dragProgress * 0.16) : 1 }
    private var dragCornerRadius: CGFloat { allowsMotion ? dragProgress * 28 : 0 }
    private var allowsMotion: Bool { motionEnabled }
    private var usesDarkForeground: Bool {
        colorScheme == .light || backgroundAppearance == .bright
    }
    private var lyricsPrimary: Color { usesDarkForeground ? .black.opacity(0.86) : .white }
    private var lyricsSecondary: Color { lyricsPrimary.opacity(0.66) }
    private var playButtonForeground: Color { usesDarkForeground ? .white : Color(palette.bottom) }
}

private struct PlayerPaletteBackground: View {
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
                        colors: [Color(palette.top), Color(palette.bottom)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    RadialGradient(
                        colors: [Color(palette.secondary).opacity(0.18), .clear],
                        center: secondaryPoint,
                        startRadius: 8,
                        endRadius: 540
                    )
                    RadialGradient(
                        colors: [Color(palette.accent).opacity(0.16), .clear],
                        center: accentPoint,
                        startRadius: 12,
                        endRadius: 620
                    )
                    if colorScheme == .light {
                        LinearGradient(
                            colors: [.white.opacity(0.46), .white.opacity(0.72)],
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
                    Color(palette.top)
                    if colorScheme == .light {
                        Color.white.opacity(0.56)
                    } else {
                        Color.black.opacity(0.18)
                    }
                }
            }
        case .multicolor:
            ZStack {
                LinearGradient(
                    colors: [
                        Color(palette.secondary),
                        Color(palette.top),
                        Color(palette.accent)
                    ],
                    startPoint: secondaryPoint,
                    endPoint: accentPoint
                )
                RadialGradient(
                    colors: [Color(palette.secondary).opacity(0.82), .clear],
                    center: secondaryPoint,
                    startRadius: 12,
                    endRadius: 520
                )
                RadialGradient(
                    colors: [Color(palette.accent).opacity(0.76), .clear],
                    center: accentPoint,
                    startRadius: 18,
                    endRadius: 590
                )
                readabilityOverlay
            }
        case .bright:
            ZStack {
                Color.white
                LinearGradient(
                    colors: [
                        Color(palette.secondary).opacity(0.82),
                        Color(palette.top).opacity(0.62),
                        Color(palette.accent).opacity(0.74)
                    ],
                    startPoint: secondaryPoint,
                    endPoint: accentPoint
                )
                RadialGradient(
                    colors: [.white.opacity(0.62), .clear],
                    center: .center,
                    startRadius: 20,
                    endRadius: 520
                )
                LinearGradient(
                    colors: [.white.opacity(0.08), .white.opacity(0.26)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
    }

    @ViewBuilder
    private var readabilityOverlay: some View {
        if colorScheme == .light {
            LinearGradient(
                colors: [.white.opacity(0.22), .white.opacity(0.48)],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            LinearGradient(
                colors: [.white.opacity(0.10), .clear, .black.opacity(0.28)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
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

private struct QueueView: View {
    @EnvironmentObject private var audio: AudioEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if audio.queue.isEmpty {
                    ContentUnavailableView("재생목록이 비어 있습니다", systemImage: "list.bullet")
                } else {
                    List {
                        ForEach(Array(audio.queue.enumerated()), id: \.offset) { index, song in
                            Button {
                                audio.playQueueItem(at: index)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    ArtworkView(coverArt: song.coverArt, size: 48, cornerRadius: 5)
                                        .frame(width: 48, height: 48)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(song.title)
                                            .foregroundStyle(index == audio.queueIndex ? BuFiTheme.accentSoft : Color.primary)
                                            .lineLimit(1)
                                        Text(song.artist)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if index == audio.queueIndex {
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
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("재생 대기 목록")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
    }
}
