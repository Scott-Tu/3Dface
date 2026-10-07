import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var env: KaggleEnvModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("kaggleUsername") private var username = ""
    @State private var apiKey = Keychain.get("kaggleKey") ?? ""
    @State private var testMessage: String?
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                envSection
                angleSection
                outputSection
                poseSection
                viewerSection
                networkSection
                Section {
                    Button("全部重設為預設值", role: .destructive) {
                        settings.render = RenderParams()
                        settings.client = ClientParams()
                    }
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    // MARK: Kaggle 帳號與環境

    private var accountSection: some View {
        Section {
            TextField("使用者名稱", text: $username)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("API 金鑰", text: $apiKey)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .onChange(of: apiKey) { _, newValue in
                    Keychain.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), for: "kaggleKey")
                    KaggleClient.resetAuthMode()
                }
            Button(testing ? "測試中…" : "測試 Kaggle 連線") { Task { await test() } }
                .disabled(testing)
            if let m = testMessage { Text(m).font(.footnote).foregroundStyle(.secondary) }
        } header: {
            Text("Kaggle 帳號")
        } footer: {
            Text("使用者名稱是 kaggle.com/ 後面那段（全小寫）。金鑰在 kaggle.com/settings → API 產生（KGAT_ 開頭的 Token，或 kaggle.json 裡的 key），只存在這支 iPhone 的鑰匙圈。帳號需完成手機驗證才能用 GPU。")
        }
    }

    private var envSection: some View {
        Section {
            Text(env.status).font(.callout)
            HStack {
                Button(env.ready ? "重新建立環境" : "建立 Kaggle 環境") { env.build() }
                Spacer()
                Button(env.busy ? "停止等待" : "查詢狀態") { env.busy ? env.stop() : env.refresh() }
            }
            .buttonStyle(.borderless)
            .disabled(username.isEmpty || apiKey.isEmpty)
        } header: {
            Text("Kaggle 環境（只需建立一次）")
        } footer: {
            Text("會在 Kaggle 上安裝套件、編譯並下載模型（約 40–60 分鐘，中途可以離開 App）。建好之後，每次生成只會用 5–15 分鐘的 GPU 額度，跑完 Kaggle 就自動關閉。")
        }
    }

    private func test() async {
        testing = true; defer { testing = false }
        let u = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let k = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty, !k.isEmpty else { testMessage = "請先填寫使用者名稱和 API 金鑰"; return }
        var lines: [String] = []
        if u != u.lowercased() || u.contains(" ") { lines.append("⚠️ 使用者名稱應該全部小寫、沒有空白（kaggle.com/ 後面那段）") }
        KaggleClient.resetAuthMode()
        let client = KaggleClient(username: u, key: k)
        do {
            let r = try await client.call("datasets.DatasetApiService", "UploadDatasetFile", [
                "fileName": "lamhead_test.txt", "contentLength": 1,
                "lastModifiedEpochSeconds": Int(Date().timeIntervalSince1970)])
            lines.append((r["createUrl"] as? String) != nil ? "✅ 金鑰有效，可以上傳" : "⚠️ Kaggle 沒有回傳上傳網址")
        } catch {
            lines.append("❌ \(String(error.localizedDescription.prefix(200)))")
        }
        testMessage = lines.joined(separator: "\n")
        if lines.last?.hasPrefix("✅") == true { env.refresh() }
    }

    // MARK: 生成參數

    private var angleSection: some View {
        Section {
            numberRow("左右 最小", value: $settings.render.yawMin, unit: "°")
            numberRow("左右 最大", value: $settings.render.yawMax, unit: "°")
            numberRow("左右 步距", value: $settings.render.yawStep, unit: "°")
            numberRow("上下 最小", value: $settings.render.pitchMin, unit: "°")
            numberRow("上下 最大", value: $settings.render.pitchMax, unit: "°")
            numberRow("上下 步距", value: $settings.render.pitchStep, unit: "°")
            LabeledContent("視角數", value: "\(settings.render.viewCount)")
            if let e = settings.render.validationError { Text(e).foregroundStyle(.red).font(.footnote) }
        } header: {
            Text("旋轉角度範圍")
        } footer: {
            Text("步距越小轉動越細緻，但生成時間與下載量會增加。左右 ±60°、上下 ±30° 以內，總視角數上限 400。")
        }
    }

    private var outputSection: some View {
        Section("輸出畫質") {
            Picker("影格尺寸", selection: $settings.render.outSize) {
                ForEach([256, 384, 512, 768], id: \.self) { Text("\($0) px").tag($0) }
            }
            VStack(alignment: .leading) {
                Text("JPEG 品質：\(settings.render.jpegQuality)")
                Slider(value: Binding(get: { Double(settings.render.jpegQuality) },
                                      set: { settings.render.jpegQuality = Int($0) }),
                       in: 50...100, step: 5)
            }
            ColorPicker("背景顏色", selection: Binding(get: { Color(hex: settings.render.bgColor) },
                                                    set: { settings.render.bgColor = $0.hexString }),
                        supportsOpacity: false)
            LabeledContent("預估下載量", value: String(format: "%.1f MB", settings.render.estimatedMB))
        }
    }

    private var poseSection: some View {
        Section {
            Picker("表情", selection: $settings.render.expression) {
                Text("無表情").tag("neutral")
                Text("使用 motion 影格").tag("motion")
            }
            Picker("基準姿態", selection: $settings.render.baseRotation) {
                Text("motion 影格").tag("motion")
                Text("正面").tag("frontal")
            }
            if settings.motions.isEmpty {
                TextField("motion 名稱（空白＝第一個）", text: $settings.render.motionName)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } else {
                Picker("motion", selection: $settings.render.motionName) {
                    Text("預設（第一個）").tag("")
                    ForEach(settings.motions, id: \.self) { Text($0).tag($0) }
                }
            }
            Stepper("motion 影格：\(settings.render.motionFrame)", value: $settings.render.motionFrame, in: 0...1000)
            Toggle("生成時反轉左右", isOn: Binding(get: { settings.render.yawSign == -1 },
                                              set: { settings.render.yawSign = $0 ? -1 : 1 }))
            Toggle("生成時反轉上下", isOn: Binding(get: { settings.render.pitchSign == -1 },
                                              set: { settings.render.pitchSign = $0 ? -1 : 1 }))
        } header: {
            Text("表情與姿態")
        } footer: {
            Text("motion 提供相機位置與基準頭部姿態。若生成結果往左轉時頭像卻往右轉，開啟「生成時反轉」後重新生成。")
        }
    }

    // MARK: 檢視參數（即時生效，不用重新生成）

    private var viewerSection: some View {
        Section {
            Picker("操作方式", selection: $settings.client.inputMode) {
                ForEach(ClientParams.InputMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            sliderRow("陀螺儀靈敏度", value: $settings.client.gyroSensitivity, range: 0.5...4, format: "%.1f×")
            sliderRow("拖曳靈敏度", value: $settings.client.dragSensitivity, range: 0.05...1, format: "%.2f°/pt")
            sliderRow("平滑程度", value: $settings.client.smoothing, range: 0...0.95, format: "%.2f")
            Toggle("影格交叉淡化", isOn: $settings.client.crossfade)
            Toggle("反轉左右", isOn: $settings.client.invertYaw)
            Toggle("反轉上下", isOn: $settings.client.invertPitch)
        } header: {
            Text("檢視（即時生效）")
        } footer: {
            Text("在檢視畫面雙擊可回正。")
        }
    }

    private var networkSection: some View {
        Section {
            Picker("上傳縮圖最長邊", selection: $settings.client.uploadMaxSide) {
                ForEach([768.0, 1024, 1536, 2048], id: \.self) { Text("\(Int($0)) px").tag($0) }
            }
            sliderRow("等待上限", value: $settings.client.timeoutMinutes, range: 15...180, format: "%.0f 分鐘")
        } header: {
            Text("上傳與等待")
        } footer: {
            Text("等待上限包含 Kaggle 排隊時間。")
        }
    }

    // MARK: 小元件

    private func numberRow(_ title: String, value: Binding<Double>, unit: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(title, value: value, format: .number)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }

    private func sliderRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, format: String) -> some View {
        VStack(alignment: .leading) {
            Text("\(title)：\(String(format: format, value.wrappedValue))")
            Slider(value: value, in: range)
        }
    }
}
