import SwiftUI

@main
struct LAMHeadApp: App {
    @StateObject private var settings = SettingsStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(settings)
                // 掃描 Kaggle 的 QR Code（lamhead://config?url=...&key=...）會從這裡進來
                .onOpenURL { settings.apply(configURL: $0) }
        }
    }
}
