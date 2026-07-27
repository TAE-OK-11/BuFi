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
    @State private var tab: AppTab = .home
    @State private var pageOpacity = 1.0
    @State private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    @AppStorage("appearance-mode") private var appearanceMode = AppAppearance.system.rawValue
    @AppStorage("haptics-enabled") private var hapticsEnabled = true
    @AppStorage("motion-enabled") private var motionEnabled = true
    @AppStorage("server-sync-interval") private var syncInterval = 30.0

    var body: some View {
        Group {
            switch model.sessionState {
            case .signedOut, .connecting:
                LoginView()
            case .ready:
                appContent
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.sessionState)
        .preferredColorScheme(
            AppAppearance(rawValue: appearanceMode)?.colorScheme
        )
        .transaction { transaction in
            if !motionEnabled { transaction.animation = nil }
        }
        .task(id: syncTaskID) {
            await runAutomaticSync()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: Notification.Name.NSProcessInfoPowerStateDidChange
            )
        ) { _ in
            lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
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

    private var appContent: some View {
        tabs
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            tabPage(HomeView(), tag: .home)
                .tabItem {
                    Label("홈", systemImage: "house.fill")
                }
                .tag(AppTab.home)

            tabPage(SearchView(), tag: .search)
                .tabItem {
                    Label("검색하기", systemImage: "magnifyingglass")
                }
                .tag(AppTab.search)

            tabPage(LibraryView(), tag: .library)
                .tabItem {
                    Label("내 라이브러리", systemImage: "music.note.list")
                }
                .tag(AppTab.library)

            tabPage(SettingsView(), tag: .settings)
                .tabItem {
                    Label("설정", systemImage: "gearshape.fill")
                }
                .tag(AppTab.settings)
        }
        .tint(BuFiTheme.accent)
        .onChange(of: tab) { _, _ in
            if hapticsEnabled {
                UISelectionFeedbackGenerator().selectionChanged()
            }
            guard motionEnabled else {
                pageOpacity = 1
                return
            }
            pageOpacity = 0
            withAnimation(.easeOut(duration: 0.18)) {
                pageOpacity = 1
            }
        }
    }

    @ViewBuilder
    private func tabPage<Content: View>(_ content: Content, tag: AppTab) -> some View {
        content
            .opacity(tab == tag ? pageOpacity : 1)
            .safeAreaInset(edge: .bottom, spacing: 10) {
                if audio.currentSong != nil {
                    LegacyMiniPlayerView()
                        .frame(height: 60)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                }
            }
    }

    private var syncTaskID: String {
        "\(model.sessionState)-\(scenePhase)-\(syncInterval)-\(lowPowerMode)-\(tab)"
    }

    private var baseSyncInterval: TimeInterval {
        let selected = max(syncInterval, 30)
        guard lowPowerMode else { return selected }
        return max(selected * 2, 120)
    }

    private func syncDelay(afterCompletedRounds rounds: Int) -> TimeInterval {
        guard !lowPowerMode else {
            return min(max(baseSyncInterval * pow(2, Double(min(rounds, 2))), 120), 600)
        }
        return min(baseSyncInterval * pow(2, Double(min(rounds, 4))), 300)
    }

    private func runAutomaticSync() async {
        guard model.sessionState == .ready, scenePhase == .active else { return }

        var completedRounds = 0
        while !Task.isCancelled {
            let delay = syncDelay(afterCompletedRounds: completedRounds)
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }

            guard model.sessionState == .ready, scenePhase == .active else { return }
            await model.refresh(silent: true)
            completedRounds += 1
        }
    }
}
