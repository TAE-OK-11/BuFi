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
    @AppStorage("motion-enabled") private var motionEnabled = true

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                background
                if let song = audio.currentSong {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            header(song)
                            artwork(song, availableHeight: proxy.size.height)
                            metadata(song)
                            progress
                            transport
                            utilityRow(song)
                            lyricsCard
                        }
                        .padding(.horizontal, 22)
                        .padding(.bottom, max(proxy.safeAreaInsets.bottom, 18) + 10)
                    }
                } else {
                    ContentUnavailableView("재생 중인 곡이 없습니다", systemImage: "music.note")
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(isPresented: $audio.showFullLyrics) {
            FullLyricsView(palette: palette)
                .environmentObject(audio)
        }
        .sheet(isPresented: $showQueue) {
            QueueView()
                .environmentObject(audio)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: audio.elapsed) { _, value in
            if !isScrubbing { scrubValue = value }
        }
        .onAppear { scrubValue = audio.elapsed }
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
        .animation(.easeInOut(duration: 0.55), value: palette)
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
            .frame(maxWidth: 240)
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

    private func artwork(_ song: Song, availableHeight: CGFloat) -> some View {
        let edge = min(UIScreen.main.bounds.width - 44, max(264, availableHeight * 0.47))
        return ZStack {
            ArtworkView(
                coverArt: song.coverArt,
                size: edge,
                cornerRadius: 14,
                onPalette: { palette = $0 }
            )
            .id(song.id)
            .transition(
                motionEnabled
                    ? .asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    )
                    : .opacity
            )
        }
        .frame(width: edge, height: edge)
        .shadow(color: .black.opacity(0.38), radius: 28, y: 17)
        .padding(.top, 13)
        .padding(.bottom, 28)
        .animation(
            motionEnabled
                ? .interactiveSpring(response: 0.52, dampingFraction: 0.84)
                : .none,
            value: song.id
        )
    }

    private func metadata(_ song: Song) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(song.title)
                    .font(.system(size: 25, weight: .bold))
                    .tracking(-0.7)
                    .lineLimit(1)
                    .contentTransition(.interpolate)
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
        .padding(.bottom, 18)
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
                        audio.showFullLyrics = true
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
                    audio.showFullLyrics = true
                } label: {
                    VStack(alignment: .leading, spacing: 13) {
                        ForEach(visibleLyrics) { line in
                            Text(line.text)
                                .font(.system(size: 23, weight: .bold))
                                .tracking(-0.55)
                                .foregroundStyle(lyricColor(line))
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxHeight: 205, alignment: .top)
                    .clipped()
                }
                .buttonStyle(.plain)
            }
            .padding(20)
            .foregroundStyle(playerPrimary)
            .background(
                LinearGradient(
                    colors: [
                        playerPrimary.opacity(0.19),
                        playerPrimary.opacity(0.10)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
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

    private var visibleLyrics: [LyricLine] {
        let lines = audio.lyrics.lines
        guard !lines.isEmpty else { return [] }
        let anchor = max(0, audio.activeLyricIndex - 1)
        return Array(lines[anchor..<min(lines.count, anchor + 5)])
    }

    private func lyricColor(_ line: LyricLine) -> Color {
        guard let index = audio.lyrics.lines.firstIndex(where: { $0.id == line.id }) else {
            return playerPrimary.opacity(0.76)
        }
        if index == audio.activeLyricIndex { return playerPrimary }
        if index < audio.activeLyricIndex { return playerPrimary.opacity(0.28) }
        return playerPrimary.opacity(0.58)
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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    let palette: ArtworkPalette
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false
    @AppStorage("lyrics-auto-scroll") private var autoScroll = true
    @AppStorage("motion-enabled") private var motionEnabled = true

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(palette.top), Color(palette.bottom)],
                startPoint: .top,
                endPoint: .bottom
            )
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
        .onAppear { scrubValue = audio.elapsed }
        .onChange(of: audio.elapsed) { _, value in
            if !isScrubbing { scrubValue = value }
        }
    }

    private var header: some View {
        HStack {
            Button {
                audio.showFullLyrics = false
                dismiss()
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
                                .multilineTextAlignment(.leading)
                                .foregroundStyle(color(for: index))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
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
                withAnimation(
                    motionEnabled
                        ? .interactiveSpring(response: 0.48, dampingFraction: 0.86)
                        : .none
                ) {
                    proxy.scrollTo(audio.lyrics.lines[index].id, anchor: .center)
                }
            }
            .onAppear {
                let index = audio.activeLyricIndex
                guard audio.lyrics.lines.indices.contains(index) else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(audio.lyrics.lines[index].id, anchor: .center)
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

    private func color(for index: Int) -> Color {
        if index == audio.activeLyricIndex { return lyricsPrimary }
        if index < audio.activeLyricIndex { return lyricsPrimary.opacity(0.30) }
        return lyricsPrimary.opacity(0.54)
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
