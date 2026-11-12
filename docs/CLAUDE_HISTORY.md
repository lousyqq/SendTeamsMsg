# CLAUDE.md 歷史紀錄（2026-11-10 封存）

> 這是 2026-11-10 精簡前 CLAUDE.md 的完整內容，依版本逐段記錄開發過程、使用者回報、驗證範圍與當時限制。目前架構與規則以根目錄 CLAUDE.md 為準；此檔僅供追查歷史，不會在每次對話自動載入。

# 接收端優化：輪詢不寫檔、紀錄保留、狀態回覆（2026-11-10，receiveropt1）

- 工作占用紀錄：接收輪詢原本每秒每來源 `Register-E3WorkOwner 'cdp'`，等於每秒寫入並刪除 `logs\work_control\cdp.owner.json`。現在只在來源未連線（重新連線／自動恢復，可能持有鎖數秒到約兩分鐘）時登記；穩定輪詢只持鎖數毫秒，不登記。回覆、通知仍經 `Enter-E3WorkLock` 登記。實測 12 秒輪詢由約 12 次降為 1 次。
- 紀錄保留：`Clear-E3ReceiverOldLogs` 在接收啟動時與之後每 24 小時執行。只刪 `logs\teams_receiver\captures\yyyy-MM-dd`（超過 7 天，與主程式 captures 相同）、`logs\teams_receiver\yyyy-MM-dd`（收據與啟動診斷，超過 30 天，依資料夾名日期）及 `commands\*.json`（指令 claim，修改時間超過 30 天；早於接收啟動 cutoff 的訊息本來就不會再被選取）。不碰 `teams_cdp`（blocked／review）、heartbeat、status、watchdog 檔、非日期資料夾與連結目錄。
- `@日管 狀態`：加主機名稱、接收端連續執行時間，以及每個排程的 Windows 任務結果（依 action 的本專案 e3_monitor_native.ps1 與 `-Schedule <id>` 對應，`Get-ScheduledTaskInfo`）：上次時間＋成功／執行中／有頁面或傳送失敗（代碼 1）／逾時（124）／其他代碼，及下次時間；未同步提示按「重新套用」，停用排程標示已停用，讀不到任務清單時明示。只讀，不執行排程。`狀態` 後可接 。！!？? 單一標點。
- `Get-ScheduledTask -TaskPath '\'` 在根資料夾沒有任務時會丟例外（本機實測），狀態回覆與 receiverwatch1／receiverrecover1 的任務註冊／移除都改為列出全部後篩選 TaskPath。修正前在全新主機會讓 `register_receiver_watchdog.bat` 直接失敗。
- `Update-E3CdpReceiptRuntime`：舊版 runtime（receipttext1 以前）通過版本白名單後，原本顯示原始錯誤碼 CDP_RUNTIME_REFRESH_REQUIRED／DELIVERY_STILL_ACTIVE，現改為中文說明（核對後重新整理原分頁，不需重新綁定；或待傳送結束），其他錯誤原樣拋出。
- teams_receiver.ps1 改為先 dot-source `work_control.ps1` 並使用 `Disable-E3ConsoleQuickEdit`，移除重複的 QuickEdit 實作；仍在載入 CDP 模組前停用。
- 未實作：群組發送者白名單（需從 Teams DOM 取得發送者識別，現有 adapter 不讀作者，無真實 DOM 無法安全驗證）；排程與接收端共用同一份 Teams 登入（牽涉兩種 Edge 模式與鎖，屬大型重構）。
- 驗證：紀錄清理 4 項（7／30 天邊界、claim、blocked／heartbeat／非日期資料夾不動）、狀態行 4 項（替身任務成功／失敗／未同步／停用／讀不到）、真實 config＋本機任務清單完整回覆、標點 4 例、舊版 runtime 訊息 3 例、輪詢寫檔次數；監看 18 項、指令解析 6 例、任務定義與 ListSchedules 回歸通過。未連真實 Teams。

# 接收端 Edge／分頁自動恢復與登入自動啟動（2026-11-10，receiverrecover1）

- 取代下節「重開後須重跑 setup」的限制。接收迴圈在來源未連線時先呼叫 `Repair-E3ReceiverSource`：`Get-E3ReceiverBrowserState` 分為 ok、tab（Edge 在、綁定分頁已關）、browser（session.json 無效、Edge 結束或重開）。只處理這兩種情形；分頁仍在但跑到別的對話或登入頁時不自動導航，沿用原錯誤與 10 秒重試。
- `Open-E3ReceiverBrowser`：profile 無 `Default` 時要求先跑 setup，不開空白 Edge。profile 已被 Edge 使用時，只採用該 profile 自己寫的 DevToolsActivePort，並核對監聽埠屬於該 profile 程序，才改寫 session.json；無法連線則請使用者關閉該 Edge，不強制結束。沒有任何程序時以 `Start-E3TestBrowser`（有視窗）重開並沿用原登入資料。
- `Restore-E3ReceiverTarget`：在專用 Edge 開一個分頁（新 Edge 用其空白分頁），注入 image-frame bootstrap，沿用無視窗傳送的 `Move-E3HeadlessPage`（chatId 深層連結）＋`Wait-E3HeadlessChat`（90 秒，完整名稱唯一選取、登入頁 20 秒判定過期），再用正式 `Connect-E3CdpTarget` 嚴格核對 accountId／chatId／label 才接受。成功後 `Update-E3ReceiverBindingTarget` 在 E3TeamsCdpShared 下只改該 route 的 targetId（帳號、chatId、label 必須與記憶體相同，否則拒絕並請重啟接收端），其他綁定原樣保存。
- 每個來源恢復失敗後 60 秒冷卻，錯誤保留在心跳 sources.error（監看通知會顯示，例如登入過期）；同一來源只保留一個恢復分頁並在下次重用，登入頁留給使用者處理，不會每次多開分頁。恢復不讀舊訊息、不重送：cutoff、seen 與 claim 紀錄不變，恢復後仍需兩次相同快照才處理新指令。
- 自動啟動：`-RegisterReceiverWatchdog`／`register_receiver_watchdog.bat` 現在同時註冊「E3 日管接收監看」與「E3 日管接收端」。後者為 AtLogOn（目前使用者，延遲 1 分鐘）執行 `start_teams_receiver.bat`、Interactive、無執行時間上限（PT0S）、IgnoreNew；接收 mutex 防止重複。兩個任務註冊前先一併檢查同名任務是否為本工具建立（watchdog 看 `-ReceiverWatchdog` 參數，autostart 看 action 是否為本資料夾的 start_teams_receiver.bat），否則兩個都不變更；`-UnregisterReceiverWatchdog` 只刪本工具建立者。主機重開後仍須有人登入 Windows（或公司允許的自動登入）任務才會執行；不會處理 Teams MFA。
- 驗證：真實 Edge（測試時以無視窗參數、暫存 profile）＋替身 Teams 導航與身分核對，16 項通過：Edge 未開→自動開啟並更新 targetId、其他綁定不變、session 正確；Edge 在但分頁關閉→同 Edge 新分頁；session.json 過期→採用原 Edge 不開第二個；登入失敗→保留原因、60 秒冷卻、重試重用同一分頁、登入恢復後在該分頁完成；Edge 被強制結束→新程序重開；正常時不導航；綁定被修改→拒絕；無登入資料→要求 setup 且不開 Edge。另以替身跑真接收迴圈，確認恢復後照常接收並寫心跳；任務定義只建立物件核對（PT10M 無限重複、AtLogOn 延遲 PT1M、PT0S），未註冊真實任務。真實 Teams 深層連結在有視窗 Edge 的導頁、MFA 與 A 主機重開機流程仍待實測。

# 接收端防睡眠、心跳與離線通知（2026-11-10，receiverwatch1）

- 目標：A 主機長時間開著接收端，讓手機 @日管 隨時可遙控。檢查發現接收端不阻止自動睡眠、離線時使用者無從得知，本次補上；Edge／主機重開後的自動恢復見上節 receiverrecover1。
- 防睡眠：`Invoke-E3ReceiverTest` 取得接收 mutex 後以 `[E3CdpDesktop]::SetThreadExecutionState(0x80000001)`（ES_CONTINUOUS|ES_SYSTEM_REQUIRED）要求系統保持清醒，不含 ES_DISPLAY_REQUIRED，允許關螢幕與鎖定，不改電源計畫；finally 以 0x80000000 解除（Ctrl+C 會執行 finally；程序被結束時 OS 自動解除）。測試模式（非 Continuous）也套用。無法阻止手動睡眠、闔蓋、登出、斷電，Modern Standby 機型未實測。
- 心跳：僅 `-Continuous` 寫 `logs\teams_receiver\heartbeat.json`（`Write-E3WorkJson` 原子取代）：state（listening／processing／stopped）、pid、processStart（與 Test-E3WorkProcess 同格式）、startedUtc、utc、busyUntilUtc、sleepGuard、stopReason、sources[route, active, lastOkUtc, error]。每輪最多 30 秒寫一次；來源接上、處理指令前（busyUntil=+1200 秒，涵蓋 330 秒擷取與兩次鎖等待）與回覆後強制寫入；結束時先解除防睡眠再寫 stopped。單次測試模式不寫，避免覆蓋持續接收的心跳。寫入失敗只警告，不影響接收。
- 監看：新檔 `teams_receiver_watchdog.ps1`（UTF-8 BOM），由主程式 `-ReceiverWatchdog` 載入。`Get-E3ReceiverHealth` 為純判定：無心跳、stopped、程序不存在（pid＋啟動時間）、心跳超過 10 分鐘且不在 busyUntil 內、啟動滿 10 分鐘後任一來源超過 10 分鐘未成功讀取，皆異常並附原因。異常時等 60 秒再讀一次確認，避免寫檔瞬間或睡眠喚醒後誤報。
- 通知：只支援 `teams.prefer_window=cdp`，透過主程式 `Send-GroupToTeams` 傳純文字到 `teams.target_chat_name`（與排程共用 E3TeamsCdpSendTest 登入，與接收端 E3TeamsCommandReceiver 登入不同）。文字以「✦ [日管監看]」開頭，不會被接收端當成指令。`watchdog_state.json` 先寫 alerted／notify=sending 再傳送，結果 sent／failed；同一次離線只通知一次、失敗不重試（沿用不自動重送原則）；恢復時只有先前離線通知 sent 才發「已恢復」，否則靜默重設。不持有 E3MonitorNativeRun，避免延誤正式排程；`Local\E3ReceiverWatchdog` 防重入，480 秒 Start-E3RunDeadline。非 CDP 或未設定對象時 exit 1 並寫 `watchdog_last.txt`，不改狀態。
- 排程：`-RegisterReceiverWatchdog`／`register_receiver_watchdog.bat` 註冊根目錄任務「E3 日管接收監看」：Once 觸發＋每 10 分鐘無限重複、Interactive／Limited、StartWhenAvailable、IgnoreNew、10 分鐘上限、不要求喚醒。同名但 action 不含 `-ReceiverWatchdog` 的任務拒絕覆寫；`-UnregisterReceiverWatchdog` 只刪本工具建立者。action 無 `-Schedule`，`Get-E3OwnedTaskId` 不視為排程任務，重新套用排程不會刪除它，設定頁排程狀態也不列出。
- 驗證（離線，未傳 Teams、未註冊真實任務）：監看判定 8 情境與通知去重 10 情境（替身 Send-GroupToTeams）共 18 項通過，含未送出不發恢復、非 CDP 不送；真接收迴圈以替身 CDP 執行，確認心跳內容、30 秒節流、來源接上強制寫入、被強制結束後判定程序已結束、無綁定時 stopped＋原因；SetThreadExecutionState 執行緒狀態 0x80000001 與解除；主程式 `-ReceiverWatchdog` 以非 CDP 暫存設定確認接線與 exit 1。`powercfg /requests` 需系統管理員，未能從系統面確認；任務註冊與實際 Teams 通知待 A 主機驗收。
- 本輪同時：測試機版本 NBSP→空白、.ps1 補 BOM、.bat CRLF（傳輸造成，原檔無誤）；calibrator.html numeric-preview fetch 截斷行補回；teams_self_test.ps1 白名單補 receiptbreak1；receiver-snapshot.js 移除誤貼內容；teams_cdp/READRE.md 改名 README.md。必備檔案新增 teams_receiver_watchdog.ps1、register_receiver_watchdog.bat。

# 左軸上下界與中間刻度容錯（2026-11-10，取代舊版逐字一致限制）
 
- 使用者案例：左軸實際 35,30,25,20,15,10,5,0，但 OCR 把 15 讀成 5、10 讀成 0，原本單一中間誤讀就使整組失敗。`Get-E3AxisFit -AllowInteriorOutliers` 以本次可讀上下界建立比例，至少六個可讀刻度、75% 刻度位置符合 1.5 px 誤差才容忍少數中間誤讀；不捨棄或補造上下界。先走原嚴格擬合，失敗才採容錯；仍需兩次影像辨識的比例互相符合才採用。`ignored_ticks` 保留排除的讀值供診斷。沒有固定 35，也不沿用上次截圖的刻度。
- 藍線 ROI 峰值約 32、門檻 30 => exceeded；低於門檻 => normal；證據不足、上下界錯讀、兩次比例矛盾、峰頂裁切、找不到藍線或落在門檻誤差範圍 => unknown 並給原因。未知結果不再把四輪 OCR 數字全部堆進 Teams 回覆。綠線、右軸和框外尖峰仍不納入。
- 驗證 `tools/test_numeric_axis_retry.ps1`：重現上述兩個中間誤讀仍得到 32.02／30 超標，亦測正常、臨界、錯誤上下界、過多誤讀、不同上下界 40～180、兩次不一致。`tools/test_numeric_monitor.ps1 -OutputDir tools/validation_numeric_axis_20261110` 通過本機 Windows OCR、單位、色線、ROI、裁切與實際排程分析（全部攔截發送）。另一台電腦 OCR 未直接驗收，沒有傳送真實 Teams。
- 累積包 `SendTeamsMsg_20261110_Axis_Bounds_Update.zip`，包含上一版 CDP 設定修正。保留 config／登入／綁定／圖片／logs。完成目前工作後重開設定服務與 Teams 接收程式，網頁重新整理；不需重填門檻或重建排程。
 
# CDP 檢查後重新設定（2026-11-10）
 
- `/api/teams-detect` 改為啟動背景檢查並回傳 id；`/api/teams-detect-status` 依直接子程序完成狀態回報。移除會阻塞單執行緒 HttpListener 的 `Start-Process -Wait`，不等待 Edge 後代程序；檢查期間設定與工作選擇 API 仍可回應。重複點檢查沿用現有工作，每次結果寫入 `logs/teams_detect/<id>.txt`，命令列直接檢查仍用 `logs/teams_detect.txt`。
- 檢查工作登記 CDP 操作權。重新設定遇到占用時，沿用明確的等待／強制停止前一工作／取消選擇，不自動搶占。清理失敗也必須釋放綁定的 mutex；檢查不發訊息、不清草稿或舊收據。
- 設定服務與互動 CDP 設定停用當前主控台 QuickEdit，保留 Read-Host 與 Ctrl+C，防止滑鼠選取讓主控台暫停。網頁 API 每次回應最多等待 8 秒，設定按鈕顯示開啟中並在錯誤後恢復，逾時不自動重開設定。
- 工作選擇的暫存檔採同目錄短名稱，避免重複串接 token/GUID 超過 Windows 路徑長度。
- 隔離驗證：`tools/test_cdp_detect_setup.ps1` 覆蓋檢查完成／失敗後設定、檢查中設定、後代程序未退出、重複檢查及使用者明確交接；`tools/test_cdp_detect_ui.ps1` 以 Edge 攔截全部 HTTP 驗證輪詢、設定並行、逾時與按鈕恢復。另跑原綁定與工作控制測試。未對正式 Teams 發訊息，使用者現場卡住畫面仍待核對。
- 累積更新包 `SendTeamsMsg_20261110_CdpSetup_Responsive_Update.zip`。完成或取消現有操作後關閉設定服務，覆蓋並重新開啟 `open_calibrator.bat`、重新整理網頁。保留 config、圖片、profiles、Teams 綁定與全部 logs；不需重建排程。不新增更新 README。
 
# 工作選擇與藍線門檻（2026-11-10，優先於下方舊版等待說明）
 
- work_control.ps1 統一追蹤 capture／cdp 的占用工作。排程、本人的實際排程測試、抓圖預覽、Teams 指令截圖、CDP 發送與設定遇到占用時，先讓短暫操作完成；仍忙碌則寫入 logs/work_control 等待要求，由設定頁 work_control.js 彈窗顯示目前工作、新工作、等待時間，以及「繼續等待」「強制停止前一工作，執行新的」「取消本次新工作」。沒有點選絕不自動強制停止。繼續等待可延長本次等待，仍受原有總工作期限限制；設定頁須保持開啟，右下角可重新開啟等待選項。不經 Teams 發送選擇提示，以免提示也受傳送鎖阻擋。
- 強制停止限定當下顯示的 owner token，核對 PID／建立時間／專用程式路徑／啟動參數。只結束可驗證的工作程序，不停止 Edge 或設定服務；接收端用取消訊號停止當前回覆，保留接收迴圈。先取得 OS mutex 才開始新工作，不能在前一工作仍持有操作權時同時操作。無法辨識的舊版占用者不允許猜測 PID 強制停止，會顯示原因。更新時須重新啟動設定服務、接收程式與相關工作。
- 新的本人測試按鈕在舊測試進行中仍可點選，先查 /api/test-self-active 並顯示選擇；繼續等待保留原測試，強制停止後才建立新 ID。/api/test-self-cancel 只接受原工作 controlToken，使用服務保存的原 Process handle。worker.json 保存 PID／建立時間／token，服務重啟後僅恢復路徑與參數相符的自有工作，不自動啟動或重送。已自然完成的工作不改寫成取消。未知舊版程序沒有可驗證資料時不強制停止。
- /api/work-waits 與 /api/work-decision 沿用本機同源限制；決定須匹配要求 ID／token／當下 owner，先到決定生效，相同 token 重複提交不重做，過期／不同 owner 拒絕。紀錄為當前操作控制與選擇稽核，不用歷史送信結果阻擋新工作。強制中止不撤回已發訊息，不重送舊內容。
- 数值監控以 ROI 內指定藍色曲線的最高點，換算左 Y 軸後與 value_threshold 比較；綠線、右側秒數及框外曲線不列入。數值模式在框內畫出「門檻 N（左軸）」虛線。Get-E3VerifiedAxisFit 先用 4x／6x 二值化 OCR；未取得兩次有效比例時改試保留灰階的 4x／6x。至少兩次有效線性比例一致才採用；相互矛盾仍 unknown，不能硬設 35～0 或推測修正數字。失敗顯示實際 OCR 讀到的數字。沿用邊界誤差與峰頂裁切檢查。
- 本機 sample_images P58_D3 使用 axis_roi 54,19,25,230、ROI 1673,35,128,203，實際 en-US Windows OCR 讀到 35,30,25,20,15,10,5,0；藍色最高值約 5.092、門檻 30、結果 normal。另一台電腦的原始 OCR 錯讀尚未重現，不能以本機結果宣稱該機已修復。
- 驗證：真實隔離 mutex／可丟棄工作測試明確選擇、無自動強停、錯 token／owner、逾時；真實 loopback API 驗證強停後可開始新測試、服務重啟恢復正確工作、重複決定與跨來源拒絕；隔離 Edge 驗證彈窗、無自動 POST、文字安全顯示、重複點擊與 owner 改變。既有接收容錯／多來源、本人按鈕非同步流程、Windows OCR／排程分析測試通過。所有傳送測試均攔截，沒有向真實 Teams 發訊息。
# CDP 新工作等待操作權（2026-11-10）
 
- Send-GroupToTeamsCdp 原本 WaitOne(0) 遇到任何共享 CDP 操作（含接收快照）就立即丟出「另一個 CDP 傳送或設定尚未結束」。現在先嘗試立即取得；忙碌時等待最多 180 秒，取得後繼續這次新工作。一般傳送等待後重讀綁定，避免使用等待前的舊對象；SelfTest 沿用取得鎖後辨識本人。接收端已持有同名 mutex 時仍可重入。
- 取得操作權後沿用既有身分核對、停止舊 runtime、清除舊草稿／附件、新 ID／本次內容流程。歷史收據不是此鎖的來源，不刪歷史紀錄、不重送舊內容、不強制中斷其他程序正在執行的傳送或設定。逾時仍占用則明確回報尚未貼圖／送出；原有總工作期限不變。
- tools/test_cdp_send_lock.ps1 使用隔離的真實 mutex 與另一執行緒模擬占用，驗證釋放後新工作進入準備一次、持續占用時逾時且不準備、等待後綁定再核對及接收端重入。瀏覽器初始化為測試停止點，未開 Teams 或發送。本人新工作測試亦改用隔離 mutex，以免影響正式接收。
# CDP 工作紀錄統一到專案 logs（2026-11-10）
 
- 使用者要求 C:\Users\...\AppData\Local\E3TeamsCdpSendTest\blocked 等工作紀錄統一管理。Get-E3CdpRecordRoot 使用模組所在專案 logs\teams_cdp；blocked 保存待確認標記、review 保存封存及同名衝突紀錄。原 logs\日期\receipts、startup 摘要與工作紀錄沿用原位置。Get-E3CdpStateRoot 僅繼續保存登入 profile、bindings.json、session.json，避免重新登入／綁定。
- 首次讀寫工作紀錄時，在共用 E3TeamsCdpShared mutex 下搬移舊 blocked/review 檔案（含巢狀目錄）。跨目錄以串流複製到短暫存檔、Flush、SHA-256 核對、目的地同磁碟 rename 完成後才移除原檔；保留原 bytes、工作 ID、結果及 receipt 連結。重跑同內容不重複，衝突保留既有 active block，舊內容依 SHA-256 封存在 review/migration_conflicts。損壞 JSON 不解析、不丟掉；占用／不可寫／連結路徑／來源目的相同等停止並保留原紀錄。搬移不解除阻擋、不送訊息，不觸及登入／綁定。
- 來源舊目錄可留空目錄，不再寫入新紀錄；每次存取都檢查，能處理舊 worker 結束後才留下的檔案。更新須停止工具、服務與舊 worker；跨專案拷貝部署應以實際執行的安裝目錄為準，傳送收據中的舊路徑仍代表其原始位置。
- test_cdp_record_storage.ps1 20 項檔案／mutex 測試；pending recovery 20 情境、本人新工作 86 檢查、profile restart，以及 headless 準備與 retained-page 草稿兩種 loopback 全流程通過。既有測試改用隔離 log root；測試產物留 TEMP，專案 logs\teams_cdp 已清掉本輪 fixture 記錄。這些不等於公司 Teams 實送；本機沒有正式 AppData 舊目錄，桌機更新後首次檢查／排程才會搬移其舊檔。
- 累積包 SendTeamsMsg_Central_Logs_Update.zip。保留設定、登入、綁定、截圖、收據與 Windows 排程；不需重設對象。無新增 README。
# Teams 多來源聊天指令與即時截圖（2026-11-10）
 
- 啟動檔編碼修正：舊版 LF + UTF-8 中文 title 在 CMD 初始 code page 950 實際重現「'1'／亂碼 Teams 不是內部或外部命令」。改為 ASCII + CRLF，其他封裝啟動批次檔一併統一 CRLF。使用中文含空白暫存路徑與無網路 stub 驗證初始 code page 950、65001 都僅啟動一次，Listen／Continuous 參數正確，無 CMD 錯誤。打包加入批次檔 CRLF 與接收啟動檔 ASCII 檢查，避免再次回歸；未啟動實際 Teams 接收或傳訊。
 
- 截圖意圖提示：帶 @日管 前綴且含「截圖」，但沒有名稱或未匹配時，回覆「想截哪個項目呢？請從下方清單選擇名稱。」並列出目前启用項目、排程與指令範例。清單全數不可用或缺少項目時也附清單供選擇；部分有效仍照常擷取。名稱衝突則詢問符合的選項。這是單次 help 回覆，不擷取、不發收到通知，也不建立跨訊息追問狀態；後續仍輸入完整 @日管 截圖 名稱。69 項指令檢查及回覆流程檢查通過，未實送 Teams。
 
- 接收視窗防暫停：Listen 啟動時先停用目前 console 的 Quick Edit（清除 0x0040、設定 Extended Flags 0x0080），保留 Ctrl+C 等其他旗標，不改全域登錄或其他視窗。LibraryOnly／Setup 不修改 console；無 console 時略過，API 失敗只提示不終止。載入模組前顯示啟動提示，start_teams_receiver.bat 使用純 ASCII 指令與英文視窗標題、Windows CRLF；中文提示由 UTF-8 BOM 的 PowerShell 程式輸出。舊視窗標題出現「選取」時按 Esc 或 Enter 恢復；標題列選單手動進入標記模式仍可暫停。
 
- 2026-11-10 接收容錯：來源初始化與重新連線都在迴圈內執行，共用傳送鎖忙碌時等待下一輪。讀取、設定、截圖及傳送例外不結束接收程序；失敗來源每 10 秒重建 CDP context 並重新核對原帳號／對話／綁定，恢復後須兩次相同快照才處理指令。保留啟動 cutoff、seen 與磁碟 claim，不重做已嘗試指令，也不清除舊收據或草稿。原分頁／登入須恢復；重新 BIND 仍須重啟以採用新綁定。
- 狀態檔寫入失敗只警告；失敗結果寫入失敗保留原 claimed 紀錄，不影響接收。新指令無法建立 durable claim 時不傳送，仍保留服務等待後續指令。start_teams_receiver.bat 持續待命；test_teams_receiver.bat 仍在成功處理一個指令或 10 分鐘逾時後結束。
- tools/test_receiver_recovery.ps1 用隔離 mutex、暫存紀錄及模擬重連時鐘驗證：回覆不明、通知不明、讀取斷線、啟動未就緒、設定讀取失敗、紀錄寫入失敗、對話驗證失敗；同一来源後續新指令可回覆，舊指令不重送。這是本機故障模擬，未實送 Teams，也未驗證另一台電腦的長時間運行。
 
- setup_teams_receiver.bat 直接開專用 Teams，使用者自行選個人或群組聊天，Enter 核對後 BIND；每個來源重複設定一次；start_teams_receiver.bat 持續接收，Ctrl+C 停止；test_teams_receiver.bat 保留單次回覆／10 分鐘等候模式。專用 Edge 須保持開啟；使用 %LOCALAPPDATA%\E3TeamsCommandReceiver 的登入與綁定、專案 logs\teams_receiver 紀錄，不變更 config 或排程收件對象。
- 只接收文字前綴「@日管 」加指令：@日管 狀態、@日管 截圖清單、@日管 截圖 P14_D3、@日管 幫我截圖警戒線測試。前綴後必須有空格，允許多個空格與 Teams 顯示用 NBSP；不接受省略前綴、少空格、換行當分隔或原本的 / 指令。這是輸入文字，不需選取 Teams 帳號標註。瀏覽器篩選與 PowerShell 分派均檢查前綴，未知的已指定指令回覆目前支援的功能與用法：查詢狀態、截圖清單、單張、多張及依排程名稱擷取圖片；以項目名稱／排程名稱作為填入範例，提示先查清單。不觸發擷取、不額外送收到通知。一般聊天仍忽略，保留含「截圖」時的清單提問提示。以「截圖」加設定內的完整頁面／排程名稱辨識，非自由語意模型；P14 不匹配 P14_D3。名稱衝突回覆選项，支援「@日管 截圖 頁面 名稱」／「@日管 截圖 排程 名稱」。名稱每次讀 config；當前有 P14、P58、CMS、KPI、P14_D3、P58_D3，排程 MSD日管Index測試、警戒線測試，沒有「特殊頁面監控」。
- 多頁指令支援 @日管 截圖 P14_D3、P58_D3，以頓號／中文逗號／英文逗號或「跟、及、和、與、以及」分隔完整頁面名稱，可省略分隔字旁的空格並混用。清單依輸入順序、以頁面 ID 去重，沿用同一 New-E3ReceiverCaptureRequest 驗證與 20 頁上限；找不到、停用、重名或無效 ID 保留提示並處理其餘有效頁。空項目要求修正，完整設定名稱本身含分隔字時優先視為單一名稱；Split-E3ReceiverNames 依長名稱優先辨識完整名稱，再辨識外部連接字，即使在多項清單內也保留「和平監控」「報表甲、乙」等名稱。清單不展開排程；排程用原本單一名稱指令。既有批次傳送負責超過 4 張圖或 25 MiB 時分則，不自動重送。DOM 清單輸入及接收流程兩張圖分派測試通過，未重新實送 Teams。本輪 test_receiver_commands.ps1 共 63 檢查通過，涵蓋口語連接字、混合分隔、完整名稱保護、重複去除與部分失敗；P14 不模糊匹配 XP14 或 P14_D3。
- 指定排程只使用 pages 順序選頁、去重，不觸發工作排程器、不依原收件人群發、不做警戒判定。手動指令可使用停用計時的排程，但停用頁面不擷取；缺頁／停用／失敗有提示，成功圖片照常傳回原對話。每次最多 20 頁。
- teams_receiver_commands.ps1 負責名稱辨識與工作啟動；e3_monitor_native.ps1 -ReceiverCaptureJob 只執行 teams_receiver_capture.ps1 的擷取分支，在排程主流程之前結束。重用 Capture-PagesNative、已登入 edge_profile、capture_view、browser_zoom、zabbix_time 與 crop_region。每個指令獨立輸出資料夾；不讀 sample_images 或舊截圖，不寫出含帳密的 config 複本。
- 擷取時釋放 E3TeamsCdpShared；子工作以 E3MonitorNativeRun 排他使用監控網站 profile，忙碌就回報失敗。子工作期限 300 秒，父程序最多等候 330 秒；截圖完成再鎖定 Teams、重新核對本人身分與空白輸入框，固定透過觸發指令的來源 route CDP 傳送。傳送後 socket 會被釋放，持續接收必須重連同一綁定分頁。
- 接收程式啟動之前的訊息不執行；新指令須完整時間、頁面最新位置、訊息連續、兩次相同文字與 ID／時間觀測。以帳號／chatId／時間建立持久 claim，再擷取／傳送，結果不明不重送；編輯同時間訊息不另建執行。SendTeamsMsg 回覆前綴、圖片訊息、引用訊息、傳送中及超過 400 字文字不當指令，避免回覆觸發自己。傳送結果不明時保留 claim，不重送該指令；10 秒後重連，繼續處理同一來源的新指令。
- 原 /狀態 回覆已由使用者確認成功。receiptbreak1 修正 BR 後 CRLF 被算成雙換行；Connect-E3CdpTarget 會在 idle／finished 時更新相容的 receipttext1，不替換傳送中的工作。保持伺服器訊息 ID、正文、圖片與防重送核對。
- 驗證：前綴／名稱／多頁清單／選頁／部分失敗 50 項檢查；真實瀏覽器 DOM 指令篩選；接收流程 40 項檢查，含模擬兩次指令、傳送後重連、防重送及 claim。本機新擷取 P14_D3 成功，1873×417 與保存裁切相符；指定警戒線測試亦實際取得 P14_D3、P58_D3 兩張新圖。新指令從手機發出並收到圖片、整晚及锁定使用仍需實測，不能用本機測試替代。工具與說明保留於既有維護文件，不另新增 README。
- 2026-11-10 跨機測試更新包：SendTeamsMsg_20261110_WorkChoices_Axis_Update.zip，沿用 tools/package_update.ps1 的來源／壓縮內容 SHA-256 檢查。目標電腦第一次啟用接收端須 setup_teams_receiver.bat 建立該機各聊天来源綁定，不複製本機 session。
- 本輪依使用者修正範圍：支援本人、其他個人與多個群組聊天；團隊頻道暫不需要，未實作貼文／回覆串接收。Get-E3ReceiverTargets 驗證最多 20 個來源，拒絕重複 route、targetId 或帳號／chatId。每個來源有獨立 baseline、cutoff、seen、context、endpoint、active；切換來源依專用 websocket 重新連線，不能借用其他分頁 context。
- 輪流讀取所有來源，擷取期間釋放 CDP 鎖。傳送前重新 Resolve route 並比對啟動時保存的 targetId／accountId／chatId／label，防止擷取期間重新綁定導致送錯。實際畫面再次用 AllowGroup 核對身分，傳送固定使用原 target.route。來源失敗進入 10 秒重連等待，其他來源繼續；即使所有來源暫時失敗，Continuous 接收迴圈也持續待命。未確認的指令仍保留 not_retried；已回覆的來源紀錄不因後續錯誤變成未送。
- 驗證：test_receiver_multichat.ps1 通過 25 項，涵蓋 A/B 原路回覆、同時間指令隔離、A uncertain 不影響 B、重新綁定不得改送新來源；既有接收 40 項及真實瀏覽器 DOM 篩選通過。實際 MSD群組經唯讀核對，isSelf=false、身分／訊息快照／最新位置皆通過；未發訊息、未代存綁定。真正群組收到圖片及另一台主機仍待使用者測試。
- 接收端改用 Set-E3CdpBinding -SelectInBrowser，略過來源名稱與編號提示，驗證所選對話後自動取 label；重綁同一 accountId/chatId 取代原 alias（含舊 self），不同同名來源加數字避免覆蓋。原排程綁定流程未使用此 switch，維持原收件名稱。test_receiver_choose_chat.ps1 驗證直接選取、取消不改綁定、本人來源改名及同名不同群組隔離；不發訊息。
- 日管回覆保留語意分行，不插入空白行：署名、提示、分類標題、每個清單選項與每張圖片說明各一行。Format-E3ReceiverText 統一保留換行並移除空白行，ImageReply 參數保留相容性。清單直接列設定名稱，不重複加「頁面／排程」前綴；傳圖例如「已擷取 P14，最近 7 天圖表」。
- 圖片結果依使用者要求不顯示「已完成 X/Y 頁截圖」計數；保留署名、頁面與時間範圍的口語描述、失敗提示，移除「圖片順序」「圖片如下」與重複的頁名。
- 日管回覆改為「✦ [日管]」，包含狀態、清單、收到通知、圖片結果與錯誤。有效截圖指令由 Get-E3ReceiverResponse 的 BeforeCapture 回呼，先呼叫 Send-E3ReceiverAcknowledgement，確定原 route／帳號／chatId／分頁與空輸入框後送出收到通知，再執行擷取。通知包括每页名稱、Zabbix 與 7d／3d／keep／disabled 的實際設定說明；其他網站不臆測天數，可附 config 既有 description。URL 與參數不放入簡介。
- claim version 3 使用 ack_sending、acknowledged、replied，失敗保存 phase 和 acknowledged。收到通知不當成完成；通知傳送失敗只結束該指令，不進入截圖例外回覆、不補送；來源等待重連後可接收新指令。成功確認通知後釋放 CDP 鎖，再擷取，最後再次核對原來源並回傳圖片。既有持久 claim 防止重啟重做。狀態／清單維持單次回覆；test 模式處理一個指令，可包含通知與圖片兩則。
- 驗證：回覆簡介與通知例外邊界 10 項；接收流程 46 項（兩次指令各先通知、後結果）；多來源 27 項（A 通知不明則停止 A，B 通知與結果仍原路完成）；真實瀏覽器 13 項文字收據案例含「✦ [日管]」及少星號拒絕，並確認通知／完成內容不觸發新指令。本輪沒有實際 Teams 發送，需在目標對話驗收兩段回覆與圖片。
- 打包工具包含接收器及其必要模組，共 19 檔；部署保留 config.json、edge_profile、Teams 登入與綁定、logs、captures、sample_images 及 Windows 排程。更新檔案後須重啟接收視窗。
 
# CDP 說明提示與排程區收合（2026-11-10）
 
