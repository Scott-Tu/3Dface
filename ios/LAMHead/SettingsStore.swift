import Foundation

/// 所有可調整設定，存在 UserDefaults
@MainActor
final class SettingsStore: ObservableObject {
    @Published var serverURL: String { didSet { save() } }
    @Published var apiKey: String { didSet { save() } }
    @Published var render: RenderParams { didSet { save() } }
    @Published var client: ClientParams { didSet { save() } }
    @Published var motions: [String] = []

    private let defaults = UserDefaults.standard

    init() {
        serverURL = defaults.string(forKey: "serverURL") ?? ""
        apiKey = defaults.string(forKey: "apiKey") ?? ""
        render = Self.load(RenderParams.self, key: "render") ?? RenderParams()
        client = Self.load(ClientParams.self, key: "client") ?? ClientParams()
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func save() {
        defaults.set(serverURL, forKey: "serverURL")
        defaults.set(apiKey, forKey: "apiKey")
        if let d = try? JSONEncoder().encode(render) { defaults.set(d, forKey: "render") }
        if let d = try? JSONEncoder().encode(client) { defaults.set(d, forKey: "client") }
    }

    func makeClient() throws -> APIClient {
        try APIClient(baseURLString: serverURL, apiKey: apiKey)
    }

    /// 處理 Kaggle 顯示的 QR Code：lamhead://config?url=...&key=...
    @discardableResult
    func apply(configURL url: URL) -> Bool {
        guard url.scheme == "lamhead", url.host == "config",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return false }
        if let u = items.first(where: { $0.name == "url" })?.value { serverURL = u }
        if let k = items.first(where: { $0.name == "key" })?.value { apiKey = k }
        return true
    }
}
