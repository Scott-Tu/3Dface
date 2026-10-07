import Foundation
import UIKit

/// 「建立 Kaggle 環境」：只需要做一次，把套件、編譯結果和模型權重存在 Kaggle 上
@MainActor
final class KaggleEnvModel: ObservableObject {
    @Published var status: String
    @Published var busy = false
    @Published var ready: Bool { didSet { UserDefaults.standard.set(ready, forKey: "envReady") } }
    private var task: Task<Void, Never>?
    private var buildId: String? {
        get { UserDefaults.standard.string(forKey: "envBuildId") }
        set { UserDefaults.standard.set(newValue, forKey: "envBuildId") }
    }

    init() {
        let r = UserDefaults.standard.bool(forKey: "envReady")
        ready = r
        status = r ? "✅ 環境已建立" : "尚未建立（第一次使用前要先建立）"
    }

    /// 送出建置工作並等待完成（約 40–60 分鐘；中途離開 App 也沒關係，回來按「查詢狀態」）
    func build() {
        guard let client = KaggleClient.fromSettings() else { status = "請先填入 Kaggle 使用者名稱與 API 金鑰"; return }
        task?.cancel()
        task = Task {
            busy = true
            defer { busy = false }
            do {
                let id = shortId()
                let script = try KaggleScripts.envScript(buildId: id)
                status = "送出建置工作…"
                try await withRetry("送出建置工作") {
                    try await client.pushKernel(slug: KaggleNames.envKernel, title: "lam env build", script: script,
                                                machineShape: KaggleNames.machineShape)
                }
                buildId = id
                ready = false
                try await wait(client: client, id: id)
            } catch is CancellationError {
                status = "已停止等待；Kaggle 仍在建置，稍後按「查詢狀態」"
            } catch {
                status = "❌ \(error.localizedDescription)"
            }
        }
    }

    /// 查詢最近一次建置的結果
    func refresh() {
        guard let client = KaggleClient.fromSettings() else { status = "請先填入 Kaggle 使用者名稱與 API 金鑰"; return }
        task?.cancel()
        task = Task {
            busy = true
            defer { busy = false }
            do {
                if let id = buildId {
                    try await wait(client: client, id: id)
                } else {
                    // 這支 iPhone 沒送過建置工作：直接看 Kaggle 上有沒有可用的環境
                    let (_, j) = try await client.outputJSON(kernel: KaggleNames.envKernel, file: "env_meta.json")
                    apply(j)
                }
            } catch is CancellationError {
                status = "已停止等待"
            } catch {
                status = "❌ \(error.localizedDescription)"
            }
        }
    }

    func stop() { task?.cancel() }

    private func wait(client: KaggleClient, id: String) async throws {
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        let (_, j) = try await client.waitForOutput(
            kernel: KaggleNames.envKernel, file: "env_meta.json", maxWait: 3 * 3600,
            isMine: { ($0["build_id"] as? String) == id && ($0["status"] as? String) != "running" },
            onStatus: { [weak self] text, elapsed in
                self?.status = "\(text)（已 \(Int(elapsed / 60)) 分鐘，通常 40–60 分鐘；可以先離開 App）"
            })
        apply(j)
    }

    private func apply(_ j: [String: Any]?) {
        guard let j else { ready = false; status = "尚未建立（第一次使用前要先建立）"; return }
        let ok = (j["status"] as? String) == "ok"
        let versionOK = (j["env_version"] as? String) == KaggleNames.envVersion
        ready = ok && versionOK
        if ready {
            let gb = (j["size_gb"] as? Double).map { String(format: "，%.1f GB", $0) } ?? ""
            status = "✅ 環境已建立\(gb)"
        } else if ok {
            status = "⚠️ 環境版本過舊，請重新建立"
        } else if (j["status"] as? String) == "running" {
            status = "⏳ 還在建置中"
        } else {
            status = "❌ 建置失敗：\((j["message"] as? String ?? "").suffix(400))"
        }
    }
}
