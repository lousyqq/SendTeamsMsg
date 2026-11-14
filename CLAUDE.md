# E3 監控自動截圖、警戒線判定與 Teams 通報（開發者文件）

本檔只記錄**目前**的架構、設定格式、規則與限制。事件經過、改版前後比較與當時的驗證範圍在 `docs\CLAUDE_HISTORY.md`（不自動載入）。最後整理：2026-11-12。

---

## 1. 必守規則

### 1.1 文件同步
- 任何修改都要在同一次變更中更新兩份文件：**`USER_MANUAL.html`**（給使用者：操作步驟、按鈕名稱、畫面文字、批次檔、注意事項、FAQ，並更新開頭「最後更新」日期）與 **本檔**（給開發者：架構、設定格式、原理、限制）。完成後回報兩份各改了哪些段落。本檔只寫現況，不寫「原本／改為」與事件經過；需要留存的經過寫進 `docs\CLAUDE_HISTORY.md`。
- 改了 `calibrator.html` 的按鈕／欄位／文字：更新手冊對應步驟，並執行 `tools\make_screenshots.ps1` 重拍截圖（見 1.4）。
- 手冊中的 Teams 畫面、確認視窗、log 是 HTML 示意（`.mock`／`.dialog`／`.log`），文字改變要同步。
- 不為每次更新另建 README；操作說明集中在手冊與本檔。

### 1.2 檔案編碼與傳檔
- 所有 `.ps1` 必須是 **UTF-8 with BOM**（PowerShell 5.1 無 BOM 會以 cp950 讀取，中文造成大量解析錯誤）。其他檔案 UTF-8 無 BOM 即可。用程式改寫 `.ps1` 時要保留 BOM（`ReadAllText` 會吃掉 BOM，寫回時要明確指定）。
- 任何檔案都**不可含 U+00A0（NBSP）**：瀏覽器 `JSON.parse` 不接受、CSS 選擇器／屬性名會失效、PowerShell 無 BOM 時無法解析。零寬字元在程式中一律寫成 regex 跳脫（`\u200B` 等），不放實際字元。
- `.bat` 只能用 **ASCII + CRLF**；中文訊息寫在 PowerShell 腳本或手冊。`.gitattributes` 設定 `*.bat text eol=crlf`，在任何 git 設定下取出都是 CRLF（git 內部仍存 LF）。`tools\make_screenshots.ps1` 寫入圖片區塊時沿用手冊原本的換行（目前 LF）。
- 在公司／測試機與開發機之間傳檔要用 **zip 或附件**，不可經 Teams／Outlook／網頁複製貼上（會造成 NBSP 縮排、BOM 遺失、整行截斷，已多次發生）。收到檔案後先執行 `tools\check_files.ps1`。
- 新增執行時必備的檔案：同步更新本檔第 3 節、`tools\check_files.ps1` 的 `$required`、手冊「8-1 程式檔與狀態資料」；若需由瀏覽器載入，加入 `-Calibrator` 的靜態檔白名單。

### 1.3 行為原則
- **零外掛**：只用 Windows 內建 PowerShell 5.1、.NET Framework 4.x（System.Drawing、WinForms、ClientWebSocket、UIAutomation、`Add-Type` 編譯 user32／kernel32 呼叫）與系統 Edge 的 CDP。不需 Python、pip、WebDriver、Edge 擴充、改登錄檔。主機在企業內網，**不能使用外部 AI 服務**。
- **不自動重送**：任何傳送結果不明（uncertain）、逾時或中斷，都保留紀錄並停止，不補送、不把不明改成成功。新工作只送本次內容，不讀取或續送舊工作。
- **失敗要說得出原因**：手機端看不到主機視窗與 log，回覆不可只寫「請查看本機紀錄」。失敗原因要寫進回覆或另一則**純文字說明**，並留在紀錄檔。說明是關於失敗的新訊息，不是重送：不含原回覆內容與圖片、每個指令最多一則、每個管道最多嘗試一次，文字必須依階段說清楚「可能已送出／確定沒送出」，不可把不明說成失敗或成功。指令本身不重做。
- **不猜測**：對話、帳號、頁面、刻度、按鈕都要能唯一辨識；辨識不到或有歧義就停止並說明原因。名稱打錯時只給建議，不代選。
- 測試一律用隔離資料（暫存 profile、loopback 網站、替身傳送邊界、隔離 mutex、暫存資料夾的程式副本），**不對真實 Teams 發訊息、不註冊或刪除正式 Windows 任務、不改正式 config**，除非使用者明確要求。回報時清楚區分「本機驗證」與「待目標主機實測」。
- `config.json` 的版本控制與帳密保管由使用者自行決定，**不要提出或處理**（不建議移出 git、清歷史或更換密碼）。測試仍不可修改正式 config。

### 1.4 手冊截圖（`tools\make_screenshots.ps1`）
- 一律以專案目前的 `config.json` 與 `sample_images\`（使用者在公司主機實際擷取的圖片）為準，不另造示範設定；手冊文字中的範例名稱（頁面、排程 id／名稱、`@日管` 指令）也對應目前設定。
- 工具只讀 config：網站帳號與密碼（全域與每頁 `auth`）改成遮罩、移除空白收件項目後交給頁面；不啟動正式設定服務、不載入 `e3_monitor_native.ps1`。以獨立暫存 profile 啟動 headless Edge（`--remote-debugging-port=0`，不需關閉正式設定工具），用 CDP `Fetch` 攔截頁面所有請求並由記憶體回應（不連到真正的 8765），只回應 GET，POST 等一律 403；以 `addScriptToEvaluateOnNewDocument` 在 `autoSaveEnabled` 變成 true 的當下關閉自動儲存／自動辨識並停用 `scheduleSampleSave`。
- 數值門檻以 `Measure-E3NumericRule` 對 `<id>_full.png` 依 crop 裁切後試算，結果注入 `numericCache`；排程同步、CDP 綁定／檢查、手機遙控狀態為依目前設定產生的示範狀態（手冊圖說需註明）。頁面依規則類型自動挑選（數值規則頁、像素規則頁、有裁切的頁），設定改變時圖說要重新核對。
- 各張截圖在拍攝前呼叫 `setSideTab`／`setPageSection`（01～04、08、11 在 pages 分頁，其中 01／04／11 為 rules、02／03／08 為 page；05／06／12 在 schedule；07_site_tab 在 site；09／10／13 在 teams，13 另展開「接收端設定」並收起其中的「ⓘ」說明；14_panels_collapsed 以 `setPanelCollapsed(…, {save:false})` 收起左右欄，不寫入記憶）；09／10／13 先把對應區塊捲進畫面再截。14 張全部完成且與手冊 `data-shot` 完全一致後，才以暫存檔＋`File.Replace` 原子替換 `<!-- MANUAL_IMAGES_BEGIN -->`～`END` 區塊（base64）；`%TEMP%\e3_manual_shots_<時間>` 保留原手冊與 PNG 供檢查。**不可手動編輯圖片資料、不要整檔輸出手冊**。新增／改名截圖時同步修改 `Shot` 清單與 `<img data-shot="...">`。

---

## 2. 專案目標
企業內網中，每天定時以專用 Edge 開啟多個監控網頁（Zabbix 圖表、報表等），擷取指定區域，判定警戒線或左 Y 軸數值是否超標，將截圖與總結文字送到指定 Teams 對話。另提供手機在 Teams 輸入 `@日管 …` 遙控主機：截圖、檢查數值、查排程結果、主機狀況與網站連線，失敗時說明原因。

---

## 3. 檔案結構

| 檔案 | 用途 |
| --- | --- |
| `open_calibrator.bat` | 設定工具入口：啟動 `e3_monitor_native.ps1 -Calibrator` 並開啟設定工具 |
| `calibrator.html` | 設定工具網頁（頁面／監測項目／排程／預覽／測試） |
| `work_control.js` | 設定頁的「工作忙碌時選擇」彈窗（繼續等待／強制停止前一工作／取消） |
| `e3_monitor_native.ps1` | 主程式：擷取、判定、排程、Teams 發送、本機服務、各內部工作模式 |
| `teams_delivery.ps1` | 共用分批規則、訊息組合、`Start-E3RunDeadline` 硬期限 |
| `work_control.ps1` | 跨程序工作占用登記、等待選擇、可驗證的強制停止、QuickEdit 停用 |
| `numeric_monitor.ps1` | 數值門檻：Windows OCR 讀左 Y 軸刻度、線性擬合、藍線峰值換算 |
| `teams_self_test.ps1`／`teams_self_test.js` | 「傳給自己」測試（本人對話辨識、設定頁確認、CDP 導頁） |
| `teams_cdp\Delivery.ps1` | CDP 傳送模組；Teams 網頁腳本以 here-string 內嵌於 `Get-E3CdpRuntimeSource` |
| `setup_cdp.bat` | 設定 CDP 收件對象（`-CdpSetup`） |
| `teams_receiver.ps1` | 手機 `@日管` 接收端（單一工作分頁輪流讀取、回覆、心跳、防睡眠、自動復原、程序內重新開始、紀錄；`-Stop` 要求停止） |
| `teams_receiver_commands.ps1` | 指令解析（問法辨識、名稱建議）、擷取／檢查工作分派與回覆組成、失敗說明文字、指令紀錄查詢 |
| `teams_receiver_queries.ps1` | 唯讀查詢：排程結果（含主機 log 錯誤行）、主機狀況、網站連線測試 |
| `teams_receiver_capture.ps1` | 擷取子工作（由主程式 `-ReceiverCaptureJob` 載入；`analyze` 時另做判定） |
| `teams_receiver_watchdog.ps1` | 接收端監看、排程結果與登入檢查、失敗說明代發、Windows 任務註冊（由主程式 `-ReceiverWatchdog` 等載入；接收端啟動時也載入以共用判斷） |
| `teams_cdp\receiver-snapshot.js`、`teams_cdp\receiver-switch.js` | 接收端網頁腳本（執行時讀檔）：讀取最新指令；在同一分頁切換到綁定對話 |
| `setup_teams_receiver.bat`／`start_teams_receiver.bat`／`stop_teams_receiver.bat`／`test_teams_receiver.bat` | 綁定接收對話／持續接收／要求停止／單次測試 |
| `register_receiver_watchdog.bat` | 註冊「E3 日管接收監看」與「E3 日管接收端」兩個 Windows 任務 |
| `config.json` | 設定（含帳密） |
| `USER_MANUAL.html` | 使用手冊（截圖內嵌） |
| `docs\CLAUDE_HISTORY.md` | 開發歷史（事件經過、舊版說明、清理前的本檔全文） |
| `tools\check_files.ps1` | 程式檔損壞檢查（見下） |
| `tools\make_screenshots.ps1` | 手冊截圖（見 1.4） |
| `tools\test_*.ps1` | 隔離回歸測試：`test_receiver_chat_only`（接收端讀取／切換／開對話只核對聊天室、回覆前仍完整核對帳號；用真實 adapter 腳本在替身頁面上驗證）、`test_navigation_retry`（開啟 Teams 頁面的網路錯誤重試規則，含真實 Edge 在重試間恢復連線）、`test_account_proof`（Teams 帳號驗證失效時的重新核對：接收讀取、對話內切換、傳送前檢查各只恢復一次）、`test_capture_startup`（截圖 Edge 動態除錯埠、擁有者核對、不經 Proxy、60 秒等待與關閉清理）、`test_cdp_image_preflight`（接收端圖片預檢）、`test_receiver_latest`（最新訊息讀取）、`test_receiver_single_tab`（單一工作分頁、輪讀退避、監看重啟、通知佇列、排程結果判斷）、`test_receiver_failure_notice`（失敗原因、說明訊息、中斷／離線通知、狀態回覆、監看歷史、代發、損壞檔啟動檢查）、`test_receiver_control`（設定頁啟動／停止／設定接收對話：執行中判斷、任務或 bat 啟動、兩個接收端任務的歸屬核對（含本工具註冊內容自我核對）、停止要求、bat 正常停止關窗；暫存程式副本與替身 setup bat 的服務 API 與單一設定視窗）、`test_privilege`（接收端與監看任務的執行權限紀錄、比對文字、狀態回覆、設定頁摘要、重啟失敗說明）、`test_receiver_queries`（問法辨識、名稱建議、檢查回覆、排程結果、主機、連線、共用判定、擷取工作端到端） |

**沒有可重跑測試的保護**：第 8.3 節的 Edge 啟動與分頁連線恢復、聊天紀錄基準（`deliverySnapshot`）、傳送失敗／中斷時不重送，以及第 11.1 節停止要求在程序內重新開始期間的處理，目前沒有隔離測試（早期驗證用的測試檔從未進入 git，公司主機上也已不存在）。修改這些部分時需先補測試。

**`tools\check_files.ps1`**：唯讀掃描專案內 `.ps1／.js／.json／.bat／.html／.md`（略過 `.` 開頭的資料夾、`logs`、`captures`、`edge_profile`、`sample_images`），回報必備檔缺少、`.ps1` 缺 BOM 或無法解析（以 UTF-8 內容交給 Parser）、NBSP／零寬字元／非 UTF-8、`.bat` 非 ASCII 或 LF 換行、`.json` 無法解析、`.html` 結尾不是 `</html>`。程式類（ps1／js／json／bat）的問題為 error（exit 1），html／md 的 NBSP 等為提醒；`-PassThru` 回傳物件（file／level／message）。**此檔刻意只用 ASCII**（中文訊息寫成 `\uXXXX` 經 `[regex]::Unescape`，旁有英文註解），傳檔弄掉 BOM 時它自己才不會壞；修改訊息時要把非 ASCII 字元轉成跳脫。必備檔清單 `$required` 與本節同步。接收端 `-Listen` 啟動時（載入 `Delivery.ps1` 之前）若有此檔就先執行，有 error 即列出檔名與原因、不啟動；持續模式另寫一筆 `fatal` 心跳（stopReason「程式檔損壞…」），監看帶原因通知且不重啟。`start_teams_receiver.bat` 在接收端以錯誤結束後也執行一次，涵蓋 `teams_receiver.ps1` 本身損壞的情況。此檔不存在時略過。

**專案狀態資料**（`.gitignore` 排除 `logs/`、`captures/`、`edge_profile/`、`sample_images/annotated_*.png`、`sample_images/tmp_*`，不放進版本控制）：同機更新保留 `config.json`、`sample_images\`（每頁 `<id>_full.png`、`<id>.png`、`annotated_<id>.png`）與 `logs\`（收據、待核對、去重與工作紀錄，不可當成一般 log 全刪）。設定與校正圖片可帶往新機，但需重新抓圖驗證；不在 config 的頁面圖於服務啟動時刪除，`sample_images` 不可放其他圖片。`edge_profile\` 是監控網站登入，同機保留；可刪後重建但必須重新登入，不跨機搬加密登入。`captures\` 是排程截圖，日期資料夾保留 7 天；主程式一般 log 保留 30 天，不代表所有 logs 子目錄採同一清理規則。

**本機狀態（不在專案內）**：`%LOCALAPPDATA%\E3TeamsCdpSendTest`（排程／測試的 CDP 登入 profile、`bindings.json`、`session.json`）、`%LOCALAPPDATA%\E3TeamsCommandReceiver`（接收端的 Teams 登入與綁定）。更新程式時保留；重設時先停止相關工作與專用 Edge，再分別重新登入／綁定。新機需重新設定。

**`logs` 結構**：`logs\<日期>_<HHmm>_<排程id>.log`（主程式逐次 log）、`logs\<日期>\receipts\`（CDP 收據）、`logs\<日期>\startup_edge_*.json`／`connect_*.json`（Edge 啟動與分頁連線診斷）、`logs\teams_cdp\blocked|review`（待核對／封存紀錄）、`logs\self_tests\<id>\`、`logs\work_control\`、`logs\teams_detect\`、`logs\schedule_results\<排程id>.json`（每個排程最近一輪的傳送結果）、`logs\teams_receiver\`：`heartbeat.json`、`status.json`、`commands\<key>.json`（指令紀錄與失敗原因）、`outbox\`（待送通知）、`*_last.txt`（監看各項檢查的最新結果）、`watchdog_privilege.json`（監看任務上次執行的權限）、`<日期>\receiver_console_<時分秒>_<pid>.log`（接收視窗副本）、`<日期>\receiver_events.log`（逐筆事件）、`<日期>\watchdog_history.log`（監看結果有變化時一行）、`<日期>\receipts\`、`captures\<日期>\`。

---

## 4. 主程式參數（`e3_monitor_native.ps1`）
- 一般：`-ConfigPath`（預設同資料夾 config.json）、`-Schedule <id>`（只跑該排程；不帶則全部啟用頁面）、`-ListSchedules`、`-RegisterSchedules`、`-TestSample`（用 sample_images 不開網頁）、`-NoSend`、`-DryRun`。
- 設定工具：`-Calibrator [-Port 8765] [-NoBrowser]`、`-LoginMode`（開專用 Edge 手動登入監控網站）、`-PreviewCapture -PageId -Url -OutFile [-PreviewZoom 50..200] [-PreviewWaitSeconds 1..60] [-InteractiveCapture]`。
- Teams：`-DetectTeams [-DetectJobId]`、`-CdpSetup`。
- 內部工作（由服務或接收端啟動）：`-SelfTestJob`、`-SelfScheduleJob`、`-ReceiverCaptureJob <資料夾>`。
- 接收端監看：`-ReceiverWatchdog`、`-RegisterReceiverWatchdog`、`-UnregisterReceiverWatchdog`。`-ReceiverWatchdog` 依序執行四項，各自 try/catch、互不中斷：①排程傳送結果（只讀檔案與任務狀態）②接收端心跳與自動重啟③指令失敗說明代發④排程登入預警。只讀的放最前面，因為後面的步驟會開 Edge／傳訊息並各有硬期限（逾時直接結束程序），而 Windows 任務上限 10 分鐘。
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
    "target_chat_name": "自己", "prefer_window": "cdp", "cdp_headless": true, "receiver_headless": false, "receiver_reload_minutes": 240, "auto_press_enter": true,
    "default_message": "", "normal_summary": "", "abnormal_header": "", "attach_annotated_image_on_alert": false
  }
}
```