- CDP 無視窗選項下的長篇說明改為「使用說明」提示：滑鼠停留或鍵盤聚焦時在下方顯示，平常不占說明段落的高度。原模式切換與說明內容沿用。
- 排程時段增加 schedulesFold，初次預設收合，摘要顯示總數／啟用數；展開保留新增、搜尋及各筆卡片，另加「全部收合」。頁面、收件對象、訊息內層初次亦預設收合；沿用瀏覽器 panelLayout 記住選擇。大量清單使用局部捲動，Windows 同步結果與重新套用仍在收合区外。收合不更動排程啟用、收件人或工作排程器。
- tools/make_screenshots.ps1 -CompactOnly 在隔離 Edge 產生四種實際畫面（CDP 簡短／提示、排程收合／展開），更新手冊內嵌圖；已人工核對可讀性。未傳送 Teams 或註冊正式排程。
- 再次核讀 Send-GroupToTeamsCdp：正式及 SelfTest 每批用新 GUID，傳送目前內容；舊的 Assert-E3CdpNotBlocked 不在正式發送入口。準備階段依現用 runtime／對話清除草稿，Retire-E3HeadlessPending 只封存標記，並非續送舊工作。這次介面調整未改發送邏輯。
- 累積包 SendTeamsMsg_Compact_Schedules_Update.zip，含門檻自動試算與 CDP 設定狀態修正。更新保留 config.json、sample_images、captures、edge_profile、登入／綁定、logs 與 Windows 排程。
 
# CDP 設定檢查聚焦完成狀態（2026-11-10）
 
- 使用者只要確認是否設定完成，不需要檢查結果列出舊工作紀錄或其路徑。Test-E3CdpConnection 呼叫 Test-E3CdpTargetReady -ConfigurationOnly，驗證已保存的唯一綁定及目前登入／帳號／chatId／label；舊工作標記和草稿不再提前中止設定檢查。成功列及總結顯示「已設定完成」，缺綁定、登入或對話錯誤仍失敗並逐項報告。
- ConfigurationOnly 不清除紀錄、草稿，不發訊息。原 Test-E3CdpTargetReady 預設的完整檢查、初次綁定及傳送前檢查不變。test_cdp_headless_binding.ps1 涵蓋多對象、舊紀錄／草稿、失敗續查、分頁模式及預設嚴格檢查；test_cdp_headless.ps1 -ConfigurationOnly 使用隔離 Edge／本機 loopback 驗證實際連線與紀錄保留，不是公司 Teams 實送。
- 累積包 SendTeamsMsg_CDP_Setup_Status_Update.zip 含先前門檻自動試算修正。關閉設定頁與服務後覆蓋重開，保留 config.json、截圖、登入、綁定、logs 及 Windows 排程，不需因本次更新重新綁定。
 
# 設定頁重開自動試算數值門檻（2026-11-10）
 
- 原 numericCache 僅在網頁 WeakMap 保存；門檻／座標已寫 config.json，重開仍因沒有預覽結果顯示「尚未試算」。設定及圖片載入後改為自動逐項呼叫既有 /api/numeric-preview，涵蓋非目前選取頁面；變更門檻、座標、顏色或截圖後重新試算。請求串行並避開拖曳／擷取提交，不發訊息，不改正式排程分析邏輯。
- 結果仍綁定 rule、canvas 與設定簽章，過期結果不呈現為目前結果；等候顯示辨識中，真正辨識失敗保留原因，不自動無限重試，可用原按鈕重試。門檻／座標持久化，OCR 結果不寫 config 作為固定刻度。
- tools/make_screenshots.ps1 -NumericOnly 使用隔離服務與 Edge，搭配 numeric_ui_checks.js 及 numeric_auto_ui_checks.js，通過雙頁自動 OCR、門檻／圖片變更、過期回應、串行、失敗後手動重試與保存後真正導航重開。這是本機測試，不代表使用者網站或 Teams 實送。
- 累積更新包 SendTeamsMsg_Numeric_Auto_Preview_Update.zip；關閉設定頁及服務後覆蓋重開，保留 config.json、sample_images、captures、edge_profile、Teams 登入／綁定、logs 與 Windows 排程。不需重填門檻或重建排程。
 
# Teams 檢查結果位置（2026-11-10）
 
- 使用者指出「檢查 CDP 連線」位於 Teams 傳送設定，但結果跑到上方預覽與測試，操作與回饋不在同一區。將唯一 detectTeamsResult 元件移到 teamsSettingsFold 裡，位於檢查／設定按鈕下方、已設定的 CDP 對象清單上方。
- 原偵測處理函式與 API 不變；CDP 及一般 Teams 檢查的進行中／成功／錯誤共用新位置。結果有 aria-live=polite，沿用最大高度與內部捲動。本人測試的 selfTestStatus 留在預覽與測試。
- make_screenshots 的 09_detect_teams 開啟設定摺疊區並檢查結果只有一份、確實位於同一個 details，再產生手冊截圖。使用隔離示範資料，沒有向 Teams 發訊息或修改正式排程。
- 累積包 SendTeamsMsg_Check_Result_Layout_Update.zip。停止設定工具／服務後覆蓋重開，保留 config、截圖、登入、綁定及收據；不用重新設定收件對象或建立排程。
# 原始 Edge log 預設關閉與目錄清理（2026-11-10）
 
- 使用者要求不再常態寫 edge_*.stdout/stderr.log，並清除不需要的測試檔。Start-E3TestBrowser 預設用 .NET Process 非同步持續讀取／丟棄 stdout/stderr，不建立原始診斷目錄、不寫 log、不混入主程式輸出，也不等待 Edge 結束。只有明確 E3_EDGE_RAW_LOGS=1 才沿用原始檔案診斷。保留應用程式傳送收據、工作 log、啟動失敗 startup_*.json；失敗時原始 log 路徑為 null，訊息明確說明未記錄。
- test_cdp_startup_cleanup.ps1 實際隔離 Edge 驗證預設無檔、明確開啟可保存、主控台安靜、CDP 可回應、啟動失敗只清理自己的程序、startup JSON 保留原階段；不連公司 Teams。
- 以 Windows 資源回收筒方式移除 40 個 tools/validation_* 舊輸出目錄、11 個 tools 根目錄測試 log、374 個既有 edge 原始 log，以及被累積包取代的 4 個 ZIP。計畫共 172.73 MiB；只刪此工作目錄中逐項核對的路徑，不接觸設定、登入、綁定、收據、正式截圖或其他專案。清理清單與結果保存在本機 TEMP，不新增 README。永久批次刪除被自動審查拒絕後，改用可還原的資源回收筒並完成；106 個設定／JSON 紀錄／樣本程式檔核對雜湊未變，無略過項目。
- 6 個仍被測試引用的基準 PS1/HTML/PNG 已移至 tools/fixtures 並更新引用、核對雜湊；現行 test_*.ps1、fixture server、手冊工具與 demo config 保留。test_cdp_server_proof.ps1 從舊輸出目錄移回 tools；capture consistency 測試自行建立輸出目錄。之後跑測試可重建 validation_* 輸出，不能再當成永久输入。
- tools/package_update.ps1 改為獨立 12 檔累積包產生器，不依赖舊 validation manifest；只保留 tools/release_manifest.json 對應最新包。SendTeamsMsg_Quiet_Edge_Update.zip 沿用 receipttext1 及此前所有修正。更新目的主機時，停止工具／服務／舊 worker 後覆蓋重開，保留設定／登入／綁定／收據及 Windows 排程。此輪目錄清理僅作用於 D:\00058897\SendTeamsMsg，不自動刪除其他主機的檔案。
# 送出後文字與伺服器證據（2026-11-11，receipttext1）
 
- 使用者 ceda261e62ac4bbcb6cdb3a44f869fff 收據：captionspace1、editor 全通過、兩張 PNG 已核對；receipt=message_text_mismatch、7 個新 ID 文字不符，沒有送出後正文差異資料。Worker 的真正 message_send POST 回覆 201、有 serverId；使用者確認文字與圖片均收到。舊 serverReceipt.ok=false 是沒有匹配的 DOM messageId，不能解釋成伺服器沒接受。此筆不可補送。
- 找到並在隔離 Edge 重現獨立缺陷：receipt text() 略過所有 img，漏掉 Teams 把警告等 Unicode 符號轉成 emoji 圖片的正文。現在僅對明確 emoji/emoticon 標記且 alt 為完整 Unicode emoji 序列者讀回；不猜英文名稱；遇到無法讀取的已標記表情也不忽略放行，不讀一般附件 alt，保留不同 emoji／膚色／正文差異。Extended_Pictographic 後的 FE0E/FE0F 顯示樣式等價；emoji 圖不算報表圖片。舊 log 無 DOM/差異，尚無法確認使用者這筆是哪種具體正文差異，不宣稱已現場驗收。
- receipt.textComparisons 有每個候選列（最多 8）的 ID、長度、首差位置／類型、換行數、emoji 可讀數、頂層標籤；不記正文、alt、HTML、URL。Get-E3ServerReceipt 分開保存 serverAcceptanceObserved/domMessageMatched；已有有效伺服器 ID 但未匹配 DOM 時 reason=server_accepted_dom_unmatched、ok 仍 false。message_text_mismatch 改明確中文提示已按送出／伺服器已接受，仍 uncertain，不自動重送。
- tools/validation_receipt_text_20261111：修正前 emoji fixture 可重現；七個修正後 emoji/缺字/未知標籤情境，四個正式發送 loopback 情境跨 headless／retained-page 分支；完整 server+DOM 通過才成功，少字即使 server accepted 仍 uncertain，只有一次 send。可見分支由 headless fixture 承載；公司 Teams 只知道使用者回報上一版本這筆已收到，新版尚未現場實測。
- runtime 2026-11-11-receipttext1，兩處版本白名單同步。累積 12 檔 SendTeamsMsg_Receipt_Text_Fix.zip；停止工具／服務／舊 worker 後覆蓋，保留設定／圖片／登入／CDP 綁定／收據及既有排程。不新增 README。
# CDP 訊息尾端空白核對（2026-11-10，captionspace1）
 
- 使用者 3baa4947ae434680be495b22e6c27778 收據：preparationCleanup.composerEmpty=true，caption textMatches=false；expectedLength=74、renderedLength=73、firstDifference=73、expectedDifferenceKind=space、actualDifferenceKind=end。確認是尾端空白被 innerText 省略；不是草稿未清除，也未貼圖／按送出。
- adapter 新增 comparableText：沿用 CRLF/NBSP 正規化，僅忽略整段訊息最後的 ASCII space/Tab，不忽略前方／中間空白或真正換行。套用文字前置、圖片段落、CKEditor filler、已存在／新出現同文訊息比較與舊式編輯器準備核對；原始設定和貼上正文不改。收據模組原有 whitespace 正規化不變，raw editor diagnostics 仍保留原始差異。真正缺字／編輯事件／錯圖／收件者或伺服器收據仍須通過原規則，不重貼／重送。
- runtime captionspace1，兩處既有 runtime 白名單同步支援；有視窗與無視窗共用 adapter。tools/validation_caption_space_20261110 保存修正前真實隔離 Edge 重現 textMatches 失敗，以及九種修正後 fixture、四種尾端空白歷史同文防重複情境；完整 loopback 測試覆蓋兩種 CDP 分支、尾空白保留／移除，各兩张圖片一次傳送。可見分支仍以 headless fixture 承載，不等於公司 Teams 可見／鎖定實測。
- 累積包 SendTeamsMsg_Caption_Whitespace_Fix.zip，12 個既有交付檔；關閉工具與服務／舊 worker 後覆蓋重開，保留 config、captures、edge_profile、teams_cdp 登入／綁定及收據，不需重建排程。不新增 README。
# 所有傳送模式草稿清理與工作期限（2026-11-10，allmodes1）
 
- 使用者明確擴大到有視窗 CDP 及桌面版／PWA／Edge 分頁。正式 CDP 傳送統一清除舊文字、圖片、附件並封存舊阻擋紀錄；有視窗僅操作已綁定 targetId 對應的目前 socket，保留瀏覽器。Connect-E3CdpTarget -PrepareNew 與本人既有分頁會先停止上一個 runtime/frame，再核對帳號；readonly 檢查不呼叫 PrepareNew。不自動關閉日常瀏覽器。
- UIA 三種模式共同用 Clear-E3TeamsUiDraft：核對對話／輸入框後 Ctrl+A、Backspace，刪除前重核前景／對話／鍵盤焦點。最多三次／15 秒且空白持續 700ms；無法識別、焦點變更、清不掉等情況停止。自己測試先確認本人，再清草稿；不送出的檢查不清。Find-TeamsComposeBox 改為唯一輸入框，Get-ComposeState 額外偵測輸入區內 attachment/file-preview/upload-preview。此不等於各租戶所有 UIA 版型已實測。
- 共用執行 mutex 最多等 30 秒；非 CDP 等待解鎖共用最多 30 秒，原為各 30 分鐘。既有一般例外逐收件對象捕捉並繼續。所有排程與自己測試工作有 Start-E3RunDeadline 10 分鐘期限，獨立 .NET Timer 不依賴 PowerShell/UIA 返回；逾時只終止當前 worker（exit 124），釋放 OS mutex；不殺 Teams／設定服務。不代表網路、登入或作業系統故障時必能送达。
- 硬逾時不執行該 worker 的 finally，保留 captures／收據並記錄 .deadline.json；不能把已按送出的訊息當未送出或自動補送。該輪尚未完成的其他對象也會隨 worker 結束，後續排程依觸發重新執行；已經因 30 秒執行鎖超時而略過的輪次不自動補跑。一般超時與硬逾時須分清楚，不宣稱所有收件對象均已完成。
- 驗證 tools/validation_all_modes_20261110：visible retained-page 傳送分支用隔離 headless fixture 承載（不是實際可見公司 Teams），舊文字、附件、失敗清理及保留頁面；本人傳送替身覆蓋兩種 CDP；UIA policy fixture 七情境（未操作公司桌面 Teams）；真實獨立 worker 被 deadline 結束／正常 dispose 與 mutex 釋放；make_screenshots 更新各模式說明。
- 累積包 SendTeamsMsg_All_Modes_Recovery_Update.zip。關閉工具與服務後覆蓋重開，保留設定、登入、綁定與收據，不需重建 Windows 排程；舊版已在執行的 worker 必須先結束才會套用新版。沒有新增 README。
 
# 排程準備失敗隔離與 Edge 啟動等待（2026-11-10，preparation1）
 
- 使用者再次明確要求每次無視窗排程先清除未送出的內容，避免前一筆失敗阻擋後續。提供兩份 log：DevToolsActivePort 分享鎖例外（尚未導覽／貼圖），及四合一文字前置條件錯誤（本次兩張圖已準備，但尚未貼圖／按送出，editor=null）。後者原紀錄無法分辨確切條件；程式固定只等 120ms 且會把非同步編輯器通知當修改，已補有界等待與診斷。
- Wait-E3DevToolsEndpoint 以 ReadWrite/Delete 分享讀取，對未建立、占用、半寫入、HTTP 尚未就緒重試最多約 30 秒；核對 port 與 browser WebSocket path 一致才連接。不因檔案剛出現就直接 ReadAllLines。
- Send-GroupToTeamsCdp 在取得傳送 mutex 後且僅正式 headless 傳送呼叫 Reset-E3HeadlessBrowserForNewDelivery：只核對該使用者的專用 profile、main headless command line，先正常關閉再按原 PID／CreationDate 強制清理遺留程序。不停止另一個仍持有 mutex 的工作，不自動關閉有視窗設定 Edge 或日常 Edge。檢查／DryRun 不清理。接著核對收件對象並沿用 discard1 清除草稿與封存旧失敗紀錄。
- 說明文字貼入改等 5 秒內連續 200ms 正確；只在本次文字貼上階段容許非 trusted 的 input/beforeinput 插入通知，仍須比對完整正文、帳號／chatId／label、無多餘附件及同一編輯器。真實輸入事件、paste/drop、不同文字或對話變更仍停止。失敗 editor.phase=text_before_images、failedChecks、事件／重讀次數及去識別化比較寫入收據；不重貼、不自動重送。
- headless 本次結果明確 not_sent 且 receipt=not_armed/not_clicked 時，先 stop 本次 image-frame，再核對與清除這次留下的半成品草稿；寫 .draft-cleanup.json，保留原失敗紀錄與未決標記供下次封存。已按送出或結果不明不走此清理。收據新增 preparationCleanup 說明傳送前清理證據。runtime 2026-11-10-preparation1；本人有視窗版本檢查同步支援 preflight1 與 preparation1。
- tools/test_cdp_port_ready.ps1 重現實體檔案獨占與半寫入；test_cdp_send 的延遲文字／分段文字／錯誤文字／後續修改等 7 情境；test_cdp_headless -PreparationOnly 驗證錯誤文字自動清除、下一筆回收孤立 Edge 與舊草稿、只送本次兩張圖一次、舊失敗紀錄保留，以及延遲文字的 loopback 完整收據。test_self_pending_retry 76 檢查與 profile restart 保留其他瀏覽器／登入檔／PID 身分檢查。這些為本機隔離測試，未對公司 Teams 實送，也未實測使用者 P 槽主機。
- 更新包 SendTeamsMsg_Schedule_Preparation_Fix.zip；停止設定工具與服務後覆蓋，保留 config、截圖、edge_profile、teams_cdp 登入／綁定／收據，不重建排程，不另建 README。證據 tools/validation_preparation_20261110。
 
# 顯示已設定 CDP 對象（2026-11-09，bindinglist1）
 
- Teams 傳送設定在設定按鈕下顯示已儲存的 CDP 對象清單、route 與實際 label、預設標示與完整性；一般模式不顯示此區。列表高度限制 140px，長名稱自動換行，以 textContent 顯示。
- GET /api/cdp-bindings 使用 Get-E3SavedCdpTargets 唯讀讀取本 Windows 使用者的 E3TeamsCdpSendTest/bindings.json，僅回傳 route、label、complete、windowConfigured；不回傳帳號、chatId、targetId 或登入資料，不啟動瀏覽器、不寫設定、不檢查即時登入。重複 route／不完整 binding 不標為可用，讀檔失敗回報錯誤，不能當成尚未綁定。
- 首次顯示、回到工具焦點、可见時每 30 秒及手動重新整理更新。防止重疊要求，5 秒逾時；切換模式、修改預設名稱會重新計算標示。已設定不代表連線有效，旁邊保留「檢查 CDP 連線」。
- 驗證 tools/validation_binding_list_20261109：唯讀摘要的無檔、多對象、缺欄位、重複、損壞、敏感欄位排除及原檔不變；make_screenshots 的實際本機 API 與介面列表／預設／空白／失敗／文字安全／模式切換檢查，更新手冊截圖。未對 Teams 發送。
- 累積包 SendTeamsMsg_Cdp_Target_List_Update.zip；停止工具與服務後覆蓋重開，保留設定、截圖、登入、CDP 綁定及收據，無需重建排程。不另建 README。
 
# 送出前歷史訊息檢查（2026-11-09，preflight1）
 
- 使用者提供 5ea9deb88c2e403cb87f8e70d5ba1028 收據：headless=true、四張圖片載入與編輯器全部通過、modelReady=true，但結果 not_sent／receipt=not_clicked。舊錯誤把 snapshot 失敗及出現同正文新 ID 合併，該 log 無法證明是哪個分支；renderedTextMatches=false 是原始排版差異，composerTextMatches=true 已通過，不應據此宣稱文字錯誤。
- 送出前僅重讀聊天紀錄，最多 2.5 秒／26 次，處理短暫缺正文或 timestamp。文字相同但 ID 剛出現的列，只有時間嚴格早於原邊界最新訊息時視為重新載入的舊紀錄；同時或較新仍阻擋。等待後重新驗證帳號、chatId、label、composer、文字／圖片及送出鈕，不重貼、不重按，也不重試送出。
- runtime 2026-11-09-preflight1；收據新增 preSend，包含讀取次數、明確失敗原因、恢復前讀取錯誤、舊同文列與衝突列數；失敗 checks 分為 historyReadable／noNewMatchingMessage。既有伺服器與畫面收據確認不變，並保留 discard1 的舊草稿處理。
- tools/test_cdp_send.ps1 multi-history-* 在隔離 Edge 測試四張圖、舊紀錄、短暫／永久讀取錯誤、新同文／同時間、等待時切換對象或編輯內容，以及取消前送出；tools/test_cdp_headless.ps1 -DiscardDraftOnly 驗證本機 loopback 全流程，未對公司 Teams 發訊息。證據 tools/validation_preflight_20261109。
- 累積更新包 SendTeamsMsg_PreSend_History_Fix.zip，關閉工具及服務後覆蓋重開；保留 config、captures、edge_profile、teams_cdp 登入／綁定／收據，無需重建排程，不另建 README。
 
# 無視窗新工作自動清除草稿（2026-11-09，discard1）
 
- 使用者明確要求無視窗模式先刪除之前未送出的内容，執行本次選定排程。Send-GroupToTeamsCdp 的正式傳送與 SelfTest，在專用 profile 與共用傳送 mutex 下核對帳號／chatId／label、停止舊 runtime，再執行 Clear-E3HeadlessDraftForNewDelivery。本人傳送仍先確認本人對象；取消時不清除。DryRun／連線檢查／設定綁定與有視窗模式不自動清除。
- discard-draft.js 限定唯一、獨立的 composer；用原生 CDP Ctrl+A／Backspace 通知編輯器更新資料，用 composer 内附件移除按鈕取消附件；不直接清空 DOM、不使用桌面剪貼簿、不操作已送出的訊息列。刪除前再次檢查身分、焦點、選取範圍與舊 runtime 已結束；焦點改變、編輯既有訊息、多個輸入框、未知附件按鈕、仍在傳送等狀態停止。確認空白持續一秒並再次核對對話與 pending rows 後才繼續。
- Retire-E3HeadlessPending 在上述證據完成後封存舊 blocked 原始 bytes（含損壞舊紀錄），移至 review/discard_*.pending.json；另存停止／清除證據與新工作 ID，不補送舊工作、不把原 uncertain 改成成功。既有收據保留。只在本次第一批清除，後續同工作批次沿用正常送達驗證；本次發送不確定仍停止後续批次，不自行重試。其他程序仍佔用傳送 mutex／profile、或無法證明舊工作停止時，不強殺也不混送。
- tools/test_cdp_discard_draft.ps1 以真實隔離 Edge 驗證文字、inline 圖片、附件、混合、原生 input 更新、錯帳號／profile、焦點變更、拒絕刪除、編輯既有訊息、送出中與未知附件，保留歷史且無送出；tools/test_self_pending_retry.ps1 通過 76 項檢查，驗證正式函式本人路徑的順序、新 ID／本次內容，以及舊工作取消與紀錄封存。tools/test_cdp_headless.ps1 -DiscardDraftOnly 在隔離 Edge／loopback 模擬伺服器完成舊草稿與舊附件兩種全流程：各只送一次本次文字與兩張圖片、不含舊內容、核對本機收據、保留舊 uncertain 紀錄並關閉瀏覽器。既有 visible pending recovery 20 情境與 runtime recovery 通過；此為本機 fixture，未操作公司 Teams。
- 更新包 SendTeamsMsg_Headless_Discard_Draft_Update.zip；關閉設定工具及服務後覆蓋重開，保留 config、圖片、edge_profile 與全部 teams_cdp 登入／綁定／收據，不需重建排程。不另建 README。驗證 tools/validation_discard_draft_20261109。
 
# OCR 語言相容修正（2026-11-09，numericlang1）
 
- 前版 Get-E3AxisWords 固定建立 en-US 引擎，僅有中文 OCR 的電腦會被誤擋。新增 Select-E3OcrEngine／Get-E3OcrEngine，依 AvailableRecognizerLanguages 選擇已安裝語言，優先保留已驗證的英文路徑，其次中文與其他語言；引擎建立失敗則嘗試下一個。全部未安裝與已安裝卻無法啟動使用不同錯誤訊息，不因圖片是純數字要求英文套件，不自動安裝語言。
- 中文引擎使用對應繁／簡中文辨識上下文，Read-E3OcrContext 保留嚴格上下文檢查；原本雙次 OCR、線性擬合、峰值與門檻誤差判定不变。預览與正式排程都使用同一模組。數字圖片仍需要某種可用 OCR 引擎，不能宣稱不需任何文字辨識元件。
- tools/test_numeric_ocr_languages.ps1：模擬只有繁中／簡中／日文、英文正常與無法載入、沒有引擎，以及各語言上下文；本機實際只有 en-US，真實中文模型辨識需目標電腦驗證。tools/test_numeric_monitor.ps1 重跑實際本機 OCR 與攔截傳送的排程回歸，見 tools/validation_numeric_ocr_languages_20261109。
- 更新包 SendTeamsMsg_Numeric_OCR_Language_Fix.zip，保留設定、圖檔與登入狀態，關閉設定工具及服務後覆蓋重開並重新按「讀取刻度並試算」。不需重建排程，不另建 README。
 
# 動態 Y 軸數值門檻（2026-11-09，numeric1）
 
- 每個 rules[] 可選 measure_mode="numeric"，使用原 roi 作監測區域、axis_roi={x,y,w,h} 作左側刻度數字區、value_threshold 作數值門檻，指定藍色 target_color／color_tolerance。省略模式或 pixel 沿用舊警戒線；兩框座標都相對最終裁切 PNG。監測框需含完整曲線高度，刻度框勿含軸線、標題、右側刻度。
- numeric_monitor.ps1（UTF-8 BOM）使用本機 Windows English OCR，擷取灰黑刻度文字、放大與二值化，加已知英文上下文以改善單字元辨識；4x／6x 各至少三個有效刻度、線性擬合與雙次刻度換算交叉核對。不需雲端或另裝套件；主機缺英文 OCR 時回報無法判定，不自動安裝。數字中的 O/o 正規化 0、I/l/i 正規化 1，仍需擬合與雙次一致檢查。漏讀或非數字不作校準點，每次至少三個有效刻度，不超出已辨識範圍換算。支援負數、小數、千分位與 K/M/G/T（千進位）及百分比，門檻使用換算後同單位數值；不支援對數軸或旋轉圖。
- 偵測 ROI 內指定藍色連通區的最高點（至少三像素，保留單像素寬尖峰），不以超標區像素總數代表數值。找不到藍色、峰值被監測框上缘裁切、超出已辨識刻度範圍、辨識衝突、接近門檻而落在至少 1.5 像素的換算誤差內，皆 unknown。誤差範圍外才依嚴格大於判超標。不能保證任意字型、影像品質皆能 OCR。
- 設定工具新增判定方式、門檻、獨立 Y 軸框選、精確座標及「讀取刻度並試算」。POST /api/numeric-preview 只接本機同源 PNG，不寫設定、不發訊息。預覽以規則與圖片身分綁定結果，改設定／重抓圖片後失效；舊非同步結果不能覆蓋新狀態。正式與本人排程共用主分析流程，每張當次 PNG 重新 OCR；不讀預覽快取。超標訊息包含最高值、門檻、已辨識刻度與誤差；unknown 保留截圖、列入 failures，alert_only 也會提醒。
- tools/test_numeric_monitor.ps1：實際 Windows OCR 35/32 超標、180/25 正常、30 邊界 unknown；範圍外尖峰、缺框、裁切、無藍色、錯色、非線性刻度、單位；正式排程入口以本機圖片驗證分析與傳送邊界（攔截所有傳送）。tools/numeric_ui_checks.js 與 tools/make_screenshots.ps1 驗證真實 Edge、本機 API、座標、過期結果、模式切換及手冊截图。不代表公司網站或 Teams 已驗收。
- 更新包 SendTeamsMsg_Numeric_Threshold_Update.zip 為累積包，必須包含 numeric_monitor.ps1；關閉設定工具及服務後覆蓋再開啟，保留 config、圖片、edge_profile、teams_cdp 登入／綁定狀態，不需重建既有 Windows 任務。不另建 README。驗證位於 tools/validation_numeric_20261109。
 
# 手動抓圖沿用每頁時間設定（2026-11-09，previewtimefix1）
 
- 修正 PreviewCapture 建立 previewPage 時漏帶 cfgPage.zabbix_time，導致介面選 NOW→3d，手動抓圖仍套用預設 7d。現在明確傳入同一頁的設定；3d、7d、只切 NOW、停用與舊版預設均保留。正式排程原本已傳入，未改其路徑。
- tools/test_zabbix_time.ps1 直接執行正式 PreviewCapture 的頁面建立敘述，修正前可重現設定遺失；修正後將該預覽物件送入本機 Edge 擷取流程，並於實際截圖前核對 NOW、259200 秒及 Zoom 3d 點擊。先前只用測試自行建立的頁面，漏測這個預覽轉換步驟。
- 更新包 SendTeamsMsg_Preview_Time_Fix.zip；關閉設定工具及服務後覆蓋再開啟，保留 config、圖片、edge_profile 與 teams_cdp 登入／綁定狀態，不需重新註冊排程。舊預覽圖不會自動更新，需按「抓圖」重新擷取。未實測公司網站，未傳送 Teams 訊息；驗證見 tools/validation_preview_time_20261109。不新增 README。
 
# 每頁圖表時間設定（2026-11-09，pagetime1）
 
- pages[].zabbix_time={enabled:true,range:"3d"}，range 為 7d／3d／keep。缺少整個設定沿用既有 NOW→7d；enabled=false 不操作時間控制列。keep 只移到 NOW，不點日期區間，範圍依網站前進後結果為準，不宣稱鎖定原天數。
- calibrator 在支援的 screens.php／charts.php 頁面顯示「圖表時間區間」折疊區，按頁面記住收合狀態；選項獨立保存，取消啟用仍保留先前選項。更改網址即更新可用性，改區間不改 Windows 觸發設定。
- 保留 Set-ZabbixRecentWeek 函式名称以相容既有入口，新增 settings 參數；Get-JsZabbixTimeStep 支援 604800／259200／0，依實際控制列點右箭頭到 NOW，再選對應 Zoom。只切 NOW 不要求 Zoom 按鈕；所有模式都核對 timeline、時間標籤、圖片 period／isNow 與載入穩定。失敗不回退 7d。Capture-PagesNative 傳入每頁設定，手動、正式排程與本人排程共用。
- Save-ConfigBody 驗證 boolean 與合法範圍，無效資料不覆蓋 config。未修改網站登入、取圖比例、裁切、警戒線判斷、Teams 收件與傳送。
- 本機真實 Edge 控制列替身涵蓋 7d 舊行為、3d、只切 NOW、關閉調整、缺少按鈕、過期圖、重新載入及每頁失敗隔離；本人排程測試核對設定傳入擷取函式。此為本機驗證，不代表公司所有 Zabbix 版本都已實測。
- USER_MANUAL.html 增加每頁操作說明及新截圖。累積包 SendTeamsMsg_Page_Time_Update.zip；關閉設定工具服務後覆蓋再開啟，選頁面設定區間並重新抓圖確認。保留 config、圖片、登入與 CDP 狀態。不新增 README；驗證見 tools/validation_page_time_20261109。
# 左欄收合整理（2026-11-09，sidebarfold1）
 
- 保留頁面清單／分類切換／搜尋、名稱／網址／抓圖；新增 categoryManageFold、pageLoginFold、pageZoomFold。登入與縮放摘要僅顯示啟用狀態／百分比，不顯示帳密。
- 預覽與測試獨立保持展開，Teams 對象／模式／CDP 設定移至 teamsSettingsFold，摘要顯示對象與模式。selfHelpFold 與 scheduleHelpFold 收納長篇說明；排程清單、sync、selfTestStatus、detectTeamsResult、registerReport 留在折疊區外。
- 沿用 bindPanelFold／e3PanelLayout.v1，設定預設收合；登入與縮放狀態按 page.id 保存，其餘為共同介面偏好。摘要隨比例、登入選項、對象及傳送模式更新。儲存受限時仍能操作。
- 僅介面與說明調整；不更改 config 欄位、擷取、排程觸發器、傳送方式或登入資料。新測試用實際 Edge 檢查初始收合、狀態重載、跨頁獨立、摘要無密碼、操作與錯誤可見、設定及排程簽章不變；沿用既有 UI 回歸與 14 張手冊截圖。
- USER_MANUAL.html 更新 4-1 收合操作说明及介面圖。累積包 SendTeamsMsg_Sidebar_Fold_Update.zip；關閉設定工具服務後覆蓋再開啟，保留原設定、圖片、登入及 Teams 綁定／傳送紀錄。不新增 README。驗證見 tools/validation_sidebar_folds_20261109。
# 本人排程測試選擇與張數（2026-11-09，selfselection1）
 
- 根因：勾選框只改 schedules[].enabled，startSelfTest(schedule) 卻沿用 getPreviewSchedule 的既有 previewScheduleId。取消四張排程、勾選兩張時，舊四張仍可能被手動執行。
- 預設發送區新增「本次預覽／測試排程」選單及名稱／預計張數，與右側預覽共用 previewScheduleId。勾選選中該排程；取消目前選取者，改為另一已啟用排程或 ALL_PAGES_KEY。多個勾選不合併測試；直接使用選單不變更 enabled，已停用排程明確標示仍可手動測試。
- startSelfTest 在任何非同步等待前固定排程 ID 與完整 config 快照，狀態先顯示該次名稱與預計張數。處理中停用左側選單；其他預覽操作不改已送工作。全部頁面仍僅可做圖片预覽測試，不能作為實際排程入口。
- 前端實際 Edge 測試覆蓋四張→取消→兩張、全部取消、多個勾選、左右同步、快照競態、張數與重複點擊。既有 HTTP／worker 本人排程回歸核對選定頁序及兩張輸出，所有發送攔截，不傳真實 Teams 訊息、不改正式任務。
- 實際 Edge 選擇／張數／請求快照測試通過；本人排程 HTTP／worker 回歸 62 項通過。
- 更新 USER_MANUAL.html 本人測試章節與 14 張介面圖。累積包 SendTeamsMsg_Self_Schedule_Selection_Fix.zip；關閉設定工具服務後覆蓋、重新開啟即可，保留 config、登入／綁定、圖片與傳送紀錄。未改引擎或排程觸發設定，不新增 README。驗證见 tools/validation_self_selection_20261109。
# 每個排程獨立訊息文字（2026-11-09，schedulemessages1）
 
- schedules[].messages 保存 default_message、normal_summary、abnormal_header，title 保持原欄位；排程卡片內新增「訊息文字」折疊區，所有文字只編輯該排程。新排程文字預設空白，刻意留空不回退共用值。
- initializeScheduleMessages 與後端 Save-ConfigBody 將舊版缺少的訊息欄位從 teams 複製一次，再各自保存；沒有開啟／保存過的舊設定仍由引擎沿用原文字。三個欄位分別辨識缺少與空白。訊息修改不納入 scheduleSignature，不重新註冊觸發器。
- 原共用 messageFold 移至全域設定，明確標示只供手動「全部啟用頁面」。每個排程的前端 composeTeamsMessage、預览本人快照、正式排程、TestSample 與 SelfScheduleJob 均使用對應文字。Get-TeamsMessageText 新增可選 schedule 參數，Get-TeamsScheduleMessages 統一處理缺省／空白；仍共用原傳送模式與收件規則。
- 異常明細／失敗原因仍附上；正常／異常選填與純圖片、分批規則保留。沒有修改公司 Teams 登入、CDP receipt、重試、排程時段及個人資料。
- 更新 USER_MANUAL.html「每個排程的訊息文字」與操作索引；make_screenshots.ps1 更新介面及手冊圖。驗證包含兩個排程不同正常／異常文字、交替執行、空白不回退、舊文字複製、保存還原、訊息變更不註冊排程，以及本人排程入口。所有 Teams 發送邊界攔截，不向真實 Teams 發送。
- 本次通過 19 項訊息引擎檢查（含實際隔離 CLI）、62 項本人排程入口檢查、89 項保存／任務回歸，以及真正 Edge 介面檢查與 14 張手冊圖。預覽快照不修改設定。
- 累積包 SendTeamsMsg_Schedule_Messages_Update.zip；關閉設定工具服務後覆蓋、重新開啟，再分別展開排程編輯訊息。保留原 config、圖片、登入與 CDP 狀態；不新增 README。詳細驗證見 tools/validation_schedule_messages_20261109。
# 時段內重複排程（2026-11-09，repeat1）
 
