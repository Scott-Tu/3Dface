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

    /// 已送出建置、還沒拿到最終結果（App 被關掉或切到背景後，回來要接著查詢，不能重送）
    @Published private(set) var building: Bool { didSet { UserDefaults.standard.set(building, forKey: "envBuilding") } }

    init() {
        let r = UserDefaults.standard.bool(forKey: "envReady")
        let b = UserDefaults.standard.bool(forKey: "envBuilding")
        ready = r
        building = b
        status = b ? "⏳ 上次送出的建置還在 Kaggle 上跑，正在查詢…"
                   : (r ? "✅ 環境已建立" : "尚未建立（第一次使用前要先建立）")
        if b { Task { @MainActor in self.refresh() } }
    }

    /// App 回到前景時呼叫：有建置在跑就自動接著等
    func resumeIfNeeded() {
        if building && !busy { refresh() }
    }

    /// 送出建置工作並等待完成（約 40–60 分鐘；中途離開 App 也沒關係，回來會自動接著查詢）
    func build() {
        guard let client = KaggleClient.fromSettings() else { status = "請先填入 Kaggle 使用者名稱與 API 金鑰"; return }
        task?.cancel()
        task = Task {
            busy = true
            defer { busy = false }
            do {
                // Kaggle 上已經有建置在跑時不要重送：重送會取消正在跑的那次、從頭再來
                let current = building ? (try? await client.kernelStatus(slug: KaggleNames.envKernel))?.status.lowercased() ?? "" : ""
                if let id = buildId, current.contains("running") || current.contains("queued") {
                    status = "Kaggle 上的建置還在跑，繼續等它完成（不重新送出）"
                    try await wait(client: client, id: id)
                    return
                }
                let id = shortId()
                let script = try KaggleScripts.envScript(buildId: id)
                status = "送出建置工作…"
                try await withRetry("送出建置工作") {
                    try await client.pushKernel(slug: KaggleNames.envKernel, title: "lam env build", script: script,
                                                machineShape: KaggleNames.machineShape)
                }
                buildId = id
                ready = false
                building = true
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
                    // Kaggle 上還沒有這個程式時會回 403／404，視為尚未建立
                    let r = try? await client.outputJSON(kernel: KaggleNames.envKernel, file: "env_meta.json")
                    apply(r?.json)
                }
            } catch is CancellationError {
                status = building ? "已停止等待；Kaggle 仍在建置，稍後按「查詢狀態」" : "已停止等待"
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
        if (j?["status"] as? String) != "running" { building = false }
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