- **頁面**：`mode` 由設定工具依是否有啟用規則自動寫入（threshold_check／capture_only）。`browser_zoom` 50～200 整數。`zabbix_time.range` 為 `7d`／`3d`／`keep`（只切 NOW）；缺少整個物件＝NOW→7d，`enabled:false` 不操作時間列；只對 `screens.php`／`charts.php` 生效。`capture_view` 由互動抓圖產生，`layout` 必須為 `native100-v1`，其他值會停止該頁並要求重新抓圖。`crop_region` 是來源 PNG 的整數像素。`description` 用於 `@日管` 收到通知的頁面簡介。
- **帳密**：`pages[].auth` 明確覆寫，停用或 null 不回退；只有缺少 `auth` 的頁面使用全域 `auth`。佔位值 `YOUR_USERNAME` 視為未設定。
- **規則（監測項目）**：`measure_mode` 省略或 `pixel` 為警戒線像素判定；`numeric` 使用 `roi`（監測區）、`axis_roi`（左軸刻度區）、`value_threshold` 與藍線 `target_color`。所有座標相對裁切後的 PNG。`alert_message` 是純文字，`@名字` 不會變成 Teams 標註。
- **分類**：`page_categories` 只影響設定工具的顯示與搜尋；未知或缺少 `category_id` 顯示「未分類」。
- **排程**：`id` 為英數字／`_`／`-`；`name` 即 Windows 任務名稱（需唯一、≤200 字、不含 Windows 任務保留字元；空白時用 id）。`days` 空陣列＝每天，否則 `MON`～`SUN`（以開始日計算）。`pages` 依清單順序擷取並送出。`target_chat_names` 非空時覆寫頁面／全域對象，依序逐一發送；缺少此欄才讀 `target_chat_name`。收件優先序：排程 > 頁面 `target_chat_name` > `teams.target_chat_name`。`messages` 各排程獨立；缺少時由 `teams` 複製一次，刻意留空不回退。`schedules: []` 表示沒有排程；完全缺少 `schedules` 的 config 視為一個 `daily` 全頁面排程。
- **自動 Enter**：`teams.auto_press_enter=false` 在視窗模式只貼上不送出；CDP 無法留下草稿給人送，`Send-GroupToTeamsCdp` 在非 DryRun 時丟出「未送出」例外（排程記為傳送失敗 exit 1、監看通知記為 failed）。傳給自己的兩個測試固定以 true 執行。設定頁 `autoPressEnterHint` 依模式顯示提醒（CDP 且未勾選時為紅字）。
- **Teams**：`target_chat_name` 為聊天清單顯示名稱或 `自己`／`self`；含 `48:notes` 的 Teams 連結視為「自己」，其他連結與 Email 會被拒絕。設定工具經本機服務載入時以 `normalizeLegacySelfTargets` 把 teams／頁面／排程（含 `target_chat_names`，轉換後去重並移除空白項目）中的連結改存成 `自己`；畫面一律用 `targetDisplayName` 顯示，不顯示原始網址（內含組織帳號識別）。`prefer_window` 為空（自動：pwa→desktop→edge-tab）／`pwa`／`edge-tab`／`desktop`／`cdp`。`cdp_headless` 缺省視為 true。訊息組合：排程 `title` → `default_message` → `normal_summary` 或 `abnormal_header` → 超標／失敗明細；全部選填，空白項不輸出，不補預設文字。`receiver_headless`（缺省 false）只決定手機接收端的專用 Edge 是否有視窗，接收端啟動時讀取一次；與 `cdp_headless` 互不影響。`receiver_reload_minutes`（缺省或無效＝240）是接收端工作分頁在閒置時重新載入的間隔：0＝只在讀取失敗時重開，或 15～1440 分鐘整數；設定頁提供 240／30／0，存檔時 `Save-ConfigBody` 拒絕其他型別或範圍；接收端啟動時讀取一次。

---

## 6. 擷取與判定

**共用判定 `Invoke-E3PageAnalysis $page $imgPath [$label]`**（排程與 `@日管 檢查` 共用）：驗證 PNG（大小、格式、邊長／畫素），沒有啟用規則或 `capture_only` 回 `captureOnly`；否則依 6.2／6.3 逐條判定、寫 `annotated_<檔名>`，回傳 `alerts`／`failures`（排程訊息文字）、`hasAlert`、`annotated` 與結構化 `rules`（name、mode、status＝normal／exceeded／unknown、數值規則的 maximum／below／threshold／detail／reason、像素規則的 hits）。圖片無效時丟例外，由呼叫端回報。函式定義在 `Test-CurvePixel` 之後、各模式分派之前，`-ReceiverCaptureJob` 也能使用。修改判定時，以舊版與新版主程式在暫存副本對各排程跑 `-TestSample -NoSend`，比對判定輸出與標示圖雜湊。

