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

    @ViewBuilder
    private var appContent: some View {
        if #available(iOS 26.1, *) {
            tabs
                .tabViewBottomAccessory(isEnabled: audio.currentSong != nil) {
                    MiniPlayerView()
                }
        } else {
            tabs
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if audio.currentSong != nil {
                        MiniPlayerView()
                    }
                }
        }
    }

    private var tabs: some View {
        TabView(selection: $tab) {
            HomeView()
                .tabItem {
                    Label("홈", systemImage: "house.fill")
                }
                .tag(AppTab.home)
            SearchView()
                .tabItem {
                    Label("검색하기", systemImage: "magnifyingglass")
                }
                .tag(AppTab.search)
            LibraryView()
                .tabItem {
                    Label("내 라이브러리", systemImage: "music.note.list")
                }
                .tag(AppTab.library)
            SettingsView()
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
}
