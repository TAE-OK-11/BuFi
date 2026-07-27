import SwiftUI
import UIKit

enum AppTab: Hashable {
    case home
    case search
    case library
    case settings
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var audio: AudioEngine
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tab: AppTab = .home
    @State private var pageProgress = 1.0
    @State private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var thermalState = ProcessInfo.processInfo.thermalState
    @AppStorage("appearance-mode") private var appearanceMode = AppAppearance.system.rawValue
    @AppStorage("haptics-enabled") private var hapticsEnabled = true
    @AppStorage("motion-enabled") private var motionEnabled = true
    @AppStorage("server-sync-interval") private var syncInterval = 30.0

    private let tabHaptic = UISelectionFeedbackGenerator()

    var body: some View {
        Group {
            switch model.sessionState {
            case .signedOut, .connecting:
                LoginView()
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            case .ready:
                appContent
                    .transition(.opacity)
            }
        }
        .animation(effectiveMotion ? BuFiMotion.fade : .none, value: model.sessionState)
        .preferredColorScheme(AppAppearance(rawValue: appearanceMode)?.colorScheme)
        .transaction { transaction in
            if !effectiveMotion { transaction.animation = nil }
        }
        .task(id: syncTaskID) {
            await runAutomaticSync()
        }
        .onAppear {
            if hapticsEnabled && !lowPowerMode { tabHaptic.prepare() }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            Task(priority: .utility) {
                await OfflineStore.shared.flushPendingWrites()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name.NSProcessInfoPowerStateDidChange)) { _ in
            lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            thermalState = ProcessInfo.processInfo.thermalState
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            Task(priority: .utility) {
                await ArtworkStore.shared.clearMemory()
            }
        }
        .alert(
            "오류",
            isPresented: Binding(
                get: { model.errorMessage != nil && model.sessionState == .ready },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("확인", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert(
            "재생 오류",
            isPresented: Binding(
                get: { audio.playbackError != nil },
                set: { if !$0 { audio.playbackError = nil } }
            )
        ) {
            Button("확인", role: .cancel) { audio.playbackError = nil }
        } message: {
            Text(audio.playbackError ?? "")
        }
        .fullScreenCover(isPresented: $audio.showPlayer) {
            NavigationStack {
                PlayerView()
                    .navigationDestination(for: MusicRoute.self) { route in
                        MusicDetailView(route: route)
                    }
            }
            .environmentObject(model)
            .environmentObject(audio)
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

    private var effectiveMotion: Bool {
        motionEnabled && !reduceMotion && !lowPowerMode && !isThermallyConstrained
    }

    private var appContent: some View {
        tabs
    }

    private var tabs: some View {
        TabView(selection: $tab) {
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
        .onChange(of: tab) { _, _ in
            if hapticsEnabled && !lowPowerMode {
                tabHaptic.selectionChanged()
                tabHaptic.prepare()
            }
            guard effectiveMotion else {
                pageProgress = 1
                return
            }
            pageProgress = 0
            withAnimation(BuFiMotion.page) {
                pageProgress = 1
            }
        }
    }

    @ViewBuilder
    private func tabPage<Content: View>(_ content: Content, tag: AppTab) -> some View {
        let activeProgress = tab == tag && effectiveMotion ? pageProgress : 1
        content
            .opacity(activeProgress)
            .scaleEffect(0.992 + (0.008 * activeProgress))
            .blur(radius: (1 - activeProgress) * 1.2)
            .safeAreaInset(edge: .bottom, spacing: 10) {
                if audio.currentSong != nil {
                    LegacyMiniPlayerView()
                        .frame(height: 60)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                        .transition(effectiveMotion ? .move(edge: .bottom).combined(with: .opacity) : .opacity)
                }
            }
            .animation(effectiveMotion ? BuFiMotion.player : .none, value: audio.currentSong?.id)
    }

    private var syncTaskID: String {
        "\(model.sessionState)-\(scenePhase)-\(syncInterval)-\(lowPowerMode)-\(thermalKey)-\(audio.isPlaying)"
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
            return max(selected, audio.isPlaying ? 300 : 120)
        case .nominal:
            break
        @unknown default:
            return max(selected, 900)
        }

        if audio.isPlaying {
            return max(selected, 180)
        }
        return selected
    }

    private func syncDelay(afterCompletedRounds rounds: Int) -> TimeInterval {
        let maximum: TimeInterval = audio.isPlaying ? 900 : 600
        return min(baseSyncInterval * pow(2, Double(min(rounds, 4))), maximum)
    }

    private func runAutomaticSync() async {
        guard model.sessionState == .ready,
              scenePhase == .active,
              !lowPowerMode,
              !isThermallyConstrained else {
            return
        }

        var completedRounds = 0
        while !Task.isCancelled {
            let delay = syncDelay(afterCompletedRounds: completedRounds)
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }

            guard model.sessionState == .ready,
                  scenePhase == .active,
                  !lowPowerMode,
                  !isThermallyConstrained else {
                return
            }
            await model.refresh(silent: true)
            completedRounds += 1
        }
    }
}
