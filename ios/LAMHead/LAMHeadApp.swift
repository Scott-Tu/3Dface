import SwiftUI

@main
struct LAMHeadApp: App {
    @StateObject private var settings = SettingsStore()
    @StateObject private var env = KaggleEnvModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                .environmentObject(env)
        }
    }
}
