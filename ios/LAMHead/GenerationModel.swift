import UIKit

/// 拍照 → 上傳到 Kaggle → 執行 → 下載影格 的流程狀態
@MainActor
final class GenerationModel: ObservableObject {
    enum Phase {
        case idle
        case working(String, String)     // 標題、補充說明
        case ready(FrameSet)
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var inputImage: UIImage?
    @Published var pendingJobId: String? = UserDefaults.standard.string(forKey: "pendingJobId")
    private var task: Task<Void, Never>?

    var isBusy: Bool {
        if case .working = phase { return true }
        return false
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    private func setPending(_ id: String?) {
        pendingJobId = id
        UserDefaults.standard.set(id, forKey: "pendingJobId")
    }

    func generate(settings: SettingsStore) {
        guard let image = inputImage else { return }
        if let err = settings.render.validationError { phase = .failed(err); return }
        guard let client = KaggleClient.fromSettings() else {
            phase = .failed("請先到右上角設定填入 Kaggle 使用者名稱與 API 金鑰"); return
        }
        let render = settings.render
        let maxSide = settings.client.uploadMaxSide
        let timeout = settings.client.timeoutMinutes * 60

        task?.cancel()
        task = Task {
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            do {
                let jobId = shortId()
                phase = .working("準備照片…", "")
                guard let jpeg = image.resizedJPEG(maxSide: maxSide, quality: 0.9) else { throw APIError.invalidData }
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("input_\(jobId).jpg")
                try jpeg.write(to: file)
                defer { try? FileManager.default.removeItem(at: file) }

                phase = .working("上傳照片到 Kaggle…", "上傳時請保持 App 在前景")
                let token = try await withRetry("上傳") { try await client.uploadBlob(file: file) }
                try await withRetry("建立資料集") {
                    try await client.pushDataset(slug: KaggleNames.inputDataset, title: "LAM head input", fileToken: token)
                }
                phase = .working("等待 Kaggle 處理照片…", "")
                try await Task.sleep(nanoseconds: 15_000_000_000)
                try await client.waitDatasetReady(slug: KaggleNames.inputDataset, timeout: 900)

                setPending(jobId)
                try await startJob(client: client, jobId: jobId, params: render)
                try await waitAndFetch(client: client, jobId: jobId, params: render, timeout: timeout)
            } catch is CancellationError {
                stopped()
            } catch let e as URLError where e.code == .cancelled {
                stopped()
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// App 被關掉或離開後，回來繼續查詢上一次的工作
    func resume(settings: SettingsStore) {
        guard let jobId = pendingJobId, let client = KaggleClient.fromSettings() else { return }
        let render = settings.render
        let timeout = settings.client.timeoutMinutes * 60
        task?.cancel()
        task = Task {
            UIApplication.shared.isIdleTimerDisabled = true
            defer { UIApplication.shared.isIdleTimerDisabled = false }
            do {
                try await waitAndFetch(client: client, jobId: jobId, params: render, timeout: timeout)
            } catch is CancellationError {
                stopped()
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func stopped() {
        phase = pendingJobId == nil ? .idle : .failed("已停止等待。Kaggle 仍會繼續算，稍後按「繼續查詢上一次的工作」取回結果")
    }

    private func startJob(client: KaggleClient, jobId: String, params: RenderParams) async throws {
        let script = try KaggleScripts.jobScript(jobId: jobId, params: params)
        phase = .working("啟動 Kaggle 運算…", "")
        try await withRetry("啟動運算") {
            try await client.pushKernel(slug: KaggleNames.jobKernel, title: "lam head job", script: script,
                                        datasetSources: [KaggleNames.inputDataset],
                                        kernelSources: [KaggleNames.envKernel],
                                        machineShape: KaggleNames.machineShape)
        }
    }

    private func waitAndFetch(client: KaggleClient, jobId: String, params: RenderParams, timeout: TimeInterval) async throws {
        var restarts = 0
        while true {
            let (files, meta) = try await client.waitForOutput(
                kernel: KaggleNames.jobKernel, file: "result_meta.json", maxWait: timeout,
                isMine: { ($0["jobId"] as? String) == jobId && ($0["status"] as? String) != "running" },
                onStatus: { [weak self] text, elapsed in
                    self?.phase = .working(text, "已等待 \(Int(elapsed / 60)) 分鐘（通常 5–15 分鐘）。可以先離開 App，回來後按「繼續查詢」")
                })
            if (meta["status"] as? String) == "ok" {
                phase = .working("下載影格…", "")
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent(jobId)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for name in ["manifest.json", "bundle.bin"] {
                    guard let f = files.first(where: { ($0.name as NSString).lastPathComponent == name }) else {
                        throw KaggleError(message: "Kaggle 輸出裡找不到 \(name)")
                    }
                    try await withRetry("下載 \(name)") { try await client.download(f.url, to: dir.appendingPathComponent(name)) }
                }
                let manifestData = try Data(contentsOf: dir.appendingPathComponent("manifest.json"))
                let bundle = try Data(contentsOf: dir.appendingPathComponent("bundle.bin"))
                try? FileManager.default.removeItem(at: dir)
                let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
                let frames = try await Task.detached(priority: .userInitiated) {
                    try FrameSet(manifest: manifest, bundle: bundle)
                }.value
                setPending(nil)
                phase = .ready(frames)
                return
            }
            let code = meta["error"] as? String ?? ""
            if code == "stale_input" && restarts < 3 {
                restarts += 1
                phase = .working("Kaggle 資料集還沒更新，1 分鐘後重新啟動…", "")
                try await Task.sleep(nanoseconds: 60_000_000_000)
                try await startJob(client: client, jobId: jobId, params: params)
                continue
            }
            setPending(nil)
            throw KaggleError(message: "生成失敗：\(meta["message"] as? String ?? code)")
        }
    }
}

extension UIImage {
    /// 依方向轉正並縮到最長邊 maxSide，輸出 JPEG
    func resizedJPEG(maxSide: Double, quality: CGFloat) -> Data? {
        let longest = max(size.width, size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, CGFloat(maxSide) / longest)
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let img = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
        return img.jpegData(compressionQuality: quality)
    }
}
