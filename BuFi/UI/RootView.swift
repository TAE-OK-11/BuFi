import SwiftUI

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
            PlayerView()
                .environmentObject(model)
                .environmentObject(audio)
        }
    }

    private var appContent: some View {
        TabView(selection: $tab) {
            HomeView()
                .tag(AppTab.home)
            SearchView()
                .tag(AppTab.search)
            LibraryView()
                .tag(AppTab.library)
            SettingsView()
                .tag(AppTab.settings)
        }
        .toolbar(.hidden, for: .tabBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 5) {
                MiniPlayerView()
                bottomBar
            }
            .background(
                LinearGradient(
                    colors: [.clear, Color.black.opacity(0.96)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
            )
        }
    }

    private var bottomBar: some View {
        HStack {
            tabButton(.home, title: "홈", icon: "house.fill")
            tabButton(.search, title: "검색하기", icon: "magnifyingglass")
            tabButton(.library, title: "내 라이브러리", icon: "books.vertical.fill")
            tabButton(.settings, title: "설정", icon: "gearshape.fill")
        }
        .frame(height: 57)
    }

    private func tabButton(_ value: AppTab, title: String, icon: String) -> some View {
        Button {
            tab = value
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: tab == value ? .bold : .regular))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(tab == value ? .white : .secondary)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(tab == value ? .isSelected : [])
    }
}
