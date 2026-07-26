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
    @State private var tab: AppTab = .home
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
            tabPage(HomeView())
                .tabItem {
                    Label("홈", systemImage: "house.fill")
                }
                .tag(AppTab.home)

            tabPage(SearchView())
                .tabItem {
                    Label("검색하기", systemImage: "magnifyingglass")
                }
                .tag(AppTab.search)

            tabPage(LibraryView())
                .tabItem {
                    Label("내 라이브러리", systemImage: "music.note.list")
                }
                .tag(AppTab.library)

            tabPage(SettingsView())
                .tabItem {
                    Label("설정", systemImage: "gearshape.fill")
                }
                .tag(AppTab.settings)
        }
        .tint(BuFiTheme.accent)
        .onChange(of: tab) { _, _ in
            guard hapticsEnabled else { return }
            UISelectionFeedbackGenerator().selectionChanged()
        }
        .animation(
            motionEnabled
                ? .interactiveSpring(response: 0.38, dampingFraction: 0.82)
                : .none,
            value: tab
        )
    }

    @ViewBuilder
    private func tabPage<Content: View>(_ content: Content) -> some View {
        content
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
        "\(model.sessionState)-\(syncInterval)"
    }

    private func runAutomaticSync() async {
        guard model.sessionState == .ready else { return }
        let seconds = max(syncInterval, 30)
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            } catch {
                return
            }
            guard model.sessionState == .ready else { return }
            await model.refresh()
        }
    }
}
