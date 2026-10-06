import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var testMessage: String?
    @State private var testing = false

    var body: some View {
        NavigationStack {
            Form {
                serverSection
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

    // MARK: 伺服器

    private var serverSection: some View {
        Section {
            TextField("https://xxxx.trycloudflare.com", text: $settings.serverURL)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("API Key", text: $settings.apiKey)
            HStack {
                Button("測試連線") { Task { await test() } }
                Spacer()
                Button("載入伺服器預設參數") { Task { await loadDefaults() } }
            }
            .disabled(testing)
            if let m = testMessage { Text(m).font(.footnote).foregroundStyle(.secondary) }
        } header: {
            Text("Kaggle 伺服器")
        } footer: {
            Text("每次重開 Kaggle 網址都會改變；用 iPhone 相機掃描 notebook 的 QR Code 可自動更新。")
        }
    }

    private func test() async {
        testing = true; defer { testing = false }
        do {
            let h = try await settings.makeClient().health()
            if let e = h.loadError { testMessage = "❌ 模型載入失敗：\(e)" }
            else { testMessage = h.modelLoaded ? "✅ 連線成功（\(h.gpu ?? "GPU")），模型已就緒" : "⏳ 連線成功，模型載入中" }
            _ = try await settings.makeClient().defaults()   // 順便驗證 API Key
        } catch {
            testMessage = "❌ \(error.localizedDescription)"
        }
    }

    private func loadDefaults() async {
        testing = true; defer { testing = false }
        do {
            let d = try await settings.makeClient().defaults()
            settings.render = d.params
            settings.motions = d.motions
            testMessage = "✅ 已載入伺服器預設參數（\(d.motions.count) 個 motion）"
        } catch {
            testMessage = "❌ \(error.localizedDescription)"
        }
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
            Toggle("伺服器端反轉左右", isOn: Binding(get: { settings.render.yawSign == -1 },
                                              set: { settings.render.yawSign = $0 ? -1 : 1 }))
            Toggle("伺服器端反轉上下", isOn: Binding(get: { settings.render.pitchSign == -1 },
                                              set: { settings.render.pitchSign = $0 ? -1 : 1 }))
        } header: {
            Text("表情與姿態")
        } footer: {
            Text("motion 提供相機位置與基準頭部姿態。若生成結果往左轉時頭像卻往右轉，開啟「伺服器端反轉」後重新生成。")
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
        Section("上傳與等待") {
            Picker("上傳縮圖最長邊", selection: $settings.client.uploadMaxSide) {
                ForEach([768.0, 1024, 1536, 2048], id: \.self) { Text("\(Int($0)) px").tag($0) }
            }
            sliderRow("輪詢間隔", value: $settings.client.pollInterval, range: 0.5...5, format: "%.1f 秒")
            sliderRow("逾時", value: $settings.client.timeoutMinutes, range: 2...30, format: "%.0f 分鐘")
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
