# E3 監控自動截圖、警戒線判定與 Teams 通報（開發者文件）
 
本檔只記錄**目前**的架構、設定格式與必須遵守的規則。各版本的開發過程、使用者回報、當時驗證範圍與已被取代的設計，封存在 `docs\CLAUDE_HISTORY.md`（需要追查原因時再讀）。最後整理：2026-11-11。
 
---
 
## 1. 必守規則
 
### 1.1 文件同步
- 任何修改都要在同一次變更中更新兩份文件：**`USER_MANUAL.html`**（給使用者：操作步驟、按鈕名稱、畫面文字、批次檔、注意事項、FAQ，並更新開頭「最後更新」日期）與 **本檔**（給開發者：架構、設定格式、原理、限制）。完成後回報兩份各改了哪些段落。
- 改了 `calibrator.html` 的按鈕／欄位／文字：更新手冊對應步驟，並執行 `tools\make_screenshots.ps1` 重拍截圖。**手冊截圖一律以專案目前的 `config.json` 與 `sample_images\`（使用者在公司主機實際擷取的圖片）為準**，不用 `sample_data.js` 舊範例或另造示範設定；手冊文字中的範例名稱（頁面、排程 id／名稱、`@日管` 指令）也對應目前設定。工具只讀 config：網站帳號與密碼（全域與每頁 `auth`）都改成遮罩、移除空白收件項目後交給頁面；不啟動正式設定服務、不載入 `e3_monitor_native.ps1`。以獨立暫存 profile 啟動 headless Edge（`--remote-debugging-port=0` 隨機除錯埠，不需關閉正式設定工具），用 CDP `Fetch` 攔截頁面所有請求並由記憶體回應（不會連到真正的 8765），只回應 GET，POST 等一律 403；頁面載入時以 `addScriptToEvaluateOnNewDocument` 在 `autoSaveEnabled` 變成 true 的當下關閉自動儲存／自動辨識並停用 `scheduleSampleSave`。數值門檻以 `numeric_monitor.ps1` 的 `Measure-E3NumericRule` 對 `<id>_full.png` 依 crop 裁切後試算，結果注入 `numericCache`；排程同步、CDP 綁定／檢查、手機遙控狀態為依目前設定產生的示範狀態（手冊圖說需註明）。頁面挑選依規則類型自動找（數值規則頁、像素規則頁、有裁切的頁），設定改變時圖說要重新核對。13 張截圖全部完成且與手冊 `data-shot` 完全一致後，才以暫存檔＋`File.Replace` 原子替換 `<!-- MANUAL_IMAGES_BEGIN -->`～`END` 區塊（base64）；暫存目錄 `%TEMP%\e3_manual_shots_<時間>` 保留原手冊與 PNG 供檢查。**不可手動編輯圖片資料、不要整檔輸出手冊**。新增／改名截圖時同步修改 `Shot` 清單與 `<img data-shot="...">`。
- 手冊中的 Teams 畫面、確認視窗、log 是 HTML 示意（`.mock`／`.dialog`／`.log`），文字改變要同步。
- 不為每次更新另建 README；操作說明集中在手冊與本檔。
 
### 1.2 檔案編碼與傳檔
- 所有 `.ps1` 必須是 **UTF-8 with BOM**（PowerShell 5.1 無 BOM 會以 cp950 讀取，中文造成大量解析錯誤）。其他檔案 UTF-8 無 BOM 即可。
- 任何檔案都**不可含 U+00A0（NBSP）**：瀏覽器 `JSON.parse` 不接受、CSS 選擇器／屬性名會失效、PowerShell 無 BOM 時無法解析。零寬字元在程式中一律寫成 regex 跳脫（`\u200B` 等），不放實際字元。
- `.bat` 只能用 **ASCII + CRLF**；中文訊息寫在 PowerShell 腳本或手冊。
- 在公司／測試機與開發機之間傳檔要用 **zip 或附件**，不可經 Teams／Outlook／網頁複製貼上（曾造成 NBSP 縮排、BOM 遺失、整行截斷）。2026-11-11 帶回的版本再次發生：`teams_receiver.ps1`、`teams_cdp\Delivery.ps1` 與兩個測試腳本遺失 BOM 且含 NBSP，`receiver-snapshot.js`、本檔、手冊與歷史檔含 NBSP，手冊第 8 章、附錄開頭、圖片區塊與前半段腳本被截斷；已修復。收到檔案後先掃描 NBSP／BOM 並以 PowerShell Parser 解析全部 `.ps1`。
- 新增執行時必備的檔案：同步更新本檔第 3 節、手冊「8-1 程式檔與狀態資料」；若需由瀏覽器載入，加入 `-Calibrator` 的靜態檔白名單。
 
### 1.3 行為原則
- **零外掛**：只用 Windows 內建 PowerShell 5.1、.NET Framework 4.x（System.Drawing、WinForms、ClientWebSocket、UIAutomation、`Add-Type` 編譯 user32／kernel32 呼叫）與系統 Edge 的 CDP。不需 Python、pip、WebDriver、Edge 擴充、改登錄檔。
- **不自動重送**：任何傳送結果不明（uncertain）、逾時或中斷，都保留紀錄並停止，不補送、不把不明改成成功。新工作只送本次內容，不讀取或續送舊工作。
- **不猜測**：對話、帳號、頁面、刻度、按鈕都要能唯一辨識；辨識不到或有歧義就停止並說明原因。
- 測試一律用隔離資料（暫存 profile、loopback 網站、替身傳送邊界、隔離 mutex），**不對真實 Teams 發訊息、不註冊或刪除正式 Windows 任務、不改正式 config**，除非使用者明確要求。回報時清楚區分「本機驗證」與「待目標主機實測」。
- `config.json` 含監控網站帳密明文，**不可 commit 到 git**（目前已在版本控制中，需處理）。
 
---
 
## 2. 專案目標
企業內網中，每天定時以專用 Edge 開啟多個監控網頁（Zabbix 圖表、報表等），擷取指定區域，判定警戒線或左 Y 軸數值是否超標，將截圖與總結文字送到指定 Teams 對話。另提供手機在 Teams 輸入 `@日管 …` 遙控主機即時截圖回傳。
 
---
 
## 3. 檔案結構
 
| 檔案 | 用途 |
| --- | --- |
| `open_calibrator.bat` | 設定工具入口：啟動 `e3_monitor_native.ps1 -Calibrator` 並開啟設定工具 |
| `calibrator.html` | 設定工具網頁（頁面／警戒線／排程／預覽／測試） |
| `work_control.js` | 設定頁的「工作忙碌時選擇」彈窗（繼續等待／強制停止前一工作／取消） |
| `e3_monitor_native.ps1` | 主程式：擷取、判定、排程、Teams 發送、本機服務、各內部工作模式 |
| `teams_delivery.ps1` | 共用分批規則、訊息組合、`Start-E3RunDeadline` 硬期限 |
| `work_control.ps1` | 跨程序工作占用登記、等待選擇、可驗證的強制停止、QuickEdit 停用 |
| `numeric_monitor.ps1` | 數值門檻：Windows OCR 讀左 Y 軸刻度、線性擬合、藍線峰值換算 |
| `teams_self_test.ps1`／`teams_self_test.js` | 「傳給自己」測試（本人對話辨識、設定頁確認、CDP 導頁） |
| `teams_cdp\Delivery.ps1` | CDP 傳送模組；Teams 網頁腳本以 here-string 內嵌於 `Get-E3CdpRuntimeSource` |
| `teams_cdp\README.md` | CDP 模組說明 |
| `setup_cdp.bat` | 設定 CDP 收件對象（`-CdpSetup`） |
| `teams_receiver.ps1` | 手機 `@日管` 指令接收端（單一工作分頁輪流讀取、回覆、心跳、防睡眠、自動復原、程序內重新開始；`-Stop` 要求停止） |
| `teams_receiver_commands.ps1` | 指令解析與擷取工作分派 |
| `teams_receiver_capture.ps1` | 擷取子工作（由主程式 `-ReceiverCaptureJob` 載入） |
| `teams_receiver_watchdog.ps1` | 接收端監看與 Windows 任務註冊（由主程式 `-ReceiverWatchdog` 等載入） |
| `teams_cdp\receiver-snapshot.js`、`teams_cdp\receiver-switch.js` | 接收端網頁腳本（執行時讀檔）：讀取最新指令；在同一分頁切換到綁定對話 |
| `setup_teams_receiver.bat`／`start_teams_receiver.bat`／`stop_teams_receiver.bat`／`test_teams_receiver.bat` | 綁定接收對話／持續接收／要求停止／單次測試 |
| `register_receiver_watchdog.bat` | 註冊「E3 日管接收監看」與「E3 日管接收端」兩個 Windows 任務 |
| `config.json` | 設定（含帳密） |
| `USER_MANUAL.html` | 使用手冊（截圖內嵌） |
| `sample_data.js` | 選用：內建範例圖 page1～page4，只在直接開啟 HTML（file://）時使用；手冊截圖不使用 |
| `tools\` | 維護與隔離驗證：`make_screenshots.ps1`（手冊截圖，見 1.1）、`test_cdp_image_preflight.ps1`（接收端圖片預檢）、`test_receiver_latest.ps1`（接收端最新訊息讀取） |
| `docs\CLAUDE_HISTORY.md` | 本檔精簡前的完整歷史 |
 
專案狀態：同機更新保留 `config.json`、`sample_images\`（每頁 `<id>_full.png`、`<id>.png`、`annotated_<id>.png`）與 `logs\`（收據、待核對、去重與工作紀錄，不可當成一般 log 全刪）。設定與校正圖片可備份／帶往新機，但需重新抓圖驗證；不在 config 的頁面圖於服務啟動時刪除，sample_images 不可放其他圖片。`edge_profile\` 是監控網站登入，同機通常保留；可刪後重建但必須重新登入，不直接跨機搬加密登入。`captures\` 是排程截圖，日期資料夾保留 7 天；一般主程式 log 保留 30 天，不代表所有 logs 子目錄採同一清理規則。
 
本機狀態（不在專案內）：`%LOCALAPPDATA%\E3TeamsCdpSendTest`（排程／測試的 CDP 登入 profile、`bindings.json`、`session.json`）、`%LOCALAPPDATA%\E3TeamsCommandReceiver`（接收端的 Teams 登入與綁定）。更新程式可保留，不需清除；若使用者決定重設，先停止相關工作與專用 Edge，之後分別重新登入／綁定。新機需重新設定，不能直接搬登入資料就假設可用。
 
`logs` 結構：`logs\<日期>\receipts\`（CDP 收據）、`logs\<日期>\startup_*.json`（啟動失敗診斷）、`logs\teams_cdp\blocked|review`（待核對／封存紀錄）、`logs\self_tests\<id>\`、`logs\work_control\`、`logs\teams_detect\`、`logs\schedule_results\<排程id>.json`（每個排程最近一輪的傳送結果，只保留最新一份，供監看判斷是否送達）、`logs\teams_receiver\`（接收端，見第 11 節）。
 
---
 
## 4. 主程式參數（`e3_monitor_native.ps1`）
- 一般：`-ConfigPath`（預設同資料夾 config.json）、`-Schedule <id>`（只跑該排程；不帶則全部啟用頁面）、`-ListSchedules`、`-RegisterSchedules`、`-TestSample`（用 sample_images 不開網頁）、`-NoSend`、`-DryRun`、`-CountdownSeconds`。
- 設定工具：`-Calibrator [-Port 8765] [-NoBrowser]`、`-LoginMode`（開專用 Edge 手動登入監控網站）、`-PreviewCapture -PageId -Url -OutFile [-PreviewZoom 50..200] [-PreviewWaitSeconds 1..60] [-InteractiveCapture]`。
- Teams：`-DetectTeams [-DetectJobId]`、`-CdpSetup`。
- 內部工作（由服務或接收端啟動）：`-SelfTestJob`、`-SelfScheduleJob`、`-ReceiverCaptureJob <資料夾>`。
- 接收端監看：`-ReceiverWatchdog`、`-RegisterReceiverWatchdog`、`-UnregisterReceiverWatchdog`。
- config.json 格式錯誤時：`-Calibrator` 仍啟動（網頁顯示錯誤），其他模式 exit 1。
 
---
 
## 5. 設定格式（config.json）
 
```json
{
  "auth": { "enabled": false, "username": "", "password": "" },
  "page_categories": [{ "id": "category_xxx", "name": "日管Index" }],
  "pages": [{
    "id": "page1", "name": "P14_D7", "enabled": true, "category_id": "category_xxx",
    "url": "http://.../screens.php?...", "wait_seconds": 5, "browser_zoom": 100,
    "auth": { "enabled": true, "username": "", "password": "" },
    "zabbix_time": { "enabled": true, "range": "7d" },
    "capture_view": { "width": 0, "height": 0, "x": 0, "y": 0, "zoom": 100, "layout": "native100-v1" },
    "crop_region": { "x": 0, "y": 0, "w": 0, "h": 0 },
    "description": "",
    "rules": [{
      "name": "", "enabled": true, "alert_message": "",
      "measure_mode": "pixel", "roi": { "x": 0, "y": 0, "w": 0, "h": 0 }, "threshold_y": 0,
      "color_mode": "auto", "target_color": "#0000ff", "color_tolerance": 60, "min_pixels": 2,
      "axis_roi": { "x": 0, "y": 0, "w": 0, "h": 0 }, "value_threshold": 30
    }]
  }],
  "schedules": [{
    "id": "morning", "enabled": true, "name": "MSD日管Index", "time": "08:00", "days": [],
    "repeat": { "enabled": false, "every": 30, "unit": "minutes", "end_time": "18:00" },
    "pages": ["page1"], "target_chat_names": ["自己"], "title": "", "alert_only": false,
    "messages": { "default_message": "", "normal_summary": "", "abnormal_header": "" }
  }],
  "teams": {
    "target_chat_name": "自己", "prefer_window": "cdp", "cdp_headless": true, "receiver_headless": false, "auto_press_enter": true,
    "default_message": "", "normal_summary": "", "abnormal_header": "", "attach_annotated_image_on_alert": false
  }
}
```
 
- **頁面**：`mode` 由設定工具依是否有啟用規則自動寫入（threshold_check／capture_only）。`browser_zoom` 50～200 整數。`zabbix_time.range` 為 `7d`／`3d`／`keep`（只切 NOW）；缺少整個物件＝NOW→7d，`enabled:false` 不操作時間列；只對 `screens.php`／`charts.php` 生效。`capture_view` 由互動抓圖產生，`layout` 必須為 `native100-v1`，舊範圍會停止該頁並要求重新抓圖。`crop_region` 是來源 PNG 的整數像素。`description` 用於 `@日管` 收到通知的頁面簡介。
- **帳密**：`pages[].auth` 明確覆寫，停用或 null 不回退；只有缺少 `auth` 的舊頁面使用全域 `auth`。佔位值 `YOUR_USERNAME` 視為未設定。
- **規則**：`measure_mode` 省略或 `pixel` 為警戒線像素判定；`numeric` 使用 `roi`（監測區）、`axis_roi`（左軸刻度區）、`value_threshold` 與藍線 `target_color`。所有座標相對裁切後的 PNG。
- **分類**：`page_categories` 只影響設定工具的顯示與搜尋；未知或缺少 `category_id` 顯示「未分類」。
- **排程**：`id` 為英數字／`_`／`-`；`name` 即 Windows 任務名稱（需唯一、≤200 字、不含 Windows 任務保留字元；空白時用 id）。`days` 空陣列＝每天，否則 `MON`～`SUN`（以開始日計算）。`pages` 依清單順序擷取並送出。`target_chat_names` 非空時覆寫頁面／全域對象，依序逐一發送；缺少此欄才讀舊的 `target_chat_name`。收件優先序：排程 > 頁面 `target_chat_name`（舊設定相容）> `teams.target_chat_name`。`messages` 各排程獨立；舊排程缺少時由 `teams` 複製一次，刻意留空不回退。`schedules: []` 表示沒有排程；完全缺少 `schedules` 的舊 config 視為一個 `daily` 全頁面排程。
- **自動 Enter**：`teams.auto_press_enter=false` 在視窗模式只貼上不送出；CDP 無法留下草稿給人送，`Send-GroupToTeamsCdp` 在非 DryRun 時直接丟出「未送出」例外（排程記為傳送失敗 exit 1、監看通知記為 failed），不再靜默 return。傳給自己的兩個測試固定以 true 執行。設定頁 `autoPressEnterHint` 依模式顯示提醒（CDP 且未勾選時為紅字）。
- **Teams**：`target_chat_name` 為聊天清單顯示名稱或 `自己`／`self`；含 `48:notes` 的舊版 Teams 連結視為「自己」，其他連結與 Email 會被拒絕。設定工具載入時（經本機服務）以 `normalizeLegacySelfTargets` 把 teams／頁面／排程（含 `target_chat_names`，轉換後去重並移除空白項目）中的舊連結改存成 `自己`，畫面一律用 `targetDisplayName` 顯示，不顯示原始網址（內含組織帳號識別）。`prefer_window` 為空（自動：pwa→desktop→edge-tab）／`pwa`／`edge-tab`／`desktop`／`cdp`。`cdp_headless` 缺省視為 true。訊息組合：排程 `title` → `default_message` → `normal_summary` 或 `abnormal_header` → 超標／失敗明細；全部選填，空白項不輸出，不補預設文字。 `receiver_headless`（缺省 false）只決定手機接收端的專用 Edge 是否有視窗，接收端啟動時讀取一次；與 `cdp_headless`（排程傳送）互不影響。
 
---
 
## 6. 擷取與判定
 
### 6.1 擷取（`Capture-PagesNative`）
- 專用 profile `edge_profile\`，啟動參數含 `--remote-debugging-port`、`--disable-features=Translate,msEdgeTranslate`、`--hide-crash-restore-bubble`、`--force-device-scale-factor=1`、背景節流停用。截圖結束先 `Browser.close` 正常關閉，逾時才強制結束同 profile 程序；不影響日常 Edge。
- 啟動前 `Reset-CaptureProfileZoom`：只清空專用 profile Preferences 內的縮放 map（原子取代、其餘位元組保留），避免 Edge 記住的縮放改變表格排版。
- **登入三層**：持久 profile／Windows 整合驗證 → 偵測密碼框（`PASSWORD`）填帳密送出，或只有文字完全等於 Login／Log in／Sign in／登入 的按鈕（`LOGIN_BUTTON`）時點擊後等密碼框 → 送出後重開原網址，仍是登入頁即**此頁失敗**。未設定帳密且有密碼框也失敗。SSO／MFA 需用 🔐 手動登入。
- **頁面載入檢查**：`Page.navigate` 的 errorText、`chrome-error://`／`edge-error://`、非 http(s)、HTTP 4xx/5xx 皆此頁失敗。CDP 指令預設 60 秒逾時；連線中斷時開新分頁重連後繼續下一頁。
- **Zabbix 時間**：`screens.php`／`charts.php` 以 DOM 點擊時間列右箭頭至 NOW，再點上方 Zoom（7d=604800／3d=259200）；核對 timeline、`(now)` 標籤、圖片 URL period／isNow 與載入穩定後才截圖；最多 180 秒／120 次點擊，無法確認即此頁失敗，不回退舊區間。
- **可視範圍重播**：互動抓圖時最大化視窗、讀實際 CSS 可視尺寸並保存 `capture_view`；排程以 `dontSetVisibleSize=true` 套用相同 CSS 尺寸與 `scale=factor/nativeZoom` 補償原生縮放，還原捲動並嚴格核對（最多微調三次），不符即此頁失敗。截圖前 `Clear-CaptureHover`（有視窗時移開實體滑鼠＋CDP mouseMoved 移出，等 1 秒）。截 `fromSurface=true` 可視內容，先存 `_full.png` 再用 `crop_region` 裁切。互動抓圖期間偵測到使用者改縮放會阻擋。
- **桌面不可用**（鎖定、RDP 斷線）或全域 CDP 且 `cdp_headless` 不為 false 時，正式排程與「執行排程傳給自己」以 headless 擷取，不移動實體滑鼠；手動抓圖一律有視窗。
- 每頁獨立 try/catch，失敗原因記入 `Failures`，其他頁照常；失敗頁不附圖並在訊息列出原因，exit 1。
 
