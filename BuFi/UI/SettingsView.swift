import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: AppSessionState
    @Environment(\.buFiMotionEnabled) private var effectiveMotionEnabled
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
    @AppStorage("server-sync-interval") private var syncInterval = 300.0
    @AppStorage("offline-wifi-only") private var offlineWiFiOnly = true
    @AppStorage("offline-prefetch-count") private var offlinePrefetchCount = 0
    @AppStorage("offline-storage-limit-gb") private var offlineStorageLimitGB = 10.0

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    BuFiPageHeader(title: "설정")
                        .buFiEntranceMotion()
                    serverCard
                        .buFiVerticalSectionMotion(delay: 0.02)
                    appearanceSection
                        .buFiVerticalSectionMotion(delay: 0.04)
                    syncSection
                        .buFiVerticalSectionMotion(delay: 0.06)
                    recommendationSection
                        .buFiVerticalSectionMotion(delay: 0.08)
                    PlaybackSettingsSection()
                        .buFiVerticalSectionMotion(delay: 0.075)
                    offlineSection
                        .buFiVerticalSectionMotion(delay: 0.08)
                    appSection
                        .buFiVerticalSectionMotion(delay: 0.08)
                    logoutRow
                        .buFiVerticalSectionMotion(delay: 0.08)
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

                SettingsDivider()

                settingLabel("플레이어 스타일", icon: "music.note.house")
                Picker("플레이어 스타일", selection: $playerAppearance) {
                    ForEach(PlayerAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                settingsNote("Classic은 기존 디자인을 유지하고 Liquid Glass는 재생바만 Apple 스타일로 표시합니다. Dynamic은 잠금화면처럼 제어 요소를 유리 카드에 모읍니다.")

                SettingsDivider()

                settingLabel("플레이어 배경", icon: "paintpalette.fill")
                Picker("플레이어 배경", selection: $playerBackgroundAppearance) {
                    ForEach(PlayerBackgroundAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                settingsNote("기본은 대표색을 중심으로 은은하게 섞고, 다중 컬러는 앨범 속 세 가지 예술색의 위치를 더 선명하게 반영합니다. 밝게는 같은 색 구성을 화사하게 표시합니다.")

                SettingsDivider()

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
            } label: {
                HStack(spacing: 12) {
                    settingIcon("wand.and.stars")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("추천")
                            .font(.system(size: 16, weight: .semibold))
                        Text("지금 듣는 흐름, 취향, 새로운 음악")
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
            .buttonStyle(BuFiPressStyle())
        }
        .padding(.horizontal, 16)
    }

}

private struct PlaybackSettingsSection: View {
    @EnvironmentObject private var audio: AudioEngine
    @AppStorage("auto-open-player") private var autoOpenPlayer = false
    @AppStorage("lyrics-auto-scroll") private var lyricsAutoScroll = true
    @AppStorage("restore-play-queue") private var restorePlayQueue = true
    @AppStorage("algorithmic-autoplay-enabled")
    private var algorithmicAutoplayEnabled = true
    @AppStorage("keep-screen-awake") private var keepScreenAwake = false

    var body: some View {
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

                SettingsDivider()

                settingsToggle("플레이어 자동 열기", icon: "rectangle.expand.vertical", value: $autoOpenPlayer)
                settingsToggle("재생 대기목록 기억", icon: "clock.arrow.circlepath", value: $restorePlayQueue)
                settingsToggle("추천곡 계속 재생", icon: "infinity.circle", value: $algorithmicAutoplayEnabled)
                settingsNote("재생목록이 끝나기 전에 서버 유사곡을 추가해 음악이 끊기지 않도록 합니다.")

                SettingsDivider()

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

                SettingsDivider()

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
        .onChange(of: restorePlayQueue) { _, enabled in
            audio.setQueueRestoration(enabled: enabled)
        }
        .onChange(of: keepScreenAwake) { _, _ in
            audio.refreshIdleTimerPreference()
        }
    }
}

extension SettingsView {
    private var offlineSection: some View {
        SettingsGroup(title: "오프라인 및 저장 공간") {
            VStack(alignment: .leading, spacing: 14) {
                settingsToggle("Wi-Fi에서만 저장", icon: "wifi", value: $offlineWiFiOnly)

                SettingsDivider()

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
                        .contentTransition(.numericText())
                        .animation(
                            effectiveMotionEnabled ? BuFiMotion.content : .none,
                            value: offlineStorageText
                        )
                }

                SettingsDivider()

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
                SettingsDivider()
                Label("적응형 배터리·메모리 최적화", systemImage: "leaf.fill")
                    .foregroundStyle(.primary)
                Label("분석·광고 SDK 없음", systemImage: "hand.raised.fill")
                    .foregroundStyle(.primary)
                SettingsDivider()
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
                .buttonStyle(BuFiPressStyle())
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
                            .transition(.opacity.combined(with: .scale(scale: 0.88)))
                    }
                }
                .animation(
                    effectiveMotionEnabled ? BuFiMotion.symbol : .none,
                    value: isLoggingOut
                )
                .padding(.horizontal, 16)
                .frame(minHeight: 50)
                .contentShape(Rectangle())
            }
            .buttonStyle(BuFiPressStyle())
            .disabled(isLoggingOut)
        }
        .padding(.horizontal, 16)
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

@ViewBuilder
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

private struct SettingsDivider: View {
    var body: some View {
        Divider()
            .overlay(BuFiTheme.separator.opacity(0.34))
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
            .scaleEffect(configuration.isPressed && motionEnabled ? 0.985 : 1)
            .brightness(configuration.isPressed ? -0.012 : 0)
            .opacity(configuration.isPressed ? 0.96 : 1)
            .animation(
                motionEnabled
                    ? BuFiMotion.press(isPressed: configuration.isPressed)
                    : .none,
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
    @State private var lastFMAPIKey = ""
    @State private var listenBrainzUsername = ""
    @State private var listenBrainzToken = ""
    @AppStorage(RecommendationTasteControls.nowKey)
    private var nowPlayingFeel = RecommendationTasteControls.defaultNow
    @AppStorage(RecommendationTasteControls.tasteKey)
    private var myTasteFeel = RecommendationTasteControls.defaultTaste
    @AppStorage(RecommendationTasteControls.freshKey)
    private var freshFeel = RecommendationTasteControls.defaultFresh

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                BuFiPageHeader(title: "추천")
                    .buFiEntranceMotion()

                SettingsGroup(title: "추천에 쓰는 서비스") {
                    VStack(alignment: .leading, spacing: 16) {
                        serviceStatusRow(
                            name: "Last.fm",
                            linked: session.hasLastFMAPIKey,
                            usable: session.hasLastFMAPIKey,
                            activeCount: model.home.lastFMRecommendedSongs.count,
                            offDetail: "키가 없어 비슷한 곡 추천에는 쓰이지 않습니다.",
                            waitingDetail: "키는 저장됐고, 홈을 새로고침하면 추천에 들어갑니다."
                        )
                        Divider()
                        serviceStatusRow(
                            name: "ListenBrainz",
                            linked: !session.listenBrainzUsername.isEmpty,
                            usable: !session.listenBrainzUsername.isEmpty,
                            activeCount: model.home.listenBrainzRecommendedSongs.count,
                            offDetail: "아이디가 없어 비슷한 취향 추천에는 쓰이지 않습니다.",
                            waitingDetail: session.hasListenBrainzToken
                                ? "아이디와 토큰이 저장됐고, 홈을 새로고침하면 추천에 들어갑니다."
                                : "아이디가 저장됐고, 홈을 새로고침하면 추천에 들어갑니다."
                        )
                        Divider()
                        Text(algorithmSourceSummary)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 16)
                .buFiVerticalSectionMotion(delay: 0.025)

                SettingsGroup(title: "이런 음악을 더") {
                    VStack(spacing: 18) {
                        feelRow(
                            "지금 듣는 흐름",
                            caption: "방금 나온 노래와 비슷한 분위기를 이어갑니다.",
                            value: $nowPlayingFeel
                        )
                        feelRow(
                            "내가 좋아하는 음악",
                            caption: "좋아요와 자주 들은 곡을 더 자주 꺼냅니다.",
                            value: $myTasteFeel
                        )
                        feelRow(
                            "새로운 음악",
                            caption: "처음 듣는 곡을 살짝 섞습니다.",
                            value: $freshFeel
                        )
                        Button("기본으로 되돌리기") {
                            nowPlayingFeel = RecommendationTasteControls.defaultNow
                            myTasteFeel = RecommendationTasteControls.defaultTaste
                            freshFeel = RecommendationTasteControls.defaultFresh
                            model.rebuildRecommendations()
                        }
                        .font(.system(size: 15, weight: .semibold))
                    }
                }
                .padding(.horizontal, 16)
                .buFiVerticalSectionMotion(delay: 0.05)

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
                        settingsDescription("비슷한 곡을 더 찾아옵니다. 키는 last.fm/api에서 무료로 만들 수 있고, 로그인까지는 필요 없습니다.")
                    }
                }
                .padding(.horizontal, 16)
                .buFiVerticalSectionMotion(delay: 0.075)

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
                        settingsDescription("비슷한 취향의 사람들이 듣는 곡을 참고합니다. 아이디만 있어도 되고, 토큰은 없어도 됩니다.")
                    }
                }
                .padding(.horizontal, 16)
                .buFiVerticalSectionMotion(delay: 0.10)
            }
            .padding(.top, 18)
            .buFiMiniPlayerContentClearance()
        }
        .background(BuFiScreenBackground())
        .toolbar(.visible, for: .navigationBar)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .tint(BuFiTheme.accent)
        .onAppear {
            listenBrainzUsername = session.listenBrainzUsername
        }
    }

    private var algorithmSourceSummary: LocalizedStringKey {
        let lastFM = session.hasLastFMAPIKey
        let listenBrainz = !session.listenBrainzUsername.isEmpty
        switch (lastFM, listenBrainz) {
        case (true, true):
            return "Last.fm과 ListenBrainz를 서버 음악·내 취향과 함께 씁니다."
        case (true, false):
            return "Last.fm을 서버 음악·내 취향과 함께 씁니다."
        case (false, true):
            return "ListenBrainz를 서버 음악·내 취향과 함께 씁니다."
        case (false, false):
            return "외부 서비스 없이 서버 음악과 내 취향만으로 추천합니다."
        }
    }

    private func serviceStatusRow(
        name: String,
        linked: Bool,
        usable: Bool,
        activeCount: Int,
        offDetail: LocalizedStringKey,
        waitingDetail: LocalizedStringKey
    ) -> some View {
        let inAlgorithm = usable && activeCount > 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle()
                    .fill(inAlgorithm
                        ? BuFiTheme.accent
                        : (linked ? Color.orange : Color.secondary.opacity(0.45)))
                    .frame(width: 8, height: 8)
                Text(name)
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Text(linked ? "연동됨" : "안 함")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(linked ? BuFiTheme.accent : Color.secondary)
            }
            Group {
                if inAlgorithm {
                    Text("추천에 사용 중") + Text(verbatim: " · \(activeCount)곡")
                } else if linked {
                    Text(waitingDetail)
                } else {
                    Text(offDetail)
                }
            }
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func feelRow(
        _ title: LocalizedStringKey,
        caption: LocalizedStringKey,
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
            Text(caption)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

}

private struct OpenSourceNoticesView: View {
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                BuFiPageHeader(title: "오픈소스")
                    .buFiEntranceMotion()

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
                .buFiVerticalSectionMotion(delay: 0.025)

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
                .buFiVerticalSectionMotion(delay: 0.05)

                SettingsGroup(title: "적용한 GPL 소스") {
                    notice(
                        "Amperfy",
                        license: "GNU GPL v3 · Copyright © Maximilian Bauer and contributors",
                        detail: "Subsonic 스트림 MIME 처리와 오디오 세션 패턴을 Amperfy의 GPLv3 구현에서 적용했습니다. 전체 대응 소스는 BuFi 공개 저장소에서 제공합니다."
                    )
                }
                .padding(.horizontal, 16)
                .buFiVerticalSectionMotion(delay: 0.075)

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
                    .buttonStyle(BuFiPressStyle())
                }
                .padding(.horizontal, 16)
                .buFiVerticalSectionMotion(delay: 0.10)
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
                .buFiEntranceMotion()
                .buFiMiniPlayerContentClearance()
        }
        .background(BuFiScreenBackground())
        .navigationTitle("제3자 라이선스 전문")
        .navigationBarTitleDisplayMode(.inline)
    }
}
