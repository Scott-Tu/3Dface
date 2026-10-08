import SwiftUI

@main
struct LAMHeadApp: App {
    @StateObject private var settings = SettingsStore()
    @StateObject private var env = KaggleEnvModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(env)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { env.resumeIfNeeded() }
        }
    }
}
