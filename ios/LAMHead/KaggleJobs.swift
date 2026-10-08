import Foundation

/// 在 Kaggle 上使用的名稱（都建立在使用者自己的帳號下，皆為私人）
enum KaggleNames {
    static let envKernel = "lam-env-build"      // 環境建置程式（只跑一次），它的輸出就是打包好的環境
    static let jobKernel = "lam-head-job"       // 每次生成用的程式
    static let inputDataset = "lam-head-input"  // 每次生成上傳的照片
    static let envVersion = "1"                 // 環境內容有變動時加 1，App 會要求重建
    static let machineShape = "NvidiaTeslaT4"
}

/// 打包在 App 內的 Kaggle 腳本（kaggle/*.py），送出前替換參數
enum KaggleScripts {
    private static func load(_ name: String) throws -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: "py"),
              let s = try? String(contentsOf: url, encoding: .utf8) else {
            throw KaggleError(message: "App 內找不到 \(name).py")
        }
        return s
    }

    private static func lamServerB64() throws -> String {
        guard let url = Bundle.main.url(forResource: "lam_server", withExtension: "py"),
              let d = try? Data(contentsOf: url) else {
            throw KaggleError(message: "App 內找不到 lam_server.py")
        }
        return d.base64EncodedString()
    }

    static func envScript(buildId: String) throws -> String {
        try load("lam_env_build")
            .replacingOccurrences(of: "__BUILD_ID__", with: buildId)
            .replacingOccurrences(of: "__ENV_VERSION__", with: KaggleNames.envVersion)
            .replacingOccurrences(of: "__LAM_SERVER_B64__", with: try lamServerB64())
    }

    static func jobScript(jobId: String, params: RenderParams) throws -> String {
        let paramsB64 = try JSONEncoder().encode(params).base64EncodedString()
        return try load("lam_job")
            .replacingOccurrences(of: "__JOB_ID__", with: jobId)
            .replacingOccurrences(of: "__PARAMS_B64__", with: paramsB64)
            .replacingOccurrences(of: "__ENV_VERSION__", with: KaggleNames.envVersion)
            .replacingOccurrences(of: "__LAM_SERVER_B64__", with: try lamServerB64())
    }
}

extension KaggleClient {
    /// 讀取某個 Kaggle 程式最近一次輸出中的 JSON 檔
    func outputJSON(kernel: String, file: String) async throws -> (files: [OutputFile], json: [String: Any]?) {
        let files = try await kernelOutputs(slug: kernel)
        guard let f = files.first(where: { ($0.name as NSString).lastPathComponent == file }) else { return (files, nil) }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try await download(f.url, to: tmp)
        let obj = (try? JSONSerialization.jsonObject(with: Data(contentsOf: tmp))) as? [String: Any]
        return (files, obj)
    }

    /// 等待程式跑完，直到輸出的 JSON 符合 isMine（確認是這一次的結果，不是上一次留下的）
    func waitForOutput(kernel: String, file: String, maxWait: TimeInterval,
                       isMine: @escaping ([String: Any]) -> Bool,
                       onStatus: @MainActor (String, TimeInterval) -> Void) async throws -> (files: [OutputFile], json: [String: Any]) {
        let start = Date()
        while true {
            try Task.checkCancellation()
            let elapsed = Date().timeIntervalSince(start)
            if elapsed > maxWait {
                throw KaggleError(message: "等待超過 \(Int(maxWait / 60)) 分鐘，請到 kaggle.com 查看「\(kernel)」的紀錄")
            }
            var st = ""
            var failure: String?
            do {
                (st, failure) = try await kernelStatus(slug: kernel)
            } catch let e as KaggleError {
                // 剛送出時 Kaggle 可能還查不到這個程式（403／404），先等一下再查
                if elapsed > 300 { throw e }
                await onStatus("等待 Kaggle 建立程式…", elapsed)
                try await Task.sleep(nanoseconds: 20_000_000_000)
                continue
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                await onStatus("網路不穩，稍後再查詢…", elapsed)
                try await Task.sleep(nanoseconds: 20_000_000_000)
                continue
            }
            let s = st.lowercased()
            if s.contains("queued") { await onStatus("Kaggle 排隊中…", elapsed) }
            else if s.contains("running") { await onStatus("Kaggle 運算中…", elapsed) }
            else { await onStatus("Kaggle 狀態：\(st)", elapsed) }

            if s.contains("complete") || s.contains("error") || s.contains("cancel") {
                let r = try? await outputJSON(kernel: kernel, file: file)
                if let r, let j = r.json, isMine(j) { return (r.files, j) }
                if s.contains("error") && elapsed > 180 {
                    throw KaggleError(message: "Kaggle 執行失敗：\(failure ?? "請到 kaggle.com 查看「\(kernel)」的紀錄")")
                }
                if s.contains("cancel") && elapsed > 180 {
                    throw KaggleError(message: "Kaggle 上的執行被取消了")
                }
                if s.contains("complete") && elapsed > 180 {
                    throw KaggleError(message: "Kaggle 程式已結束，但沒有留下這次的結果，請到 kaggle.com 查看「\(kernel)」的紀錄")
                }
            }
            try await Task.sleep(nanoseconds: 20_000_000_000)
        }
    }
}

/// 網路不穩時自動重試（Kaggle 回傳的錯誤不重試）
func withRetry<T>(_ label: String, attempts: Int = 4, _ op: () async throws -> T) async throws -> T {
    var lastError: Error = KaggleError(message: "網路錯誤")
    for k in 0..<attempts {
        do {
            return try await op()
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as KaggleError {
            throw e
        } catch {
            lastError = error
            if k == attempts - 1 { break }
            try await Task.sleep(nanoseconds: UInt64(5 + 10 * k) * 1_000_000_000)
        }
    }
    throw KaggleError(message: "\(label)失敗：網路連線不穩（\(lastError.localizedDescription)）")
}

func shortId() -> String { String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased() }
