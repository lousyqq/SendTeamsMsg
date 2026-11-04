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
     - **即時抓圖更新 (`POST /api/capture-url`)**：按 Enter 或「📸 抓圖」呼叫 `-PreviewCapture -InteractiveCapture`。專用 Edge 載入完成後等待使用者捲動，按「擷取目前畫面」才截圖並正常關閉；按「取消」不變更圖片與設定，10 分鐘逾時亦停止。2026-11-03 起改為背景執行：`/api/capture-url` 啟動引擎後立即回 `{pending:true}`，前端每秒 `GET /api/capture-status`，完成後才把暫存圖移成 `<id>_full.png` 並回傳 PNG 與 `capture_view`（結果只回傳一次），前端一併存入每頁設定，再框選。同時只允許一個抓圖。請求攜帶當前 `browser_zoom`（50～200 整數）及 `wait_seconds`（1～60 整數），不依賴自動儲存完成時間。URL 欄位失焦不再自動開啟互動視窗。
     - **自動存檔 (`POST /api/save`)**、**自動同步排程 (`POST /api/register-schedules`、`GET /api/schedule-status`)**、**登入監控網站 (`POST /api/login-setup` → 主引擎 `-LoginMode`)**、**測試發送 (`POST /api/test-teams`)**。
4. **整合公司內部 (`46518`) 實測最佳實踐**
   - **防背景休眠凍結**：透過 Edge CDP `Page.setWebLifecycleState({state: "active"})`、`Page.bringToFront` 與 `--disable-background-timer-throttling` 參數，解決背景分頁凍結導致定時任務延遲送出的問題。
   - **使用已開啟、已登入的 Teams 發送**（2026-11-02 起；取代舊的 `msteams:` ChatID 跳轉與 `edge_teams_web` CDP 貼上）：支援 **Teams 應用程式 (PWA)**、**Edge 分頁** (`teams.cloud.microsoft`) 與 **桌面版 Teams**，不需另外登入。以 UI Automation 在聊天清單點選「對話名稱」，**確認視窗標題的對話名稱完全相同**後才以剪貼簿貼上，任何確認失敗即停止（詳見 3.3）。
   - **Teams 圖片上限保護**：遵循單則訊息最多 **4 張圖片**（單張 `<= 10 MiB`、合計 `<= 25 MiB`）限制，若啟用超過 4 張圖片會自動以 4 張為一批分批送出，並預留圖片模型上傳緩衝時間。





---





## 2. 專案目錄與檔案結構（`<專案資料夾>\`）





> 路徑不限：程式一律以 `$PSScriptRoot` / `%~dp0` 定位，所有檔案放同一資料夾即可。開發機為 `C:\SendTeamsMsg\`，手冊範例沿用 `C:\TEST\`。



```text
<專案資料夾>\
├── CLAUDE.md                  # 專案架構與開發維護紀錄文件 (本檔案)
├── USER_MANUAL.html           # 使用者手冊 (截圖已內嵌、Teams 示意圖、測試檢查清單)；設定工具右上「📖 使用手冊」可開啟
├── tools\                     # 只供維護、部署時不需要：make_screenshots.ps1 (重拍手冊截圖)、_demo_config.json
├── config.json                # 核心設定檔 (多時段排程 schedules、登入資訊、Teams 目標連結、各頁面與警戒線規則)
├── calibrator.html            # 視覺化設定工具 (三分頁：頁面與警戒線 / 排程與發送 / 全域設定，右側依排程預覽 Teams 訊息)
├── e3_monitor_native.ps1      # 【主執行引擎，唯一程式】截圖、像素分析、Teams 發送、排程註冊；-Calibrator = 設定工具本機服務 (127.0.0.1:8765)：
│                              #   /api/config, /api/save, /api/capture-url, /api/capture-status, /api/save-sample, /api/delete-sample, /api/test-teams[?schedule=id&send=1],
│                              #   /api/register-schedules, /api/schedule-status, /api/login-setup, /api/teams-detect
├── open_calibrator.bat        # 【唯一需要雙擊的檔案】執行 e3_monitor_native.ps1 -Calibrator 並自動開啟 calibrator.html
├── teams_delivery.ps1         # 【必備】Teams 分批規則 (Split-TeamsImageBatches / Get-TeamsBatchText)；主程式啟動即載入，缺檔時所有模式 (含設定工具) 都無法啟動
├── teams_cdp\Delivery.ps1     # CDP 背景傳送 (見 3.3 第 8 點)；只有 prefer_window=cdp 時由主程式 dot-source；UTF-8 with BOM
├── setup_cdp.bat              # 執行 e3_monitor_native.ps1 -CdpSetup (顯示 Edge 登入 Teams 網頁版並檢查發送對象)
│
├── sample_data.js             # 預先轉為 Base64 的 4 張範例截圖資料 (供 calibrator.html 離線預覽)
├── sample_images\             # 各頁面設定/測試用圖：<id>_full.png 未裁切來源畫面、<id>.png 依 crop_region 裁切 (calibrator 自動產生)、annotated_<id>.png 診斷圖；同一頁重新抓圖一律覆蓋，不在 config.pages 的頁面圖會被刪除 (見 3.4)
│
│   (以下資料夾由程式自動建立，不需複製、可刪除)
├── edge_profile\              # 專用 Edge 瀏覽器設定檔目錄 (保存登入 Cookie / Session，與日常瀏覽器隔離)；刪除後需重新「🔐 登入監控網站」，不可跨電腦複製 (DPAPI 加密)
├── captures\                  # 實際擷取之截圖與標註診斷圖 (captures\YYYY-MM-DD\<排程id>_HHmm\，保留 7 天 `$CaptureKeepDays`)
└── logs\                      # 每次執行的 log (YYYY-MM-DD_HHmm_<排程id>.log，保留 30 天)、register_last.txt、preview_last.txt、teams_detect.txt
```





> 2026-11-01 已移除：Python 備援模組 (`main.py`、`capture.py`、`analyzer.py`、`teams_sender.py`、`setup_env.bat`)、舊版 `edge_headless_profile\`、早期測試 `edge_profile_test\`。本專案不需要 Python。
> `pic\` 為使用者個人照片，與專案無關。





---





## 3. 核心模組運作原理





### 3.1 網頁登入與特定區域截圖 (`Capture-PagesNative` in `e3_monitor_native.ps1`)
0. **停用翻譯提示（2026-11-03）**：`-LoginMode` 與 `Capture-PagesNative` 啟動專用瀏覽器時皆加入 `--disable-features=Translate,msEdgeTranslate`，停用 Chromium / Edge 翻譯功能，避免出現「是否翻譯成英文」提示並保留網站原文。涵蓋手動登入、📸 抓圖與正式排程；僅作用於本次啟動的專用瀏覽器，不修改登錄檔、登入資料或日常 Edge 設定。更新前已開啟的登入視窗需先關閉再開啟。已通過 PowerShell 5.1 語法檢查，翻譯提示是否消失仍需在公司 Edge 實機確認。
1. **三層登入過關機制**：
   - **第一層（Windows AD / 持久化 Profile）**：使用獨立 `--user-data-dir="<專案資料夾>\edge_profile"`，自動帶入公司內網 Windows 整合驗證身分，並保留「🔐 登入監控網站」(`-LoginMode`) 登入過的所有 Cookie。
   - **第二層（自動登入）**：每次載入目標網址 3 秒後以 CDP `Runtime.evaluate` 執行 `$JsLoginState`：
     - `PASSWORD`（有可見的 `input[type="password"]`）→ `Get-JsFillLogin` 填帳密送出。
     - `LOGIN_BUTTON`（沒有密碼框，但有可見、文字完全等於 `Login` / `Log in` / `Sign in` / `登入` 的 button / a / input / `[role=button]`，例如 Zabbix「You are not logged in」提示頁）→ `$JsClickLoginButton` 點它，再每 2 秒試填一次（最多 8 次 = 16 秒）等密碼框出現。
     - 帳號框依優先順序找且只取可見欄位（`#name`、`name="name"`、`type=email`、name 含 user / login / account / id、`type=text`），避免填到隱藏欄位（例如 `sid`）；以原生 value setter 設值（React 也收得到）；有「記住我」（Zabbix `#autologin` / name 含 remember）就勾選；帳密以 `ConvertTo-Json` 轉成 JS 字串（不怕引號）。
     - 送出 4 秒後（點 Login 後 16 秒內沒出現密碼框時也一樣）以 `Open-PageUrl` 重新開啟原本網址再判斷一次：仍為 `PASSWORD`，或已嘗試自動登入但不是 `NONE` → **此頁失敗**（2026-11-03 起；舊版照常截下登入畫面當成正常結果送出）。沒設定帳密且是 `PASSWORD` 也判定失敗；沒設定帳密且只有 `LOGIN_BUTTON` 可能是允許訪客瀏覽的頁面，照常截圖。
     - 沒設定帳密（`Test-AuthConfigured`：`auth.enabled`、username 非空且不是 `YOUR_USERNAME`）時只寫提示、不點按鈕。
     - 已用本機模擬的 Zabbix 流程（提示頁 → Login → `#name` / `#password` / `#autologin` / `#enter` 表單 → 帶 cookie 回 charts.php）實測成功、帳密錯誤、未設定帳密三種情況；尚未對真正的 Zabbix 實測。
   - **第三層（防背景凍結）**：每次切換頁面與截圖前呼叫 `Page.bringToFront` 與 `Page.setWebLifecycleState({ state: "active" })`。
