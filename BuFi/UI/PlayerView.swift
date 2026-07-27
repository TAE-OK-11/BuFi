import SwiftUI

struct PlayerView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var audio: AudioEngine
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var palette = ArtworkPalette.fallback
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false
    @State private var showQueue = false
    @State private var artworkPage = 0
    @State private var transitionDirection: CGFloat = 1
    @Namespace private var lyricsMorph
    @AppStorage("motion-enabled") private var motionEnabled = true

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                background

                if let song = audio.currentSong {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            header(song)
                            nowPlayingPager(song, availableWidth: proxy.size.width, availableHeight: proxy.size.height)
                            progress
                            transport
                            utilityRow(song)
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
                    FullLyricsView(palette: palette, namespace: lyricsMorph)
                        .environmentObject(audio)
                        .transition(
                            motionEnabled
                                ? .asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .move(edge: .bottom).combined(with: .opacity)
                                )
                                : .opacity
                        )
                        .zIndex(20)
                }
            }
            .animation(
                motionEnabled
                    ? .interactiveSpring(response: 0.42, dampingFraction: 0.86)
                    : .none,
                value: audio.showFullLyrics
            )
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
        .onChange(of: audio.queue.count) { _, _ in
            syncArtworkPage(to: audio.queueIndex, animated: false)
        }
        .onAppear {
            scrubValue = audio.elapsed
            syncArtworkPage(to: audio.queueIndex, animated: false)
            prefetchUpcomingArtwork(after: audio.queueIndex)
        }
    }

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [Color(palette.top), Color(palette.bottom)],
                startPoint: .top,
                endPoint: .bottom
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
        .ignoresSafeArea()
        .animation(motionEnabled ? BuFiMotion.color : .none, value: palette)
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
                    Text(
                        song.album.isEmpty
                            ? String(localized: "지금 재생 중")
                            : song.album
                    )
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    Text(song.artist)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(playerSecondary)
                        .lineLimit(1)
                }
                .id(song.id)
                .transition(
                    motionEnabled
                        ? .asymmetric(
                            insertion: .move(edge: transitionDirection > 0 ? .trailing : .leading).combined(with: .opacity),
                            removal: .move(edge: transitionDirection > 0 ? .leading : .trailing).combined(with: .opacity)
                        )
                        : .opacity
                )
            }
            .frame(maxWidth: 240)
            .animation(motionEnabled ? BuFiMotion.text : .none, value: song.id)
            Spacer()

            Menu {
                Button {
                    Task { await model.toggleStar(song: song) }
                } label: {
                    Label(
                        song.isStarred
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
        .frame(height: 58)
    }

    /// 앨범 아트 + 메타데이터를 함께 페이징하는 뷰. TabView 자체가 좌우 스와이프 전환을
    /// 담당하므로, 여기에 별도의 `.animation(value: artworkPage)`를 얹지 않는다.
    /// (제스처 기반 페이징 애니메이션과 암시적 애니메이션이 겹치면 전환이 두 번 겹쳐
    /// 재생되며 끊기는 현상이 있었음 — 실제 버그였던 부분.)
    private func nowPlayingPager(_ song: Song, availableWidth: CGFloat, availableHeight: CGFloat) -> some View {
        let edge = min(availableWidth - 44, max(264, availableHeight * 0.47))
        let songs = audio.queue.isEmpty ? [song] : audio.queue

        return TabView(selection: $artworkPage) {
            ForEach(Array(songs.enumerated()), id: \.element.id) { index, item in
                VStack(spacing: 0) {
                    ArtworkView(
                        coverArt: item.coverArt,
                        size: edge,
                        cornerRadius: 14,
                        onPalette: { nextPalette in
                            guard index == artworkPage else { return }
                            withAnimation(motionEnabled ? BuFiMotion.color : .none) {
                                palette = nextPalette
                            }
                        }
                    )
                    .frame(width: edge, height: edge)
                    .padding(.horizontal, 4)
                    .padding(.top, 13)
                    .padding(.bottom, 26)

                    metadataContent(item)
                        .padding(.bottom, 18)
                }
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(height: edge + 116)
        .contentShape(Rectangle())
        .onChange(of: artworkPage) { oldIndex, index in
            transitionDirection = index >= oldIndex ? 1 : -1
            guard index != audio.queueIndex,
                  audio.queue.indices.contains(index) else { return }
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
                            Text(song.artist)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(playerSecondary)
                    }
                    .buttonStyle(BuFiPressStyle())
                    .accessibilityLabel(
                        String(
                            format: String(localized: "%@ 아티스트 페이지 열기"),
                            song.artist
                        )
                    )
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
                Image(systemName: song.isStarred ? "heart.fill" : "heart")
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundStyle(song.isStarred ? BuFiTheme.accent : playerPrimary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(BuFiPressStyle())
            .accessibilityLabel(song.isStarred ? "좋아요 취소" : "좋아요 표시")
        }
    }

    private var progress: some View {
        VStack(spacing: 0) {
            InteractiveSeekBar(
                value: $scrubValue,
                range: 0...max(audio.duration, 1),
                tint: playerPrimary
            ) { editing in
                isScrubbing = editing
                if !editing { audio.seek(to: scrubValue) }
            }
            HStack {
                Text((isScrubbing ? scrubValue : audio.elapsed).playbackText)
                Spacer()
                Text("-\(max(0, audio.duration - (isScrubbing ? scrubValue : audio.elapsed)).playbackText)")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(playerSecondary)
            .monospacedDigit()
        }
    }

    private var transport: some View {
        HStack {
            control(
                "shuffle",
                size: 24,
                active: audio.isShuffleEnabled,
                label: "셔플"
            ) { audio.toggleShuffle() }
            Spacer()
            control("backward.end.fill", size: 31, label: "이전 곡") { audio.previous() }
            Spacer()
            Button {
                audio.togglePlayback()
            } label: {
                ZStack {
                    Circle().fill(playerPrimary).frame(width: 70, height: 70)
                    if audio.isBuffering {
                        ProgressView().tint(playerButtonForeground)
                    } else {
                        Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 27, weight: .bold))
                            .foregroundStyle(playerButtonForeground)
                            .offset(x: audio.isPlaying ? 0 : 2)
                    }
                }
            }
            .buttonStyle(BuFiPressStyle())
            .accessibilityLabel(audio.isPlaying ? "일시정지" : "재생")
            Spacer()
            control("forward.end.fill", size: 31, label: "다음 곡") { audio.next() }
            Spacer()
            control(
                audio.repeatMode == .one ? "repeat.1" : "repeat",
                size: 24,
                active: audio.repeatMode != .off,
                label: "반복"
            ) { audio.cycleRepeat() }
        }
        .frame(height: 112)
    }

    private func utilityRow(_ song: Song) -> some View {
        HStack(spacing: 25) {
            AirPlayButton(lightContent: colorScheme == .dark)
                .frame(width: 32, height: 32)
                .accessibilityLabel("AirPlay")
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
                    // 안쪽: 같은 곡 안에서 가사 줄이 넘어갈 때는 위/아래로.
                    // 바깥쪽: 곡 자체가 바뀔 때는 앨범 아트와 같은 방향으로 좌/우 슬라이드.
                    ZStack(alignment: .topLeading) {
                        miniLyricsWindow
                            .id(audio.activeLyricIndex)
                            .transition(
                                motionEnabled
                                    ? .asymmetric(
                                        insertion: .offset(y: 10).combined(with: .opacity),
                                        removal: .offset(y: -10).combined(with: .opacity)
                                    )
                                    : .opacity
                            )
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 205, alignment: .top)
                    .clipped()
                    .id(audio.currentSong?.id)
                    .transition(
                        motionEnabled
                            ? .asymmetric(
                                insertion: .move(edge: transitionDirection > 0 ? .trailing : .leading).combined(with: .opacity),
                                removal: .move(edge: transitionDirection > 0 ? .leading : .trailing).combined(with: .opacity)
                            )
                            : .opacity
                    )
                    .animation(
                        motionEnabled ? BuFiMotion.fade : .none,
                        value: audio.activeLyricIndex
                    )
                    .animation(
                        motionEnabled ? BuFiMotion.player : .none,
                        value: audio.currentSong?.id
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .foregroundStyle(playerPrimary)
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                playerPrimary.opacity(0.19),
                                playerPrimary.opacity(0.10)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .matchedGeometryEffect(id: "lyrics-surface", in: lyricsMorph)
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
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// 화면에 보여줄 가사 줄들을, 전체 가사 배열 안에서의 실제 인덱스와 함께 반환.
    /// 이전에는 lyricColor에서 id로 firstIndex(where:) 재탐색을 했는데,
    /// 여기서 이미 알고 있는 인덱스를 그대로 넘겨 O(1)로 만들었다.
    private var visibleLyrics: [(index: Int, line: LyricLine)] {
        let lines = audio.lyrics.lines
        guard !lines.isEmpty else { return [] }
        let active = lines.indices.contains(audio.activeLyricIndex) ? audio.activeLyricIndex : 0
        let end = min(lines.count, active + 4)
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
        .accessibilityLabel(label)
    }

    private func artistRoute(for song: Song) -> MusicRoute? {
        let artists = model.home.starredArtists + model.home.artists
        if let artistID = song.artistId {
            let artist = artists.first(where: { $0.id == artistID }) ?? Artist(
                id: artistID,
                name: song.artist,
                coverArt: song.coverArt,
                artistImageUrl: nil,
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
        withAnimation(
            motionEnabled
                ? .interactiveSpring(response: 0.44, dampingFraction: 0.86)
                : .none
        ) {
            audio.showFullLyrics = true
        }
    }

    private func syncArtworkPage(to index: Int, animated: Bool) {
        let resolved = audio.queue.indices.contains(index) ? index : 0
        guard artworkPage != resolved else { return }
        if animated && motionEnabled {
            withAnimation(BuFiMotion.player) {
                artworkPage = resolved
            }
        } else {
            artworkPage = resolved
        }
    }

    private func prefetchUpcomingArtwork(after index: Int) {
        guard !audio.queue.isEmpty else { return }
        let start = max(index + 1, 0)
        let end = min(audio.queue.count, start + 3)
        guard start < end else { return }
        let upcoming = Array(audio.queue[start..<end])

        Task(priority: .utility) {
            for song in upcoming {
                guard !Task.isCancelled,
                      let url = await model.artworkURL(id: song.coverArt, size: 1200) else {
                    continue
                }
                _ = try? await ArtworkStore.shared.image(for: url, pixelSize: 1200)
            }
        }
    }

    private var playerPrimary: Color {
        colorScheme == .dark ? .white : .black.opacity(0.86)
    }

    private var playerSecondary: Color {
        playerPrimary.opacity(0.64)
    }

    private var playerButtonForeground: Color {
        colorScheme == .dark ? Color(palette.bottom) : .white
    }
}

private struct FullLyricsView: View {
    @EnvironmentObject private var audio: AudioEngine
    @Environment(\.colorScheme) private var colorScheme

    let palette: ArtworkPalette
    let namespace: Namespace.ID

    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false
    @State private var dragOffset: CGFloat = 0
    @AppStorage("lyrics-auto-scroll") private var autoScroll = true
    @AppStorage("motion-enabled") private var motionEnabled = true

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: dragCornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(palette.top), Color(palette.bottom)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .matchedGeometryEffect(id: "lyrics-surface", in: namespace)
                .ignoresSafeArea()

            if colorScheme == .light {
                LinearGradient(
                    colors: [.white.opacity(0.48), .white.opacity(0.73)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            }

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
            Button {
                closeLyrics()
            } label: {
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
        .contentShape(Rectangle())
        // 드래그로 내려서 닫는 제스처는 헤더 영역에만 붙인다.
        // 이전에는 body 전체(ZStack)에 걸려 있어서, 아래 가사 리스트를
        // 스크롤할 때도 이 제스처가 같이 인식되며 배경이 흔들리는 문제가 있었다.
        .simultaneousGesture(dismissGesture)
    }

    private var lyrics: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 25) {
                    Color.clear.frame(height: 22)
                    ForEach(Array(audio.lyrics.lines.enumerated()), id: \.element.id) { index, line in
                        Button {
                            if audio.lyrics.synced { audio.seek(to: line.start) }
                        } label: {
                            Text(line.text)
                                .font(.system(size: 29, weight: .bold))
                                .tracking(-0.95)
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(color(for: index))
                                .scaleEffect(
                                    index == audio.activeLyricIndex ? 1.045 : 1,
                                    anchor: .leading
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .animation(
                                    motionEnabled ? BuFiMotion.fade : .none,
                                    value: audio.activeLyricIndex
                                )
                        }
                        .buttonStyle(.plain)
                        .id(line.id)
                    }
                    Color.clear.frame(height: 180)
                }
                .padding(.horizontal, 24)
            }
            .onChange(of: audio.activeLyricIndex) { _, index in
                guard autoScroll, audio.lyrics.lines.indices.contains(index) else { return }
                withAnimation(motionEnabled ? BuFiMotion.lyrics : .none) {
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
        VStack(spacing: 7) {
            InteractiveSeekBar(
                value: $scrubValue,
                range: 0...max(audio.duration, 1),
                tint: lyricsPrimary
            ) { editing in
                isScrubbing = editing
                if !editing { audio.seek(to: scrubValue) }
            }
            HStack {
                Text((isScrubbing ? scrubValue : audio.elapsed).playbackText)
                Spacer()
                Text("-\(max(0, audio.duration - (isScrubbing ? scrubValue : audio.elapsed)).playbackText)")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(lyricsSecondary)
            .monospacedDigit()

            Button { audio.togglePlayback() } label: {
                Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 29, weight: .bold))
                    .foregroundStyle(playButtonForeground)
                    .frame(width: 72, height: 72)
                    .background(lyricsPrimary, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(audio.isPlaying ? "일시정지" : "재생")
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
                let shouldDismiss =
                    value.translation.height > 100 ||
                    value.predictedEndTranslation.height > 180
                if shouldDismiss {
                    closeLyrics()
                } else {
                    withAnimation(
                        motionEnabled
                            ? .interactiveSpring(response: 0.38, dampingFraction: 0.86)
                            : .none
                    ) {
                        dragOffset = 0
                    }
                }
            }
    }

    private func closeLyrics() {
        withAnimation(
            motionEnabled
                ? .interactiveSpring(response: 0.42, dampingFraction: 0.88)
                : .none
        ) {
            dragOffset = 0
            audio.showFullLyrics = false
        }
    }

    private func color(for index: Int) -> Color {
        if index == audio.activeLyricIndex { return lyricsPrimary }
        if index < audio.activeLyricIndex { return lyricsPrimary.opacity(0.30) }
        return lyricsPrimary.opacity(0.54)
    }

    private var dragProgress: CGFloat {
        min(max(dragOffset / 420, 0), 1)
    }

    private var dragScale: CGFloat {
        1 - (dragProgress * 0.055)
    }

    private var dragOpacity: Double {
        1 - Double(dragProgress * 0.16)
    }

    private var dragCornerRadius: CGFloat {
        dragProgress * 28
    }

    private var lyricsPrimary: Color {
        colorScheme == .dark ? .white : .black.opacity(0.86)
    }

    private var lyricsSecondary: Color {
        lyricsPrimary.opacity(0.66)
    }

    private var playButtonForeground: Color {
        colorScheme == .dark ? Color(palette.bottom) : .white
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
                        ForEach(Array(audio.queue.enumerated()), id: \.element.id) { index, song in
                            Button {
                                audio.playQueueItem(at: index)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    ArtworkView(coverArt: song.coverArt, size: 48, cornerRadius: 5)
                                        .frame(width: 48, height: 48)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(song.title)
                                            .foregroundStyle(
                                                index == audio.queueIndex
                                                    ? BuFiTheme.accentSoft
                                                    : Color.primary
                                            )
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
