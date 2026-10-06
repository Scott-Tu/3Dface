import SwiftUI

/// 顯示多角度影格，依陀螺儀／拖曳切換
struct ViewerView: View {
    let frames: FrameSet
    @EnvironmentObject var settings: SettingsStore
    @StateObject private var controller = ViewerController()
    @State private var dragging = false

    var body: some View {
        let s = frames.sample(yaw: controller.yaw, pitch: controller.pitch)
        VStack(spacing: 12) {
            ZStack {
                if settings.client.crossfade {
                    Image(uiImage: s.a).resizable().scaledToFit()
                    Image(uiImage: s.b).resizable().scaledToFit().opacity(s.weight)
                } else {
                    Image(uiImage: s.weight < 0.5 ? s.a : s.b).resizable().scaledToFit()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { v in
                        controller.dragChanged(v.translation, isStart: !dragging)
                        dragging = true
                    }
                    .onEnded { _ in dragging = false }
            )
            .onTapGesture(count: 2) { controller.reset() }

            Text(String(format: "左右 %+.1f°　上下 %+.1f°", controller.yaw, controller.pitch))
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)

            HStack {
                Button("以目前姿勢為正面", systemImage: "scope") { controller.recalibrate() }
                Spacer()
                Button("回正", systemImage: "arrow.counterclockwise") { controller.reset() }
            }
            .font(.footnote)

            if !controller.gyroAvailable && settings.client.inputMode != .drag {
                Text("此裝置無法使用陀螺儀，請改用拖曳").font(.footnote).foregroundStyle(.orange)
            }
            if let sec = frames.manifest.seconds {
                Text("伺服器生成 \(frames.manifest.frames.count) 個視角，耗時 \(String(format: "%.1f", sec)) 秒")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .onAppear {
            controller.params = settings.client
            controller.yawRange = frames.yawRange
            controller.pitchRange = frames.pitchRange
            controller.start()
        }
        .onDisappear { controller.stop() }
        .onChange(of: settings.client) { _, newValue in controller.params = newValue }
    }
}