### 6.1 擷取（`Capture-PagesNative`）
- 專用 profile `edge_profile\`，啟動前先執行 `Stop-ProfileEdge`、`Reset-CaptureProfileZoom` 並清除舊的 `DevToolsActivePort`（無法刪除即報錯停止），再以 `--remote-debugging-address=127.0.0.1 --remote-debugging-port=0`（動態連接埠）、`--disable-features=Translate,msEdgeTranslate`、`--hide-crash-restore-bubble`、`--force-device-scale-factor=1`、背景節流停用啟動。
- **除錯端點驗證與等待（`Wait-CaptureDevTools`、`Invoke-CaptureLocalJson`）**：讀取 `edge_profile\DevToolsActivePort` 取得實際埠與 browser 路徑，最多等待 60 秒（防毒掃描時不因 20 秒短逾時失敗），就緒時印出實際耗時秒數與除錯埠。以 `Get-NetTCPConnection` 與 `Get-CaptureEdgeProcessIds` 核對監聽該埠的 PID 屬於 `edge_profile` 的瀏覽器，若為其他程序立即拒絕連線並停止；本機除錯 HTTP 請求（`/json/version`、`/json`、`/json/new`、`/json/close`）一律經 `Invoke-CaptureLocalJson` 以 `Proxy=$null` 且限 Loopback 發送，不走系統／公司 Proxy。
- **程序存活判定與關閉清理（`Test-CaptureProcessAlive`、`Stop-ProfileEdge`）**：檢查程序是否仍在執行時一律使用 `Test-CaptureProcessAlive`（確認 `-not $proc.HasExited` 並於 `finally` 呼叫 `Dispose()` 釋放 Handle，避免已退出程序因 Handle 未釋放而留在 `Win32_Process`，導致 `Reset-CaptureProfileZoom` 誤判「專用擷取瀏覽器尚未結束」）。截圖結束先由 `Close-CaptureBrowser` 送出 `Browser.close`；`Stop-ProfileEdge` 除呼叫 `CloseMainWindow()` 外，若 `DevToolsActivePort` 仍由該 profile 程序監聽，亦會連上 browser WebSocket 送出 `Browser.close`（讓 `--headless=new` 無視窗程序正常關閉），5 秒逾時才連同同 profile 與子程序（`ParentProcessId`）強制結束；不影響日常 Edge。
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
- 依 `AvailableRecognizerLanguages` 選擇已安裝的 Windows OCR（優先英文，其次中文），不自動安裝。刻度區依序以 4／6／5／3／8 倍二值化、再以同樣倍率灰階辨識（`Get-E3VerifiedAxisFit`），取得兩次一致的線性比例就停止；O/o→0、I/l/i→1。
- OCR 回報的小角度 `TextAngle`（±1～3°）是自建刻度表的雜訊，不據此丟棄結果，只寫 Verbose。某一列沒有被前後綴完整包住時只略過該列（`Read-E3OcrContext` 回 null）。刻度列位置由 `Get-E3AxisBands`（純幾何、不 OCR）取得。
- 先嚴格擬合；失敗時 `-AllowInteriorOutliers` 以可讀的上下界建立比例，需 ≥6 個可讀刻度且 75% 位置誤差 ≤1.5 px，排除的讀值記在 `ignored_ticks`。不補造上下界、不沿用上次刻度。
- **框內沒有藍線**：只有在可證明時才判為正常：刻度已確認、框上緣不低於左軸最上方刻度列（`Get-E3AxisBands` 第一列 +1.5 px）、框下緣換算值不高於門檻、且整張圖仍找得到指定藍色。此時 `status=normal`、`maximum=$null`、`below`＝框下緣數值、`peak_x/peak_y=$null`，detail「框內沒有藍色曲線（貼近底部），最高值低於約 N」。任一條件不符仍 unknown 並說明要怎麼調整框或取色。
- 取 ROI 內指定藍色連通區最高點換算數值，嚴格大於門檻才超標。峰頂被框裁切、超出刻度範圍、辨識矛盾、落在誤差範圍內皆 `unknown`（列入失敗並提醒，含 alert_only）。綠線、右軸、框外曲線不納入。支援負數、小數、千分位、K/M/G/T、百分比；不支援對數軸。
- 設定頁 `/api/numeric-preview` 只試算不寫設定；正式排程每張圖重新 OCR，不讀預覽快取。

---

## 7. 排程
- `-RegisterSchedules`（設定頁自動同步／🔄 重新套用／頁首「點此同步」）以目前使用者 Interactive／Limited 註冊根目錄任務，名稱＝排程名稱；`WakeToRun`、`StartWhenAvailable`、電池可執行、上限 2 小時、`IgnoreNew`；PowerShell 以 `-WindowStyle Hidden` 執行。
- 任務所有權由**單一 action 的 PowerShell、完整 script 與 config 路徑、`-Schedule <id>`** 判定（`Get-E3OwnedTaskId`），不看名稱前綴；解析其他應用的異常路徑時視為非本專案。改名先停用舊任務、註冊新名、成功後移除舊任務；註冊失敗恢復原狀；舊任務執行中拒絕改名。
- `repeat`：觸發器加 Repetition（間隔、時段長度減 1 秒、`StopAtDurationEnd=false`）。結束時刻不再啟動；結束早於開始代表跨日。主流程取得執行權後以 `Test-E3RepeatWindow` 再檢查時段，過時補跑或已停用就略過。
- 設定頁以 `/api/schedule-status` 回讀實際觸發器（時間、星期、重複、啟用、喚醒／補跑）比對 `scheduleSignature`（不含 pages，改頁面清單只需存檔），核對通過才顯示已同步；開啟設定頁不自動註冊。
- 執行時：以 `Enter-E3WorkLock` 取得 `Local\E3MonitorNativeRun`（capture 資源）排他，忙碌時最多等 180 秒並可在設定頁選擇（見第 10 節），逾時本輪不執行；執行期間 `SetThreadExecutionState(ES_CONTINUOUS|ES_SYSTEM_REQUIRED)`；每個 worker 有 `Start-E3RunDeadline` 10 分鐘硬期限（.NET Timer，逾時 exit 124、寫 `.deadline.json`，不執行 finally、不重送）。
- 每輪正式排程寫 `logs\schedule_results\<id>.json`；沒送達時由監看任務經接收端通知（第 11.6 節）。
- `alert_only=true` 且整個排程無超標也無失敗時不發送（截圖保留）；任一頁異常則依原收件分組發送全部可用截圖。不記錄前次告警、不發恢復通知。
- 非 CDP 模式在桌面鎖定時等待解鎖最多 30 秒（同一次執行共用截止時間），逾時失敗、截圖保留。
- `Get-ScheduledTask -TaskPath '\'` 在根資料夾沒有任務時會丟例外，查詢一律列出全部後篩選 TaskPath。

---

## 8. Teams 傳送

### 8.1 共用規則（`teams_delivery.ps1`）
- 每批最多 4 張圖、原始 PNG 合計 ≤25 MiB；單張 ≤10 MiB、邊長 ≤4096、≤1600 萬畫素。多批時文字加批次序號；全空文字可只傳圖片；無圖無文字拒絕。
- 主流程逐收件對象 try/catch：一個對話失敗只記錄並繼續下一個，exit 1。發送對象仍是佔位文字時略過並 exit 1。

### 8.2 視窗模式（PWA／Edge 分頁／桌面版，UI Automation）
- 找已開啟、已登入的 Teams；在聊天清單以名稱點選，視窗標題的對話名稱必須**完全相同**（容許聊天類型前的 `(數字)` 未讀數；自己＝名稱以 `(您)`／`(You)` 結尾）。
- 開始前輸入框有草稿就停止；`Clear-E3TeamsUiDraft` 只在核對對話／焦點後 Ctrl+A、Backspace（最多三次／15 秒）。剪貼簿逐張貼圖、確認出現後貼文字，每次貼上與 Enter 前再核對前景與標題，被切走即停止。需解鎖桌面，佔用剪貼簿與前景。
- 目前設定使用 CDP，這套功能仍可在設定頁選擇，屬於支援中的功能。