2. **精準區域截圖**：
   - `Save-RenderedPage` 有兩種來源模式：每頁有 `capture_view` 時先還原可視範圍及主文件捲動，以 `Page.captureScreenshot`（captureBeyondViewport=false、fromSurface=true、不帶 clip）截可視內容；舊設定未含此欄位時沿用完整文件擷取。先存 `<id>_full.png`（未裁切來源圖），再用 .NET Bitmap.Clone 裁切成 `<id>.png`，與前端 Canvas.drawImage 使用相同圖片像素座標。
   - **互動捲動擷取（2026-11-03）**：`Set-CaptureViewport -FitWindow` 最大化專用視窗、讀取實際可視尺寸，依縮放計算 CSS viewport 並套用顯示 scale，讓捲軸可操作，不再以大於實際視窗的固定範圍操作。登入、Zabbix now/7d 完成後，`Get-JsCaptureControls` 注入獨立 Shadow DOM 的「擷取目前畫面／取消」面板；按鈕先移除面板，`Wait-InteractiveCapture` 再取得選擇。**縮放防呆**：Edge 記住的網站縮放在啟動前清除（見下方 `Clear-RememberedZoom`），預設縮放由 `Set-CaptureViewport` 補償；之後以 `devicePixelRatio` 與 `zoom/100` 比對；只有套用後比例再變動才阻擋，面板提示「擷取期間網頁縮放已變更…請按「取消」後重新抓圖」。`Save-RenderedPage` 的 `Assert-NoManualZoom` 使用相同判定。
   - **設定 `pages[].capture_view = {width,height,x,y,zoom}`**：width/height 為可視範圍 CSS 像素，x/y 為主文件 scrollX/scrollY，zoom 為選擇時的百分比。排程每頁使用已存尺寸，載入及時間調整後 `Restore-CaptureScroll` 還原位置並等待該頁 wait_seconds，再核對尺寸與位置。無法還原或縮放已改但尚未重新抓圖時此頁失敗（見 3.1 第 4 點），避免默默擷取其他位置。crop_region 與警戒線均以可視來源 PNG 為基準。位置變更後前端重置裁切為整張並提示確認警戒線。
   - 互動預覽引擎透過 `<OutFile>.json` 回傳 capture_view 給本機 API，API 隨圖片回傳前端後刪除中繼資料。CLI 未帶 `-InteractiveCapture` 仍自動擷取完整主文件。
   - **每頁縮放與座標系（2026-11-04）**：`pages[].browser_zoom` 為 50～200 整數百分比，省略預設 100。`Set-CaptureViewport` 清除舊 Emulation 後讀取原生 DPR（啟動固定 `--force-device-scale-factor=1`），以 `deviceScaleFactor=factor/nativeZoom`、viewport 尺寸乘 `nativeZoom` 成對補償；互動顯示 scale 同樣使用補償值，pageScaleFactor=1。導航／登入後在目標頁重新套用，再等待圖表載入。重播讀回實際 CSS 尺寸，最多微調三次以處理 Chromium 整數取整與 DPR 浮點誤差；最終仍由 `Restore-CaptureScroll` 嚴格核對。互動抓圖以當時實際視窗為基準，排程以 capture_view 保存的 CSS 尺寸為準；無 capture_view 的舊設定才使用 1920×1080 基準擷取完整文件。完整文件模式以 `cssContentSize` 驗證輸出像素上限、`contentSize`（DIP）設定 CDP clip，避免原生縮放造成多餘空白或截短。`crop_region` 是來源 PNG 整數像素，不直接當成 CDP clip；超界或非整數時此頁失敗、不輸出該圖。
   - **視窗不留白**：抓圖與排程都最大化 Edge，`Emulation.setDeviceMetricsOverride`（首次與重播微調）一律帶 `dontSetVisibleSize=true`、`scale=factor/nativeZoom`，保留實際視窗內容區；不帶時 Edge 顯示區會被縮成 override 尺寸，右側與下方大片留白、擷取面板被裁切。只檢查 `fromSurface=true` 的 PNG 看不出這個問題，需另以 `fromSurface=false` 檢查實際視窗。排程的 CSS 尺寸與捲動位置使用 capture_view；換電腦或螢幕後應重新抓圖。
   - **清除記住的網站縮放（`Clear-RememberedZoom`）**：Edge 會依網站記住 Ctrl＋滾輪／加減號的縮放（`Default\Preferences` 的 `per_host_zoom_levels`），抓圖與排程記住的比例不同時，同一 capture_view 的 CSS 尺寸在不同原生縮放下無法精確重現（例如 80% 設定、原生 75% 時每 1 DIP = 1.33 CSS px）。`Capture-PagesNative` 在 `Stop-ProfileEdge` 之後、啟動 Edge 之前把每個 `per_host_zoom_levels` 物件換成 `{}`：以括號配對（略過字串）只替換該物件，其餘內容逐字保留；結果須能 `ConvertFrom-Json` 才寫入（UTF-8 無 BOM），寫入前備份為 `Preferences.e3bak`；已是空的不寫；任何錯誤只記警告並退回補償。edge_profile 是本工具專用，在 🔐 登入視窗調過的網站縮放會在下次抓圖或排程時被清除。預設頁面縮放（edge://settings）不清除，由補償處理。
   - **驗證**：隔離 Edge profile 與 loopback 網站實測，網頁縮放 67%／80%／100%／125% 時抓圖與排程的可視範圍及截圖尺寸一致；80% 時實際視窗右／下 0% 白色。以沙盒（主程式副本、暫存 edge_profile、loopback 網站）驗證 11 項：Edge 記住 75% 時面板不誤判、抓圖前已清除、capture_view 與乾淨 Edge 相同且逐像素一致、Preferences 仍有效並有備份；之後再讓 Edge 記住 75%，排程與模擬鎖定的 headless 排程重播仍逐像素一致。全新 profile 在 Entra 管理的筆電第一次抓圖時視窗可能尚未最大化（Edge 首次使用流程），第二次起正常，測試先暖機一次。
   - **`-PreviewCapture -PageId <id> -Url <url> -OutFile <png> [-PreviewZoom <50..200>] [-PreviewWaitSeconds <1..60>]`**：截單一頁完整文件（crop 停用），共用 `Capture-PagesNative` 的登入、防凍結、縮放、時間調整與整頁擷取。新增參數為當次預覽覆寫，省略沿用設定檔；與排程共用 Mutex（等 10 秒），錯誤寫入 `logs\preview_last.txt`。





