import Foundation

enum APIError: LocalizedError {
    case badURL
    case http(Int, String)
    case invalidData
    case timeout

    var errorDescription: String? {
        switch self {
        case .badURL: return "伺服器網址格式錯誤"
        case .http(let code, let body):
            if code == 401 { return "API Key 錯誤" }
            if let d = body.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let detail = obj["detail"] {
                return "伺服器錯誤 \(code)：\(detail)"
            }
            if [404, 502, 503, 530].contains(code) { return "連不到伺服器（Kaggle 或 tunnel 可能已停止）" }
            return "伺服器錯誤 \(code)"
        case .invalidData: return "收到的資料格式不正確"
        case .timeout: return "等待逾時"
        }
    }
}

struct APIClient {
    let baseURL: URL
    let apiKey: String

    init(baseURLString: String, apiKey: String) throws {
        var s = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), let scheme = url.scheme, scheme.hasPrefix("http"), url.host != nil
        else { throw APIError.badURL }
        self.baseURL = url
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func request(_ path: String, method: String = "GET", timeout: TimeInterval = 30) -> URLRequest {
        var r = URLRequest(url: baseURL.appendingPathComponent(path))
        r.httpMethod = method
        r.timeoutInterval = timeout
        r.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        return r
    }

    private func send(_ r: URLRequest) async throws -> Data {
        let (data, resp) = try await URLSession.shared.data(for: r)
        guard let http = resp as? HTTPURLResponse else { throw APIError.invalidData }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private func get<T: Decodable>(_ path: String, as type: T.Type) async throws -> T {
        let data = try await send(request(path))
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw APIError.invalidData }
    }

    func health() async throws -> HealthResponse { try await get("health", as: HealthResponse.self) }
    func defaults() async throws -> DefaultsResponse { try await get("defaults", as: DefaultsResponse.self) }
    func status(_ jobId: String) async throws -> JobStatus { try await get("jobs/\(jobId)", as: JobStatus.self) }
    func manifest(_ jobId: String) async throws -> Manifest { try await get("jobs/\(jobId)/manifest", as: Manifest.self) }

    func bundle(_ jobId: String) async throws -> Data {
        try await send(request("jobs/\(jobId)/bundle", timeout: 120))
    }

    /// 上傳照片與參數，回傳 job 狀態
    func submit(jpeg: Data, params: RenderParams) async throws -> JobStatus {
        let boundary = "Boundary-\(UUID().uuidString)"
        var r = request("jobs", method: "POST", timeout: 90)
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func add(_ s: String) { body.append(Data(s.utf8)) }
        let paramsJSON = String(data: try JSONEncoder().encode(params), encoding: .utf8) ?? "{}"
        add("--\(boundary)\r\n")
        add("Content-Disposition: form-data; name=\"params\"\r\n\r\n")
        add(paramsJSON)
        add("\r\n--\(boundary)\r\n")
        add("Content-Disposition: form-data; name=\"image\"; filename=\"input.jpg\"\r\n")
        add("Content-Type: image/jpeg\r\n\r\n")
        body.append(jpeg)
        add("\r\n--\(boundary)--\r\n")
        r.httpBody = body

        let data = try await send(r)
        do { return try JSONDecoder().decode(JobStatus.self, from: data) }
        catch { throw APIError.invalidData }
    }
}
