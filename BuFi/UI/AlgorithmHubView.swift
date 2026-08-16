import SwiftUI

struct AlgorithmHubView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: AppSessionState
    @EnvironmentObject private var audio: AudioEngine

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                BuFiPageHeader(title: "추천 설정")
                Text("듣는 방식을 골라 주세요. 둘 다 손대지 않아도 기본값으로 잘 돌아가요.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 18)

                NavigationLink {
                    ClassicAlgorithmSettingsView()
                        .environmentObject(model)
                        .environmentObject(session)
                } label: {
                    algorithmCard(
                        icon: "chart.bar.fill",
                        title: "기본 추천",
                        subtitle: "내가 듣던 곡, 좋아요, 비슷한 노래를 중심으로"
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)

                NavigationLink {
                    RecommendationSettingsView()
                        .environmentObject(model)
                        .environmentObject(session)
                        .environmentObject(audio)
                        .environmentObject(audio.playbackState)
                } label: {
                    algorithmCard(
                        icon: "sparkles",
                        title: "AI 추천",
                        subtitle: "지금 기분과 가사를 보고 다음 곡을 이어 줘요"
                    )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
            }
            .padding(.top, 18)
            .buFiMiniPlayerContentClearance()
        }
        .background(BuFiScreenBackground())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .tint(BuFiTheme.accent)
    }

    private func algorithmCard(
        icon: String,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(BuFiTheme.accent)
                .frame(width: 46, height: 46)
                .background(BuFiTheme.accent.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(BuFiTheme.elevated, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(Rectangle())
    }
}

struct ClassicAlgorithmSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: AppSessionState
    @State private var lastFMAPIKey = ""
    @State private var listenBrainzUsername = ""
    @State private var listenBrainzToken = ""
    @AppStorage("recommendation-weight-history") private var historyWeight = 0.68
    @AppStorage("recommendation-weight-favorites") private var favoriteWeight = 0.82
    @AppStorage("recommendation-weight-server") private var serverWeight = 0.88
    @AppStorage("recommendation-weight-discovery") private var discoveryWeight = 0.32
    @AppStorage("recommendation-weight-lastfm") private var lastFMWeight = 0.52
    @AppStorage("recommendation-weight-listenbrainz")
    private var listenBrainzWeight = 0.52
    @AppStorage("recommendation-weight-behavior")
    private var behaviorWeight = 0.88
    @AppStorage("recommendation-weight-recency")
    private var recencyWeight = 0.68
    @AppStorage("recommendation-weight-context")
    private var contextWeight = 0.72
    @AppStorage("recommendation-weight-metadata")
    private var metadataWeight = 0.62
    @AppStorage("recommendation-weight-playlist-affinity")
    private var playlistAffinityWeight = 0.55
    @AppStorage("recommendation-weight-album-completion")
    private var albumCompletionWeight = 0.50
    @AppStorage("recommendation-weight-forgotten-favorites")
    private var forgottenFavoritesWeight = 0.48
    @AppStorage("recommendation-weight-artist-rotation")
    private var artistRotationWeight = 0.55
    @AppStorage("recommendation-weight-time-awareness")
    private var timeAwarenessWeight = 0.36
    @AppStorage("recommendation-weight-lyric-mood")
    private var lyricMoodWeight = 0.62
    @AppStorage("recommendation-discovery-ratio")
    private var discoveryRatio = 0.32

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                BuFiPageHeader(title: "기본 추천")

                SettingsGroup(title: "내가 듣던 음악") {
                    VStack(spacing: 18) {
                        weightRow("예전에 듣던 곡", value: $historyWeight)
                        weightRow("좋아요 한 곡", value: $favoriteWeight)
                        weightRow("스킵·반복·완주 습관", value: $behaviorWeight)
                        weightRow("요즘 빠진 곡", value: $recencyWeight)
                    }
                }
                .padding(.horizontal, 16)

                SettingsGroup(title: "지금 듣는 중") {
                    VStack(spacing: 18) {
                        weightRow("방금 들은 흐름", value: $contextWeight)
                        weightRow("가사 분위기", value: $lyricMoodWeight)
                        weightRow("지금 시간대", value: $timeAwarenessWeight)
                        weightRow("같은 앨범 이어서", value: $albumCompletionWeight)
                    }
                }
                .padding(.horizontal, 16)

                SettingsGroup(title: "새로운 곡") {
                    VStack(spacing: 18) {
                        weightRow("처음 보는 곡 비중", value: $discoveryWeight)
                        weightRow("새로운 가수 섞기", value: $discoveryRatio)
                        weightRow("잊고 있던 좋아요", value: $forgottenFavoritesWeight)
                        weightRow("같은 가수 너무 많이 안 나오게", value: $artistRotationWeight)
                    }
                }
                .padding(.horizontal, 16)

                SettingsGroup(title: "비슷한 곡 찾기") {
                    VStack(spacing: 18) {
                        weightRow("서버가 고른 비슷한 곡", value: $serverWeight)
                        weightRow("장르·템포 맞추기", value: $metadataWeight)
                        weightRow("플레이리스트에 같이 있던 곡", value: $playlistAffinityWeight)
                        weightRow("Last.fm 비슷한 곡", value: $lastFMWeight)
                        weightRow("ListenBrainz 비슷한 곡", value: $listenBrainzWeight)
                        Button("처음 설정으로 되돌리기") { restoreDefaults() }
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
                .padding(.horizontal, 16)

                lastFMSection
                listenBrainzSection
            }
            .padding(.top, 18)
            .buFiMiniPlayerContentClearance()
        }
        .background(BuFiScreenBackground())
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .tint(BuFiTheme.accent)
        .onAppear {
            listenBrainzUsername = session.listenBrainzUsername
        }
    }

    private var lastFMSection: some View {
        SettingsGroup(title: "Last.fm") {
            VStack(alignment: .leading, spacing: 14) {
                SecureField(
                    session.hasLastFMAPIKey ? "저장된 API 키 교체" : "Last.fm API 키",
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
                note("비슷한 곡을 불러오려면 API 키만 있으면 돼요. 따로 로그인할 필요는 없어요.")
            }
        }
        .padding(.horizontal, 16)
    }

    private var listenBrainzSection: some View {
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
                        if await model.saveListenBrainz(username: username, token: token) {
                            listenBrainzToken = ""
                        }
                    }
                }
                .buttonStyle(SettingsActionButtonStyle())
                .disabled(
                    listenBrainzUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                note("다른 사람이 같이 들은 곡을 가져와서, 내 서버에 있는 노래만 골라 줘요.")
            }
        }
        .padding(.horizontal, 16)
    }

    private func weightRow(_ title: LocalizedStringKey, value: Binding<Double>) -> some View {
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

    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func restoreDefaults() {
        historyWeight = 0.68
        favoriteWeight = 0.82
        serverWeight = 0.88
        discoveryWeight = 0.32
        lastFMWeight = 0.52
        listenBrainzWeight = 0.52
        behaviorWeight = 0.88
        recencyWeight = 0.68
        contextWeight = 0.72
        metadataWeight = 0.62
        playlistAffinityWeight = 0.55
        albumCompletionWeight = 0.50
        forgottenFavoritesWeight = 0.48
        artistRotationWeight = 0.55
        timeAwarenessWeight = 0.36
        lyricMoodWeight = 0.62
        discoveryRatio = 0.32
        model.rebuildRecommendations()
    }
}