3. **Zabbix 截圖前自動調整最近七天（2026-11-03）**：
   - `Capture-PagesNative` 在登入與載入等待之後、`Page.captureScreenshot` 之前呼叫 `Set-ZabbixRecentWeek`。網址路徑為 `screens.php` / `charts.php` 時啟用，其他報表維持原流程。`-PreviewCapture`、正式排程與真實網頁 `-NoSend` / `-DryRun` 共用此流程；`-TestSample` 不開網頁，不調整時間。
   - 依專案附帶的網站快取確認 `timeControl.timeline`、`CScrollBar.dom.right`（`navigateRight`）及 `#scrollbar_cntr .zoom a[zoom="604800"]`（`setZoom`）；透過 `Get-JsZabbixTimeStep` 執行 DOM 點擊，不依賴滑鼠座標。先重複點右側按鈕至 `timeline.now()` 與時間標籤 `(now)` / `(now!)` 同時成立，再點上方 Zoom 7d。下方導覽列的 7d 是移動時間，不可使用。已符合時間條件就略過點擊。
   - 每次輪詢重新取得元件，可處理 AJAX 更新及整頁重載；點擊用 `setTimeout` 延後，讓 CDP 先回覆。等待 `flickerfreeScreen` 無刷新、重試或載入錯誤，圖表圖片載入成功，時間標籤相差 604800 秒且與 timeline 一致，圖片 URL 的 `period=604800`，若有 `isNow` 則必須為 1。符合後持續觀察至少 `wait_seconds`（最少 1 秒）才截圖。
   - 每頁時間調整最多 180 秒、120 次點擊。點擊後時間沒有變化 15 秒，或元件版本不支援、時間／圖表無法確認時 `throw`，此頁失敗（不送圖，訊息中標示原因），不將舊區間當成正常結果。詳細原因寫在原有 log / `preview_last.txt`。
   - 驗證：已以暫存 Edge profile 與 loopback 模擬網站測試歷史時間、已在 now、已是 7d、AJAX 延遲與整頁重載、錯誤 7d 元件、缺少元件、舊圖片、刷新卡住、點擊無效、其他報表略過；公司 Zabbix 實機仍需確認。





4. **逐頁失敗處理與錯誤頁偵測（2026-11-03）**：
   - `Open-PageUrl`：`Page.navigate` 回傳 `errorText`（DNS、拒絕連線、逾時等）即失敗；舊版忽略此欄位，非 Zabbix 頁會截下 Edge 錯誤頁並配正常訊息送出，Zabbix 頁則等 180 秒逾時後整次中止、Teams 收不到任何訊息。
   - `Assert-PageLoaded`：載入等待後、Zabbix 調整前檢查 `location.href` 不是 `chrome-error://` / `edge-error://`，且 `performance.getEntriesByType('navigation')[0].responseStatus` 不是 4xx / 5xx（取不到狀態碼時不判斷）。
   - `Capture-PagesNative` 每頁包在 try/catch：失敗原因記在 `Failures[頁面id]` 並繼續下一頁，回傳 `@{ Files; Failures }`。`-PreviewCapture` 有失敗時 `throw` 該原因（寫入 `preview_last.txt` 供設定工具顯示）。整個截圖流程無法開始（例如 Edge 啟動失敗）時，主流程把每頁都標為失敗。
   - 主流程：失敗頁不送圖，該發送對象的訊息改為異常，列出「⚠️ 頁面名稱 截圖失敗，本頁圖片未附上，請檢查：原因」（與警戒線超標訊息同一份清單，排在其後），其他頁照常送出；有任何失敗頁時 exit code 1。
   - 本機以沙盒（主程式副本、loopback 網站、沙盒內 edge_profile、`-NoSend`）實測：拒絕連線、HTTP 404、帳密錯誤的登入頁三頁失敗、一頁正常，訊息正確列出三個原因且正常頁照常截圖（4 頁共約 28 秒，停機的 Zabbix 網址不再等 180 秒）；`-PreviewCapture` 對停機網址回傳原因；空白總結文字改用預設文字；`Send-GroupToTeams` 收到空白文字時在碰 Teams 前停止。公司網站與 Teams 實際送出尚待部署後確認。
   - `Assert-PageLoaded` 另要求 `location.href` 為 http(s)：Edge 內部頁面（例如全新設定檔在組織管理電腦上的「設定您的設定檔以存取組織資源」首次使用頁，沙盒測試開新分頁時曾蓋掉目標網頁）判定此頁失敗，不會被截圖送出。
   - **CDP 逾時與重新連線**：`Invoke-CdpCommand` 預設 60 秒（`-TimeoutSeconds`，以 `CancellationTokenSource` 同時限制 Send/Receive；收到 Close 訊框即失敗），逾時訊息「Edge 沒有回應（方法 超過 60 秒）」。.NET 取消 `ReceiveAsync` 會中止該 WebSocket，因此下一頁開始前若 `$ws.State` 不是 Open，`Connect-CdpPage -NewTab` 以 `PUT /json/new?about:blank` 開新分頁、`/json/close/<id>` 關閉舊分頁（由瀏覽器程序處理，不經過卡住的網頁）再連線；重連同一分頁的話卡住的網頁仍不會回應。`Connect-CdpPage` 也負責啟動時的連線（ConnectAsync 15 秒逾時，Page/Runtime.enable、bringToFront、setWebLifecycleState）。注意 PowerShell 5.1 的 `Invoke-RestMethod` 把 JSON 陣列當單一物件輸出，取分頁清單時須經管線展開（`@(... | ForEach-Object { $_ })`）。實測：第 1 頁網頁無限迴圈 → 60 秒後此頁失敗、開新分頁，同網站與其他網站的第 2、3 頁都正常截圖（整輪約 80～90 秒）。





### 3.2 昨日區間警戒線像素高度判定 (`Test-CurvePixel` in `e3_monitor_native.ps1` & `calibrator.html`)
1. **座標定義**：
   - 每個小圖表規則定義一個 `roi: { x, y, w, h }`（框住該圖表最右側「昨日區間」的完整高度範圍）以及一條水平警戒線 `threshold_y`。
   - 圖片座標系左上角為 `(0, 0)`，因此位於警戒線上方的超標區域為 `roi.y <= y <= threshold_y`。
2. **像素顏色過濾 (`color_mode`)**：
   - `auto`（預設）：自動排除高亮度低飽和度的灰白背景與格線（`lum > 206 && sat < 28`），並排除 Zabbix 7天圖表特有的垂直粉紅日期分隔虛線（`r > 200 && (r - g) > 15 && g > 160 && b > 160`），僅針對真正的數據曲線像素計數。
   - `custom`（滴管指定顏色）：計算像素與指定曲線顏色 `target_color` 的 RGB 歐氏距離，距離 `<= color_tolerance` 視為曲線像素。
