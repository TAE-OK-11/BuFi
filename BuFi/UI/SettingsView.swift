import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var audio: AudioEngine
    @State private var offlineBytes: Int64 = 0
    @State private var confirmOfflineRemoval = false
    @State private var confirmArtworkRemoval = false
    @AppStorage("appearance-mode") private var appearanceMode = AppAppearance.system.rawValue
    @AppStorage("motion-enabled") private var motionEnabled = true
    @AppStorage("player-control-appearance")
    private var playerControlAppearance = PlayerControlAppearance.liquidGlass.rawValue
    @AppStorage("haptics-enabled") private var hapticsEnabled = true
    @AppStorage("auto-open-player") private var autoOpenPlayer = false
    @AppStorage("lyrics-auto-scroll") private var lyricsAutoScroll = true
    @AppStorage("restore-play-queue") private var restorePlayQueue = true
    @AppStorage("keep-screen-awake") private var keepScreenAwake = false
    @AppStorage("server-sync-interval") private var syncInterval = 30.0
    @AppStorage("offline-wifi-only") private var offlineWiFiOnly = true
    @AppStorage("offline-prefetch-count") private var offlinePrefetchCount = 1
    @AppStorage("offline-storage-limit-gb") private var offlineStorageLimitGB = 10.0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [BuFiTheme.accentSoft, BuFiTheme.deezerGlow],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 54, height: 54)
                            .overlay {
                                Image(systemName: "music.note")
                                    .font(.title3.bold())
                                    .foregroundStyle(.white)
                            }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("TAE Music")
                                .font(.headline)
                            Text(
                                model.serverVersion.isEmpty
                                    ? "OpenSubsonic"
                                    : String(
                                        format: String(localized: "서버 %@"),
                                        model.serverVersion
                                    )
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .listRowBackground(settingsRowBackground)

                Section("화면 및 동작") {
                    Picker("화면 모드", selection: $appearanceMode) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .tint(BuFiTheme.accent)

                    Picker("플레이어 컨트롤", selection: $playerControlAppearance) {
                        ForEach(PlayerControlAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .tint(BuFiTheme.accent)

                    Text("Liquid Glass는 iOS 26 이상에서 Apple 기본 재생 막대와 컨트롤을 사용합니다. 이전 iOS에서는 클래식 스타일로 자동 전환됩니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Toggle(isOn: $motionEnabled) {
                        Label("애니메이션 및 모션", systemImage: "sparkles")
                    }
                    Text("동작 줄이기, 저전력 모드 또는 기기 온도가 높을 때는 애니메이션을 자동으로 줄입니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Toggle(isOn: $hapticsEnabled) {
                        Label("햅틱 피드백", systemImage: "waveform.path")
                    }
                }
                .listRowBackground(settingsRowBackground)

                Section("서버 동기화") {
                    Picker("자동 동기화 주기", selection: $syncInterval) {
                        Text("30초").tag(30.0)
                        Text("1분").tag(60.0)
                        Text("5분").tag(300.0)
                        Text("15분").tag(900.0)
                    }
                    .tint(Color(uiColor: .secondaryLabel))
                    Text("앱이 활성 상태일 때만 동기화합니다. 평소에는 좋아요·새 앨범·플레이리스트만 가볍게 갱신하고, 전체 라이브러리는 5분 간격으로 확인합니다. 저전력 모드에서는 주기를 자동으로 늘립니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(settingsRowBackground)

                Section("재생") {
                    Picker("음질", selection: $audio.quality) {
                        ForEach(StreamQuality.allCases) { quality in
                            Text(quality.title).tag(quality)
                        }
                    }
                    .tint(Color(uiColor: .secondaryLabel))
                    Text("자동 음질은 FLAC·Opus·Vorbis 등 고부하 원본을 서버에서 AAC 256kbps로 변환해 기기 배터리 사용량을 줄입니다. 원본 무손실은 원본 재생을 먼저 시도하고 실패하면 AAC·MP3로 전환합니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Toggle(isOn: $autoOpenPlayer) {
                        Label("재생 시 플레이어 자동 열기", systemImage: "rectangle.expand.vertical")
                    }
                    Toggle(isOn: $restorePlayQueue) {
                        Label("재생 대기목록 기억", systemImage: "clock.arrow.circlepath")
                    }
                    Toggle(isOn: $lyricsAutoScroll) {
                        Label("가사 자동 스크롤", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    Toggle(isOn: $keepScreenAwake) {
                        Label("재생 중 화면 켜두기", systemImage: "sun.max")
                    }
                    HStack {
                        Label("AirPlay", systemImage: "airplayaudio")
                        Spacer()
                        AirPlayButton()
                            .frame(width: 42, height: 34)
                    }
                }
                .listRowBackground(settingsRowBackground)

                Section("오프라인 및 저장 공간") {
                    Toggle(isOn: $offlineWiFiOnly) {
                        Label("Wi-Fi에서만 오프라인 저장", systemImage: "wifi")
                    }
                    Picker("다음 곡 선캐시", selection: $offlinePrefetchCount) {
                        Text("끔").tag(0)
                        Text("1곡").tag(1)
                        Text("3곡").tag(3)
                    }
                    Picker("오프라인 용량 제한", selection: $offlineStorageLimitGB) {
                        Text("5 GB").tag(5.0)
                        Text("10 GB").tag(10.0)
                        Text("25 GB").tag(25.0)
                        Text("제한 없음").tag(0.0)
                    }
                    LabeledContent("오프라인 저장 공간") {
                        Text(
                            ByteCountFormatter.string(
                                fromByteCount: offlineBytes,
                                countStyle: .file
                            )
                        )
                        .foregroundStyle(.secondary)
                    }
                    Button("오프라인 음악 모두 삭제", role: .destructive) {
                        confirmOfflineRemoval = true
                    }
                    Button("앨범 이미지 캐시 비우기") {
                        confirmArtworkRemoval = true
                    }
                }
                .listRowBackground(settingsRowBackground)

                Section("앱") {
                    LabeledContent("최소 iOS", value: "17.0")
                    LabeledContent("버전", value: versionText)
                    Label("적응형 배터리·메모리 최적화", systemImage: "leaf.fill")
                    Label("분석·광고 SDK 없음", systemImage: "hand.raised.fill")
                    NavigationLink("오픈소스 및 라이선스") {
                        OpenSourceNoticesView()
                    }
                }
                .listRowBackground(settingsRowBackground)

                Section {
                    Button("로그아웃", role: .destructive) {
                        model.logout()
                    }
                }
                .listRowBackground(settingsRowBackground)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(BuFiScreenBackground())
            .navigationTitle("설정")
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
        }
    }

    private var settingsRowBackground: Color {
        BuFiTheme.elevated
    }

    private var versionText: String {
        let version =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.4.0"
        let build =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "15"
        return "\(version) (\(build))"
    }
}

private struct OpenSourceNoticesView: View {
    var body: some View {
        List {
            Section("BuFi") {
                Text("Copyright © 2026 TAE-OK-11")
                Text("GNU GPL v3 or later")
                Text("BuFi는 SwiftUI, AVFoundation, MediaPlayer, Core Graphics, CryptoKit, Keychain, URLSession 등 Apple 시스템 프레임워크를 중심으로 구현됩니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("빌드 도구") {
                VStack(alignment: .leading, spacing: 5) {
                    Text("XcodeGen").font(.headline)
                    Text("MIT License · Copyright © Yonas Kolb")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("재생 호환성") {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Amperfy").font(.headline)
                    Text("GNU GPL v3")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Subsonic 스트림 MIME 처리와 오디오 세션 패턴을 Amperfy의 GPLv3 구현에서 적용했습니다. 전체 대응 소스는 BuFi 공개 저장소에서 제공합니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("SwiftSonic") {
                VStack(alignment: .leading, spacing: 5) {
                    Text("SwiftSonic").font(.headline)
                    Text("MIT License · Copyright © 2026 Mathieu Dubart")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("인증된 스트림·아트워크·다운로드 URL 생성에 사용합니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Nuke") {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Nuke").font(.headline)
                    Text("MIT License · Copyright © Alexander Grebenyuk and contributors")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("앨범 이미지 다운샘플링, 요청 병합, 메모리 및 디스크 캐싱에 사용합니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Cassette 참고 구조") {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Cassette").font(.headline)
                    Text("MPL-2.0 · 구조와 동작 방식 참고, 소스 파일 직접 복사 없음")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("독립 재생 매니저, 최소 UI 관찰 상태, 오프라인 우선 설계를 참고했습니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("네트워크 압축") {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Zstandard").font(.headline)
                    Text("BSD 3-Clause · Meta Platforms, Inc. and contributors")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Foundation이 직접 해제하지 않은 HTTP zstd 응답을 안전하게 처리합니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("라이선스 전문") {
                NavigationLink {
                    ThirdPartyLicensesView()
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("제3자 라이선스 전문", systemImage: "doc.text")
                        Text("SwiftSonic, Nuke 및 Zstandard의 공식 라이선스 전문")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("오픈소스")
        .navigationBarTitleDisplayMode(.inline)
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
                .padding()
        }
        .background(BuFiScreenBackground())
        .navigationTitle("제3자 라이선스 전문")
        .navigationBarTitleDisplayMode(.inline)
    }
}
