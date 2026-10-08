# LAM 3D 頭像：iPhone 拍照 → Kaggle 生成 → iPhone 旋轉檢視

```
iPhone App ──照片＋參數──▶ 你的 Kaggle 帳號（Kaggle API，GPU T4）
    ▲                          │ 1. 解壓預先建好的環境（lam-env-build 的輸出）
    │                          │ 2. FLAME 臉部追蹤 → LAM 生成 Gaussian 頭像
    └── 下載多角度影格 ◀────────┘ 3. 依角度網格批次渲染，跑完自動關機
App 依陀螺儀／拖曳即時切換影格（含交叉淡化），手機端不需要 GPU。
```

只用手機就能操作：不必開電腦、不必打開 Kaggle 網頁，也不會一直佔用 GPU 額度。

## 檔案

| 路徑 | 說明 |
|---|---|
| `kaggle/lam_env_build.py` | 環境建置（只跑一次）：安裝、編譯、下載權重、打包。App 會自動送到 Kaggle |
| `kaggle/lam_job.py` | 每次生成時 App 送到 Kaggle 執行的程式 |
| `kaggle/lam_server.py` | 生成程式本體（`--once` 單次模式；也可當常駐伺服器自架） |
| `kaggle/lam_server_kaggle.ipynb`、`kaggle/KAGGLE_SETUP.md` | 舊的手動 notebook 伺服器模式（可不使用） |
| `ios/LAMHead/*.swift` | iPhone App 原始碼（SwiftUI，iOS 17+） |
| `ios/project.yml` | XcodeGen 專案設定（自動產生 Xcode 專案） |
| `.github/workflows/build-ipa.yml` | GitHub Actions 雲端編譯 IPA |

## 一、Kaggle 帳號（一次就好，都在手機上做得到）

1. 到 kaggle.com 註冊並登入，右上頭像 → **Settings** → 完成 **Phone verification**（沒驗證就不能用 GPU）。
2. 在 kaggle.com/settings 的 **API** 區塊按 **Generate New Token**，複製金鑰（`KGAT_` 開頭；舊版 `kaggle.json` 裡的 key 也可以）。
3. 記下使用者名稱（個人頁網址 `kaggle.com/你的名稱`）。

App 會在你的帳號下建立三個私人項目：程式 `lam-env-build`（環境）、程式 `lam-head-job`（每次生成）、資料集 `lam-head-input`（上傳的照片）。

## 二、iPhone 端（不需要 Mac：GitHub 雲端編譯 + Windows 安裝）

### 1. GitHub 雲端編譯 IPA
1. 在 github.com 建立新的 repository（Public 的 Actions 免費；Private 每月有免費額度，但 macOS 分鐘數以 10 倍計算）。
2. 點 **uploading an existing file**，把解壓後 `lam-iphone` 資料夾**裡面的內容**（`README.md`、`kaggle`、`ios`）拖進去，按 Commit。
3. **檢查 `.github` 資料夾有沒有上傳成功**（隱藏資料夾在網頁上傳時常被略過）。若沒有：Add file → Create new file，檔名輸入
   `.github/workflows/build-ipa.yml`，把同名檔案的內容貼上後 Commit。
4. 到 **Actions** 分頁 → 左側 **Build IPA** → **Run workflow**。
5. 約 5–10 分鐘後，點進完成的執行紀錄，在頁面下方 **Artifacts** 下載 `LAMHead-ipa`（是 zip，解壓得到 `LAMHead.ipa`）。
6. 若編譯失敗，把 Actions 的錯誤訊息貼給我修正。

### 2. Windows 用 Sideloadly 安裝
1. 安裝 **iTunes**（建議用 Apple 官網版，不要用 Microsoft Store 版）與 **Sideloadly**。
2. USB 連接 iPhone，iPhone 上點「信任這部電腦」。
3. 把 `LAMHead.ipa` 拖進 Sideloadly，輸入 Apple ID，按 Start（建議用一個副帳號 Apple ID）。

### 3. iPhone 設定
1. 設定 → 隱私權與安全性 → **開發者模式** → 開啟並重開機（安裝過一次側載 App 後才會出現這個選項）。
2. 設定 → 一般 → **VPN 與裝置管理** → 點你的 Apple ID → 信任。
3. 免費 Apple ID 安裝的 App **7 天後失效**，重新用 Sideloadly 安裝即可（不用重新編譯）。

### 4. 第一次設定 App
1. 右上角設定 → 填 Kaggle **使用者名稱**與 **API 金鑰** → 按「測試 Kaggle 連線」。
2. 按「**建立 Kaggle 環境**」：在 Kaggle 上安裝套件、編譯、下載模型，約 40–60 分鐘，**只需要做一次**。中途可以離開 App，回來按「查詢狀態」。
3. 環境顯示「✅ 環境已建立」後，就可以拍照 →「生成 3D 頭像」。每次約 5–15 分鐘（含排隊），等待時可以離開 App，回來按「繼續查詢上一次的工作」。

### （有 Mac 的話）用 Xcode 直接安裝
`brew install xcodegen` → 在 `ios/` 執行 `xcodegen generate` → 開啟 `LAMHead.xcodeproj` → Signing 選你的 Apple ID → 接上 iPhone 按 ▶。

## 三、可調整參數

**生成參數**（App 設定頁，每次生成時送出）

| 參數 | 預設 | 範圍／選項 | 說明 |
|---|---|---|---|
| `yaw_min` / `yaw_max` | −30 / 30 | ±60° | 左右角度範圍 |
| `yaw_step` | 2.5 | ≥ 0.5° | 左右步距，越小越細緻 |
| `pitch_min` / `pitch_max` | −10 / 10 | ±30° | 上下角度範圍 |
| `pitch_step` | 5 | ≥ 0.5° | 上下步距 |
| `out_size` | 384 | 128–1024 | 影格邊長（模型原生 512） |
| `jpeg_quality` | 85 | 40–100 | |
| `bg_color` | #FFFFFF | | 背景色 |
| `expression` | neutral | neutral／motion | 無表情或用 motion 影格的表情 |
| `motion_name` / `motion_frame` | 第一個 / 0 | | 提供相機與基準姿態 |
| `base_rotation` | motion | motion／frontal | 旋轉的基準姿態 |
| `yaw_sign` / `pitch_sign` | 1 | 1／−1 | 方向相反時改 −1 |
| `chunk_size` | 64 | 4–256 | 每批渲染視角數，記憶體不足就調小（僅伺服器端） |
| `max_views` | 400 | | 視角總數上限（僅伺服器端） |

**檢視參數**（只在 App 內，即時生效）：操作方式（陀螺儀／拖曳／兩者）、陀螺儀與拖曳靈敏度、平滑程度、交叉淡化、反轉方向、上傳縮圖尺寸、等待上限。

預設 25 × 5 = 125 個視角、384 px，下載約 2–4 MB。

## 四、注意事項

- 頭部旋轉是以 FLAME 模型原點為軸心轉動頭部（類似真人轉頭），相機固定。
- Kaggle 免費 GPU 每週約 30 小時，每次生成只在執行期間計算額度；本架構僅適合個人測試，正式服務請改用付費 GPU 主機（`lam_server.py` 可直接沿用）。
- 授權：LAM 程式碼為 Apache-2.0，**模型權重為 CC BY-NC 4.0（非商業）**，且依賴 FLAME 模型（另有授權條款）。
- 請只上傳你有權使用的照片。
- iOS 程式碼尚未實際編譯驗證；GitHub Actions 若編譯失敗，把錯誤訊息貼給我即可修正。