### 8.3 CDP 模式（`teams_cdp\Delivery.ps1`）
- **Edge 啟動**：`Wait-E3DevToolsEndpoint` 總等待 60 秒、單次本機 HTTP 5 秒（受剩餘總時間限制），就緒立即繼續；接收端重連現有程序用 3 秒檢查。`logs\<日期>\startup_edge_<id>.json` 記錄各階段耗時、端點嘗試次數、錯誤階段／類型、清理前程序是否已退出及退出碼，不記錄 HTTP 內容或 URL；失敗訊息附診斷路徑，診斷寫入失敗不影響啟動結果。不自動重啟或重送。
- **分頁連線**：`Start-E3TestBrowser` 的初始連接用 `Connect-E3CdpPageContext -InitialBlank`，只接受新程序原本的 `about:blank`。`Connect-E3CdpPageContext` 把端點識別、連接、Page.enable／active、焦點模擬、frame／isolated world 建立及唯讀 runtime 探測放在受限恢復範圍：單次 CDP 上限 20 秒、總期限 60 秒，暫時 HTTP／CDP 逾時或 context 失效最多重連兩次，每次核對同一 browser ID、target ID、Teams URL 與本機 WebSocket 路徑。原瀏覽器／分頁消失、登入頁、識別不符及非暫時錯誤立即停止；已導航離開空白頁不當成可繼續的啟動。傳送觀察器存在時禁止初始化恢復；注入 runtime、停止舊工作、帳號選單核對、貼上及送出都不在重試範圍。`logs\<日期>\connect_<id>.json` 保存嘗試階段、耗時與 lastCommand。
- **本機 /json 讀取**：`Get-E3LocalJson` 單次 5 秒，逾時／連線失敗等暫時錯誤重讀一次（間隔 500 ms），只接受 127.0.0.1／localhost。
- **開啟 Teams 頁面的網路重試**（`Move-E3HeadlessPage`）：`Page.navigate` 回傳的 `errorText` 屬於網路類（`$script:E3RetryableNavigationErrors`：`net::ERR_TIMED_OUT`、`CONNECTION_*`、`EMPTY_RESPONSE`、`NAME_NOT_RESOLVED`、`NETWORK_CHANGED`、`INTERNET_DISCONNECTED`、`ADDRESS_UNREACHABLE`、`NETWORK_IO_SUSPENDED`、`PROXY_CONNECTION_FAILED`、`TUNNEL_CONNECTION_FAILED`）時，等 10 秒、20 秒各重新開啟一次（`-NetworkRetries`，預設 2）；其他錯誤（如 `ERR_ABORTED`）與傳送已開始（`$script:E3SendNetwork`）時不重試。這發生在貼圖之前，重新開頁不是重送。最後失敗訊息附「共試 N 次」，每次結果記在 `$script:E3CdpNavigationAttempts` 並寫進 `startup_*.json` 的 `navigationAttempts`。CDP 指令本身逾時（`CDP_TIMEOUT`）仍只重連原分頁、不再導航。接收端開對話傳 `-NetworkRetries 0 -RetriedLater`：它在持有 `E3TeamsCdpShared` 時開頁，改由來源退避（10 秒起）在不持鎖的情況下重試，避免拖住排程；`Wait-E3HeadlessChat` 內改開首頁的備援也傳 0，以免超過等待期限。排程、登入檢查與傳給自己測試用預設 2 次，每個收件對象最壞多約 90 秒（仍在 10 分鐘期限內）。
- **圖片組件**：`Send-GroupToTeamsCdp` 有圖片時，在 PNG 驗證前以 `Add-Type -AssemblyName System.Drawing -ErrorAction Stop` 載入（接收端是獨立程序，不能依賴其他程序預先載入）。圖片驗證失敗在貼上／傳送之前停止。
- **綁定**：`-CdpSetup`／設定頁「設定 CDP 收件對象」開專用 Edge（`E3TeamsCdpSendTest\profile`）。`Select-E3BindingRoutes` 列出 config 中所有收件名稱與「已綁定／尚未綁定」，可輸入多個編號（逗號分隔）或 `A`（依序設定全部尚未綁定者）；無視窗模式在同一分頁切換對話，分頁模式每個對象開新分頁（`Open-E3BindingTab`）。每個對象由 `Get-E3SelfBinding` 嚴格讀出 accountId／chatId／label（`E3Cdp.beginBinding()` 回 `ACCOUNT_PROFILE_AMBIGUOUS`、即帳號頭像數量不是 1 時，每 250 ms 重讀，最多 10 秒，不點擊；讀帳號另計 10 秒），輸入 BIND 並確認輸入框空白才寫 `bindings.json`；輸入 S 或非 BIND 即略過且原綁定不變。無視窗模式最後關閉設定 Edge，以 `Test-E3CdpRoutesReady` 用一個背景 Edge 依序驗證本次儲存的對象。每個收件名稱各自綁定；「自己」只能綁本人對話。`Resolve-E3CdpTarget` 先找完全相同的 route；找不到且名稱是「自己」的任一寫法時，接受唯一一個 `binding.isSelf=true` 的「自己」綁定。profile 被占用時詢問是否關閉重開（輸入 Y）。
- **綁定視窗**：手動綁定一律在有視窗的專用 Edge 進行。沿用已在執行的專用 Edge 前，`Test-E3BindingBrowserInteractive` 以 profile 程序與監聽埠的擁有者確認它不是 headless（例如接收端停止後留下的無視窗 Edge）；是 headless 或無法確認時不沿用，改走詢問重開流程。新開時加 `--new-window --start-maximized`；每次要求使用者選聊天室前 `Show-E3BindingWindow` 把視窗還原、最大化並帶到前景，失敗就停止並說明，不在看不到的視窗等使用者操作。
- **帳號驗證失效的重新核對**：Teams 介面重繪（例如頭像按鈕重建）後，先前的帳號證據會失效，`BridgeAdapter.inspect` 回 `GROUP_REPORT_ACCOUNT_NOT_VERIFIED`。`Restore-E3CdpAccountProof` 只在沒有傳送進行中（`$script:E3SendNetwork` 為空）且 runtime 為 idle／finished 時，重新執行 `Get-E3SelfBinding` 並要求 accountId／chatId／label 與原綁定完全相同；不導覽、不重貼、不重送。使用處：傳送前的 `resume-check.js`／`discard-draft.js` 經 `Invoke-E3PreparationCheck`（腳本在改動焦點或附件之前就回 `accountProofLost`，每次傳送最多恢復一次，恢復後穩定計時重來）、接收端讀取 `Read-E3ReceiverSettled` 與對話內切換 `Open-E3ReceiverChat`（`receiver-switch.js` 回 `reauth`；只有回到同一個已開啟的對話才原地核對，其他對話改走連結開啟與完整核對）。同一次讀取／切換／傳送再次失效即停止並說明原因。
- **無視窗（`cdp_headless` 預設 true）**：每次傳送以 headless 啟動專用 Edge（與接收端相同的啟動參數 `Get-E3TeamsBrowserArguments`：依 msedge.exe 主版本組出不含 Headless 的 `--user-agent` 與 `--window-size=1600,1000`；接收端的 `Get-E3ReceiverBrowserArguments` 也改用它），先清理同 profile 遺留的 headless 程序，以 chatId 深層連結（失敗時以完整名稱唯一選取）開啟對話，開啟對話時 `Wait-E3HeadlessChat`（診斷版本 `navigation2`）要求對話 ID 相符且帳號頭像按鈕剛好一個才算就緒，否則停在 `wait_account` 並在逾時訊息附上頭像數量；失敗診斷 `startup_*.json` 另記 `navigation` 與 `account` 階段狀態。核對帳號／chatId／label 後傳送，結束正常關閉。
- **保留視窗（`cdp_headless=false`）**：使用綁定時的專用 Edge 分頁（`session.json` 的 browserUrl + `targetId`），Edge 或分頁關閉後需重新綁定（接收端例外，見第 11 節）。
- **傳送流程**：共用 mutex `Local\E3TeamsCdpShared`（`Enter-E3WorkLock`，忙碌最多等 180 秒）；取得後重讀綁定；停止上一個 runtime、清除舊文字／圖片／附件草稿（`Clear-E3HeadlessDraftForNewDelivery`）；只處理本次內容，不讀取、續送或自動封存舊工作紀錄。每批新工作 ID；貼上前以 `deliverySnapshot` 建立聊天紀錄基準（見下）；貼圖後核對每張圖的 hash／畫素、CKEditor model ready、文字（忽略整段結尾的空白）、帳號與對話；送出前重讀聊天紀錄（`preSend`）；按一次送出。
- **聊天紀錄基準（`deliverySnapshot`，排程與手機回覆共用）**：貼上前最多 2.5 秒重讀，需連續兩次 ID、可讀正文／時間與不可解析列集合一致；只讀取，不重貼、不重送。已穩定存在、ID 唯一但缺正文／完整時間的列放進 `boundary.ids` 排除集合，不當作新回覆、不猜時間。非空紀錄至少要有一筆可讀時間錨點；缺少／無效／重複 ID、全不可讀、草稿變動即停止並回報「無法建立聊天紀錄基準」及具體原因。貼圖後與核對回覆時出現不在基準中的不可解析 ID 或失去歷史連續性，停止／保持不明。一般 `snapshot` 仍嚴格。收據的 `history`／`preSend.history` 記錄讀取次數、穩定性、rows／readable／opaque 與原因代碼（不含正文）。
- **成功判定**：DOM 出現相符的新訊息列（文字、時間、圖片數與比例、非等待／失敗狀態）**且**觀察到相符的伺服器回應（Teams messaging 端點的 POST 200/201，ID 對應；含 Dedicated Worker 的網路請求），穩定 1.5 秒以上。最終核對接受的訊息 ID 為 runtime 結果 ID、相符請求的 serverId 或 clientId（`Get-E3ServerReceipt` 回傳；Teams 可能先以 client ID 顯示再換成 server ID），其他 ID 為 uncertain；ID 改變時穩定計時重新開始，`finalReceiptHistory` 每筆記 `idRelation`（same／server_id／client_id／other／none）。基本等待 12 秒；出現 `image_count_or_loading_mismatch`／`image_shape_mismatch` 時延長到伺服器確認後 45 秒（受每批 135 秒期限限制），只讀取。未達成即 `uncertain`，保留 `logs\teams_cdp\blocked`，不自動重送。emoji 圖片正文只讀明確標記的 Unicode alt。
- **完成與中斷**：本批已取得相符伺服器及穩定畫面證據後，圖片 probe 的 stop 失敗只警告，不改判失敗；後續批次各自判定。傳送連線中斷且取消也失敗時，保留原收據 checkpoint 並另寫 `<收據>.interrupted.json`（uncertain、lastCommand、network）；不重連、不重送。
- **收據**：`logs\<日期>\receipts\<工作ID>.json`，含 editor／preSend／textComparisons（無正文）／network 摘要（無 URL、header、正文）。
- **Runtime 版本**：目前 `2026-11-12-history1`（adapter 1.0.37）；`Connect-E3CdpTarget` 與 `teams_self_test.ps1` 的白名單必須同步。相容的 receipttext1／receiptbreak1 分頁在 idle／finished 時可原地一起升級 adapter、receipt 與 runtime；不替換進行中的傳送；更舊版本需使用者核對後重新整理分頁。更動內嵌 runtime 時要更新版本字串與兩處白名單。同名 isolated world（`E3ProductionCdp`）重用同一個執行環境，runtime 只注入一次。
- **檢查 CDP 連線**（`Test-E3CdpConnection`；`/api/teams-detect` 背景工作＋`/api/teams-detect-status`；排程登入預警也用它）：只讀，核對綁定、登入、帳號與對話（ConfigurationOnly），不清草稿、不解除 blocked、不發訊息。取得 `E3TeamsCdpShared` 最多等 15 秒（接收端每讀一個對話就短暫持有）；仍取不到時回「CDP 正在傳送或設定中」（監看依這段文字判斷略過，**不可改字**）。無視窗模式由 `Test-E3CdpRoutesReady` 先 `Reset-E3HeadlessBrowserForNewDelivery`（只結束同 profile 的 headless 程序），再只啟動一個背景 Edge（`Open-E3HeadlessBrowser`），每個對象在同一分頁重新套用頁面模擬與 bootstrap 後以深層連結開啟並嚴格核對（`Open-E3HeadlessChat`）；某對象失敗就關閉該 Edge，下一個對象重開。**正式傳送仍是每個收件對象各自啟動／關閉背景 Edge（`Open-E3HeadlessTarget`）**。

### 8.4 傳給自己（測試）
- 「將目前預覽傳給自己」：前端 PNG＋文字快照 → `/api/test-self` → `-SelfTestJob`。「執行排程傳給自己」：`/api/test-self-schedule` → `-SelfScheduleJob`，以點擊當下的 config 快照完整跑一次正式流程（登入、擷取、判定），只送本人，忽略 alert_only 與 auto_press_enter=false。兩者都不改正式設定與收件人。
- 一律先辨識本人對話（CDP：綁定的 isSelf 分頁或 headless 嚴格驗證；UIA：本人標記、唯一選取列、標頭等原生 UIA 證據），在設定頁中央 dialog 顯示實際對話供確認（token、5 分鐘逾時、決定不可覆寫），確認後再重驗身分與空白輸入框才送。
- 工作狀態 `/api/test-self-status`（服務重啟後讀 `logs\self_tests\<id>\status.json`），`/api/test-self-active`／`/api/test-self-cancel` 只接受原工作 token。結果不明時保留鎖定與 ID，不重送。

---

## 9. 設定工具（`-Calibrator`，`calibrator.html`）

### 9.1 本機服務
- `http://127.0.0.1:8765`（HttpListener **單執行緒**，長工作一律背景程序；啟動時的數值自動試算會讓其他請求排隊數秒，例如新增頁面後表單要等 `ensurePageImage` 的圖片請求完成才切換）。不送 CORS；`OPTIONS` 與非本工具 Origin 一律 403。靜態白名單：`calibrator.html`、`work_control.js`、`USER_MANUAL.html`、`sample_images/*.png`；config 只能經 `/api/config`。回應帶 `Cache-Control: no-store`。單一請求例外回 500，服務繼續。前端以 `SERVICE_BASE` 呼叫 API：經服務開啟（`http://127.0.0.1:<Port>`）時為 `location.origin`，直接開檔（file://）時才用 `http://127.0.0.1:8765`（與 `work_control.js` 相同判斷），所以 `-Port` 改埠號時頁面仍讀寫同一個服務；新增 API 呼叫一律用 `SERVICE_BASE +` 或相對路徑，不可寫死埠號。
- API：`config`、`save`、`save-sample`、`delete-sample`、`capture-url`／`capture-status`（互動抓圖，同時只一個）、`commit-capture`（`Save-CaptureBundle` 在執行 mutex 內整組寫 full／crop／config，失敗回復）、`numeric-preview`、`register-schedules`、`schedule-status`、`login-setup`、`cdp-setup`、`cdp-bindings`（唯讀摘要，不回帳號／chatId）、`teams-detect`／`teams-detect-status`、`test-teams`（預設 DryRun，`?send=1` 正式送出需確認）、`test-self*`、`work-waits`／`work-decision`、`receiver-status`（GET，唯讀：`Get-E3ReceiverOverview`，不含帳號／chatId）、`receiver-register`（POST，confirm 後呼叫 `Register-E3ReceiverWatchdog`）、`receiver-control`（GET 回 `running`（`Test-E3ReceiverRunning`）與 `setupOpen`；POST `{action}`：`start`＝`Start-E3ReceiverProcess`、`stop`＝`Request-E3ReceiverStop`、`setup`＝以 cmd 開 `setup_teams_receiver.bat` 並保留 Process 物件；設定視窗開著時拒絕 setup 與 start，執行中拒絕 setup／start，未執行拒絕 stop，皆回 409；未知 action 回 400）。服務啟動時有 `teams_receiver_watchdog.ps1` 才載入，缺檔時這三個 API 回 404。`cdp-setup` 同樣保留啟動的 Process，視窗未結束前再按回 409（只防設定頁開的視窗，直接雙擊 bat 看不到）。
- 存檔：`Save-ConfigBody` 驗證可解析、頁面 id 合法唯一、排程引用存在、時段與欄位型別，先寫暫存再 `File.Replace`；失敗回 400 且原檔不變。前端每秒比對自動儲存（只有從 `/api/config` 成功讀入後才啟用；格式錯誤時顯示錯誤並停用）。
- 必須經本機服務開啟；`file://` 時嘗試轉址，否則顯示「本機服務沒有啟動」橫幅，畫面只有提示圖。

