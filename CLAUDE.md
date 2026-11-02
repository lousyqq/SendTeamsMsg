# E3 系統每日監控自動截圖、警戒線判定與 Teams 自動通報系統 (`CLAUDE.md`)

> ## ⚠️ 文件同步規則（每次修改專案都必須遵守）
> 本專案有兩份文件，**任何修改都要在同一次變更中一併更新兩份**，不可只改程式：
> - **`USER_MANUAL.html`**（給使用者）：操作步驟、按鈕名稱、畫面文字、批次檔用法、指令參數、注意事項、測試檢查清單、常見問題。截圖以 base64 內嵌在檔案尾端的 `MANUAL_IMAGES` 區塊，單一檔案即可。
> - **`CLAUDE.md`**（本檔，給開發者）：架構、設定格式、模組原理、設計決策、已知限制。
>
> 判斷方式：
> - 改了 `calibrator.html` 的按鈕 / 分頁 / 欄位 / 文字 → 更新手冊中對應步驟的按鈕名稱與畫面描述，**並執行 `tools\make_screenshots.ps1` 重新產生截圖**（需先關閉 open_calibrator 的黑色視窗；截圖用 `tools\_demo_config.json` 示範環境與 `sample_data.js` 範例圖，不含真實連結；腳本會直接改寫手冊中 `<!-- MANUAL_IMAGES_BEGIN -->`～`<!-- MANUAL_IMAGES_END -->` 區塊，請勿手動編輯該區塊，也不要整檔讀取，以免讀到大量 base64）。若新增 / 改名截圖，同步修改腳本中的 `Shot` 清單與手冊的 `<img data-shot="...">`。
> - 手冊中的 Teams 畫面、確認視窗、log 為 HTML 示意圖（`.mock` / `.dialog` / `.log`），訊息或 log 文字改變時要同步修改。
> - 改了 `config.json` 格式、`e3_monitor_native.ps1` 參數或行為（含 `-Calibrator` 本機服務 API）、`open_calibrator.bat` → 兩份都要更新。
> - 新增已知問題或限制 → 手冊「常見問題」＋本檔「已知限制」。
> - 更新手冊開頭的「最後更新」日期。
> - 完成後回報時，列出兩份文件各更新了哪些段落。

## 1. 專案目標與設計核心
本專案旨在實現**企業內網環境下（無需安裝任何第三方外掛或外部套件）**，每日定時自動開啟多個監控網頁（如 Zabbix 7天趨勢圖、Fab Index 產線報表等），擷取特定區域畫面，自動判斷「昨日區間」的圖表曲線是否超過自訂的「警戒線高度」，並將截圖與總結文字（正常訊息或異常罐頭語）自動發送至指定的 Microsoft Teams 對話框（個人自聊或指定群組）。

### 核心特色
1. **企業資安零外掛原生架構 (Zero-Dependency)**
   - **免安裝 Python / 免 `pip` 下載 / 免 WebDriver / 免載入 Edge 擴充功能 / 免改註冊表 (`HKCU`)**。
   - 100% 使用 Windows 10/11 出廠內建之 **PowerShell 5.1**、**.NET Framework 4.x** (`System.Drawing`, `System.Windows.Forms`, `System.Net.WebSockets.ClientWebSocket`, `UIAutomationClient`；`user32.dll` 以 `Add-Type` 內建編譯器即時載入) 與系統內建 **Microsoft Edge (`msedge.exe`) 原生 CDP (Chrome DevTools Protocol) 通道**。
2. **100% 彈性化設定（不寫死）**
   - 透過視覺化工具 `calibrator.html`，可自由**新增／刪除／啟用／停用任意數量的擷取頁面**。
   - 每個頁面有啟用中的警戒線就判定 (`threshold_check`)，沒有就只截圖 (`capture_only`)；`mode` 由設定工具依警戒線自動寫入，引擎在沒有啟用警戒線時也一律只截圖。
   - 每個頁面可設定 **0 至任意多條警戒線規則 (`rules`)**、自訂異常罐頭語，並可指定發送到不同的 Teams 對話群組。
   - **多時段排程 (`schedules`)**：一支主程式 + 一份 `config.json`，可設定任意多個時段，每個時段各自挑選要截圖傳送的頁面（例：08:00 傳 4 張、17:00 傳 1 張、20:00 傳 3 張）。頁面只定義一次，可被多個排程重複引用。