### 6.2 警戒線（像素）
- 每條規則 `roi` + 水平線 `threshold_y`；`roi.y ≤ y ≤ threshold_y` 範圍內曲線像素數 ≥ `min_pixels` 即超標。`color_mode=auto` 排除灰白背景與 Zabbix 粉紅日期虛線；`custom` 以 RGB 距離 ≤ `color_tolerance` 比對 `target_color`。
- 規則框或線超出圖片／尺寸無效：列為監控失敗並保留截圖，不視為正常。超標訊息空白時補頁名／規則名。
 
### 6.3 數值門檻（`numeric_monitor.ps1`）
- 依 `AvailableRecognizerLanguages` 選擇已安裝的 Windows OCR（優先英文，其次中文），不自動安裝。刻度區放大（4x／6x）二值化，不足時改灰階；O/o→0、I/l/i→1。至少兩次辨識得到一致的線性比例才採用。
- 先嚴格擬合；失敗時 `-AllowInteriorOutliers` 以可讀的上下界建立比例，需 ≥6 個可讀刻度且 75% 位置誤差 ≤1.5 px，排除的讀值記在 `ignored_ticks`。不補造上下界、不沿用上次刻度。
- 取 ROI 內指定藍色連通區最高點換算數值，嚴格大於門檻才超標。找不到藍線、峰頂被框裁切、超出刻度範圍、辨識矛盾、落在誤差範圍內皆 `unknown`（列入失敗並提醒，含 alert_only）。綠線、右軸、框外曲線不納入。支援負數、小數、千分位、K/M/G/T、百分比；不支援對數軸。
- 設定頁 `/api/numeric-preview` 只試算不寫設定；正式排程每張圖重新 OCR，不讀預覽快取。
 
