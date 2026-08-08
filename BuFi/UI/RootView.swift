import SwiftUI
import UIKit

enum AppTab: Hashable {
    case home
    case search
    case library
    case settings
}

private struct MiniPlayerPlacementPreferenceKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }

    static func reduce(
        value: inout Anchor<CGRect>?,
        nextValue: () -> Anchor<CGRect>?
    ) {
        value = nextValue() ?? value
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: AppSessionState
    @EnvironmentObject private var playbackItem: PlaybackItemState
    @EnvironmentObject private var playbackActivity: PlaybackActivityState
    @EnvironmentObject private var playbackQueue: PlaybackQueueState
    @EnvironmentObject private var playerPresentation: PlayerPresentationState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tab: AppTab = .home
    @State private var pageProgress = 1.0
    @State private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var thermalState = ProcessInfo.processInfo.thermalState
    @AppStorage("appearance-mode") private var appearanceMode = AppAppearance.system.rawValue
    @AppStorage("haptics-enabled") private var hapticsEnabled = true
    @AppStorage("motion-enabled") private var motionEnabled = true
    @AppStorage("server-sync-interval") private var syncInterval = 300.0

    private let audio = AudioEngine.shared

    var body: some View {
        Group {
            switch session.phase {
            case .signedOut:
                LoginView()
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            case .connecting:
                ZStack {
                    BuFiScreenBackground()
                    ProgressView("자동 로그인 중…")
                        .font(.system(size: 15, weight: .semibold))
                        .tint(BuFiTheme.accent)
                }
                .transition(.opacity)
            case .ready:
                tabs
                    .transition(.opacity)
            }
        }
        .animation(effectiveMotion ? BuFiMotion.fade : .none, value: session.phase)
        .preferredColorScheme(AppAppearance(rawValue: appearanceMode)?.colorScheme)
        .environment(\.buFiMotionEnabled, effectiveMotion)
        .transaction { transaction in
            if !effectiveMotion { transaction.animation = nil }
        }
        .task(id: syncTaskID) {
            await runAutomaticSync()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            Task(priority: .utility) {
                await OfflineStore.shared.flushPendingWrites()
                await ListeningHistoryStore.shared.flushPendingWrites()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)) { _ in
            let currentLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            lowPowerMode = currentLowPowerMode
            model.handleEnergyConstraints(
                lowPowerMode: currentLowPowerMode,
                thermalState: thermalState
            )
            audio.handleEnergyConstraints(
                lowPowerMode: currentLowPowerMode,
                thermalState: thermalState
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            let currentThermalState = ProcessInfo.processInfo.thermalState
            thermalState = currentThermalState
            model.handleEnergyConstraints(
                lowPowerMode: lowPowerMode,
                thermalState: currentThermalState
            )
            audio.handleEnergyConstraints(
                lowPowerMode: lowPowerMode,
                thermalState: currentThermalState
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            model.handleMemoryPressure()
            audio.handleMemoryPressure()
            Task(priority: .utility) {
                await ArtworkStore.shared.clearMemory()
            }
        }
        .alert(
            "오류",
            isPresented: Binding(
                get: { session.errorMessage != nil && session.phase == .ready },
                set: { if !$0 { session.errorMessage = nil } }
            )
        ) {
            Button("확인", role: .cancel) { session.errorMessage = nil }
        } message: {
            Text(session.errorMessage ?? "")
        }
        .alert(
            "재생 오류",
            isPresented: Binding(
                get: { playerPresentation.playbackError != nil },
                set: { if !$0 { playerPresentation.playbackError = nil } }
            )
        ) {
            Button("확인", role: .cancel) { playerPresentation.playbackError = nil }
        } message: {
            Text(playerPresentation.playbackError ?? "")
        }
        .fullScreenCover(
            isPresented: Binding(
                get: { playerPresentation.showPlayer },
                set: { audio.showPlayer = $0 }
            )
        ) {
            NavigationStack {
                PlayerView(
                    initialArtworkPage: currentArtworkPageID
                )
                    .navigationDestination(for: MusicRoute.self) { route in
                        MusicDetailView(route: route)
                    }
            }
            .environmentObject(model)
            .environmentObject(audio)
            .environment(\.buFiMotionEnabled, effectiveMotion)
            .id(playerPresentation.presentationID)
        }
    }

    private var currentArtworkPageID: PlayerArtworkPageID? {
        if playbackQueue.songs.indices.contains(playbackQueue.index) {
            let song = playbackQueue.songs[playbackQueue.index]
            return PlayerArtworkPageID(
                queueIndex: playbackQueue.index,
                songID: song.id,
                coverArtID: song.coverArt
            )
        }
        guard let song = playbackItem.currentSong else { return nil }
        return PlayerArtworkPageID(
            queueIndex: 0,
            songID: song.id,
            coverArtID: song.coverArt
        )
    }

    private var isThermallyConstrained: Bool {
        switch thermalState {
        case .serious, .critical:
            true
        case .nominal, .fair:
            false
        @unknown default:
            true
        }
    }

    private var effectiveMotion: Bool {
        BuFiMotion.isEnabled(
            userPreference: motionEnabled,
            reduceMotion: reduceMotion,
            lowPowerMode: lowPowerMode,
            thermalState: thermalState
        )
    }

    @ViewBuilder
    private var tabs: some View {
        let tabView = TabView(selection: $tab) {
            tabPage(HomeView(), tag: .home)
                .tabItem { Label("홈", systemImage: "house.fill") }
                .tag(AppTab.home)

            tabPage(SearchView(), tag: .search)
                .tabItem { Label("검색하기", systemImage: "magnifyingglass") }
                .tag(AppTab.search)

            tabPage(LibraryView(), tag: .library)
                .tabItem { Label("내 라이브러리", systemImage: "music.note.list") }
                .tag(AppTab.library)

            tabPage(SettingsView(), tag: .settings)
                .tabItem { Label("설정", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
        .tint(BuFiTheme.accent)
        .sensoryFeedback(.selection, trigger: tab) { _, _ in
            hapticsEnabled && !lowPowerMode
        }
        .onChange(of: tab) { _, _ in
            guard effectiveMotion else {
                pageProgress = 1
                return
            }
            pageProgress = 0
            withAnimation(BuFiMotion.page) {
                pageProgress = 1
            }
        }

        tabView
            .overlayPreferenceValue(MiniPlayerPlacementPreferenceKey.self) { anchor in
                GeometryReader { proxy in
                    if let anchor, playbackItem.currentSong != nil {
                        let frame = proxy[anchor]
                        miniPlayer
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                            .zIndex(10)
                    }
                }
            }
            .animation(
                effectiveMotion ? BuFiMotion.content : .none,
                value: playbackItem.currentSong != nil
            )
    }

    private func tabPage<Content: View>(_ content: Content, tag: AppTab) -> some View {
        let activeProgress = tab == tag && effectiveMotion ? pageProgress : 1
        return content
            .opacity(activeProgress)
            .scaleEffect(0.996 + (0.004 * activeProgress))
            .safeAreaInset(edge: .bottom, spacing: 10) {
                if playbackItem.currentSong != nil {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: 60)
                        .anchorPreference(
                            key: MiniPlayerPlacementPreferenceKey.self,
                            value: .bounds
                        ) { $0 }
                        .padding(.bottom, 6)
                }
            }
    }

    private var miniPlayer: some View {
        MiniPlayerView()
            .frame(height: 60)
            .padding(.horizontal, 8)
            .transition(
                effectiveMotion
                    ? .move(edge: .bottom).combined(with: .opacity)
                    : .opacity
            )
    }

    private var syncTaskID: String {
        "\(session.phase)-\(scenePhase)-\(syncInterval)-\(lowPowerMode)-\(thermalKey)-\(playbackActivity.isPlaying)"
    }

    private var thermalKey: String {
        switch thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    private var baseSyncInterval: TimeInterval {
        let selected = max(syncInterval, 30)

        switch thermalState {
        case .serious, .critical:
            return max(selected, 900)
        case .fair:
            return max(selected, playbackActivity.isPlaying ? 300 : 120)
        case .nominal:
            break
        @unknown default:
            return max(selected, 900)
        }

        if playbackActivity.isPlaying {
            return max(selected, 180)
        }
        return selected
    }

    private func runAutomaticSync() async {
        guard session.phase == .ready,
              scenePhase == .active,
              !lowPowerMode,
              !isThermallyConstrained else {
            return
        }

        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(baseSyncInterval))
            } catch {
                return
            }

            guard session.phase == .ready,
                  scenePhase == .active,
                  !lowPowerMode,
                  !isThermallyConstrained else {
                return
            }
            await model.refresh(silent: true)
        }
    }
}