3. **視覺化拉框、即時網址抓圖預覽與本機直接存檔（免匯出搬檔）**
   - `open_calibrator.bat` → `e3_monitor_native.ps1 -Calibrator`（本機 `127.0.0.1:8765` 輕量服務，啟動後自動開啟瀏覽器；原 `server.ps1` 已併入主程式）：
     - **即時抓圖更新 (`POST /api/capture-url`)**：在 `calibrator.html` 修改「網址」後按 `Enter` 或點擊 **「📸 抓圖」**，後端呼叫主引擎 `-PreviewCapture`，用與正式排程**同一個已登入的 `edge_profile`**、同樣 1920×1080 可視範圍截取整頁畫面，存成 `sample_images/<pageId>_full.png`；calibrator 再用 **✂️ 擷取範圍** 在整頁圖上框選要傳送的區域。
     - **自動存檔 (`POST /api/save`)**、**自動同步排程 (`POST /api/register-schedules`、`GET /api/schedule-status`)**、**登入監控網站 (`POST /api/login-setup` → 主引擎 `-LoginMode`)**、**測試發送 (`POST /api/test-teams`)**。
4. **整合公司內部 (`46518`) 實測最佳實踐**
   - **防背景休眠凍結**：透過 Edge CDP `Page.setWebLifecycleState({state: "active"})`、`Page.bringToFront` 與 `--disable-background-timer-throttling` 參數，解決背景分頁凍結導致定時任務延遲送出的問題。
   - **使用已開啟、已登入的 Teams 發送**（2026-11-02 起；取代舊的 `msteams:` ChatID 跳轉與 `edge_teams_web` CDP 貼上）：支援 **Teams 應用程式 (PWA)**、**Edge 分頁** (`teams.cloud.microsoft`) 與 **桌面版 Teams**，不需另外登入。以 UI Automation 在聊天清單點選「對話名稱」，**確認視窗標題的對話名稱完全相同**後才以剪貼簿貼上，任何確認失敗即停止（詳見 3.3）。
   - **Teams 圖片上限保護**：遵循單則訊息最多 **4 張圖片**（單張 `<= 10 MiB`、合計 `<= 25 MiB`）限制，若啟用超過 4 張圖片會自動以 4 張為一批分批送出，並預留圖片模型上傳緩衝時間。

---

## 2. 專案目錄與檔案結構 (`c:\TEST\`)

```text
c:\TEST\
├── CLAUDE.md                  # 專案架構與開發維護紀錄文件 (本檔案)
├── USER_MANUAL.html           # 使用者手冊 (截圖已內嵌、Teams 示意圖、測試檢查清單)；設定工具右上「📖 使用手冊」可開啟
├── tools\                     # 只供維護：make_screenshots.ps1 (重拍手冊截圖並嵌入手冊)、_demo_config.json (示範設定)；部署時不需要
├── config.json                # 核心設定檔 (多時段排程 schedules、登入資訊、Teams 目標連結、各頁面與警戒線規則)
├── calibrator.html            # 視覺化設定工具 (三分頁：頁面與警戒線 / 排程與發送 / 全域設定，右側依排程預覽 Teams 訊息)
├── e3_monitor_native.ps1      # 【主執行引擎，唯一程式】截圖、像素分析、Teams 發送、排程註冊；-Calibrator = 設定工具本機服務 (127.0.0.1:8765)：
│                              #   /api/config, /api/save, /api/capture-url, /api/save-sample, /api/test-teams[?schedule=id&send=1],
│                              #   /api/register-schedules, /api/schedule-status, /api/login-setup, /api/teams-detect
├── open_calibrator.bat        # 【唯一需要雙擊的檔案】執行 e3_monitor_native.ps1 -Calibrator 並自動開啟 calibrator.html
│
├── sample_data.js             # 預先轉為 Base64 的 4 張範例截圖資料 (供 calibrator.html 離線預覽)
├── sample_images\             # 各頁面設定/測試用圖：<id>_full.png 整頁原圖、<id>.png 依 crop_region 裁切 (calibrator 自動產生)、annotated_<id>.png 診斷圖
│
│   (以下資料夾由程式自動建立，不需複製、可刪除)
├── edge_profile\              # 專用 Edge 瀏覽器設定檔目錄 (保存登入 Cookie / Session，與日常瀏覽器隔離)；刪除後需重新「🔐 登入監控網站」，不可跨電腦複製 (DPAPI 加密)
├── captures\                  # 實際擷取之截圖與標註診斷圖 (captures\YYYY-MM-DD\<排程id>_HHmm\)
└── logs\                      # 每次執行的 log (YYYY-MM-DD_HHmm_<排程id>.log，保留 30 天)、register_last.txt、preview_last.txt、teams_detect.txt
```

