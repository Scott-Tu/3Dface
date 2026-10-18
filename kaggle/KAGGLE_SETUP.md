# Kaggle 端設定步驟（從零開始）

> 這個專案的 Kaggle 部分**完全在 Kaggle 網頁上執行**，不需要 `kaggle.json` API 金鑰，也不用在電腦上安裝 Kaggle CLI。
> 需要的只有：Kaggle 帳號（已完成手機驗證）＋ `kaggle/lam_server_kaggle.ipynb` 這個檔案。

## 0. 帳號準備（只做一次）
1. 到 kaggle.com 註冊／登入。
2. 右上頭像 → **Settings** → **Phone Verification** 完成手機驗證。沒驗證就不能開 Internet 與 GPU。

## 1. 匯入 notebook
1. 左側 **Create → New Notebook**。
2. 上方選單 **File → Import Notebook**，選電腦上的 `kaggle/lam_server_kaggle.ipynb`。

## 2. 右側面板 Settings（最常漏掉）
| 項目 | 設定 |
|---|---|
| Accelerator | **GPU T4 x2**（不要選 P100 或 TPU） |
| Internet | **On**（要下載 LAM 程式、權重、Cloudflare Tunnel） |
| Persistence | 不需要 |

右側面板沒出現時，點 notebook 右上角的「>|」展開。

## 3. 固定 API 金鑰（建議）
1. 上方 **Add-ons → Secrets → Add a new secret**。
2. Label 填 `LAM_API_KEY`，Value 填一組自己的密碼（英數即可）。
3. 勾選旁邊的方框，讓這個 notebook 可以讀取它。

不設也能跑：每次會隨機產生金鑰，重新掃 QR Code 即可。

## 4. 依序執行儲存格
| 格 | 作用 | 第一次大約時間 |
|---|---|---|
| 1 | 設定、檢查 GPU（應看到 `Tesla T4`） | 幾秒 |
| 2 | 建立 Python 3.10 獨立環境 | 1 分鐘 |
| 3 | 下載 LAM、安裝套件、**編譯 CUDA 套件** | 20–40 分鐘 |
| 4 | 下載權重與資源（數 GB） | 3–10 分鐘 |
| 5 | 寫入伺服器程式 | 幾秒 |
| 6 | 啟動伺服器，等到「✅ 模型就緒」 | 1–5 分鐘 |
| 7 | 用範例照片自我測試，顯示角度網格圖（可略過） | 1–3 分鐘 |
| 8 | 開公開網址，顯示 **網址／金鑰／QR Code** | 10–30 秒 |
| 9 | 保持執行、每 5 分鐘回報狀態 | 一直跑 |

用 iPhone 相機掃第 8 格的 QR Code → 開啟 App → 網址與金鑰會自動填入。

## 5. 加速下次啟動：把編譯結果存成 Dataset（強烈建議）
第 3 格編譯出的 4 個 wheel 會放在 `/kaggle/working/lam_wheels`。存起來後，下次第 3 格只要 1–2 分鐘。
1. 第 3 格跑完後，右上 **Save Version → Quick Save**。
2. 到該 notebook 的版本頁面 → **Output** 分頁 → **New Dataset**（或 Datasets → New Dataset → 來源選 Notebook Output），名稱填 `lam-wheels`，設為 Private。
3. 下次開啟 notebook：右側 **Input → Add Input**，搜尋自己的 `lam-wheels` 加入。
4. 第 1 格會自動找到 wheel（印出「wheel 快取：/kaggle/input/...」），第 3 格就會跳過編譯。

## 6. 不想一直開著瀏覽器
**Save Version → Save & Run All (Commit)** 會在背景完整執行，最長 12 小時。
網址與金鑰在該版本頁面的 **Logs** 裡找「伺服器網址：」那行（QR Code 在背景模式看不到，請在 App 設定頁手動輸入）。

## 7. 常見錯誤
| 現象 | 原因／處理 |
|---|---|
| 第 1 格 `nvidia-smi: not found` | Accelerator 沒選 GPU |
| 下載時 `Temporary failure in name resolution`／連不到 GitHub、HuggingFace | Internet 沒開，或帳號沒做手機驗證 |
| 第 3 格編譯失敗 | 把該格最後 30 行錯誤訊息貼給 Claude |
| 第 6 格「❌ 模型載入失敗」 | 執行 `!tail -n 50 /tmp/lam/server.log` 看詳細錯誤 |
| 第 8 格網址是 None | 再跑一次第 8 格；或 Internet 沒開 |
| App 顯示 401 | 金鑰不對，重新掃 QR Code |
| App 連不上 | session 已結束或重啟（網址每次都會變），重跑第 6、8 格 |
| 渲染時 CUDA out of memory | App 設定把 `chunk_size` 調小（例如 16），或 `out_size` 調小 |
| 方向相反 | `yaw_sign`／`pitch_sign` 改 -1 |

GPU 額度：免費每週約 30 小時，不用時請按右上 **Stop session**，避免浪費額度。