### 9.2 版面
- 三欄：左欄四分頁（`data-tab`：pages 📄 頁面與監測／schedule 📅 排程／teams 💬 Teams 與手機／site 🌐 網站與其他；按鈕圖示在上、名稱在下，避免在字中間換行）、中間畫布、右欄。`setSideTab` 記在 `localStorage e3_calibrator_tab`，舊值 send／global 對應到 schedule／site，未知值回 pages。多數區塊為 `<details>` 收合並記在 `localStorage e3PanelLayout.v1`。
- 左右欄收合：`.workspace` 欄寬用 `--left-w`／`--right-w`（365px／380px），`left-collapsed`／`right-collapsed` 時改為 44px，欄內只顯示 `.panel-rail`（其餘子元素 `display:none !important`）。`setPanelCollapsed(side, collapsed, {save})` 切換、更新畫布工具列兩端的 `toggleLeftBtn`／`toggleRightBtn`（«／»），記在 `localStorage e3_calibrator_panels`，之後 `requestAnimationFrame` 重新 `renderCanvas()`。左細欄 `#leftRail`：展開鈕＋四個分頁圖示（點了 `setSideTab` 再展開；`setSideTab` 同步標示目前分頁）。右細欄 `#rightRail`：展開鈕、🎯／👁／⚡ 對應 `currentPageJudgeBox`／`previewControlsBox`／`overallJudgeBox`（展開後捲到該區塊）；🎯／⚡ 的 `.rail-dot` 由 `MutationObserver` 跟著 `currentPageJudgeBadge`／`overallBadge` 的 class（status-ok→綠、status-alert→紅、空白→灰）。快捷鍵 `[`／`]`，焦點在 input／textarea／select／contenteditable 或有 Ctrl／Alt／Meta 時不觸發。點「目前頁面」的監測項目時若左欄收著會自動展開。用詞統一為「監測項目」（警戒線與數值門檻兩種判定方式）。
- 頁首儲存狀態 `#autoSaveStatus` 是 `<button>`：`setAutoSaveStatus` 在 error 且文字含「排程未同步／排程同步失敗」時加上 `actionable`、`data-action=sync` 與「（點此同步）」，點擊（需 `autoSaveEnabled`、未在儲存中）執行與「重新套用」相同的 `applySchedules()`；其他錯誤不可點。
- 中間畫布：✂️ 擷取範圍、📏 監測項目、💧 取色、縮放（只改預覽大小）、像素放大鏡。

### 9.3 左欄：頁面與監測
- 頁面清單：分類篩選、搜尋、卡片（「監測 N 項」／「只截圖」／「已停用」，未完成時加「⚠ 缺網址」「⚠ 未加入排程」等第一個缺的步驟）。一頁放得下（`PAGE_LIST_SIZE` 20）時隱藏分頁器與計數列。
- 清單下方 `.page-section-switch`（「⚙️ 此頁設定」／「📏 監測項目 (N)」）：`setPageSection('page'|'rules')` 設定 `.sidebar` 的 `data-page-section`，CSS 依 `data-pagesec` 一次只顯示一塊；選擇記在 `localStorage e3_calibrator_page_section`（預設 page）。`addRule` 後、點右欄「目前頁面」的項目時切到 rules；按 ✂️ 擷取範圍時切到 page。沒有選取頁面（`.sidebar.no-page-selection`）或不在頁面分頁時不顯示。
- **此頁完成度** `#pageSetupSteps`（`pageSetupSteps`／`renderPageSetup`，由 `renderTeamsPreview` 呼叫，網址輸入時即時更新）：網址（http(s) 開頭；新增時的範例網址 `your-internal-system.corp` 不算）→ 抓圖（`capture_view.layout === 'native100-v1'`，目前頁面另需非提示圖）→ 擷取範圍（需已抓圖且 w、h > 0）→ 監測項目（選填）→ 加入排程（至少一個啟用中的排程含此頁）。缺的標黃，「下一步」：網址＝聚焦網址欄、抓圖＝呼叫 `fetchLiveUrlScreenshot()`、擷取範圍＝切 ✂️、加入排程＝捲到勾選區。`firstMissingStep` 也用在頁面卡片（停用頁面不標）。只看設定與已載入的圖。
- **加入哪些排程** `#pageScheduleChecks`（`renderPageScheduleChecks`）：每個排程一個勾選框，勾選把頁面 id 加到該排程 `pages` 最後、取消則移除，接著 `renderAll()`；與排程卡片的頁面清單是同一份資料。
- `.inner-fold` 內直接放的勾選列、說明標籤與縮放輸入框使用與 `.field` 相同的字級與深色外觀。
- **監測項目編輯**：名稱欄在判定方式之前；長說明收在 `details.inline-help`（「ⓘ 怎麼操作」「ⓘ 兩個框要怎麼框」「ⓘ 排程時怎麼判定」），預設收合。項目卡片以 DOM 文字組成：判定方式＋門檻＋最近讀數（數值：「數值門檻 30・最近讀到最高約 8.05」或「最近最高低於約…」；像素：「警戒線（固定高度）・越線 N 點／沒有越線」），座標只在「進階」。「超標時的訊息」標籤註明是純文字。
- 每頁畫面來源：`sample_images\<id>_full.png`（依 crop 重裁）→ `sample_images\<id>.png` → 都沒有時顯示「這一頁還沒有畫面」提示圖（不評估監測項目）。
- 數值規則：設定與圖片載入後自動逐項呼叫 numeric-preview（串行），結果綁定規則與圖片簽章，過期結果不顯示。

### 9.4 左欄：排程、Teams 與手機、網站與其他
- 排程分頁只有「排程時段」與 Windows 同步列。Teams 與手機分頁由上而下：手機遙控（`receiverFold`，記憶鍵 `sidebar:receiverFold:v2`，預設展開）、Teams 傳送設定（`teamsSettingsFold`，最後是「正式排程貼上後自動按 Enter 送出」）。網站與其他分頁：🔐 登入監控網站、手動全部頁面的訊息文字（`messageFold`）。
- 「排程時段」`schedulesFold` 預設展開（記憶鍵 `sidebar:schedulesFold:v2`），收合摘要列出前 3 個排程的時間與名稱。`#scheduleList` 與 `.schedule-page-list` 不設內部捲軸，只由左側欄捲動。
- 排程卡片標題下兩行由 `renderScheduleRowStatus` 填入：設定摘要＋「下次」，以及 `rowLast`「上次 時間：結果」（class ok／warn／bad／running，title 為完整原因）。資料來自 `/api/schedule-status` 每個任務的 `last`：`Get-E3ScheduleTaskStatus` 讀 `LastRunTime`／`LastTaskResult` 與 `logs\schedule_results\<id>.json`，交給 `Get-E3ScheduleRunSummary`（與排程未送達通知同一套 `Get-E3ScheduleRunProblem`；watchdog 檔缺少時只有時間）。`refreshScheduleRunInfo` 在視窗取得焦點與每 60 秒（頁面可見、已從服務載入時）重讀，只更新卡片文字；完整同步核對由 `refreshScheduleStatus` 負責。
- 「手機遙控（@日管）」`receiverFold`：最上方 `.receiver-actions` 為 ▶ 啟動接收端／⏹ 停止／🔄 重新啟動／↻ 重新整理，接著是 `receiverControlResult` 與狀態列；不常用的收在 `receiverSetupFold`「⚙️ 接收端設定」（`.inner-fold`，記憶鍵 `sidebar:receiverSetupFold`，預設收合；心跳不存在＝從未啟動過時，本次開啟期間自動展開但不寫回記憶；摘要顯示視窗模式、重新載入間隔與離線通知），內含 🔗 設定接收對話、註冊離線通知與開機自動啟動、兩個選項，長說明改為 `details.inline-help`「ⓘ」，選項變更提示寫在 `receiverSettingNote`。狀態列以 textContent 顯示 `/api/receiver-status` 的接收端狀態、已執行時間、最後回報、防睡眠、視窗模式與頁面重新載入間隔（心跳的 mode／reloadMinutes 與設定不同時提示重啟接收端；舊版心跳沒有 reloadMinutes 視為 30）、各接收對話（讀不到時顯示原因）、離線通知、開機啟動、自動重啟、執行權限（overview 的 `privilege.text`，`mismatch` 時以 warn 顯示）、排程登入檢查與待送通知數。載入時、視窗取得焦點與每 30 秒（頁面可見時）更新；「註冊離線通知與開機自動啟動」先 confirm 再 POST；操作按鈕「▶ 啟動接收端／⏹ 停止／🔄 重新啟動／🔗 設定接收對話」呼叫 `/api/receiver-control`（`renderReceiverControl` 依 running／setupOpen／busy 停用；GET 失敗時 running=null、四顆全停用，並在 `receiverControlState` 以黃字寫出原因：404 代表背景服務是更新前的程式（網頁已更新、服務沒重開），請重開設定工具，其他錯誤附原因與 bat 替代做法；↻ 同時重讀狀態與 receiver-control），停止、重新啟動（執行中時）、執行中的設定先 confirm；重新啟動在接收端未執行時直接 start；重新啟動與設定在頁面端先 stop，再每 3 秒 GET 直到 running=false（最多 30 分鐘），才送 start／setup，頁面關閉則只停止不啟動；`receiverHeadlessChk` 寫入 `teams.receiver_headless`、`receiverReloadSel` 寫入 `teams.receiver_reload_minutes`（設定檔中其他合法值會加成一個選項，不改寫；兩者都是下次啟動接收端生效）。

### 9.5 右欄
- 由上而下：
  - `#currentPageJudgeBox`「🎯 目前頁面」（`renderCurrentPageJudge`，由 `renderTeamsPreview` 呼叫）：只看正在編輯的頁面，每個監測項目一行（`judgeRuleLine`，數值規則用 `numericDescription`），點一行會選取該項目並切到頁面分頁的 📏 模式；徽章為「正常／N 項超標／N 項無法判定／只截圖／已停用」。下方說明此頁屬於哪些排程：在預覽排程內就註明；不在時列出包含它的排程按鈕（點擊只改 `previewScheduleId`，不自動切換，避免改到「執行排程傳給自己」的對象）；沒有加入任何排程時提醒並指向「加入哪些排程」。
  - `.preview-controls`「👁 排程預覽與測試」：唯一的排程選單 `previewScheduleSelect`（選項含張數）、`selfTestScheduleHint`、四個測試按鈕（`testPreviewBtn`、`sendToSelfBtn`、`runScheduleToSelfBtn`、`testSendNowBtn`，都用 `previewScheduleId`）、`selfHelpFold`、`selfTestRefreshBtn`、`selfTestStatus`。測試啟動中停用選單與「目前頁面」的排程切換按鈕。
  - 「⚡ 排程判定結果」：所選排程每一頁的結果與總計徽章。
  - Teams 訊息預覽：依目前圖片估算分批。