> 2026-11-01 已移除：Python 備援模組 (`main.py`、`capture.py`、`analyzer.py`、`teams_sender.py`、`setup_env.bat`)、舊版 `edge_headless_profile\`、早期測試 `edge_profile_test\`。本專案不需要 Python。
> `pic\` 為使用者個人照片，與專案無關。

---

## 3. 核心模組運作原理

### 3.1 網頁登入與特定區域截圖 (`Capture-PagesNative` in `e3_monitor_native.ps1`)
1. **三層登入過關機制**：
   - **第一層（Windows AD / 持久化 Profile）**：使用獨立 `--user-data-dir="c:\TEST\edge_profile"`，自動帶入公司內網 Windows 整合驗證身分，並保留「🔐 登入監控網站」(`-LoginMode`) 登入過的所有 Cookie。
   - **第二層（自動登入）**：每次載入目標網址 3 秒後以 CDP `Runtime.evaluate` 執行 `$JsLoginState`：
     - `PASSWORD`（有可見的 `input[type="password"]`）→ `Get-JsFillLogin` 填帳密送出。
     - `LOGIN_BUTTON`（沒有密碼框，但有可見、文字完全等於 `Login` / `Log in` / `Sign in` / `登入` 的 button / a / input / `[role=button]`，例如 Zabbix「You are not logged in」提示頁）→ `$JsClickLoginButton` 點它，再每 2 秒試填一次（最多 8 次 = 16 秒）等密碼框出現。
     - 帳號框依優先順序找且只取可見欄位（`#name`、`name="name"`、`type=email`、name 含 user / login / account / id、`type=text`），避免填到隱藏欄位（例如 `sid`）；以原生 value setter 設值（React 也收得到）；有「記住我」（Zabbix `#autologin` / name 含 remember）就勾選；帳密以 `ConvertTo-Json` 轉成 JS 字串（不怕引號）。
     - 送出 4 秒後重新開啟原本網址，再判斷一次：仍為 `PASSWORD` / `LOGIN_BUTTON` 就寫「❌ 自動登入後仍停在登入畫面」（照常截圖，不中止）。
     - 沒設定帳密（`Test-AuthConfigured`：`auth.enabled`、username 非空且不是 `YOUR_USERNAME`）時只寫提示、不點按鈕。
     - 已用本機模擬的 Zabbix 流程（提示頁 → Login → `#name` / `#password` / `#autologin` / `#enter` 表單 → 帶 cookie 回 charts.php）實測成功、帳密錯誤、未設定帳密三種情況；尚未對真正的 Zabbix 實測。
   - **第三層（防背景凍結）**：每次切換頁面與截圖前呼叫 `Page.bringToFront` 與 `Page.setWebLifecycleState({ state: "active" })`。
2. **精準區域截圖**：
   - 直接呼叫 Edge CDP 原生指令 `Page.captureScreenshot`，並傳入 `clip: { x, y, width, height, scale: 1 }`，不需透過螢幕截圖 (`CopyFromScreen`)，即使視窗被遮擋也能擷取乾淨的網頁像素。
   - **固定座標系**：Edge 以 `--force-device-scale-factor=1` 啟動，並呼叫 `Emulation.setDeviceMetricsOverride {1920x1080, deviceScaleFactor 1}`，可視範圍固定為 1920×1080、不受視窗邊框與 Windows 顯示比例 (125%/150%) 影響。`crop_region` 即此座標系中的 CSS 像素。
   - **`-PreviewCapture -PageId <id> -Url <url> -OutFile <png>`**：供 `/api/capture-url` 呼叫，截單一頁整頁 (crop 停用)，同樣走 `Capture-PagesNative`（自動登入、防凍結）；與排程共用 Mutex（等 10 秒），錯誤訊息寫入 `logs\preview_last.txt`。

### 3.2 昨日區間警戒線像素高度判定 (`Test-CurvePixel` in `e3_monitor_native.ps1` & `calibrator.html`)
1. **座標定義**：
   - 每個小圖表規則定義一個 `roi: { x, y, w, h }`（框住該圖表最右側「昨日區間」的完整高度範圍）以及一條水平警戒線 `threshold_y`。
   - 圖片座標系左上角為 `(0, 0)`，因此位於警戒線上方的超標區域為 `roi.y <= y <= threshold_y`。
2. **像素顏色過濾 (`color_mode`)**：
   - `auto`（預設）：自動排除高亮度低飽和度的灰白背景與格線（`lum > 206 && sat < 28`），並排除 Zabbix 7天圖表特有的垂直粉紅日期分隔虛線（`r > 200 && (r - g) > 15 && g > 160 && b > 160`），僅針對真正的數據曲線像素計數。
   - `custom`（滴管指定顏色）：計算像素與指定曲線顏色 `target_color` 的 RGB 歐氏距離，距離 `<= color_tolerance` 視為曲線像素。