- 每個 schedules 項目新增可選 repeat={enabled:true,every:30,unit:"minutes",end_time:"18:00"}，unit 可為 minutes／hours。既有 time 為開始時間；缺少 repeat 或 enabled 不為 true 保持固定時間模式。頁面與收件人及全域 Teams 模式不變。
- UI 提供固定／重複模式、開始／結束與數值／單位，摘要、預覽與搜尋顯示時段。結束較早代表隔天，星期以開始日計算。結束時間不再啟動；例 08:00～18:00 每 30 分，最後為 17:30。開始與結束不可相同，間隔正整數且小於時段；無效資料暫停自動儲存／套用，後端保存與註冊也先驗證。
- Get-E3RepeatPlan 建立標準分鐘與時段秒數。Daily／Weekly trigger 的 Repetition 使用間隔與時段減 1 秒，避免結束邊界再觸發；StopAtDurationEnd=false，保留已在執行的工作。IgnoreNew、Hidden、喚醒、補跑、身分及所有權檢查保留。
- Get-E3TaskSchedule 回讀 repeat_interval_minutes／end_time；核對 duration、StopAtDurationEnd、每日／每週規則。scheduleSignature 納入間隔與結束時間；外部修改不誤報同步，重新套用以工具設定為準。
- 主流程重新取得 config 並取得執行權後，以 Test-E3RepeatWindow 檢查重複時段／開始星期；過時補跑、已停用或排隊後跨過結束時刻時記錄略過，不截圖、不傳送。固定模式維持原行為；SelfScheduleJob 與 TestSample 仍能手動測試時段外資料。
- 驗證：tools/test_schedule_names.ps1 擴充重複註冊、狀態回讀、跨日星期、無效值、取消重複、已執行工作不強制停止；所有任務寫入均為替身。tools/test_background_schedule.ps1 檢查實際 CLI 時段內執行／時段外略過；test_self_schedule.ps1 -Headless -Repeat 驗證時段外本人測試。repeat_schedule_checks.js 經 make_screenshots.ps1 在真正 Edge 檢查介面與同步，並更新 14 張手冊圖。詳細結果見 tools/validation_repeat_schedule_20261109。
- 本次通過：87 項任務／保存／時段檢查、10 個實際 CLI 情境、57 項時段外本人排程測試，以及真正 Edge 介面回歸與 14 張手冊圖。
- 更新 USER_MANUAL.html 4-1、4-3、4-5。累積更新包 SendTeamsMsg_Repeat_Schedule_Update.zip；關閉設定工具服務後覆蓋、重新開啟並按「重新套用」。保留 config、profiles、Teams 綁定／待核對紀錄、圖片及 logs。不新增每次更新 README。不實際註冊正式任務或向 Teams 發送；Windows 到點触發／睡眠喚醒與公司收件仍需部署主機驗收。
# 排程截圖與傳送全程無視窗（2026-11-09，background1）
 
- 全域 CDP 且 cdp_headless 不為 false 時，正式排程及「執行排程傳給自己」一律使用 Headless Capture-PagesNative，即使桌面可用也不顯示擷取 Edge、不移動實體滑鼠。缺省 true 與現有 Teams 傳送模式一致；其他模式保留原桌面狀態判斷。
- 手動 PreviewCapture／InteractiveCapture 保持有視窗，供使用者選擇位置；自己測試仍有人工本人確認。未更動 Teams 傳送、收據、重試或登入策略，也未新增逐排程模式。
- Windows 排程的 PowerShell 改用 -WindowStyle Hidden；既有使用者需按「重新套用」更新任務。保留 config、edge_profile、Teams 專用登入／綁定、截圖、logs 及待核對紀錄。
- test_background_schedule.ps1：8 個實際 CLI 情境，含可用／不可用桌面、CDP 預設／有／無視窗、UIA、手動入口及真正無視窗 Edge；驗證保存範圍、裁切尺寸／像素、實際 headless 程序與無 OS cursor 操作。test_self_schedule.ps1 -Headless：57 項，含實際 HTTP／排程 worker 與真正 Edge。test_schedule_names.ps1：48 項，含 Hidden 啟動參數。
- 本機測試攔截 Teams 發送與 Windows 任務寫入，未向公司 Teams 發訊息、未修改正式排程。無視窗模式的實際收件／長時間鎖定仍需公司主機驗證；不保證休眠中執行或登入永久有效。
- calibrator 更新無視窗選項與模式提示；USER_MANUAL.html 的 CDP 章節更新背景操作、驗證界線與重新套用步驟，介面截圖由 tools/make_screenshots.ps1 更新。
- 累積包 SendTeamsMsg_Background_Schedule_Update.zip。依使用者偏好不新增每次更新 README，操作說明集中本檔與 USER_MANUAL.html；既有 README 檔案不刪除。
# 傳給自己失敗後重試修正（2026-11-09，selfretry1）
 
- 根因：Send-GroupToTeamsCdp 的 SelfTest 分支在本人確認前直接 Assert-E3CdpNotBlocked；首批恢復又排除 SelfTest，造成前次已停止也永遠被舊紀錄擋住。
- 移除自己測試的無條件阻擋；確認實際本人、重驗身分與空白輸入框後，在首批生成新 ID，再共用 Resume-E3CdpPendingForNewDelivery。恢復通過才 reset／建立 pending／開始本次傳送。取消與身分錯誤不移動舊紀錄。
- 預覽與排程兩種自己測試、CDP 有／無視窗均適用。既有停止證據、傳送中訊息、草稿、共用 Mutex、保留舊結果與不重送舊 ID 的檢查保留；不讓舊結果是否已確認成功阻擋新測試。連線檢查仍只讀。未修改 runtime 版本，不需重新綁定或清除狀態。
- test_self_pending_retry.ps1 66 檢查：連續兩次失敗再次啟動、新 ID 與本次內容、保留歷史、不明結果、取消、活動工作、待送列、草稿、身分與缺少停止證據。test_self_test.ps1 37 檢查、既有 pending 恢復 20 情境通過；全部攔截發送邊界，未傳真實 Teams 訊息。
- 累積包 SendTeamsMsg_Self_Retry_Fix.zip，含前版表格漏列修正。USER_MANUAL.html 更新重試規則與步驟，teams_cdp/README.md 移除舊的自己測試不可恢復說明。本次沒有修改 calibrator 可見介面，沿用原 UI 截圖。操作見 README_SELF_RETRY_FIX.txt。
 
# 排程表格截圖少一列修正（2026-11-09，tablelayout1）
 
- 已直接讀取 KPI 網頁重現：設定 80%、相同 CSS viewport 2390×1195 與 PNG 1912×956，原生 Edge 縮放 80% 時 L11-13 第三列底部約 906.3 像素，100% 時約 924 像素，909 高的舊框會漏列。先前純色塊測試沒有涵蓋密集表格的字型列高取整；DPR 補償不能代表排版相同。
- Capture-PagesNative 在 Stop-ProfileEdge 後、啟動 Edge 前呼叫 Reset-CaptureProfileZoom。僅限專用 capture profile，確認無占用程序，驗證 Preferences JSON，再以平衡括號定位 partition 內 default_zoom_level／per_host_zoom_levels 兩個縮放 map 並清空；其餘文字逐位元組保留。暫存檔原子取代，無法解析、占用或取代失敗即停止；不改登入、Cookie、其他瀏覽器或 Teams CDP profile。
- Set-CaptureViewport 檢查未套用 Emulation 時 DPR 必須是 1，拒絕以補償掩蓋原生縮放差異。每頁的 50～200% 比例、CSS 尺寸／捲動還原與 PNG 像素裁切仍保留。新擷取 capture_view.layout = native100-v1；舊範圍沒有排版基準，排程停止該頁並要求重新抓圖框選，不能猜測或自動放大框。
- 正式排程與執行排程傳給自己共用修正；預覽快照發送仍只使用已保存圖片。更新後所有要排程的頁面需重新抓圖及框選一次。這個版本規則優先於後文歷史上的「僅補償原生縮放、不改 Preferences」說明。
- 新增 test_capture_profile_zoom.ps1 與 test_table_layout.ps1，驗證縮放 map 以外資料保留、占用／失敗拒絕、密集表格及真正 KPI 頁，搭配排程 CLI、可見 Edge 與自己排程入口回歸。詳見 tools/validation_table_layout_20261109/RESULT.md；測試不向正式 Teams 發送，不改正式 config 或排程。
- 累積更新包 SendTeamsMsg_Capture_Table_Fix.zip；操作見 README_CAPTURE_TABLE_FIX.txt。USER_MANUAL.html 更新 3-2 排版／重新框選說明、FAQ 及最後更新日期；本次未改設定工具可見 UI，沿用現有手冊 UI 圖。
 
# Windows 任務狀態回讀修正（2026-11-06，taskname2）
 
- 使用者已成功建立 TEST，但 `/api/schedule-status` 因其他 Windows 任務的 Execute 路徑使 `Path.GetFileName` 拋出 `Illegal characters in path` 而中斷。前版純任務替身沒有涵蓋此情境，是程式缺陷，不代表使用者註冊失敗。
- `Get-E3OwnedTaskId` 先移除成對的執行檔外層引號，再解析檔名；遇到 ArgumentException 回傳不屬於本專案，繼續檢查其他任務。仍須同時符合 PowerShell 執行檔、完整 script/config 路徑和固定 Schedule ID，不以顯示名稱猜測任務，也不修改其他應用的路徑。
- `test_schedule_names.ps1` 47 項通過：新增含引號、非法引號、NUL、混入參數、空字串，驗證其他任務不遮蔽 TEST、不影響重新註冊、不被刪改；合法引號 PowerShell 仍核對 config 所有權。
- `test_schedule_path_http.ps1` 用開發機真正 Windows 任務與隔離的 HTTP 設定服務重現：115 筆 action 中 1 筆讓舊版拋出同樣錯誤；修正版連續两次回讀成功。只有唯讀查詢，未註冊或刪除真實任務、未傳送 Teams。證據：`tools/validation_schedule_path_fix/RESULT.md`。
- 最新累積包 `SendTeamsMsg_Schedule_Status_Fix.zip`。保留已建立的 TEST、正式 config 與登入資料；覆蓋更新並重啟設定工具即可重新讀取。若先前失敗狀態仍保留，按一次「重新套用」核對；不必先刪任務或清快取。
 
# Windows 任務沿用排程名稱（2026-11-06，taskname1）
 
- Windows 工作排程器根目錄的任務名稱等於排程 name（前後空白移除；空白名稱回退 id），例如「測試」。`-Schedule morning` 仍使用固定 ID，改名不改頁面、收件人或執行內容。名称必須唯一（不分大小寫），最多 200 字，不允許 Windows 任務保留字元；與其他應用程式同名時停止，不覆寫。
- `Get-E3OwnedTaskId` 依單一 PowerShell action 的完整 script/config 路徑及 Schedule 參數辨識本專案任務，不以名稱前綴判定所有權。可辨識現有 `E3_Monitor_<id>` 並遷移，其他專案或不同 config 的任務不清理。`Get-E3ScheduleTaskStatus` 回傳穩定 id、實際 task_name/task_path、觸發器及狀態。
- 改名先停用舊任務，再註冊新名稱，成功後移除舊任務；註冊失敗恢復原本啟用狀態。舊任務移除失敗則保持停用並回報，不留兩個啟用觸發器；舊任務正在執行時停止改名。整份計畫先檢查名稱／ID 重複與非法字元；註冊有失敗時不清理其他已刪除任務。
- `scheduleSignature` 納入任務名稱；改名會自動重新註冊。介面比對實際名稱、根目錄路徑及同 ID 重複任務，舊名稱不再顯示已同步。`schedules:[]` 表示没有排程，刪除最後一個排程不建立舊版 daily；缺少 schedules 的舊 config 仍相容。
- 部署後保留 config、登入、CDP 綁定、截圖及傳送紀錄，重啟設定工具再按一次「重新套用」遷移旧任務。此版累積包 `SendTeamsMsg_Schedule_Names_Update.zip`，見 `README_SCHEDULE_NAMES_UPDATE.txt`。若程式或 config 本身搬過位置，路徑不同的舊任務不自動刪除，需另行核對。
- 驗證與界線見 `tools/validation_schedule_names/RESULT.md`；註冊／回復／刪除以隔離替身檢查，介面以真正 Edge 執行，沒有修改正式 Windows 任務或傳送 Teams 訊息。
 
# 登入流程檢查（2026-11-06，selflogin1）
 
以下為目前行為；後方版本紀錄保存歷史，舊更新包名稱及當時的限制不代表最新版。
 
| 入口 | 圖片來源 | Teams 有視窗 CDP 行為 |
| --- | --- | --- |
| 將目前預覽傳給自己 | 前端預覽 PNG／文字快照；不重新登入或擷取监控網站 | `/api/test-self` → `-SelfTestJob` → `Send-GroupToTeams -SelfTest` |
| 執行排程傳給自己 | `/api/test-self-schedule` → `-SelfScheduleJob`；按設定重新擷取、登入監控網站、判定警戒線 | 共用 `Send-GroupToTeams -SelfTest`，只傳本人 |
 
- 兩條路徑都保留 `teams.prefer_window=cdp`、`teams.cdp_headless=false`，進入 `Open-E3SelfTestCdp(false)` → `Open-E3ExistingSelfTestCdp`。沿用原 CDP 瀏覽器與唯一可核對的本人分頁，不建立／導向登入分頁、不關閉使用者 Edge；忽略正式收件名稱，但不略過帳號／聊天室、草稿、人工確認與收據核對。
- 有視窗 Edge 已開啟不代表設定已選有視窗：`cdp_headless` 缺省仍是 true。保留視窗時須取消勾選「使用無視窗 Edge 傳送」。兩顆按鈕使用點擊時的模式；不自動改正式設定或移除登入資料。
- 無視窗模式仍使用 CDP 保存的 profile 啟動自己的 Edge，不接管另一個可見視窗。此次修正 `teams_self_test.js` 漏認「改用 Web 應用程式／使用 Web 應用程式」：在受允許的 Teams 網域找到唯一 Web 按鈕時可繼續；不點下載或登入按鈕，也不操作 Microsoft 登入頁。此處僅負責導頁，後續嚴格本人驗證不變。
- 無視窗找不到自聊時，錯誤文字改為「未就緒不一定代表登入過期」，不再一律叫使用者先登入。真正的 Teams 登入過期／MFA 仍需人工處理；監控網站登入使用另一個 `edge_profile` 和每頁帳密，與 Teams 登入分開。
- 本次重跑：有視窗原分頁 20 項、防誤傳 37 項、按鈕 13 情境、預覽 HTTP 五模式、實際排程 51 項、導頁與身分 15 項。HTTP／排程子程序另核對 `cdp_headless=false` 未遺失。結果見 `tools/validation_self_login_review/RESULT.md`；使用隔離 Edge／本機網頁及攔截的傳送邊界，未向真實 Teams 發訊息，不代表公司登入政策、無視窗鎖定或隔夜送達已驗收。
- 此版更新包：`SendTeamsMsg_Self_Login_Checked.zip`，步驟見 `README_SELF_LOGIN_CHECKED.txt`。先完成／取消舊工作，再只重啟設定工具服務與頁面；保留已登入的 CDP Edge、config、圖片、監控網站 profile、排程、logs 及完整 `%LOCALAPPDATA%\E3TeamsCdpSendTest`。
 
# 2026-11-06 CDP 自己測試沿用既有本人分頁（selfexisting1）
 
- 使用者已保留有視窗 CDP 自聊，但自己測試另開 Target.createTarget 後前往 /l/chat/48%3Anotes/conversations，導到 dl/launcher 的「加入交談」頁。此現象不等於原分頁登入已失效。
- Open-E3SelfTestCdp(false) 現在呼叫 Open-E3ExistingSelfTestCdp：驗證原 session/browser endpoint；優先使用 bindings.json 中唯一仍開啟的 isSelf 分頁，忽略呼叫端或排程收件名稱；Connect-E3CdpTarget + strict self recheck 驗證 accountId/chatId/label，選回原分頁，不新建、不導向、不重新登入。
- 同分頁的相同身分 alias 去重；同分頁身分矛盾、多個本人分頁或保存的本人分頁已關閉均停止。有本人綁定但無法核对時不退回其他帳號。沒有本人綁定時，僅允許唯一現有 Teams app 分頁通過嚴格自聊辨識；launcher/deep-link/auth 頁面排除。
- 傳回 browser=null，不取得使用者視窗所有權；測試清理不關閉原分頁。既有 blocked、草稿、設定頁面人工確認、確認後身分與每批 receipt 核對保留。無視窗路徑此次未變更。
- tools/test_self_cdp_existing.ps1：隔離的真正有視窗 Edge，現有自聊加 launcher 分頁；禁止 discovery 的 create/navigate/close 命令，驗證真實 binding/self proof、選回原分頁、草稿、身分改變、別名／多分頁／端點替換拒絕，並確認零貼上／零傳送。未向公司 Teams 發訊息。
- 更新包 SendTeamsMsg_CDP_Existing_Self_Fix.zip；取消或完成舊測試後只重啟設定工具服務／頁面，保留已登入的 CDP Edge、正式 config、登入 profile、排程、綁定及傳送紀錄。
 
# 2026-11-06 截圖前清除滑鼠懸停（capturehover1）
 
- Save-RenderedPage 在還原捲動後、截圖之前共用 Clear-CaptureHover；手動擷取、正式排程、實際排程傳給自己，以及舊完整頁面模式都適用。舊預覽圖片需重新擷取才會更新。
- 有視窗且桌面可用時將實體滑鼠停在主螢幕頂端，離開最大化 Edge 的網頁區域；CDP 發送 viewport 外的 mouseMoved，觸發真正 pointer/mouse leave 與 CSS :hover 更新，等待一秒供延遲提示／淡出完成，截圖前再送一次移出事件。無視窗／桌面不可用時只使用 CDP，不操作實體滑鼠。
- 不以刪除 tooltip DOM、注入全域樣式、點擊空白或 Escape 清理，以免改變網站資料／展開狀態。原 capture_view、縮放、捲動、裁切、登入與送出確認規則保留。
- tools/test_capture_hover.ps1 用真正 Edge（有視窗／無視窗）驗證 CSS 反白、500ms 延遲加 250ms 淡出的 tooltip、Canvas 重繪、iframe leave、左上角懸停，及 80/100/125% 裁切結果逐檔相同。有視窗另外以實際 Windows 滑鼠重現並清除懸停。正式排程共用入口另作回歸。
- 更新包 SendTeamsMsg_Capture_Hover_Fix.zip；保留原 config、sample_images、sample_data.js、edge_profile、captures、logs、排程、CDP 完整狀態。更新後重新抓圖或使用「執行排程傳給自己」取得新結果。
 
# 2026-11-06 實際執行排程傳給自己（selfschedule1）
 
- 預覽傳給自己旁新增「執行排程傳給自己」。必須選一個排程；以點擊時設定的獨立快照呼叫 /api/test-self-schedule → -SelfScheduleJob，不寫正式 config、不改 Windows 排程或原收件人。
- 直接共用正式排程主流程：Resolve-SchedulePages、Capture-PagesNative（登入、縮放、capture_view、裁切）、規則判定、標記圖與 Get-TeamsMessageText。排程停用仍可手動測試；停用頁面略過。測試忽略 alert_only，正常也傳結果；本次確認後一定送出，忽略正式 auto_press_enter=false。
- 主流程強制只建立「自己」分組，以 -SelfTest 傳送並沿用實際本人辨識、設定頁面確認、確認後身分／草稿重核對。全部原收件人及多收件人清單無效；不碰正式 CDP 綁定。預覽模式保留既有流程。
- 狀態檔以完整取代方式發布；讀取使用可共享刪除的 handle 和短重試，避免更新瞬間 Get-Content 路徑檢查回報 HTTP 500。500 次更新及並行讀取通過。
- 兩顆按鈕共用工作鎖、狀態輪詢與防重送編號；capturing/analyzing/finding/confirming/sending 都可見。已有執行工作時測試立即停止，不排隊三十分鐘。部分失敗保留成功圖片並附具名提醒。
- logs/self_tests/<id>/ 下保存本次實際 captures、worker/transcript 與確認結果；含網站登入資訊的 run-config.json 正常結束／取消後移除。不要把測試檔當成正式登入或 CDP 狀態清理。
- tools/test_self_schedule.ps1 以隔離服務、子程序、正式判定流程驗證；最後一案真正用 Edge 擷取本機頁面，驗證保存的 viewport/scroll 及紅色像素觸發警戒線。Teams 傳送邊界攔截，未向真實帳號傳訊。搭配按鈕、既有預覽 HTTP、一般排程与完整 UI 回歸。
- 更新包 SendTeamsMsg_Live_Schedule_Self_Update.zip；保留原 config、sample_images、sample_data.js、edge_profile、captures、logs、Windows 任務與完整 E3TeamsCdpSendTest 狀態。關閉設定服務與頁面後覆蓋更新，再以 open_calibrator.bat 重開。
 
# 2026-11-06 自己測試改用設定頁面確認（selfconfirm1）
 
- 移除隱藏於 Edge 後面的 WinForms 確認框。calibrator.html 原生 dialog 在頁面中央顯示實際對話、帳號（CDP）、預覽名稱與圖片數；核對勾選後才可確認。Escape/取消停止，預設五分鐘逾時停止。
- teams_self_test.ps1 以每筆工作隨機 token 發布 confirming 狀態，等待 decision.json；HTTP /api/test-self-confirm 驗證同源、工作 ID、token、狀態與期限。第一個決定原子寫入且不可覆蓋；相同決定重試只回覆既有結果，不重新啟動或傳送。
- 顯示 dialog 時設定唯一 title marker；worker 找到唯一相符的 msedge 視窗後只嘗試一次切到前景。確認後仍走原有身分／對話／草稿重核對。瀏覽器更新、斷線與服務重啟只查原工作，不自動重送。
- tools/test_self_confirmation.ps1 使用隔離服務、真正 Edge 和子程序，截斷 Teams 發送邊界；驗證前景、頁面確認、取消、逾時、重複／錯誤確認、失去回應及重啟。此證據不代表公司 Teams 已完成實際發送驗收。
- 更新包 SendTeamsMsg_InPage_Confirmation_Update.zip；保留 config、登入、擷取、logs、排程及完整 CDP 狀態。舊版已開的 Windows 確認框先按「否」，待測試停止後再更新並重啟設定服務與頁面。
# 2026-11-06 側欄收合與實際本人參與者階層（panels1 / selfparticipants1）
 
- calibrator.html 增加排程名稱／時間搜尋、完整名稱換行、頁面／收件人／訊息／判定明細 details 收合、按收件人收合預覽與按批次顯示更多。右側排程選單及操作鈕 sticky；整體異常及自己測試狀態保留在收合區外。
- UI 狀態存 localStorage e3PanelLayout.v1；fold keys 依排程 ID／收件人，最後展開排程依 ID 保存。儲存拒絕不阻斷操作。顯示更多數量只保留於本頁生命週期。每輪 PNG 轉換共用，收合群組不建立圖片 DOM；發送 payload 與 config 不受顯示上限影響。
- 使用者診斷已收到：原生屬性正常，但 h2 名稱是「聊天參與者」，本人完整姓名是下層 description，不是同名 heading；聊天列 selected=false。先前「只缺 .NET 屬性」的修正不足。
- teams_self_test.ps1 原生 Reader 新增觀察到的 chat-topic-person-8:orgid:* → 唯一 listitem/list → level2 heading → entity-header-title-area-prim → chat-header-* 辨識路徑。要求可見、姓名完全相符且參與者唯一；納入 person ID、chat header ID 與 runtime ID 作固定核對。managed 找不到同名 heading 時也走原生路徑。送出確認、草稿／焦點／多視窗／身分變更的停止規則保留。
- tools/panel_layout_ui_checks.js：125 頁／30 排程、收合／搜尋／儲存拒絕／完整 payload 不變通過。tools/make_screenshots.ps1 原有 UI 回歸通過，分批檢查先按顯示更多後驗證完整内容，手冊 14 圖更新。
- tools/test_self_participants.ps1：實際診斷匿名階層在真實 Windows UIA 的 managed/native 各 9 案例通過；原 Reader 同場景返回 0。既有各 15 辨識、37 自己測試、28 UIA 流程與五模式 HTTP 回歸通過。尚未真實 Teams 送達驗收。
- 證據 tools/validation_panel_layout/RESULT.md、tools/validation_self_participants/RESULT.md。合併更新包 SendTeamsMsg_Panels_And_Self_Fix.zip，說明 README_PANELS_AND_SELF_FIX.txt。保留 config、登入、截圖、紀錄、CDP binding/blocked/review 及 Windows 任務；關閉設定服務、覆蓋程式後重啟並重新整理。
 
# 2026-11-06 本人辨識實機仍失敗：先收集診斷
 
- selfidentity2 更新後使用者回報「標頭 0、選取 0、讀取方式 native」。不能宣稱本人辨識已實機修復，也不能只憑模擬 h2 頁面猜測 Teams 結構。正式傳送規則本輪未再變更。
- 新增獨立 diagnose_self_chat.bat/ps1（SendTeamsMsg_Self_Diagnostic.zip）。只讀取 Teams 介面並寫出 Teams_Self_Diagnostic.json；不操作焦點、貼上、送出、登入／設定／排程或草稿，不關閉 Teams。監督程序有 60 秒上限，只終止自己啟動的診斷程序。
- 收集本人名稱相符與上方區域的控制項首行名稱、native heading／ARIA／selected／AutomationId／bounds，以及五層不含 Name 的祖先結構。需要使用者在實際出錯主機執行並提供 JSON，以區分 provider、標頭類型及名稱差異。
- 生成來源 tools/build_self_diagnostic.py、tools/self_diagnostic.template.ps1、tools/self_diagnostic_reader.fragment.cs。工具以現有 COM 介面前綴產生獨立副本，不需要使用者更新主程式。tools/test_self_diagnostic.ps1 在真實 Windows UIA／本機 Edge 驗證 h2/button/span、祖先資訊、獨立啟動與草稿不變；未传真實 Teams。證據 tools/validation_self_diagnostic/RESULT.md。
 
# 2026-11-06 舊版 .NET 本人標頭相容（selfidentity2）
 
- 使用者回報 selfidentity1 顯示「標頭 0、選取 0、支援標頭 False」。目前主機 .NET UIAutomationClient 沒有 HeadingLevelProperty，先前程式直接略過標頭核對。不能因此認定 Teams 沒有標頭。
- teams_self_test.ps1 新增 Get-E3ManagedHeadingProperty 與延後載入的 E3SelfNativeUia.Reader。缺少 .NET 欄位時使用 Windows CUIAutomation / IUIAutomationElement.GetCurrentPropertyValue(30173) 讀取真正 HeadingLevel；不依賴新版 .NET、不增加外部套件。C# COM 宣告僅包含所需介面前綴，未使用的 vtable 槽不得隨意增刪或呼叫。
- 原生讀取限定同一 hwnd/root runtime ID，名稱完全相符、可見且 level 1/2 的標頭，回傳 runtime ID，沿用唯一列／輸入框與確認後身分固定檢查。找不到、多個或讀取失敗均不能取代本人證據；舊有「完整姓名與已選取列」路徑仍可用。原生讀取方法不呼叫聚焦、點選、貼上或送出。
- tools/test_self_identity_uia.ps1 -NativeHeading 只在測試程序模擬缺少 .NET 欄位；生產程式沒有跳過辨識的設定。以前版快照重現「支援標頭 False」，新版以真正 Windows 原生 UIA 通過。managed/native 各 15 情境、標頭改變重核、原生視窗身分不符／介面不可用的拒絕案例通過，另通過 28 項 UIA 流程、37 項自己測試及五模式 HTTP 回歸。
- 完整證據 tools/validation_self_identity_compat/RESULT.md。未傳真實 Teams；開發機缺欄位模擬不代表使用者 Windows/Teams/租戶驗收完成。
- 更新包 SendTeamsMsg_Self_Identity_Compat_Fix.zip；README_SELF_IDENTITY_COMPAT_FIX.txt。需關閉設定工具服務、覆蓋程式後重啟並重新整理。保留 config、截圖、登入、CDP binding/blocked/review、logs 與任務；不升級 .NET、不重綁、不清快取。
 
# 2026-11-06 本人對話辨識（selfidentity1）
 
- 自己測試在解析收件人前直接選擇「自己」，不驗證或沿用設定的預設／頁面／排程對象。CDP 原有帳號、自聊 ID 與確認機制不變。
- UIA 不再要求所有 Teams 版本的聊天列同時含本人標記與 SelectionItem.IsSelected。視窗標題必須含本人標記；聊天列須可見、唯一相符且不是群組。如有選取狀態，不能指向其他列。可用真正 UIA Level1／Level2 標頭（完整名稱一致、可見且唯一）交叉確認；沒有標頭時仍要求舊版完整姓名與已選取列證據。普通訊息文字不能取代標頭，輸入框也必須可見且唯一。
- 確認對話前不貼圖；確認後將 header runtime ID 與既有視窗、程序、列、輸入框一起固定核對。缺少證據、草稿、焦點或身分變更一律停止。不是僅依設定的姓名或視窗標題直接送出。
- Test-ChatTitle/Get-ChatItemFilter 本人標記支援中文半形、全形括號及 您／你／You。一般指定對象比對不變。
- tools/test_self_identity_uia.ps1 使用隔離的有視窗 Edge 本機 HTML 與真正 Windows UI Automation，舊版缺標記／選取兩案例拒絕，新版 15 種情境及標頭變更重核通過。流程替身測試含文字與純圖、取消、草稿、對話／焦點變更；HTTP 五模式與防重送通過。未傳真實 Teams，不能宣稱租戶或使用者主機已驗收。
- 更新包 SendTeamsMsg_Self_Identity_Fix.zip，說明 README_SELF_IDENTITY_FIX.txt。保留全部正式 config、截圖、登入、CDP binding/blocked/review、紀錄與 Windows 任務。重新開啟設定工具服務並重新整理頁面。
 
# 2026-11-06 傳給自己按鈕回饋與狀態恢復（selfbutton1）
 
- 修正原按鈕在 crypto.randomUUID() 不存在、sessionStorage.setItem() 被阻擋時於提示前拋出例外，造成看似毫無反應。安全編號採 randomUUID 或 getRandomValues 16 bytes，沒有 Math.random 降級；無安全亂數／儲存空間時停止並於按鈕下方顯示原因，不 POST。
- 點擊立即顯示準備狀態並鎖住重複操作；预覽、編號、儲存錯誤均顯示持續狀態。POST 最多 15 秒、狀態 GET 最多 10 秒（含 JSON 讀取）；逾時不等於未送出，不重新 POST，只查同 ID。結果不明仍保留防重送 ID 與鎖定。
- 新增「重新查詢測試狀態」，只 GET 原工作。查詢序號與當前 ID 防止舊回應覆寫新工作狀態。sessionStorage 初始讀取失敗不再中斷後續介面綁定。
- /api/test-self-status 在設定工具服務重啟、記憶體工作表遺失時，依合法 32 位 ID 讀 logs/self_tests/<id>/status.json，不重啟 worker。已確認 complete/stopped 才解除前端鎖定；沒有程序證據的 finding/confirming/sending 不自動當成成功或已停止。已知程序退出的 stopped 狀態會落盤，避免下次重啟退回舊狀態。
- teams_self_test.ps1/Save-E3SelfTestStatus 新增選填 directory，支援上述伺服器寫入。原本人／對話確認視窗、CDP/UIA 核對、正式排程 pending2 均保留。
- 測試：tools/test_self_test_button.ps1 在真實隔離 Edge 執行正式按鈕程式、攔截所有 HTTP；舊版重現兩種全空白失敗，新版涵蓋缺 API、儲存讀寫失败、空預覽、拒絕／逾時／中斷及舊回應競態。test_self_test_http 實際 loopback／隔離子程序涵蓋五模式與服務重啟、同 ID 不重送。完整結果見 tools/validation_self_test_button/RESULT.md。未傳真實 Teams，未確認使用者主機的確切故障原因。
- 更新包 SendTeamsMsg_SelfTest_Button_Fix.zip；關閉設定工具服務後覆蓋更新檔，再執行 open_calibrator.bat 並重新整理網頁。保留 config.json、sample_images、sample_data.js、edge_profile、captures、logs、Windows 排程及完整 %LOCALAPPDATA%/E3TeamsCdpSendTest。結果不明時不可只清除瀏覽器紀錄來重送。
 
# 2026-11-06 舊工作封存、新工作檢查後繼續（pending2）
 
本節取代較早版本「同一聊天室只要有 blocked 就一律停止正式傳送」的規則；舊工作不會自動補送，也不會自動當作成功。
 
- 正式 Send-GroupToTeamsCdp 在共用 Mutex 內連線並驗證帳號／聊天室，首批建立新的工作 ID，再檢查舊 blocked。必須確認目前 runtime idle／finished，以及舊工作有終止收據、同 ID 已結束 runtime、原 endpoint 已 idle，或新建的專用 profile 瀏覽器（啟動前已排除舊程序占用）。缺少停止證據仍停止；已取消／過期可最多等 3 秒終止，不推進舊傳送。
- 再以 resume-check.js 驗證固定身分與目前已載入的訊息列沒有 sending／pending，並要求輸入框唯一、無文字、圖片或附件。不能據此宣稱 Teams 隱藏佇列或遠端傳送絕對不存在；不取消 Teams 佇列、不自動刪草稿。
- 通過後先寫 %LOCALAPPDATA%/E3TeamsCdpSendTest/review/<舊ID>_<唯一值>.review.json，保留舊收據快照、原 runtime、停止依據及新工作 ID，再以同磁碟原子移動保留原 blocked 為同名 .pending.json。舊收據不改寫；無相符伺服器成功證據者保留 pending_manual_review。讀寫失敗、紀錄改變、身分／草稿／pending／active 均保留阻擋、不貼圖、不送出。
- 此流程只處理目前傳入的新內容，不讀取或補送舊圖片／文字；新批次仍受原本帳號、圖片、serverack、receipt2 與防重送檢查。新工作失敗仍留下自己的 blocked，後續新工作再重新检查。相同舊／新 ID 明確拒絕。
- 「檢查 CDP 連線」維持只讀、不解除 blocked。2026-11-09 起，兩個「傳給自己」按鈕在使用者確認與本人身分重驗後，也共用正式新工作的恢復判斷；舊工作已停止且沒有草稿／傳送中訊息就執行本次內容，不等待舊結果變成功。設定綁定原有人工核對流程不變。
- 本次 host 新功能不修改 runtime 版本（仍 receipt2），支援既有 headless1／optionaltext1／receipt2 runtime；resume-check 腳本按需執行。無需因本次功能關閉／重綁有視窗分頁。尚未套用前版 receipt2 的分頁，若要取得圖片穩定性診斷，仍需核對後自行重新整理。
- 更新包 SendTeamsMsg_CDP_Pending_Recovery_Update.zip。保留 config.json、sample_images、sample_data.js、edge_profile、captures、logs、Windows 排程及完整 %LOCALAPPDATA%/E3TeamsCdpSendTest（含 review）。測試見 tools/validation_pending_recovery/RESULT.md；未傳真實 Teams、未做 Win+L 實機驗收。
 
# 2026-11-06 CDP 送出後穩定核對（receipt2）
 
