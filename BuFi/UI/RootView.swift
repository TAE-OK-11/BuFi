import SwiftUI
import UIKit

enum AppTab: Hashable {
    case home
    case search
    case library
    case settings
}

private struct MiniPlayerPlacementPreferenceKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(
        value: inout Anchor<CGRect>?,
        nextValue: () -> Anchor<CGRect>?
    ) {
        value = nextValue() ?? value
    }
}

private struct PlayerPresentationSession: Identifiable {
    let id: UUID
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: AppSessionState
    @EnvironmentObject private var currentPlayback: CurrentPlaybackState
    @EnvironmentObject private var playerPresentation: PlayerPresentationState
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tab: AppTab = .home
    @State private var mountedTabs: Set<AppTab> = [.home]
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
                    .transition(effectiveMotion ? BuFiTransition.scene : .opacity)
            case .connecting:
                ZStack {
                    BuFiScreenBackground()
                    ProgressView("자동 로그인 중…")
                        .font(.system(size: 15, weight: .semibold))
                        .tint(BuFiTheme.accent)
                }
                .transition(effectiveMotion ? BuFiTransition.scene : .opacity)
            case .signingOut:
                ZStack {
                    BuFiScreenBackground()
                    ProgressView("로그아웃 중…")
                        .font(.system(size: 15, weight: .semibold))
                        .tint(BuFiTheme.accent)
                }
                .transition(effectiveMotion ? BuFiTransition.scene : .opacity)
            case .ready:
                tabs
                    .transition(effectiveMotion ? BuFiTransition.scene : .opacity)
            }
        }
        .animation(effectiveMotion ? BuFiMotion.fade : .none, value: session.phase)
        .preferredColorScheme(AppAppearance(rawValue: appearanceMode)?.colorScheme)
        .environment(\.buFiMotionEnabled, effectiveMotion)
        .transaction { transaction in
            if !effectiveMotion { transaction.animation = nil }
        }
        .background {
            AutomaticSyncHost(
                model: model,
                syncInterval: syncInterval,
                lowPowerMode: lowPowerMode,
                thermalState: thermalState
            )
        }
        .task(id: scenePhase == .active) {
            guard scenePhase != .active else { return }
            await OfflineStore.shared.flushPendingWrites()
            await ListeningHistoryStore.shared.flushPendingWrites()
        }
        .task {
            await observePowerStateChanges()
        }
        .task {
            await observeThermalStateChanges()
        }
        .task {
            await observeMemoryWarnings()
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
        .fullScreenCover(item: playerPresentationSession) { presentation in
            NavigationStack {
                PlayerView()
                    .navigationDestination(for: MusicRoute.self) { route in
                        MusicDetailView(route: route)
                    }
            }
            .environmentObject(model)
            .environmentObject(audio)
            .environment(\.buFiMotionEnabled, effectiveMotion)
            .id(presentation.id)
        }
    }

    private var playerPresentationSession: Binding<PlayerPresentationSession?> {
        Binding(
            get: {
                guard playerPresentation.showPlayer else { return nil }
                return PlayerPresentationSession(
                    id: playerPresentation.presentationID
                )
            },
            set: { presentation in
                if presentation == nil {
                    audio.showPlayer = false
                }
            }
        )
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
            tabPage(mounted(.home) { HomeView() }, tag: .home)
                .tabItem { Label("홈", systemImage: "house.fill") }
                .tag(AppTab.home)

            tabPage(mounted(.search) { SearchView() }, tag: .search)
                .tabItem { Label("검색하기", systemImage: "magnifyingglass") }
                .tag(AppTab.search)

            tabPage(mounted(.library) { LibraryView() }, tag: .library)
                .tabItem { Label("내 라이브러리", systemImage: "music.note.list") }
                .tag(AppTab.library)

            tabPage(mounted(.settings) { SettingsView() }, tag: .settings)
                .tabItem { Label("설정", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
        .tint(BuFiTheme.accent)
        .sensoryFeedback(.selection, trigger: tab) { _, _ in
            hapticsEnabled && !lowPowerMode
        }
        .onChange(of: tab) { _, newTab in
            mountedTabs.insert(newTab)
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
                    if let anchor, currentPlayback.song != nil {
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
                value: currentPlayback.song != nil
            )
    }

    @ViewBuilder
    private func mounted<Content: View>(
        _ tag: AppTab,
        @ViewBuilder content: () -> Content
    ) -> some View {
        if mountedTabs.contains(tag) || tab == tag {
            content()
        } else {
            Color.clear.accessibilityHidden(true)
        }
    }

    private func tabPage<Content: View>(_ content: Content, tag: AppTab) -> some View {
        let activeProgress = tab == tag && effectiveMotion ? pageProgress : 1
        return content
            .opacity(activeProgress)
            .scaleEffect(0.996 + (0.004 * activeProgress))
            .offset(y: effectiveMotion ? CGFloat(1 - activeProgress) * 7 : 0)
            .safeAreaInset(edge: .bottom, spacing: 10) {
                if currentPlayback.song != nil {
                    Color.clear
                        .frame(maxWidth: .infinity)
                        .frame(height: 60)
                        .anchorPreference(
                            key: MiniPlayerPlacementPreferenceKey.self,
                            value: .bounds
                        ) { tab == tag ? $0 : nil }
                        .padding(.bottom, 6)
                }
            }
    }

    private var miniPlayer: some View {
        MiniPlayerView()
            .frame(height: 60)
            .padding(.horizontal, 8)
            .transition(effectiveMotion ? BuFiTransition.miniPlayer : .opacity)
    }

    @MainActor
    private func observePowerStateChanges() async {
        let currentLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        let currentThermalState = ProcessInfo.processInfo.thermalState
        lowPowerMode = currentLowPowerMode
        thermalState = currentThermalState
        applyEnergyConstraints(
            lowPowerMode: currentLowPowerMode,
            thermalState: currentThermalState
        )

        for await _ in NotificationCenter.default.notifications(
            named: Notification.Name.NSProcessInfoPowerStateDidChange
        ) {
            guard !Task.isCancelled else { return }
            let currentLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            lowPowerMode = currentLowPowerMode
            applyEnergyConstraints(
                lowPowerMode: currentLowPowerMode,
                thermalState: thermalState
            )
        }
    }

    @MainActor
    private func observeThermalStateChanges() async {
        for await _ in NotificationCenter.default.notifications(
            named: ProcessInfo.thermalStateDidChangeNotification
        ) {
            guard !Task.isCancelled else { return }
            let currentThermalState = ProcessInfo.processInfo.thermalState
            thermalState = currentThermalState
            applyEnergyConstraints(
                lowPowerMode: lowPowerMode,
                thermalState: currentThermalState
            )
        }
    }

    @MainActor
    private func applyEnergyConstraints(
        lowPowerMode: Bool,
        thermalState: ProcessInfo.ThermalState
    ) {
        model.handleEnergyConstraints(
            lowPowerMode: lowPowerMode,
            thermalState: thermalState
        )
        audio.handleEnergyConstraints(
            lowPowerMode: lowPowerMode,
            thermalState: thermalState
        )
    }

    @MainActor
    private func observeMemoryWarnings() async {
        for await _ in NotificationCenter.default.notifications(
            named: UIApplication.didReceiveMemoryWarningNotification
        ) {
            guard !Task.isCancelled else { return }
            model.handleMemoryPressure()
            audio.handleMemoryPressure()
            await ArtworkStore.shared.clearMemory()
        }
    }
}

private struct AutomaticSyncHost: View {
    @EnvironmentObject private var session: AppSessionState
    @EnvironmentObject private var playbackActivity: PlaybackActivityState
    @Environment(\.scenePhase) private var scenePhase

    let model: AppModel
    let syncInterval: TimeInterval
    let lowPowerMode: Bool
    let thermalState: ProcessInfo.ThermalState

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: identity) {
                await runAutomaticSync()
            }
    }

    private var identity: AutomaticSyncIdentity {
        AutomaticSyncIdentity(
            isReady: session.phase == .ready,
            isSceneActive: scenePhase == .active,
            syncInterval: syncInterval,
            lowPowerMode: lowPowerMode,
            isPlaying: playbackActivity.isPlaying,
            thermalKey: thermalKey
        )
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

private struct AutomaticSyncIdentity: Hashable, Sendable {
    let isReady: Bool
    let isSceneActive: Bool
    let syncInterval: TimeInterval
    let lowPowerMode: Bool
    let isPlaying: Bool
    let thermalKey: String
}