---

## 10. 工作控制（`work_control.ps1`）
- 資源 `cdp` 與 `capture` 的占用者寫在 `logs\work_control\<資源>.owner.json`（PID＋啟動時間＋入口腳本＋描述）。等待時寫 `waits\<id>.json`，設定頁彈窗讓使用者選擇；**沒有點選絕不自動強制停止**。`Get-E3WorkOwner` 只回傳程序仍存在的占用者。
- 強制停止只結束可驗證的專用工作程序（`e3_monitor_native.ps1`／`teams_receiver.ps1` 的 worker，排除 `-Calibrator`、`-Listen`），不停 Edge 或服務；接收端等 cooperative 工作改寫 cancel 檔讓其自行停止。決定需匹配 id／token／當下 owner，重複提交不重做。
- `Test-E3ProcessElevated`：以 `WindowsPrincipal.IsInRole(Administrator)` 判斷目前程序是否持有系統管理員權限（UAC 提升或 UAC 關閉的管理員帳號），讀不到回 `$null`；只讀，不要求、不改權限。
- `Disable-E3ConsoleQuickEdit` 只改目前主控台的輸入模式（清 0x0040、設 0x0080），保留 Ctrl+C；設定服務、CDP 設定與接收端共用。

---

## 11. 手機 `@日管` 遙控（接收端）

### 11.1 設定、啟動與停止
- **設定**：`setup_teams_receiver.bat`（`Set-E3CdpBinding -SelectInBrowser`）在 `E3TeamsCommandReceiver` 的有視窗 Edge 由使用者選對話後 BIND，可連續綁本人、其他個人與多個群組（最多 20 個，route／帳號＋chatId 不可重複；不支援團隊頻道）。接收只需要綁定中的 accountId／chatId／label，設定時開的分頁之後不需保留。接收端執行中（`Local\E3TeamsCommandReceiver` 存在）拒絕 setup。
- **啟動**：`start_teams_receiver.bat`（`-Listen -Continuous`）；`test_teams_receiver.bat` 回覆一個指令或 10 分鐘後結束。啟動時先執行 `tools\check_files.ps1`（見第 3 節）。`Local\E3TeamsCommandReceiver` 防重複啟動。
- **設定頁操作**：設定頁「手機遙控」卡片四個按鈕與 `setup_／start_／stop_teams_receiver.bat` 做同一件事（見 9.1 `receiver-control`）。啟動時 `Start-E3ReceiverProcess` 優先用已註冊、本工具所有且未停用的「E3 日管接收端」任務（Running 時先 Stop，因為停在 pause 的舊視窗會讓 IgnoreNew 擋掉新的），接收端因此是任務的一般權限；任務不可用時以 cmd 執行 bat（監看自動重啟用 Minimized、設定頁用 Normal），本身是系統管理員時回覆中提醒。`Test-E3ReceiverRunning` 以 `TryOpenExisting` 判斷接收端 mutex，存取被拒（系統管理員權限的接收端）也視為執行中；測試以 `$script:E3ReceiverMutexName` 換成隔離名稱。`start_teams_receiver.bat` 在接收端 exit 0（正常停止）時 `exit /b 0` 關閉視窗，錯誤結束才執行 check_files 並 pause。
- **停止**：`stop_teams_receiver.bat`（`-Stop`）或設定頁 `Request-E3ReceiverStop` 寫 `logs\teams_receiver\stop.request`（兩者相同，心跳 stopReason「已依停止要求結束（設定頁「⏹ 停止」或 stop_teams_receiver.bat）」），主迴圈每 3 秒檢查後正常結束。明確啟動只在取得接收端 mutex 後清除舊停止標記；程序內重新開始傳入 `PreserveStopRequest`，2／15 秒等待期間每最多 250 ms 檢查停止檔，下一次入口在載入對話或 Edge 前處理。進行中的截圖／傳送按原流程結束。Ctrl+C 與 stop 都在心跳記為 `intentional`，監看不會重啟；直接關閉黑色視窗視為異常結束，會被監看重新啟動。

### 11.2 指令（規則式問法辨識）
- 聊天文字只用來挑選已設定的名稱與固定查詢，**從不執行**；不使用 AI。
- **前綴**：以 `@日管` 開頭，後面接空白（半形、全形 U+3000、NBSP），或直接接已知指令字（`$starts`：狀態、截圖、檢查、主機、排程、連線、說明…），所以 `@日管狀態` 可用、`@日管理員…` 不算。`receiver-snapshot.js` 只把 `^@日管[ 　]*\S` 當候選，是否為指令由 `Resolve-E3ReceiverRequest` 決定；不是指令的候選仍建立 claim，狀態 `ignored`、不回覆。
- **判斷順序**（先去掉前後客氣話：請、幫我、麻煩、謝謝、嗎、標點…，存成 `$q`）：上一個指令 → 說明 → 打招呼（回「我在」＋執行時間＋用法）→ 狀態 → 清單 → 主機（有主機字、沒有截圖字也沒有頁面名稱時）→ 檢查（檢查、多少、數值、超標、門檻、最高、正常嗎…；「截圖並檢查」也是檢查）→ 截圖（截圖、抓圖、擷取、截一張、拍一張、給我看）→ 連線（連線、連得到、打不開、ping…）→ 排程（排程、有送、沒收到、發了、結果…）→ 只有名稱（視為截圖）→ 看不懂（「這句我還看不懂」＋可能的名稱建議＋用法）。「為什麼截圖失敗／沒回」是上一個指令，「為什麼沒收到」是排程。
- **名稱**：每次讀 config，完整名稱優先、英數邊界不模糊匹配（P14 不匹配 P14_D3）；清單（、，, 跟 及 和 與 以及）依輸入順序；`頁面 名稱`／`排程 名稱` 解決重名；名稱可寫在截圖字前面。每次最多 20 頁。找不到時 `Get-E3ReceiverSuggestions` 給最多 3 個建議（忽略大小寫與 `_ - 空白`、包含關係、字母順序顛倒、編輯距離 ≤ 長度/4），**只建議、不代選**；清單中某項找不到時其他項照做並附建議。檢查／連線的文字中有像名稱的英數字（`Get-E3ReceiverLooseWords`）卻對不到任何名稱時，回覆建議而不是擴大成全部頁面。
- **截圖**：排程名稱只取其 pages，不觸發 Windows 任務、不群發、不判定。收到通知（`Get-E3ReceiverAcknowledgement`）列出頁面簡介；`Get-E3WorkOwner 'capture'` 有占用者時說明要等它結束（最多 3 分鐘）。結果附「擷取時間 MM/dd HH:mm，花了 N 秒」；沒截到的頁寫「名稱：沒有截到。原因：…」。
- **檢查**（`analyze`）：同一條擷取流程，`request.json` 帶 `analyze=true`，子工作在每頁擷取成功後呼叫 `Invoke-E3PageAnalysis`，`result.json` 每頁多 `analysis`（captureOnly、rules、annotated 檔名、error）。回覆第一行「檢查結果（時間，花了 N 秒）：🚨 n 項超標、⚠️ n 項無法判定、✅ n 項正常」，每頁頁名後每個監測項目一行白話結果，只截圖的頁註明，沒截到的頁寫原因；圖片優先附標示圖（≤10 MiB）。不填名稱時檢查所有啟用且有啟用規則的頁面。只回覆原對話、不發給排程收件人、不寫排程結果。
- **查詢**（`teams_receiver_queries.ps1`，釋放 CDP 鎖後執行；查詢本身失敗時回覆「…查詢沒有完成。原因：…」）：
  - 排程結果 `Get-E3ReceiverScheduleReport`：篩選＝排程名稱，否則時段字（早上 0–12、中午 11–14、下午 12–18、晚上 17–24，或「9點」「晚上7點半」取該小時），否則全部。每個排程一行（`Get-E3ReceiverScheduleLines`，與設定頁相同的判斷與原因），再附最近 26 小時內最新一份 `logs\yyyy-MM-dd_HHmm_<id>.log` 中以 ❌／⚠️／🚨 開頭的行（去重，最多 6 行，每行 150 字）。不執行、不補跑。
  - 主機 `Get-E3ReceiverHostReply`：開機時間、CPU、記憶體、每顆本機磁碟剩餘空間（標出程式所在磁碟；<10% 或 <5 GB 標「空間不足」）、讀不到的接收對話（`$script:E3ReceiverLiveSources`）、`Get-E3ReceiverHealthLines`，各部分讀不到時分別說明，最後一行整體結論。資料來源 `Get-E3ReceiverHostFacts`（CIM），可替換以便測試。
  - 連線 `Get-E3ReceiverConnectReply`／`Test-E3ReceiverSite`：每個不同網址一次 GET（8 秒、自動轉址、`UseDefaultCredentials=false`、不帶 cookie，只讀標頭）。2xx／3xx＝連得到，401／403＝連得到但要求登入，其他 HTTP 碼與 DNS／連不上／逾時／憑證／TLS 各有白話原因。不填名稱時測所有啟用頁面。
- **上一個指令**（同義：上個指令、最近指令、指令紀錄，或含「為什麼…失敗／沒回／沒反應」）：`Get-E3ReceiverHistoryReply` 列出同一個對話最近 5 筆指令與結果／原因，不顯示其他對話的指令。
- **狀態**：主機名稱、連續執行時間、排程數，以及各排程 Windows 任務的上次結果（`Get-E3ScheduleRunSummary`，沒送達或部分失敗時附原因）與下次時間；未同步、停用、讀不到任務清單會明示。再加 `Get-E3ReceiverHealthLines`：排程用的 Teams 登入（`sender_login_state.json`，只在 CDP 模式）、離線監看任務、執行權限（「執行權限：…」，接收端 `$script:E3ReceiverElevated` 對照 `watchdog_privilege.json`）、待送通知數、這個對話最近 24 小時沒完成的指令數。
- **執行權限比對**（`Get-E3PrivilegeComparison`，純判斷，定義在 `teams_receiver_watchdog.ps1`）：只有「接收端是系統管理員、監看任務不是」算 `mismatch`（監看無法結束卡住的接收端，自動重啟會失敗）；相同為「一致」，反向不影響；任一方沒有紀錄時說「尚未回報」。監看任務每次執行時（建立 480 秒期限後）寫 `watchdog_privilege.json`（elevated、utc）；設定頁經 `Get-E3ReceiverOverview` 的 `privilege` 顯示。只記錄與提醒，不改權限、不要求提升。
- 回覆以「✦ [日管]」開頭、保留分行不插空行（`Format-E3ReceiverText`）。

