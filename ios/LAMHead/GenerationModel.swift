import UIKit

/// 上傳 → 輪詢 → 下載 的流程狀態
@MainActor
final class GenerationModel: ObservableObject {
    enum Phase {
        case idle
        case uploading
        case processing(JobStatus)
        case downloading
        case ready(FrameSet)
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var inputImage: UIImage?
    private var task: Task<Void, Never>?

    var isBusy: Bool {
        switch phase {
        case .uploading, .processing, .downloading: return true
        default: return false
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    func generate(settings: SettingsStore) {
        guard let image = inputImage else { return }
        if let err = settings.render.validationError { phase = .failed(err); return }
        let render = settings.render
        let client = settings.client
        let api: APIClient
        do { api = try settings.makeClient() } catch {
            phase = .failed(error.localizedDescription); return
        }

        task?.cancel()
        task = Task {
            do {
                phase = .uploading
                guard let jpeg = image.resizedJPEG(maxSide: client.uploadMaxSide, quality: 0.9) else {
                    throw APIError.invalidData
                }
                var status = try await api.submit(jpeg: jpeg, params: render)
                phase = .processing(status)

                let deadline = Date().addingTimeInterval(client.timeoutMinutes * 60)
                while status.status != "done" {
                    if status.status == "error" { throw GenError(status.error ?? "生成失敗") }
                    if Date() > deadline { throw APIError.timeout }
                    try await Task.sleep(for: .seconds(max(0.5, client.pollInterval)))
                    status = try await api.status(status.jobId)
                    phase = .processing(status)
                }

                phase = .downloading
                async let m = api.manifest(status.jobId)
                async let b = api.bundle(status.jobId)
                let (manifest, bundle) = try await (m, b)
                let frames = try await Task.detached(priority: .userInitiated) {
                    try FrameSet(manifest: manifest, bundle: bundle)
                }.value
                phase = .ready(frames)
            } catch is CancellationError {
                // 使用者取消
            } catch let e as URLError where e.code == .cancelled {
                // 使用者取消
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

struct GenError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
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