---
 
## 7. 排程
- `-RegisterSchedules`（設定頁自動同步／🔄 重新套用）以目前使用者 Interactive／Limited 註冊根目錄任務，名稱＝排程名稱；`WakeToRun`、`StartWhenAvailable`、電池可執行、上限 2 小時、`IgnoreNew`；PowerShell 以 `-WindowStyle Hidden` 執行。
- 任務所有權由**單一 action 的 PowerShell、完整 script 與 config 路徑、`-Schedule <id>`** 判定（`Get-E3OwnedTaskId`），不看名稱前綴；解析其他應用的異常路徑時視為非本專案。改名先停用舊任務、註冊新名、成功後移除舊任務；註冊失敗恢復原狀；舊任務執行中拒絕改名。
- `repeat`：觸發器加 Repetition（間隔、時段長度減 1 秒、`StopAtDurationEnd=false`）。結束時刻不再啟動；結束早於開始代表跨日。主流程取得執行權後以 `Test-E3RepeatWindow` 再檢查時段，過時補跑或已停用就略過。
- 設定頁以 `/api/schedule-status` 回讀實際觸發器（時間、星期、重複、啟用、喚醒／補跑）比對 `scheduleSignature`，只有核對通過才顯示已同步；開啟設定頁不自動註冊。
- 執行時：以 `Enter-E3WorkLock` 取得 `Local\E3MonitorNativeRun`（capture 資源）排他，忙碌時最多等 180 秒並可在設定頁選擇（見第 10 節），逾時本輪不執行；執行期間 `SetThreadExecutionState(ES_CONTINUOUS|ES_SYSTEM_REQUIRED)`；每個 worker 有 `Start-E3RunDeadline` 10 分鐘硬期限（.NET Timer，逾時 exit 124、寫 `.deadline.json`，不執行 finally、不重送）。
- 每輪正式排程寫 `logs\schedule_results\<id>.json`；沒送達時由監看任務經接收端通知（第 11 節「排程傳送結果通知」）。
- `alert_only=true` 且整個排程無超標也無失敗時不發送（截圖保留）；任一頁異常則依原收件分組發送全部可用截圖。不記錄前次告警、不發恢復通知。
- 非 CDP 模式在桌面鎖定時等待解鎖最多 30 秒（同一次執行共用截止時間），逾時失敗、截圖保留。
 