### 11.3 讀取（單一工作分頁）
- **防重複**：只處理接收端啟動之後、位於最新位置、兩次快照文字／ID／時間一致的訊息；以帳號＋chatId＋時間雜湊建立持久 claim（`New-E3ReceiverClaim` → `commands\<key>.json`）後才處理；`seen` 在 claim 建立成功後才加入（建立前的儲存失敗可於恢復後重選，已存在的紀錄含不完整檔案一律不重送）。忽略「✦」開頭、含圖片、引用、傳送中、超過 400 字的訊息。
- 一個專用 Edge、一個分頁服務所有綁定對話。`Initialize-E3ReceiverTab` 沿用仍在執行且模式相符的專用 Edge（只採用該 profile 自己寫的 DevToolsActivePort 且監聽埠屬於該程序），模式不符先正常關閉再重開；bindings 中其他舊分頁會關閉。`Set-E3ReceiverBindingTab` 把所有接收綁定的 `targetId` 指向工作分頁，因為回覆沿用 `Send-GroupToTeamsCdp`（經 bindings.json 找分頁）；接收端呼叫時固定傳 `cdp_headless=$false`（使用現有分頁），**不可改成 true**，否則會把接收端自己的瀏覽器當成遺留程序清掉。
- **讀取只核對聊天室**：綁定帶 `groupReport` 時，`BridgeAdapter.inspect` 每次都要求帳號頭像證據有效（`refreshIdentity` 比對頭像按鈕元素與其文字指紋）；長時間開著的頁面在頭像被重畫或狀態文字改變時會失效，導致反覆重新驗證與整頁重開。接收端的唯讀動作因此改用 `Get-E3ChatOnlyBinding`（綁定去掉 `groupReport`）：`receiver-snapshot.js`、`receiver-switch.js` 經 `Get-E3ReceiverScript` 注入它；`Open-E3ReceiverChat` 以 `Wait-E3HeadlessChat -ChatOnly`（`navigation.js` 的 `requireAccount=false`，不等頭像）與 `Connect-E3CdpTarget -ChatOnly`（只以 adapter 核對 chatId 與名稱，不開帳號選單）開啟對話。**帳號仍在每次回覆前完整核對**：`Enter-E3ReceiverChat` 用一般的 `Connect-E3CdpTarget`（`Get-E3SelfBinding`）與 `Assert-E3ReceiverDestination`，`Send-GroupToTeamsCdp` 的檢查也照舊。排程傳送、登入檢查與傳給自己測試不使用這兩個選項。
- `Open-E3ReceiverChat`：頁面已準備好時先用 `receiver-switch.js` 在 Teams 內切換（只點擊聊天清單中名稱唯一相符的項目，點一次後最多等 6 秒並以 chatId 核對；同名、不在清單、未切換都回 `reopen`），否則以 chatId 連結整頁開啟（同一連線先註冊 `image-frame-bootstrap`，`Wait-E3HeadlessChat` 75 秒，再由 `Connect-E3CdpTarget` 嚴格核對）。主迴圈由 `Get-E3ReceiverNextSource` 取「到期且最久未讀」的來源，`Invoke-E3ReceiverVisit` 讀兩次相隔 500 ms 的穩定快照後交給 `Select-E3ReceiverCommand`；單一來源每圈 1 秒、多來源每圈 300 ms。頁面載入超過 `$script:E3ReceiverReloadMinutes`（`Get-E3ReceiverReloadMinutes` 讀 `teams.receiver_reload_minutes`，預設 240；0 時不定期重載）在下次讀取時整頁重載；讀取失敗的來源（`source.reload`）不論設定都改以連結重開。啟動訊息以 `Get-E3ReceiverReloadText` 印出目前間隔。
- 送出前（收到通知、結果、待送通知）一律 `Enter-E3ReceiverChat`：切回來源對話、`Connect-E3CdpTarget`、`Assert-E3ReceiverDestination`。**不檢查輸入框空白**：殘留草稿交給 `Send-GroupToTeamsCdp`（分頁模式 `Clear-E3HeadlessDraftForNewDelivery -Visible`，先核對分頁、帳號、對話並停止舊 runtime 工作）清除；在這裡要求空白會讓一次中斷的貼上擋住之後所有回覆。
- **最新訊息讀取**（`receiver-snapshot.js`，viewport 版本 `receiver-latest2`）：不使用發送端的 `followLatest`／`atLatest`／`snapshot`。以 `BridgeAdapter.inspect` 核對綁定與 label，在對話根節點內找唯一可捲動的訊息清單（找不到或不唯一即回錯誤）；可見的「回到最新訊息」按鈕最多每 2 秒點一次，點擊或捲動後本次回傳 `latest:false`，下次讀取穩定在底部（誤差 ≤2 px，支援 column-reverse）才讀指令。不聚焦輸入框、不送鍵、不碰草稿與其他捲軸。無法解析的列（卡片、通話紀錄、已刪除訊息等）只計入 `skipped`；指令列嚴格要求唯一 ID、單一正文、完整含時區時間、純文字（表情圖示除外）、無引用、非傳送中。`Read-E3ReceiverSettled` 在期限內（預設 8 秒）每 400 ms 重讀，「尚未到最新」只是等待。
- **有視窗／無視窗**（`teams.receiver_headless`，預設有視窗；有視窗新開時加 `--window-size=1600,1000`，與無視窗相同大小，避免窄視窗讓 Teams 收起頭像）：無視窗以 `--headless=new` 啟動，並用啟動參數 `--user-agent`（依 msedge.exe 主版本組出不含 Headless 的字串）與 `--window-size=1600,1000`（CDP 重連會失去連線層級的模擬）。有視窗時每 15 秒以 `Browser.getWindowForTarget` 檢查，被最小化就還原（最小化會停止繪製）。

### 11.4 處理與失敗說明
- 截圖／檢查指令先送收到通知（等傳送鎖最多 180 秒），釋放 CDP 鎖後由 `Invoke-E3ReceiverCapture` 啟動 `-ReceiverCaptureJob` 子程序以 headless 擷取（期限 300 秒，父程序最多等 330 秒；`E3MonitorNativeRun` 排他，排程執行中最多等 180 秒），結果回覆等傳送鎖最多 420 秒；處理中心跳 `busyUntil` 1500 秒。回傳前重新核對原來源、帳號、對話，以原 route 回傳。同一時間只處理一個指令；處理期間不讀取其他來源。
- 截圖回覆由 `ConvertTo-E3ReceiverCaptureReply` 依子工作資料夾的 `result.json`（每頁 `error`、整體 `error`）、`deadline.json`、結束代碼與 `capture-error.log` 組成，原因經 `Format-E3ReceiverReason`（去掉內部前綴、單行、限長）；等不到擷取執行權寫成「排程或另一個擷取正在執行，等了 3 分鐘仍未輪到」。回傳的 `problems` 寫進指令紀錄。
- **指令紀錄** `commands\<key>.json`（version 3，`Save-E3ReceiverClaimState`，每個狀態都帶 `route`、`command`、`messageTime`）：`claimed`→（截圖／檢查）`ack_sending`→`acknowledged`→`replied`（含 `images`、`problems`）；失敗 `not_retried`（含 `phase`：received／acknowledgement／capture／result，與 `error`）；`ignored`；`interrupted`。
- **失敗說明**：主迴圈 catch 在指令已領取且未回覆時，寫 `not_retried` 後以 `Add-E3ReceiverOutbox` 排入一則純文字說明（`New-E3ReceiverFailureText`：台灣時間＋指令、`Get-E3ReceiverPhaseText` 依階段說明可能已送出什麼、原因、不會自動重做），`route`＝原對話、`kind=command_failure`；`E3_RECEIVER_RELOAD` 也先記錄與排入再往外丟。
- **中斷**：`Resolve-E3ReceiverInterruptedClaims` 在取得接收端 mutex 之後，把 6 小時內仍停在 claimed／ack_sending／acknowledged 且有 `route` 的紀錄先改成 `interrupted` 再排入一則說明；同一筆只說一次，指令不重做。
- **離線期間的指令**：第一次啟動時讀舊 `heartbeat.json` 的 `utc` 當作 `E3ReceiverOfflineFrom`（7 天內才採用）。每個對話第一次成功讀取時，`Get-E3ReceiverMissedCommands` 找出畫面上時間落在（上次心跳, 本次啟動]、且沒有指令紀錄的 `@日管` 訊息，排入一則「這段時間有 N 個指令沒有處理」到該對話（每個對話每個程序一次，`E3ReceiverMissedDone`）。只列出、不補做；只看得到畫面上仍載入的訊息。
- **代發**：接收端自己送不出說明時檔案成為 `.failed`。監看任務的 `Invoke-E3FailedNoticeRelay` 只處理 6 小時內、`kind=command_failure` 的 `.failed`：先改名 `.relaying`，再用排程的 Teams 登入（`Send-GroupToTeams`）送到 `teams.target_chat_name`，文末註明原對話，結果 `.relayed`／`.relayfailed`，每輪最多 3 則、各只試一次；需要 `prefer_window=cdp`。紀錄在 `notice_relay_last.txt`。
- **監看任務的監看**：接收端啟動 20 分鐘後每 10 分鐘 `Test-E3ReceiverWatchdogTask`：「E3 日管接收監看」已註冊且啟用，卻超過 30 分鐘沒執行（或註冊後從未執行）連續兩次，就排入一則通知到本人對話；任務恢復前不重複。未註冊或停用只在狀態回覆中說明。

### 11.5 容錯、心跳與紀錄
- **容錯與復原**：任何來源讀取、截圖、傳送例外都不結束接收程序。`Set-E3ReceiverSourceFailure` 只影響該來源：退避 10→20→40→80→160→300 秒，下次改以連結重開，其他來源照常；同一原因只印一次。`E3_RECEIVER_LOGIN` 讓全部來源暫停 60 秒；`E3_RECEIVER_BROWSER` 清掉分頁狀態，20 秒後重建。有視窗模式看到 Microsoft 登入頁時 15 分鐘內不再導覽，留給使用者登入。對話改名（label 不同）回 `E3_RECEIVER_SOURCE`，需重新綁定。bindings.json 被改寫丟 `E3_RECEIVER_RELOAD`。`Start-E3ReceiverSupervised`：持續模式遇到未預期例外不結束程序，15 秒後（RELOAD 為 2 秒）重新進入 `Invoke-E3ReceiverTest`，沿用第一次啟動的指令時間界線（`E3ReceiverCutoff`）；只有 `E3_RECEIVER_FATAL`（沒有綁定、重複綁定、重複啟動）會結束。復原不重讀、重試或回覆先前的指令。
- **防睡眠**：接收期間 `SetThreadExecutionState(ES_CONTINUOUS|ES_SYSTEM_REQUIRED)`，允許關螢幕與鎖定，不改電源計畫，結束時解除。
- **心跳** `heartbeat.json`（持續模式，version 2）：state（listening／processing／restarting／stopped）、pid、processStart、computer、startedUtc、utc、busyUntilUtc、sleepGuard、stopReason、reloadMinutes、elevated（`Test-E3ProcessElevated`，啟動時讀一次）、mode（window／headless）、intentional、fatal、sources[route, active, lastOkUtc, error]；最多每 30 秒一次，連上、處理前、回覆後與結束時強制寫入。
- **紀錄**：`Start-E3ReceiverLog` 在 `-Listen` 入口以 `Start-Transcript` 寫 `<日期>\receiver_console_*.log`，每 3 秒的檢查順便換日（`Update-E3ReceiverLog`）；`Write-E3ReceiverEvent` 寫 `<日期>\receiver_events.log`（時間、種類、內容），`Save-E3ReceiverStatus` 每次都會寫，另有 start／end／fatal／restart／command／command_failed／notice_queued／notice_sent／notice_failed。寫入失敗不影響接收；`-LibraryOnly` 不啟動 transcript。
- **紀錄保留**：啟動時與每 24 小時清理：`captures\<日期>` 超過 7 天、`<日期>` 資料夾與 `commands\*.json` 超過 30 天、outbox 中已完成的檔案（`.sent`／`.failed`／`.expired`／`.invalid`／`.relaying`／`.relayed`／`.relayfailed`）超過 30 天；不碰 `teams_cdp`（blocked／review）、heartbeat、status、watchdog 檔與待送的 `*.json`。

