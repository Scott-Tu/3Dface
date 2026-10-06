import SwiftUI
import PhotosUI

struct ContentView: View {
    @EnvironmentObject var settings: SettingsStore
    @StateObject private var gen = GenerationModel()
    @State private var photoItem: PhotosPickerItem?
    @State private var showCamera = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if settings.serverURL.isEmpty {
                        Label("請先在設定填入 Kaggle 伺服器網址，或用 iPhone 相機掃描 notebook 顯示的 QR Code",
                              systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
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
        case .uploading:
            progressCard("上傳照片中…", progress: nil)
        case .processing(let s):
            progressCard(s.status == "queued"
                         ? "\(s.stage)\(s.queuePosition.map { "（前面還有 \($0) 個）" } ?? "")"
                         : "\(s.stage)（\(s.views) 個視角，已 \(Int(s.elapsed)) 秒）",
                         progress: s.progress)
        case .downloading:
            progressCard("下載影格中…", progress: nil)
        case .ready(let frames):
            ViewerView(frames: frames).id(frames.manifest.jobId)
        case .failed(let msg):
            Label(msg, systemImage: "xmark.octagon")
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func progressCard(_ text: String, progress: Double?) -> some View {
        VStack(spacing: 10) {
            if let p = progress { ProgressView(value: p) } else { ProgressView() }
            Text(text).font(.callout).multilineTextAlignment(.center)
            Button("取消", role: .cancel) { gen.cancel() }.font(.footnote)
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
            .disabled(gen.inputImage == nil || gen.isBusy || settings.serverURL.isEmpty)

            Text("將生成 \(settings.render.viewCount) 個視角，約 \(String(format: "%.1f", settings.render.estimatedMB)) MB")
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