---
 
## 8. Teams 傳送
 
### 8.1 共用規則（`teams_delivery.ps1`）
- 每批最多 4 張圖、原始 PNG 合計 ≤25 MiB；單張 ≤10 MiB、邊長 ≤4096、≤1600 萬畫素。多批時文字加批次序號；全空文字可只傳圖片；無圖無文字拒絕。
- 主流程逐收件對象 try/catch：一個對話失敗只記錄並繼續下一個，exit 1。發送對象仍是佔位文字時略過並 exit 1。
 
### 8.2 視窗模式（PWA／Edge 分頁／桌面版，UI Automation）
- 找已開啟、已登入的 Teams；在聊天清單以名稱點選，視窗標題的對話名稱必須**完全相同**（容許聊天類型前的 `(數字)` 未讀數；自己＝名稱以 `(您)`／`(You)` 結尾）。
- 開始前輸入框有草稿就停止；`Clear-E3TeamsUiDraft` 只在核對對話／焦點後 Ctrl+A、Backspace（最多三次／15 秒）。剪貼簿逐張貼圖、確認出現後貼文字，每次貼上與 Enter 前再核對前景與標題，被切走即停止。需解鎖桌面，佔用剪貼簿與前景。
 
### 8.3 CDP 模式（`teams_cdp\Delivery.ps1`）
- **圖片組件**：`Send-GroupToTeamsCdp` 有圖片時，在 PNG 驗證前以 `Add-Type -AssemblyName System.Drawing -ErrorAction Stop` 載入內建組件。接收端為獨立 PowerShell 程序，不能依賴主程式或截圖子程序預先載入 `Drawing.Bitmap`。純文字不載入此組件；圖片驗證失敗仍在貼上／傳送之前停止。
- **綁定**：`-CdpSetup`／設定頁「設定 CDP 收件對象」開專用 Edge（`E3TeamsCdpSendTest\profile`）。`Select-E3BindingRoutes` 列出 config 中所有收件名稱與「已綁定／尚未綁定」，可輸入多個編號（逗號分隔，依輸入順序）或 `A`（依序設定全部尚未綁定者）；同一次設定逐一處理：無視窗模式在同一分頁切換對話，分頁模式每個對象開新分頁（`Open-E3BindingTab`）。每個對象選好對話後由 `Get-E3SelfBinding` 嚴格讀出 accountId／chatId／label（讀不到可重試）、輸入 BIND 並確認輸入框空白才寫 `bindings.json`；輸入 S 或非 BIND 即略過該對象且原綁定不變。全部略過時回報未儲存。無視窗模式最後關閉設定 Edge，以 `Test-E3CdpRoutesReady` 用一個背景 Edge 依序驗證本次儲存的對象。每個收件名稱各自綁定；「自己」只能綁本人對話。`Resolve-E3CdpTarget` 先找完全相同的 route；找不到且名稱是「自己」的任一寫法（自己／self／48:notes 連結）時，才接受唯一一個 route 也是「自己」寫法且 `binding.isSelf=true` 的綁定，讓舊連結名稱的綁定在 config 改存成「自己」後仍可用。profile 被占用時詢問是否關閉重開（輸入 Y）。
- **無視窗（`cdp_headless` 預設 true）**：每次傳送以 headless 啟動專用 Edge，先清理同 profile 遺留的 headless 程序，以 chatId 深層連結（失敗時以完整名稱唯一選取）開啟對話，核對帳號／chatId／label 後傳送，結束正常關閉。
- **保留視窗（`cdp_headless=false`）**：使用綁定時的專用 Edge 分頁（`session.json` 的 browserUrl + `targetId`），Edge 或分頁關閉後需重新綁定（接收端例外，見第 11 節）。
- **傳送流程**：共用 mutex `Local\E3TeamsCdpShared`（`Enter-E3WorkLock`，忙碌最多等 180 秒）；取得後重讀綁定；停止上一個 runtime、清除舊文字／圖片／附件草稿（`Clear-E3HeadlessDraftForNewDelivery`）；本次入口只處理新內容，不讀取、續送或自動封存舊工作紀錄。每批新工作 ID；貼圖後核對每張圖的 hash／畫素、CKEditor model ready、文字（忽略整段結尾的空白）、帳號與對話；送出前重讀聊天紀錄（`preSend`）；按一次送出。
- **成功判定**：DOM 出現相符的新訊息列（文字、時間、圖片數與比例、非等待／失敗狀態）**且**觀察到相符的伺服器回應（Teams messaging 端點的 POST 200/201，ID 對應；含 Dedicated Worker 的網路請求），穩定 1.5 秒以上（最多 12 秒）。否則 `uncertain`，保留 `logs\teams_cdp\blocked`，不自動重送。emoji 圖片正文只讀明確標記的 Unicode alt。
- **收據**：`logs\<日期>\receipts\<工作ID>.json`，含 editor／preSend／textComparisons（無正文）／network 摘要（無 URL、header、正文）。
- **Runtime 版本**：目前 `2026-11-10-receiptbreak1`；`Connect-E3CdpTarget` 與 `teams_self_test.ps1` 的白名單必須同步。相容的 receipttext1 分頁可在 idle 時原地升級；更舊版本需使用者核對後重新整理分頁。更動內嵌 runtime 時要更新版本字串與兩處白名單。
- 同名 isolated world（`E3ProductionCdp`）會重用同一個執行環境，runtime 只注入一次。
- 「檢查 CDP 連線」（`Test-E3CdpConnection`）取得 `E3TeamsCdpShared` 時最多等 15 秒：接收端每讀一個對話就持有並釋放這把鎖，只試一次會隨機誤判忙碌（排程登入預警也因此常被略過）。真正的傳送／設定持有超過 15 秒時仍回「CDP 正在傳送或設定中」（監看依這段文字判斷略過，不可改字）。
- 「檢查 CDP 連線」（`/api/teams-detect` 背景工作＋`/api/teams-detect-status`）只讀：核對綁定、登入、帳號與對話（ConfigurationOnly），不清草稿、不解除 blocked、不發訊息。無視窗模式由 `Test-E3CdpRoutesReady` 只啟動一個背景 Edge（`Open-E3HeadlessBrowser`），每個對象在同一分頁重新套用頁面模擬與 bootstrap（屬於 CDP 連線階段，換連線要重設）後以深層連結開啟並嚴格核對（`Open-E3HeadlessChat`）；某對象在開啟或核對時失敗就關閉該 Edge，下一個對象重開，避免分頁狀態不明。排程登入預警也用這個檢查。**正式傳送仍是每個收件對象各自啟動／關閉背景 Edge（`Open-E3HeadlessTarget`）**，以維持現有的草稿清除、收據與防重送流程；尚未改為共用。
 
