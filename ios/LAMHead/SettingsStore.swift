import Foundation

/// 生成與檢視參數，存在 UserDefaults（Kaggle 帳號另外存：使用者名稱在 UserDefaults，金鑰在鑰匙圈）
@MainActor
final class SettingsStore: ObservableObject {
    @Published var render: RenderParams { didSet { save() } }
    @Published var client: ClientParams { didSet { save() } }
    @Published var motions: [String] = []

    private let defaults = UserDefaults.standard

    init() {
        render = Self.load(RenderParams.self, key: "render") ?? RenderParams()
        client = Self.load(ClientParams.self, key: "client_v2") ?? ClientParams()
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func save() {
        if let d = try? JSONEncoder().encode(render) { defaults.set(d, forKey: "render") }
        if let d = try? JSONEncoder().encode(client) { defaults.set(d, forKey: "client_v2") }
    }
}