3. **判定門檻與輸出**：
   - 當警戒線上方的曲線像素點數 `>= min_pixels`（預設 `2` px）時判定為 **「🚨 超過警戒線」**，自動將該規則的 `alert_message` 加入異常清單，並在 `annotated_<page_id>.png` 畫上紅框備查；若全部正常則輸出 `normal_summary`（預設：`目前E3系統正常`）。

### 3.3 Teams 對話定位與分流發送 (`Send-GroupToTeams` in `e3_monitor_native.ps1`)
> 2026-11-02 改版：公司環境的 Teams 是 **Edge 安裝的 PWA**（或直接在 Edge 分頁開 `teams.cloud.microsoft`），沒有桌面版可接 `msteams:` 連結；舊的 `edge_teams_web` 要在專用 `edge_profile` 另外登入 Teams。因此改成「使用已經開著、已經登入的 Teams」。`teams.send_mode`、`desktop_window_title`、`auto_switch_chat` 已不再使用（舊 config 留著無妨）。

1. **`webhook_url`（若設定）**：直接 HTTP POST Adaptive Card 至 Teams Workflow Webhook，不操作視窗（優先於下列流程）。
2. **發送對象 = 對話名稱**（`Resolve-ChatTarget`）：填 Teams 聊天清單上顯示的名稱；`自己` / `self` / 含 `48:notes` 的舊連結 = 自己的個人對話（名稱以 `(您)` / `(You)` 結尾）。其他連結 (`http(s):` / `msteams:`) 與 Email 直接 `throw`（設定工具 `targetProblem()` 同步顯示 ⚠️ 並阻擋 🚀）。
3. **找 Teams 視窗**（`Get-TeamsCandidates` / `Find-TeamsWindow`，順序 `$TeamsKinds` = `pwa` → `desktop` → `edge-tab`；`teams.prefer_window` 指定時只找該種）：
   - `pwa`：程序 `msedge`、標題含 `Microsoft Teams`、且標題**不以** `Microsoft Edge` 結尾（`$EdgeSuffix`，中間可能有 U+200B）。不限定結尾，因 Edge 可能在前面加「應用程式名稱 - 」。**尚未在真正的 PWA 上實測**。
   - `desktop`：程序 `ms-teams`（新版）/ `Teams`（舊版）。
   - `edge-tab`：一般 Edge 視窗中 Name 含 `Microsoft Teams` 的 `TabItem`；找到後 `SelectionItemPattern.Select()` 切成目前分頁。分頁名稱會帶「- 已捨棄 - 記憶體使用量 …」等後綴（睡眠分頁）。
   - `Get-EdgeTabs` 只用 `ControlViewWalker` 走瀏覽器外框、**跳過 `Document` 子樹**：目前分頁是 Teams 時，對整個 Edge 視窗 `FindAll(Descendants)` 會走完 Teams 網頁的協助工具樹，實測卡住超過 1 分鐘。
   - 都沒開時 `Open-TeamsApp`：開始功能表 / 桌面最上層的 Teams PWA 捷徑（參數含 `--app-id`）→ `msteams:`（有註冊時）→ `msedge <TeamsWebHome>`；有 `prefer_window` 時只開該種，開不了就 `throw`。開啟後等 20 秒載入。`Find-TeamsPwaShortcut` 桌面不遞迴（桌面常被導向 OneDrive / 網路磁碟，實測遞迴要 70 秒以上）。
4. **切換對話**（`Open-TeamsChat`）：最多等 30 秒讓 Teams 畫面載入（喚醒睡眠分頁）→ 不在聊天畫面時點左側「聊天」（`Find-TeamsChatNav`）→ `Find-ChatListItem` 在 `TreeItem` 中找名稱（可往下捲 10 頁；找不到且還沒點過「聊天」時，點「聊天」後再找一次）→ 點選 → 等視窗標題變成該對話。
5. **以視窗標題確認對話**（`Get-ChatNameFromTitle` / `Test-ChatTitle`）：標題格式「聊天 | 對話名稱 | 組織 | … | Microsoft Teams」，PWA 可能有前綴「… - 」，Edge 分頁有後綴「 和其他 N 個頁面 - 設定檔 - Microsoft Edge」；英文介面為「Chat | …」。取出的對話名稱必須與設定**完全相同**（避免「E3」誤認「E3 乖乖」）；自己 = 名稱以 `(您)` / `(You)` 結尾。
6. **貼上與送出**：
   - **前景**（`Set-WindowForeground`）：縮小時 `ShowWindow(SW_RESTORE)`，再以「按放 Alt + `AttachThreadInput` + `SetForegroundWindow`」突破前景鎖定，並以 `GetForegroundWindow()` 驗證。
   - **輸入框**（`Find-TeamsComposeBox` / `Set-TeamsComposeFocus`）：UI Automation 找 `ControlType.Edit` 且 `AutomationId` 為 `new-message-*`（或 Name 為「輸入訊息 / Type a message」）→ `SetFocus()`，未取得焦點時點擊。Chromium / WebView2 的協助工具樹需先 `FindAll(TrueCondition)` 喚醒，每 4 次重試做一次完整查詢。
   - 開始前若輸入框已有草稿（`Get-ComposeState`：圖片 = Name「影像 / Image」的按鈕，文字排除提示字與 U+2060 等不可見字元）就停止。
   - 圖片以剪貼簿逐張貼上（每 4 張一批），等該批圖片全部出現在輸入框（最多 90 秒）→ 最後一批貼總結文字並確認有文字 → Enter → 確認輸入框清空。
   - **防貼錯**（`Confirm-TeamsReady`）：每張圖、文字、Enter 之前確認前景仍是 Teams 且標題仍是目標對話；等待期間被切走也停止。失敗即 `throw`（exit 1）。
   - `-DryRun` / `auto_press_enter=false`：停在目標對話不送出；正式送出後切回原本的對話。
   - `Add-Type` 失敗（公司封鎖編譯器）時無法操作視窗，直接 `throw`。
