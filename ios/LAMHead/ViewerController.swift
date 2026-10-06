import Foundation
import CoreMotion
import CoreGraphics

/// 把陀螺儀與拖曳輸入轉成頭像角度（含平滑與範圍限制）
@MainActor
final class ViewerController: ObservableObject {
    @Published private(set) var yaw: Double = 0
    @Published private(set) var pitch: Double = 0

    var params = ClientParams()
    var yawRange: ClosedRange<Double> = -30...30
    var pitchRange: ClosedRange<Double> = -10...10

    private let motion = CMMotionManager()
    private var reference: CMAttitude?
    private var gyroYaw = 0.0, gyroPitch = 0.0
    private var dragYaw = 0.0, dragPitch = 0.0
    private var dragStartYaw = 0.0, dragStartPitch = 0.0
    private var timer: Timer?

    var gyroAvailable: Bool { motion.isDeviceMotionAvailable }

    func start() {
        if motion.isDeviceMotionAvailable && !motion.isDeviceMotionActive {
            motion.deviceMotionUpdateInterval = 1.0 / 60.0
            motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] data, _ in
                guard let data else { return }
                MainActor.assumeIsolated { self?.handle(data.attitude) }
            }
        }
        if timer == nil {
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(t, forMode: .common)   // 拖曳時也持續更新
            timer = t
        }
    }

    private func handle(_ att: CMAttitude) {
        if reference == nil { reference = att.copy() as? CMAttitude }
        if let ref = reference { att.multiply(byInverseOf: ref) }
        // 直拿手機：左右傾斜＝roll，前後傾斜＝pitch
        gyroYaw = att.roll * 180 / .pi
        gyroPitch = att.pitch * 180 / .pi
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
        timer?.invalidate()
        timer = nil
    }

    /// 以目前手機姿勢作為「正面」
    func recalibrate() {
        reference = nil
        gyroYaw = 0; gyroPitch = 0
    }

    /// 回到正面
    func reset() {
        recalibrate()
        dragYaw = 0; dragPitch = 0
    }

    func dragChanged(_ translation: CGSize, isStart: Bool) {
        guard params.inputMode != .gyro else { return }
        if isStart { dragStartYaw = dragYaw; dragStartPitch = dragPitch }
        let k = params.dragSensitivity
        dragYaw = dragStartYaw + Double(translation.width) * k
        dragPitch = dragStartPitch - Double(translation.height) * k
        // 拖曳累積值也限制在範圍內，避免拖過頭後要拖很久才回來
        dragYaw = clamp(dragYaw, yawRange)
        dragPitch = clamp(dragPitch, pitchRange)
    }

    private func tick() {
        var ty = 0.0, tp = 0.0
        if params.inputMode != .drag {
            ty += gyroYaw * params.gyroSensitivity
            tp += gyroPitch * params.gyroSensitivity
        }
        if params.inputMode != .gyro {
            ty += dragYaw
            tp += dragPitch
        }
        if params.invertYaw { ty = -ty }
        if params.invertPitch { tp = -tp }
        ty = clamp(ty, yawRange)
        tp = clamp(tp, pitchRange)

        let a = 1 - min(max(params.smoothing, 0), 0.97)
        let ny = yaw + (ty - yaw) * a
        let np = pitch + (tp - pitch) * a
        if abs(ny - yaw) > 0.01 || abs(np - pitch) > 0.01 {
            yaw = ny
            pitch = np
        }
    }

    private func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double {
        min(max(v, r.lowerBound), r.upperBound)
    }
}