3. **判定門檻與輸出**：
   - 當警戒線上方的曲線像素點數 `>= min_pixels`（預設 `2` px）時判定為 **「🚨 超過警戒線」**，自動將該規則的 `alert_message` 加入異常清單，並在 `annotated_<page_id>.png` 畫上紅框備查；若全部正常則輸出 `normal_summary`；`normal_summary` / `abnormal_header` 空白時引擎使用 `$DefaultNormalSummary`（`目前E3系統正常`）/ `$DefaultAbnormalHeader`（`⚠️ 系統異常通知：`），與 calibrator 預覽相同（2026-11-03 前引擎送出空字串，與預覽不一致；且排程沒有 title 時 `Clipboard.SetText("")` 例外，已貼上的圖片留在輸入框成為草稿，下次排程再因「已有草稿」停止）。`Send-GroupToTeams` 在找 Teams 視窗前先檢查文字非空白。





### 3.3 Teams 對話定位與分流發送 (`Send-GroupToTeams` in `e3_monitor_native.ps1`)
> 2026-11-02 改版：公司環境的 Teams 是 **Edge 安裝的 PWA**（或直接在 Edge 分頁開 `teams.cloud.microsoft`），沒有桌面版可接 `msteams:` 連結；舊的 `edge_teams_web` 要在專用 `edge_profile` 另外登入 Teams。因此改成「使用已經開著、已經登入的 Teams」。`teams.send_mode`、`desktop_window_title`、`auto_switch_chat` 已不再使用（舊 config 留著無妨）。





1. **不使用 Workflow／Webhook**：只操作 Teams（視窗或 CDP 背景傳送）；儲存 API 與設定工具載入時會清除舊版 `delivery_method`、`webhook_targets`、`webhook_url` 欄位，避免舊設定重新帶入網址。
2. **發送對象 = 對話名稱**（`Resolve-ChatTarget`）：填 Teams 聊天清單上顯示的名稱；`自己` / `self` / 含 `48:notes` 的舊連結 = 自己的個人對話（名稱以 `(您)` / `(You)` 結尾）。其他連結 (`http(s):` / `msteams:`) 與 Email 直接 `throw`（設定工具 `targetProblem()` 同步顯示 ⚠️ 並阻擋 🚀）。
3. **找 Teams 視窗**（`Get-TeamsCandidates` / `Find-TeamsWindow`，順序 `$TeamsKinds` = `pwa` → `desktop` → `edge-tab`；`teams.prefer_window` 指定時只找該種）：
   - `pwa`：程序 `msedge`、標題含 `Microsoft Teams`、且標題**不以** `Microsoft Edge` 結尾（`$EdgeSuffix`，中間可能有 U+200B）。不限定結尾，因 Edge 可能在前面加「應用程式名稱 - 」。**尚未在真正的 PWA 上實測**。
   - `desktop`：程序 `ms-teams`（新版）/ `Teams`（舊版）。
   - `edge-tab`：一般 Edge 視窗中 Name 含 `Microsoft Teams` 的 `TabItem`；找到後 `SelectionItemPattern.Select()` 切成目前分頁。分頁名稱會帶「- 已捨棄 - 記憶體使用量 …」等後綴（睡眠分頁）。
   - `Get-EdgeTabs` 只用 `ControlViewWalker` 走瀏覽器外框、**跳過 `Document` 子樹**：目前分頁是 Teams 時，對整個 Edge 視窗 `FindAll(Descendants)` 會走完 Teams 網頁的協助工具樹，實測卡住超過 1 分鐘。
   - 都沒開時 `Open-TeamsApp`：開始功能表 / 桌面最上層的 Teams PWA 捷徑（參數含 `--app-id`）→ `msteams:`（有註冊時）→ `msedge <TeamsWebHome>`；有 `prefer_window` 時只開該種，開不了就 `throw`。開啟後等 20 秒載入。`Find-TeamsPwaShortcut` 桌面不遞迴（桌面常被導向 OneDrive / 網路磁碟，實測遞迴要 70 秒以上）。
4. **切換對話**（`Open-TeamsChat`）：最多等 30 秒讓 Teams 畫面載入（喚醒睡眠分頁）→ 不在聊天畫面時點左側「聊天」（`Find-TeamsChatNav`）→ `Find-ChatListItem` 在 `TreeItem` 中找名稱（可往下捲 10 頁；找不到且還沒點過「聊天」時，點「聊天」後再找一次）→ 點選 → 等視窗標題變成該對話。
   - **2026-11-03 對話清單比對修正**：`Get-ChatItemFilter` 的正規表示式必須寫成 `^${ChatPrefix}?`。原本 `^$ChatPrefix?` 被 PowerShell 解讀成名為 `ChatPrefix?` 的未定義變數，造成「聊天／群組聊天／Chat」可選前綴消失；即使目標在清單內，帶前綴的 UIA 名稱仍會比對失敗。修正保留對話名稱的 regex escaping，以及點擊後的完整標題確認。
5. **以視窗標題確認對話**（`Get-ChatNameFromTitle` / `Test-ChatTitle`）：標題格式「聊天 | 對話名稱 | 組織 | … | Microsoft Teams」，PWA 可能有前綴「… - 」，Edge 分頁有後綴「 和其他 N 個頁面 - 設定檔 - Microsoft Edge」；英文介面為「Chat | …」。取出的對話名稱必須與設定**完全相同**（避免「E3」誤認「E3 乖乖」）；自己 = 名稱以 `(您)` / `(You)` 結尾。
   - **2026-11-03 未讀數量支援**：聊天類型前接受可選的 `(數字)`，例如使用者回報的 `Microsoft Teams (PWA) - (1) 聊天 | AI coding 討論群組 | Microsoft Teams`。只忽略聊天類型前的未讀數量，不刪除對話名稱中的括號或 `(您)`。適用於切換前後、每次貼上／Enter 前、等待圖片期間及送出確認。
6. **貼上與送出**：
   - **前景**（`Set-WindowForeground`）：縮小時 `ShowWindow(SW_RESTORE)`，再以「按放 Alt + `AttachThreadInput` + `SetForegroundWindow`」突破前景鎖定，並以 `GetForegroundWindow()` 驗證。
   - **輸入框**（`Find-TeamsComposeBox` / `Set-TeamsComposeFocus`）：UI Automation 找 `ControlType.Edit` 且 `AutomationId` 為 `new-message-*`（或 Name 為「輸入訊息 / Type a message」）→ `SetFocus()`，未取得焦點時點擊。Chromium / WebView2 的協助工具樹需先 `FindAll(TrueCondition)` 喚醒，每 4 次重試做一次完整查詢。
   - 開始前若輸入框已有草稿（`Get-ComposeState`：圖片 = Name「影像 / Image」的按鈕，文字排除提示字與 U+2060 等不可見字元）就停止。
   - 圖片以剪貼簿逐張貼上（每 4 張一批），等該批圖片全部出現在輸入框（最多 90 秒）→ 每批貼總結文字與失敗清單並確認有文字 → Enter → 確認輸入框清空。
   - **防貼錯**（`Confirm-TeamsReady`）：每張圖、文字、Enter 之前確認前景仍是 Teams 且標題仍是目標對話；等待期間被切走也停止。失敗即 `throw`（exit 1）。
   - **逐個對話發送（2026-11-03）**：主流程對每個發送對象各自 try/catch 呼叫 `Send-GroupToTeams`；一個對話失敗只記在 `$sendFailures`、exit code 1，繼續送下一個對話，最後列出「共有 N/M 個對話沒有送出」。舊版 catch 在整個 foreach 外，第一個對話失敗後面的對話都不送。失敗對話若已貼上圖片，草稿留在該對話，不影響其他對話（下一次排程該對話會因草稿停止，需人工清除）。已用替身函數實測 A 對話失敗、B 對話照常送出。
   - `-DryRun` / `auto_press_enter=false`：停在目標對話不送出；正式送出後切回原本的對話。
   - `Add-Type` 失敗（公司封鎖編譯器）時無法操作視窗，直接 `throw`。
