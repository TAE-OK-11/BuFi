import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var audio: AudioEngine
    @State private var offlineBytes: Int64 = 0

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

                Section("스트리밍") {
                    Picker("음질", selection: $audio.quality) {
                        ForEach(StreamQuality.allCases) { quality in
                            Text(quality.title).tag(quality)
                        }
                    }
                    HStack {
                        Label("AirPlay", systemImage: "airplayaudio")
                        Spacer()
                        AirPlayButton()
                            .frame(width: 42, height: 34)
                    }
                    LabeledContent(
                        "오프라인 저장 공간",
                        value: ByteCountFormatter.string(fromByteCount: offlineBytes, countStyle: .file)
                    )
                }

                Section("앱") {
                    LabeledContent("최소 iOS", value: "17.0")
                    LabeledContent("버전", value: "1.0.0")
                    Label("분석·광고 SDK 없음", systemImage: "hand.raised.fill")
                    NavigationLink("오픈소스 및 라이선스") {
                        OpenSourceNoticesView()
                    }
                }

                Section {
                    Button("라이브러리 새로고침") {
                        Task { await model.refresh() }
                    }
                    Button("로그아웃", role: .destructive) {
                        model.logout()
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(BuFiTheme.background)
            .navigationTitle("설정")
            .task {
                offlineBytes = await OfflineStore.shared.totalBytes()
            }
        }
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
