import SwiftUI

@main
struct BuFiApp: App {
    @StateObject private var model: AppModel
    @StateObject private var audio: AudioEngine

    init() {
        LaunchDiagnostics.beginLaunch()
        _model = StateObject(wrappedValue: AppModel())
        LaunchDiagnostics.mark("app-model-created")
        _audio = StateObject(wrappedValue: AudioEngine.shared)
        LaunchDiagnostics.mark("audio-model-created")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.session)
                .environmentObject(model.library)
                .environmentObject(model.searchContent)
                .environmentObject(model.favorites)
                .environmentObject(audio)
                .environmentObject(audio.playbackState)
                .environmentObject(audio.playbackState.current)
                .environmentObject(audio.activityState)
                .environmentObject(audio.controlState)
                .environmentObject(audio.presentation)
                .tint(BuFiTheme.accent)
                .task {
                    // SwiftUI may begin a view task before Core Animation has
                    // committed the first frame. Yield and add a short grace
                    // period so MediaPlayer, AVFoundation, and network-monitor
                    // registration cannot extend or crash the pre-frame path.
                    await Task.yield()
                    try? await Task.sleep(for: .milliseconds(150))
                    LaunchDiagnostics.mark("first-scene-mounted")
                    audio.activateRuntimeIfNeeded()
                    await model.bootstrapIfNeeded()
                }
        }
    }
}