7. **偵測模式 `-DetectTeams`**（設定工具 🔍 → `POST /api/teams-detect`：先存 config，再以 `$PSCommandPath -DetectTeams` 執行並回傳 `logs\teams_detect.txt`）：列出所有 Teams 候選（不切換分頁）、所有 msedge / ms-teams 視窗原始標題（PWA 沒被認出時回報用）、PWA 捷徑、`msteams:` 是否註冊；對「發送時會使用」的視窗檢查目前對話、輸入框、聊天清單項目數，以及預設與各啟用排程的發送對象是否在清單畫面上。Edge 分頁不是目前分頁時不檢查畫面內容。本機約 4 秒。
8. **CDP 背景傳送（`teams.prefer_window = "cdp"`，`teams_cdp\Delivery.ps1`）**：
   - **目標**：Windows 保持登入即可，鎖定、螢幕關閉時排程照常「開 Edge 截圖 → 傳到 Teams 群組」。不使用系統剪貼簿、SendKeys、滑鼠或前景視窗；`Send-GroupToTeams` 在最前面分派到 `Send-GroupToTeamsCdp`，主流程對 CDP 不呼叫 `Wait-TeamsDesktop`。
   - **為什麼用背景 (headless) Edge**：鎖定後有畫面的 Edge 視窗會被視為遮蔽，Chromium 停止送出畫格，`requestAnimationFrame` 不跑，Teams（React）介面會停住；headless 不畫在桌面上，鎖定與否行為一致（截圖在鎖定時同樣用 headless）。每次傳送才啟動、送完以 `Browser.close` 正常關閉，不需要保持分頁開啟，也沒有常駐的除錯埠。
   - **一批 = 一則訊息**：與 PWA／Edge 分頁／桌面版相同，共用 `teams_delivery.ps1` 的 `Split-TeamsImageBatches`（每批最多 4 張、合計 25 MiB）與 `Get-TeamsBatchText`。同一批圖片逐張貼進同一個輸入框、再輸入文字，只按一次「傳送」，所以 4 張圖＋文字是一則訊息；超過 4 張才分成多則，每則都帶同一段文字與「（第 N/M 批）」。設定工具右側預覽同樣一批畫一則。
   - **profile**：與截圖共用 `edge_profile\`（一次登入）。`Start-TeamsCdpBrowser` 先 `Stop-ProfileEdge`，以除錯埠 9334 啟動；headless 時把 `Browser.getVersion` 的 UA 中 `HeadlessEdg`/`HeadlessChrome` 換回一般字串並 `Emulation.setUserAgentOverride`（避免 Teams 視為不支援的瀏覽器），`Emulation.setFocusEmulationEnabled`，`Runtime.disable` 減少事件。`teams.cdp_headless=false` 改用顯示視窗（鎖定時行為未驗證）；`teams.cdp_url` 預設 `https://teams.cloud.microsoft/`（測試時指向模擬網站）。
   - **網頁內操作**（`$CdpTeamsJs` 注入 `window.__e3t`，換頁後重新注入）：選擇器取自實際 Teams 協助工具樹（唯讀檢查本機新版桌面 Teams，與網頁版同一套程式）：輸入框 `[id^="new-message-"]`（contenteditable，aria-label「輸入訊息」）、左側 aria-label 以「聊天 / Chat」開頭的按鈕、聊天清單 `[role="tree"]` 內的 `[role="treeitem"]`、aria-label 以「傳送 / Send」開頭的按鈕（實際為「傳送 (Ctrl+Enter)」）。登入頁以網域 `login.microsoftonline.com` 等或「有密碼框且沒有聊天介面」判斷；Teams 啟動頁的「改用網頁版」會自動點選。
   - **對話定位**：與桌面 UIA 相同的「名稱 + 標題完全相同」規則，`document.title` 格式即視窗標題，直接沿用 `Test-ChatTitle` / `Get-ChatNameFromTitle`（含未讀數 `(1)`、`(您)`）。`findChat` 先找「項目文字第一行 = 對話名稱」或 aria-label 完全符合（避免 `^…名稱(\s|$)` 讓「E3 測試群組」點到排在前面的「E3 測試群組 乖乖」——桌面 UIA 版同樣有此弱點，靠標題確認才擋下但會停止發送）；整份清單（最多捲 10 頁、虛擬清單只畫可視範圍）都沒有完全相同時，第二輪才接受前綴比對，最後仍以標題確認。
   - **貼上與送出**：先驗證全部 PNG（存在、PNG 檔頭）再開 Teams；`Split-TeamsImageBatches` 分批。每張以 `DataTransfer` + `ClipboardEvent('paste')` 貼到輸入框、等圖片數增加（60 秒）；整批圖片 `complete && naturalWidth>0` 連續 3 次才繼續（90 秒）；文字每行 `Input.insertText`，行間 `Input.dispatchKeyEvent` Shift+Enter（帶 `text:"\r"`，Teams 的 Enter 會直接送出）；點「傳送」按鈕，找不到或停用時送 Ctrl+Enter；30 秒內輸入框清空才算送出，再於聊天記錄比對第一行文字的出現次數（排除輸入框本身）增加為「已在聊天記錄看到」，否則記錄「輸入框已清空、聊天記錄未讀到」。每一步前確認標題仍是目標對話。開始前有草稿就停止；任何失敗 `throw`，由主流程記入 `$sendFailures`，不重送。`-DryRun` 只開啟對話確認輸入框；`auto_press_enter=false` 貼上不送出。
   - **檢查與登入**：`Test-E3CdpConnection`（`-DetectTeams`、🔍 檢查 CDP 連線）背景開啟 Teams，回報登入與每個發送對象（`Get-CdpTargets`：預設、啟用排程、舊版頁面層級）是否找得到、輸入框是否空白，不貼上。`Set-E3CdpBinding`（`-CdpSetup`、`setup_cdp.bat`、`POST /api/cdp-setup`）顯示 Edge 讓使用者登入 Teams 網頁版，按 Enter 後檢查發送對象，再確認 headless 能沿用登入；不寫任何設定檔。兩者以 `Local\E3MonitorNativeRun` 互斥，等 10 秒拿不到即提示排程正在使用。`-CdpSetup` 區塊必須放在所有函數定義之後（模組共用主程式的函數）。
   - **`Invoke-CdpCommand` 調整**：收到訊息先以字串比對 `"id":N,` / `"id":N}`，不符就略過，不對每個網頁事件 `ConvertFrom-Json`（Teams console 事件量大）。
   - **驗證**：以本機模擬 Teams（登入頁 + 持久 cookie、聊天按鈕、虛擬清單、名稱相近、草稿、上傳延遲、Enter 送出／Shift+Enter 換行、拒絕 Headless UA）與沙盒主程式執行：未登入、登入後檢查、5 頁分 2 批（4+1，文字含換行與批次序號）、DryRun 不送、傳給自己、清單下方需捲動、草稿與找不到時不送、模擬鎖定（headless 截圖 + CDP 傳送且不等待解鎖），以及約 6 MiB 大圖原大小送達（約 19 秒），共 16 項全部通過；`-CdpSetup` 以輸入管線模擬 Enter 測試通過。**尚未在公司真實 Teams 驗證**：選擇器、貼圖是否被 Teams 接受、headless 下公司登入（條件式存取、SSO）能否沿用，都需使用者驗收。





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
- **存檔前驗證（2026-11-03）**：`/api/save`、`/api/test-teams`、`/api/register-schedules`、`/api/teams-detect` 一律經 `Save-ConfigBody`：可解析且含 `pages` 陣列才寫入，先寫 `config.json.saving` 再 `File.Replace` 整檔取代（失敗時改 Copy），格式不對回 400 `{ok:false,error}` 且不執行測試 / 註冊 / 偵測；前端對 400 顯示「❌ 儲存失敗：原因（config.json 沒有變更）」並以 `lastSavedJson` 停止對同一內容每秒重試，不再誤報成「本機服務沒有回應」。
- **config.json 格式錯誤時（2026-11-03）**：前端 `initApp()` 以 `resp.text()` + `JSON.parse` 讀取，解析失敗（瀏覽器 `JSON.parse` 比 PowerShell 嚴格，例如不接受 NBSP）時顯示「❌ config.json 格式錯誤，無法讀取（行列位置）」橫幅、狀態「❌ config.json 格式錯誤」並停用自動儲存，不再顯示成「無法自動儲存 / 服務沒開」。引擎讀取失敗時 `-Calibrator` 仍啟動服務（`$config = $null`，孤兒圖清理自動略過），其他模式寫「❌ config.json 格式錯誤，無法讀取」並 exit 1。
- **抓圖不阻塞服務**：HttpListener 是單執行緒；舊版 `/api/capture-url` 以 `Start-Process -Wait` 等使用者最多 10 分鐘，期間自動存檔、排程狀態、偵測都卡住。現以 `$captureJob` 保存背景程序（取 `$proc.Handle` 才能在結束後讀 `ExitCode`）。已用沙盒實測：抓圖請求 0.3 秒回應、等待期間存檔 0.1 秒完成、重複抓圖被拒、完成後前端取得圖片與 capture_view、等待期間的設定修改沒有被覆蓋。
- 本機服務（`-Calibrator`）單一請求例外時回 500 並繼續服務（舊版 `catch { break }` 會讓整個服務靜默結束，之後所有儲存都失敗）。服務內呼叫主程式其他模式一律用 `$PSCommandPath` 另開 powershell（抓圖、測試、註冊、登入），避免阻塞或污染服務程序。`-NoBrowser` 不自動開瀏覽器（截圖工具 / 測試用）。`-ConfigPath` 預設為主程式同資料夾的 `config.json`。
- **本機服務安全限制**（舊版送 `Access-Control-Allow-Origin: *`，任何網頁都能讀 config 密碼、改設定、觸發 Teams 發送與註冊排程）：
  - 不送任何 CORS 標頭；帶有 `Origin` 且不是 `http://127.0.0.1:8765` 的請求與所有 `OPTIONS` 一律 403（沒有 `Origin` 的本機程式呼叫照常允許）。
  - 靜態檔白名單：`calibrator.html`、`sample_data.js`、`USER_MANUAL.html`、`sample_images/*.png`；`config.json` 只能經 `/api/config` 讀取。
  - 因此 calibrator 在 `file://` 偵測服務時用 `fetch(..., {mode: "no-cors"})`（只確認有沒有回應）。
  - 所有回應帶 `Cache-Control: no-store`，避免更新 calibrator.html / 手冊 / 截圖後瀏覽器仍顯示舊版。
