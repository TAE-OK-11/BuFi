import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: AppSessionState
    @EnvironmentObject private var audio: AudioEngine
    @State private var offlineBytes: Int64 = 0
    @State private var confirmOfflineRemoval = false
    @State private var confirmArtworkRemoval = false
    @State private var confirmLogout = false
    @State private var isLoggingOut = false
    @AppStorage("appearance-mode") private var appearanceMode = AppAppearance.system.rawValue
    @AppStorage("motion-enabled") private var motionEnabled = true
    @AppStorage("player-seekbar-appearance")
    private var playerAppearance = PlayerAppearance.liquidGlass.rawValue
    @AppStorage("player-background-appearance")
    private var playerBackgroundAppearance = PlayerBackgroundAppearance.classic.rawValue
    @AppStorage("haptics-enabled") private var hapticsEnabled = true
    @AppStorage("auto-open-player") private var autoOpenPlayer = false
    @AppStorage("lyrics-auto-scroll") private var lyricsAutoScroll = true
    @AppStorage("restore-play-queue") private var restorePlayQueue = true
    @AppStorage("algorithmic-autoplay-enabled")
    private var algorithmicAutoplayEnabled = true
    @AppStorage("keep-screen-awake") private var keepScreenAwake = false
    @AppStorage("server-sync-interval") private var syncInterval = 300.0
    @AppStorage("offline-wifi-only") private var offlineWiFiOnly = true
    @AppStorage("offline-prefetch-count") private var offlinePrefetchCount = 0
    @AppStorage("offline-storage-limit-gb") private var offlineStorageLimitGB = 10.0

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    BuFiPageHeader(title: "설정")
                    serverCard
                    appearanceSection
                    syncSection
                    recommendationSection
                    playbackSection
                    offlineSection
                    appSection
                    logoutRow
                }
                .padding(.top, 18)
                .buFiMiniPlayerContentClearance()
            }
            .background(BuFiScreenBackground())
            .toolbar(.hidden, for: .navigationBar)
            .tint(BuFiTheme.accent)
            .task {
                offlineBytes = await OfflineStore.shared.totalBytes()
            }
            .onChange(of: restorePlayQueue) { _, enabled in
                audio.setQueueRestoration(enabled: enabled)
            }
            .onChange(of: keepScreenAwake) { _, _ in
                audio.refreshIdleTimerPreference()
            }
            .confirmationDialog(
                "오프라인 음악을 모두 삭제할까요?",
                isPresented: $confirmOfflineRemoval,
                titleVisibility: .visible
            ) {
                Button("모두 삭제", role: .destructive) {
                    Task {
                        try? await OfflineStore.shared.removeAll()
                        offlineBytes = await OfflineStore.shared.totalBytes()
                    }
                }
                Button("취소", role: .cancel) {}
            } message: {
                Text("다운로드한 음악만 삭제되며 서버의 원본은 유지됩니다.")
            }
            .confirmationDialog(
                "앨범 이미지 캐시를 비울까요?",
                isPresented: $confirmArtworkRemoval,
                titleVisibility: .visible
            ) {
                Button("캐시 비우기", role: .destructive) {
                    Task { await ArtworkStore.shared.clearAll() }
                }
                Button("취소", role: .cancel) {}
            } message: {
                Text("이미지는 필요할 때 서버에서 다시 불러옵니다.")
            }
            .confirmationDialog(
                "로그아웃할까요?",
                isPresented: $confirmLogout,
                titleVisibility: .visible
            ) {
                Button("로그아웃", role: .destructive) {
                    isLoggingOut = true
                    Task { @MainActor in
                        await model.logout()
                        isLoggingOut = false
                    }
                }
                Button("취소", role: .cancel) {}
            } message: {
                Text("서버 로그인 정보가 이 기기에서 삭제되고 현재 재생이 중지됩니다. 다운로드한 음악은 유지됩니다.")
            }
        }
    }

    private var serverCard: some View {
        BuFiGroupedSurface {
            HStack(spacing: 14) {
                Circle()
                    .fill(BuFiTheme.accent.opacity(0.14))
                    .frame(width: 52, height: 52)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(BuFiTheme.accent)
                    }
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: serverTitle)
                        .font(.system(size: 18, weight: .bold))
                        .lineLimit(2)
                    Text(serverDescription)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                ServerLatencyBadge(client: model.client)
            }
            .padding(16)
        }
        .padding(.horizontal, 16)
    }

    private var appearanceSection: some View {
        SettingsGroup(title: "화면 및 동작") {
            VStack(alignment: .leading, spacing: 16) {
                settingLabel("화면 모드", icon: "circle.lefthalf.filled")
                Picker("화면 모드", selection: $appearanceMode) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                settingsDivider

                settingLabel("플레이어 스타일", icon: "music.note.house")
                Picker("플레이어 스타일", selection: $playerAppearance) {
                    ForEach(PlayerAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                settingsNote("Classic은 기존 디자인을 유지하고 Liquid Glass는 재생바만 Apple 스타일로 표시합니다. Dynamic은 잠금화면처럼 제어 요소를 유리 카드에 모읍니다.")

                settingsDivider

                settingLabel("플레이어 배경", icon: "paintpalette.fill")
                Picker("플레이어 배경", selection: $playerBackgroundAppearance) {
                    ForEach(PlayerBackgroundAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                settingsNote("기본은 대표색을 단색으로, 다중 컬러는 앨범 속 색의 위치를 반영합니다. 밝게는 추출색만 더 밝고 선명하게 표시합니다.")

                settingsDivider

                Toggle(isOn: $motionEnabled) {
                    Label("애니메이션 및 모션", systemImage: "sparkles")
                        .font(.system(size: 16, weight: .semibold))
                }
                settingsNote("동작 줄이기, 저전력 모드 또는 기기 온도가 높을 때는 자동으로 모션을 줄입니다.")
                Toggle(isOn: $hapticsEnabled) {
                    Label("햅틱 피드백", systemImage: "waveform.path")
                        .font(.system(size: 16, weight: .semibold))
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var syncSection: some View {
        SettingsGroup(title: "서버 동기화") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    settingLabel("자동 동기화 주기", icon: "arrow.triangle.2.circlepath")
                    Spacer(minLength: 8)
                    Picker("자동 동기화 주기", selection: $syncInterval) {
                        Text("30초").tag(30.0)
                        Text("1분").tag(60.0)
                        Text("5분").tag(300.0)
                        Text("15분").tag(900.0)
                    }
                    .labelsHidden()
                    .tint(.secondary)
                }
                settingsNote("활성 화면을 선택한 주기로 확인합니다. 재생 중에는 간격을 늘리고 저전력·고온 상태에서는 자동 동기화를 멈춥니다.")
            }
        }
        .padding(.horizontal, 16)
    }

    private var recommendationSection: some View {
        SettingsGroup(title: "추천") {
            NavigationLink {
                RecommendationSettingsView()
                    .environmentObject(model)
                    .environmentObject(audio)
                    .environmentObject(audio.playbackState)
            } label: {
                HStack(spacing: 12) {
                    settingIcon("wand.and.stars")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("추천 알고리즘")
                            .font(.system(size: 16, weight: .semibold))
                        Text("취향 가중치와 외부 추천 서비스")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
    }

    private var playbackSection: some View {
        SettingsGroup(title: "재생") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    settingLabel("음질", icon: "waveform")
                    Spacer(minLength: 8)
                    Picker("음질", selection: $audio.quality) {
                        ForEach(StreamQuality.allCases) { quality in
                            Text(quality.title).tag(quality)
                        }
                    }
                    .labelsHidden()
                    .tint(.secondary)
                }
                settingsNote("자동은 iPhone이 지원하는 형식은 원본으로 재생하고, 지원하지 않는 형식은 서버에서 AAC 256kbps로 변환합니다.")

                settingsDivider

                settingsToggle("플레이어 자동 열기", icon: "rectangle.expand.vertical", value: $autoOpenPlayer)
                settingsToggle("재생 대기목록 기억", icon: "clock.arrow.circlepath", value: $restorePlayQueue)
                settingsToggle("추천곡 계속 재생", icon: "infinity.circle", value: $algorithmicAutoplayEnabled)
                settingsNote("재생목록이 끝나기 전에 서버 유사곡을 추가해 음악이 끊기지 않도록 합니다.")

                settingsDivider

                HStack(spacing: 12) {
                    settingLabel("셔플 방식", icon: "shuffle")
                    Spacer(minLength: 8)
                    Picker("셔플 방식", selection: $audio.shuffleStyle) {
                        ForEach(ShuffleStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    .labelsHidden()
                    .tint(.secondary)
                }
                settingsNote("반복 줄이기는 최근 재생곡을 피해서 같은 곡이 짧은 간격으로 나오는 현상을 줄입니다.")

                settingsDivider

                settingsToggle("가사 자동 스크롤", icon: "text.line.first.and.arrowtriangle.forward", value: $lyricsAutoScroll)
                settingsToggle("재생 중 화면 켜두기", icon: "sun.max", value: $keepScreenAwake)
                HStack(spacing: 12) {
                    settingLabel("AirPlay", icon: "airplayaudio")
                    Spacer()
                    AirPlayButton()
                        .frame(width: 42, height: 34)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var offlineSection: some View {
        SettingsGroup(title: "오프라인 및 저장 공간") {
            VStack(alignment: .leading, spacing: 14) {
                settingsToggle("Wi-Fi에서만 저장", icon: "wifi", value: $offlineWiFiOnly)

                settingsDivider

                HStack(spacing: 12) {
                    settingLabel("다음 곡 선캐시", icon: "arrow.down.circle")
                    Spacer(minLength: 8)
                    Picker("다음 곡 선캐시", selection: $offlinePrefetchCount) {
                        Text("끔").tag(0)
                        Text("1곡").tag(1)
                        Text("3곡").tag(3)
                    }
                    .labelsHidden()
                    .tint(.secondary)
                }
                settingsNote("선캐시는 곡 전환을 빠르게 하지만 전체 음원을 미리 저장합니다. 저전력·고온 상태에서는 자동으로 제한됩니다.")

                HStack(spacing: 12) {
                    settingLabel("용량 제한", icon: "externaldrive")
                    Spacer(minLength: 8)
                    Picker("오프라인 용량 제한", selection: $offlineStorageLimitGB) {
                        Text("5 GB").tag(5.0)
                        Text("10 GB").tag(10.0)
                        Text("25 GB").tag(25.0)
                        Text("제한 없음").tag(0.0)
                    }
                    .labelsHidden()
                    .tint(.secondary)
                }

                HStack {
                    Text("사용 중인 저장 공간")
                    Spacer()
                    Text(offlineStorageText)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                settingsDivider

                Button("오프라인 음악 모두 삭제", role: .destructive) {
                    confirmOfflineRemoval = true
                }
                Button("앨범 이미지 캐시 비우기") {
                    confirmArtworkRemoval = true
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var appSection: some View {
        SettingsGroup(title: "앱") {
            VStack(alignment: .leading, spacing: 14) {
                LabeledContent("최소 iOS", value: "17.0")
                LabeledContent("버전", value: versionText)
                settingsDivider
                Label("적응형 배터리·메모리 최적화", systemImage: "leaf.fill")
                    .foregroundStyle(.primary)
                Label("분석·광고 SDK 없음", systemImage: "hand.raised.fill")
                    .foregroundStyle(.primary)
                settingsDivider
                NavigationLink {
                    OpenSourceNoticesView()
                } label: {
                    HStack {
                        Label("오픈소스 및 라이선스", systemImage: "doc.text")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    private var logoutRow: some View {
        BuFiGroupedSurface {
            Button(role: .destructive) {
                confirmLogout = true
            } label: {
                HStack {
                    Text("로그아웃")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(.red)
                    Spacer()
                    if isLoggingOut {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.secondary)
                    }
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isLoggingOut)
        }
        .padding(.horizontal, 16)
    }

    private func settingsToggle(
        _ title: LocalizedStringKey,
        icon: String,
        value: Binding<Bool>
    ) -> some View {
        Toggle(isOn: value) {
            settingLabel(title, icon: icon)
        }
        .font(.system(size: 16, weight: .semibold))
    }

    private func settingLabel(
        _ title: LocalizedStringKey,
        icon: String
    ) -> some View {
        Label {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
        } icon: {
            settingIcon(icon)
        }
    }

    private func settingIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(BuFiTheme.accent)
            .frame(width: 30, height: 30)
            .background(BuFiTheme.accent.opacity(0.11), in: Circle())
    }

    private func settingsNote(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var settingsDivider: some View {
        Divider()
            .overlay(BuFiTheme.separator.opacity(0.34))
    }

    private var serverTitle: String {
        session.connectedServerAddress.isEmpty
            ? String(localized: "연결된 서버")
            : session.connectedServerAddress
    }

    private var serverDescription: String {
        let serverVersion = session.serverVersion
        let subsonicAPIVersion = session.subsonicAPIVersion

        if !serverVersion.isEmpty, !subsonicAPIVersion.isEmpty {
            return String(
                format: String(localized: "서버 %@ · Subsonic API %@"),
                serverVersion,
                subsonicAPIVersion
            )
        }
        if !serverVersion.isEmpty {
            return String(
                format: String(localized: "서버 %@"),
                serverVersion
            )
        }
        if !subsonicAPIVersion.isEmpty {
            return String(
                format: String(localized: "Subsonic API %@"),
                subsonicAPIVersion
            )
        }
        return "OpenSubsonic"
    }

    private var offlineStorageText: String {
        ByteCountFormatter.string(
            fromByteCount: offlineBytes,
            countStyle: .file
        )
    }

    private var versionText: String {
        let version =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.0.0"
        let build =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "1"
        return "\(version) (\(build))"
    }
}

private struct SettingsGroup<Content: View>: View {
    let title: LocalizedStringKey
    let content: Content

    init(
        title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .tracking(-0.45)
                .padding(.horizontal, 2)
            BuFiGroupedSurface {
                content
                    .padding(16)
            }
        }
    }
}

private struct SettingsActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.buFiMotionEnabled) private var motionEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(
                isEnabled ? BuFiTheme.accent : Color.secondary.opacity(0.28),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .scaleEffect(configuration.isPressed && motionEnabled ? 0.98 : 1)
            .animation(
                motionEnabled ? BuFiMotion.tap : .none,
                value: configuration.isPressed
            )
    }
}

private extension View {
    func settingsTextField() -> some View {
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 14)
            .frame(height: 50)
            .background(
                Color.primary.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(BuFiTheme.separator.opacity(0.30), lineWidth: 0.7)
            }
    }
}

private struct RecommendationSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: AppSessionState
    @EnvironmentObject private var audio: AudioEngine
    @EnvironmentObject private var playbackState: PlaybackState
    @State private var currentSignature: LyricSignature?
    @State private var showCurrentAnalysisEditor = false
    @State private var probe: LyricIntelligenceProbe?
    @State private var isProbing = false
    @State private var coverage = LyricAnalysisCoverage.empty
    @State private var batchProgress = LyricBatchProgress.idle
    @State private var batchTask: Task<Void, Never>?
    @State private var confirmFullLyricReanalysis = false
    @State private var lastFMAPIKey = ""
    @State private var listenBrainzUsername = ""
    @State private var listenBrainzToken = ""
    @AppStorage("recommendation-weight-history") private var historyWeight = 0.70
    @AppStorage("recommendation-weight-favorites") private var favoriteWeight = 0.80
    @AppStorage("recommendation-weight-server") private var serverWeight = 0.90
    @AppStorage("recommendation-weight-discovery") private var discoveryWeight = 0.35
    @AppStorage("recommendation-weight-lastfm") private var lastFMWeight = 0.55
    @AppStorage("recommendation-weight-listenbrainz")
    private var listenBrainzWeight = 0.55
    @AppStorage("recommendation-weight-behavior")
    private var behaviorWeight = 0.85
    @AppStorage("recommendation-weight-completion")
    private var completionWeight = 0.70
    @AppStorage("recommendation-weight-repeat")
    private var repeatWeight = 0.55
    @AppStorage("recommendation-weight-recency")
    private var recencyWeight = 0.65
    @AppStorage("recommendation-weight-context")
    private var contextWeight = 0.60
    @AppStorage("recommendation-weight-metadata")
    private var metadataWeight = 0.60
    @AppStorage("recommendation-weight-playlist-affinity")
    private var playlistAffinityWeight = 0.55
    @AppStorage("recommendation-weight-album-completion")
    private var albumCompletionWeight = 0.45
    @AppStorage("recommendation-weight-forgotten-favorites")
    private var forgottenFavoritesWeight = 0.50
    @AppStorage("recommendation-weight-artist-rotation")
    private var artistRotationWeight = 0.45
    @AppStorage("recommendation-weight-time-awareness")
    private var timeAwarenessWeight = 0.30
    @AppStorage("recommendation-weight-lyric-mood")
    private var lyricMoodWeight = 0.50
    @AppStorage("recommendation-discovery-ratio")
    private var discoveryRatio = 0.35
    @AppStorage("lyric-intelligence-provider")
    private var lyricProviderRaw = LyricIntelligenceProviderKind.onDevice.rawValue
    @AppStorage("lyric-intelligence-openrouter-model")
    private var openRouterModel = LyricIntelligenceSettings.defaultOpenRouterModel
    @AppStorage("lyric-intelligence-groq-model")
    private var groqModel = LyricIntelligenceSettings.defaultGroqModel
    @AppStorage("lyric-intelligence-cerebras-model")
    private var cerebrasModel = LyricIntelligenceSettings.defaultCerebrasModel
    @AppStorage("recommendation-llm-review-enabled")
    private var llmReviewEnabled = false
    @State private var openAIKey = ""
    @State private var openRouterKey = ""
    @State private var groqKey = ""
    @State private var cerebrasKey = ""

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                BuFiPageHeader(title: "추천 알고리즘")

                SettingsGroup(title: "핵심 추천 가중치") {
                    VStack(spacing: 18) {
                        weightRow("청취 기록 취향", value: $historyWeight)
                        weightRow("좋아요 취향", value: $favoriteWeight)
                        weightRow("서버 유사곡·Sonic", value: $serverWeight)
                        weightRow("새로운 음악 발견", value: $discoveryWeight)
                        weightRow("Last.fm 유사곡", value: $lastFMWeight)
                        weightRow("ListenBrainz 추천", value: $listenBrainzWeight)
                        weightRow("재생 행동", value: $behaviorWeight)
                        weightRow("완주율", value: $completionWeight)
                        weightRow("반복 재생", value: $repeatWeight)
                        weightRow("최근 취향", value: $recencyWeight)
                        weightRow("현재 세션 흐름", value: $contextWeight)
                    }
                }
                .padding(.horizontal, 16)

                SettingsGroup(title: "발견 비율") {
                    VStack(alignment: .leading, spacing: 12) {
                        weightRow("새로운 곡·아티스트 비율", value: $discoveryRatio)
                        settingsDescription("점수에 곱하지 않고 최종 목록에서 익숙한 음악과 새로운 음악의 구성 비율을 조절합니다.")
                    }
                }
                .padding(.horizontal, 16)

                SettingsGroup(title: "고급 추천 신호") {
                    VStack(alignment: .leading, spacing: 18) {
                        weightRow("장르·BPM·분위기 메타데이터", value: $metadataWeight)
                        weightRow("플레이리스트 연관성", value: $playlistAffinityWeight)
                        weightRow("듣던 앨범 이어 듣기", value: $albumCompletionWeight)
                        weightRow("잊고 있던 좋아요", value: $forgottenFavoritesWeight)
                        weightRow("아티스트 순환", value: $artistRotationWeight)
                        weightRow("시간대 맞춤", value: $timeAwarenessWeight)
                        weightRow("가사 분위기", value: $lyricMoodWeight)
                        Button("기본값으로 복원") {
                            restoreDefaults()
                        }
                        .font(.system(size: 15, weight: .semibold))
                        settingsDescription("모든 입력은 0~1로 정규화되며, 낮은 메타데이터 매칭 신뢰도와 반복 조기 스킵은 별도로 감점합니다.")
                    }
                }
                .padding(.horizontal, 16)

                SettingsGroup(title: "Last.fm") {
                    VStack(alignment: .leading, spacing: 14) {
                        SecureField(
                            session.hasLastFMAPIKey
                                ? "저장된 API 키 교체"
                                : "Last.fm API 키",
                            text: $lastFMAPIKey
                        )
                        .settingsTextField()
                        Button(session.hasLastFMAPIKey ? "API 키 갱신" : "API 키 저장") {
                            Task { @MainActor in
                                await model.saveLastFMAPIKey(lastFMAPIKey)
                                lastFMAPIKey = ""
                            }
                        }
                        .buttonStyle(SettingsActionButtonStyle())
                        .disabled(lastFMAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if session.hasLastFMAPIKey {
                            Button("Last.fm 연동 해제", role: .destructive) {
                                Task { await model.saveLastFMAPIKey("") }
                            }
                        }
                        settingsDescription("track.getSimilar은 API 키가 필요하지만 별도 사용자 로그인은 필요하지 않습니다.")
                    }
                }
                .padding(.horizontal, 16)

                SettingsGroup(title: "ListenBrainz") {
                    VStack(alignment: .leading, spacing: 14) {
                        TextField("사용자 이름", text: $listenBrainzUsername)
                            .settingsTextField()
                        SecureField(
                            session.hasListenBrainzToken
                                ? "저장된 토큰 유지 또는 교체"
                                : "사용자 토큰",
                            text: $listenBrainzToken
                        )
                        .settingsTextField()
                        Button("ListenBrainz 설정 저장") {
                            let username = listenBrainzUsername
                            let token = listenBrainzToken
                            Task { @MainActor in
                                let saved = await model.saveListenBrainz(
                                    username: username,
                                    token: token
                                )
                                if saved { listenBrainzToken = "" }
                            }
                        }
                        .buttonStyle(SettingsActionButtonStyle())
                        .disabled(
                            listenBrainzUsername
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .isEmpty
                        )
                        if session.hasListenBrainzToken || !session.listenBrainzUsername.isEmpty {
                            Button("ListenBrainz 연동 해제", role: .destructive) {
                                Task { @MainActor in
                                    if await model.removeListenBrainz() {
                                        listenBrainzUsername = ""
                                        listenBrainzToken = ""
                                    }
                                }
                            }
                        }
                        settingsDescription("협업 필터 추천 MBID를 받아 서버 라이브러리에 실제로 있는 곡만 매칭합니다.")
                    }
                }
                .padding(.horizontal, 16)

                SettingsGroup(title: "가사 지능") {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("분석 엔진", selection: $lyricProviderRaw) {
                            ForEach(LyricIntelligenceProviderKind.visibleCases) { kind in
                                Text(kind.title).tag(kind.rawValue)
                            }
                        }
                        .pickerStyle(.menu)
                        Toggle("LLM 추천 검수", isOn: $llmReviewEnabled)
                            .font(.system(size: 15, weight: .semibold))
                            .onChange(of: llmReviewEnabled) { _, _ in
                                RecommendationMixer.invalidateCache()
                                model.rebuildRecommendations()
                            }
                        settingsDescription("켜면 알고리즘이 후보를 줄인 뒤, 가사 요약·분위기·음향 분석을 LLM이 한 번 더 보고 순서를 다듬습니다. 꺼두면 점수만 씁니다.")
                        settingsDescription(lyricEngineDescription)
                        if usesOnDeviceFallback {
                            SecureField(
                                session.hasOpenRouterKey
                                    ? "Gemma 3 대체용 OpenRouter 키 유지/교체"
                                    : "Gemma 3용 OpenRouter 키 (선택)",
                                text: $openRouterKey
                            )
                            .settingsTextField()
                            Button(session.hasOpenRouterKey ? "키 갱신" : "키 저장") {
                                Task {
                                    await model.saveLyricAPIKey(
                                        openRouterKey,
                                        provider: .openRouter
                                    )
                                    openRouterKey = ""
                                }
                            }
                            .buttonStyle(SettingsActionButtonStyle())
                            .disabled(
                                openRouterKey
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                    .isEmpty
                            )
                        }
                        if lyricProviderRaw == LyricIntelligenceProviderKind.openAI.rawValue {
                            SecureField(
                                session.hasOpenAIKey ? "저장된 OpenAI 키 교체" : "OpenAI API 키",
                                text: $openAIKey
                            )
                            .settingsTextField()
                            Button(session.hasOpenAIKey ? "OpenAI 키 갱신" : "OpenAI 키 저장") {
                                Task {
                                    await model.saveLyricAPIKey(openAIKey, provider: .openAI)
                                    openAIKey = ""
                                }
                            }
                            .buttonStyle(SettingsActionButtonStyle())
                            .disabled(openAIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        if lyricProviderRaw == LyricIntelligenceProviderKind.openRouter.rawValue {
                            TextField("OpenRouter 모델", text: $openRouterModel)
                                .settingsTextField()
                            SecureField(
                                session.hasOpenRouterKey
                                    ? "저장된 OpenRouter 키 교체"
                                    : "OpenRouter API 키",
                                text: $openRouterKey
                            )
                            .settingsTextField()
                            Button(session.hasOpenRouterKey ? "OpenRouter 키 갱신" : "OpenRouter 키 저장") {
                                Task {
                                    await model.saveLyricAPIKey(
                                        openRouterKey,
                                        provider: .openRouter
                                    )
                                    openRouterKey = ""
                                }
                            }
                            .buttonStyle(SettingsActionButtonStyle())
                            .disabled(
                                openRouterKey
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                    .isEmpty
                            )
                        }
                        if lyricProviderRaw == LyricIntelligenceProviderKind.groq.rawValue {
                            Picker("Groq 모델", selection: $groqModel) {
                                Text("Llama 3.3 70B").tag("llama-3.3-70b-versatile")
                                Text("GPT-OSS 120B").tag("openai/gpt-oss-120b")
                                Text("Llama 3.1 8B").tag("llama-3.1-8b-instant")
                            }
                            .pickerStyle(.menu)
                            TextField("Groq 모델 ID", text: $groqModel)
                                .settingsTextField()
                            SecureField(
                                session.hasGroqKey
                                    ? "저장된 Groq 키 교체"
                                    : "Groq API 키",
                                text: $groqKey
                            )
                            .settingsTextField()
                            Button(session.hasGroqKey ? "Groq 키 갱신" : "Groq 키 저장") {
                                Task {
                                    await model.saveLyricAPIKey(groqKey, provider: .groq)
                                    groqKey = ""
                                }
                            }
                            .buttonStyle(SettingsActionButtonStyle())
                            .disabled(
                                groqKey
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                    .isEmpty
                            )
                        }
                        if lyricProviderRaw == LyricIntelligenceProviderKind.cerebras.rawValue {
                            Picker("Cerebras 모델", selection: $cerebrasModel) {
                                Text("Llama 3.3 70B").tag("llama-3.3-70b")
                                Text("GPT-OSS 120B").tag("gpt-oss-120b")
                            }
                            .pickerStyle(.menu)
                            TextField("Cerebras 모델 ID", text: $cerebrasModel)
                                .settingsTextField()
                            SecureField(
                                session.hasCerebrasKey
                                    ? "저장된 Cerebras 키 교체"
                                    : "Cerebras API 키",
                                text: $cerebrasKey
                            )
                            .settingsTextField()
                            Button(session.hasCerebrasKey ? "Cerebras 키 갱신" : "Cerebras 키 저장") {
                                Task {
                                    await model.saveLyricAPIKey(
                                        cerebrasKey,
                                        provider: .cerebras
                                    )
                                    cerebrasKey = ""
                                }
                            }
                            .buttonStyle(SettingsActionButtonStyle())
                            .disabled(
                                cerebrasKey
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                    .isEmpty
                            )
                        }
                        lyricIntelligenceTestSection
                    }
                }
                .padding(.horizontal, 16)

                SettingsGroup(title: "가사 분석 진행") {
                    lyricAnalysisProgressSection
                }
                .padding(.horizontal, 16)
            }
            .padding(.top, 18)
            .buFiMiniPlayerContentClearance()
        }
        .background(BuFiScreenBackground())
        .toolbar(.visible, for: .navigationBar)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .tint(BuFiTheme.accent)
        .confirmationDialog(
            "기존 분석을 모두 지우고 새로 분석할까요?",
            isPresented: $confirmFullLyricReanalysis,
            titleVisibility: .visible
        ) {
            Button("모두 지우고 새로 분석", role: .destructive) {
                startFullLyricReanalysis()
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("저장된 가사 요약·분위기·임베딩·음향 분석을 초기화하고 현재 라이브러리를 선택한 엔진으로 처음부터 다시 분석합니다. 원격 엔진은 API 사용량이 발생할 수 있습니다.")
        }
        .sheet(isPresented: $showCurrentAnalysisEditor) {
            if let song = playbackState.currentSong {
                CurrentLyricAnalysisEditor(
                    song: song,
                    signature: currentSignature,
                    onSave: { draft in
                        await saveCurrentAnalysisEdit(draft)
                    },
                    onReanalyze: {
                        await reanalyzeCurrentSong()
                    }
                )
            } else {
                ContentUnavailableView(
                    "재생 중인 곡 없음",
                    systemImage: "music.note",
                    description: Text("곡을 재생한 뒤 다시 열어주세요.")
                )
            }
        }
        .onAppear {
            listenBrainzUsername = session.listenBrainzUsername
            if lyricProviderRaw == LyricIntelligenceProviderKind.applePrivateCloud.rawValue,
               !LyricIntelligenceProviderKind.applePrivateCloud.isVisibleInSettings {
                lyricProviderRaw = LyricIntelligenceProviderKind.onDevice.rawValue
            }
        }
        .task(id: playbackState.currentSong?.id) {
            currentSignature = await currentSongSignature()
        }
        .task {
            await refreshCoverage()
            let latest = await LyricIntelligence.shared.currentBatchProgress()
            batchProgress = latest
            if latest.isRunning {
                watchBatchProgress()
            }
        }
    }

    @ViewBuilder
    private var lyricAnalysisProgressSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsDescription(
                String(
                    localized: "알고 있는 곡 \(coverage.known) · 분석됨 \(coverage.lyricDone) · 남음 \(coverage.pending.count) · 음향 \(coverage.soundDone) · 음향 대기 \(coverage.needsSound.count) · 요약 대기 \(coverage.needsResummary.count)"
                )
            )
            if batchProgress.isRunning || batchProgress.processed > 0 {
                ProgressView(value: batchProgress.fraction)
                    .tint(BuFiTheme.accent)
                settingsDescription(batchStatusText)
            }
            if !coverage.done.isEmpty {
                DisclosureGroup("분석된 곡 \(coverage.done.count)") {
                    songStatusList(coverage.done, pending: false)
                }
            }
            if !coverage.pending.isEmpty {
                DisclosureGroup("아직 안 된 곡 \(coverage.pending.count)") {
                    songStatusList(coverage.pending, pending: true)
                }
            }
            if !coverage.needsSound.isEmpty {
                DisclosureGroup("음향 없는 곡 \(coverage.needsSound.count)") {
                    songStatusList(coverage.needsSound, pending: false)
                }
            }
            if !coverage.needsResummary.isEmpty {
                DisclosureGroup("요약 다시 할 곡 \(coverage.needsResummary.count)") {
                    songStatusList(coverage.needsResummary, pending: false)
                }
            }
            if coverage.known == 0 {
                settingsDescription("홈·청취 기록에 곡이 생기면 여기에 집계됩니다.")
            }
            if batchProgress.isRunning {
                Button("분석 중단") {
                    batchTask?.cancel()
                    Task { await LyricIntelligence.shared.cancelBatch() }
                }
                .buttonStyle(SettingsActionButtonStyle())
            } else {
                Button("지금 곡 다시 분석") {
                    startCurrentSongReanalysis()
                }
                .buttonStyle(SettingsActionButtonStyle())
                .disabled(
                    playbackState.currentSong == nil
                        || lyricProviderRaw == LyricIntelligenceProviderKind.off.rawValue
                )
                Button("안 된 곡 전부 분석") {
                    startPendingAnalysis()
                }
                .buttonStyle(SettingsActionButtonStyle())
                .disabled(
                    coverage.workQueue.isEmpty
                        || lyricProviderRaw == LyricIntelligenceProviderKind.off.rawValue
                )
                Button("안 된 곡 Groq로 분석") {
                    startPendingAnalysis(usingGroq: true)
                }
                .buttonStyle(SettingsActionButtonStyle())
                .disabled(
                    coverage.workQueue.isEmpty
                        || !session.hasGroqKey
                )
                Button("기존 분석 지우고 전체 새로 분석", role: .destructive) {
                    confirmFullLyricReanalysis = true
                }
                .disabled(
                    coverage.known == 0
                        || lyricProviderRaw == LyricIntelligenceProviderKind.off.rawValue
                )
            }
            settingsDescription("지금 곡은 저장된 결과를 지우고 다시 돌립니다. 안 된 곡·요약이 비거나 이상한 곡·음향 없는 곡은 이어서 분석합니다. ‘전체 새로 분석’은 저장된 가사·요약·임베딩·음향 결과를 비운 뒤 현재 엔진으로 모든 곡을 처음부터 다시 돌립니다.")
        }
    }

    @ViewBuilder
    private func songStatusList(
        _ entries: [LyricAnalysisEntry],
        pending: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(entries.prefix(30))) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.song.title)
                        .font(.system(size: 14, weight: .semibold))
                    Text(songStatusDetail(entry, pending: pending))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            if entries.count > 30 {
                Text("외 \(entries.count - 30)곡")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 6)
    }

    @ViewBuilder
    private var lyricIntelligenceTestSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("실기기 시험")
                .font(.system(size: 15, weight: .semibold))
            settingsDescription(AppleFoundationLyricClient.onDeviceStatus().title)
            settingsDescription(AppleFoundationLyricClient.privateCloudStatus().title)
            if let song = playbackState.currentSong {
                if let currentSignature {
                    settingsDescription(nowPlayingAnalysisText(song: song, signature: currentSignature))
                } else {
                    settingsDescription(
                        String(
                            localized: "지금 재생 중: \(song.title). 가사가 뜨면 분석이 시작되고, 같은 가사는 다시 돌리지 않습니다."
                        )
                    )
                }
            } else {
                settingsDescription("가사가 있는 곡을 재생하면 저장된 분석이 여기에 나타납니다. 다운로드가 없으면 스트림으로 음향을 분석합니다.")
            }
            if let probe {
                settingsDescription(probeResultText(probe))
            }
            Button("현재 재생곡 분석 데이터") {
                showCurrentAnalysisEditor = true
            }
            .buttonStyle(SettingsActionButtonStyle())
            .disabled(playbackState.currentSong == nil)
            Button(isProbing ? "분석 중…" : "샘플 가사로 시험") {
                Task { await runLyricProbe() }
            }
            .buttonStyle(SettingsActionButtonStyle())
            .disabled(isProbing)
            settingsDescription("누를 때마다 지금 고른 엔진으로 새 LLM 세션을 만들어 샘플 가사를 실제 분석합니다. LLM이 모두 실패하면 분석 완료로 저장하지 않습니다.")
        }
    }

    private var batchStatusText: String {
        if batchProgress.isCancelled {
            return String(
                localized: "중단됨 · \(batchProgress.processed)/\(batchProgress.total) · 새로 \(batchProgress.analyzed) · 캐시 \(batchProgress.cached) · 가사 없음 \(batchProgress.noLyrics)"
            )
        }
        if batchProgress.isRunning {
            let current = batchProgress.currentTitle.isEmpty
                ? String(localized: "준비 중")
                : batchProgress.currentTitle
            return String(
                localized: "\(batchProgress.processed)/\(batchProgress.total) · \(current)"
            )
        }
        return String(
            localized: "완료 · \(batchProgress.processed)/\(batchProgress.total) · 새로 \(batchProgress.analyzed) · 캐시 \(batchProgress.cached) · 가사 없음 \(batchProgress.noLyrics) · 음향 \(batchProgress.soundAnalyzed)"
        )
    }

    private func songStatusDetail(
        _ entry: LyricAnalysisEntry,
        pending: Bool
    ) -> String {
        if pending {
            return entry.song.artist
        }
        let sound = entry.hasSound
            ? String(localized: "음향 있음")
            : String(localized: "음향 없음")
        return "\(entry.sourceTitle) · \(entry.song.artist) · \(sound)"
    }

    private func refreshCoverage() async {
        let catalog = await model.intelligenceCatalog()
        if let scope = model.client?.accountScope {
            await LyricIntelligence.shared.activate(accountScope: scope)
        }
        coverage = await LyricIntelligence.shared.coverage(catalog: catalog)
    }

    private func startPendingAnalysis(usingGroq: Bool = false) {
        batchTask?.cancel()
        batchProgress = LyricBatchProgress.idle
        batchProgress.isRunning = true
        batchTask = Task {
            let catalog = await model.intelligenceCatalog()
            guard let client = model.client else {
                batchProgress.isRunning = false
                return
            }
            let scope = client.accountScope
            var settings = await LyricIntelligenceSettings.load()
            if usingGroq {
                settings.provider = .groq
            }
            let progress = await LyricIntelligence.shared.analyzePending(
                catalog: catalog,
                accountScope: scope,
                lyricsProvider: { song in
                    await Self.lyricsText(for: song, client: client)
                },
                fileProvider: { song in
                    await SoundAnalysisSample.resolve(for: song, client: client)
                },
                settings: settings
            )
            guard !Task.isCancelled else { return }
            batchProgress = progress
            await refreshCoverage()
            currentSignature = await currentSongSignature()
            model.rebuildRecommendations()
        }
        watchBatchProgress()
    }

    private func startFullLyricReanalysis() {
        batchTask?.cancel()
        batchProgress = LyricBatchProgress.idle
        batchProgress.total = coverage.known
        batchProgress.isRunning = true
        batchProgress.currentTitle = String(localized: "기존 분석 초기화 중")
        batchTask = Task {
            let catalog = await model.intelligenceCatalog()
            guard let client = model.client else {
                batchProgress.isRunning = false
                batchProgress.currentTitle = ""
                return
            }
            let scope = client.accountScope

            await LyricIntelligence.shared.activate(accountScope: scope)
            let previousIndex = await LyricIntelligence.shared.index()
            await LyricIntelligence.shared.cancelBatch()
            await LyricIntelligence.shared.deactivate()

            let songIDs = Set(previousIndex.bySongID.keys)
                .union(catalog.map(\.id))
            for songID in songIDs {
                guard !Task.isCancelled else { return }
                let cleared = LyricSignature(
                    songID: songID,
                    lyricsHash: "",
                    moods: [],
                    themes: [],
                    energy: 0.5,
                    valence: 0.5,
                    embedding: [],
                    source: ""
                )
                _ = await AppDatabase.shared.saveTrackIntelligence(
                    cleared,
                    scope: scope
                )
            }

            guard !Task.isCancelled else { return }
            await LyricIntelligence.shared.activate(accountScope: scope)
            let settings = await LyricIntelligenceSettings.load()
            let progress = await LyricIntelligence.shared.analyzePending(
                catalog: catalog,
                accountScope: scope,
                lyricsProvider: { song in
                    await Self.lyricsText(for: song, client: client)
                },
                fileProvider: { song in
                    await SoundAnalysisSample.resolve(for: song, client: client)
                },
                force: true,
                settings: settings
            )
            guard !Task.isCancelled else { return }
            batchProgress = progress
            await refreshCoverage()
            currentSignature = await currentSongSignature()
            model.rebuildRecommendations()
        }
        watchBatchProgress()
    }

    private func startCurrentSongReanalysis() {
        batchTask?.cancel()
        batchTask = Task {
            _ = await reanalyzeCurrentSong()
        }
    }

    private func reanalyzeCurrentSong() async -> LyricSignature? {
        guard let song = playbackState.currentSong,
              let client = model.client else {
            return nil
        }
        let lyrics = await Self.lyricsText(for: song, client: client)
        guard lyrics.count >= 24 else { return nil }
        await LyricIntelligence.shared.reanalyze(
            song: song,
            lyrics: lyrics,
            accountScope: client.accountScope
        )
        if let fileURL = await SoundAnalysisSample.resolve(
            for: song,
            client: client
        ) {
            await LyricIntelligence.shared.scheduleSoundAnalysis(
                song: song,
                fileURL: fileURL,
                audioRevision: song.audioResourceRevision.isEmpty
                    ? song.id
                    : song.audioResourceRevision,
                accountScope: client.accountScope
            )
        }
        await refreshCoverage()
        currentSignature = await currentSongSignature()
        model.rebuildRecommendations()
        return currentSignature
    }

    private func saveCurrentAnalysisEdit(
        _ draft: LyricAnalysisEditDraft
    ) async -> LyricSignature? {
        guard let song = playbackState.currentSong,
              let client = model.client,
              let currentSignature else {
            return nil
        }
        let lyrics = await Self.lyricsText(for: song, client: client)
        guard lyrics.count >= 24 else { return nil }
        let updated = await LyricIntelligence.shared.saveManualEdit(
            song: song,
            lyrics: lyrics,
            accountScope: client.accountScope,
            moods: draft.combinedMoods,
            themes: draft.themeTags,
            energy: draft.energy,
            valence: draft.valence,
            summary: draft.summary,
            details: draft.makeDetails(base: currentSignature.details)
        )
        if let updated {
            self.currentSignature = updated
            await refreshCoverage()
            model.rebuildRecommendations()
        }
        return updated
    }

    private static func lyricsText(
        for song: Song,
        client: OpenSubsonicClient
    ) async -> String {
        let document = try? await client.lyrics(
            songID: song.id,
            artist: song.artist,
            title: song.title
        )
        return document?.lines
            .map(\.text)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func watchBatchProgress() {
        Task {
            while !Task.isCancelled {
                let latest = await LyricIntelligence.shared.currentBatchProgress()
                let waitingForBatchStart = await MainActor.run {
                    if latest.isRunning || latest.processed > 0 || latest.isCancelled {
                        batchProgress = latest
                    }
                    return batchProgress.isRunning
                        && !latest.isRunning
                        && latest.processed == 0
                        && !latest.isCancelled
                }
                if !latest.isRunning && !waitingForBatchStart {
                    await refreshCoverage()
                    break
                }
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
    }

    private func currentSongSignature() async -> LyricSignature? {
        guard let songID = playbackState.currentSong?.id else { return nil }
        if let scope = model.client?.accountScope {
            await LyricIntelligence.shared.activate(accountScope: scope)
        }
        return await LyricIntelligence.shared.signature(for: songID)
    }

    private func runLyricProbe() async {
        isProbing = true
        defer { isProbing = false }
        let scope = model.client?.accountScope
        probe = await LyricIntelligence.shared.probeSample(accountScope: scope)
        currentSignature = await currentSongSignature()
    }

    private func nowPlayingAnalysisText(song: Song, signature: LyricSignature) -> String {
        var parts = [
            String(localized: "지금 재생 중: \(song.title)"),
            String(localized: "가사 엔진: \(signature.sourceTitle)")
        ]
        if !signature.details.primaryMoods.isEmpty {
            parts.append(
                String(localized: "핵심 분위기: \(signature.details.primaryMoods.joined(separator: ", "))")
            )
        } else if !signature.moods.isEmpty {
            parts.append(String(localized: "분위기: \(signature.moods.joined(separator: ", "))"))
        }
        if !signature.details.secondaryMoods.isEmpty {
            parts.append(
                String(localized: "보조 분위기: \(signature.details.secondaryMoods.joined(separator: ", "))")
            )
        }
        if !signature.themes.isEmpty {
            parts.append(String(localized: "테마: \(signature.themes.joined(separator: ", "))"))
        }
        if !signature.details.emotionalArc.isEmpty {
            parts.append(String(localized: "감정 흐름: \(signature.details.emotionalArc)"))
        }
        if signature.hasStoredSummary {
            parts.append(String(localized: "요약: \(signature.summary.replacingOccurrences(of: "\n", with: " / "))"))
        }
        if signature.hasSentenceEmbedding {
            parts.append(
                String(
                    localized: "문장 임베딩: \(signature.sentenceEmbedding.count)차원 저장됨"
                )
            )
        }
        if signature.hasStoredSoundAnalysis {
            let labels = signature.soundLabels.joined(separator: ", ")
            parts.append(String(localized: "음향: \(labels)"))
        } else {
            parts.append(String(localized: "음향: 아직 없음 (다운로드된 곡을 재생하면 채워집니다)"))
        }
        return parts.joined(separator: "\n")
    }

    private func probeResultText(_ probe: LyricIntelligenceProbe) -> String {
        let cache = probe.reusedCache
            ? String(localized: "캐시에서 읽음")
            : String(localized: "새 LLM 호출")
        guard let signature = probe.signature else {
            return String(localized: "시험 결과: 분석을 저장하지 못했습니다. 가사 지능이 꺼져 있는지 확인하세요.")
        }
        let moods = signature.moods.isEmpty
            ? String(localized: "없음")
            : signature.moods.joined(separator: ", ")
        return [
            String(localized: "시험 결과: \(cache)"),
            String(localized: "엔진: \(signature.sourceTitle)"),
            String(localized: "분위기: \(moods)"),
            String(
                localized: "에너지 \(Int((signature.energy * 100).rounded()))% · 감정 \(Int((signature.valence * 100).rounded()))%"
            ),
            signature.hasStoredSummary
                ? String(localized: "요약: \(signature.summary.replacingOccurrences(of: "\n", with: " / "))")
                : String(localized: "요약: 없음"),
            signature.hasSentenceEmbedding
                ? String(localized: "문장 임베딩: \(signature.sentenceEmbedding.count)차원")
                : String(localized: "문장 임베딩: 없음")
        ].joined(separator: "\n")
    }

    private var usesOnDeviceFallback: Bool {
        lyricProviderRaw == LyricIntelligenceProviderKind.onDevice.rawValue
            || lyricProviderRaw == LyricIntelligenceProviderKind.applePrivateCloud.rawValue
    }

    private var lyricEngineDescription: String {
        switch LyricIntelligenceProviderKind(rawValue: lyricProviderRaw) ?? .onDevice {
        case .off:
            String(localized: "가사 분석을 하지 않습니다. 이미 저장한 결과는 로컬 DB에 남습니다.")
        case .onDevice, .applePrivateCloud:
            String(localized: "자동은 Apple Intelligence 3B를 곡마다 새 세션으로 호출합니다. 실패하면 저장된 Groq·Cerebras·OpenRouter·OpenAI 키의 LLM으로 순차 대체하며, 모든 LLM이 실패하면 완료 처리하지 않고 재시도 대상으로 남깁니다.")
        case .openAI:
            String(localized: "OpenAI로 가사 분위기를 분석합니다. 결과는 로컬 DB에 저장되어 같은 가사는 다시 보내지 않습니다.")
        case .openRouter:
            String(localized: "OpenRouter 모델로 가사 분위기를 분석합니다. 결과는 로컬 DB에 저장되어 같은 가사는 다시 보내지 않습니다.")
        case .groq:
            String(localized: "Groq는 모델마다 다른 프롬프트를 씁니다. Llama 3.3 70B는 태그·차선 정리에, GPT-OSS 120B는 긴 요약과 플레이리스트 연출에 맞춥니다.")
        case .cerebras:
            String(localized: "Cerebras도 Llama 3.3 70B와 GPT-OSS 120B에 각각 다른 프롬프트를 씁니다. 결과는 로컬에 남습니다.")
        }
    }

    private func weightRow(
        _ title: LocalizedStringKey,
        value: Binding<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue, format: .percent.precision(.fractionLength(0)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(
                value: value,
                in: 0...1,
                step: 0.05,
                onEditingChanged: { isEditing in
                    guard !isEditing else { return }
                    model.rebuildRecommendations()
                }
            )
                .tint(BuFiTheme.accent)
        }
    }

    private func settingsDescription(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func settingsDescription(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func restoreDefaults() {
        historyWeight = 0.70
        favoriteWeight = 0.80
        serverWeight = 0.90
        discoveryWeight = 0.35
        lastFMWeight = 0.55
        listenBrainzWeight = 0.55
        behaviorWeight = 0.85
        completionWeight = 0.70
        repeatWeight = 0.55
        recencyWeight = 0.65
        contextWeight = 0.60
        metadataWeight = 0.60
        playlistAffinityWeight = 0.55
        albumCompletionWeight = 0.45
        forgottenFavoritesWeight = 0.50
        artistRotationWeight = 0.45
        timeAwarenessWeight = 0.30
        lyricMoodWeight = 0.50
        discoveryRatio = 0.35
        model.rebuildRecommendations()
    }
}


private struct LyricAnalysisEditDraft {
    var primaryMoods: String
    var secondaryMoods: String
    var themes: String
    var energy: Double
    var valence: Double
    var emotionIntensity: Double
    var summary: String
    var explicitContent: String
    var interpretation: String
    var emotionalArc: String
    var relationship: String
    var content: String
    var narrative: String
    var setting: String
    var social: String
    var season: String
    var dayparts: String
    var listenContext: String

    init(signature: LyricSignature?) {
        let details = signature?.details ?? .empty
        let allMoods = signature?.moods ?? []
        let primary = details.primaryMoods.isEmpty
  ? Array(allMoods.prefix(3))
  : details.primaryMoods
        let secondary = details.secondaryMoods.isEmpty
  ? Array(allMoods.dropFirst(primary.count).prefix(2))
  : details.secondaryMoods
        primaryMoods = primary.joined(separator: ", ")
        secondaryMoods = secondary.joined(separator: ", ")
        themes = (signature?.themes ?? details.themes).joined(separator: ", ")
        energy = signature?.energy ?? details.energy
        valence = signature?.valence ?? details.valence
        emotionIntensity = details.emotionIntensity
        summary = signature?.summary ?? details.summary
        explicitContent = details.explicitContent
        interpretation = details.interpretation
        emotionalArc = details.emotionalArc
        relationship = details.relationship
        content = details.content
        narrative = details.narrative
        setting = details.setting
        social = details.social
        season = details.season
        dayparts = details.dayparts.joined(separator: ", ")
        listenContext = details.listenContext
    }

    var combinedMoods: [String] {
        Self.tags(primaryMoods, limit: 3) + Self.tags(secondaryMoods, limit: 2)
    }

    var themeTags: [String] {
        Self.tags(themes, limit: 5)
    }

    func makeDetails(base: LyricDetailProfile) -> LyricDetailProfile {
        var details = base
        details.primaryMoods = Self.tags(primaryMoods, limit: 3)
        details.secondaryMoods = Self.tags(secondaryMoods, limit: 2)
        details.moods = combinedMoods
        details.themes = themeTags
        details.energy = energy
        details.valence = valence
        details.emotionIntensity = emotionIntensity
        details.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        details.explicitContent = explicitContent.trimmingCharacters(in: .whitespacesAndNewlines)
        details.interpretation = interpretation.trimmingCharacters(in: .whitespacesAndNewlines)
        details.emotionalArc = emotionalArc.trimmingCharacters(in: .whitespacesAndNewlines)
        details.relationship = relationship.trimmingCharacters(in: .whitespacesAndNewlines)
        details.content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        details.narrative = narrative.trimmingCharacters(in: .whitespacesAndNewlines)
        details.setting = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        details.social = social.trimmingCharacters(in: .whitespacesAndNewlines)
        details.season = season.trimmingCharacters(in: .whitespacesAndNewlines)
        details.dayparts = Self.tags(dayparts, limit: 4)
        details.listenContext = listenContext.trimmingCharacters(in: .whitespacesAndNewlines)
        return details
    }

    private static func tags(_ raw: String, limit: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for piece in raw.split(separator: ",") {
  let value = piece.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !value.isEmpty else { continue }
  let key = LyricLexicalEmbedding.normalized(value)
  guard seen.insert(key).inserted else { continue }
  result.append(value)
  if result.count >= limit { break }
        }
        return result
    }
}

private struct CurrentLyricAnalysisEditor: View {
    @Environment(\.dismiss) private var dismiss
    let song: Song
    let signature: LyricSignature?
    let onSave: (LyricAnalysisEditDraft) async -> LyricSignature?
    let onReanalyze: () async -> LyricSignature?

    @State private var draft: LyricAnalysisEditDraft
    @State private var isSaving = false
    @State private var isReanalyzing = false
    @State private var statusMessage = ""

    init(
        song: Song,
        signature: LyricSignature?,
        onSave: @escaping (LyricAnalysisEditDraft) async -> LyricSignature?,
        onReanalyze: @escaping () async -> LyricSignature?
    ) {
        self.song = song
        self.signature = signature
        self.onSave = onSave
        self.onReanalyze = onReanalyze
        _draft = State(initialValue: LyricAnalysisEditDraft(signature: signature))
    }

    var body: some View {
        NavigationStack {
  ScrollView {
      VStack(alignment: .leading, spacing: 18) {
          VStack(alignment: .leading, spacing: 5) {
              Text(song.title)
                  .font(.system(size: 24, weight: .bold))
              Text(song.artist)
                  .foregroundStyle(.secondary)
              Text("엔진: \(signature?.sourceTitle ?? String(localized: "분석 없음"))")
                  .font(.system(size: 13, weight: .semibold))
                  .foregroundStyle(.secondary)
          }

          if signature == nil {
              Text("저장된 LLM 분석이 없습니다. 아래 ‘현재 엔진으로 다시 분석’을 눌러 새 분석을 만들 수 있습니다.")
                  .font(.system(size: 13))
                  .foregroundStyle(.secondary)
          } else {
              editorField("핵심 분위기", text: $draft.primaryMoods, prompt: "yearning, obsessive, melancholic")
              editorField("보조 분위기", text: $draft.secondaryMoods, prompt: "resentful, anxious")
              editorField("테마", text: $draft.themes, prompt: "lost relationship, memory")

              metricSlider("가사 에너지", value: $draft.energy)
              metricSlider("감정 긍정도", value: $draft.valence)
              metricSlider("감정 강도", value: $draft.emotionIntensity)

              editorTextArea("요약", text: $draft.summary, minHeight: 120)
              editorTextArea("가사에 직접 드러난 내용", text: $draft.explicitContent)
              editorTextArea("AI 해석", text: $draft.interpretation)
              editorTextArea("감정 흐름", text: $draft.emotionalArc)
              editorField("관계", text: $draft.relationship, prompt: "former lovers")

              DisclosureGroup("세부 데이터") {
                  VStack(alignment: .leading, spacing: 12) {
                      editorField("내용 태그", text: $draft.content, prompt: "longing")
                      editorField("서사", text: $draft.narrative, prompt: "first-person recollection")
                      editorField("장소", text: $draft.setting, prompt: "city")
                      editorField("사회적 상태", text: $draft.social, prompt: "alone")
                      editorField("계절", text: $draft.season, prompt: "winter")
                      editorField("시간대", text: $draft.dayparts, prompt: "night, evening")
                      editorField("추천 상황", text: $draft.listenContext, prompt: "late night")
                  }
                  .padding(.top, 10)
              }

              if let signature, signature.hasStoredSoundAnalysis {
                  VStack(alignment: .leading, spacing: 4) {
                      Text("음향 분석 · 읽기 전용")
                          .font(.system(size: 14, weight: .semibold))
                      Text(signature.soundLabels.joined(separator: ", "))
                          .font(.system(size: 12.5))
                          .foregroundStyle(.secondary)
                  }
              }

              Button(isSaving ? "저장 중…" : "수정 내용 저장") {
                  Task { @MainActor in
                      isSaving = true
                      defer { isSaving = false }
                      if let updated = await onSave(draft) {
                          draft = LyricAnalysisEditDraft(signature: updated)
                          statusMessage = String(localized: "수정한 분석을 저장하고 추천에 반영했습니다.")
                      } else {
                          statusMessage = String(localized: "수정 내용을 저장하지 못했습니다.")
                      }
                  }
              }
              .buttonStyle(SettingsActionButtonStyle())
              .disabled(isSaving || isReanalyzing)
          }

          Button(isReanalyzing ? "다시 분석 중…" : "현재 엔진으로 다시 분석") {
              Task { @MainActor in
                  isReanalyzing = true
                  defer { isReanalyzing = false }
                  if let updated = await onReanalyze() {
                      draft = LyricAnalysisEditDraft(signature: updated)
                      statusMessage = String(localized: "새 LLM 분석으로 교체했습니다.")
                  } else {
                      statusMessage = String(localized: "LLM 분석에 실패했습니다. 기존 데이터는 유지됩니다.")
                  }
              }
          }
          .buttonStyle(SettingsActionButtonStyle())
          .disabled(isSaving || isReanalyzing)

          if !statusMessage.isEmpty {
              Text(statusMessage)
                  .font(.system(size: 12.5))
                  .foregroundStyle(.secondary)
          }
      }
      .padding(18)
  }
  .background(BuFiScreenBackground())
  .navigationTitle("현재 곡 분석 데이터")
  .navigationBarTitleDisplayMode(.inline)
  .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
          Button("완료") { dismiss() }
      }
  }
        }
        .presentationDetents([.large])
    }

    private func editorField(
        _ title: LocalizedStringKey,
        text: Binding<String>,
        prompt: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
  Text(title)
      .font(.system(size: 14, weight: .semibold))
  TextField(prompt, text: text)
      .settingsTextField()
        }
    }

    private func editorTextArea(
        _ title: LocalizedStringKey,
        text: Binding<String>,
        minHeight: CGFloat = 86
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
  Text(title)
      .font(.system(size: 14, weight: .semibold))
  TextEditor(text: text)
      .font(.system(size: 14))
      .frame(minHeight: minHeight)
      .padding(10)
      .background(
          Color.primary.opacity(0.055),
          in: RoundedRectangle(cornerRadius: 14, style: .continuous)
      )
      .overlay {
          RoundedRectangle(cornerRadius: 14, style: .continuous)
              .stroke(BuFiTheme.separator.opacity(0.30), lineWidth: 0.7)
      }
        }
    }

    private func metricSlider(
        _ title: LocalizedStringKey,
        value: Binding<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
  HStack {
      Text(title)
          .font(.system(size: 14, weight: .semibold))
      Spacer()
      Text(value.wrappedValue, format: .percent.precision(.fractionLength(0)))
          .foregroundStyle(.secondary)
          .monospacedDigit()
  }
  Slider(value: value, in: 0...1, step: 0.05)
      .tint(BuFiTheme.accent)
        }
    }
}

private struct OpenSourceNoticesView: View {
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                BuFiPageHeader(title: "오픈소스")

                SettingsGroup(title: "BuFi") {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Copyright © 2026 TAE-OK-11")
                            .font(.system(size: 16, weight: .semibold))
                        Text("GNU GPL v3 or later")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                        Text("BuFi는 SwiftUI, AVFoundation, MediaPlayer, Core Graphics, CryptoKit, Keychain, URLSession 등 Apple 시스템 프레임워크를 중심으로 구현됩니다.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 16)

                SettingsGroup(title: "연결된 런타임 구성요소") {
                    VStack(alignment: .leading, spacing: 16) {
                        notice(
                            "SwiftSonic",
                            license: "MIT License · Copyright © 2026 Mathieu Dubart",
                            detail: "인증된 스트림·아트워크·다운로드 URL 생성에 사용합니다."
                        )
                        Divider()
                        notice(
                            "GRDB",
                            license: "MIT License · Copyright © 2015–2025 Gwendal Roué",
                            detail: "재생 기록, 오프라인 메타데이터, 홈 캐시와 재생 대기목록을 트랜잭션으로 저장합니다."
                        )
                        Divider()
                        notice(
                            "Nuke",
                            license: "MIT License · Copyright © Alexander Grebenyuk and contributors",
                            detail: "이미지 다운샘플링, 요청 병합과 메모리·디스크 캐싱에 사용합니다."
                        )
                        Divider()
                        notice(
                            "Zstandard",
                            license: "BSD 3-Clause · Meta Platforms, Inc. and contributors",
                            detail: "Foundation이 직접 해제하지 않은 HTTP zstd 응답을 안전하게 처리합니다."
                        )
                        Divider()
                        notice(
                            "Unbounded",
                            license: "SIL Open Font License 1.1 · Copyright 2022 The Unbounded Project Authors",
                            detail: "맞춤 믹스 아트워크의 제목 글꼴로 앱에 포함됩니다."
                        )
                    }
                }
                .padding(.horizontal, 16)

                SettingsGroup(title: "적용한 GPL 소스") {
                    notice(
                        "Amperfy",
                        license: "GNU GPL v3 · Copyright © Maximilian Bauer and contributors",
                        detail: "Subsonic 스트림 MIME 처리와 오디오 세션 패턴을 Amperfy의 GPLv3 구현에서 적용했습니다. 전체 대응 소스는 BuFi 공개 저장소에서 제공합니다."
                    )
                }
                .padding(.horizontal, 16)

                SettingsGroup(title: "라이선스 전문") {
                    NavigationLink {
                        ThirdPartyLicensesView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(BuFiTheme.accent)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("제3자 라이선스 전문")
                                    .font(.system(size: 16, weight: .semibold))
                                Text("SwiftSonic, GRDB, Nuke, Zstandard 및 Unbounded")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
            }
            .padding(.top, 18)
            .buFiMiniPlayerContentClearance()
        }
        .background(BuFiScreenBackground())
        .toolbar(.visible, for: .navigationBar)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .tint(BuFiTheme.accent)
    }

    private func notice(
        _ title: LocalizedStringKey,
        license: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 16, weight: .bold))
            Text(license)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ThirdPartyLicensesView: View {
    private let contents: String

    init(bundle: Bundle = .main) {
        if let url = bundle.url(
            forResource: "ThirdPartyLicenses",
            withExtension: "txt"
        ),
            let text = try? String(contentsOf: url, encoding: .utf8)
        {
            contents = text
        } else {
            contents = String(localized: "라이선스 파일을 불러오지 못했습니다.")
        }
    }

    var body: some View {
        ScrollView {
            Text(verbatim: contents)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .buFiMiniPlayerContentClearance()
        }
        .background(BuFiScreenBackground())
        .navigationTitle("제3자 라이선스 전문")
        .navigationBarTitleDisplayMode(.inline)
    }
}