7. **偵測模式 `-DetectTeams`**（設定工具 🔍 → `POST /api/teams-detect`：先存 config，再以 `$PSCommandPath -DetectTeams` 執行並回傳 `logs\teams_detect.txt`）：列出所有 Teams 候選（不切換分頁）、所有 msedge / ms-teams 視窗原始標題（PWA 沒被認出時回報用）、PWA 捷徑、`msteams:` 是否註冊；對「發送時會使用」的視窗檢查目前對話、輸入框、聊天清單項目數，以及預設與各啟用排程的發送對象是否在清單畫面上。Edge 分頁不是目前分頁時不檢查畫面內容。本機約 4 秒。

### 3.4 設定工具版面 (`calibrator.html`)
- 左欄分三個分頁（記在 `localStorage` 的 `e3_calibrator_tab`）：
  - **📄 頁面與警戒線**：擷取頁面清單、此頁面設定（擷取範圍數值與載入等待秒數收在「進階」；沒有「處理模式」與「單頁發送對象」欄位）、警戒線清單與編輯（名稱、訊息；座標、紅線高度、顏色、💧 取色收在「進階」）。表單下方顯示「實際發送對象（來源）」與會改送他處的排程。
  - **📅 排程與發送**：預設「Teams 對話名稱」（**📨 先傳給自己測試** 寫入 `自己`；舊設定的 `48:notes` 連結輸入框顯示為 `自己`，預覽顯示「👤 自己（個人對話）」；填連結 / Email 時顯示 ⚠️ 並阻擋 🚀）、「使用哪個 Teams」(`teams.prefer_window`：空白 = 自動 / `pwa` / `edge-tab` / `desktop`)、**🔍 偵測 Teams 視窗**（`/api/teams-detect`，結果顯示在下方 `#detectTeamsResult`）、排程時段卡片（收合成一行，含「下次執行時間 / ⚠️ 未寫入」；id 自動產生）、同步狀態列與 🔄 重新套用、訊息文字。
- **自動儲存**（無 💾 按鈕）：`autoSaveTick()` 每秒比對 `JSON.stringify(config)`，有變動就 `/api/save`（拖曳中不存）；右上角 `#autoSaveStatus` 顯示狀態。只有從 `/api/config` 成功讀入設定時才啟用（`autoSaveEnabled`），避免以 localStorage 舊資料覆蓋 config.json。存檔前 `normalizePageModes()` 依警戒線同步 `mode`。
- **自動同步排程**：`scheduleSignature()` = 各排程 `[id, enabled, time, days]`；有變動時改呼叫 `/api/register-schedules`（同時存檔並註冊 / 移除 Windows 任務）。名稱、標題、發送對象、頁面變動只存檔不重新註冊。開啟時不自動註冊，而是以 `/api/schedule-status`（`Get-ScheduledTask E3_Monitor_*` + `NextRunTime`）顯示「✅ 已同步 / ⚠️ N 個尚未寫入」，由使用者按 🔄 重新套用。
- **畫布只有兩種模式**：`currentTool` = `crop`（✂️ 擷取範圍）或 `rule`（📏 警戒線），`pick_color` 為一次性取色。📏 模式 `hitTestRules()`：選取中警戒線的紅線 ±6px → 拖曳調高度（游標 ↕，兩端有把手）；框內 → 選取並拖曳移動（紅線跟著移）；空白處拖曳超過 4px → `addRule()` 新增（紅線預設 35% 高度），單擊不新增。
- `tools\make_screenshots.ps1` 每張截圖前先設 `autoSaveEnabled = false`，避免示範環境寫回設定或自動註冊 Windows 排程。
  - **⚙️ 全域設定**：🔐 登入監控網站、監控網站帳密、自動按 Enter（「名稱搜尋切換對話」已移除，現在一律以名稱 + 標題確認）。