- 修正 host 收到相符的伺服器確認後，只讀一次 DOM 就判定失敗的競態。現在最多等 12 秒反覆核對同一 messageId，連續通過至少 1.5 秒才完成；沒有重貼、重按送出或只靠 HTTP 201 成功。帳號／聊天室改變、明確傳送失敗及相異 messageId 立即停止。
- receipt.js 對圖片來源或尺寸變更重新計算穩定時間；pending／草稿／身分失敗也清除先前穩定候選。仍保留逐張比例、順序、張數、載入完成、文字、時間、帳號、聊天室及相符伺服器確認。永久裁切縮圖或仍不相符會保留 uncertain，未以放寬比例規則掩蓋問題。
- 收據新增 receipt.images（預期／實際尺寸、比例符合、張數）與 finalReceiptHistory（核對原因轉換），不記錄圖片 URL、正文、token 或圖片內容。runtime 版本 receipt2；舊 headless1／optionaltext1 分頁相容 host 等待，但新增尺寸診斷與圖片穩定性檢查要核對草稿後手動重新整理原分頁。headless 下次啟動自動載入新版。
- 本機隔離 headless Edge＋loopback HTTP 模擬 4 圖：先形成 DOM 收據，3.5 秒換錯誤比例，5 秒回 HTTP 201，7 秒恢復。舊版重現 image_shape_mismatch；新版等待恢復。負面案例檢查永久不符、缺圖、文字變更、聊天室改變、傳送失敗均保留阻擋且下一排程不開瀏覽器／不重送。詳見 tools/validation_receipt_recheck/RESULT.md。
- 更新包 SendTeamsMsg_CDP_Receipt_Fix.zip；保留 config.json、sample_images、sample_data.js、edge_profile、captures、logs、Windows 排程及整個 %LOCALAPPDATA%/E3TeamsCdpSendTest。既有 blocked 不自動清除，需使用者核對原訊息與草稿後再以「設定 CDP 收件對象」重新確認。未在公司 Teams 或 Windows 鎖定環境重現，不保證原故障一定是短暫縮圖變動。
 
# 2026-11-06 訊息內容全部選填（optionaltext1）
 
- 新增 teams.default_message，預設空白。組合順序為排程 title → default_message → normal_summary 或 abnormal_header → 超標／失敗明細，忽略空白項目、不產生額外空行。既有已填文字保留；缺少屬性及空白不再補預設「目前E3系統正常」或異常標頭。
- 三個訊息欄位均為選填 textarea；前端 composeTeamsMessage 與後端 teams_delivery.ps1/Get-TeamsMessageText 一致。一般预覽與傳給自己的 PNG 快照共用文字組合。全空可只傳圖片；分批時全空也不補「第 n/m 批」文字。沒有圖片也沒有文字則拒絕發送。警戒線／擷取失敗明細仍保留。
- UIA 有圖片而無文字時跳過文字剪貼簿／貼上與文字驗證，保留每次圖片、Enter 前的目的地核對。CDP optionaltext1 runtime 支援 output-image-v1 空文字，仍需有經驗證的圖片；跳過空文字 paste，嚴格辨識只含已驗證圖片及 CKEditor filler 的段落，保留附件、帳號、對話、草稿、收據與 pending 檢查。
- CDP 已載入的 headless1 分頁仍可傳文字，但不允許悄悄降級傳純圖片。純圖片前查 supportsImageOnly；舊分頁會在貼圖前停止並提示：核對訊息／草稿後重新整理原分頁、回到綁定對話。targetId 未變則不用重綁；不自動重整、不清除登入資料。新開啟的 self-test／headless 分頁直接用新版。
- 驗證：test_self_test 36 檢查（含純圖片新版支援／舊版停止）；test_optional_messages 實際引擎七組內容＋五個共用組合檢查；UIA -ImageOnly 28 案例、HTTP -ImageOnly 五模式；CDP 單張／四張純圖片、草稿／帳號／取消／標題／缺附件收據 fixture 與原文字流程通過。optional_message_ui_checks 檢查五模式預覽、留空、訊息編輯與重讀；原多收件人及分類介面回歸通過。make_screenshots 加入第 14 張訊息區塊。未傳真實 Teams，未改正式設定／登入／排程。
- 更新包 SendTeamsMsg_Optional_Message_Update.zip 以原更新包清單加入本次變更；保留 config.json、sample_images、sample_data.js、edge_profile、captures、logs 及整個 %LOCALAPPDATA%/E3TeamsCdpSendTest。重啟設定工具服務與頁面，CDP 純圖片需依上段處理舊分頁。
 
# 2026-11-06 預覽傳給自己、頁面分類與排程排序（self-organize1）
 
- 「將目前預覽傳給自己」改為獨立測試：前端擷取目前預覽排程的 PNG 與文字快照，POST /api/test-self，子程序 -SelfTestJob 在 logs/self_tests/<id> 執行；不呼叫 Save-ConfigBody，不改正式收件人、排程或 CDP 綁定。全部啟用頁面亦可測試。警戒線提示沿用預覽；測試忽略 alert_only。成功圖片保留，失敗頁列明原因；每則維持 4 張／25 MiB。輸入限制單張 10 MiB、4096 邊長／1600 萬畫素、快照合計 75 MiB。
- 每次傳送前必須先辨識自聊，再顯示實際對話供使用者確認，預設「否」。UIA 選定唯一視窗，核對本人標記、選取列、完整標題、視窗／輸入框 RuntimeId；確認後及每次貼上／Enter 前重新核對，焦點改變就停止。CDP 有視窗改沿用已開啟的本人分頁（見 selfexisting1）；無視窗沿用設定的 headless 專用 profile，嚴格驗證 accountId/chatId/isSelf；確認後再檢查身分與空草稿，沿用正式 runtime 的持續身分核對及 pending/receipt 防重送。一般視窗不提供 CDP 的帳號郵件證據，確認框明列 UIA 辨識依據；無法判定時不降級猜測。
- 非同步狀態 /api/test-self-status，重複 job ID 拒絕重跑；確認中／傳送中停用按鈕。失去回應保留鎖定與 job ID，重整只查狀態，不自動重送。測試需解鎖桌面以完成確認；不變更正式排程鎖屏 CDP 能力。無實際 Teams 自聊驗收，本次只跑隔離 fixture。
- config.page_categories = [{id,name}]；pages[].category_id 指向分類。舊頁面及未知分類顯示「未分類」。一次只顯示目前分類，搜尋名稱，每頁最多 20 張卡片。新增頁面繼承選取分類；可重新命名、移動頁面；刪除分類移回未分類，保留頁面與排程。分類只影響維護介面，不影響排程執行。
- 排程頁面改成依分類分組的下拉選單，可搜尋名稱／分類、逐一加入；已加入者不重複出現。清單顯示完整名稱換行，↑／↓／移除依序操作 schedules[].pages，不再按 config.pages 的全域順序重排。既有排序原樣保留；停用／遺失頁面保留可見提示供修正。
- 新必備檔 teams_self_test.ps1（UTF-8 BOM）、teams_self_test.js；JS 僅由 PowerShell 注入 CDP，瀏覽器不直接載入，不加入 HTTP 靜態白名單。更新時與引擎、calibrator.html、teams_delivery.ps1、teams_cdp/Delivery.ps1 一起部署。原 config.json、sample_images、sample_data.js、edge_profile、captures、logs、%LOCALAPPDATA%/E3TeamsCdpSendTest 全部保留，不需重綁原對象或重註冊既有正確排程；須重啟設定工具服務及頁面。
- 驗證：test_self_test.ps1 32 檢查；test_self_test_uia.ps1 28 流程案例；test_self_test_http.ps1 真實 HTTP＋隔離子程序涵蓋五模式、快照、重複請求與分類／順序存取。make_screenshots 附加 self_test_ui_checks、page_organization_ui_checks，以 125 頁驗證分類／搜尋／分頁／完整名稱／排序及原功能，重拍 13 張手冊圖片。既有 review_fixes 14 情境、multi_targets 15 情境，以及 CDP closed-menu／changed-chat／account-change／cancel-before-click／draft fixture 通過。測試未傳真實 Teams、未改正式設定及 Windows 排程。
 
# 2026-11-06 CDP 設定時確認關閉占用 Edge（restart1）
 
使用者要求：設定 CDP 收件對象遇到專用登入資料被 Edge 占用時，直接詢問是否關閉並重啟，不必自行找背景程序。
 
- 僅 `Set-E3CdpBinding` 呼叫 `Start-E3TestBrowser -InteractiveRestart`；沿用 `Local\E3TeamsCdpShared` Mutex，其他傳送／設定尚在進行時仍停止，不搶占。排程、連線檢查與一般 headless 啟動不傳此開關，不提問或終止占用程序。
- `Request-E3ProfileRestart` 限定 Get-E3CdpStateRoot/profile，列出占用 PID、分頁／草稿影響及 pending 數量。輸入 Y 才執行，Enter／其他輸入取消。先 CloseMainWindow，再核對 DevToolsActivePort 的 port、browser path 與監聽程序確實屬於該 profile，才送 Browser.close；等待後必要時強制結束已確認的相同 PID／CreationDate 程序。仍有占用則不啟動第二個瀏覽器。
- `Test-E3ProfileCommandLine` 比對完整 --user-data-dir 參數、正規化絕對路徑，不使用字串包含比對；profile_other、網址中出現路徑、多組／相對路徑均不視為匹配。關閉後等待也共用此完整比對，避免把名稱相近的其他 Edge 誤認為殘留。
- 重啟不刪除 profile、session、bindings、blocked。保留視窗模式若 session 可沿用，仍只開新分頁，不重啟。實際重啟會關閉該專用 Edge 的全部分頁，其他分頁模式路由需重綁。若本次因重啟重新綁定的聊天室仍有 pending，BIND 後需再輸入 CHECKED 確認已核對已送訊息／草稿，才允許原本的清除 pending 流程；取消則原綁定與阻擋不变。不自動重送。
 
驗證：`tools/test_cdp_profile_restart.ps1` 使用兩個隔離真實 headless Edge，驗證精確路徑／重用 PID 防護、取消、無人值守不提問、錯誤 port 不關其他 Edge、正常與強制結束、同一次 Start 自動重開及狀態檔保留。既有 headless_binding 加入 restart/CHECKED 流程；startup_cleanup、recovery 回歸通過。僅 about:blank／本機測試資料，不關閉正式 Edge、不傳 Teams。只有 PowerShell 設定流程與說明變更，calibrator 網頁與既有 13 張手冊圖不變。瀏覽器 runtime／七段 JS 未變，不因本次程式更新強制重綁。
 
更新包 `SendTeamsMsg_CdpRestart_Update.zip`，說明見 README_CDP_RESTART_UPDATE.txt；保留所有正式設定、圖片、logs、截圖與 Teams profile、綁定及待核對狀態。
 
# 2026-11-06 擷取整組保存與排程核對（commitfix1）
 
修正第二輪檢查的三項問題：失敗後自動保存新位置、最後寫檔期間修改網址、排程更新失敗卻顯示已同步。以下規則取代 reviewfix1 的分開保存方式。
 
- `fetchLiveUrlScreenshot` 保留前段設定版本檢查；圖片載入後先等待既有保存結束，再檢查一次。最後提交期間設 workspace.inert、攔截編輯事件並暫停自動／手動保存。候選圖片、裁切與位置只存在局部變數，提交成功前不修改 config、fullImages 或裁切圖。失敗後下一輪 autoSave 不會保存候選位置。
- 新增 `/api/commit-capture` 與 `Save-CaptureBundle`：後端在 `Local\E3MonitorNativeRun` Mutex 內重讀 config，核對 expectedPage，驗證 PNG／裁切範圍，準備 full、crop、config 三份新檔與舊檔備份，最後依序取代。一般寫入例外回復已取代檔案；回復也失敗時保留 .bak，回傳 uncertain，要求停止編輯檢查權限。PowerShell 5.1 的 File.Replace 空備份參數必須使用 `[NullString]::Value`。主引擎／預覽取得執行 Mutex 後重讀 config，避免沿用等待提交前的設定。這不是斷電或強制結束程序的耐久交易保證。
- 新 API 只修改當頁的 capture_view、browser_zoom、crop_region，其他設定沿用磁碟最新值。回傳實際保存的 config 作為 lastSavedJson 基準，等待擷取時對其他頁面的未保存編輯仍會送出。網路中斷或回應不完整時無法判定是否已提交：停止編輯與自動保存，要求重新整理讀回磁碟資料，不盲目用舊記憶體覆寫。既有 `/api/save-sample` 仍供裁切拖曳與手動載入圖片使用，不用於這次抓圖提交。
- `Get-E3TaskSchedule` 讀取 Windows 任務實際觸發器，回傳每天／每週的時間與星期；不支援的類型、多重觸發器、非每一天／每一週間隔、重複間隔及停用觸發器不視為相符。`/api/schedule-status` 增加 enabled、schedule。前端比對任務清單、時間、星期、啟用狀態及喚醒／補跑，不以任務存在作為已同步證據。
- `lastAttemptedSchedulesJson` 與 `lastAppliedSchedulesJson` 分開；只有實際核對通過才標記同步。失敗後保留提示，普通設定保存不蓋成同步成功，不每秒自動重註冊；修改排程時間／星期等欄位或按重新套用才再試。頁面剛載入不自動改正式 Windows 任務。
 
驗證：`test_capture_commit.ps1` 涵蓋三個取代位置失敗、全新檔案回復、設定衝突、無效圖片／裁切及任務觸發器解析。`test_capture_commit_http.ps1` 啟動隔離服務，檢查真實 HTTP 提交、回讀、409 拒絕、Windows 實際檔案鎖導致失敗後整組回復與解除鎖定後再保存。`review_ui_checks.js` 覆蓋 15 種擷取／提交情境（包含下一輪自動保存、最後寫檔編輯、其他頁面編輯、回應中斷）；`schedule_sync_checks.js` 驗證時間／星期／停用／舊服務／多餘任務、更新失敗保持提示、普通保存不重試及手動重試。兩支 JS 由 make_screenshots 的隔離瀏覽器執行並重拍 13 張手冊圖。既有 14 個 reviewfix、15 個多收件、27 個 alert_only 引擎案例及 9 項排程恢復測試通過；不發真實 Teams、不修改正式任務。
 
更新包 `SendTeamsMsg_CommitFix_Update.zip`，操作見 README_COMMIT_FIX_UPDATE.txt。前後端必须一起更新並重新開啟設定工具服務／頁面；保留 config.json、sample_images、sample_data.js、edge_profile、captures、logs 及整個 %LOCALAPPDATA%\E3TeamsCdpSendTest。無需重綁 CDP 或重新註冊原本已正確的 Windows 排程。
 
# 2026-11-06 專案檢查修正（reviewfix1）
 
修正四項檢查結果，不修改正式 config、帳密、CDP 綁定或 Windows 任務：
 
- 抓圖開始記住頁面物件與完整設定（含解析後帳密）；等待儲存後、送出請求前及圖片載入後再次確認。網址、縮放、帳密、裁切、規則、頁面刪除或替換等變更會捨棄舊結果；只切換目前選取頁面仍可保存到原頁。按鈕等待圖片載入完才解除，避免前次 onload 覆蓋新工作。
- `/api/capture-status` 只回傳暫存候選 PNG／capture_view 並清除暫存，不再先覆蓋 `<id>_full.png`。前端檢查通過後才經既有 `/api/save-sample` 立即保存 full／crop，等待兩份圖片與設定保存成功才提示完成。前後端必須一起更新並重新開啟設定服務／設定頁；不只更新 HTML。擷取後保存失敗不再被成功提示蓋掉。
- `Save-ConfigBody` 驗證頁面 id 合法且唯一（OrdinalIgnoreCase），排程 pages 為清單且所引用 id 存在；拒絕時原檔不變。舊版無 schedules、空頁面／空排程草稿、明確停用頁面仍相容。
- `Resolve-SchedulePages` 透過 MissingPages 回傳不存在的引用。執行時保留可用圖片，把缺頁原因附到既有收件組；沒有可用頁面時依排程清單／舊單一對象／預設對象純文字通知，不開截圖瀏覽器。回報 exit 1，僅異常模式不抑制，單一收件失敗仍繼續其他對象。明確停用與空排程仍略過。預覽同步顯示缺頁待確認與通知內容。
- 加入 `[hidden] { display:none !important; }`，避免 button／label 的 display 覆蓋隱藏屬性。介面與 teams_cdp/README 統一建議先使用保留專用 Edge，無視窗需實機驗證；保留舊設定 cdp_headless 缺省 true 的相容行為，不自動替使用者切換模式。
 
測試：`tools/test_review_fixes.ps1` 使用引擎隔離副本、擷取／Teams 替身與記憶體 HTTP 回應，覆蓋缺頁通知、保存拒絕不覆檔與候選圖不覆寫原圖。`tools/review_ui_checks.js` 由 make_screenshots 的隔離瀏覽器執行，驗證五模式實際可見性、十二種擷取與保存情境及缺頁多收件預覽；同步產生 13 張手冊圖。驗證通過：14 個新增引擎案例、8 個保存案例、3 個候選圖檢查；既有 multi_targets 15 案例及 alert_only 27 案例全部通過。本次不發真實 Teams、不操作正式網站或註冊 Windows 任務。
 
更新包：`SendTeamsMsg_ReviewFix_Update.zip`，操作見 `README_REVIEW_FIX_UPDATE.txt`。保留 config.json、sample_images、sample_data.js、edge_profile、captures、logs 及整個 %LOCALAPPDATA%\E3TeamsCdpSendTest。既有專用 Teams Edge 不需關閉或重綁；只需重新開啟設定工具服務與設定頁。
 
# 2026-11-06 排程多收件對象（multitarget1）
 
新增 `schedules[].target_chat_names` 字串陣列。「排程收件對象（可多個）」每列一個名稱，可新增／移除；清單非空時覆寫原頁面／全域對象，所有選定頁面依清單順序逐一發送。去除前後空白與空項、按 Ordinal 去重（保留大小寫差別）。缺少新欄位才讀舊 target_chat_name；新清單為空時沿用頁面／全域對象，不恢復舊單一名稱。介面編輯清單時清空舊欄位。收件變更只存設定、不改 scheduleSignature 或 Windows 任務。
 
`teams_delivery.ps1/Get-TeamsScheduleTargets` 共用於引擎、CDP 設定／連線檢查與 UIA 偵測。主流程僅擷取／分析一次，非空清單先彙整全部頁面結果，再將相同圖片路徑、alerts、failures 分派給其餘對象。chatGroups 使用 Ordinal OrderedDictionary，順序与 CDP 名稱比對一致；每個對象保留原分批、逐對象 catch 及不自動重送。僅異常條件在分派後統一套用，正常全部不發送；超標／失敗則通知清單全部對象。相同名稱只發送一次；不同名稱若被人工綁到同一實際聊天室，仍是不同路由，設定時應避免重複對應。
 
預覽只分析每頁一次，再複製到各收件卡片，保留圖片／文字／批次順序；不把多收件數乘入超標數。頁面實際對象提示、正式送出確認、CDP 綁定與全部連線檢查都涵蓋清單。每個收件名稱需有自己的 CDP 綁定；保留視窗模式在同一專用 Edge 建立多個對應分頁，多個排程可共用同一名稱。新增不同對象不取代其他綁定。
 
驗證：tools/test_multi_targets.ps1 在隔離副本以擷取／傳送替身檢查五種模式、一次擷取／分析、相同檔案與訊息、順序去重、空清單／舊設定、某個對象失敗／未綁定後繼續、部分截圖失敗、僅異常模式。test_cdp_headless_binding 改用多收件排程覆寫，驗證逐項檢查及 blocked 保留；既有 alert_only 與 capture_delivery_consistency 回歸。make_screenshots 加入實際瀏覽器清單增刪、保存回讀、預覽多批、確認對象、不重註冊與舊設定相容，重拍 13 張手冊圖。只用測試資料，不傳正式 Teams、不改正式 config／Windows 任務。
 
更新包：`SendTeamsMsg_MultiTarget_Update.zip`，操作见 `README_MULTI_TARGET_UPDATE.txt`。必須包含 teams_delivery.ps1 与 teams_cdp/Delivery.ps1；七段內嵌瀏覽器腳本未變，不因本次更新重綁既有對象，新對象需另外 BIND。包含前版每頁帳密與僅異常模式。手冊更新 4-1／4-2 收件操作與預覽、CDP 綁定說明、8-1 更新包；本文件本節說明設定與分派原理，teams_cdp/README.md 補上清單規則。
 
使用者已補充確認：在其實際主機，保留專用 Edge 視窗的 CDP 模式於 Windows 隔夜鎖定後仍正常發送。此為使用者回報，未提供本次新測試紀錄；不外推無視窗模式、其他主機或登入永不過期。
 
# 2026-11-06 排程僅異常時發送（alertonly1）
 
`schedules[].alert_only` 為布林值，預設 false；舊排程缺少欄位維持每次發送。設定工具每張排程卡片新增「僅異常時發送」，收合摘要顯示「僅異常」。只存 config，不納入 scheduleSignature，因此不重註冊 Windows 任務。
 
主流程完成所有頁面擷取與分析後，彙總各 chatGroups 的 alerts／failures。指定排程且 alert_only=true、全排程無超標也無失敗時，記錄「不發送 Teams；截圖與紀錄已保留」，在桌面等待與 Send-GroupToTeams 前略過所有組別。任一組異常則依原路由發送全排程的可用截圖，各組仍只收到自己原本的圖片與訊息，不合併不同收件對象。其他組可能收到其正常總結；失敗組的原因不跨組散布。截圖全部失敗仍純文字通知。無啟用規則時只由監控失敗觸發；沒有指定 -Schedule 的執行不受此開關影響。指定排程的 TestSample／DryRun 同樣遵守，不另設強制傳送繞過；每次超標均提醒，不儲存前次告警狀態，也不發恢復通知。
 
警戒線無法判定不可視為正常：完整／部分超出圖片、非正尺寸或高度不在 ROI 內，列為 failures，保留原截圖並 exit 1；其他型別／分析例外沿用逐頁錯誤處理。超標訊息空白時補上頁名／規則名，避免無內容告警。設定工具 evaluateRule 與預覽同步檢查範圍；缺預覽圖標為待確認，不宣稱正常。右側正常時不顯示傳送卡片，改提示本次預估不發送；最終仍以當次截圖判定。
 
驗證：tools/test_alert_only.ps1 用真實主引擎、合成 PNG 與暫存 config，僅替換 Send-GroupToTeams／Wait-TeamsDesktop 為本機紀錄，檢查五種傳送模式、正常零呼叫、超標／失敗跨原分組、規則無效、無規則、空白訊息、預設相容、未指定排程及重複超標。make_screenshots.ps1 加入瀏覽器 UI 開關保存／回讀、不重註冊簽章、正常／超標／無效規則／缺圖預覽測試並重拍手冊 13 張圖。測試不發真實 Teams、不修改正式 config 或 Windows 任務。
 
更新包 `SendTeamsMsg_AlertOnly_Update.zip` 包含前版每頁帳密功能與現版程式／兩份文件，操作見 `README_ALERT_ONLY_UPDATE.txt`；不含使用者設定或登入資料。重新開啟設定工具服務後自行勾選排程，無需重綁 CDP 或重新註冊排程。手冊更新 4-1／4-2 的操作與預覽、7 的未通知／規則失敗說明、8-1 更新包；本檔更新本節、3.4 的無效規則說明。以下舊紀錄以本節為準。
 
# 2026-11-06 每頁獨立帳密（pageauth1）
 
更新包：`SendTeamsMsg_PageAuth_Update.zip`；操作見 `README_PAGE_AUTH_UPDATE.txt`。包含現版程式、teams_delivery／teams_cdp 與兩份文件，不含 config、使用者圖片或登入狀態。本次 Teams 模組未變更，不因本次更新要求重綁；只需重新開啟設定工具服務，原 Windows 排程無需重註冊。
 
設定工具在「頁面與警戒線」加入「使用帳密自動登入」、此頁帳號／密碼。新增頁面預設停用；全域設定只保留手動登入入口。`pages[].auth = {enabled, username, password}` 明確覆寫舊全域設定，停用或 null 不回退；只有缺少 auth 的舊頁面使用 `config.auth`。介面讀取舊設定時為各頁建立獨立副本，排除 YOUR_USERNAME 佔位值，仍保留原全域資料供舊頁面相容。不主動修改正式 config 或登入 profile。
 
`Get-PageAuth` 共用於 `Capture-PagesNative` 與 PreviewCapture 的預覽頁建立；每頁遇到登入畫面時才選取該頁帳密。不強制登出既有登入、不保證切換已登入帳號，同站多帳號仍共用 edge_profile，SSO／MFA／特殊表單沿用手動登入限制。停用頁面遇密碼框仍失敗；只有訪客頁面的 Login 連結而未啟用帳密時不自動點選。錯誤帳密仍列為該頁失敗，其他成功頁继续處理。
 
抓圖會等既有儲存完成，再 await 保存目前 config，成功後才呼叫 /api/capture-url；保存期間鎖定 autoSave，避免舊儲存覆蓋剛輸入的帳密。未載入正式設定或儲存失敗時不開抓圖，錯誤提示保留原因。未將帳密加入 CLI 參數或 log；既有 config.json／localStorage 的明文保存方式不變。抓圖取消不提交新圖片、viewport 或裁切，但按抓圖前編輯的登入設定已先保存。
 
驗證：tools/test_page_auth.ps1 與 page_auth_fixture.py 使用四個隔離 loopback 網站、合成帳密、暫存 Edge profile；檢查四站分別登入、登入按鈕跳轉、錯誤密碼與停用時不送全域帳密、逐頁失敗隔離、實際 PreviewCapture CLI。Python 僅測試 fixture 使用，正式程式依舊只需 PowerShell／Edge。make_screenshots.ps1 加入實際瀏覽器的頁面切換、啟停／密碼遮蔽、舊設定搬移、新頁預設與抓圖前儲存／失敗阻擋檢查，重建手冊截圖。正式四個網站的表單與 MFA 仍需逐頁按抓圖確認，無 Teams 傳送或 Windows 排程修改。
 
本次更新手冊 1-2、1-3、3 的抓圖提示與 7 的登入問題，開發文件本節及 3.4／5 的登入說明。以下較早日期的全域帳密描述是歷史紀錄，以本節為準。
 
# 目前操作建議與驗證界線（更新：2026-11-05）
 