- **警戒線框超出圖片**：`evaluateRule()` 回傳 `outOfRange`，清單顯示「⚠️ 超出圖片範圍」且不計入超標（圖外像素讀成黑色會誤判）；引擎同樣略過該條並寫 log，不再因 `GetPixel` 例外讓整次執行失敗。
- **沒有圖的頁面**：不再拿 `page1` 範例圖代替；畫布顯示「這一頁還沒有畫面」提示圖（`isPlaceholder`，不評估警戒線、預覽顯示提醒）；`-TestSample` 也直接略過該頁並提醒先 📸 抓圖。
- 切換到沒有整頁圖的頁面時，✂️ 工具自動改回 📏；🗑️ 刪除頁面會先確認。
- **兩張圖模型**：`fullImages[id]`（未裁切的來源圖，互動抓圖時為所選可視畫面）與 `pageImageCanvases[id]`（依 `crop_region` 從來源圖裁切 = 排程實際送出的圖）。保留 `_full.png` 檔名以相容既有載入流程，不代表一定是整份網頁。
  - 左側「網頁縮放」（2026-11-03 起為 `#pageBrowserZoom` 數字輸入框 + `#pageZoomPresets` 常用比例按鈕 50/67/75/80/90/100/110/125/150/175/200，與 Edge 級距相同）控制每頁實際渲染；`setBrowserZoom()` 只接受 50～200 整數（與引擎 `Get-BrowserZoom`、`/api/capture-url` 檢查一致），範圍外或小數提示後以 `renderBrowserZoom()` 還原。67% 已用暫存 Edge 實測抓圖與排程還原的可視範圍及截圖尺寸一致。上方「畫布預覽」的符合寬度／100%／200%／300% 僅改預覽大小。`getCanvasCoords` 按 bounding rect 與 canvas 實際像素尺寸換算，避免 CSS 四捨五入及捲動造成座標偏差。更改網頁縮放後須重新抓圖、框選與確認警戒線。
  - **✂️ 擷取範圍** 工具顯示整頁圖與擷取框，拖曳即改 `crop_region`；其他工具顯示裁切後的圖，警戒線 ROI 座標以裁切後的圖為準（與引擎一致）。
  - 裁切結果經 `/api/save-sample` (kind=crop) 自動寫回 `sample_images\<id>.png`，`-TestSample` 與下次開啟都用同一張圖；🖼️ 載入截圖 以 kind=full 寫回 `<id>_full.png`。
  - 開啟時若有 `<id>_full.png` 即以它為準重新裁切；沒有則退回舊的 `<id>.png`（此時 ✂️ 會提示先 📸 抓圖）。
  - 📸 抓圖的 capture_view 改變時重置 crop_region 為整張來源圖；位置與可視尺寸相同則保留裁切，超出新圖時才改為整張。須重新確認警戒線。
  - 擷取範圍改變不會自動平移既有警戒線 ROI。
  - **範例圖清理（2026-11-03）**：同一頁的 `<id>.png` / `<id>_full.png` / `annotated_<id>.png` 本來就是覆蓋寫入。🗑️ 刪除頁面時前端清掉記憶體中的圖並呼叫 `POST /api/delete-sample {pageId}`（id 需符合 `^[A-Za-z0-9_-]+$`），刪除 `Get-SampleImagePageId` 判定屬於該頁的檔案（含 `tmp_<id>_full.png(.json)`）。`-Calibrator` 啟動時以 `Remove-OrphanSampleImages` 刪除不在 `config.pages` 的頁面圖（設定讀不到任何頁面時不刪）；因此 `sample_images\` 內任何 `.png` 都視為頁面圖，不可放其他圖片。`tools\_demo_config.json` 的 page1～5 與 `make_screenshots.ps1` 產生的範例圖一致，不受影響。`-PreviewCapture` 結束後刪除 `%TEMP%\e3_preview_capture`。
- 右欄以「預覽哪個排程」選單為準，顯示該排程實際送出的圖片、標題、訊息、發送對象（與引擎相同的優先順序）；每 4 張圖片＋同一段文字畫成一則訊息，超過 4 張時分成多則並在文字後加「（第 N/M 批）」，與實際送出一致。
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
   - `-RegisterSchedules`：依 config 註冊/更新每個啟用排程，並移除已刪除/停用的 `E3_Monitor_*` 任務與舊版 `E3_Daily_Monitor_Teams`。以目前使用者「僅登入時執行 (Interactive)」註冊，不保存 Windows 密碼、不切換 SYSTEM。任務設定：`WakeToRun` 要求喚醒、`StartWhenAvailable` 錯過後補跑、電池模式也執行、上限 2 小時、`IgnoreNew` 不重複啟動；不加整次任務自動失敗重試，以免部分成功後重送。更新失敗時保留原任務並回報失敗。喚醒受硬體、供電、公司電源政策限制，無法保證關機／睡眠期間準時執行。
   - `-ListSchedules`：列出排程與頁面。
3. **企業環境防護**：
   - **鎖定／遠端斷線恢復測試版（2026-11-04）**：`Get-DesktopBlockReason` 以 WTS 目前工作階段狀態與 input desktop 名稱判斷，未知狀態視為不可操作。正式 `-Schedule` 發現桌面不可用時呼叫 `Capture-PagesNative -Headless`，仍使用原 profile、已保存的 CSS viewport、縮放、捲動與裁切；互動抓圖不允許 headless。發送前 `Wait-TeamsDesktop` 每 5 秒檢查、每分鐘記錄，共用第一次等待起算的 30 分鐘截止時間，恢復後發送已保存的圖。逾時 exit 1，圖仍保留；不是永久佇列，程序被結束後不會自動補送。貼圖途中桌面失效時停止、不重試整批，須檢查草稿與已送訊息。
   - 排程持有執行 Mutex 後要求 `ES_CONTINUOUS | ES_SYSTEM_REQUIRED`，在 finally 解除，降低執行期間自動睡眠；不禁用鎖定、不改電源計畫、不繞過遠端／公司安全政策，不能阻止手動睡眠、登出或斷電。
   - `/api/schedule-status` 回傳 `wake`／`catch_up`，介面遇到舊任務提示「尚未套用喚醒／補跑設定」，使用者需按「🔄 重新套用」更新 Windows 任務。只更新檔案不會自動改動已註冊的任務設定。實際遠端軟體、主機喚醒與 Teams 恢復貼圖待使用者驗收。
   - 具名 Mutex `Local\E3MonitorNativeRun`：兩個排程時間重疊時依序執行（共用 `edge_profile`、Teams 視窗與剪貼簿），最多等 30 分鐘。
   - **Edge 正常關閉（2026-11-03）**：截圖流程在 `finally` 透過既有 CDP 連線由 `Close-CaptureBrowser` 送出 `Browser.close`（送出上限 3 秒，不等關閉回覆），等 2 秒後釋放連線，再執行 `Stop-ProfileEdge`。後者只處理命令列含本專案 `edge_profile` 的程序，先要求關閉視窗、最多等 5 秒，逾時才強制清理並記錄警告；不影響日常 Edge（包含 Teams PWA / Teams 分頁）。舊版每次截圖後直接 `Stop-Process -Force`，造成 profile 記錄 `exit_type: Crashed`，下次啟動彈出「還原頁面：Microsoft Edge 意外關閉」。截圖啟動參數加入 `--hide-crash-restore-bubble` 抑制前次異常退出提示，不修改既有登入資料。已用隔離的暫存 profile 連續兩次執行本機 `about:blank` 截圖，均產生 PNG 且退出狀態為 `Normal`；公司主機待驗證。
   - `Wait-CdpTargets`：輪詢 CDP 埠最多 20 秒（防毒掃描導致 Edge 啟動慢）。
   - `Start-Transcript` 寫入 `logs\`，背景排程無視窗時可追查。
   - **截圖保留 7 天（2026-11-03）**：每次主流程執行（排程、`-TestSample` 等）在 transcript 開始後，刪除 `captures\` 下名稱為 `yyyy-MM-dd` 且日期早於「今天 − `$CaptureKeepDays`(7) 天」的資料夾（依名稱日期，不看修改時間；第 7 天當天保留；非日期名稱的資料夾與檔案不動）。舊版從不清理，每次排程新增一個資料夾。已用沙盒實測：0/3/7/8/30 天前的資料夾只刪除 8 與 30 天前。





---





### 3.6 精簡部署（開發機只放必要檔案）
- **必備 5 個檔案**：`open_calibrator.bat`、`calibrator.html`、`e3_monitor_native.ps1`、`teams_delivery.ps1`、`config.json`（2026-11-04 起主程式啟動即 dot-source `teams_delivery.ps1`，缺檔時連設定工具也無法開啟）。使用「CDP 背景傳送」另需 `teams_cdp\Delivery.ps1`（UTF-8 with BOM）與 `setup_cdp.bat`。路徑不限 `C:\TEST`（腳本皆以 `$PSScriptRoot` / `%~dp0` 定位），但需放在同一資料夾。2026-11-01 已移除 `server.ps1`（併入 `-Calibrator`）、`login_setup.bat`（→ 設定工具 🔐 按鈕）、`test_to_my_teams.bat`（→ 🧪 / 🚀 按鈕）、`register_schedule.bat`（→ 自動同步 / 🔄 重新套用）、`run_daily.bat`（Windows 排程直接呼叫主程式；手動補跑用 `schtasks /Run`）。
- **自動產生、不需複製**：`edge_profile\`、`captures\`、`logs\`、`sample_images\`（📸 抓圖後重建）。
- **選用**：`USER_MANUAL.html`（📖 手冊，圖片已內嵌）、`sample_data.js`（缺檔時 `window.SAMPLE_IMAGES` 為空，calibrator 照常運作；但 `tools\make_screenshots.ps1` 需要它）、`CLAUDE.md`、`tools\`（只供維護）。
- **檔案編碼（2026-11-03 修復）**：`e3_monitor_native.ps1`、`teams_delivery.ps1`、`teams_cdp\Delivery.ps1` 必須是 **UTF-8 with BOM**（PowerShell 5.1 沒有 BOM 時以系統代碼頁 950 讀取，中文字串會造成上百個解析錯誤，整支程式無法執行）；其餘檔案 UTF-8 無 BOM 即可。不可含 U+00A0（不換行空白）：瀏覽器 `JSON.parse` 不接受 config.json 中的 NBSP，CSS 選擇器帶 NBSP 會整條失效。程式中的零寬字元一律以 regex 跳脫（`\u200B`、`\u2060`）表示；文件中也只寫跳脫文字，不要貼上實際字元（2026-11-04 傳回時本句的實際字元已被吃掉），不要放實際字元。曾因以複製貼上（Teams / Outlook / 網頁）在公司與開發機之間傳檔而三者同時發生；請以附件或 zip 傳檔。
- **`.bat` 檔只能用 ASCII（英文）**：cmd 以系統代碼頁 (950) 讀批次檔，`chcp 65001` 之後的中文行會被錯位解析，與下一行黏在一起（症狀：「'亂碼…powershell' 不是內部或外部命令」）。中文說明一律寫在 PowerShell 腳本或手冊裡。
- **新增檔案時**：若執行時必須存在，需同步更新本節、手冊「8-1 必備與可刪除的檔案」，以及主程式 `-Calibrator` 區塊的靜態檔白名單（若需由瀏覽器載入）。
- Windows Server 可執行截圖與判斷；操作 Teams 視窗仍需登入且解鎖。未安裝 Teams 桌面程式可用 Edge Teams 網頁版（公司允許登入時）；一般聊天網址不是上傳端點。Bot／Graph 或專用無人值守 RPA 需公司核准與另行整合，不能保證不受資安政策限制。





## 4. 常用維護與操作流程





> 完整的使用者操作步驟（含測試發送到自己的 Teams、新增網頁擷取範圍與警戒線、測試檢查清單）請見 **`USER_MANUAL.html`**；本節只列重點。





1. **開啟設定工具**：雙擊 `open_calibrator.bat`（自動開啟瀏覽器；所有修改自動儲存）。
2. **首次綁定網站登入狀態**：設定工具 ⚙️ 全域設定 → 🔐 登入監控網站，在彈出的 Edge 登入後關閉即可保存至 `edge_profile\`。
3. **測試發送到自己的 Teams**：先開好並登入 Teams（PWA / Edge 分頁 / 桌面版）→ 📅 排程與發送 → 📨 先傳給自己測試 → 🔍 偵測 Teams 視窗 → 右欄 🧪 測試貼上（不送出）/ 🚀 正式送出…。
4. **排程**：在「📅 排程與發送」新增 / 修改時段，自動同步到 Windows（第一次使用按 🔄 重新套用）。手動補跑：`schtasks /Run /TN E3_Monitor_<id>`，或 `powershell -File e3_monitor_native.ps1 -Schedule <id>`。
5. **執行紀錄**：`logs\`。





---





## 5. 已知限制





1. **網頁版面隨縮放與內容變化**：互動抓圖保存主文件 viewport 與 scroll，排程還原它們；舊設定沿用整頁流程。更改縮放、網址或版面後須重新抓圖並框選、確認警戒線（不自動平移 ROI）。不保存 iframe／表格內部獨立捲軸，也不重演任意點擊與延遲載入流程，建議使用報表直接網址。請在頁面資料載入後按擷取；互動期間重新整理／跳轉會停止，需重新抓圖。圖片上限單邊 16384 像素、總計 6400 萬像素。
2. **📸 抓圖會短暫開啟 Edge 視窗**（非 headless），排程在桌面不可用時則以 headless 共用擷取流程。兩者都會關閉其他使用 `edge_profile` 的 Edge（例如未關閉的 🔐 登入用視窗）。
3. **`-TestSample` 使用 `sample_images\<pageId>.png`**，缺檔的頁面會略過；該檔由 calibrator 在 📸 抓圖 / 框選後自動產生，從未抓圖的頁面才會缺檔。
4. **Teams 視窗發送需互動桌面且 Teams 要開著**：鎖定時即使 Teams 還在執行，也不能貼圖。排程會先背景擷取、等待桌面恢復（最多 30 分鐘），逾時失敗；一般手動測試及貼圖途中鎖定會停止。等待恢復的圖片是當次擷取資料，可能晚於原排程時間送到；系統睡眠期間沒有程式在執行，恢復後補跑取得的是恢復當時的網頁資料。不能保證所有電源／登入狀態下即時發送。執行期間會佔用系統剪貼簿、拉到前景及操作滑鼠。Teams 改版仍可能影響 UI Automation 定位，需依偵測紀錄調整。
5. **PWA 實測範圍**：使用者提供的 2026-11-03 公司執行紀錄已確認可辨識 PWA、切到前景，且先前已有貼圖送出成功紀錄。15:27 回報從其他群組切換時失敗，本次修正聊天清單前綴與 `(1)` 未讀標題；修正版跨對話切換尚待公司驗證。PWA 仍依「msedge 視窗、標題含 Microsoft Teams、不以 Microsoft Edge 結尾」判斷，若標題格式再變動，依 `-DetectTeams` 的原始標題調整。
6. **以名稱找對話**：名稱必須與 Teams 顯示的完全一致（群組改名要同步修改）；沒有命名的群組，聊天清單與標題顯示的成員名單可能不同而無法確認。聊天清單最多往下捲 10 頁。
7. **網頁登入帳密以明文**存在 `config.json` 與瀏覽器 `localStorage`（`e3_monitor_config_v1`）。
8. **自動登入的範圍**：所有網站共用 `auth` 一組帳密；只認文字完全等於 Login / Log in / Sign in / 登入 的按鈕（其他字樣如「Login with SSO」不會點）；Login 後若進到 SSO / MFA 等沒有密碼框的頁面無法自動登入，需改用 🔐 登入監控網站。允許訪客瀏覽、但頁面上有 Sign in 連結的網站，設定帳密後也會被登入一次（無害）。
9. **Edge 異常關閉提示**：正常截圖已改為正常關閉；若電腦斷電、外部強制結束或關閉逾時，仍可能留下異常退出狀態。抑制還原提示參數是否生效受 Edge 版本影響；若仍出現提示，先確認執行主機已更新腳本，再查看 log 是否有「專用 Edge 關閉逾時」。不要為此刪除登入 profile。
10. **翻譯提示停用範圍**：啟動參數只控制專用瀏覽器內建翻譯，網站自行提供的語言選擇視窗不在此範圍。若更新主程式並重新開啟專用瀏覽器後仍有內建翻譯提示，需依實際 Edge 版本確認參數支援。
11. **Zabbix 時間控制版本**：最近七天自動調整目前支援帶 `timeControl` / `scrollbar_cntr` 的舊版 `screens.php` / `charts.php` 圖表頁，且確認英文 `(now)` / `(now!)` 標籤。新版 Zabbix、其他語系、包在 iframe 或不同網址路徑的頁面需另外適配；上述兩種路徑若無支援的元件會判定此頁失敗，不會猜測按鈕。網站改版、圖表 URL 無法確認時間或時間過於久遠超出操作上限時也是此頁失敗。
12. **專用 Edge 縮放**：每次抓圖／排程啟動 Edge 前清除 edge_profile 記住的網站縮放（`Clear-RememberedZoom`），比例只由設定工具的「網頁縮放」決定；在 🔐 登入視窗調整的網站縮放會被清除。預設頁面縮放不是 100% 時由補償處理。擷取面板開啟後請勿再按 Ctrl＋滾輪／加減號，偵測到比例變動會阻擋，請取消並重新抓圖。換電腦、換螢幕或改網頁縮放後，若保存的可視範圍無法精確還原，該頁停止並提示重新抓圖。
13. **CDP 背景傳送依賴 Teams 網頁版結構（2026-11-04）**：輸入框 `new-message-*`、`treeitem` 聊天清單、「聊天」「傳送」按鈕名稱與 `document.title` 格式取自目前版本，Teams 改版時需調整 `teams_cdp\Delivery.ps1` 的 `$CdpTeamsJs`。貼圖以網頁事件模擬，Teams 若不接受合成的 paste 事件會在「圖片沒有出現在輸入框」停止。headless 下 Teams 能否沿用公司登入（條件式存取、裝置相容性要求）未驗證，必要時設 `teams.cdp_headless=false`。登入過期需使用者重新登入（不能代輸入帳密）。電腦睡眠、登出、關機時沒有程式在執行。只支援聊天（含群組聊天），不支援團隊頻道貼文。