- 中間畫布預設「符合寬度」縮放（下限 0.1，1920px 整頁圖在筆電需縮到 0.5 以下）；`.canvas-wrapper` 用 `margin: 0 auto` 置中而非 `justify-content: center`，圖比畫面寬時才不會左側被切掉、無法捲動。像素放大鏡浮在畫布右下角。
- **必須經由本機服務開啟**：以 `file://` 開啟時圖片只能用 `sample_data.js` 內建舊範例、裁切圖也無法寫回。`initApp()` 偵測到 `file:` 時，若 `127.0.0.1:8765` 有回應就 `location.replace` 到 `http://127.0.0.1:8765/calibrator.html`，否則顯示紅色 `serviceBanner`。
- **儲存失敗必須明確告知**：`/api/save` 或 `/api/save-sample` 沒回應時顯示紅色提示與 `serviceBanner`（`config.json` 沒有更新）；`localStorage` 只作備份，不再顯示成「已儲存」。已移除 `showSaveFilePicker` 備援（它只能存 config，不能存圖，容易造成設定與圖不一致）。
- 本機服務（`-Calibrator`）單一請求例外時回 500 並繼續服務（舊版 `catch { break }` 會讓整個服務靜默結束，之後所有儲存都失敗）。服務內呼叫主程式其他模式一律用 `$PSCommandPath` 另開 powershell（抓圖、測試、註冊、登入），避免阻塞或污染服務程序。`-NoBrowser` 不自動開瀏覽器（截圖工具 / 測試用）。`-ConfigPath` 預設為主程式同資料夾的 `config.json`。
- **本機服務安全限制**（舊版送 `Access-Control-Allow-Origin: *`，任何網頁都能讀 config 密碼、改設定、觸發 Teams 發送與註冊排程）：
  - 不送任何 CORS 標頭；帶有 `Origin` 且不是 `http://127.0.0.1:8765` 的請求與所有 `OPTIONS` 一律 403（沒有 `Origin` 的本機程式呼叫照常允許）。
  - 靜態檔白名單：`calibrator.html`、`sample_data.js`、`USER_MANUAL.html`、`sample_images/*.png`；`config.json` 只能經 `/api/config` 讀取。
  - 因此 calibrator 在 `file://` 偵測服務時用 `fetch(..., {mode: "no-cors"})`（只確認有沒有回應）。
  - 所有回應帶 `Cache-Control: no-store`，避免更新 calibrator.html / 手冊 / 截圖後瀏覽器仍顯示舊版。
- **警戒線框超出圖片**：`evaluateRule()` 回傳 `outOfRange`，清單顯示「⚠️ 超出圖片範圍」且不計入超標（圖外像素讀成黑色會誤判）；引擎同樣略過該條並寫 log，不再因 `GetPixel` 例外讓整次執行失敗。
- **沒有圖的頁面**：不再拿 `page1` 範例圖代替；畫布顯示「這一頁還沒有畫面」提示圖（`isPlaceholder`，不評估警戒線、預覽顯示提醒）；`-TestSample` 也直接略過該頁並提醒先 📸 抓圖。
- 切換到沒有整頁圖的頁面時，✂️ 工具自動改回 📏；🗑️ 刪除頁面會先確認。
- **兩張圖模型**：`fullImages[id]`（整頁原圖，來自 📸 抓圖或 🖼️ 載入截圖）與 `pageImageCanvases[id]`（依 `crop_region` 從整頁圖裁切 = 排程實際送出的圖）。
  - **✂️ 擷取範圍** 工具顯示整頁圖與擷取框，拖曳即改 `crop_region`；其他工具顯示裁切後的圖，警戒線 ROI 座標以裁切後的圖為準（與引擎一致）。
  - 裁切結果經 `/api/save-sample` (kind=crop) 自動寫回 `sample_images\<id>.png`，`-TestSample` 與下次開啟都用同一張圖；🖼️ 載入截圖 以 kind=full 寫回 `<id>_full.png`。
  - 開啟時若有 `<id>_full.png` 即以它為準重新裁切；沒有則退回舊的 `<id>.png`（此時 ✂️ 會提示先 📸 抓圖）。
  - 📸 抓圖保留原本的 `crop_region`，超出新畫面才改為整頁；新頁面預設 `crop_region = 0,0,1920,1080`。
  - 擷取範圍改變不會自動平移既有警戒線 ROI。
