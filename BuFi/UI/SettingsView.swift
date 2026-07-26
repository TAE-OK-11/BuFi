import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var audio: AudioEngine
    @State private var offlineBytes: Int64 = 0
    @State private var confirmOfflineRemoval = false
    @State private var confirmArtworkRemoval = false
    @AppStorage("appearance-mode") private var appearanceMode = AppAppearance.system.rawValue
    @AppStorage("motion-enabled") private var motionEnabled = true
    @AppStorage("haptics-enabled") private var hapticsEnabled = true
    @AppStorage("auto-open-player") private var autoOpenPlayer = false
    @AppStorage("lyrics-auto-scroll") private var lyricsAutoScroll = true
    @AppStorage("restore-play-queue") private var restorePlayQueue = true
    @AppStorage("keep-screen-awake") private var keepScreenAwake = false
    @AppStorage("server-sync-interval") private var syncInterval = 30.0

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

                Section("화면 및 동작") {
                    Picker("화면 모드", selection: $appearanceMode) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.title).tag(appearance.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)

                    Toggle(isOn: $motionEnabled) {
                        Label("Liquid Glass 애니메이션", systemImage: "sparkles")
                    }
                    Toggle(isOn: $hapticsEnabled) {
                        Label("햅틱 피드백", systemImage: "waveform.path")
                    }
                }

                Section("서버 동기화") {
                    Picker("자동 동기화 주기", selection: $syncInterval) {
                        Text("30초").tag(30.0)
                        Text("1분").tag(60.0)
                        Text("5분").tag(300.0)
                        Text("15분").tag(900.0)
                    }
                    Text("앱이 활성 상태일 때만 동기화합니다. 평소에는 좋아요·새 앨범·플레이리스트만 가볍게 갱신하고, 전체 라이브러리는 5분 간격으로 확인합니다. 저전력 모드에서는 주기를 자동으로 늘립니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("재생") {
                    Picker("음질", selection: $audio.quality) {
                        ForEach(StreamQuality.allCases) { quality in
                            Text(quality.title).tag(quality)
                        }
                    }
                    .tint(Color(uiColor: .secondaryLabel))
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

                Section("저장 공간") {
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

                Section("앱") {
                    LabeledContent("최소 iOS", value: "17.0")
                    LabeledContent("버전", value: versionText)
                    Label("적응형 배터리·메모리 최적화", systemImage: "leaf.fill")
                    Label("분석·광고 SDK 없음", systemImage: "hand.raised.fill")
                    NavigationLink("오픈소스 및 라이선스") {
                        OpenSourceNoticesView()
                    }
                }

                Section {
                    Button("로그아웃", role: .destructive) {
                        model.logout()
                    }
                }
            }
            .listStyle(.insetGrouped)
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

    private var versionText: String {
        let version =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.2.8"
        let build =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "12"
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
        }
        .navigationTitle("오픈소스")
        .navigationBarTitleDisplayMode(.inline)
    }
}