- **建議先採用保留視窗 CDP**：設定工具選 CDP，取消「使用無視窗 Edge 傳送」、先儲存，再設定正式收件對象。BIND 後保留專用 Teams 分頁與對話；關閉或重新開機後需重新設定分頁綁定。更新包不修改 config，缺少 teams.cdp_headless 時程式仍預設 true；建議模式不等於已替使用者切換正式設定。
- **已驗證**：本機有視窗解鎖、短時間 Win+L 鎖定，各傳送 1 則文字＋1 張測試圖，使用者確認收到。鎖定工作 4ce1abd408ee430883b537104973f415 在開始、送出前、結束均 unavailable，Worker POST 201、DOM 與手機核對通過。只代表該次本機測試。
- **尚未驗證**：v8 無視窗模式的真實 Teams 鎖定收件、正式多圖排程、其他主機、整晚鎖定至隔天 08:00。背景 Worker 修正適用兩種 CDP 模式，不可由保留視窗測試推論 headless 成功；較早 headless 的本機新訊息／未辨識 HTTP 201 不是送達證據。
- **設定後視窗自動關閉**：啟用 headless 時屬預期行為；Set-E3CdpBinding 正常關閉設定 Edge 後驗證無視窗登入／聊天室，不傳訊息。保留視窗模式則應顯示需保持專用 Edge 開啟。不要把另一個日常 Teams 視窗當作可自動接管的 CDP 分頁；同 profile 佔用也可能阻止 headless 啟動。
- **分頁休眠**：現有背景節流參數、Page.setWebLifecycleState(active)、焦點模擬在啟動／操作時降低背景影響，並非整晚不休眠保證。建議使用者在專用 Edge 的系統與效能設定，將 teams.cloud.microsoft、teams.microsoft.com 加入不休眠網站；UI 名稱與可否修改依版本／公司政策而定。本次未自動改 Edge 或系統電源設定。
- **整機睡眠與排程**：註冊程式已設 WakeToRun、StartWhenAvailable；舊任務需按「重新套用」，僅更新檔案不會改既有任務。SetThreadExecutionState 只在監控任務執行期間要求保持清醒，結束解除，並非排程前整晚的守候服務；不能代替喚醒設定，也不能阻止手動睡眠、登出或斷電。鎖定／熄屏與睡眠不同；硬體、供電、喚醒計時器與政策仍會影響準時啟動。
- **登入與隔夜驗證**：MFA／登入過期需要解鎖處理；保留視窗不保證永遠登入。隔夜測試應在實際主機前晚確認連線並保留專用分頁，Win+L 後按實際供電／網路條件等隔天 08:00，核對啟動、截圖時間、三個桌面快照、serverReceipt 與手機收件。此測試尚未建立或執行，三個快照也不證明整晚狀態。
- **紀錄與保留資料**：新啟動診斷為專案 logs/日期/startup_*.json；新收據為 logs/日期/receipts/*.json；Edge stdout/stderr 同在 logs/日期。LOCALAPPDATA/E3TeamsCdpSendTest 仍是正式登入、bindings/session 與 blocked 狀態；保留 config、sample_images、edge_profile、captures、logs。兩種 CDP 模式的 uncertain 均保留阻擋，不自動重送；先核對手機與草稿再處理。
 
本次同步重整 USER_MANUAL.html 的 CDP 操作、模式比較、視窗關閉原因、休眠／電源、登入與隔夜驗證說明，修正舊步驟要求勾選 headless 及舊 AppData 收據路徑。只改文件，沒有改程式、設定、排程或登入資料；介面與手冊原截圖資源未變。以下日期段落保留各階段的開發歷史，當時的「未驗證」等敘述應以本節與最新實測結果為準。
 
### 2026-11-05 15:06 真人鎖定測試通過（worker1）
 
使用者確認收到 visible_locked 文字與一張測試圖片。收據 4ce1abd408ee430883b537104973f415：headless=false；desktopAtStart、desktopBeforeClick、desktop 均 unavailable；Worker POST https://teams.cloud.microsoft/api/chatsvc/apac/v1/users/ME/conversations/{id}/messages 回覆 201；serverId=1793862390654；DOM 核對通過，程序 exit 0。證實本機「保留有視窗專用 Edge＋CDP」可在鎖定時發送一則一圖訊息，並確認原先這筆誤判來自主頁觀察器漏掉 Worker。不能外推到無視窗、多圖正式監控、其他主機。
 
實測只送兩則：visible_unlocked 與 visible_locked，各一次；首次鎖定等待曾逾時而未送出，重啟等待後才執行鎖定測試。使用者已確認兩則收件，未重送任何已確認訊息。測試配置／profile 獨立；正式 config、登入、綁定未改。詳見 logs/manual_cdp_test/20261105_143836/RESULT.md；有視窗 Edge 保留開啟。正式模式需由設定工具取消 headless 並建立正式收件綁定。v8 更新包已納入實測說明。
 
### 2026-11-05 Teams 背景 Worker 網路確認（worker1）
 
使用者授權本機登入與測試。以獨立 E3TeamsCdpLocalTest/20261105_143836 profile、本人聊天室、有視窗解鎖模式送出一張純測試圖。使用者已從手機確認文字和圖片都收到；原 host 卻 uncertain。實機頁面層的 201 是 as-prod.asyncgw.teams.microsoft.com/v1/objects 圖片物件建立和 PUT 上傳，沒有真正的訊息請求；Teams 分頁另有兩個 Dedicated Worker。主頁面單一 Network observer 的覆蓋不足，因此補上關聯 Worker 的觀察。
 
Invoke-E3Cdp 新增可選 SessionId，支援 flattened 子 session 指令；Target.setAutoAttach 只針對目前 Teams 分頁的關聯目標，waitForDebuggerOnStart=false，不暫停 app。Target.attachedToTarget 僅佇列 worker/shared_worker/service_worker；在外層呼叫 Update-E3NetworkWorkers 執行各 worker 的 Network.enable，避免在接收迴圈內遞迴讀走原指令回覆。request key 加入 session ID，Network.getResponseBody 從原 worker session 讀取。每批保留已附加 worker 狀態，收據保存 workerObserver 與 network[].source。未知端點、聊天／訊息 ID、HTTP 狀態及防重送條件不放寬。缺少 worker 支援會留下診斷，不能拿圖片上傳 201 當訊息確認。
 
本機 fixture 第二批改由真實 Dedicated Worker 發出延遲訊息 POST，驗證只有 worker source 的 HTTP 201 亦可精確核對，並重跑原失敗／防重送情境。備份在 D:\00058897\SendTeamsMsg_worker_backup_20261105_144339。真人測試 log 在 logs/manual_cdp_test/20261105_143836；第一筆已由使用者明確確認收件，記錄 confirmed_visible_unlocked.json 後只解除該筆測試 profile 的 blocked，不重送。正式 config 與 profile 保持原樣。鎖定實測已通過，結果見該目錄 RESULT.md 與本文件最新紀錄。
 
teams_cdp 保持兩檔，七段內嵌 JS 不變。新包 SendTeamsMsg_CDP_Compact_v8.zip，不含登入資料、log 或設定。Headless 的正式租戶／鎖定可用性不得從有視窗測試推論。
 
### 2026-11-05 補足未辨識請求的端點診斷（endpoint1）
 
使用者提供工作 ecde43e2 的收據：headless=true，DOM confirmed_new_row，但全部 network 為 other_post，其中有 HTTP 201，server_ack_not_confirmed。這只能確定觀察器未辨識相符訊息請求，不能從 201 直接認定訊息送達，也不能推定租戶拒絕 headless。原收據 desktop=interactive 是結束快照，無法證明整段鎖定。
 
新增 Get-E3EndpointDiagnostic：保留主機與固定 API 字詞組成的路徑樣板，任意 path 值（含聊天 ID、帳號）一律 {value}，query/userinfo/header/body 不保存。分類包含 unrecognized_host、unsupported_origin、unsupported_message_path、different_chat_id、unsupported_path_suffix、unsupported_method、before_send_checkpoint、recognized。加入 request method、sequence、hasPostData、observedAfterClickCheckpoint；按 sequence 排序。額外觀察 PUT/PATCH 只供診斷，仍只有原本信任端點的 POST 可進入成功核對；未擴充主機白名單，也未放寬聊天／訊息 ID、200/201、快取、錯誤或防重送規則。
 
收據新增 diagnostics=endpoint1、desktopAtStart、desktopBeforeClick，原 desktop 仍為結束快照。這三個快照不等於完整鎖定歷程；若要證實接收，仍需手機／另一個 Teams 視窗核對。初始 modelReady 在送出後可能隨空輸入框變回 false，不可據此判定送出前圖片未準備好。
 
沿用 test_cdp_headless 增加 -NetworkDiagnosticsOnly（不開瀏覽器），驗證未知 HTTP 201 不會算成功、路徑去識別、query/header/body 不落盤、PUT 不取得授權、送出前請求不取得授權、序號排序；另重跑既有 loopback 傳送與防重送。備份與結果：D:\00058897\SendTeamsMsg_endpoint_backup_20261105_143042。teams_cdp 仍两檔，七段內嵌 JS 不變。包為 SendTeamsMsg_CDP_Compact_v8.zip；本版是診斷補強，實機傳輸根因仍待可辨識端點與收件結果。
 
### 2026-11-05 無視窗 Teams 載入與 CDP 逾時恢復（navigation1）
 
使用者的 13:59 排程在 chat_list 階段以 GetResult「已取消作業」結束，尚未貼圖。實機沒有記錄逾時指令，不能據此證實 headless 不支援或原機根因。程式已確認的缺口：單次指令固定 10 秒、Wait-E3HeadlessChat 吞掉所有例外、Socket 取消後可能 Aborted 而持續重用，以及 15 秒首頁 fallback 可能打斷已開始的聊天室選取。
 
Invoke-E3Cdp/Invoke-E3Js 新增可指定 TimeoutMs，預設仍 10 秒；啟動導航／載入探測採最多 30 秒，探測依 120 秒總期限剩餘時間縮短。錯誤含指令、send/receive 階段、時限及 socket 狀態，不記錄 JS 正文或 CDP 參數。Connect-E3Cdp 保留成功連接的本機 endpoint。Restore-E3NavigationConnection 限制原 /devtools/page/ 分頁且 E3SendNetwork 必須尚未啟動；不在貼圖或傳送階段自動重連／重送。
 
載入探測最多重連兩次；失去 Page.navigate 回覆時僅重連後檢查結果，不再重發導航指令。一般 JS 錯誤立即回報，僅明確的 execution-context 切換短暫重試。首頁 fallback 改為 45 秒且只有未觀察到 chat_list/select_chat/verify_chat_id/web_launcher 進度才可執行，保留原聊天 ID／帳號核對。啟動失敗在專案 logs/日期/startup_工作ID.json 保存 phase、error、lastCommand、Edge stderr 路徑及未貼圖／未送出旗標，再正常關閉本次 Edge。原登入、綁定與防重送資料不變，不改成有視窗模式，不假設無視窗已在正式租戶驗收。
 
沿用 test_cdp_navigation 重現真實 Chromium 回應逾時／.NET WebSocket Aborted、原分頁恢復、有限次重連、一般 JS 錯誤、傳送階段禁止恢復，並測 47 秒聊天載入不被首頁 fallback 打斷。test_cdp_startup_cleanup 加入啟動診斷／導航回覆遺失不重播檢查，另重跑 headless 伺服器確認與防重送套件。備份與結果在 D:\00058897\SendTeamsMsg_navigation_backup_20261105_140725。七段內嵌 JS 不變，teams_cdp 仍兩檔；更新包 SendTeamsMsg_CDP_Compact_v8.zip。所有傳送驗證僅限 loopback，未對真實 Teams 發送。
 
### 2026-11-05 傳送成功必須核對伺服器回應（serverack1）
 
使用者回報 Win+L 排程顯示 confirmed_new_row／已顯示新訊息，但手機完全無新訊息。此證據不足以判定原主機的傳輸根因；確認原收件判定只核對本機 DOM，沒有伺服器確認，因此補上 host 層必要條件。瀏覽器 runtime headless1 與七段內嵌 JS 不變。
 
Start-E3SendNetwork 在貼上前啟用被動 Network 事件觀察，before_click 才允許該次傳送的確認。僅信任 HTTPS Teams／msg.skype.com messaging host、綁定聊天室的 conversations/{chatId}/messages POST，需 HTTP 200/201、完成回應、非快取／Service Worker／redirect、有 response JSON id 或 Location resource id，且與本次 DOM id 或 request clientmessageid 相符。HTTP 202、單純本機新列、其他聊天室或無法辨識的 endpoint 都不能算成功。這是支援上述端點形態的保守核對，未宣稱涵蓋所有租戶 API 或收件端同步。
 
DOM 成功後最多再等待 45 秒伺服器確認，期間不按第二次送出、不關閉瀏覽器；取得伺服器確認後再讀一次 DOM 收件狀態，以免沿用等待前已過期的核對結果。總 host 時限 135 秒。沒有相符確認則 uncertain，所有 CDP 模式保留 blocked 狀態，不自動重送；核對收件與草稿後才能重新 BIND。登入／綁定／防重送資料仍在原 LOCALAPPDATA；新收據與無正文的網路摘要放在專案 logs/日期/receipts/工作ID.json，摘要只含 request 類別、HTTP status、ID、完成／快取／失敗旗標與錯誤碼，不保存 URL、header、cookie 或 request/response 正文。
 
沿用 test_cdp_headless 加入真實 loopback HTTP 201、延遲回應、本機假訊息列、HTTP 403、防重送，以及端點／ID／202／快取／redirect 單元檢查。測試與备份位於 D:\00058897\SendTeamsMsg_receipt_backup_20261105_134505。未對真實 Teams 傳送、未在此機器做 Win+L 驗收。最新包 SendTeamsMsg_CDP_Compact_v8.zip；teams_cdp 仍兩檔。
 
### 2026-11-05 診斷紀錄改放專案 logs（diagnostics2）
 
依使用者要求，Edge stdout/stderr 改存本專案 logs/日期；部署到其他磁碟或目錄時自動跟隨專案位置。沿用原檔名、錯誤顯示及瀏覽器流程；不移動或刪除舊紀錄與登入資料。既有 startup cleanup 測試增加紀錄位置檢查，並從不同工作目錄啟動子程序。更新包為 SendTeamsMsg_CDP_Compact_v8.zip。
 
# E3 系統每日監控自動截圖、警戒線判定與 Teams 自動通報系統 (`CLAUDE.md`)
### 2026-11-05 Edge 診斷輸出分離（diagnostics1）
 
Start-E3TestBrowser 的 Start-Process 同時指定 RedirectStandardError／RedirectStandardOutput。每次啟動使用時間＋GUID 的獨立檔案，放在專案目錄的 `logs/yyyy-MM-dd`；正式路徑為 `專案目錄\logs\日期`；以模組所在位置定位，不受 PowerShell 或排程的工作目錄影響。
 
原始 DevTools listening、EDGE_IDENTITY、fallback_task_provider 等診斷保留在 stderr.log，不混入主程式結果；stdout.log 亦保留。沒有使用停用登入、降低日誌等級或將所有錯誤丟棄的方式。這是輸出分離，不代表修復 Chromium 內部診斷所指的元件問題。主程式仍依既有帳號／聊天室／圖片／收據條件判定成功；啟動錯誤保留原原因及診斷目錄，Start-Process 失敗時亦正常處理尚未建立的 process。
 
Browser 回傳值增加 stderrLog／stdoutLog；啟動時印出紀錄位置。既有失敗與防重送判定、登入資料、七段內嵌 JS 都不變。此原始診斷目錄不會自動清理；不用提供或刪除 profile 才能查看紀錄。
 
沿用 test_cdp_startup_cleanup，增加子 PowerShell 的 stdout/stderr 隔離檢查：DevTools 訊息必須存在 Edge 檔案且不出現在主控台，CDP evaluate 正常；啟動失敗仍回報原原因、紀錄位置並清理本次瀏覽器。另重跑 loopback headless 四圖與防重送。備份與本次紀錄在 `D:\00058897\SendTeamsMsg_diagnostics_backup_20261105_110448`。維持 teams_cdp 兩檔、18 支既有測試；未改 UI，不重拍手冊截圖。部署包：SendTeamsMsg_CDP_Compact_v8.zip。

### 2026-11-05 預覽、登入後驗證與完整收件檢查（workflow1）
 
保持 teams_cdp 的兩檔結構，無新增正式模組或測試腳本。calibrator 的 getTeamsPreviewImage 取得目前 PNG 編碼大小；splitTeamsPreviewBatches 依 4 張／25 MiB 拆卡片，維持排程頁面順序、收件分組、總結與批次序號。缺圖或單張大於 10 MiB 顯示待確認提示；畫面明示依目前圖估算，實際排程的圖片、標記及失敗頁會改變批次。
 
Delivery.ps1 的 Get-E3ConfiguredRoutes 列出預設與啟用頁面／排程的覆寫名稱，以 Ordinal 去重，包含尚未綁定者。Set-E3CdpBinding 在 BIND 與空輸入框確認、儲存綁定後，關閉可見設定 Edge，持續持有 mutex，用 Test-E3CdpTargetReady 重啟 headless 核對登入／帳號／chatId／label／空輸入框。失敗明示綁定已保存且驗證未通過，不假報完成；常駐分頁模式不做 headless 重啟。
 
Test-E3CdpConnection 共用同一 Ready 檢查，逐項收集結果而不在第一個錯誤中止；缺綁定、草稿、對象不符、待核對阻擋均記錄具體原因。檢查不清除 pending 或啟動傳送。-PassThru 回傳 ok/results/lines；引擎保留完整 teams_detect.txt 並以 exit 1 表示任一失敗，設定 CLI 失敗亦 exit 1。兩種模式均檢查實際身分與草稿，分頁模式保留原瀏覽器。同步本機 API 仍等待完整檢查，UI 提示可能數分鐘。
 
沿用既有 test_cdp_headless_binding、test_cdp_headless、test_cdp_entry、test_cdp_integration；make_screenshots 加入五模式預覽、4/4/1、25 MiB、順序／對象覆寫與缺圖檢查，重拍 13 張手冊圖。測試使用替身或 loopback，不送真實 Teams。傳送 runtime 與七段內嵌 JS 維持 headless1。
 
最新版部署包：SendTeamsMsg_CDP_Compact_v2.zip。前版程式、文件與本次驗證在 D:\00058897\SendTeamsMsg_features_backup_20261105_103800；保留設定、圖檔、截圖／Teams profile 與傳送狀態。USER_MANUAL 更新 4-2 分批預覽、CDP 登入與檢查步驟、8-1 新版包名稱。
 
 
### 2026-11-05 CDP 檔案整合（compact1）
 
`teams_cdp` 從 12 個檔案縮成 2 個：`Delivery.ps1` 與 `README.md`。主引擎入口不變；原 Cdp.ps1、Headless.ps1 合併為 Delivery.ps1 內的 transport／lifecycle 區段，七份 JavaScript 以單引號 here-string 內嵌在 Get-E3CdpRuntimeSource，來源說明併入 README。原 `.js`／`vendor` 路徑只當內嵌區段識別，不再讀取外部分散檔案，也不於執行時展開產生新檔案。
 
僅改檔案載入方式；七段網頁腳本逐段比對一致（統一 CRLF/LF 後），保留帳號、chatId、標題、圖片／model ready／receipt 核對、取消與持久化防重送。runtime 保持 `2026-11-05-headless1`，不因 compact1 檔案整理而重綁。Delivery.ps1 使用 UTF-8 BOM，供 PowerShell 5.1 讀取；各 region 供維護定位。
 
五支原有 CDP 測試已改用同一內嵌來源函數，未新增測試腳本。重跑合併後的本機 headless 四圖、圖片缺漏／順序、背景焦點、綁定、取消／復原、啟動清理與真實引擎 DryRun。實際租戶與 Windows 鎖定驗收限制不變。
 
合併前模組、測試及文件在 `D:\00058897\SendTeamsMsg_compact_backup_20261105_102337`，驗證輸出也集中於該處。最新部署包為 `SendTeamsMsg_CDP_Compact.zip`；前一版 HeadlessFix 包移至該備份。部署時先正常停止排程與 CDP 設定、將舊 teams_cdp 移至備份，再放入新版兩個檔案；單純解壓覆蓋不會刪除旧分散檔案。根目錄 teams_delivery.ps1 仍必備；保留 config.json、sample_images、edge_profile、captures、logs 及 LOCALAPPDATA 的正式狀態。
 
以下檔名與目錄數量若屬歷史紀錄，請以上述 compact1 結構為準。
 
 
### 2026-11-05 測試檔案整理
 
已將 12 個過時項目（83 個檔案，約 5.11 MiB）移至專案外備份 `D:\00058897\SendTeamsMsg_cleanup_backup_20261105_101726`，未永久刪除。備份含逐檔 SHA-256 清單及整理前文件；需還原時依 manifest.csv 的相對路徑放回，勿覆蓋新版正式模組。
 
移出：未完成的 teams_bridge、第一階段 teams_cdp_probe、舊 teams_cdp_send_test、引用現版不存在 KPI 函數的 tools/test_kpi_capture.ps1、過時 tools/UNATTENDED_OPTIONS.md、五個舊驗證目錄（CDP probe、schedule recovery、schedule window、webhook、zoom），以及 LifecycleFix／BackgroundFix 兩個中間更新包。以下歷史記錄若引用這些路徑，內容已移至上述備份，不是現版執行步驟。
 
保留正式 teams_cdp 全部內容、最新 HeadlessFix 更新包、目前 CDP／擷取／縮放／排程回歸測試與其共用 fixture。保留 validation_cdp_send_20261104（現行測試仍寫入此目錄）、validation_cdp_background_20261105、validation_cdp_headless_20261105。tools/README.md 說明維護用途。config.json、sample_images、edge_profile、captures、logs 及 LOCALAPPDATA 正式 CDP 登入／綁定／收據／阻擋狀態不在清理範圍。
 
USER_MANUAL.html 的 8-1 已改為現版必備檔案與保留資料清單，修正舊版「只複製 4 個檔案」及將登入 profile 列為可清除項目的說明。本次未更動 UI、截圖或傳送邏輯，因此不重拍介面截圖；HeadlessFix.zip 保留原已發布內容。
 
 
### 2026-11-05 無視窗 Teams 排程與背景編輯器修正（headless1）
 
正式模組仍是 `teams_cdp`。採用 NEW 的排程自行啟動 headless Edge 概念，保留本專案的帳號、chatId、標題、圖片畫素／順序、model ready 與新訊息回讀核對；不以輸入框清空單獨判定成功。
 
- `teams.prefer_window = cdp` 才使用 CDP。新增 `teams.cdp_headless`，未設定視為 true；取消設定畫面的「使用無視窗 Edge 傳送」則使用舊版持續開啟分頁的模式。其他傳送模式不受此開關影響。
- `Headless.ps1` 管理本次啟動的 Edge；`navigation.js` 先用保存的 chatId 網頁連結，載入未完成時回 Teams 首頁，以保存的完整名稱選取對話，再由 adapter 嚴格核對實際帳號、chatId、標題。同名候選不唯一、ID 不符、登入過期或逾時皆停止。登入站台允許 20 秒自動 SSO 跳轉，不能代替互動登入或 MFA。
- 沿用 `%LOCALAPPDATA%\E3TeamsCdpSendTest\profile`，與截圖用 `edge_profile` 分開。每個收件對象啟動、傳送各批並正常關閉；舊分頁 targetId 不再限制 headless，持久化帳號與聊天室綁定仍有效。設定時開可見 Edge，人工核對後輸入 BIND，確認輸入框空白才儲存；headless 模式設定完成便關閉。
- 同一 profile 已被使用時停止，不搶用或關閉日常 Edge。正常結束使用 Browser.close 並等待 profile 程序退出，送出後不強制終止可能有草稿的瀏覽器。啟動失敗且尚未導向任何網站時，才清理本次建立的程序。
- 每次 headless runtime.start 前將工作 ID 與 receipt 路徑寫入 `blocked/<SHA256(accountId+換行+chatId)>.json`；只有 confirmed sent 才刪除。結果不明、貼上失败或程序中斷會保留，下一次排程在開瀏覽器前就停止；即使改回分頁模式也不能繞過。使用者核對收件與草稿後，重新 BIND 且確認空輸入框才能解除。此機制避免瀏覽器重啟遺失記憶體狀態而重送。
- 背景編輯器修正保留：Page active、Emulation focus、關閉背景節流、DOM composer focus、最長 30 秒等待整批圖片核對；不使用 Windows 剪貼簿、SendKeys 或前景視窗。每筆 receipt reset 帶工作 ID，避免 not_sent 搭配前筆 confirmed_new_row。診斷增加 failedChecks、圖片預期／實際／載入／驗證數、焦點與 visibility，不記錄聊天內容或 Cookie。
- `runtime.js` 與 Delivery 版本均為 `2026-11-05-headless1`。保留取消／逾時工作 recover、部分截圖成功仍通知、每批 4 圖／25 MiB。截图、縮放、捲動與裁切流程沿用。
- 驗證資料：`tools/validation_cdp_headless_20261105`。本機 loopback Edge 驗證登入 cookie 跨重啟、兩次四圖、錯誤帳號／標題／chatId、登入過期、結果不明持久阻擋；另測導航、啟動清理、綁定解除與 UI 開關。這些不代表真實租戶、MFA 或 Win+L 排程已驗收。
- 更新包 `SendTeamsMsg_CDP_HeadlessFix.zip` 不含使用者狀態；保留 `config.json`、`sample_images`、`edge_profile`、`%LOCALAPPDATA%\E3TeamsCdpSendTest`。更新時先檢查前次收件／草稿並正常關閉舊 CDP Edge；原綁定完整且登入有效可直接檢查 headless 連線，不需刪除 profile。
 
以下 2026-11-04 記錄為歷史；持續保持分頁、關閉後須重綁等要求只適用取消無視窗模式時。
 
 
> 2026-11-04 CDP 正式流程整合：使用者已確認測試 0.2 在桌機尚未解鎖時，手機收到圖片與文字；當時程式回報 uncertain。本次將背景傳送接入主程式與設定畫面，並新增訊息回讀核對。以下舊探針／獨立測試記錄保留作歷史；正式程式採 `teams_cdp`，不採未完成的 `teams_bridge`。本次整合與新版核對仍需使用者在實際主機驗收。
 
 
### CDP 整合維護說明（2026-11-04）
 
 
工作生命週期修正：實機四圖擷取成功但 reset 回 DELIVERY_STILL_ACTIVE，表示分頁內前一筆工作未終止。runtime `2026-11-04-lifecycle1` 提供工作 ID、到期時間、取消與 recover；僅已取消／逾時者可以要求結束，必須等待 finally finished 才 reset，未逾時工作不強制中斷。圖片解碼後再 check，避免取消後晚到的 Promise 繼續傳送。Host 在 start 呼叫前即標示可能已開始，回應遺失也會以工作 ID 嘗試取消並等 3 秒；清理失敗保留原因。新工作先 recover，前筆結果保存 recovered_ID.json，不自動重播。現有 runtime 同版時不再重新注入圖片／收據模組以免破壞活動狀態；舊版明確提示重綁。控制碼更新必須同步更換 runtime version 與 host 版本檢查。啟動 log 在目錄清理前有提示，等待 Local\E3MonitorNativeRun 前顯示最多 30 分鐘。測試：test_cdp_lifecycle、test_cdp_recovery，加上多圖／引擎入口回歸；真實主機待驗收。
 
 
各模式一致性更新：新增根目錄 `teams_delivery.ps1`，引擎與 CDP 都使用 Split-TeamsImageBatches／Get-TeamsBatchText。自動、PWA、Edge 分頁、桌面版與 CDP 都是每批最多 4 張、25 MiB，每批包含同一總結及失敗清單；多批加批次序號。部署必須帶此檔。原本逐頁擷取失敗繼續的流程保留，另補上缺檔、壞 PNG、過大图片與警戒線處理錯誤的逐頁隔離。失敗頁不附圖、明確列出頁名並要求檢查；全部失敗仍建立純文字通知。任一頁失敗 exit 1，不代表成功圖文沒有送出。單頁處理完成後才提交警戒線訊息，避免失敗頁留下部分警戒線結果。25 個真實引擎 -TestSample -NoSend 情境驗證五種模式之成功／缺檔／壞圖／分析錯誤／全部缺檔；未實際傳送 Teams。
 
 
多圖更新：CDP 改為每批最多 4 張、原始 PNG 合计 25 MiB，全部預檢後依序分批；單批原文不追加逐圖序號，多批追加批次序號。`item.images` 與 base64 陣列同順序，`BridgeOutgoingImages` 逐張 hash／畫素確認，單次 DataTransfer 放入多個 File；編輯器必須按順序包含全部圖，MAIN model 必須恰有預期數量且全部 success，才按一次送出。收據核對整批圖數、載入與比例。每批一份結果，uncertain 停止後續批次，不重送。保留舊單張 item.image 相容入口。這版多圖尚待實機 Teams 驗收，不以合成編輯器通過代表真實租戶支援多檔貼上。
 
 
發送總結改為「未完整完成」，不再將部分送達／核對不明描述為整個對話「沒有送出」。
 
 
> 收件核對修正：使用者正式 4 圖測試，手機收到前 2 張，第 2 張回報 matching_row_not_found 而中止。已確認為送出後核對未通過，尚無足夠實機診斷確認具體原因。receipt 不再因 DOM 節點在送出前已存在就排除新 message ID（相容虛擬清單重用）；仍排除舊 ID 並核對文字、時間、圖片與狀態。保留具體失敗原因，新增只含數量的 counts 診斷，不記錄聊天文字／圖片／Cookie。合成情境覆蓋節點重用成功及舊 ID 不得誤認新訊息；實際第二張原因需新版收據確認。
 
 
- 設定沿用 `teams.prefer_window`，新增 `cdp` 值；不引入已被清理的 `delivery_method`。未選 CDP 的設定仍走原桌面貼圖。更新包不得包含 config.json、sample_images、edge_profile 或本機登入資料。
 
- `e3_monitor_native.ps1 -CdpSetup` / `setup_cdp.bat` / `POST /api/cdp-setup` 啟動互動綁定。API 先儲存畫面設定，再開啟設定視窗。設定工具新增模式、綁定與連線檢查；CDP 的 DryRun 只查圖片與本機綁定，不貼圖。`-DetectTeams` 在 CDP 模式改查專用瀏覽器。
 
- `Send-GroupToTeams` 分派至 `teams_cdp/Delivery.ps1`；排程 CDP 跳過 `Wait-TeamsDesktop`。既有截圖、縮放、捲動、裁切、選頁與警戒線流程沿用。CDP 不使用系統剪貼簿、SendKeys 或前景視窗。
 
- 專用 profile 沿用 `%LOCALAPPDATA%\E3TeamsCdpSendTest\profile`。同目錄 session.json 固定本次瀏覽器端點 GUID，bindings.json 固定路由名稱、targetId、帳號、chatId、標題；不靠同名聊天室猜測。設定時核對後 BIND，支援本人與群組，每個對象一個專用分頁。「自己」不得綁定群組。
 
- 舊版分頁模式使用者必須保持已綁定 Edge 分頁開啟、停留於對應對話且登入有效；可鎖定 Windows，不可睡眠或登出。Edge／分頁關閉、重開機或更新控制碼後須重新綁定。排程不自動重建分頁或登入；不同 Windows 帳號不共用本機狀態。
 
- 先驗證全部 PNG，再每批最多 4 張圖片一起發送（合計最多 25 MiB）。單張最多 10 MiB、邊長 4096、1600 萬畫素。沒有圖片可傳純文字。Local mutex 防止同時綁定／發送；失敗或 uncertain 停止該對象後續批次，不重送。
 
- `receipt.js` 在 click 前保存舊訊息基準。編輯器維持既有 hash／畫素／model ready 核對；送出後再查新的穩定訊息 ID、文字、時間、附件載入與比例、編輯器清空，以及非等待／失敗狀態。即使原圖逐像素核對通過，也不得跳過狀態檢查。這是 DOM 回讀證據，不是伺服器送達 API；證據不足仍 uncertain。
 
- 紀錄在 `%LOCALAPPDATA%\E3TeamsCdpSendTest\receipts\日期\工作ID.json`，無自動保留期；日誌不存圖片或 Cookie。途中斷線可能只有最後 checkpoint，需人工查看 Teams 後再補送。舊版分頁模式的專用 Edge 不隨排程結束而關閉；結束控制連線並停止本次 rAF。
 
- 驗證：`tools/test_cdp_send.ps1` 使用本機假 Teams，測傳送、群組綁定、縮圖回讀、錯誤與等待狀態、帳號／對話變更及不重送；`test_cdp_integration.ps1` 測路由、PNG 預檢、逐圖／中止、設定保存；`test_cdp_entry.ps1` 測真實引擎 TestSample DryRun 分派。`make_screenshots.ps1` 已更新手冊 13 張截圖。這些不替代使用者的整合版鎖定多頁排程驗收。
 
 
> 2026-11-04 CDP 測試 0.2：使用者回報初次綁定 `ACCOUNT_MENU_NOT_OPEN`。改由 `Get-E3SelfBinding` 呼叫 isolated world 的 `beginBinding`，只點一次可唯一辨識的頭像；有界輪詢 10 秒讀取原 adapter 的嚴格帳號／本人對話證據，MAIN world rAF pulse 協助背景選單載入，finally 收起工具自行開啟的選單。使用者只需選好自己、回 PowerShell 按 Enter，不再要求手動保持帳號選單開啟。帳號未驗證時仍停止、不貼圖或送出；登入 profile、原程式、config 與排程不變。新增關閉選單重現、延遲選單成功、選單不出現與頭像缺失測試。
 
 
> 2026-11-04 第二階段：使用者桌機 Edge 155.0.4283.60 已回報 CDP 檢查 PASS 並可登入 Teams 網頁，Edge 86 不再納入此次目標。新增獨立 `teams_cdp_send_test/run_send_test.bat`，不接入原排程。專用固定 profile、驗證本人帳號及 19/48 thread、手動 SEND、立即／45 秒後鎖定模式、一張合成 PNG＋唯一編號文字；鎖定模式須先有 interactive 再轉 unavailable，貼上與 click 前持久化 checkpoint 並再檢查。CDP isolated world 沿用同事 adapter／圖片核對，MAIN world 處理有界 rAF 與 model ready，無擴充功能／SendKeys／系統剪貼簿／前景切換。未確認結果不重送；結果與診斷存 results。詳見包內 README.txt／SOURCE_NOTES.md。只有本機 fixture 驗證，真實 Teams 與鎖定送達等待使用者驗收；不將 earlier probe PASS 當作送達。
 
 
> 2026-11-04 CDP 可行性檢查：`teams_cdp_probe/run_check.bat` 是獨立第一階段工具；讀取 HKLM/HKCU 的 `RemoteDebuggingAllowed`，明確禁止即停止。使用 LOCALAPPDATA 下隨機 profile、回環位址及動態埠測試 CDP Runtime；一般模式再開 Teams 讓使用者手動確認登入，SelfTest 僅跑 about:blank 並以 Browser.close 關閉。輸出 `CDP_Result.txt`，不擷取聊天、憑證、不傳送訊息、不改 config/排程。PASS 不等於 Teams 網頁相容或鎖定送達通過；尚未整合 CDP 傳送。測試 profile 需使用者正常關閉後按需刪除。
 
 
> 2026-11-04：使用者要求先測試 Edge 擴充功能可否安裝，再繼續背景傳送開發。`teams_extension_probe` 是獨立、唯讀安裝探針，宣告預計需要的六項權限與兩個 Teams 網站範圍；只讀取權限及 Teams 分頁數量。`teams_bridge` 目前是未完成草稿，尚未接入引擎／設定工具，不可視為可部署版本。安裝探針通過不等於 Native Messaging、背景控制或鎖定送達通過。
 
 
 
 
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
 
   - **降低背景節流影響**：擷取流程使用 CDP 頁面啟用等操作及背景節流參數；Teams CDP 另使用頁面啟用與焦點模擬。這些處理不保證分頁整晚不休眠，長時間鎖定與整機睡眠需依目前操作建議另行驗證。
 
   - **使用已開啟、已登入的 Teams 發送**（2026-11-02 起；取代舊的 `msteams:` ChatID 跳轉與 `edge_teams_web` CDP 貼上）：支援 **Teams 應用程式 (PWA)**、**Edge 分頁** (`teams.cloud.microsoft`) 與 **桌面版 Teams**，不需另外登入。以 UI Automation 在聊天清單點選「對話名稱」，**確認視窗標題的對話名稱完全相同**後才以剪貼簿貼上，任何確認失敗即停止（詳見 3.3）。
 
   - **Teams 圖片上限保護**：遵循單則訊息最多 **4 張圖片**（單張 `<= 10 MiB`、合計 `<= 25 MiB`）限制，若啟用超過 4 張圖片會自動以 4 張為一批分批送出，並預留圖片模型上傳緩衝時間。
 
 
 
 
---
 
 
 
 
## 2. 專案目錄與檔案結構（`<專案資料夾>\`）
 
 
 
 
> 路徑不限：程式一律以 `$PSScriptRoot` / `%~dp0` 定位，所有檔案放同一資料夾即可。開發機為 `C:\SendTeamsMsg\`，手冊範例沿用 `C:\TEST\`。
 
 
```text
 
<專案資料夾>\
 
├── CLAUDE.md                  # 專案架構與開發維護紀錄文件 (本檔案)
 
├── USER_MANUAL.html           # 使用者手冊 (截圖已內嵌、Teams 示意圖、測試檢查清單)；設定工具右上「📖 使用手冊」可開啟
 
├── tools\                     # 只供維護：make_screenshots.ps1、_demo_config.json、test_remembered_zoom.ps1 等回歸腳本；部署時不需要
 
├── config.json                # 核心設定檔 (多時段排程 schedules、登入資訊、Teams 目標連結、各頁面與警戒線規則)
 
├── calibrator.html            # 視覺化設定工具 (三分頁：頁面與警戒線 / 排程與發送 / 全域設定，右側依排程預覽 Teams 訊息)
 
├── e3_monitor_native.ps1      # 【主執行引擎，唯一程式】截圖、像素分析、Teams 發送、排程註冊；-Calibrator = 設定工具本機服務 (127.0.0.1:8765)：
 
│                              #   /api/config, /api/save, /api/capture-url, /api/capture-status, /api/save-sample, /api/delete-sample, /api/test-teams[?schedule=id&send=1],
 
│                              #   /api/register-schedules, /api/schedule-status, /api/login-setup, /api/teams-detect
 
├── open_calibrator.bat        # 【唯一需要雙擊的檔案】執行 e3_monitor_native.ps1 -Calibrator 並自動開啟 calibrator.html
 
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
 
   - **互動捲動擷取（2026-11-03）**：`Set-CaptureViewport -FitWindow` 最大化專用視窗、讀取實際可視尺寸，依縮放計算 CSS viewport 並套用顯示 scale，讓捲軸可操作，不再以大於實際視窗的固定範圍操作。登入、Zabbix now/7d 完成後，`Get-JsCaptureControls` 注入獨立 Shadow DOM 的「擷取目前畫面／取消」面板；按鈕先移除面板，`Wait-InteractiveCapture` 再取得選擇。**縮放防呆（2026-11-04 修正）**：原本把 Edge 先前記住的網站／預設縮放直接判成使用者本次手動縮放（例如設定 80%、Edge 原生 80%，DPR=0.64），導致一開面板就不能擷取。現在先由 `Set-CaptureViewport` 補償既有縮放，再以 `devicePixelRatio` 與 `zoom/100` 比對；只有套用後比例再變動才阻擋，面板提示「擷取期間網頁縮放已變更…請按「取消」後重新抓圖」。`Save-RenderedPage` 的 `Assert-NoManualZoom` 使用相同判定。
 
   - **設定 `pages[].capture_view = {width,height,x,y,zoom}`**：width/height 為可視範圍 CSS 像素，x/y 為主文件 scrollX/scrollY，zoom 為選擇時的百分比。排程每頁使用已存尺寸，載入及時間調整後 `Restore-CaptureScroll` 還原位置並等待該頁 wait_seconds，再核對尺寸與位置。無法還原或縮放已改但尚未重新抓圖時此頁失敗（見 3.1 第 4 點），避免默默擷取其他位置。crop_region 與警戒線均以可視來源 PNG 為基準。位置變更後前端重置裁切為整張並提示確認警戒線。
 
   - 互動預覽引擎透過 `<OutFile>.json` 回傳 capture_view 給本機 API，API 隨圖片回傳前端後刪除中繼資料。CLI 未帶 `-InteractiveCapture` 仍自動擷取完整主文件。公司開發環境的 `tools\test_interactive_capture.ps1`（未納入此 repo）使用隔離的長報表測試按鈕、兩軸捲動、100%/150% 排程重現逐像素裁切、取消及不可到達位置阻擋。
 
   - **每頁縮放與座標系（2026-11-04）**：`pages[].browser_zoom` 為 50～200 整數百分比，省略預設 100。`Set-CaptureViewport` 清除舊 Emulation 後讀取原生 DPR（啟動固定 `--force-device-scale-factor=1`），以 `deviceScaleFactor=factor/nativeZoom`、viewport 尺寸乘 `nativeZoom` 成對補償；互動顯示 scale 同樣使用補償值，pageScaleFactor=1。導航／登入後在目標頁重新套用，再等待圖表載入。重播讀回實際 CSS 尺寸，最多微調三次以處理 Chromium 整數取整與 DPR 浮點誤差；最終仍由 `Restore-CaptureScroll` 嚴格核對。互動抓圖以當時實際視窗為基準，排程以 capture_view 保存的 CSS 尺寸為準；無 capture_view 的舊設定才使用 1920×1080 基準擷取完整文件。完整文件模式以 `cssContentSize` 驗證輸出像素上限、`contentSize`（DIP）設定 CDP clip，避免原生縮放造成多餘空白或截短。`crop_region` 是來源 PNG 整數像素，不直接當成 CDP clip；超界或非整數時此頁失敗、不輸出該圖。
 
   - **100% 時右側／下方留白修正（2026-11-04）**：上一版僅驗證 `fromSurface=true` 的 PNG，漏掉 Edge 真正顯示區被 `Emulation.setDeviceMetricsOverride` 同步縮小的問題；原生 80%＋設定 100% 時，PNG 約 1912×956，但顯示區只有 1530×765，造成大片留白與操作面板被裁切。最初僅在 `Set-CaptureViewport -FitWindow` 加入 `dontSetVisibleSize=true`，解決互動抓圖。後續修正正式排程：兩種模式皆最大化 Edge，首次 override 與重播尺寸微調皆使用 `dontSetVisibleSize=true`、`scale=factor/nativeZoom`，保留實際視窗內容區。排程的 CSS 尺寸與捲動位置仍使用 capture_view，PNG 的比例、嚴格還原核對與裁切邏輯不變。換電腦或螢幕環境後仍應重新抓圖，不能保證舊電腦保存的尺寸剛好符合新視窗。
 
   - **排程視窗驗證（2026-11-04）**：`tools\test_zoom_range.ps1` 現在於新 Edge 重播並擷取後，另外檢查 `fromSurface=false` 的真實視窗尺寸、右／下固定色塊及內容邊緣，取樣排除隨比例變大的原生捲軸；不能用 `fromSurface=true` 的 PNG 正確推論視窗也正確。此項修正的測試、版本雜湊與結果見 `tools\validation_schedule_window_20261104\README.md`；下列 486 筆是前一版的驗證，當時尚未檢查排程視窗。
 
   - **50%～200% 全範圍驗證（2026-11-04）**：新增 `tools\test_zoom_range.ps1`、`tools\test_zoom_schedule.ps1` 與共用 `ZoomPixels.cs`。範圍測試涵蓋全部 151 個整數比例；可視 Edge 測試檢查實際顯示區、右側／下方定位色塊、雙軸滾輪與滑鼠按鈕擷取。保存設定後關閉 Edge、重新讀入 JSON 並開啟新瀏覽器，比對整張 PNG 與右下角 300×200 裁切的每個像素。另以隔離副本與 loopback 網站執行真正的 `-Schedule zoom_check -NoSend`，將 11 個快捷比例交錯排列，驗證排程選頁、導航、縮放、位置還原及裁切。`-Headless` 補充測試只驗證擷取與重播，不算實際視窗／滑鼠檢查；可視滑鼠測試應依序執行，避免視窗互相遮擋。最終通過 173 筆實際視窗情境、302 筆 headless 補充重播及 11 筆 CLI 排程情境（共 486 筆）；完整結果與各模式範圍見 `tools\validation_zoom_20261104\README.md`；這是本機靜態測試網頁驗證，公司網站資料與版面仍需實機驗收。
 
   - **`-PreviewCapture -PageId <id> -Url <url> -OutFile <png> [-PreviewZoom <50..200>] [-PreviewWaitSeconds <1..60>]`**：截單一頁完整文件（crop 停用），共用 `Capture-PagesNative` 的登入、防凍結、縮放、時間調整與整頁擷取。新增參數為當次預覽覆寫，省略沿用設定檔；與排程共用 Mutex（等 10 秒），錯誤寫入 `logs\preview_last.txt`。
 
   - 公司開發環境的 `tools\test_capture_zoom.ps1`（未納入此 repo）使用暫存 profile 與離線 HTML，驗證多頁縮放、原始元素尺寸、完整頁高、視窗下方裁切與 calibrator 實際函數逐像素一致、捲動座標及非法範圍阻擋。不使用正式設定或 Teams。


3. **Zabbix 截圖前自動調整最近七天（2026-11-03）**：
 
   - `Capture-PagesNative` 在登入與載入等待之後、`Page.captureScreenshot` 之前呼叫 `Set-ZabbixRecentWeek`。網址路徑為 `screens.php` / `charts.php` 時啟用，其他報表維持原流程。`-PreviewCapture`、正式排程與真實網頁 `-NoSend` / `-DryRun` 共用此流程；`-TestSample` 不開網頁，不調整時間。
 
   - 依專案附帶的網站快取確認 `timeControl.timeline`、`CScrollBar.dom.right`（`navigateRight`）及 `#scrollbar_cntr .zoom a[zoom="604800"]`（`setZoom`）；透過 `Get-JsZabbixTimeStep` 執行 DOM 點擊，不依賴滑鼠座標。先重複點右側按鈕至 `timeline.now()` 與時間標籤 `(now)` / `(now!)` 同時成立，再點上方 Zoom 7d。下方導覽列的 7d 是移動時間，不可使用。已符合時間條件就略過點擊。
 
   - 每次輪詢重新取得元件，可處理 AJAX 更新及整頁重載；點擊用 `setTimeout` 延後，讓 CDP 先回覆。等待 `flickerfreeScreen` 無刷新、重試或載入錯誤，圖表圖片載入成功，時間標籤相差 604800 秒且與 timeline 一致，圖片 URL 的 `period=604800`，若有 `isNow` 則必須為 1。符合後持續觀察至少 `wait_seconds`（最少 1 秒）才截圖。
 
   - 每頁時間調整最多 180 秒、120 次點擊。點擊後時間沒有變化 15 秒，或元件版本不支援、時間／圖表無法確認時 `throw`，此頁失敗（不送圖，訊息中標示原因），不將舊區間當成正常結果。詳細原因寫在原有 log / `preview_last.txt`。
 
   - 公司開發環境的 `tools\test_zabbix_time.ps1`（未納入此 repo）以暫存 Edge profile 與 loopback 模擬網站測試，不讀正式 config、不連監控網站、不操作 Teams。涵蓋歷史時間、已在 now、已是 7d、AJAX 延遲與整頁重載、錯誤 7d 元件、缺少元件／不支援介面、舊圖片、刷新卡住、點擊無效、其他報表略過，以及整合截圖成功／失敗前阻擋。公司 Zabbix 實機驗證仍需部署後進行。
 
 
 
 
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
 
 
 
 
1. **Workflow／Webhook 已移除（2026-11-04）**：回復操作 Teams 視窗（桌面版／PWA／Edge 分頁）；移除 HTTP 發送分支、網址欄位與專用測試腳本。儲存 API 與瀏覽器載入會清除舊版 delivery_method、webhook_targets、webhook_url，避免舊設定重新帶入網址。保留縮放與擷取位置、喚醒／補跑及解鎖等待功能。雲端流程須由使用者另行關閉／刪除。先前文字送達 Workflows 私訊，圖片遭公司代理禁止；歷史測試不代表現版功能。替代方案與官方文件見 tools/UNATTENDED_OPTIONS.md。 本機 teams_webhook.txt 刪除被工具政策拒絕，檔案仍在但不再被程式使用；雲端流程也尚未刪除。移除後 9 項恢復／設定清理測試、4 個比例的排程像素比對與 12 張手冊截圖通過；測試需先 Import-Module ScheduledTasks 再設定替身，避免自動載入覆蓋，診斷時建立的暫存任務已清除。
 
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
 
   - 公司開發環境的 `tools\test_teams_chat.ps1`（未納入此 repo）透過 AST 載入實際函數，完成 42 項離線檢查，包含中文／英文清單前綴、PWA 未讀標題、自己與具名個人對話、特殊字元、從其他群組切到目標、已在目標不重複點擊、相似名稱／錯誤標題／缺少目標的阻擋。UIA 與 Win32 使用記憶體替身，不操作真實 Teams、不發訊息；公司 PWA 修正版切換仍需部署後確認。
 
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
 
 
 
 
### 3.4 設定工具版面 (`calibrator.html`)
 
- 左欄分三個分頁（記在 `localStorage` 的 `e3_calibrator_tab`）：
 
  - **📄 頁面與警戒線**：擷取頁面清單、此頁面設定（擷取範圍數值與載入等待秒數收在「進階」；沒有「處理模式」與「單頁發送對象」欄位）、警戒線清單與編輯（名稱、訊息；座標、紅線高度、顏色、💧 取色收在「進階」）。表單下方顯示「實際發送對象（來源）」與會改送他處的排程。
 
  - **📅 排程與發送**：預設「Teams 對話名稱」（**📨 先傳給自己測試** 寫入 `自己`；舊設定的 `48:notes` 連結輸入框顯示為 `自己`，預覽顯示「👤 自己（個人對話）」；填連結 / Email 時顯示 ⚠️ 並阻擋 🚀）、「使用哪個 Teams」(`teams.prefer_window`：空白 = 自動 / `pwa` / `edge-tab` / `desktop`)、**🔍 偵測 Teams 視窗**（`/api/teams-detect`，結果顯示在下方 `#detectTeamsResult`）、排程時段卡片（收合成一行，含「下次執行時間 / ⚠️ 未寫入」；id 自動產生）、同步狀態列與 🔄 重新套用、訊息文字。
 
- **自動儲存**（無 💾 按鈕）：`autoSaveTick()` 每秒比對 `JSON.stringify(config)`，有變動就 `/api/save`（拖曳中不存）；右上角 `#autoSaveStatus` 顯示狀態。只有從 `/api/config` 成功讀入設定時才啟用（`autoSaveEnabled`），避免以 localStorage 舊資料覆蓋 config.json。存檔前 `normalizePageModes()` 依警戒線同步 `mode`。
 
- **自動同步排程**：`scheduleSignature()` = 各排程 `[id, taskName, enabled, time, days]`；有變動時改呼叫 `/api/register-schedules`（同時存檔並註冊 / 移除 Windows 任務）。名称變動會重新註冊；標題、發送對象、頁面變動只存檔。開啟時不自動註冊，而是以 `/api/schedule-status`（依 action 路徑辨識本專案任務 + `NextRunTime`）顯示「✅ 已同步 / ⚠️ N 個尚未寫入」，由使用者按 🔄 重新套用。
 
- **畫布只有兩種模式**：`currentTool` = `crop`（✂️ 擷取範圍）或 `rule`（📏 警戒線），`pick_color` 為一次性取色。📏 模式 `hitTestRules()`：選取中警戒線的紅線 ±6px → 拖曳調高度（游標 ↕，兩端有把手）；框內 → 選取並拖曳移動（紅線跟著移）；空白處拖曳超過 4px → `addRule()` 新增（紅線預設 35% 高度），單擊不新增。
 
- `tools\make_screenshots.ps1` 每張截圖前先設 `autoSaveEnabled = false`，避免示範環境寫回設定或自動註冊 Windows 排程。
 
  - **⚙️ 全域設定**：🔐 手動登入監控網站、自動按 Enter（「名稱搜尋切換對話」已移除，現在一律以名稱 + 標題確認）。
 
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
 
- **警戒線框或高度無效**：`evaluateRule()` 回傳 `outOfRange`，不判為正常。引擎將該條列為監控失敗、保留該頁截圖並通知（exit 1）；僅異常模式也必須發送提醒，其他頁繼續處理。
 
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
 
   - `id`：英數字 / `_` / `-`，作為固定的 `-Schedule <id>` 執行參數；Windows 任務名稱使用 name。
 
   - `days`：空陣列 = 每天；或填 `MON`~`SUN` 指定星期。
 
   - `pages`：依清單順序截圖與貼圖；頁面本身 `enabled=false` 時一律略過。
 
   - `target_chat_name`（選填）：Teams 對話名稱或 `自己`（見 3.3）。發送對象優先順序 **排程 > 頁面 > `teams.target_chat_name`**。設定工具已不提供「頁面」層級欄位（只剩預設與排程）；引擎與預覽仍相容舊設定中的 `pages[].target_chat_name`。
 
   - `title`（選填）：加在 Teams 訊息最前面，用來區分不同時段。
 
   - 舊版只有 `schedule_time` 的 config 仍可用：自動視為一個 `daily` 排程（包含全部頁面）。
 
2. **執行參數**（`e3_monitor_native.ps1`）：
 
   - `-Schedule <id>`：只跑該排程的頁面；不帶則跑全部啟用頁面。
 
   - `-RegisterSchedules`：依 config 註冊/更新每個啟用排程，並移除已刪除/停用且 action 可確認屬於此專案與 config 的任務；舊名稱可遷移為排程名稱。以目前使用者「僅登入時執行 (Interactive)」註冊，不保存 Windows 密碼、不切換 SYSTEM。任務設定：`WakeToRun` 要求喚醒、`StartWhenAvailable` 錯過後補跑、電池模式也執行、上限 2 小時、`IgnoreNew` 不重複啟動；不加整次任務自動失敗重試，以免部分成功後重送。更新失敗時保留原任務並回報失敗。喚醒受硬體、供電、公司電源政策限制，無法保證關機／睡眠期間準時執行。
 
   - `-ListSchedules`：列出排程與頁面。
 
3. **企業環境防護**：
 
   - **鎖定／遠端斷線恢復測試版（2026-11-04）**：`Get-DesktopBlockReason` 以 WTS 目前工作階段狀態與 input desktop 名稱判斷，未知狀態視為不可操作。正式 `-Schedule` 發現桌面不可用時呼叫 `Capture-PagesNative -Headless`，仍使用原 profile、已保存的 CSS viewport、縮放、捲動與裁切；互動抓圖不允許 headless。發送前 `Wait-TeamsDesktop` 每 5 秒檢查、每分鐘記錄，共用第一次等待起算的 30 分鐘截止時間，恢復後發送已保存的圖。逾時 exit 1，圖仍保留；不是永久佇列，程序被結束後不會自動補送。貼圖途中桌面失效時停止、不重試整批，須檢查草稿與已送訊息。
 
   - 排程持有執行 Mutex 後要求 `ES_CONTINUOUS | ES_SYSTEM_REQUIRED`，在 finally 解除，降低執行期間自動睡眠；不禁用鎖定、不改電源計畫、不繞過遠端／公司安全政策，不能阻止手動睡眠、登出或斷電。
 
   - `/api/schedule-status` 回傳 `wake`／`catch_up`，介面遇到舊任務提示「尚未套用喚醒／補跑設定」，使用者需按「🔄 重新套用」更新 Windows 任務。只更新檔案不會自動改動已註冊的任務設定。離線行為測試 `tools/test_schedule_recovery.ps1` 使用虛擬時鐘及註冊替身，不真的鎖定、睡眠、註冊任務或發訊息；`tools/test_zoom_schedule.ps1 -WindowPreview` 驗證可視預覽 → 模擬斷線 → 真正排程入口的背景擷取。詳見 `tools/validation_schedule_recovery_20261104/README.md`；實際遠端軟體、主機喚醒與 Teams 恢復貼圖待使用者驗收。
 
   - 具名 Mutex `Local\E3MonitorNativeRun`：兩個排程時間重疊時依序執行（共用 `edge_profile`、Teams 視窗與剪貼簿），最多等 30 分鐘。
 
   - **Edge 正常關閉（2026-11-03）**：截圖流程在 `finally` 透過既有 CDP 連線由 `Close-CaptureBrowser` 送出 `Browser.close`（送出上限 3 秒，不等關閉回覆），等 2 秒後釋放連線，再執行 `Stop-ProfileEdge`。後者只處理命令列含本專案 `edge_profile` 的程序，先要求關閉視窗、最多等 5 秒，逾時才強制清理並記錄警告；不影響日常 Edge（包含 Teams PWA / Teams 分頁）。舊版每次截圖後直接 `Stop-Process -Force`，造成 profile 記錄 `exit_type: Crashed`，下次啟動彈出「還原頁面：Microsoft Edge 意外關閉」。截圖啟動參數加入 `--hide-crash-restore-bubble` 抑制前次異常退出提示，不修改既有登入資料。已用隔離的暫存 profile 連續兩次執行本機 `about:blank` 截圖，均產生 PNG 且退出狀態為 `Normal`；公司主機待驗證。
 
   - `Wait-CdpTargets`：輪詢 CDP 埠最多 20 秒（防毒掃描導致 Edge 啟動慢）。
 
   - `Start-Transcript` 寫入 `logs\`，背景排程無視窗時可追查。
 
   - **截圖保留 7 天（2026-11-03）**：每次主流程執行（排程、`-TestSample` 等）在 transcript 開始後，刪除 `captures\` 下名稱為 `yyyy-MM-dd` 且日期早於「今天 − `$CaptureKeepDays`(7) 天」的資料夾（依名稱日期，不看修改時間；第 7 天當天保留；非日期名稱的資料夾與檔案不動）。舊版從不清理，每次排程新增一個資料夾。已用沙盒實測：0/3/7/8/30 天前的資料夾只刪除 8 與 30 天前。
 
 
 
 
---
 
 
 
 
### 3.6 精簡部署（開發機只放必要檔案）
 
- **目前必備檔案**：`open_calibrator.bat`、`calibrator.html`、`e3_monitor_native.ps1`、`teams_delivery.ps1`、`teams_self_test.ps1`、`teams_self_test.js`、`config.json`；CDP 另需 `teams_cdp/Delivery.ps1` 與 `setup_cdp.bat`；共用 `work_control.ps1`／`work_control.js`、`numeric_monitor.ps1`；手機 @日管 遙控另需 `teams_receiver.ps1`、`teams_receiver_commands.ps1`、`teams_receiver_capture.ps1`、`teams_receiver_watchdog.ps1`、`teams_cdp/receiver-snapshot.js` 與 `setup_／start_／test_teams_receiver.bat`、`register_receiver_watchdog.bat`。路徑不限 `C:\TEST`（腳本皆以 `$PSScriptRoot` / `%~dp0` 定位），但需放在同一資料夾。2026-11-01 已移除 `server.ps1`（併入 `-Calibrator`）、`login_setup.bat`（→ 設定工具 🔐 按鈕）、`test_to_my_teams.bat`（→ 🧪 / 🚀 按鈕）、`register_schedule.bat`（→ 自動同步 / 🔄 重新套用）、`run_daily.bat`（Windows 排程直接呼叫主程式；手動補跑用 `schtasks /Run`）。
 
- **自動產生、不需複製**：`edge_profile\`、`captures\`、`logs\`、`sample_images\`（📸 抓圖後重建）。
 
- **選用**：`USER_MANUAL.html`（📖 手冊，圖片已內嵌）、`sample_data.js`（缺檔時 `window.SAMPLE_IMAGES` 為空，calibrator 照常運作；但 `tools\make_screenshots.ps1` 需要它）、`CLAUDE.md`、`tools\`（只供維護）。
 
- **檔案編碼（2026-11-03 修復）**：`e3_monitor_native.ps1` 必須是 **UTF-8 with BOM**（PowerShell 5.1 沒有 BOM 時以系統代碼頁 950 讀取，中文字串會造成上百個解析錯誤，整支程式無法執行）；其餘檔案 UTF-8 無 BOM 即可。不可含 U+00A0（不換行空白）：瀏覽器 `JSON.parse` 不接受 config.json 中的 NBSP，CSS 選擇器帶 NBSP 會整條失效。程式中的零寬字元一律以 regex 跳脫（``、``）表示，不要放實際字元。曾因以複製貼上（Teams / Outlook / 網頁）在公司與開發機之間傳檔而三者同時發生；請以附件或 zip 傳檔。
 
- **`.bat` 檔只能用 ASCII（英文）**：cmd 以系統代碼頁 (950) 讀批次檔，`chcp 65001` 之後的中文行會被錯位解析，與下一行黏在一起（症狀：「'亂碼…powershell' 不是內部或外部命令」）。中文說明一律寫在 PowerShell 腳本或手冊裡。
 
- **新增檔案時**：若執行時必須存在，需同步更新本節、手冊「8-1 必備與可刪除的檔案」，以及主程式 `-Calibrator` 區塊的靜態檔白名單（若需由瀏覽器載入）。
 
- Windows Server 可執行截圖與判斷；UI Automation／剪貼簿操作 Teams 仍需登入且解鎖。CDP 模式需依本文件最新驗證範圍另行驗收，不能由本機結果推論 Windows Server 可用。未安裝 Teams 桌面程式可用 Edge Teams 網頁版（公司允許登入時）；一般聊天網址不是上傳端點。Bot／Graph 或專用無人值守 RPA 需公司核准與另行整合，不能保證不受資安政策限制。
 
 
 
 
## 4. 常用維護與操作流程
 
 
 
 
> 完整的使用者操作步驟（含測試發送到自己的 Teams、新增網頁擷取範圍與警戒線、測試檢查清單）請見 **`USER_MANUAL.html`**；本節只列重點。
 
 
 
 
1. **開啟設定工具**：雙擊 `open_calibrator.bat`（自動開啟瀏覽器；所有修改自動儲存）。
 
2. **首次綁定網站登入狀態**：設定工具 ⚙️ 全域設定 → 🔐 登入監控網站，在彈出的 Edge 登入後關閉即可保存至 `edge_profile\`。
 
3. **測試發送到自己的 Teams**：先開好並登入 Teams（PWA / Edge 分頁 / 桌面版）→ 📅 排程與發送 → 📨 先傳給自己測試 → 🔍 偵測 Teams 視窗 → 右欄 🧪 測試貼上（不送出）/ 🚀 正式送出…。
 
4. **排程**：在「📅 排程與發送」新增 / 修改時段，自動同步到 Windows（第一次使用按 🔄 重新套用）。手動補跑：`schtasks /Run /TN "排程名稱"`，或 `powershell -File e3_monitor_native.ps1 -Schedule <id>`。
 
5. **執行紀錄**：`logs\`。
 
 
 
 
---
 
 
 
 
## 5. 已知限制
 
 
 
 
1. **網頁版面隨縮放與內容變化**：互動抓圖保存主文件 viewport 與 scroll，排程還原它們；舊設定沿用整頁流程。更改縮放、網址或版面後須重新抓圖並框選、確認警戒線（不自動平移 ROI）。不保存 iframe／表格內部獨立捲軸，也不重演任意點擊與延遲載入流程，建議使用報表直接網址。請在頁面資料載入後按擷取；互動期間重新整理／跳轉會停止，需重新抓圖。圖片上限單邊 16384 像素、總計 6400 萬像素。
 
2. **📸 抓圖會短暫開啟 Edge 視窗**（非 headless），排程在桌面不可用時則以 headless 共用擷取流程。兩者都會關閉其他使用 `edge_profile` 的 Edge（例如未關閉的 🔐 登入用視窗）。
 
3. **`-TestSample` 使用 `sample_images\<pageId>.png`**，缺檔的頁面會略過；該檔由 calibrator 在 📸 抓圖 / 框選後自動產生，從未抓圖的頁面才會缺檔。
 
4. **非 CDP 的 UI Automation／剪貼簿發送需互動桌面**：以下限制適用 PWA、一般 Edge 分頁及桌面版原有視窗貼圖流程，不適用於已實測的保留視窗 CDP。此類流程在鎖定時即使 Teams 還在執行，也不能貼圖。排程會先背景擷取、等待桌面恢復（最多 30 分鐘），逾時失敗；一般手動測試及貼圖途中鎖定會停止。等待恢復的圖片是當次擷取資料，可能晚於原排程時間送到；系統睡眠期間沒有程式在執行，恢復後補跑取得的是恢復當時的網頁資料。不能保證所有電源／登入狀態下即時發送。執行期間會佔用系統剪貼簿、拉到前景及操作滑鼠。Teams 改版仍可能影響 UI Automation 定位，需依偵測紀錄調整。
 
5. **PWA 實測範圍**：使用者提供的 2026-11-03 公司執行紀錄已確認可辨識 PWA、切到前景，且先前已有貼圖送出成功紀錄。15:27 回報從其他群組切換時失敗，本次修正聊天清單前綴與 `(1)` 未讀標題；修正版跨對話切換尚待公司驗證。PWA 仍依「msedge 視窗、標題含 Microsoft Teams、不以 Microsoft Edge 結尾」判斷，若標題格式再變動，依 `-DetectTeams` 的原始標題調整。
 
6. **以名稱找對話**：名稱必須與 Teams 顯示的完全一致（群組改名要同步修改）；沒有命名的群組，聊天清單與標題顯示的成員名單可能不同而無法確認。聊天清單最多往下捲 10 頁。
 
7. **網頁登入帳密（包含 pages[].auth）以明文**存在 `config.json` 與瀏覽器 `localStorage`（`e3_monitor_config_v1`）。
 
8. **自動登入的範圍**：各頁使用 `pages[].auth` 的 enabled／username／password；只有缺少 auth 的舊頁面沿用全域 `auth`。停用不會回退全域帳密，也不登出已保存的登入；只認文字完全等於 Login / Log in / Sign in / 登入 的按鈕（其他字樣如「Login with SSO」不會點）；Login 後若進到 SSO / MFA 等沒有密碼框的頁面無法自動登入，需改用 🔐 登入監控網站。允許訪客瀏覽、但頁面上有 Sign in 連結的網站，設定帳密後也會被登入一次（無害）。
 
9. **Edge 異常關閉提示**：正常截圖已改為正常關閉；若電腦斷電、外部強制結束或關閉逾時，仍可能留下異常退出狀態。抑制還原提示參數是否生效受 Edge 版本影響；若仍出現提示，先確認執行主機已更新腳本，再查看 log 是否有「專用 Edge 關閉逾時」。不要為此刪除登入 profile。
 
10. **翻譯提示停用範圍**：啟動參數只控制專用瀏覽器內建翻譯，網站自行提供的語言選擇視窗不在此範圍。若更新主程式並重新開啟專用瀏覽器後仍有內建翻譯提示，需依實際 Edge 版本確認參數支援。
 
11. **Zabbix 時間控制版本**：最近七天自動調整目前支援帶 `timeControl` / `scrollbar_cntr` 的舊版 `screens.php` / `charts.php` 圖表頁，且確認英文 `(now)` / `(now!)` 標籤。新版 Zabbix、其他語系、包在 iframe 或不同網址路徑的頁面需另外適配；上述兩種路徑若無支援的元件會判定此頁失敗，不會猜測按鈕。網站改版、圖表 URL 無法確認時間或時間過於久遠超出操作上限時也是此頁失敗。
 
12. **專用 Edge 縮放（2026-11-04）**：先前記住的網站縮放與非 100% 預設縮放會在本次 CDP 渲染中自動補償，不再要求 Ctrl+0 或修改 `Preferences`，不清除登入資料。擷取面板開啟後請勿再按 Ctrl＋滾輪／加減號；偵測比例變動時會阻擋，請取消並重新抓圖。更改網站縮放或從舊版本更新後，建議重新抓圖、確認擷取範圍與警戒線；若舊的可視尺寸在新環境無法精確還原，仍停止該頁並提示重新抓圖。`tools\test_remembered_zoom.ps1` 使用隔離 Edge profile 的原生 80%／100%／125% 縮放，驗證設定 50%／67%／80%／100%／125%／200% 的實際擷取按鈕、圖片比例、雙軸捲動及排程裁切逐像素一致，也涵蓋未含 `capture_view` 的完整文件擷取尺寸與比例；另以模擬 DPR 變動檢查面板／引擎阻擋與取消。以 loopback 網站額外驗證完整 `Capture-PagesNative` 80% 抓圖、關閉瀏覽器後排程重播的裁切像素一致。公司 Zabbix 實機仍待確認。

---

# CLAUDE.md 清理前完整內容（2026-11-12 封存）

> 2026-11-12 依使用者要求清理根目錄 CLAUDE.md：移除事件經過、改版前後比較、日期註記、測試項數與已過時的待辦，只保留目前的架構、規則與限制。以下為清理前的完整原文，供追查當時的原因與驗證範圍；不會在每次對話自動載入。

## E3 監控自動截圖、警戒線判定與 Teams 通報（開發者文件）

本檔記錄**目前**的架構、設定格式與必須遵守的規則。最後整理：2026-11-12。

---

### 1. 必守規則

#### 1.1 文件同步
- 任何修改都要在同一次變更中更新兩份文件：**`USER_MANUAL.html`**（給使用者：操作步驟、按鈕名稱、畫面文字、批次檔、注意事項、FAQ，並更新開頭「最後更新」日期）與 **本檔**（給開發者：架構、設定格式、原理、限制）。完成後回報兩份各改了哪些段落。
- 改了 `calibrator.html` 的按鈕／欄位／文字：更新手冊對應步驟，並執行 `tools\make_screenshots.ps1` 重拍截圖。**手冊截圖一律以專案目前的 `config.json` 與 `sample_images\`（使用者在公司主機實際擷取的圖片）為準**，不另造示範設定；手冊文字中的範例名稱（頁面、排程 id／名稱、`@日管` 指令）也對應目前設定。工具只讀 config：網站帳號與密碼（全域與每頁 `auth`）都改成遮罩、移除空白收件項目後交給頁面；不啟動正式設定服務、不載入 `e3_monitor_native.ps1`。以獨立暫存 profile 啟動 headless Edge（`--remote-debugging-port=0` 隨機除錯埠，不需關閉正式設定工具），用 CDP `Fetch` 攔截頁面所有請求並由記憶體回應（不會連到真正的 8765），只回應 GET，POST 等一律 403；頁面載入時以 `addScriptToEvaluateOnNewDocument` 在 `autoSaveEnabled` 變成 true 的當下關閉自動儲存／自動辨識並停用 `scheduleSampleSave`。數值門檻以 `numeric_monitor.ps1` 的 `Measure-E3NumericRule` 對 `<id>_full.png` 依 crop 裁切後試算，結果注入 `numericCache`；排程同步、CDP 綁定／檢查、手機遙控狀態為依目前設定產生的示範狀態（手冊圖說需註明）。頁面挑選依規則類型自動找（數值規則頁、像素規則頁、有裁切的頁），設定改變時圖說要重新核對。13 張截圖全部完成且與手冊 `data-shot` 完全一致後，才以暫存檔＋`File.Replace` 原子替換 `<!-- MANUAL_IMAGES_BEGIN -->`～`END` 區塊（base64）；暫存目錄 `%TEMP%\e3_manual_shots_<時間>` 保留原手冊與 PNG 供檢查。**不可手動編輯圖片資料、不要整檔輸出手冊**。新增／改名截圖時同步修改 `Shot` 清單與 `<img data-shot="...">`。
- 手冊中的 Teams 畫面、確認視窗、log 是 HTML 示意（`.mock`／`.dialog`／`.log`），文字改變要同步。
- 不為每次更新另建 README；操作說明集中在手冊與本檔。

#### 1.2 檔案編碼與傳檔
- 所有 `.ps1` 必須是 **UTF-8 with BOM**（PowerShell 5.1 無 BOM 會以 cp950 讀取，中文造成大量解析錯誤）。其他檔案 UTF-8 無 BOM 即可。
- 任何檔案都**不可含 U+00A0（NBSP）**：瀏覽器 `JSON.parse` 不接受、CSS 選擇器／屬性名會失效、PowerShell 無 BOM 時無法解析。零寬字元在程式中一律寫成 regex 跳脫（`\u200B` 等），不放實際字元。
- `.bat` 只能用 **ASCII + CRLF**；中文訊息寫在 PowerShell 腳本或手冊。
- 在公司／測試機與開發機之間傳檔要用 **zip 或附件**，不可經 Teams／Outlook／網頁複製貼上（曾造成 NBSP 縮排、BOM 遺失、整行截斷）。2026-11-11 帶回的版本再次發生：`teams_receiver.ps1`、`teams_cdp\Delivery.ps1` 與兩個測試腳本遺失 BOM 且含 NBSP，`receiver-snapshot.js`、本檔、手冊與歷史檔含 NBSP，手冊第 8 章、附錄開頭、圖片區塊與前半段腳本被截斷；已修復。2026-11-12 帶回的 `teams_cdp\Delivery.ps1`、`teams_receiver.ps1` 又遺失 BOM 且行首縮排含 NBSP（無法解析），本檔也含 NBSP；未截斷，已改回空格並補 BOM。收到檔案後先掃描 NBSP／BOM 並以 PowerShell Parser 解析全部 `.ps1`。
- 新增執行時必備的檔案：同步更新本檔第 3 節、手冊「8-1 程式檔與狀態資料」；若需由瀏覽器載入，加入 `-Calibrator` 的靜態檔白名單。

#### 1.3 行為原則
- **零外掛**：只用 Windows 內建 PowerShell 5.1、.NET Framework 4.x（System.Drawing、WinForms、ClientWebSocket、UIAutomation、`Add-Type` 編譯 user32／kernel32 呼叫）與系統 Edge 的 CDP。不需 Python、pip、WebDriver、Edge 擴充、改登錄檔。
- **不自動重送**：任何傳送結果不明（uncertain）、逾時或中斷，都保留紀錄並停止，不補送、不把不明改成成功。新工作只送本次內容，不讀取或續送舊工作。
- **失敗要說得出原因**（2026-11-12 使用者要求）：手機端看不到主機視窗與 log，回覆不可只寫「請查看本機紀錄」。失敗原因要寫進回覆或另一則**純文字說明**，並留在紀錄檔。說明是關於失敗的新訊息，不是重送：不含原回覆內容與圖片、每個指令最多一則、每個管道最多嘗試一次，文字必須依階段說清楚「可能已送出／確定沒送出」，不可把不明說成失敗或成功。指令本身仍不重做。
- **不猜測**：對話、帳號、頁面、刻度、按鈕都要能唯一辨識；辨識不到或有歧義就停止並說明原因。
- 測試一律用隔離資料（暫存 profile、loopback 網站、替身傳送邊界、隔離 mutex），**不對真實 Teams 發訊息、不註冊或刪除正式 Windows 任務、不改正式 config**，除非使用者明確要求。回報時清楚區分「本機驗證」與「待目標主機實測」。
- `config.json` 含監控網站帳密明文，**不可 commit 到 git**（目前已在版本控制中，需處理）。

---

### 2. 專案目標
企業內網中，每天定時以專用 Edge 開啟多個監控網頁（Zabbix 圖表、報表等），擷取指定區域，判定警戒線或左 Y 軸數值是否超標，將截圖與總結文字送到指定 Teams 對話。另提供手機在 Teams 輸入 `@日管 …` 遙控主機即時截圖回傳。

---

### 3. 檔案結構

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
| `setup_cdp.bat` | 設定 CDP 收件對象（`-CdpSetup`） |
| `teams_receiver.ps1` | 手機 `@日管` 指令接收端（單一工作分頁輪流讀取、回覆、心跳、防睡眠、自動復原、程序內重新開始；`-Stop` 要求停止） |
| `teams_receiver_commands.ps1` | 指令解析（問法辨識、名稱建議）、擷取／檢查工作分派與回覆組成 |
| `teams_receiver_queries.ps1` | 唯讀查詢：排程結果（含主機 log 錯誤行）、主機狀況、網站連線測試 |
| `teams_receiver_capture.ps1` | 擷取子工作（由主程式 `-ReceiverCaptureJob` 載入；`analyze` 時另做判定） |
| `teams_receiver_watchdog.ps1` | 接收端監看與 Windows 任務註冊（由主程式 `-ReceiverWatchdog` 等載入） |
| `teams_cdp\receiver-snapshot.js`、`teams_cdp\receiver-switch.js` | 接收端網頁腳本（執行時讀檔）：讀取最新指令；在同一分頁切換到綁定對話 |
| `setup_teams_receiver.bat`／`start_teams_receiver.bat`／`stop_teams_receiver.bat`／`test_teams_receiver.bat` | 綁定接收對話／持續接收／要求停止／單次測試 |
| `register_receiver_watchdog.bat` | 註冊「E3 日管接收監看」與「E3 日管接收端」兩個 Windows 任務 |
| `config.json` | 設定（含帳密） |
| `USER_MANUAL.html` | 使用手冊（截圖內嵌） |
| `tools\` | 維護與隔離驗證：`check_files.ps1`（程式檔損壞檢查，見下）、`make_screenshots.ps1`（手冊截圖，見 1.1）、`test_cdp_image_preflight.ps1`（接收端圖片預檢）、`test_receiver_latest.ps1`（接收端最新訊息讀取）、`test_receiver_single_tab.ps1`（單一工作分頁、監看、通知佇列）、`test_receiver_failure_notice.ps1`（失敗原因、說明訊息、狀態回覆、監看歷史與代發）、`test_receiver_queries.ps1`（問法辨識、名稱建議、檢查回覆、排程結果、主機、連線、共用判定與擷取工作端到端） |

`tools\check_files.ps1`（2026-11-12）：唯讀掃描專案內 `.ps1／.js／.json／.bat／.html／.md`（略過 `.` 開頭的資料夾、`logs`、`captures`、`edge_profile`、`sample_images`），回報必備檔缺少、`.ps1` 缺 BOM 或無法解析（以 UTF-8 內容交給 Parser，BOM 另外回報）、NBSP／零寬字元／非 UTF-8、`.bat` 非 ASCII 或 LF 換行、`.json` 無法解析、`.html` 結尾不是 `</html>`。程式類檔案（ps1／js／json／bat）的問題為 error（exit 1），html／md 的 NBSP 等為提醒。`-PassThru` 回傳物件（file／level／message）不輸出文字。**這個檔案刻意只用 ASCII**（中文訊息寫成 `\uXXXX` 經 `[regex]::Unescape`，旁邊有英文註解）：傳檔把所有 BOM 弄掉時，含中文的檢查工具自己也會壞。修改訊息時要把非 ASCII 字元轉成跳脫。必備檔清單 `$required` 要與本節同步。接收端 `-Listen` 啟動時（載入 `Delivery.ps1` 之前）若有這個檔就先執行，有 error 即列出檔名與原因、不啟動；持續模式另寫一筆 `fatal` 心跳（stopReason「程式檔損壞…」），監看會帶著原因通知且不重啟。`start_teams_receiver.bat` 在接收端以錯誤結束後也會執行一次，涵蓋 `teams_receiver.ps1` 自己壞掉、連檢查都跑不到的情況。此檔不存在時略過，不影響啟動。

專案狀態：同機更新保留 `config.json`、`sample_images\`（每頁 `<id>_full.png`、`<id>.png`、`annotated_<id>.png`）與 `logs\`（收據、待核對、去重與工作紀錄，不可當成一般 log 全刪）。設定與校正圖片可備份／帶往新機，但需重新抓圖驗證；不在 config 的頁面圖於服務啟動時刪除，sample_images 不可放其他圖片。`edge_profile\` 是監控網站登入，同機通常保留；可刪後重建但必須重新登入，不直接跨機搬加密登入。`captures\` 是排程截圖，日期資料夾保留 7 天；一般主程式 log 保留 30 天，不代表所有 logs 子目錄採同一清理規則。

本機狀態（不在專案內）：`%LOCALAPPDATA%\E3TeamsCdpSendTest`（排程／測試的 CDP 登入 profile、`bindings.json`、`session.json`）、`%LOCALAPPDATA%\E3TeamsCommandReceiver`（接收端的 Teams 登入與綁定）。更新程式可保留，不需清除；若使用者決定重設，先停止相關工作與專用 Edge，之後分別重新登入／綁定。新機需重新設定，不能直接搬登入資料就假設可用。

`logs` 結構：`logs\<日期>\receipts\`（CDP 收據）、`logs\<日期>\startup_*.json`（啟動失敗診斷）、`logs\teams_cdp\blocked|review`（待核對／封存紀錄）、`logs\self_tests\<id>\`、`logs\work_control\`、`logs\teams_detect\`、`logs\schedule_results\<排程id>.json`（每個排程最近一輪的傳送結果，只保留最新一份，供監看判斷是否送達）、`logs\teams_receiver\`（接收端，見第 11 節）：`heartbeat.json`、`status.json`、`commands\<key>.json`（指令紀錄，含結果與失敗原因）、`outbox\`（待送通知）、`*_last.txt`（監看各項檢查的最新結果）、`<日期>\receiver_console_<時分秒>_<pid>.log`（接收視窗內容的副本）、`<日期>\receiver_events.log`（接收端逐筆事件，含時間）、`<日期>\watchdog_history.log`（監看結果有變化時一行）、`<日期>\receipts\`、`captures\<日期>\`。

---

### 4. 主程式參數（`e3_monitor_native.ps1`）
- 一般：`-ConfigPath`（預設同資料夾 config.json）、`-Schedule <id>`（只跑該排程；不帶則全部啟用頁面）、`-ListSchedules`、`-RegisterSchedules`、`-TestSample`（用 sample_images 不開網頁）、`-NoSend`、`-DryRun`。
- 設定工具：`-Calibrator [-Port 8765] [-NoBrowser]`、`-LoginMode`（開專用 Edge 手動登入監控網站）、`-PreviewCapture -PageId -Url -OutFile [-PreviewZoom 50..200] [-PreviewWaitSeconds 1..60] [-InteractiveCapture]`。
- Teams：`-DetectTeams [-DetectJobId]`、`-CdpSetup`。
- 內部工作（由服務或接收端啟動）：`-SelfTestJob`、`-SelfScheduleJob`、`-ReceiverCaptureJob <資料夾>`。
- 接收端監看：`-ReceiverWatchdog`、`-RegisterReceiverWatchdog`、`-UnregisterReceiverWatchdog`。`-ReceiverWatchdog` 依序執行四項，各自 try/catch、互不中斷：①排程傳送結果（只讀檔案與任務狀態）②接收端心跳與自動重啟③指令失敗說明代發④排程登入預警。只讀的放最前面：後面的步驟會開 Edge／傳訊息並各有硬期限（逾時直接結束程序），而 Windows 任務上限 10 分鐘。
- config.json 格式錯誤時：`-Calibrator` 仍啟動（網頁顯示錯誤），其他模式 exit 1。

---

### 5. 設定格式（config.json）

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

### 6. 擷取與判定

**共用判定 `Invoke-E3PageAnalysis $page $imgPath [$label]`**（2026-11-12 由主流程抽出，排程與 `@日管 檢查` 共用）：驗證 PNG（大小、格式、邊長／畫素），沒有啟用規則或 `capture_only` 回 `captureOnly`；否則依 6.2／6.3 逐條判定、寫 `annotated_<檔名>`，回傳 `alerts`／`failures`（排程訊息原文不變）、`hasAlert`、`annotated` 與結構化 `rules`（name、mode、status＝normal／exceeded／unknown、數值規則的 maximum／below／threshold／detail／reason、像素規則的 hits）。圖片無效時丟例外，由呼叫端回報。函式定義在 `Test-CurvePixel` 之後、各模式分派之前，`-ReceiverCaptureJob` 也能使用。抽出時以舊版與新版主程式對兩個排程跑 `-TestSample -NoSend`，判定輸出與標示圖雜湊相同。

#### 6.1 擷取（`Capture-PagesNative`）
- 專用 profile `edge_profile\`，啟動參數含 `--remote-debugging-port`、`--disable-features=Translate,msEdgeTranslate`、`--hide-crash-restore-bubble`、`--force-device-scale-factor=1`、背景節流停用。截圖結束先 `Browser.close` 正常關閉，逾時才強制結束同 profile 程序；不影響日常 Edge。
- 啟動前 `Reset-CaptureProfileZoom`：只清空專用 profile Preferences 內的縮放 map（原子取代、其餘位元組保留），避免 Edge 記住的縮放改變表格排版。
- **登入三層**：持久 profile／Windows 整合驗證 → 偵測密碼框（`PASSWORD`）填帳密送出，或只有文字完全等於 Login／Log in／Sign in／登入 的按鈕（`LOGIN_BUTTON`）時點擊後等密碼框 → 送出後重開原網址，仍是登入頁即**此頁失敗**。未設定帳密且有密碼框也失敗。SSO／MFA 需用 🔐 手動登入。
- **頁面載入檢查**：`Page.navigate` 的 errorText、`chrome-error://`／`edge-error://`、非 http(s)、HTTP 4xx/5xx 皆此頁失敗。CDP 指令預設 60 秒逾時；連線中斷時開新分頁重連後繼續下一頁。
- **Zabbix 時間**：`screens.php`／`charts.php` 以 DOM 點擊時間列右箭頭至 NOW，再點上方 Zoom（7d=604800／3d=259200）；核對 timeline、`(now)` 標籤、圖片 URL period／isNow 與載入穩定後才截圖；最多 180 秒／120 次點擊，無法確認即此頁失敗，不回退舊區間。
- **可視範圍重播**：互動抓圖時最大化視窗、讀實際 CSS 可視尺寸並保存 `capture_view`；排程以 `dontSetVisibleSize=true` 套用相同 CSS 尺寸與 `scale=factor/nativeZoom` 補償原生縮放，還原捲動並嚴格核對（最多微調三次），不符即此頁失敗。截圖前 `Clear-CaptureHover`（有視窗時移開實體滑鼠＋CDP mouseMoved 移出，等 1 秒）。截 `fromSurface=true` 可視內容，先存 `_full.png` 再用 `crop_region` 裁切。互動抓圖期間偵測到使用者改縮放會阻擋。
- **桌面不可用**（鎖定、RDP 斷線）或全域 CDP 且 `cdp_headless` 不為 false 時，正式排程與「執行排程傳給自己」以 headless 擷取，不移動實體滑鼠；手動抓圖一律有視窗。
- 每頁獨立 try/catch，失敗原因記入 `Failures`，其他頁照常；失敗頁不附圖並在訊息列出原因，exit 1。

#### 6.2 警戒線（像素）
- 每條規則 `roi` + 水平線 `threshold_y`；`roi.y ≤ y ≤ threshold_y` 範圍內曲線像素數 ≥ `min_pixels` 即超標。`color_mode=auto` 排除灰白背景與 Zabbix 粉紅日期虛線；`custom` 以 RGB 距離 ≤ `color_tolerance` 比對 `target_color`。
- 規則框或線超出圖片／尺寸無效：列為監控失敗並保留截圖，不視為正常。超標訊息空白時補頁名／規則名。

#### 6.3 數值門檻（`numeric_monitor.ps1`）
- 依 `AvailableRecognizerLanguages` 選擇已安裝的 Windows OCR（優先英文，其次中文），不自動安裝。刻度區依序以 4／6／5／3／8 倍二值化、再以同樣倍率灰階辨識（`Get-E3VerifiedAxisFit`），一取得兩次一致的線性比例就停止；O/o→0、I/l/i→1。至少兩次辨識得到一致的線性比例才採用。
- **OCR 容錯（2026-11-12）**：自建的刻度表由水平墨跡列排成，Windows OCR 對它回報的 ±1～3° `TextAngle` 是雜訊（實測讀對全部數字時也回報 -2.2°），不再因角度丟棄整次結果，只寫 Verbose。某一列沒有被前後綴完整包住時只略過該列（`Read-E3OcrContext` 回 null），不讓同一次的其他列一起作廢。刻度列位置由 `Get-E3AxisBands`（純幾何、不 OCR）取得。以實際 Zabbix 字形拼成的 0～4／6／7／9／14／18／35 刻度與兩張實際樣本驗證；舊版在 0～6 重現「刻度文字辨識不完整」。
- 先嚴格擬合；失敗時 `-AllowInteriorOutliers` 以可讀的上下界建立比例，需 ≥6 個可讀刻度且 75% 位置誤差 ≤1.5 px，排除的讀值記在 `ignored_ticks`。不補造上下界、不沿用上次刻度。
- **框內沒有藍線**：只有在可證明時才判為正常：刻度已確認、框上緣不低於左軸最上方刻度列（`Get-E3AxisBands` 第一列 +1.5 px，Zabbix 曲線不會高於此處）、框下緣換算值不高於門檻、且整張圖仍找得到指定藍色（圖例或曲線，避免取錯色被當成正常）。此時 `status=normal`、`maximum=$null`、`below`＝框下緣數值、`peak_x/peak_y=$null`（標註圖不畫峰值圓圈），detail「框內沒有藍色曲線（貼近底部），最高值低於約 N」。任一條件不符仍 unknown 並說明要怎麼調整框或取色。
- 取 ROI 內指定藍色連通區最高點換算數值，嚴格大於門檻才超標。峰頂被框裁切、超出刻度範圍、辨識矛盾、落在誤差範圍內皆 `unknown`（列入失敗並提醒，含 alert_only）。綠線、右軸、框外曲線不納入。支援負數、小數、千分位、K/M/G/T、百分比；不支援對數軸。
- 設定頁 `/api/numeric-preview` 只試算不寫設定；正式排程每張圖重新 OCR，不讀預覽快取。

---

### 7. 排程
- `-RegisterSchedules`（設定頁自動同步／🔄 重新套用）以目前使用者 Interactive／Limited 註冊根目錄任務，名稱＝排程名稱；`WakeToRun`、`StartWhenAvailable`、電池可執行、上限 2 小時、`IgnoreNew`；PowerShell 以 `-WindowStyle Hidden` 執行。
- 任務所有權由**單一 action 的 PowerShell、完整 script 與 config 路徑、`-Schedule <id>`** 判定（`Get-E3OwnedTaskId`），不看名稱前綴；解析其他應用的異常路徑時視為非本專案。改名先停用舊任務、註冊新名、成功後移除舊任務；註冊失敗恢復原狀；舊任務執行中拒絕改名。
- `repeat`：觸發器加 Repetition（間隔、時段長度減 1 秒、`StopAtDurationEnd=false`）。結束時刻不再啟動；結束早於開始代表跨日。主流程取得執行權後以 `Test-E3RepeatWindow` 再檢查時段，過時補跑或已停用就略過。
- 設定頁以 `/api/schedule-status` 回讀實際觸發器（時間、星期、重複、啟用、喚醒／補跑）比對 `scheduleSignature`，只有核對通過才顯示已同步；開啟設定頁不自動註冊。
- 執行時：以 `Enter-E3WorkLock` 取得 `Local\E3MonitorNativeRun`（capture 資源）排他，忙碌時最多等 180 秒並可在設定頁選擇（見第 10 節），逾時本輪不執行；執行期間 `SetThreadExecutionState(ES_CONTINUOUS|ES_SYSTEM_REQUIRED)`；每個 worker 有 `Start-E3RunDeadline` 10 分鐘硬期限（.NET Timer，逾時 exit 124、寫 `.deadline.json`，不執行 finally、不重送）。
- 每輪正式排程寫 `logs\schedule_results\<id>.json`；沒送達時由監看任務經接收端通知（第 11 節「排程傳送結果通知」）。
- `alert_only=true` 且整個排程無超標也無失敗時不發送（截圖保留）；任一頁異常則依原收件分組發送全部可用截圖。不記錄前次告警、不發恢復通知。
- 非 CDP 模式在桌面鎖定時等待解鎖最多 30 秒（同一次執行共用截止時間），逾時失敗、截圖保留。

---

### 8. Teams 傳送

#### 8.1 共用規則（`teams_delivery.ps1`）
- 每批最多 4 張圖、原始 PNG 合計 ≤25 MiB；單張 ≤10 MiB、邊長 ≤4096、≤1600 萬畫素。多批時文字加批次序號；全空文字可只傳圖片；無圖無文字拒絕。
- 主流程逐收件對象 try/catch：一個對話失敗只記錄並繼續下一個，exit 1。發送對象仍是佔位文字時略過並 exit 1。

#### 8.2 視窗模式（PWA／Edge 分頁／桌面版，UI Automation）
- 找已開啟、已登入的 Teams；在聊天清單以名稱點選，視窗標題的對話名稱必須**完全相同**（容許聊天類型前的 `(數字)` 未讀數；自己＝名稱以 `(您)`／`(You)` 結尾）。
- 開始前輸入框有草稿就停止；`Clear-E3TeamsUiDraft` 只在核對對話／焦點後 Ctrl+A、Backspace（最多三次／15 秒）。剪貼簿逐張貼圖、確認出現後貼文字，每次貼上與 Enter 前再核對前景與標題，被切走即停止。需解鎖桌面，佔用剪貼簿與前景。

#### 8.3 CDP 模式（`teams_cdp\Delivery.ps1`）
- **最初空白分頁也受保護**：`Start-E3TestBrowser` 的初始 CDP 連接使用 `Connect-E3CdpPageContext -InitialBlank`，只接受新程序原本的 `about:blank` 分頁；與稍後 Teams 初始化共用相同識別核對、20 秒指令上限、60 秒階段期限及最多兩次恢復。端點就緒等待與分頁初始化各有自己的期限，並非整段啟動合計 60 秒。已導航離開空白頁不會被當成可繼續的啟動，仍停止，不自動重新導航。
- **送出前分頁連線（connect1）**：`Connect-E3CdpPageContext` 將本機端點識別、連接、Page.enable／active、焦點模擬、frame／isolated world 建立及唯讀 runtime 探測放在受限恢復範圍；單次 CDP 上限 20 秒、共用總期限 60 秒，暫時 HTTP／CDP 逾時或 context 失效最多重連兩次，每次核對同一 browser ID、target ID、Teams URL 與本機 WebSocket 路徑。原瀏覽器／分頁消失、登入頁、識別不符及非暫時錯誤立即停止。傳送觀察器存在時禁止初始化恢復；注入 runtime、停止舊工作、帳號選單核對、貼上及送出均不在重試範圍。`logs\<日期>\connect_<id>.json` 保存嘗試階段、耗時與 lastCommand，不記錄 HTTP 正文。`tools\test_cdp_connection.ps1` 以隔離 about:blank Edge、替身 Teams URL／帳號邊界與注入故障驗證恢復與保護條件。
- **傳送完成與中斷紀錄**：本批已取得相符伺服器及穩定畫面證據後，圖片 probe 的 stop 失敗只警告，不將成功重分類為失敗；仍需後續批次各自成功。若傳送連線中斷，連取消都失敗，保留原收據 checkpoint 並另寫 `<收據>.interrupted.json`（uncertain、lastCommand、network）；不重連、不重送。`tools\test_cdp_delivery_failures.ps1` 使用隔離 mutex 及替身傳送／收據驗證成功清理失敗、uncertain 與取消失敗；不代表真實 Teams 收件驗收。
- **Edge 啟動診斷（edge-startup1）**：新程序的 `Wait-E3DevToolsEndpoint` 使用總等待 60 秒、單次本機 HTTP 5 秒，標頭與內容共用單次期限且受剩餘總時間限制；就緒立即繼續。接收端重連現有程序仍保留 3 秒檢查，一般 `Get-E3LocalJson` 的 1.5 秒未改。`logs\<日期>\startup_edge_<id>.json` 記錄成功／失敗階段、各階段耗時、端點嘗試次數與錯誤階段／類型、清理前程序是否已退出及退出碼；不記錄 HTTP 內容或瀏覽器 URL，原始 Edge 輸出仍須明確開啟。失敗訊息附診斷路徑，診斷寫入失敗不使成功啟動變失敗。保留原本清理行為，不新增自動重啟／重送。`tools\test_cdp_startup.ps1` 使用本機 TCP 替身及隔離 headless Edge 驗證慢回應、總期限、端點識別、程序退出與診斷。依本次使用者指示，開發期間暫緩同步使用者手冊。
- **圖片組件**：`Send-GroupToTeamsCdp` 有圖片時，在 PNG 驗證前以 `Add-Type -AssemblyName System.Drawing -ErrorAction Stop` 載入內建組件。接收端為獨立 PowerShell 程序，不能依賴主程式或截圖子程序預先載入 `Drawing.Bitmap`。純文字不載入此組件；圖片驗證失敗仍在貼上／傳送之前停止。
- **綁定**：`-CdpSetup`／設定頁「設定 CDP 收件對象」開專用 Edge（`E3TeamsCdpSendTest\profile`）。`Select-E3BindingRoutes` 列出 config 中所有收件名稱與「已綁定／尚未綁定」，可輸入多個編號（逗號分隔，依輸入順序）或 `A`（依序設定全部尚未綁定者）；同一次設定逐一處理：無視窗模式在同一分頁切換對話，分頁模式每個對象開新分頁（`Open-E3BindingTab`）。每個對象選好對話後由 `Get-E3SelfBinding` 嚴格讀出 accountId／chatId／label（讀不到可重試）、輸入 BIND 並確認輸入框空白才寫 `bindings.json`；輸入 S 或非 BIND 即略過該對象且原綁定不變。全部略過時回報未儲存。無視窗模式最後關閉設定 Edge，以 `Test-E3CdpRoutesReady` 用一個背景 Edge 依序驗證本次儲存的對象。每個收件名稱各自綁定；「自己」只能綁本人對話。`Resolve-E3CdpTarget` 先找完全相同的 route；找不到且名稱是「自己」的任一寫法（自己／self／48:notes 連結）時，才接受唯一一個 route 也是「自己」寫法且 `binding.isSelf=true` 的綁定，讓舊連結名稱的綁定在 config 改存成「自己」後仍可用。profile 被占用時詢問是否關閉重開（輸入 Y）。
- **無視窗（`cdp_headless` 預設 true）**：每次傳送以 headless 啟動專用 Edge，先清理同 profile 遺留的 headless 程序，以 chatId 深層連結（失敗時以完整名稱唯一選取）開啟對話，核對帳號／chatId／label 後傳送，結束正常關閉。
- **保留視窗（`cdp_headless=false`）**：使用綁定時的專用 Edge 分頁（`session.json` 的 browserUrl + `targetId`），Edge 或分頁關閉後需重新綁定（接收端例外，見第 11 節）。
- **傳送流程**：共用 mutex `Local\E3TeamsCdpShared`（`Enter-E3WorkLock`，忙碌最多等 180 秒）；取得後重讀綁定；停止上一個 runtime、清除舊文字／圖片／附件草稿（`Clear-E3HeadlessDraftForNewDelivery`）；本次入口只處理新內容，不讀取、續送或自動封存舊工作紀錄。每批新工作 ID；貼圖後核對每張圖的 hash／畫素、CKEditor model ready、文字（忽略整段結尾的空白）、帳號與對話；送出前重讀聊天紀錄（`preSend`）；按一次送出。
- **成功判定**：DOM 出現相符的新訊息列（文字、時間、圖片數與比例、非等待／失敗狀態）**且**觀察到相符的伺服器回應（Teams messaging 端點的 POST 200/201，ID 對應；含 Dedicated Worker 的網路請求），穩定 1.5 秒以上（最多 12 秒）。否則 `uncertain`，保留 `logs\teams_cdp\blocked`，不自動重送。emoji 圖片正文只讀明確標記的 Unicode alt。
- **伺服器確認後的最終核對（2026-11-12）**：`Get-E3ServerReceipt` 成功時另回傳該 POST 的 `clientId`。最終核對接受的訊息 ID 為 runtime 結果 ID、相符請求的 serverId 或 clientId（同一個 POST 證明是同一則訊息；Teams 可能先以 client ID 顯示再換成 server ID）；其他 ID 仍為 terminal → uncertain。ID 改變時穩定計時重新開始。`finalReceiptHistory` 每筆加 `idRelation`（same／server_id／client_id／other／none），原因或關係改變時記錄。基本等待 12 秒；只要出現 `image_count_or_loading_mismatch`／`image_shape_mismatch`，等待延長到伺服器確認後 45 秒（仍受每批 135 秒期限限制），只讀取、不重貼不重送。背景：公司主機 11/12 10:00 收據為 confirmed_new_row 卻 uncertain（符合 ID 改變），18:00 為 image_shape_mismatch；兩份收據尚未帶回核對，屬推論。runtime／receipt.js 未改，版本不變。
- **本機 /json 讀取（2026-11-12）**：`Get-E3LocalJson`（`Get-E3CdpSession`、接收端分頁清單、檢查用 `Open-E3HeadlessChat`）由 1.5 秒改為 5 秒，逾時／連線失敗等暫時錯誤重讀一次（間隔 500 ms），只接受 127.0.0.1／localhost。原因：公司主機 Edge 本機 HTTP 曾超過 1.5 秒（14:00 GetResponse 逾時），而接收端回覆與登入檢查仍用舊上限、且只試一次。Edge 已結束時約 7 秒後才報錯（原約 2 秒）。
- **登入檢查清除殘留 Edge（2026-11-12）**：`Test-E3CdpRoutesReady` 無視窗模式開背景 Edge 前先 `Reset-E3HeadlessBrowserForNewDelivery`（呼叫端已持有 `E3TeamsCdpShared`；只結束同 profile 的 headless 程序，有視窗設定 Edge 仍拒絕）。原本只有正式傳送會清，排程被 10 分鐘期限結束或 Edge 未及時退出時，檢查會因「登入資料正被使用」誤報登入異常。
- **帳號頭像等待（2026-11-12）**：`Get-E3SelfBinding` 對 `E3Cdp.beginBinding()` 的 `ACCOUNT_PROFILE_AMBIGUOUS` 每 250 ms 重讀，最多 10 秒（只讀取頭像數量，數量不是 1 時不點擊）；之後讀帳號的 10 秒另計（`$bindStarted`）。仍失敗時錯誤附上頭像數量。原本第一次讀不到頭像就失敗，造成 11/12 18:39 排程登入預警誤報。其他錯誤立即回傳不變。
- **收據**：`logs\<日期>\receipts\<工作ID>.json`，含 editor／preSend／textComparisons（無正文）／network 摘要（無 URL、header、正文）。
- **Runtime 版本**：目前 `2026-11-12-history1`（adapter 1.0.37）；`Connect-E3CdpTarget` 與 `teams_self_test.ps1` 的白名單必須同步（兩處皆已含 history1，清單相同）。相容的 receipttext1／receiptbreak1 分頁在 idle／finished 時可原地一起升級 adapter、receipt 與 runtime；不替換進行中的傳送。更舊版本需使用者核對後重新整理分頁。更動內嵌 runtime 時要更新版本字串與兩處白名單。
- **傳送前聊天基準（history1）**：手機截圖回覆與排程共用 `deliverySnapshot`。貼上前最多 2.5 秒重讀，需連續兩次 ID、可讀正文／時間與不可解析列集合一致；只有讀取，不重貼、不重送。已穩定存在、ID 唯一但缺正文／完整時間的列保留於 `boundary.ids` 排除集合，不當作新回覆，也不猜測時間。非空紀錄至少有一筆可讀時間錨點；缺少／無效／重複 ID、全不可讀、草稿變動仍停止。貼圖後與核對回覆時若出現不在基準中的不可解析 ID 或失去歷史連續性，仍停止／保持不明；原本的同文衝突、綁定、圖片與伺服器收據檢查保留。一般 `snapshot` 預設仍嚴格，接收端讀取規則未變。收據新增 `history`（讀取次數、穩定性、rows/readable/opaque、固定原因代碼、失敗／恢復原因；不記錄正文），`preSend.history` 記錄送出前讀取摘要。新錯誤「無法建立聊天紀錄基準」會保留具體原因，取代失去底層原因的「無法讀取原自聊訊息」。
- **聊天基準回歸**：`tools\test_cdp_history.ps1` 與 `tools\fixtures\cdp_history.js` 用暫存 headless Edge／本機檔案、真實 adapter／PNG 準備與像素驗證／runtime／receipt，加上替身 Teams DOM、編輯器及 model readiness，驗證特殊舊訊息下的一次圖片回覆、舊 ID 排除、短暫讀取恢復、缺失／重複 ID、新同文／不可解析列、對話與草稿變動、歷史連續性、idle 升級與活動工作阻擋。可傳 `-AdapterFile <舊版 Delivery.ps1> -ExpectLegacyFailure` 重現舊錯誤。只證明本機模擬；實際租戶、原主機無視窗與收件結果仍需實測。
- 同名 isolated world（`E3ProductionCdp`）會重用同一個執行環境，runtime 只注入一次。
- 「檢查 CDP 連線」（`Test-E3CdpConnection`）取得 `E3TeamsCdpShared` 時最多等 15 秒：接收端每讀一個對話就持有並釋放這把鎖，只試一次會隨機誤判忙碌（排程登入預警也因此常被略過）。真正的傳送／設定持有超過 15 秒時仍回「CDP 正在傳送或設定中」（監看依這段文字判斷略過，不可改字）。
- 「檢查 CDP 連線」（`/api/teams-detect` 背景工作＋`/api/teams-detect-status`）只讀：核對綁定、登入、帳號與對話（ConfigurationOnly），不清草稿、不解除 blocked、不發訊息。無視窗模式由 `Test-E3CdpRoutesReady` 只啟動一個背景 Edge（`Open-E3HeadlessBrowser`），每個對象在同一分頁重新套用頁面模擬與 bootstrap（屬於 CDP 連線階段，換連線要重設）後以深層連結開啟並嚴格核對（`Open-E3HeadlessChat`）；某對象在開啟或核對時失敗就關閉該 Edge，下一個對象重開，避免分頁狀態不明。排程登入預警也用這個檢查。**正式傳送仍是每個收件對象各自啟動／關閉背景 Edge（`Open-E3HeadlessTarget`）**，以維持現有的草稿清除、收據與防重送流程；尚未改為共用。

#### 8.4 傳給自己（測試）
- 「將目前預覽傳給自己」：前端 PNG＋文字快照 → `/api/test-self` → `-SelfTestJob`。「執行排程傳給自己」：`/api/test-self-schedule` → `-SelfScheduleJob`，以點擊當下的 config 快照完整跑一次正式流程（登入、擷取、判定），只送本人，忽略 alert_only 與 auto_press_enter=false。兩者都不改正式設定與收件人。
- 一律先辨識本人對話（CDP：綁定的 isSelf 分頁或 headless 嚴格驗證；UIA：本人標記、唯一選取列、標頭等原生 UIA 證據），在設定頁中央 dialog 顯示實際對話供確認（token、5 分鐘逾時、決定不可覆寫），確認後再重驗身分與空白輸入框才送。
- 工作狀態 `/api/test-self-status`（服務重啟後讀 `logs\self_tests\<id>\status.json`），`/api/test-self-active`／`/api/test-self-cancel` 只接受原工作 token。結果不明時保留鎖定與 ID，不重送。

---

### 9. 設定工具（`-Calibrator`，`calibrator.html`）
- 本機服務 `http://127.0.0.1:8765`（HttpListener 單執行緒，長工作一律背景程序）。不送 CORS；`OPTIONS` 與非本工具 Origin 一律 403。靜態白名單：`calibrator.html`、`work_control.js`、`USER_MANUAL.html`、`sample_images/*.png`；config 只能經 `/api/config`。回應帶 `Cache-Control: no-store`。單一請求例外回 500，服務繼續。
- API：`config`、`save`、`save-sample`、`delete-sample`、`capture-url`／`capture-status`（互動抓圖，同時只一個）、`commit-capture`（`Save-CaptureBundle` 在執行 mutex 內整組寫 full／crop／config，失敗回復）、`numeric-preview`、`register-schedules`、`schedule-status`、`login-setup`、`cdp-setup`、`cdp-bindings`（唯讀摘要，不回帳號／chatId）、`teams-detect`／`teams-detect-status`、`test-teams`（預設 DryRun，`?send=1` 正式送出需確認）、`test-self*`、`work-waits`／`work-decision`、`receiver-status`（GET，唯讀：`Get-E3ReceiverOverview` 回傳心跳、健康判定、監看狀態與兩個接收端任務，不含帳號／chatId）、`receiver-register`（POST，設定頁 confirm 後呼叫 `Register-E3ReceiverWatchdog`）。服務啟動時若有 `teams_receiver_watchdog.ps1` 才載入，缺檔時這兩個 API 回 404，其他功能不受影響。
- 存檔：`Save-ConfigBody` 驗證可解析、頁面 id 合法唯一、排程引用存在、時段與欄位型別，先寫暫存再 `File.Replace`；失敗回 400 且原檔不變。前端每秒比對自動儲存（只有從 `/api/config` 成功讀入後才啟用；格式錯誤時顯示錯誤並停用）。
- 版面：左欄三分頁（頁面與監測／排程與發送／全域設定），多數區塊為 `<details>` 收合並記在 `localStorage e3PanelLayout.v1`；中間畫布（✂️ 擷取範圍、📏 監測項目、💧 取色、縮放、像素放大鏡）。用詞統一為「監測項目」（警戒線與數值門檻兩種判定方式），頁面卡片顯示「監測 N 項」。左欄（2026-11-12）：
  - 頁面分頁在頁面清單下方有 `.page-section-switch`（「⚙️ 此頁設定」／「📏 監測項目 (N)」），`setPageSection('page'|'rules')` 設定 `.sidebar` 的 `data-page-section`，CSS 依 `data-pagesec` 一次只顯示 `此頁面設定` 或 `#rulesSection`；選擇記在 `localStorage e3_calibrator_page_section`（預設 page）。`addRule` 後、點右欄「目前頁面」的項目時切到 rules；按 ✂️ 擷取範圍時切到 page。沒有選取頁面（`no-page-selection`）或不在頁面分頁時不顯示切換鈕。
  - 監測項目編輯：名稱欄在判定方式之前；長說明改成 `details.inline-help`（「ⓘ 怎麼操作」「ⓘ 兩個框要怎麼框」「ⓘ 排程時怎麼判定」），預設收合。項目卡片改用 DOM 文字（不再以 innerHTML 插入名稱），內容為判定方式＋門檻＋最近讀數（數值：「數值門檻 30・最近讀到最高約 8.05」或「最近最高低於約…」；像素：「警戒線（固定高度）・越線 N 點／沒有越線」），座標只在「進階」。
  - 頁面清單一頁放得下（`PAGE_LIST_SIZE` 20）時隱藏「上一頁／下一頁」與計數列。
  - 排程與發送分頁的順序改為：排程時段（預設展開）→ Teams 傳送設定 → 手機遙控。
  - 此頁完成度 `#pageSetupSteps`（`pageSetupSteps(page)`／`renderPageSetup`，由 `renderTeamsPreview` 呼叫，網址輸入時也即時更新）：網址（http(s) 開頭，新增時的範例網址 `your-internal-system.corp` 不算）→ 抓圖（`capture_view.layout === 'native100-v1'`，目前頁面另需非提示圖的畫面）→ 擷取範圍（需已抓圖且 w、h > 0；新增時的預設整頁不算）→ 監測項目（選填，只顯示）→ 加入排程（至少一個啟用中的排程含此頁；只在停用排程中另有說明）。缺的標黃，「下一步」：網址＝聚焦網址欄、抓圖＝直接呼叫 `fetchLiveUrlScreenshot()`、擷取範圍＝切 ✂️、加入排程＝捲到勾選區。`firstMissingStep` 也用在頁面卡片（「⚠ 缺網址」「⚠ 未加入排程」，停用頁面不標）。只看設定與已載入的圖，非目前頁面不會讀取其圖片。
  - 「此頁設定」下方 `#pageScheduleChecks`（`renderPageScheduleChecks`）：每個排程一個勾選框，勾選把頁面 id 加到該排程 `pages` 最後、取消則移除，接著 `renderAll()`；與排程卡片的頁面清單是同一份資料。排程簽章不含 pages，所以只會自動儲存、不重新註冊 Windows 任務。
  - 「超標時的訊息」標籤改為說明是純文字、`@名字` 不會變成 Teams 標註（CDP 貼上的是純文字）。
  - 新增頁面後表單要等 `ensurePageImage` 讀完圖才切換；設定服務是單執行緒，啟動時的數值自動試算會讓這一步延後數秒（既有行為）。
  - `.inner-fold` 內直接放的勾選列、說明標籤與縮放輸入框補上與 `.field` 相同的字級與深色外觀（原本是瀏覽器預設的大字與白底）。
  - 手冊截圖工具在各張圖呼叫 `setPageSection`（01／04／11 為 rules，02／03／08 為 page），09／10／13 先把對應區塊捲進畫面再截，否則下移後的區塊會被裁掉。左欄實測 13 項＋右欄回歸 13 項通過。
右欄由上而下（2026-11-12）：
  - `#currentPageJudgeBox`「🎯 目前頁面」（`renderCurrentPageJudge`，由 `renderTeamsPreview` 呼叫）：只看正在編輯的頁面，每個監測項目一行（`judgeRuleLine`：數值規則用 `numericDescription`、像素規則寫是否越線／點數、範圍無效、尚未抓圖、已停用），點一行會選取該項目並切到頁面分頁的 📏 模式；徽章為「正常／N 項超標／N 項無法判定／只截圖／已停用」。下方說明此頁屬於哪些排程：在預覽排程內就註明；不在時列出包含它的排程按鈕（點擊只改 `previewScheduleId`，不自動切換，避免改到「執行排程傳給自己」的對象）；沒有加入任何排程時提醒「排程執行時不會被截到」。這塊與下方「⚡ 排程判定結果」（原「警戒線判定」，所選排程的全部頁面）分開，避免把其他頁的結果看成這一頁。
  - `.preview-controls`「👁 排程預覽與測試」：`previewScheduleSelect` 加上四個測試按鈕（`testPreviewBtn`、`sendToSelfBtn`、`runScheduleToSelfBtn`、`testSendNowBtn`）與 `selfHelpFold`、`selfTestRefreshBtn`、`selfTestStatus`。原本左欄排程分頁的「預覽與測試」區塊已移除，元素 id 不變，所以既有處理程式照舊。
  - 頁首儲存狀態 `#autoSaveStatus` 改為 `<button>`：`setAutoSaveStatus` 在 error 且文字含「排程未同步／排程同步失敗」時加上 `actionable`、`data-action=sync` 與「（點此同步）」，點擊（需 `autoSaveEnabled`、未在儲存中）執行與「重新套用」相同的 `applySchedules()`；其他錯誤不可點。
  - 版面以暫存副本（帳密遮罩、暫存服務、暫存 headless Edge）實測 13 項：用詞、四個按鈕位置、首頁與數值頁的目前頁面判定、不在預覽排程時的提示與一鍵切換、點項目選取、同步提示可點與其他錯誤不可點、無腳本錯誤；沒有實際點同步（會註冊 Windows 任務）。必須經本機服務開啟；`file://` 時嘗試轉址，否則顯示服務未啟動。
- 排程選單只有右欄 `previewScheduleSelect` 一個（選項含張數），下方 `selfTestScheduleHint` 顯示目前選定排程與張數；四個測試按鈕都用 `previewScheduleId`，測試啟動中停用該選單與「目前頁面」的排程切換按鈕。手冊截圖 `12_self_test` 改截 `.preview-controls`。
- 「排程時段」`schedulesFold` 預設展開（記憶鍵 `sidebar:schedulesFold:v2`，讓舊版記住收合的使用者也先看到展開），收合摘要列出前 3 個排程的時間與名稱。`#scheduleList` 與 `.schedule-page-list` 不設 max-height／內部捲軸，只由左側欄捲動（避免捲軸套捲軸切掉展開的排程設定）。
- 排程卡片標題下兩行由 `renderScheduleRowStatus` 填入：設定摘要＋「下次」，以及 `rowLast`「上次 時間：結果」（class ok／warn／bad／running 上色，title 為完整原因）。資料來自 `/api/schedule-status` 每個任務的 `last`（`at`、`status`、`text`、`reason`）：`Get-E3ScheduleTaskStatus` 讀 `LastRunTime`／`LastTaskResult` 與 `logs\schedule_results\<id>.json`，交給 watchdog 檔的 `Get-E3ScheduleRunSummary`（與排程未送達通知同一套 `Get-E3ScheduleRunProblem` 判斷；watchdog 檔缺少時只有時間）。`refreshScheduleRunInfo` 在視窗取得焦點與每 60 秒（頁面可見、已從服務載入設定時）重讀，只更新卡片文字、不重建清單，避免打斷編輯；完整同步核對仍由 `refreshScheduleStatus` 負責。手冊截圖工具以示範狀態（已送出）回應 `last`。
- 「手機遙控（@日管）」`receiverFold`（排程與發送分頁）：以 textContent 顯示 `/api/receiver-status` 的接收端狀態、已執行時間、最後回報、防睡眠、各接收對話（讀不到時顯示原因）、離線通知與開機啟動任務；摘要顯示狀態與離線通知是否設定。載入時、視窗取得焦點與每 30 秒（頁面可見時）更新；「註冊離線通知與開機自動啟動」按鈕先 confirm 再 POST `/api/receiver-register`。 卡片另顯示「視窗模式」（心跳的 `mode`；與設定不同時提示重新啟動接收端）與「自動重啟」（`autoRestart`：監看任務最近一次重啟時間），並有 `receiverHeadlessChk` 勾選框寫入 `teams.receiver_headless`（下次啟動接收端才生效）。
- 每頁畫面來源：`sample_images\<id>_full.png`（依 crop 重裁）→ `sample_images\<id>.png` → 都沒有時顯示「這一頁還沒有畫面」提示圖（不評估警戒線）。直接開啟 HTML（file://）時沒有圖可讀，只顯示提示圖與「本機服務沒有啟動」橫幅。
- 數值規則：設定與圖片載入後自動逐項呼叫 numeric-preview（串行），結果綁定規則與圖片簽章，過期結果不顯示。

---

### 10. 工作控制（`work_control.ps1`）
- 資源 `cdp` 與 `capture` 的占用者寫在 `logs\work_control\<資源>.owner.json`（PID＋啟動時間＋入口腳本）。等待時寫 `waits\<id>.json`，設定頁彈窗讓使用者選擇；**沒有點選絕不自動強制停止**。
- 強制停止只結束可驗證的專用工作程序（`e3_monitor_native.ps1`／`teams_receiver.ps1` 的 worker，排除 `-Calibrator`、`-Listen`），不停 Edge 或服務；接收端等 cooperative 工作改寫 cancel 檔讓其自行停止。決定需匹配 id／token／當下 owner，重複提交不重做。
- `Disable-E3ConsoleQuickEdit` 只改目前主控台的輸入模式（清 0x0040、設 0x0080），保留 Ctrl+C；設定服務、CDP 設定與接收端共用。

---

### 11. 手機 `@日管` 遙控（接收端）
- **停止與指令紀錄修正（stop-claim1）**：明確啟動只在取得接收端 mutex 後清除舊停止標記；自動重啟傳入 `PreserveStopRequest`，2／15 秒等待期間每最多 250 ms 檢查停止檔，下一次入口在載入對話或 Edge 前處理並寫入 intentional/stopped 心跳。既有截圖／傳送中的工作仍按原流程結束，不新增強制取消。`seen` 改在 `New-E3ReceiverClaim` 成功返回之後加入；建立紀錄前的儲存失敗可於恢復後重新選取，已存在的紀錄（含不完整檔案）仍禁止重送，不自動刪除。`tools\test_receiver_stop_claim.ps1` 使用隔離 mutex、暫存檔及替身讀取／傳送驗證這兩項；未更改監看健康判定、去重 key 或效能等待設定。依使用者指示，開發期間暫不更新使用者手冊。
- **失敗原因與說明訊息（2026-11-12）**：
  - 截圖回覆：`Invoke-E3ReceiverCapture` 只負責啟動與等待子程序，回覆由 `ConvertTo-E3ReceiverCaptureReply` 依子工作資料夾的 `result.json`（每頁 `error`、整體 `error`）、`deadline.json`、結束代碼與 `capture-error.log` 組成：沒截到的頁逐一寫「名稱：沒有截到。原因：…」，原因經 `Format-E3ReceiverReason`（去掉內部前綴、單行、限長）。等不到擷取執行權改寫成「排程或另一個擷取正在執行，等了 3 分鐘仍未輪到」。回傳 `problems` 供指令紀錄使用。
  - 指令紀錄 `commands\<key>.json`（version 3，`Save-E3ReceiverClaimState`）：每個狀態都帶 `route`、`command`、`messageTime`。狀態：`claimed`→（截圖指令）`ack_sending`→`acknowledged`→`replied`（含 `images`、`problems`）；失敗為 `not_retried`（含 `phase`：received／acknowledgement／capture／result，與 `error`）；`ignored`（沒有可回覆內容）；`interrupted`（見下）。
  - 失敗說明：主迴圈 catch 在指令已領取且未回覆時，寫入 `not_retried` 後以 `Add-E3ReceiverOutbox` 排入一則純文字說明（`New-E3ReceiverFailureText`：台灣時間＋指令、`Get-E3ReceiverPhaseText` 依階段說明可能已送出什麼、原因、不會自動重做），`route`＝原對話、`kind=command_failure`。`E3_RECEIVER_RELOAD` 也先記錄與排入再往外丟。說明由通知佇列在該對話恢復可讀後送出一次。
  - 中斷：`Resolve-E3ReceiverInterruptedClaims` 在取得接收端 mutex 之後（此時沒有其他接收端）把 6 小時內仍停在 claimed／ack_sending／acknowledged 且有 `route` 的紀錄先改成 `interrupted` 再排入一則說明（視窗被關、程式結束、主機重開）。先改狀態再排入，所以同一筆只說一次；指令不重做。舊版紀錄沒有 `route`，略過。
  - 離線期間的指令：第一次啟動時讀舊 `heartbeat.json` 的 `utc` 當作 `E3ReceiverOfflineFrom`（7 天內才採用）。每個對話第一次成功讀取時，`Get-E3ReceiverMissedCommands` 找出畫面上時間落在（上次心跳, 本次啟動]、且沒有指令紀錄的 `@日管` 訊息，排入一則「這段時間有 N 個指令沒有處理」到該對話（每個對話每個程序一次，`E3ReceiverMissedDone`）。只列出、不補做；只看得到畫面上仍載入的訊息。
  - 代發：接收端自己送不出說明時檔案成為 `.failed`。監看任務的 `Invoke-E3FailedNoticeRelay` 只處理 6 小時內、`kind=command_failure` 的 `.failed`：先改名 `.relaying` 再用排程的 Teams 登入（`Send-GroupToTeams`）送到 `teams.target_chat_name`，文末註明原對話，結果 `.relayed`／`.relayfailed`，每輪最多 3 則、各只試一次；需要 `prefer_window=cdp`。其他種類的 `.failed` 維持不重送。紀錄在 `notice_relay_last.txt`。
  - 新指令 `上一個指令`（同義：上個指令／上一次指令／最近指令／指令紀錄，或含「為什麼…失敗／沒回／沒反應」）：`Get-E3ReceiverHistoryReply` 列出**同一個對話**最近 5 筆指令與結果／原因，不顯示其他對話的指令。判斷在「截圖」之前，所以「為什麼截圖失敗」不會再截一次。
  - 紀錄：`Start-E3ReceiverLog` 在 `-Listen` 入口以 `Start-Transcript` 把視窗內容寫到 `<日期>\receiver_console_*.log`，主迴圈每 3 秒的檢查順便換日（`Update-E3ReceiverLog`）；`Write-E3ReceiverEvent` 寫 `<日期>\receiver_events.log`（時間、種類、內容各一欄），`Save-E3ReceiverStatus` 每次都會寫，另有 start／end／fatal／restart／command／command_failed／notice_queued／notice_sent／notice_failed。兩者寫入失敗都不影響接收。`-LibraryOnly`（測試）不啟動 transcript。
  - 監看任務的監看：接收端啟動 20 分鐘後每 10 分鐘 `Test-E3ReceiverWatchdogTask`：「E3 日管接收監看」已註冊且啟用，卻超過 30 分鐘沒執行（或註冊後從未執行）連續兩次，就排入一則通知到本人對話；任務恢復執行前不重複。未註冊或被停用視為使用者的選擇，只在狀態回覆中說明。
  - 回歸測試 `tools\test_receiver_failure_notice.ps1`（55 項）：替身 Teams／擷取邊界＋暫存資料夾，含真正的主迴圈（會短暫取得真實的接收端單一實例鎖，主機上有接收端在跑時先停止）與「程式副本＋一個檔案去掉 BOM」的啟動檢查。皆為本機模擬。
- **設定**：`setup_teams_receiver.bat`（`Set-E3CdpBinding -SelectInBrowser`）在 `E3TeamsCommandReceiver` 的有視窗 Edge 由使用者選對話後 BIND，可連續綁本人、其他個人與多個群組（最多 20 個，route／帳號＋chatId 不可重複；不支援團隊頻道）。接收只需要綁定中的 accountId／chatId／label，設定時開的分頁之後不需保留。接收端執行中（`Local\E3TeamsCommandReceiver` 存在）拒絕 setup，需先停止。
- **啟動／停止**：`start_teams_receiver.bat`（`-Listen -Continuous`）；`test_teams_receiver.bat` 回覆一個指令或 10 分鐘後結束；`stop_teams_receiver.bat`（`-Stop`）寫 `logs\teams_receiver\stop.request`，主迴圈每 3 秒檢查後正常結束（啟動時會清掉殘留的要求）。`Local\E3TeamsCommandReceiver` 防重複啟動。Ctrl+C 與 stop 都在心跳記為 `intentional`，監看不會重啟；直接關閉黑色視窗無法留下紀錄，視為異常結束，會被監看重新啟動。
- **指令**（2026-11-12 改為規則式問法辨識；主機在企業內網、不能用 AI 服務，所以不做自然語言 AI，聊天文字只用來挑選已設定的名稱與固定查詢，從不執行）：
  - 前綴：文字以 `@日管` 開頭，後面接空白（半形、全形 U+3000、NBSP 都可），或直接接已知的指令字（`$starts`：狀態、截圖、檢查、主機、排程、連線、說明…），所以 `@日管狀態` 可用、`@日管理員…` 不算。`receiver-snapshot.js` 只把 `^@日管[ 　]*\S` 當候選，是否為指令由 `Resolve-E3ReceiverRequest` 決定；不是指令的候選仍會建立 claim，狀態為 `ignored`、不回覆。
  - 辨識前先去掉前後的客氣話（請、幫我、麻煩、謝謝、嗎、標點…，存成 `$q`）。判斷順序：上一個指令 → 說明 → 打招呼（回「我在」＋執行時間＋用法）→ 狀態 → 清單 → 主機（有主機字、沒有截圖字也沒有頁面名稱時；「主機正常嗎」不會被當成檢查）→ 檢查（檢查、多少、數值、超標、門檻、最高、正常嗎…；「截圖並檢查」也是檢查）→ 截圖（截圖、抓圖、擷取、截一張、拍一張、給我看）→ 連線（連線、連得到、打不開、ping…）→ 排程（排程、有送、沒收到、發了、結果…）→ 只有名稱（視為截圖）→ 看不懂（回「這句我還看不懂」＋可能的名稱建議＋用法）。「為什麼截圖失敗／沒回」是上一個指令，「為什麼沒收到」是排程。
  - 名稱：每次讀 config，完整名稱優先、英數邊界不模糊匹配（P14 不匹配 P14_D3）；清單（、，, 跟 及 和 與 以及）依輸入順序；`頁面 名稱`／`排程 名稱` 解決重名；名稱也可以寫在截圖字前面。每次最多 20 頁。找不到時 `Get-E3ReceiverSuggestions` 給最多 3 個建議（忽略大小寫與 `_ - 空白`、包含關係、字母順序顛倒、編輯距離 ≤ 長度/4），**只建議、不代選**，需要使用者再下一次指令；清單中某一項找不到時其他項照做並附建議。檢查／連線的文字中有像名稱的英數字（`Get-E3ReceiverLooseWords`）卻對不到任何名稱時，回覆建議而不是擴大成全部頁面。
  - 截圖：同原本（排程名稱只取其 pages，不觸發 Windows 任務、不群發、不判定）。收到通知（`Get-E3ReceiverAcknowledgement`）列出頁面簡介；`Get-E3WorkOwner 'capture'` 有占用者時加一句「主機正在執行「…」，要等它結束才會開始（最多等 3 分鐘）」。結果附「擷取時間 MM/dd HH:mm，花了 N 秒」。
  - 檢查（`analyze`）：走同一條擷取流程（收到通知、`E3MonitorNativeRun`、300 秒期限），`request.json` 帶 `analyze=true`，子工作在每頁擷取成功後呼叫 `Invoke-E3PageAnalysis`，`result.json` 每頁多 `analysis`（captureOnly、rules、annotated 檔名、error）。回覆（`ConvertTo-E3ReceiverCaptureReply`）第一行「檢查結果（時間，花了 N 秒）：🚨 n 項超標、⚠️ n 項無法判定、✅ n 項正常」，每頁一行頁名、每個監測項目一行白話結果（數值規則寫最高值與門檻、框內沒有曲線寫「低於約」；像素規則寫是否越線；無法判定寫原因），只截圖的頁註明，沒截到的頁寫原因；圖片優先附標示圖（≤10 MiB）。不填名稱時檢查所有啟用且有啟用規則的頁面。只回覆原對話、不發給排程收件人、不寫排程結果；無法判定與沒截到列入 `problems`（指令紀錄）。
  - 查詢（`teams_receiver_queries.ps1`，在釋放 CDP 鎖後執行，查詢本身失敗時回覆「…查詢沒有完成。原因：…」）：
    - 排程結果 `Get-E3ReceiverScheduleReport`：篩選＝排程名稱，否則時段字（早上 0–12、中午 11–14、下午 12–18、晚上 17–24，或「9點」「晚上7點半」取該小時），否則全部。每個排程一行（共用 `Get-E3ReceiverScheduleLines`，含與設定頁相同的判斷與原因），再附該排程最近 26 小時內最新一份主機 log（`logs\yyyy-MM-dd_HHmm_<id>.log`，共用讀取模式）中以 ❌／⚠️／🚨 開頭的行（去重，最多 6 行，每行 150 字）。不執行、不補跑。
    - 主機 `Get-E3ReceiverHostReply`：開機時間與已開機時間、CPU 使用率、記憶體、每顆本機磁碟剩餘空間（標出程式所在磁碟；<10% 或 <5 GB 標「空間不足」）、接收對話中讀不到的（`$script:E3ReceiverLiveSources`）、`Get-E3ReceiverHealthLines`（排程登入、監看任務、待送通知），各部分讀不到時分別說明，最後一行整體結論（CPU ≥90%、記憶體 ≥90%、磁碟不足時列出）。資料來源 `Get-E3ReceiverHostFacts`（CIM），可替換以便測試。
    - 連線 `Get-E3ReceiverConnectReply`／`Test-E3ReceiverSite`：每個不同網址一次 GET（8 秒、自動轉址、`UseDefaultCredentials=false`、不帶 cookie，只讀標頭）。2xx／3xx＝連得到，401／403＝連得到但要求登入，其他 HTTP 碼與 DNS／連不上／逾時／憑證／TLS 各有白話原因。不填名稱時測所有啟用頁面。只代表網站有回應，不登入、不截圖。
- **防重複**：只處理接收端啟動之後、位於最新位置、兩次快照文字／ID／時間一致的訊息；以帳號＋chatId＋時間雜湊建立持久 claim（`logs\teams_receiver\commands\<key>.json`）後才處理；結果不明不重送。忽略「✦」開頭的回覆、含圖片、引用、傳送中、超過 400 字的訊息。
- **單一工作分頁**（2026-11-11 起，取代「每個對話一個分頁、必須停在最新訊息」）：一個專用 Edge、一個分頁服務所有綁定對話，不需要任何對話保持開啟。`Initialize-E3ReceiverTab` 確保瀏覽器與工作分頁存在：沿用仍在執行且模式相符的專用 Edge（只採用該 profile 自己寫的 DevToolsActivePort 且監聽埠屬於該程序），模式不符先正常關閉再重開；舊版記錄在 bindings 的其他分頁會關閉。`Set-E3ReceiverBindingTab` 把所有接收綁定的 `targetId` 指向工作分頁，因為回覆沿用 `Send-GroupToTeamsCdp`，它經 bindings.json 找分頁；接收端呼叫時固定傳 `cdp_headless=$false`（＝使用現有分頁，不另開瀏覽器），**不可改成 true**，否則會把接收端自己的瀏覽器當成遺留程序清掉。`Open-E3ReceiverChat` 把分頁帶到某對話：頁面已準備好時先用 `teams_cdp\receiver-switch.js` 在 Teams 內切換（只點擊聊天清單中名稱唯一相符的項目，點一次後最多等 6 秒並以 chatId 核對；同名、不在清單、未切換都回 `reopen`），否則以 chatId 連結整頁開啟（同一連線先註冊 `image-frame-bootstrap`，`Wait-E3HeadlessChat` 75 秒，再由 `Connect-E3CdpTarget` 嚴格核對帳號／chatId／label）。主迴圈每圈由 `Get-E3ReceiverNextSource` 取「到期且最久未讀」的來源，`Invoke-E3ReceiverVisit` 讀兩次相隔 500 ms 的穩定快照後交給 `Select-E3ReceiverCommand`；單一來源每圈 1 秒、多來源每圈 300 ms。頁面載入超過 `E3ReceiverReloadMinutes`（30）會在下一次讀取時整頁重載。送出前（收到通知、結果、監看通知）一律 `Enter-E3ReceiverChat`：切回來源對話、`Connect-E3CdpTarget`、`Assert-E3ReceiverDestination`。**不檢查輸入框空白**：殘留草稿交給 `Send-GroupToTeamsCdp`（分頁模式 `Clear-E3HeadlessDraftForNewDelivery -Visible`，先核對分頁、帳號、對話並停止舊 runtime 工作）清除；若在這裡要求空白，一次中斷的貼上會讓之後每個指令都被領取後失敗，而讀取仍正常、心跳與監看都看不出來。
- **有視窗／無視窗**（`teams.receiver_headless`，預設有視窗）：無視窗以 `--headless=new` 啟動，並用啟動參數 `--user-agent`（依 msedge.exe 主版本組出不含 Headless 的字串）與 `--window-size=1600,1000`，因為每次 CDP 重連都會失去連線層級的模擬設定（`Start-E3TestBrowser -ExtraArguments`）。有視窗時每 15 秒以 `Browser.getWindowForTarget` 檢查，視窗被最小化就還原（最小化會停止繪製，新訊息進不了頁面）；被其他視窗蓋住或鎖定螢幕不受影響。
- **最新訊息讀取**（`teams_cdp\receiver-snapshot.js`，viewport 版本 `receiver-latest2`）：不使用發送端的 `followLatest`／`atLatest`／`snapshot`。先以 `BridgeAdapter.inspect` 核對綁定與 label，在對話根節點內找唯一可捲動的訊息清單（找不到或不唯一即回錯誤，不猜測）；可見的「回到最新訊息」按鈕最多每 2 秒點一次，點擊或捲動後本次回傳 `latest:false`，下一次讀取穩定在底部（誤差 ≤2 px，支援 column-reverse）才讀指令。不聚焦輸入框、不送鍵、不碰草稿與其他捲軸。**訊息列由本腳本自行解析且容錯**：無法解析的列（沒有唯一正文、沒有完整含時區的時間、ID 重複，例如卡片、通話紀錄、已刪除訊息）只計入 `skipped` 並略過，不讓整個對話讀取失敗；指令列仍嚴格要求唯一 ID、單一正文、完整時間、純文字（表情圖示除外）、無引用、非傳送中。`Read-E3ReceiverSettled` 在期限內（預設 8 秒）每 400 ms 重讀：「尚未到最新」只是等待，不是斷線。回歸測試 `tools\test_receiver_latest.ps1`（33 項，暫存 headless Edge＋替身 BridgeAdapter，不導覽 Teams、不送出）。
- **處理**：截圖指令先送收到通知（頁面簡介，等傳送鎖最多 180 秒），釋放 CDP 鎖後由 `-ReceiverCaptureJob` 子程序以 headless 擷取（期限 300 秒，父程序最多等 330 秒；`E3MonitorNativeRun` 排他，排程執行中最多等 180 秒），結果回覆等傳送鎖最多 420 秒（2026-11-12，原 180 秒；排程傳送最壞約 5 分鐘），處理中心跳 `busyUntil` 為 1500 秒（原 1200，涵蓋 ack＋擷取＋420 秒等待＋傳送，避免監看把仍在回覆的接收端當成卡住而重啟），再重新核對原來源、帳號、對話與空白輸入框，以原 route 回傳圖片。回覆以「✦ [日管]」開頭、保留分行不插空行。 同一時間只處理一個指令；處理期間不讀取其他來源，完成後依序處理仍在對話中、時間在啟動之後且未領取的指令。
- **圖片回傳回歸驗證**：`tools\test_cdp_image_preflight.ps1` 每個案例用全新 PowerShell 載入接收端 `-LibraryOnly`，以替身綁定及禁止連線的邊界執行真實 CDP 圖片預檢，涵蓋有／無視窗、純圖片、純文字、錯誤 PNG、損壞 PNG、超大尺寸及混合圖片。避免測試自己產生圖片時先載入組件而掩蓋接收端缺少載入的錯誤。這是本機驗證，不代表實際 Teams 已送達。
- **狀態回覆**：主機名稱、連續執行時間、排程數，以及各排程 Windows 任務的上次結果與下次時間；未同步、停用、讀不到任務清單會明示。上次結果用與設定頁卡片相同的 `Get-E3ScheduleRunSummary`（接收端啟動時載入 `teams_receiver_watchdog.ps1`，缺檔時退回結束代碼文字），沒送達或部分失敗時附原因。之後由 `Get-E3ReceiverHealthLines` 加上：排程用的 Teams 登入（讀 `sender_login_state.json`：正常／等下一次確認／需要處理＋原因／尚未檢查；只在 CDP 模式）、離線監看任務（正常＋上次時間／未註冊／已停用／超過 30 分鐘沒執行／無法讀取）、待送通知數（有才顯示）、這個對話最近 24 小時沒有完成的指令數（有才顯示，並提示 `@日管 上一個指令`）。
- **容錯與復原階梯**：任何來源讀取、截圖、傳送例外都不結束接收程序。`Set-E3ReceiverSourceFailure` 只影響該來源：退避 10→20→40→80→160→300 秒，下次改以連結重開（`reload`），其他來源照常輪讀；同一原因只印一次。登入類錯誤（`E3_RECEIVER_LOGIN`）讓全部來源暫停 60 秒（共用一份登入，不逐一試探）；瀏覽器或分頁準備失敗（`E3_RECEIVER_BROWSER`）清掉分頁狀態，20 秒後重建。有視窗模式看到 Microsoft 登入頁時 15 分鐘內不再導覽，留給使用者登入；無視窗模式照常重試。對話改名（label 不同）回 `E3_RECEIVER_SOURCE`，需重新綁定。bindings.json 被改寫（時間戳不同或找不到原綁定）丟 `E3_RECEIVER_RELOAD`。`Start-E3ReceiverSupervised`：持續模式遇到未預期例外不結束程序，15 秒後（RELOAD 為 2 秒）重新進入 `Invoke-E3ReceiverTest`，沿用第一次啟動的指令時間界線（`E3ReceiverCutoff`）；只有 `E3_RECEIVER_FATAL`（沒有綁定、重複綁定、重複啟動）會結束。復原永遠不重讀、重試或回覆先前的指令，claim 與 seen 仍有效；程序重新啟動後只處理啟動之後的新訊息，不回補離線期間的指令。回歸測試 `tools\test_receiver_single_tab.ps1`（87 項：切換腳本於真實頁面、輪讀與退避、綁定指向工作分頁、開啟對話各路徑、監看重啟判斷、以替身對話執行真正的主迴圈，以及殘留草稿不擋回覆、CDP 關閉自動 Enter 回報未送出、通知佇列在鎖忙碌時保留（隔離 mutex 名稱）、排程傳送結果判斷與只通知一次、排程卡片上次結果摘要）；皆為本機模擬，不代表真實 Teams 行為。
- **防睡眠**：接收期間 `SetThreadExecutionState(ES_CONTINUOUS|ES_SYSTEM_REQUIRED)`，允許關螢幕與鎖定，不改電源計畫，結束時解除。
- **心跳**：持續模式寫 `logs\teams_receiver\heartbeat.json`（version 2：state〔listening／processing／restarting／stopped〕、pid、processStart、startedUtc、utc、busyUntilUtc、sleepGuard、stopReason、mode〔window／headless〕、intentional、fatal、sources[route, active, lastOkUtc, error]），最多每 30 秒一次，連上、處理前（busyUntil +1200 秒）、回覆後與結束時強制寫入。
- **監看**（`-ReceiverWatchdog`，Windows 任務「E3 日管接收監看」每 10 分鐘）：無心跳、stopped、程序不存在、心跳超過 10 分鐘（不在 busyUntil 內）、啟動滿 10 分鐘後任一來源超過 10 分鐘未成功讀取，皆異常；60 秒後再確認。只支援 CDP 模式，用排程的 Teams 登入傳純文字「✦ [日管監看]」到 `teams.target_chat_name`。`watchdog_state.json` 先記錄再傳送；同次離線只通知一次、失敗不重試；只有離線通知 sent 才發「已恢復」。不持有 `E3MonitorNativeRun`。`Write-E3WatchdogLog` 除了覆寫 `<名稱>_last.txt`（最新結果），內容與上一次不同時另在 `<日期>\watchdog_history.log` 加一行（時間、檢查名稱、內容），所以每 10 分鐘重複的「正常」不會灌滿歷史，異常、重啟、通知的時間都留得下來。 **自動重啟**：`Get-E3ReceiverHealth` 回傳 `kind`，`Get-E3ReceiverRestartPlan`（純判斷）只對程序已結束（dead）、非要求的停止（stopped）與卡住（stale，先結束經 PID＋啟動時間＋命令列核對的接收程序）重啟；`intentional`、`fatal`、從未啟動、程序仍在但讀不到 Teams（sources）、或存在 `stop.request` 都不重啟。15 分鐘內不重複、一小時最多 3 次（`watchdog_restart.json`，先記錄再動作）。`Start-E3ReceiverAutoRestart` 先確認 `Local\E3TeamsCommandReceiver` 不存在，優先以 Stop／Start「E3 日管接收端」任務重新啟動（結束後的視窗停在 pause 仍算執行中，IgnoreNew 會擋掉新啟動），任務不可用時直接執行 start_teams_receiver.bat。重啟當次不通知，下次檢查仍異常才通知，通知文字附上重啟結果。
- **排程登入預警**（同一個監看任務，`Invoke-E3SenderLoginCheck`）：排程用的 Teams 登入過期時，無法用同一份登入通知自己，因此檢查結果交給接收端（另一份登入）發送。只在 `prefer_window=cdp` 時執行；`Test-E3SenderLoginDue` 決定時機：從未檢查、距上次 ≥6 小時、下一個本專案排程任務（`Get-E3NextScheduleRunUtc`，依 `Get-E3OwnedTaskId`）在 70 分鐘內且距上次 ≥3 小時、或上次異常且已過 30 分鐘。檢查用 `Test-E3CdpConnection -PassThru`（ConfigurationOnly：登入、帳號、對話，不傳訊息）；CDP 鎖忙碌時略過且不更新狀態。下一個排程在 5 分鐘內時不開始檢查（兩者都要 CDP 鎖，排程只等 180 秒）。**連續兩次失敗才通知**（2026-11-12）：第一次失敗只記 `ok=false`、`pending=true`，下一次監看（距上次 ≥5 分鐘）再檢查，仍失敗才通知；原因是 11/12 18:39 單次失敗誤報。真正過期最多晚約 10 分鐘通知。`logs\teams_receiver\sender_login_state.json` 記錄結果；確認異常時寫一則「✦ [日管監看] 排程用的 Teams 登入需要處理…」到 `logs\teams_receiver\outbox\`，異常期間不重複，恢復時再寫一則「已恢復」。`Local\E3SenderLoginCheck` 防重入，420 秒期限。
- **排程傳送結果通知**（同一個監看任務，`Invoke-E3ScheduleResultCheck`）：主程式在正式排程（`-Schedule`，不含 `-SelfScheduleJob`／`-TestSample`／`-NoSend`／`-DryRun`）開始時寫 `logs\schedule_results\<id>.json`（state=running），等不到執行權改 `no_lock`，finally 寫 `finished`（exitCode、targets、delivered、sendFailures、error、skipped＝`outside_window`／`alert_only_normal`）。被 10 分鐘期限強制結束時 finally 不執行，留下的 running 即「中斷、結果不明」。監看依 `Get-E3OwnedTaskId` 列出本專案任務，讀 `LastRunTime`／`LastTaskResult`；執行中（267009）或從未執行（267011）不判斷。結果檔的 startedUtc 落在 LastRunTime −2～+15 分鐘才算同一輪，否則只依任務結果代碼（0 不通知）。`Get-E3ScheduleRunProblem`（純判斷）：running、no_lock、有 sendFailures、或 exitCode≠0 且沒有任何對象送達 → 通知；頁面擷取／判定失敗但訊息已送達不另通知（原因已在 Teams 訊息內），skipped 不通知。`logs\teams_receiver\schedule_result_state.json` 記錄每個排程已處理的 LastRunTime，**先記錄再排入**，同一輪只通知一次、不重送；首次檢查時超過 24 小時的舊結果只建立基準。多個排程合併成一則「✦ [日管監看]」經通知佇列由接收端發送（接收端未執行時最多保留 6 小時）；紀錄寫在 `schedule_result_last.txt`。限制：重複間隔小於 10 分鐘時兩次檢查之間只看得到最後一輪。測試用 `$script:E3WatchdogLogRoot` 指向暫存目錄，不碰正式 logs／outbox。
- **通知佇列**（接收端 `Send-E3ReceiverOutbox`，每 5 秒）：只接受以「✦」開頭、≤2000 字、6 小時內的 `outbox\*.json`（否則改名 `.invalid`／`.expired`）；項目有 `route` 時（指令失敗／中斷／離線說明）只送到那個綁定對話：該對話已不在綁定中改名 `.invalid`，尚未連線就留在佇列且不擋住後面的通知；沒有 `route` 的送到已綁定的本人對話，沒有本人對話時用第一個來源，該來源未連線時保留等待（不改送其他群組）。先以 `WaitOne(0)` 取得 `E3TeamsCdpShared`（忙碌時保留 `.json`、本輪結束，5 秒後再試，不經設定頁忙碌彈窗），取得後才改名 `.sending` 並送，結果 `.sent`／`.failed`，每則最多嘗試一次，接收端不重送；不會因等鎖逾時而沒試就變成 `.failed`。只有 `kind=command_failure` 的 `.failed` 會由監看任務用排程登入代發一次（見上）。完成的檔案（含 `.relayed`／`.relayfailed`）30 天後由紀錄清理刪除。
- **設定頁狀態**：排程與發送分頁的「手機遙控（@日管）」卡片顯示上述心跳、監看與任務狀態、排程登入檢查結果與待送通知數，並可直接註冊兩個任務（見第 9 節）。
- **自動啟動**（Windows 任務「E3 日管接收端」）：登入 Windows 1 分鐘後執行 `start_teams_receiver.bat`，無執行時間上限、IgnoreNew。兩個任務由 `register_receiver_watchdog.bat` 一起註冊；action 不含 `-Schedule`，`-RegisterSchedules` 不會刪除它們。這是登入觸發；程序結束或卡住後的重啟由監看任務負責。注意 `Test-E3ReceiverTaskAction` 的 watchdog 分支只核對 `-ReceiverWatchdog`，未完整核對 Execute／腳本／config 路徑，不能保證同名的另一份安裝不被覆寫或移除。
- **紀錄保留**：啟動時與每 24 小時清理：`captures\<日期>`（指令截圖）超過 7 天、`<日期>`（收據、診斷、視窗紀錄、事件紀錄、監看歷史）與 `commands\*.json` 超過 30 天；不碰 `teams_cdp`（blocked／review）、heartbeat、status、watchdog 檔。
- 注意：`Get-ScheduledTask -TaskPath '\'` 在根資料夾沒有任務時會丟例外，查詢一律列出全部後篩選 TaskPath。

---

### 12. 已知限制與待實測
- 網頁版面隨縮放／內容變化：改縮放、網址或版面後需重新抓圖並確認警戒線；不保存 iframe／表格內部捲軸、不重演點擊流程。圖片上限單邊 16384、總 6400 萬像素。
- 自動登入只認固定按鈕文字與密碼框；SSO／MFA／特殊表單需手動登入。帳密以明文存在 config.json 與瀏覽器 localStorage。
- Zabbix 時間調整只支援舊版 `timeControl`／`scrollbar_cntr` 介面與英文 `(now)` 標籤；新版、其他語系、iframe 需另外適配（無法確認即此頁失敗）。
- 數值 OCR 需主機有可用的 Windows OCR 語言；不保證任意字型與影像品質；另一台主機的實際 OCR 結果需現場驗證。
- 視窗模式（UIA）需解鎖的互動桌面，Teams 改版可能影響定位；名稱須與清單完全一致，清單最多往下捲 10 頁。
- CDP：本機測試、伺服器回應與手機實收要分開。保留視窗模式曾有短時間 Win+L 實收確認；無視窗、多圖、隔夜與其他主機需各自實測，不能從短時間成功推論長期可靠。Teams 登入過期／MFA 需人工處理。
- 系統睡眠期間沒有程式執行；喚醒受硬體、電源與公司政策限制。防睡眠請求無法阻止手動睡眠、闔蓋、登出或斷電。
- 死碼盤點（2026-11-12）：以 PowerShell 語法樹建立呼叫圖（指令、字串中的函式名、`function:` 變數），306 個函式全部可從進入點到達；網頁與內嵌 JS 函式、本機服務 API、CSS class 也都有使用者。已移除：`sample_data.js`（1.47 MB，只供 file:// 離線示範，卻在每次開設定頁時載入）、主程式未使用的 `-CountdownSeconds`、`Format-E3ReceiverText -ImageReply`、`Capture-PagesNative` 未讀取的 `$proc`。刻意保留的舊相容程式（需確認公司主機狀態才能刪）：`Get-E3CdpRecordRoot` 的舊紀錄搬移（`%LOCALAPPDATA%\E3TeamsCdpSendTest\blocked|review` 存在時才執行）、`Connect-E3CdpTarget`／`teams_self_test.ps1` 白名單中的舊 runtime 版本、舊設定格式相容（缺 `schedules`／`messages`／`auth`、`48:notes` 連結、`capture_only`）。一般視窗傳送（UIA，約 460 行）目前設定未使用（`prefer_window=cdp`），但仍是設定頁可選的功能，不是死碼。
- 問法辨識是固定規則，不是 AI：沒列到的說法會回「看不懂」與用法；新增說法要改 `Resolve-E3ReceiverRequest` 的字詞清單並補 `test_receiver_queries.ps1`。檢查與排程使用同一把擷取鎖，排程執行中最多等 3 分鐘。連線測試不帶 Windows 認證，使用整合驗證的網站會回 401（仍視為連得到）。Zabbix API、資料庫、檔案查詢尚未實作（等待使用者提供連線方式與實際問題）。
- 接收端：主機重開後需登入 Windows 任務才會執行；深層連結在有視窗 Edge 對「自己」對話可能先到 launcher 頁（改以名稱選取），實際行為需 A 主機驗證；群組沒有發送者白名單，任何成員都能下指令；排程與接收端使用兩份不同的 Teams 登入。
- 設定工具在視窗寬度約 900px 以下時三欄會擠壓、標題逐字換行（未做窄螢幕版面）。手冊另有窄螢幕版面；截圖展示桌面設定介面。
- CDP 設定按鈕只在啟動請求期間停用；後端每次請求仍可開一個設定 PowerShell，mutex 只序列化工作，不去除重複請求。同名綁定覆寫原紀錄，但連按仍可能留下多個等待程序，尚未做設定流程單一實例防護。
- 接收端的單一工作分頁、對話內切換、容錯讀取、無視窗啟動與監看重啟，目前只有本機模擬測試；真實 Teams 的行為（聊天清單項目的名稱比對、連結開啟後是否停在最新、多對話切換速度、長時間無視窗、鎖定螢幕時有視窗模式是否持續更新）需在公司主機實測。多對話時每個對話約 2～3 秒（估計），指令延遲隨對話數增加。輪讀會把這些對話標為已讀。防睡眠／自動復原不保證網路或 Teams 永久有效；能讀到頁面不等於 Teams 服務在線。登入過期、MFA、關機、睡眠、登出 Windows 無法自動處理。
- Windows Server 可擷取與判定；UIA 操作 Teams 需有人登入且解鎖；CDP 在 Server 未驗證。
- 失敗說明、中斷與離線通知、代發、接收端視窗紀錄與啟動檔案檢查（2026-11-12）只有本機模擬測試，需在公司主機實測：說明訊息實際送達、長時間 `Start-Transcript` 的檔案大小與換日、代發到預設對話的內容。接收端與排程兩份 Teams 登入同時失效、主機關機／睡眠／無人登入 Windows 時，仍然沒有任何通知管道。指令紀錄與事件紀錄含指令文字（原本就存在 `commands\`），保留 30 天。代發會把指令文字送到 `teams.target_chat_name`（與原對話可能不同）。