- 右欄以「預覽哪個排程」選單為準，顯示該排程實際送出的圖片、標題、訊息、發送對象（與引擎相同的優先順序與 4 張分批）。
- 測試按鈕：**🧪 測試貼上（不送出）** = `/api/test-teams` 預設帶 `-DryRun`；**🚀 正式送出…** 需確認對話框（列出排程、張數、對象）才帶 `?send=1`。發送對象未設定時不允許正式送出。
- 引擎端同樣防護：發送對象仍是佔位文字（`請將…連結` / `貼在這裡` / `預設Teams群組`）時略過發送並回傳 exit code 1。

### 3.5 多時段排程 (`schedules` in `config.json`)
1. **設定格式**（頁面在 `pages[]` 只定義一次，排程以 `id` 引用）：
   ```json
   "schedules": [
     { "id": "morning",   "enabled": true, "name": "早上 08:00 四張監控截圖", "time": "08:00", "days": [],
       "pages": ["page1","page2","page3","page4"], "target_chat_name": "", "title": "【08:00 早班巡檢】" },
     { "id": "afternoon", "enabled": true, "time": "17:00", "days": ["MON","TUE","WED","THU","FRI"], "pages": ["page4"] }
   ]
   ```
   - `id`：英數字 / `_` / `-`，同時作為 Windows 任務名稱 `E3_Monitor_<id>`。
   - `days`：空陣列 = 每天；或填 `MON`~`SUN` 指定星期。
   - `pages`：依清單順序截圖與貼圖；頁面本身 `enabled=false` 時一律略過。
   - `target_chat_name`（選填）：Teams 對話名稱或 `自己`（見 3.3）。發送對象優先順序 **排程 > 頁面 > `teams.target_chat_name`**。設定工具已不提供「頁面」層級欄位（只剩預設與排程）；引擎與預覽仍相容舊設定中的 `pages[].target_chat_name`。
   - `title`（選填）：加在 Teams 訊息最前面，用來區分不同時段。
   - 舊版只有 `schedule_time` 的 config 仍可用：自動視為一個 `daily` 排程（包含全部頁面）。
2. **執行參數**（`e3_monitor_native.ps1`）：
   - `-Schedule <id>`：只跑該排程的頁面；不帶則跑全部啟用頁面。
   - `-RegisterSchedules`：依 config 註冊/更新每個啟用排程，並移除已刪除/停用的 `E3_Monitor_*` 任務與舊版 `E3_Daily_Monitor_Teams`。以目前使用者「僅登入時執行 (Interactive)」註冊，**不需系統管理員**（貼 Teams 必須有互動桌面）。任務設定：錯過時間開機後補跑、電池模式也執行、上限 1 小時、不重複啟動。
   - `-ListSchedules`：列出排程與頁面。