### 8.4 傳給自己（測試）
- 「將目前預覽傳給自己」：前端 PNG＋文字快照 → `/api/test-self` → `-SelfTestJob`。「執行排程傳給自己」：`/api/test-self-schedule` → `-SelfScheduleJob`，以點擊當下的 config 快照完整跑一次正式流程（登入、擷取、判定），只送本人，忽略 alert_only 與 auto_press_enter=false。兩者都不改正式設定與收件人。
- 一律先辨識本人對話（CDP：綁定的 isSelf 分頁或 headless 嚴格驗證；UIA：本人標記、唯一選取列、標頭等原生 UIA 證據），在設定頁中央 dialog 顯示實際對話供確認（token、5 分鐘逾時、決定不可覆寫），確認後再重驗身分與空白輸入框才送。
- 工作狀態 `/api/test-self-status`（服務重啟後讀 `logs\self_tests\<id>\status.json`），`/api/test-self-active`／`/api/test-self-cancel` 只接受原工作 token。結果不明時保留鎖定與 ID，不重送。
 
---
 
## 9. 設定工具（`-Calibrator`，`calibrator.html`）
- 本機服務 `http://127.0.0.1:8765`（HttpListener 單執行緒，長工作一律背景程序）。不送 CORS；`OPTIONS` 與非本工具 Origin 一律 403。靜態白名單：`calibrator.html`、`sample_data.js`、`work_control.js`、`USER_MANUAL.html`、`sample_images/*.png`；config 只能經 `/api/config`。回應帶 `Cache-Control: no-store`。單一請求例外回 500，服務繼續。
- API：`config`、`save`、`save-sample`、`delete-sample`、`capture-url`／`capture-status`（互動抓圖，同時只一個）、`commit-capture`（`Save-CaptureBundle` 在執行 mutex 內整組寫 full／crop／config，失敗回復）、`numeric-preview`、`register-schedules`、`schedule-status`、`login-setup`、`cdp-setup`、`cdp-bindings`（唯讀摘要，不回帳號／chatId）、`teams-detect`／`teams-detect-status`、`test-teams`（預設 DryRun，`?send=1` 正式送出需確認）、`test-self*`、`work-waits`／`work-decision`、`receiver-status`（GET，唯讀：`Get-E3ReceiverOverview` 回傳心跳、健康判定、監看狀態與兩個接收端任務，不含帳號／chatId）、`receiver-register`（POST，設定頁 confirm 後呼叫 `Register-E3ReceiverWatchdog`）。服務啟動時若有 `teams_receiver_watchdog.ps1` 才載入，缺檔時這兩個 API 回 404，其他功能不受影響。
- 存檔：`Save-ConfigBody` 驗證可解析、頁面 id 合法唯一、排程引用存在、時段與欄位型別，先寫暫存再 `File.Replace`；失敗回 400 且原檔不變。前端每秒比對自動儲存（只有從 `/api/config` 成功讀入後才啟用；格式錯誤時顯示錯誤並停用）。
- 版面：左欄三分頁（頁面與警戒線／排程與發送／全域設定），多數區塊為 `<details>` 收合並記在 `localStorage e3PanelLayout.v1`；中間畫布（✂️ 擷取範圍、📏 警戒線、💧 取色、縮放、像素放大鏡）；右欄依「預覽哪個排程」顯示判定明細與 Teams 訊息預覽（依目前圖片估算分批）。必須經本機服務開啟；`file://` 時嘗試轉址，否則顯示服務未啟動。
- 排程選單只有右欄 `previewScheduleSelect` 一個（選項含張數）；左欄「預覽與測試」只顯示目前選定排程與張數，兩個「傳給自己」按鈕都用 `previewScheduleId`，測試啟動中停用該選單。
- 「排程時段」`schedulesFold` 預設展開（記憶鍵 `sidebar:schedulesFold:v2`，讓舊版記住收合的使用者也先看到展開），收合摘要列出前 3 個排程的時間與名稱。`#scheduleList` 與 `.schedule-page-list` 不設 max-height／內部捲軸，只由左側欄捲動（避免捲軸套捲軸切掉展開的排程設定）。
- 排程卡片標題下兩行由 `renderScheduleRowStatus` 填入：設定摘要＋「下次」，以及 `rowLast`「上次 時間：結果」（class ok／warn／bad／running 上色，title 為完整原因）。資料來自 `/api/schedule-status` 每個任務的 `last`（`at`、`status`、`text`、`reason`）：`Get-E3ScheduleTaskStatus` 讀 `LastRunTime`／`LastTaskResult` 與 `logs\schedule_results\<id>.json`，交給 watchdog 檔的 `Get-E3ScheduleRunSummary`（與排程未送達通知同一套 `Get-E3ScheduleRunProblem` 判斷；watchdog 檔缺少時只有時間）。`refreshScheduleRunInfo` 在視窗取得焦點與每 60 秒（頁面可見、已從服務載入設定時）重讀，只更新卡片文字、不重建清單，避免打斷編輯；完整同步核對仍由 `refreshScheduleStatus` 負責。手冊截圖工具以示範狀態（已送出）回應 `last`。
- 「手機遙控（@日管）」`receiverFold`（排程與發送分頁）：以 textContent 顯示 `/api/receiver-status` 的接收端狀態、已執行時間、最後回報、防睡眠、各接收對話（讀不到時顯示原因）、離線通知與開機啟動任務；摘要顯示狀態與離線通知是否設定。載入時、視窗取得焦點與每 30 秒（頁面可見時）更新；「註冊離線通知與開機自動啟動」按鈕先 confirm 再 POST `/api/receiver-register`。 卡片另顯示「視窗模式」（心跳的 `mode`；與設定不同時提示重新啟動接收端）與「自動重啟」（`autoRestart`：監看任務最近一次重啟時間），並有 `receiverHeadlessChk` 勾選框寫入 `teams.receiver_headless`（下次啟動接收端才生效）。
- 每頁畫面來源：`sample_images\<id>_full.png`（依 crop 重裁）→ `sample_images\<id>.png` → 都沒有時顯示「這一頁還沒有畫面」提示圖（不評估警戒線）。經本機服務時不使用 `sample_data.js` 的內建範例圖，避免 id 為 page1～page4 的頁面把舊範例當成實際截圖。
- 數值規則：設定與圖片載入後自動逐項呼叫 numeric-preview（串行），結果綁定規則與圖片簽章，過期結果不顯示。
 
