import SwiftUI

struct PlayerView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var audio: AudioEngine
    @Environment(\.dismiss) private var dismiss

    @State private var palette = ArtworkPalette.fallback
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false
    @State private var showQueue = false

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
        .preferredColorScheme(.dark)
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
            LinearGradient(
                colors: [.white.opacity(0.08), .clear, .black.opacity(0.14)],
                startPoint: .top,
                endPoint: .bottom
            )
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
            VStack(spacing: 3) {
                Text("추천 트랙 재생 중")
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
            }
            .frame(maxWidth: 240)
            Spacer()

            Menu {
                Button {
                    Task { await model.toggleStar(song: song) }
                } label: {
                    Label(song.isStarred ? "좋아요 취소" : "좋아요 표시", systemImage: "heart")
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
        let edge = min(UIScreen.main.bounds.width - 36, max(264, availableHeight * 0.47))
        return ArtworkView(
            coverArt: song.coverArt,
            size: edge,
            cornerRadius: 10,
            onPalette: { palette = $0 }
        )
        .frame(width: edge, height: edge)
        .shadow(color: .black.opacity(0.36), radius: 25, y: 15)
        .padding(.top, 15)
        .padding(.bottom, 30)
    }

    private func metadata(_ song: Song) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(song.title)
                    .font(.system(size: 24, weight: .bold))
                    .tracking(-0.6)
                    .lineLimit(1)
                Text(song.artist)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                audio.excludeCurrentAndAdvance()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 25, weight: .regular))
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("현재 추천에서 제외")
            Button {
                Task { await model.toggleStar(song: song) }
            } label: {
                Image(systemName: song.isStarred ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(song.isStarred ? Color.green : Color.white)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(song.isStarred ? "좋아요 취소" : "좋아요 표시")
        }
        .padding(.bottom, 18)
    }

    private var progress: some View {
        VStack(spacing: 4) {
            Slider(
                value: $scrubValue,
                in: 0...max(audio.duration, 1),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing { audio.seek(to: scrubValue) }
                }
            )
            .tint(.white)
            .accessibilityLabel("재생 위치")
            HStack {
                Text((isScrubbing ? scrubValue : audio.elapsed).playbackText)
                Spacer()
                Text("-\(max(0, audio.duration - (isScrubbing ? scrubValue : audio.elapsed)).playbackText)")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.64))
            .monospacedDigit()
        }
    }

    private var transport: some View {
        HStack {
            control(
                audio.isShuffleEnabled ? "shuffle.circle.fill" : "shuffle",
                size: 23,
                active: audio.isShuffleEnabled,
                label: "셔플"
            ) { audio.toggleShuffle() }
            Spacer()
            control("backward.end.fill", size: 33, label: "이전 곡") { audio.previous() }
            Spacer()
            Button {
                audio.togglePlayback()
            } label: {
                ZStack {
                    Circle().fill(.white).frame(width: 64, height: 64)
                    if audio.isBuffering {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 27, weight: .bold))
                            .foregroundStyle(Color(palette.bottom))
                            .offset(x: audio.isPlaying ? 0 : 2)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(audio.isPlaying ? "일시정지" : "재생")
            Spacer()
            control("forward.end.fill", size: 33, label: "다음 곡") { audio.next() }
            Spacer()
            control(
                audio.repeatMode == .one ? "repeat.1" : "repeat",
                size: 23,
                active: audio.repeatMode != .off,
                label: "반복"
            ) { audio.cycleRepeat() }
        }
        .frame(height: 104)
    }

    private func utilityRow(_ song: Song) -> some View {
        HStack(spacing: 25) {
            AirPlayButton()
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
            .padding(18)
            .foregroundStyle(.white)
            .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 18))
            .contentShape(RoundedRectangle(cornerRadius: 18))
            .buFiGlass(cornerRadius: 18, interactive: true)
            .padding(.top, 8)
        } else {
            Text("이 곡에는 표시할 가사가 없습니다.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
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
            return .black.opacity(0.76)
        }
        if index == audio.activeLyricIndex { return .white }
        if index < audio.activeLyricIndex { return .white.opacity(0.34) }
        return .black.opacity(0.78)
    }

    private func control(
        _ icon: String,
        size: CGFloat,
        active: Bool = false,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(active ? Color.green : Color.white)
                .frame(width: 42, height: 42)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private struct FullLyricsView: View {
    @EnvironmentObject private var audio: AudioEngine
    @Environment(\.dismiss) private var dismiss

    let palette: ArtworkPalette
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(palette.top), Color(palette.bottom)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                lyrics
                footer
            }
        }
        .preferredColorScheme(.dark)
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
                    .foregroundStyle(.white.opacity(0.7))
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
                guard audio.lyrics.lines.indices.contains(index) else { return }
                withAnimation(.easeInOut(duration: 0.42)) {
                    proxy.scrollTo(audio.lyrics.lines[index].id, anchor: .center)
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Slider(
                value: $scrubValue,
                in: 0...max(audio.duration, 1),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing { audio.seek(to: scrubValue) }
                }
            )
            .tint(.white)
            HStack {
                Text((isScrubbing ? scrubValue : audio.elapsed).playbackText)
                Spacer()
                Text("-\(max(0, audio.duration - (isScrubbing ? scrubValue : audio.elapsed)).playbackText)")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.66))
            .monospacedDigit()

            Button { audio.togglePlayback() } label: {
                Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 29, weight: .bold))
                    .foregroundStyle(Color(palette.bottom))
                    .frame(width: 72, height: 72)
                    .background(.white, in: Circle())
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
        if index == audio.activeLyricIndex { return .white }
        if index < audio.activeLyricIndex { return .white.opacity(0.36) }
        return .black.opacity(0.80)
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
                                            .foregroundStyle(index == audio.queueIndex ? .green : .primary)
                                            .lineLimit(1)
                                        Text(song.artist)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if index == audio.queueIndex {
                                        Image(systemName: "speaker.wave.2.fill")
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("다음 재생")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
    }
}
