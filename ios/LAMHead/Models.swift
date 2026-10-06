import Foundation

/// 送到伺服器的生成參數（欄位名稱對應伺服器的 snake_case）
struct RenderParams: Codable, Equatable {
    var yawMin: Double = -30
    var yawMax: Double = 30
    var yawStep: Double = 2.5
    var pitchMin: Double = -10
    var pitchMax: Double = 10
    var pitchStep: Double = 5
    var outSize: Int = 384
    var jpegQuality: Int = 85
    var bgColor: String = "#FFFFFF"
    var expression: String = "neutral"      // neutral | motion
    var motionName: String = ""
    var motionFrame: Int = 0
    var baseRotation: String = "motion"     // motion | frontal
    var yawSign: Int = 1
    var pitchSign: Int = 1

    enum CodingKeys: String, CodingKey {
        case yawMin = "yaw_min", yawMax = "yaw_max", yawStep = "yaw_step"
        case pitchMin = "pitch_min", pitchMax = "pitch_max", pitchStep = "pitch_step"
        case outSize = "out_size", jpegQuality = "jpeg_quality", bgColor = "bg_color"
        case expression, motionName = "motion_name", motionFrame = "motion_frame"
        case baseRotation = "base_rotation", yawSign = "yaw_sign", pitchSign = "pitch_sign"
    }

    /// 與伺服器相同的角度網格計算
    static func angles(_ lo: Double, _ hi: Double, _ step: Double) -> [Double] {
        guard hi - lo > 1e-6, step > 0 else { return [lo] }
        let n = Int(floor((hi - lo) / step + 1e-6))
        var v = (0...n).map { lo + Double($0) * step }
        if hi - (v.last ?? lo) > 1e-6 { v.append(hi) }
        return v
    }

    var viewCount: Int {
        Self.angles(yawMin, yawMax, yawStep).count * Self.angles(pitchMin, pitchMax, pitchStep).count
    }

    /// 粗估下載量（MB）
    var estimatedMB: Double {
        let bytesPerPixel = 0.08 + Double(jpegQuality - 40) / 60.0 * 0.25
        return Double(viewCount) * Double(outSize * outSize) * bytesPerPixel / 1_048_576
    }

    /// 本地檢查，避免送出明顯錯誤的參數
    var validationError: String? {
        if yawMin > yawMax { return "左右角度：最小值不可大於最大值" }
        if pitchMin > pitchMax { return "上下角度：最小值不可大於最大值" }
        if yawStep < 0.5 || pitchStep < 0.5 { return "步距至少 0.5°" }
        if !(-60...60).contains(yawMin) || !(-60...60).contains(yawMax) { return "左右角度需在 ±60° 內" }
        if !(-30...30).contains(pitchMin) || !(-30...30).contains(pitchMax) { return "上下角度需在 ±30° 內" }
        if viewCount > 400 { return "視角數 \(viewCount) 超過伺服器上限 400，請加大步距" }
        return nil
    }
}

/// App 端（檢視與連線）參數
struct ClientParams: Codable, Equatable {
    enum InputMode: String, Codable, CaseIterable, Identifiable {
        case gyro, drag, both
        var id: String { rawValue }
        var label: String {
            switch self {
            case .gyro: return "陀螺儀"
            case .drag: return "手指拖曳"
            case .both: return "兩者"
            }
        }
    }
    var inputMode: InputMode = .both
    var gyroSensitivity: Double = 1.5      // 手機傾斜 1° → 頭像轉幾度
    var dragSensitivity: Double = 0.25     // 拖曳 1 pt → 頭像轉幾度
    var smoothing: Double = 0.8            // 0＝不平滑，越大越平滑但越遲鈍
    var invertYaw = false
    var invertPitch = false
    var crossfade = true                   // 相鄰影格交叉淡化，看起來更連續
    var uploadMaxSide: Double = 1024       // 上傳前縮圖的最長邊
    var pollInterval: Double = 1.5         // 秒
    var timeoutMinutes: Double = 10
}

struct HealthResponse: Codable {
    let status: String
    let modelLoaded: Bool
    let loadError: String?
    let gpu: String?
    enum CodingKeys: String, CodingKey {
        case status, modelLoaded = "model_loaded", loadError = "load_error", gpu
    }
}

struct DefaultsResponse: Codable {
    let params: RenderParams
    let motions: [String]
}

struct JobStatus: Codable {
    let jobId: String
    let status: String          // queued | running | done | error
    let stage: String
    let progress: Double
    let error: String?
    let queuePosition: Int?
    let views: Int
    let elapsed: Double
    enum CodingKeys: String, CodingKey {
        case jobId = "job_id", status, stage, progress, error
        case queuePosition = "queue_position", views, elapsed
    }
}

struct FrameInfo: Codable {
    let yaw: Double
    let pitch: Double
    let offset: Int
    let length: Int
}

struct Manifest: Codable {
    let jobId: String
    let yaws: [Double]
    let pitches: [Double]
    let width: Int
    let height: Int
    let frames: [FrameInfo]
    let seconds: Double?
    enum CodingKeys: String, CodingKey {
        case jobId = "job_id", yaws, pitches, width, height, frames, seconds
    }
}