### 11.6 監看任務與通知佇列
- **監看**（`-ReceiverWatchdog`，Windows 任務「E3 日管接收監看」每 10 分鐘）：無心跳、stopped、程序不存在、心跳超過 10 分鐘（不在 busyUntil 內）、啟動滿 10 分鐘後任一來源超過 10 分鐘未成功讀取，皆異常；60 秒後再確認。只支援 CDP 模式，用排程的 Teams 登入傳純文字「✦ [日管監看]」到 `teams.target_chat_name`。`watchdog_state.json` 先記錄再傳送；同次離線只通知一次、失敗不重試；只有離線通知 sent 才發「已恢復」。不持有 `E3MonitorNativeRun`。`Write-E3WatchdogLog` 覆寫 `<名稱>_last.txt`，內容有變化時另在 `<日期>\watchdog_history.log` 加一行。
- **自動重啟**：`Get-E3ReceiverHealth` 回傳 `kind`，`Get-E3ReceiverRestartPlan`（純判斷）只對程序已結束（dead）、非要求的停止（stopped）與卡住（stale，先結束經 PID＋啟動時間＋命令列核對的接收程序）重啟；`intentional`、`fatal`、從未啟動、程序仍在但讀不到 Teams（sources）、或存在 `stop.request` 都不重啟。15 分鐘內不重複、一小時最多 3 次（`watchdog_restart.json`，先記錄再動作）。重啟失敗且心跳的 `elevated=true`、監看本身不是系統管理員時，通知的失敗原因後附「接收端以系統管理員權限執行，監看任務權限較低，無法結束它…」（`Get-E3PrivilegeComparison`）。`Start-E3ReceiverAutoRestart` 先確認接收端 mutex 不存在，優先以 Stop／Start「E3 日管接收端」任務重新啟動（停在 pause 的舊視窗仍算執行中，IgnoreNew 會擋掉新啟動），任務不可用時直接執行 start_teams_receiver.bat。重啟當次不通知，下次檢查仍異常才通知並附重啟結果。
- **排程登入預警**（`Invoke-E3SenderLoginCheck`）：排程用的 Teams 登入過期時無法用同一份登入通知自己，所以結果交給接收端（另一份登入）發送。只在 `prefer_window=cdp` 時執行；`Test-E3SenderLoginDue`：從未檢查、距上次 ≥6 小時、下一個本專案排程（`Get-E3NextScheduleRunUtc`）在 70 分鐘內且距上次 ≥3 小時、或上次異常且已過 30 分鐘；下一個排程在 5 分鐘內時不開始。檢查用 `Test-E3CdpConnection -PassThru`；CDP 鎖忙碌時略過且不更新狀態。**連續兩次失敗才通知**（第一次只記 `ok=false`、`pending=true`，下次監看距上次 ≥5 分鐘再檢查）。`sender_login_state.json` 記錄結果；確認異常時排入「✦ [日管監看] 排程用的 Teams 登入需要處理…」，異常期間不重複，恢復時排入「已恢復」。`Local\E3SenderLoginCheck` 防重入，420 秒期限。
- **排程傳送結果通知**（`Invoke-E3ScheduleResultCheck`）：主程式在正式排程（`-Schedule`，不含 `-SelfScheduleJob`／`-TestSample`／`-NoSend`／`-DryRun`）開始時寫 `logs\schedule_results\<id>.json`（state=running），等不到執行權改 `no_lock`，finally 寫 `finished`（exitCode、targets、delivered、sendFailures、error、skipped＝`outside_window`／`alert_only_normal`）。被 10 分鐘期限強制結束時留下的 running 即「中斷、結果不明」。監看依 `Get-E3OwnedTaskId` 列出本專案任務，讀 `LastRunTime`／`LastTaskResult`；執行中（267009）或從未執行（267011）不判斷。結果檔 startedUtc 落在 LastRunTime −2～+15 分鐘才算同一輪，否則只依任務結果代碼（0 不通知）。`Get-E3ScheduleRunProblem`（純判斷）：running、no_lock、有 sendFailures、或 exitCode≠0 且沒有任何對象送達 → 通知；頁面失敗但訊息已送達不另通知，skipped 不通知。`schedule_result_state.json` 記錄每個排程已處理的 LastRunTime，**先記錄再排入**，同一輪只通知一次；首次檢查時超過 24 小時的舊結果只建立基準。多個排程合併成一則，紀錄在 `schedule_result_last.txt`。測試用 `$script:E3WatchdogLogRoot` 指向暫存目錄。
- **通知佇列**（接收端 `Send-E3ReceiverOutbox`，每 5 秒）：只接受以「✦」開頭、≤2000 字、6 小時內的 `outbox\*.json`（否則改名 `.invalid`／`.expired`）。有 `route` 的項目（指令失敗／中斷／離線說明）只送到那個綁定對話：該對話已不在綁定中改名 `.invalid`，尚未連線就留在佇列且不擋住其他通知；沒有 `route` 的送到已綁定的本人對話，沒有本人對話時用第一個來源，未連線時保留等待（不改送其他群組）。先以 `WaitOne(0)` 取得 `E3TeamsCdpShared`（忙碌時保留、5 秒後再試），取得後才改名 `.sending` 並送，結果 `.sent`／`.failed`，每則最多嘗試一次；只有 `kind=command_failure` 的 `.failed` 會由監看代發。
- **自動啟動**（Windows 任務「E3 日管接收端」）：登入 Windows 1 分鐘後執行 `start_teams_receiver.bat`，無執行時間上限、IgnoreNew。兩個任務由 `register_receiver_watchdog.bat` 或設定頁一起註冊；action 不含 `-Schedule`，`-RegisterSchedules` 不會刪除它們。`Test-E3ReceiverTaskAction` 判斷任務是否屬於這份安裝：autostart 核對 Execute 為本資料夾的 `start_teams_receiver.bat`；watchdog 核對單一 action、Execute 為 powershell、參數含 `-ReceiverWatchdog` 且 `-File` 為本資料夾的 `e3_monitor_native.ps1`（不比對 config 路徑，換 config 仍可重新註冊）。另一份安裝的同名任務在註冊時擋下、移除時略過、狀態顯示為其他任務。

---

## 12. 已知限制、刻意保留與待辦

### 12.1 限制
- 網頁版面隨縮放／內容變化：改縮放、網址或版面後需重新抓圖並確認監測項目；不保存 iframe／表格內部捲軸、不重演點擊流程。圖片上限單邊 16384、總 6400 萬像素。
- 自動登入只認固定按鈕文字與密碼框；SSO／MFA／特殊表單需手動登入。帳密以明文存在 config.json 與瀏覽器 localStorage。
- Zabbix 時間調整只支援舊版 `timeControl`／`scrollbar_cntr` 介面與英文 `(now)` 標籤；新版、其他語系、iframe 需另外適配（無法確認即此頁失敗）。
- 數值 OCR 需主機有可用的 Windows OCR 語言；不保證任意字型與影像品質；另一台主機的實際 OCR 結果需現場驗證。
- 視窗模式（UIA）需解鎖的互動桌面，Teams 改版可能影響定位；名稱須與清單完全一致，清單最多往下捲 10 頁。
- 系統睡眠期間沒有程式執行；喚醒受硬體、電源與公司政策限制。防睡眠請求無法阻止手動睡眠、闔蓋、登出或斷電。
- 接收端：主機重開後需登入 Windows 任務才會執行；群組沒有發送者白名單，任何綁定群組的成員都能使用全部指令（使用者決定暫不限制，因此查詢一律唯讀）；排程與接收端使用兩份不同的 Teams 登入，兩者同時失效、主機關機／睡眠／無人登入時沒有任何通知管道。多對話時每個對話約 2～3 秒（估計），輪讀會把對話標為已讀。能讀到頁面不等於 Teams 服務在線。
- 問法辨識是固定字詞規則：沒列到的說法回「看不懂」與用法；新增說法要改 `Resolve-E3ReceiverRequest` 並補 `test_receiver_queries.ps1`。檢查與排程使用同一把擷取鎖。連線測試不帶 Windows 認證，整合驗證的網站會回 401（仍視為連得到）。
- 指令紀錄與事件紀錄含指令文字，保留 30 天；代發會把指令文字送到 `teams.target_chat_name`（可能與原對話不同）。
- 設定工具在視窗寬度約 900px 以下時三欄會擠壓（未做窄螢幕版面，可收起左右欄緩解）；1280 寬時畫布工具列會換行。
- 設定視窗單一實例只涵蓋設定頁開啟的視窗（服務保留 Process 物件，服務重啟後不知道先前開的視窗）；直接雙擊 `setup_cdp.bat`／`setup_teams_receiver.bat` 不受此保護。
- Windows Server 可擷取與判定；UIA 操作 Teams 需有人登入且解鎖；CDP 在 Server 未驗證。

### 12.2 刻意保留的相容程式（確認公司主機狀態後才能刪）
- `Get-E3CdpRecordRoot` 的舊紀錄搬移：`%LOCALAPPDATA%\E3TeamsCdpSendTest\blocked|review` 存在時才搬到 `logs\teams_cdp`。
- `Connect-E3CdpTarget`／`teams_self_test.ps1` 白名單中的舊 runtime 版本（保留視窗模式可能遇到舊分頁）。
- 舊設定格式：缺 `schedules`／`messages`／`auth`、`48:notes` 連結、頁面 `target_chat_name`、`capture_only`。

### 12.3 待公司主機實測
- 接收端讀取只核對聊天室、開對話不等頭像、有視窗固定大小：長時間開著時重新驗證與整頁重開是否明顯減少，需在公司主機觀察 `receiver_events.log`。
- 帳號驗證失效的重新核對、綁定視窗自動顯示與最大化、headless 傳送改用固定 user-agent 與視窗大小：只有隔離模擬（`test_account_proof`），真實 Teams 的頭像重建時機與重新核對是否穩定需實測。
- CDP：伺服器回應與手機實收要分開驗證；無視窗、多圖、隔夜與其他主機需各自實測。Teams 登入過期／MFA 需人工處理。
- 接收端：單一工作分頁、對話內切換、容錯讀取、無視窗長時間執行、鎖定螢幕時有視窗模式是否持續更新、深層連結在有視窗 Edge 對「自己」對話的行為。
- 接收端頁面重新載入改為預設 4 小時（可選 30 分鐘／只在讀取失敗時）：Teams 頁面長時間不重新載入是否變慢或記憶體持續增加，需在公司主機觀察。
- 設定頁啟動／停止／重新啟動／設定接收對話：只以替身任務與替身 setup bat 驗證；公司主機上經「E3 日管接收端」任務啟動是否為一般權限、正常停止時視窗是否自動關閉、重新啟動等待期間的畫面需實測。
- 執行權限紀錄：公司主機雙擊 `start_teams_receiver.bat` 時視窗標題顯示「Administrator」，接收端與「E3 日管接收監看」任務實際回報的權限與是否 mismatch 需看 `@日管 狀態`。
- 失敗說明、中斷與離線通知、代發、接收端視窗紀錄（長時間 `Start-Transcript` 的大小與換日）、啟動檔案檢查。
- 手機新指令（檢查、排程結果、主機、連線）的實際回覆與耗時；設定頁新版面（目前頁面、完成度、加入排程勾選、頁首同步）在公司主機的實際操作。

### 12.4 待辦
- 手冊尚未說明的 CDP 內部紀錄：`startup_edge_*.json`、`connect_*.json`、`<收據>.interrupted.json`，以及停止要求在程序內重新開始的等待期間也會生效。
- 為第 3 節「沒有可重跑測試的保護」補隔離測試，優先順序：傳送結果不明時不重送、聊天紀錄基準、停止要求。
- 手機查詢：自訂查詢框架（C6，放 Zabbix API／資料庫／檔案查詢）與補跑排程只回給自己（C5）；Zabbix、資料庫、檔案查詢需使用者提供連線方式與實際問題。
- 設定頁第三組（分頁重整為 頁面／排程／Teams 與手機／網站與其他）尚未決定是否進行。
