import SwiftUI

@main
struct BuFiApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var audio = AudioEngine.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.session)
                .environmentObject(model.library)
                .environmentObject(model.searchContent)
                .environmentObject(model.favorites)
                .environmentObject(audio)
                .environmentObject(audio.itemState)
                .environmentObject(audio.activityState)
                .environmentObject(audio.controlState)
                .environmentObject(audio.queueState)
                .environmentObject(audio.presentation)
                .tint(BuFiTheme.accent)
        }
    }
}
