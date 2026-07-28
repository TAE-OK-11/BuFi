import SwiftUI

@main
struct BuFiApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var audio = AudioEngine.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(audio)
                .tint(BuFiTheme.accent)
        }
    }
}