---
 
## 10. 工作控制（`work_control.ps1`）
- 資源 `cdp` 與 `capture` 的占用者寫在 `logs\work_control\<資源>.owner.json`（PID＋啟動時間＋入口腳本）。等待時寫 `waits\<id>.json`，設定頁彈窗讓使用者選擇；**沒有點選絕不自動強制停止**。
- 強制停止只結束可驗證的專用工作程序（`e3_monitor_native.ps1`／`teams_receiver.ps1` 的 worker，排除 `-Calibrator`、`-Listen`），不停 Edge 或服務；接收端等 cooperative 工作改寫 cancel 檔讓其自行停止。決定需匹配 id／token／當下 owner，重複提交不重做。
- `Disable-E3ConsoleQuickEdit` 只改目前主控台的輸入模式（清 0x0040、設 0x0080），保留 Ctrl+C；設定服務、CDP 設定與接收端共用。
 
---
 
## 11. 手機 `@日管` 遙控（接收端）
- **設定**：`setup_teams_receiver.bat`（`Set-E3CdpBinding -SelectInBrowser`）在 `E3TeamsCommandReceiver` 的有視窗 Edge 由使用者選對話後 BIND，可連續綁本人、其他個人與多個群組（最多 20 個，route／帳號＋chatId 不可重複；不支援團隊頻道）。接收只需要綁定中的 accountId／chatId／label，設定時開的分頁之後不需保留。接收端執行中（`Local\E3TeamsCommandReceiver` 存在）拒絕 setup，需先停止。
- **啟動／停止**：`start_teams_receiver.bat`（`-Listen -Continuous`）；`test_teams_receiver.bat` 回覆一個指令或 10 分鐘後結束；`stop_teams_receiver.bat`（`-Stop`）寫 `logs\teams_receiver\stop.request`，主迴圈每 3 秒檢查後正常結束（啟動時會清掉殘留的要求）。`Local\E3TeamsCommandReceiver` 防重複啟動。Ctrl+C 與 stop 都在心跳記為 `intentional`，監看不會重啟；直接關閉黑色視窗無法留下紀錄，視為異常結束，會被監看重新啟動。
- **指令**：文字前綴 `@日管` 加至少一個空格（容許 NBSP），不需 Teams 標註：`狀態`（可接單一標點）、`截圖清單`、`截圖 名稱`、`截圖 名稱一、名稱二`（、，, 跟 及 和 與 以及）、`截圖 排程名稱`、`截圖 頁面 名稱`／`截圖 排程 名稱`（重名時）。名稱每次讀 config，完整名稱優先、英數邊界不模糊匹配（P14 不匹配 P14_D3）；每次最多 20 頁。不認得的指令回覆用法說明；含「截圖」但沒有名稱時回覆清單。排程指令只取其 pages，不觸發 Windows 任務、不依原收件人群發、不做警戒判定。
- **防重複**：只處理接收端啟動之後、位於最新位置、兩次快照文字／ID／時間一致的訊息；以帳號＋chatId＋時間雜湊建立持久 claim（`logs\teams_receiver\commands\<key>.json`）後才處理；結果不明不重送。忽略「✦」開頭的回覆、含圖片、引用、傳送中、超過 400 字的訊息。
- **單一工作分頁**（2026-11-11 起，取代「每個對話一個分頁、必須停在最新訊息」）：一個專用 Edge、一個分頁服務所有綁定對話，不需要任何對話保持開啟。`Initialize-E3ReceiverTab` 確保瀏覽器與工作分頁存在：沿用仍在執行且模式相符的專用 Edge（只採用該 profile 自己寫的 DevToolsActivePort 且監聽埠屬於該程序），模式不符先正常關閉再重開；舊版記錄在 bindings 的其他分頁會關閉。`Set-E3ReceiverBindingTab` 把所有接收綁定的 `targetId` 指向工作分頁，因為回覆沿用 `Send-GroupToTeamsCdp`，它經 bindings.json 找分頁；接收端呼叫時固定傳 `cdp_headless=$false`（＝使用現有分頁，不另開瀏覽器），**不可改成 true**，否則會把接收端自己的瀏覽器當成遺留程序清掉。`Open-E3ReceiverChat` 把分頁帶到某對話：頁面已準備好時先用 `teams_cdp\receiver-switch.js` 在 Teams 內切換（只點擊聊天清單中名稱唯一相符的項目，點一次後最多等 6 秒並以 chatId 核對；同名、不在清單、未切換都回 `reopen`），否則以 chatId 連結整頁開啟（同一連線先註冊 `image-frame-bootstrap`，`Wait-E3HeadlessChat` 75 秒，再由 `Connect-E3CdpTarget` 嚴格核對帳號／chatId／label）。主迴圈每圈由 `Get-E3ReceiverNextSource` 取「到期且最久未讀」的來源，`Invoke-E3ReceiverVisit` 讀兩次相隔 500 ms 的穩定快照後交給 `Select-E3ReceiverCommand`；單一來源每圈 1 秒、多來源每圈 300 ms。頁面載入超過 `E3ReceiverReloadMinutes`（30）會在下一次讀取時整頁重載。送出前（收到通知、結果、監看通知）一律 `Enter-E3ReceiverChat`：切回來源對話、`Connect-E3CdpTarget`、`Assert-E3ReceiverDestination`。**不檢查輸入框空白**：殘留草稿交給 `Send-GroupToTeamsCdp`（分頁模式 `Clear-E3HeadlessDraftForNewDelivery -Visible`，先核對分頁、帳號、對話並停止舊 runtime 工作）清除；若在這裡要求空白，一次中斷的貼上會讓之後每個指令都被領取後失敗，而讀取仍正常、心跳與監看都看不出來。
- **有視窗／無視窗**（`teams.receiver_headless`，預設有視窗）：無視窗以 `--headless=new` 啟動，並用啟動參數 `--user-agent`（依 msedge.exe 主版本組出不含 Headless 的字串）與 `--window-size=1600,1000`，因為每次 CDP 重連都會失去連線層級的模擬設定（`Start-E3TestBrowser -ExtraArguments`）。有視窗時每 15 秒以 `Browser.getWindowForTarget` 檢查，視窗被最小化就還原（最小化會停止繪製，新訊息進不了頁面）；被其他視窗蓋住或鎖定螢幕不受影響。
- **最新訊息讀取**（`teams_cdp\receiver-snapshot.js`，viewport 版本 `receiver-latest2`）：不使用發送端的 `followLatest`／`atLatest`／`snapshot`。先以 `BridgeAdapter.inspect` 核對綁定與 label，在對話根節點內找唯一可捲動的訊息清單（找不到或不唯一即回錯誤，不猜測）；可見的「回到最新訊息」按鈕最多每 2 秒點一次，點擊或捲動後本次回傳 `latest:false`，下一次讀取穩定在底部（誤差 ≤2 px，支援 column-reverse）才讀指令。不聚焦輸入框、不送鍵、不碰草稿與其他捲軸。**訊息列由本腳本自行解析且容錯**：無法解析的列（沒有唯一正文、沒有完整含時區的時間、ID 重複，例如卡片、通話紀錄、已刪除訊息）只計入 `skipped` 並略過，不讓整個對話讀取失敗；指令列仍嚴格要求唯一 ID、單一正文、完整時間、純文字（表情圖示除外）、無引用、非傳送中。`Read-E3ReceiverSettled` 在期限內（預設 8 秒）每 400 ms 重讀：「尚未到最新」只是等待，不是斷線。回歸測試 `tools\test_receiver_latest.ps1`（33 項，暫存 headless Edge＋替身 BridgeAdapter，不導覽 Teams、不送出）。
- **處理**：截圖指令先送收到通知（頁面簡介），釋放 CDP 鎖後由 `-ReceiverCaptureJob` 子程序以 headless 擷取（期限 300 秒，父程序最多等 330 秒；`E3MonitorNativeRun` 排他），再重新核對原來源、帳號、對話與空白輸入框，以原 route 回傳圖片。回覆以「✦ [日管]」開頭、保留分行不插空行。 同一時間只處理一個指令；處理期間不讀取其他來源，完成後依序處理仍在對話中、時間在啟動之後且未領取的指令。
- **圖片回傳回歸驗證**：`tools\test_cdp_image_preflight.ps1` 每個案例用全新 PowerShell 載入接收端 `-LibraryOnly`，以替身綁定及禁止連線的邊界執行真實 CDP 圖片預檢，涵蓋有／無視窗、純圖片、純文字、錯誤 PNG、損壞 PNG、超大尺寸及混合圖片。避免測試自己產生圖片時先載入組件而掩蓋接收端缺少載入的錯誤。這是本機驗證，不代表實際 Teams 已送達。
- **狀態回覆**：主機名稱、連續執行時間、排程數，以及各排程 Windows 任務的上次結果（成功／執行中／代碼 1 有頁面或傳送失敗／124 逾時）與下次時間；未同步、停用、讀不到任務清單會明示。
- **容錯與復原階梯**：任何來源讀取、截圖、傳送例外都不結束接收程序。`Set-E3ReceiverSourceFailure` 只影響該來源：退避 10→20→40→80→160→300 秒，下次改以連結重開（`reload`），其他來源照常輪讀；同一原因只印一次。登入類錯誤（`E3_RECEIVER_LOGIN`）讓全部來源暫停 60 秒（共用一份登入，不逐一試探）；瀏覽器或分頁準備失敗（`E3_RECEIVER_BROWSER`）清掉分頁狀態，20 秒後重建。有視窗模式看到 Microsoft 登入頁時 15 分鐘內不再導覽，留給使用者登入；無視窗模式照常重試。對話改名（label 不同）回 `E3_RECEIVER_SOURCE`，需重新綁定。bindings.json 被改寫（時間戳不同或找不到原綁定）丟 `E3_RECEIVER_RELOAD`。`Start-E3ReceiverSupervised`：持續模式遇到未預期例外不結束程序，15 秒後（RELOAD 為 2 秒）重新進入 `Invoke-E3ReceiverTest`，沿用第一次啟動的指令時間界線（`E3ReceiverCutoff`）；只有 `E3_RECEIVER_FATAL`（沒有綁定、重複綁定、重複啟動）會結束。復原永遠不重讀、重試或回覆先前的指令，claim 與 seen 仍有效；程序重新啟動後只處理啟動之後的新訊息，不回補離線期間的指令。回歸測試 `tools\test_receiver_single_tab.ps1`（87 項：切換腳本於真實頁面、輪讀與退避、綁定指向工作分頁、開啟對話各路徑、監看重啟判斷、以替身對話執行真正的主迴圈，以及殘留草稿不擋回覆、CDP 關閉自動 Enter 回報未送出、通知佇列在鎖忙碌時保留（隔離 mutex 名稱）、排程傳送結果判斷與只通知一次、排程卡片上次結果摘要）；皆為本機模擬，不代表真實 Teams 行為。
- **防睡眠**：接收期間 `SetThreadExecutionState(ES_CONTINUOUS|ES_SYSTEM_REQUIRED)`，允許關螢幕與鎖定，不改電源計畫，結束時解除。
- **心跳**：持續模式寫 `logs\teams_receiver\heartbeat.json`（version 2：state〔listening／processing／restarting／stopped〕、pid、processStart、startedUtc、utc、busyUntilUtc、sleepGuard、stopReason、mode〔window／headless〕、intentional、fatal、sources[route, active, lastOkUtc, error]），最多每 30 秒一次，連上、處理前（busyUntil +1200 秒）、回覆後與結束時強制寫入。
- **監看**（`-ReceiverWatchdog`，Windows 任務「E3 日管接收監看」每 10 分鐘）：無心跳、stopped、程序不存在、心跳超過 10 分鐘（不在 busyUntil 內）、啟動滿 10 分鐘後任一來源超過 10 分鐘未成功讀取，皆異常；60 秒後再確認。只支援 CDP 模式，用排程的 Teams 登入傳純文字「✦ [日管監看]」到 `teams.target_chat_name`。`watchdog_state.json` 先記錄再傳送；同次離線只通知一次、失敗不重試；只有離線通知 sent 才發「已恢復」。不持有 `E3MonitorNativeRun`。 **自動重啟**：`Get-E3ReceiverHealth` 回傳 `kind`，`Get-E3ReceiverRestartPlan`（純判斷）只對程序已結束（dead）、非要求的停止（stopped）與卡住（stale，先結束經 PID＋啟動時間＋命令列核對的接收程序）重啟；`intentional`、`fatal`、從未啟動、程序仍在但讀不到 Teams（sources）、或存在 `stop.request` 都不重啟。15 分鐘內不重複、一小時最多 3 次（`watchdog_restart.json`，先記錄再動作）。`Start-E3ReceiverAutoRestart` 先確認 `Local\E3TeamsCommandReceiver` 不存在，優先以 Stop／Start「E3 日管接收端」任務重新啟動（結束後的視窗停在 pause 仍算執行中，IgnoreNew 會擋掉新啟動），任務不可用時直接執行 start_teams_receiver.bat。重啟當次不通知，下次檢查仍異常才通知，通知文字附上重啟結果。
- **排程登入預警**（同一個監看任務，`Invoke-E3SenderLoginCheck`）：排程用的 Teams 登入過期時，無法用同一份登入通知自己，因此檢查結果交給接收端（另一份登入）發送。只在 `prefer_window=cdp` 時執行；`Test-E3SenderLoginDue` 決定時機：從未檢查、距上次 ≥6 小時、下一個本專案排程任務（`Get-E3NextScheduleRunUtc`，依 `Get-E3OwnedTaskId`）在 70 分鐘內且距上次 ≥3 小時、或上次異常且已過 30 分鐘。檢查用 `Test-E3CdpConnection -PassThru`（ConfigurationOnly：登入、帳號、對話，不傳訊息）；CDP 鎖忙碌時略過且不更新狀態。`logs\teams_receiver\sender_login_state.json` 記錄結果；由正常轉異常時寫一則「✦ [日管監看] 排程用的 Teams 登入需要處理…」到 `logs\teams_receiver\outbox\`，異常期間不重複，恢復時再寫一則「已恢復」。`Local\E3SenderLoginCheck` 防重入，420 秒期限。
- **排程傳送結果通知**（同一個監看任務，`Invoke-E3ScheduleResultCheck`）：主程式在正式排程（`-Schedule`，不含 `-SelfScheduleJob`／`-TestSample`／`-NoSend`／`-DryRun`）開始時寫 `logs\schedule_results\<id>.json`（state=running），等不到執行權改 `no_lock`，finally 寫 `finished`（exitCode、targets、delivered、sendFailures、error、skipped＝`outside_window`／`alert_only_normal`）。被 10 分鐘期限強制結束時 finally 不執行，留下的 running 即「中斷、結果不明」。監看依 `Get-E3OwnedTaskId` 列出本專案任務，讀 `LastRunTime`／`LastTaskResult`；執行中（267009）或從未執行（267011）不判斷。結果檔的 startedUtc 落在 LastRunTime −2～+15 分鐘才算同一輪，否則只依任務結果代碼（0 不通知）。`Get-E3ScheduleRunProblem`（純判斷）：running、no_lock、有 sendFailures、或 exitCode≠0 且沒有任何對象送達 → 通知；頁面擷取／判定失敗但訊息已送達不另通知（原因已在 Teams 訊息內），skipped 不通知。`logs\teams_receiver\schedule_result_state.json` 記錄每個排程已處理的 LastRunTime，**先記錄再排入**，同一輪只通知一次、不重送；首次檢查時超過 24 小時的舊結果只建立基準。多個排程合併成一則「✦ [日管監看]」經通知佇列由接收端發送（接收端未執行時最多保留 6 小時）；紀錄寫在 `schedule_result_last.txt`。限制：重複間隔小於 10 分鐘時兩次檢查之間只看得到最後一輪。測試用 `$script:E3WatchdogLogRoot` 指向暫存目錄，不碰正式 logs／outbox。
- **通知佇列**（接收端 `Send-E3ReceiverOutbox`，每 5 秒）：只接受以「✦」開頭、≤2000 字、6 小時內的 `outbox\*.json`（否則改名 `.invalid`／`.expired`）；送到已綁定的本人對話，沒有本人對話時用第一個來源，該來源未連線時保留等待（不改送其他群組）。先以 `WaitOne(0)` 取得 `E3TeamsCdpShared`（忙碌時保留 `.json`、本輪結束，5 秒後再試，不經設定頁忙碌彈窗），取得後才改名 `.sending` 並送，結果 `.sent`／`.failed`，每則最多嘗試一次，不重送；不會因等鎖逾時而沒試就變成 `.failed`。完成的檔案 30 天後由紀錄清理刪除。
- **設定頁狀態**：排程與發送分頁的「手機遙控（@日管）」卡片顯示上述心跳、監看與任務狀態、排程登入檢查結果與待送通知數，並可直接註冊兩個任務（見第 9 節）。
- **自動啟動**（Windows 任務「E3 日管接收端」）：登入 Windows 1 分鐘後執行 `start_teams_receiver.bat`，無執行時間上限、IgnoreNew。兩個任務由 `register_receiver_watchdog.bat` 一起註冊；action 不含 `-Schedule`，`-RegisterSchedules` 不會刪除它們。這是登入觸發；程序結束或卡住後的重啟由監看任務負責。注意 `Test-E3ReceiverTaskAction` 的 watchdog 分支只核對 `-ReceiverWatchdog`，未完整核對 Execute／腳本／config 路徑，不能保證同名的另一份安裝不被覆寫或移除。
- **紀錄保留**：啟動時與每 24 小時清理：`captures\<日期>`（指令截圖）超過 7 天、`<日期>`（收據、診斷）與 `commands\*.json` 超過 30 天；不碰 `teams_cdp`（blocked／review）、heartbeat、status、watchdog 檔。
- 注意：`Get-ScheduledTask -TaskPath '\'` 在根資料夾沒有任務時會丟例外，查詢一律列出全部後篩選 TaskPath。
 
