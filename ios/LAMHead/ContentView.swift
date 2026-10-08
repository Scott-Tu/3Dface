import SwiftUI
import PhotosUI

struct ContentView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var env: KaggleEnvModel
    @AppStorage("kaggleUsername") private var kaggleUsername = ""
    @StateObject private var gen = GenerationModel()
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if kaggleUsername.isEmpty {
                        notice("請先到右上角設定填入 Kaggle 使用者名稱與 API 金鑰")
                    } else if !env.ready {
                        notice("第一次使用前，請到右上角設定按「建立 Kaggle 環境」（只需要做一次）")
                    }
                    if let id = gen.pendingJobId, !gen.isBusy {
                        Button { gen.resume(settings: settings) } label: {
                            Label("繼續查詢上一次的工作（\(id.prefix(6))）", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                    resultArea
                    inputArea
                }
                .padding()
            }
            .navigationTitle("3D 頭像")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker(onPick: { gen.inputImage = $0 }, onDismiss: { showCamera = false })
                    .ignoresSafeArea()
            }
            .onChange(of: photoItem) { _, item in
                Task {
                    if let data = try? await item?.loadTransferable(type: Data.self),
                       let img = UIImage(data: data) {
                        gen.inputImage = img
                    }
                }
            }
        }
    }

    // MARK: 結果區

    @ViewBuilder private var resultArea: some View {
        switch gen.phase {
        case .idle:
            EmptyView()
        case .working(let title, let detail):
            progressCard(title, detail: detail)
        case .ready(let frames):
            ViewerView(frames: frames).id(frames.manifest.jobId)
        case .failed(let msg):
            Label(msg, systemImage: "xmark.octagon")
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func notice(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.footnote).foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func progressCard(_ text: String, detail: String) -> some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(text).font(.callout).multilineTextAlignment(.center)
            if !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            Button("停止等待", role: .cancel) { gen.cancel() }.font(.footnote)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: 輸入區

    private var inputArea: some View {
        VStack(spacing: 12) {
            if let img = gen.inputImage {
                Image(uiImage: img)
                    .resizable().scaledToFit()
                    .frame(maxHeight: isReady ? 120 : 260)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            HStack {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("相簿", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.bordered)
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button { showCamera = true } label: { Label("拍照", systemImage: "camera") }
                        .buttonStyle(.bordered)
                }
            }
            .disabled(gen.isBusy)

            Button {
                gen.generate(settings: settings)
            } label: {
                Label(isReady ? "用目前參數重新生成" : "生成 3D 頭像", systemImage: "cube.transparent")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(gen.inputImage == nil || gen.isBusy || kaggleUsername.isEmpty)

            Text("將生成 \(settings.render.viewCount) 個視角，約 \(String(format: "%.1f", settings.render.estimatedMB)) MB；每次約用 5–15 分鐘 Kaggle GPU 額度")
                .font(.caption).foregroundStyle(.secondary)
            if let err = settings.render.validationError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var isReady: Bool {
        if case .ready = gen.phase { return true }
        return false
    }
}