3. **企業環境防護**：
   - 具名 Mutex `Local\E3MonitorNativeRun`：兩個排程時間重疊時依序執行（共用 `edge_profile`、Teams 視窗與剪貼簿），最多等 30 分鐘。
   - `Stop-ProfileEdge`：啟動前/結束後只關閉命令列含本專案 `edge_profile` 的 Edge，避免殘留程序使 CDP 埠打不開；不影響日常 Edge（包含使用者開著的 Teams PWA / Teams 分頁）。
   - `Wait-CdpTargets`：輪詢 CDP 埠最多 20 秒（防毒掃描導致 Edge 啟動慢）。
   - `Start-Transcript` 寫入 `logs\`，背景排程無視窗時可追查。

---

### 3.6 精簡部署（開發機只放必要檔案）
- **必備 4 個檔案**：`open_calibrator.bat`、`calibrator.html`、`e3_monitor_native.ps1`、`config.json`。路徑不限 `C:\TEST`（腳本皆以 `$PSScriptRoot` / `%~dp0` 定位），但需放在同一資料夾。2026-11-01 已移除 `server.ps1`（併入 `-Calibrator`）、`login_setup.bat`（→ 設定工具 🔐 按鈕）、`test_to_my_teams.bat`（→ 🧪 / 🚀 按鈕）、`register_schedule.bat`（→ 自動同步 / 🔄 重新套用）、`run_daily.bat`（Windows 排程直接呼叫主程式；手動補跑用 `schtasks /Run`）。
- **自動產生、不需複製**：`edge_profile\`、`captures\`、`logs\`、`sample_images\`（📸 抓圖後重建）。
- **選用**：`USER_MANUAL.html`（📖 手冊，圖片已內嵌）、`sample_data.js`（缺檔時 `window.SAMPLE_IMAGES` 為空，calibrator 照常運作；但 `tools\make_screenshots.ps1` 需要它）、`CLAUDE.md`、`tools\`（只供維護）。
- **`.bat` 檔只能用 ASCII（英文）**：cmd 以系統代碼頁 (950) 讀批次檔，`chcp 65001` 之後的中文行會被錯位解析，與下一行黏在一起（症狀：「'亂碼…powershell' 不是內部或外部命令」）。中文說明一律寫在 PowerShell 腳本或手冊裡。
- **新增檔案時**：若執行時必須存在，需同步更新本節、手冊「8-1 必備與可刪除的檔案」，以及主程式 `-Calibrator` 區塊的靜態檔白名單（若需由瀏覽器載入）。
- Windows Server 可執行截圖與判斷，但桌面版 Teams 貼上需要有人登入且螢幕未鎖定的互動桌面；無人值守主機需改用 `webhook_url`（未實測）。

## 4. 常用維護與操作流程

> 完整的使用者操作步驟（含測試發送到自己的 Teams、新增網頁擷取範圍與警戒線、測試檢查清單）請見 **`USER_MANUAL.html`**；本節只列重點。

1. **開啟設定工具**：雙擊 `open_calibrator.bat`（自動開啟瀏覽器；所有修改自動儲存）。
2. **首次綁定網站登入狀態**：設定工具 ⚙️ 全域設定 → 🔐 登入監控網站，在彈出的 Edge 登入後關閉即可保存至 `edge_profile\`。
3. **測試發送到自己的 Teams**：先開好並登入 Teams（PWA / Edge 分頁 / 桌面版）→ 📅 排程與發送 → 📨 先傳給自己測試 → 🔍 偵測 Teams 視窗 → 右欄 🧪 測試貼上（不送出）/ 🚀 正式送出…。
4. **排程**：在「📅 排程與發送」新增 / 修改時段，自動同步到 Windows（第一次使用按 🔄 重新套用）。手動補跑：`schtasks /Run /TN E3_Monitor_<id>`，或 `powershell -File e3_monitor_native.ps1 -Schedule <id>`。
5. **執行紀錄**：`logs\`。

---

## 5. 已知限制

1. **網頁版面隨可視範圍變化**：所有截圖固定在 1920×1080 可視範圍。若網頁版面改版，需重新 📸 抓圖並重新框選擷取範圍與警戒線（擷取範圍改變不會自動平移 ROI）。
2. **📸 抓圖會短暫開啟 Edge 視窗**（非 headless，與排程同一路徑），並會關閉其他使用 `edge_profile` 的 Edge（例如未關閉的 🔐 登入用視窗）。
3. **`-TestSample` 使用 `sample_images\<pageId>.png`**，缺檔的頁面會略過；該檔由 calibrator 在 📸 抓圖 / 框選後自動產生，從未抓圖的頁面才會缺檔。
4. **Teams 發送需互動桌面且 Teams 要開著**：螢幕鎖定時無法切換前景視窗，程式會停止並記錄「無法把 Teams 視窗切到最前面」；執行期間會佔用系統剪貼簿、把 Teams（或 Edge 的 Teams 分頁）拉到最前面，且可能移動滑鼠點擊。依賴 Teams 的 UI：輸入框 `AutomationId=new-message-*` / Name「輸入訊息」、聊天清單 `TreeItem`、左側「聊天」按鈕、視窗標題格式「聊天 | 對話名稱 | …」，Teams 改版若變更需同步調整 `Find-TeamsComposeBox` / `Open-TeamsChat` / `Get-ChatNameFromTitle`。
5. **PWA 偵測未實測**：開發機只有桌面版與 Edge 分頁（Edge 分頁已實測 🧪 貼上成功，含喚醒睡眠分頁）；PWA 依「msedge 視窗、標題含 Microsoft Teams、不以 Microsoft Edge 結尾」判斷，若公司 PWA 標題格式不同需依 `-DetectTeams` 的原始標題調整 `Get-TeamsCandidates`。
6. **以名稱找對話**：名稱必須與 Teams 顯示的完全一致（群組改名要同步修改）；沒有命名的群組，聊天清單與標題顯示的成員名單可能不同而無法確認。聊天清單最多往下捲 10 頁。
7. **網頁登入帳密以明文**存在 `config.json` 與瀏覽器 `localStorage`（`e3_monitor_config_v1`）。
8. **自動登入的範圍**：所有網站共用 `auth` 一組帳密；只認文字完全等於 Login / Log in / Sign in / 登入 的按鈕（其他字樣如「Login with SSO」不會點）；Login 後若進到 SSO / MFA 等沒有密碼框的頁面無法自動登入，需改用 🔐 登入監控網站。允許訪客瀏覽、但頁面上有 Sign in 連結的網站，設定帳密後也會被登入一次（無害）。