---
 
## 12. 已知限制與待實測
- 網頁版面隨縮放／內容變化：改縮放、網址或版面後需重新抓圖並確認警戒線；不保存 iframe／表格內部捲軸、不重演點擊流程。圖片上限單邊 16384、總 6400 萬像素。
- 自動登入只認固定按鈕文字與密碼框；SSO／MFA／特殊表單需手動登入。帳密以明文存在 config.json 與瀏覽器 localStorage。
- Zabbix 時間調整只支援舊版 `timeControl`／`scrollbar_cntr` 介面與英文 `(now)` 標籤；新版、其他語系、iframe 需另外適配（無法確認即此頁失敗）。
- 數值 OCR 需主機有可用的 Windows OCR 語言；不保證任意字型與影像品質；另一台主機的實際 OCR 結果需現場驗證。
- 視窗模式（UIA）需解鎖的互動桌面，Teams 改版可能影響定位；名稱須與清單完全一致，清單最多往下捲 10 頁。
- CDP：本機測試、伺服器回應與手機實收要分開。保留視窗模式曾有短時間 Win+L 實收確認；無視窗、多圖、隔夜與其他主機需各自實測，不能從短時間成功推論長期可靠。Teams 登入過期／MFA 需人工處理。
- 系統睡眠期間沒有程式執行；喚醒受硬體、電源與公司政策限制。防睡眠請求無法阻止手動睡眠、闔蓋、登出或斷電。
- 接收端：主機重開後需登入 Windows 任務才會執行；深層連結在有視窗 Edge 對「自己」對話可能先到 launcher 頁（改以名稱選取），實際行為需 A 主機驗證；群組沒有發送者白名單，任何成員都能下指令；排程與接收端使用兩份不同的 Teams 登入。
- 設定工具在視窗寬度約 900px 以下時三欄會擠壓、標題逐字換行（未做窄螢幕版面）。手冊另有窄螢幕版面；截圖展示桌面設定介面。
- CDP 設定按鈕只在啟動請求期間停用；後端每次請求仍可開一個設定 PowerShell，mutex 只序列化工作，不去除重複請求。同名綁定覆寫原紀錄，但連按仍可能留下多個等待程序，尚未做設定流程單一實例防護。
- 接收端的單一工作分頁、對話內切換、容錯讀取、無視窗啟動與監看重啟，目前只有本機模擬測試；真實 Teams 的行為（聊天清單項目的名稱比對、連結開啟後是否停在最新、多對話切換速度、長時間無視窗、鎖定螢幕時有視窗模式是否持續更新）需在公司主機實測。多對話時每個對話約 2～3 秒（估計），指令延遲隨對話數增加。輪讀會把這些對話標為已讀。防睡眠／自動復原不保證網路或 Teams 永久有效；能讀到頁面不等於 Teams 服務在線。登入過期、MFA、關機、睡眠、登出 Windows 無法自動處理。
- Windows Server 可擷取與判定；UIA 操作 Teams 需有人登入且解鎖；CDP 在 Server 未驗證。