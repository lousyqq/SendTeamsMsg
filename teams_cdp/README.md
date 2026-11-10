# 工作紀錄改存專案 logs（2026-11-10）



blocked/review 改用 Get-E3CdpRecordRoot → 專案 logs/teams_cdp。原 AppData 下的兩個紀錄目錄會在首次存取時持有 CDP 共用 mutex 搬移，逐檔複製／同步寫入／SHA-256 核對後才移除原檔。衝突內容保留在 review/migration_conflicts，不覆寫現有阻擋；失敗保留原檔，不因搬移解除待確認或重送。



登入 profile、bindings.json、session.json 仍在原 AppData，傳送收據維持 logs/日期/receipts。更新須停止舊工具／worker；不需重新綁定。test_cdp_record_storage.ps1 使用隔離測試狀態，不操作公司 Teams。
# 原始 Edge 輸出預設不落檔（2026-11-10）



正常啟動會非同步丟棄 Edge stdout/stderr，不建立原始 log，也不混入應用程式狀態。僅 E3_EDGE_RAW_LOGS=1 時保留原始輸出。傳送收據與 startup 失敗摘要仍保存；登入與 CDP 綁定不變。



# 2026-11-11 送出後文字核對（receipttext1）



修正 Teams 將 Unicode 警告符號等轉成有標記的 emoji 圖片後，讀取正文漏字而出現 message_text_mismatch 的問題。不同文字或符號仍不能通過。收據增加不含正文的差異診斷；伺服器接受與畫面核對分別記錄。已接受但未核對者保留 uncertain、不重送，錯誤說明不再讓人誤以為尚未按送出。本機模擬通過不代表使用者這筆實際 DOM 差異已確定；公司 Teams 仍需現場確認。
# 2026-11-10 訊息尾端空白（captionspace1）



修正 Teams 省略訊息最後空白造成 textMatches 失敗。僅容許整段文字末尾 space／Tab 差異，正文、真正換行、圖片及收件者仍核對；不修改已儲存訊息文字，不重貼或重送。有視窗／無視窗 CDP 共用此修正，包含 allmodes1 恢復處理。本機隔離 Edge／loopback 已驗證；公司 Teams 仍需實際收件確認。
# 2026-11-10 所有 CDP 模式（allmodes1）



有視窗與無視窗的正式 CDP 傳送現在都會先停止前次 runtime、核對綁定並清除目標草稿。已確認尚未按送出的失敗，也會嘗試清理半成品。有視窗模式保留原瀏覽器，只操作已綁定分頁；檢查連線不刪草稿。



所有傳送方式的排程工作最多執行 10 分鐘；底層呼叫無回應時會結束該 worker 並釋放執行鎖，保留紀錄且不自動重送。該輪剩餘工作隨之終止；下一輪依原觸發執行。等待上一筆及 UIA 桌面解鎖都縮短至最多 30 秒。這是避免持續占住工作的措施，不保證斷網或登入失效時能送達。



# 2026-11-10 排程準備與啟動恢復（preparation1）



正式無視窗傳送取得傳送鎖後，會先結束上次遺留的專用無視窗 Edge，再核對目標並清除草稿；登入檔與已送訊息保留。檢查連線不做清理，有視窗設定 Edge 請正常關閉。另一個仍執行中的傳送不會被強制中斷。



啟動時等待 DevToolsActivePort 寫入完成且端點一致，不因短暫檔案占用就失敗。貼圖前的文字準備等到完整內容穩定，最多 5 秒；不重貼。若本次明確未按送出，失敗後會清除半成品草稿，清理證據在收據旁的 .draft-cleanup.json；下次只準備新工作。已按送出或結果不明仍保留紀錄，不重送。



本機已重現檔案鎖與非同步文字，並完成前筆失敗、後筆恢復的隔離 loopback 測試；公司 Teams／實際排程主機仍需測試。



# 2026-11-09 送出前聊天紀錄檢查（preflight1）



貼圖後聊天紀錄可能重新載入。送出前遇到短暫讀取失敗會只重讀最多 2.5 秒，不重貼或重送。相同文字的新出現列若時間嚴格早於原最新訊息，視為舊紀錄；同時或較新仍停止。等待後重新核對對象及輸入內容。



log 的 preSend 會區分讀取失敗與新同文衝突；not_clicked 表示尚未按 Teams 送出，並非伺服器拒絕訊息。舊版的合併錯誤不足以分辨這兩種原因。此修正已用本機瀏覽器與 loopback 模擬傳送驗證，公司環境仍需實測。



# 2026-11-09 無視窗新工作清除舊草稿（discard1）



- 依使用者指示，無視窗正式傳送（含傳給自己）在核對目標身分及專用瀏覽器、確認舊工作停止後，自動移除輸入框舊文字、圖片與附件，再傳送本次內容。不刪除已送出聊天紀錄，不補送舊工作。
- 以原生編輯鍵通知 Teams 更新輸入資料，外部附件只點草稿區內的移除按鈕；空白持續一秒及 pending rows 核對後才開始新工作。仍有傳送中訊息、焦點／身分變動、未知附件、編輯已送訊息、無法停止舊 runtime 等情況不繼續。
- 舊 blocked 紀錄以原始 bytes 移至 review/discard_*.pending.json，保留原收據及不確定結果；新送達仍要求原本的嚴格確認。連線檢查、DryRun、設定綁定不刪草稿。有視窗模式沿用下方 pending2 的保守處理。
- 本機隔離 Edge 與傳送邊界替身已驗證；未在公司 Teams 實測。更新時保留登入、綁定、config 與收據，無需重建 Windows 任務。



# 2026-11-06 舊工作封存、新工作檢查後繼續（pending2，有視窗模式）



本節取代較早版本「同一聊天室只要有 blocked 就一律停止正式傳送」的規則；舊工作不會自動補送，也不會自動當作成功。



- 正式 Send-GroupToTeamsCdp 在共用 Mutex 內連線並驗證帳號／聊天室，首批建立新的工作 ID，再檢查舊 blocked。必須確認目前 runtime idle／finished，以及舊工作有終止收據、同 ID 已結束 runtime、原 endpoint 已 idle，或新建的專用 profile 瀏覽器（啟動前已排除舊程序占用）。缺少停止證據仍停止；已取消／過期可最多等 3 秒終止，不推進舊傳送。
- 再以 resume-check.js 驗證固定身分與目前已載入的訊息列沒有 sending／pending，並要求輸入框唯一、無文字、圖片或附件。不能據此宣稱 Teams 隱藏佇列或遠端傳送絕對不存在；不取消 Teams 佇列、不自動刪草稿。
- 通過後先寫 logs/teams_cdp/review/<舊ID>_<唯一值>.review.json，保留舊收據快照、原 runtime、停止依據及新工作 ID，再以同磁碟原子移動保留原 blocked 為同名 .pending.json。舊收據不改寫；無相符伺服器成功證據者保留 pending_manual_review。讀寫失敗、紀錄改變、身分／草稿／pending／active 均保留阻擋、不貼圖、不送出。
- 此流程只處理目前傳入的新內容，不讀取或補送舊圖片／文字；新批次仍受原本帳號、圖片、serverack、receipt2 與防重送檢查。新工作失敗仍留下自己的 blocked，後續新工作再重新检查。相同舊／新 ID 明確拒絕。
- 「檢查 CDP 連線」維持只讀、不解除 blocked。2026-11-09 起，兩個「傳給自己」按鈕在使用者確認與本人身分重驗後，也共用正式新工作的恢復判斷；舊工作已停止且沒有草稿／傳送中訊息就執行本次內容，不等待舊結果變成功。設定綁定原有人工核對流程不變。
- 本次 host 新功能不修改 runtime 版本（仍 receipt2），支援既有 headless1／optionaltext1／receipt2 runtime；resume-check 腳本按需執行。無需因本次功能關閉／重綁有視窗分頁。尚未套用前版 receipt2 的分頁，若要取得圖片穩定性診斷，仍需核對後自行重新整理。
- 更新包 SendTeamsMsg_CDP_Pending_Recovery_Update.zip。保留 config.json、sample_images、sample_data.js、edge_profile、captures、logs、Windows 排程及完整 %LOCALAPPDATA%/E3TeamsCdpSendTest（登入與綁定；review 改在專案 logs/teams_cdp）。測試見 tools/validation_pending_recovery/RESULT.md；未傳真實 Teams、未做 Win+L 實機驗收。



# 2026-11-06 CDP 送出後穩定核對（receipt2）



- 修正 host 收到相符的伺服器確認後，只讀一次 DOM 就判定失敗的競態。現在最多等 12 秒反覆核對同一 messageId，連續通過至少 1.5 秒才完成；沒有重貼、重按送出或只靠 HTTP 201 成功。帳號／聊天室改變、明確傳送失敗及相異 messageId 立即停止。
- receipt.js 對圖片來源或尺寸變更重新計算穩定時間；pending／草稿／身分失敗也清除先前穩定候選。仍保留逐張比例、順序、張數、載入完成、文字、時間、帳號、聊天室及相符伺服器確認。永久裁切縮圖或仍不相符會保留 uncertain，未以放寬比例規則掩蓋問題。
- 收據新增 receipt.images（預期／實際尺寸、比例符合、張數）與 finalReceiptHistory（核對原因轉換），不記錄圖片 URL、正文、token 或圖片內容。runtime 版本 receipt2；舊 headless1／optionaltext1 分頁相容 host 等待，但新增尺寸診斷與圖片穩定性檢查要核對草稿後手動重新整理原分頁。headless 下次啟動自動載入新版。
- 本機隔離 headless Edge＋loopback HTTP 模擬 4 圖：先形成 DOM 收據，3.5 秒換錯誤比例，5 秒回 HTTP 201，7 秒恢復。舊版重現 image_shape_mismatch；新版等待恢復。負面案例檢查永久不符、缺圖、文字變更、聊天室改變、傳送失敗均保留阻擋且下一排程不開瀏覽器／不重送。詳見 tools/validation_receipt_recheck/RESULT.md。
- 更新包 SendTeamsMsg_CDP_Receipt_Fix.zip；保留 config.json、sample_images、sample_data.js、edge_profile、captures、logs、Windows 排程及整個 %LOCALAPPDATA%/E3TeamsCdpSendTest。既有 blocked 不自動清除，需使用者核對原訊息與草稿後再以「設定 CDP 收件對象」重新確認。未在公司 Teams 或 Windows 鎖定環境重現，不保證原故障一定是短暫縮圖變動。



## 2026-11-06 optionaltext1：可只傳圖片



訊息開頭、預設內容、正常／異常文字全部選填。純圖片跳過文字貼上，不加入預設訊息或批次文字；仍驗證圖片內容、順序、身分及伺服器收據。
既有 headless1 分頁可繼續傳有文字的訊息；若純圖片被版本檢查擋下，先核對草稿及已送訊息，重新整理原分頁並回到綁定對話。不自動重整、不清除登入資料，分頁 ID 未變不需重綁。新建分頁會直接載入新版。
本次使用本機 Edge fixture 驗證，未傳真實 Teams。



# 正式 CDP Teams 傳送模組



版本：2026-11-05-headless1。由主引擎載入 Delivery.ps1，無外掛、無 Windows 剪貼簿或 SendKeys。



## 模式選擇



設定收件對象時，若專用 Edge 仍在背景占用登入資料，現在會顯示 PID 並詢問「是否關閉上述專用 Edge 並重新開啟？」。輸入 `Y` 才會先正常關閉，必要時強制結束已確認的專用程序，然後接續設定；Enter 或其他輸入取消。日常 Edge 與名稱相近的其他 profile 不會被關閉，不刪除登入資料。



重啟會關閉該專用 Edge 的全部分頁，其他使用分頁模式的收件對象需重新綁定。待核對傳送紀錄仍保留，不會重送；如果重新綁定的對象有待核對紀錄，請先核對已送訊息／草稿，再按提示輸入 `CHECKED`。排程、連線檢查不會自動踢掉 Edge；正在傳送或另一個設定尚未完成時仍停止。



建議先使用保留專用 Edge 的模式：在設定工具選 CDP，取消勾選「使用無視窗 Edge 傳送」，儲存後綁定收件對象，保留專用分頁。使用者已確認其實際主機在 Windows 隔夜鎖定後仍可發送；不能外推其他主機或登入永不過期。無視窗模式請先在實際主機驗證。



相容舊設定：`teams.cdp_headless` 未設定時程式仍視為 true；false 使用常駐分頁。本次只統一操作建議，不修改既有設定或綁定。一般 auto／PWA／桌面傳送不受影響。



使用 `%LOCALAPPDATA%\E3TeamsCdpSendTest\profile`，不共用截圖 `edge_profile`。先在解鎖時設定登入及收件對象；核對實際帳號、聊天室後輸入 BIND，輸入框空白才儲存並關閉設定 Edge。無視窗模式會隨即重新啟動 headless Edge，核對登入、帳號、聊天室與空白輸入框，再正常關閉；全部通過才顯示驗證完成。不貼圖、不送出。驗證失敗會明確指出「綁定已儲存，但無視窗驗證失敗」，保留綁定供修復後再檢查。取消無視窗模式時保留原常駐分頁，不做此重啟檢查。已有完整綁定可直接檢查連線，不必每次重綁。



排程依保存的 chatId 開啟 Teams；必要時回首頁選取完整相符的對話名称，同名候選不唯一則停止。貼上前由既有 adapter 嚴格核對 accountId、chatId、label。新瀏覽器的 targetId 僅供這次連線，不覆寫持久綁定。每個對象全部批次完成或失敗後正常關閉 Browser.close；同一 profile 正被使用就停止，不搶用或強制關閉既有瀏覽器。



登入轉址容許短暫 SSO；登入過期、MFA、頁面不相容或聊天室無法確認時停止，請解鎖後重新設定。取消無視窗可回舊分頁模式，但需重新綁定並保持專用分頁開啟。



## 傳送與防重送



- 共用 teams_delivery.ps1，每批最多 4 圖／25 MiB，單張最多 10 MiB。全部圖片預檢後才開始；順序與總結文字沿用。
- 背景 Page active、Emulation focus、關閉背景節流及 DOM composer focus；最長 30 秒等整批圖片被編輯器接受。仍需畫素／hash、順序、model ready 及送出後新訊息證據。
- 每筆開始先 reset receipt 並記錄工作 ID，避免引用前筆 confirmed_new_row。failedChecks 與 editor 的預期／實際／已載入／驗證圖片數供診斷。
- headless runtime.start 前寫入 blocked 下按帳號與 chatId 雜湊命名的 JSON。只有 confirmed sent 才清除；not_sent、uncertain、斷線或程序中斷都會留下待核對狀態，下次排程在啟動瀏覽器前停止。切回分頁模式也不能繞過既有阻擋。
- 請先人工核對已送訊息與草稿，再重新 BIND；空白編輯器確認通過後才解除待核對狀態。不要刪除紀錄或盲目補跑。
- 舊分頁模式仍使用 ID／到期時間／取消／recover，只有 cancelled／expired 且 finished 後可 reset，不重播舊工作。



## 檔案與驗證



目錄只需兩個檔案：



- `Delivery.ps1`：完整正式程式，依 Transport、Owned browser lifecycle、Binding and delivery、Browser scripts 四個 region 排列。包含 CDP 連線、瀏覽器生命週期、綁定、傳送、七段網頁腳本與全部核對。
- `README.md`：操作、部署、維護及來源說明。



主程式入口不變，仍載入 Delivery.ps1。共同分批規則使用根目錄 teams_delivery.ps1。網頁腳本由 Get-E3CdpRuntimeSource 依區段識別取得；原本的 runtime.js、navigation.js、vendor/adapter.js 等字串是內嵌區段名稱，不再讀取實體檔案。單引號 here-string 保留 JavaScript 原文，不進行 PowerShell 變數展開，也不會在執行時解壓出額外檔案。



此為 compact1 檔案整理，網頁 runtime 版本維持 2026-11-05-headless1，七段腳本內容不變；不因合併檔案而要求重綁。修改實際控制行為時仍須同步更新 runtime 與 host 版本。



升級時先正常結束排程及 CDP 設定，將舊專案的 teams_cdp 目錄移至備份，再放入新版兩個檔案；純覆蓋不會自動清除舊分散檔案。不要移動或清除 LOCALAPPDATA 的正式登入與綁定狀態。



「檢查 CDP 連線」會依設定中的預設收件人、啟用頁面及啟用排程覆寫對象逐一檢查，去除重複名稱並保留大小寫區分。未綁定、帳號或聊天室不符、有草稿、待核對阻擋等原因都會逐項列出；其中一項失敗仍繼續檢查下一項，不檢查已從設定移除的舊綁定。全部沒有設定對象時視為失敗。



兩種模式都核對實際帳號、聊天室與空白輸入框；headless 用完即關閉，分頁模式保留原 Edge。檢查不會貼圖、送出或清除待核對阻擋。Test-E3CdpConnection -PassThru 提供 ok/results/lines，主引擎保存完整報告並於任一失敗時回傳 exit 1。一般呼叫仍輸出可讀文字。DryRun 仍只做本機 PNG 與綁定檢查。



設定工具的訊息預覽按收件對象、圖片原順序與每批 4 張／25 MiB 拆成多則卡片，每則含相同總結，多批才附批次序號。尺寸以目前預覽 PNG 為估算，排程當次圖片大小、警戒線標記及擷取失敗可能改變分批；缺圖／超過單張上限會顯示待確認提示。



本機驗證見 tools/validation_cdp_headless_20261105：loopback 網頁、獨立 Edge profile，不連真實 Teams。登入 cookie 跨重啟、四圖與防重送測試通過，不代表租戶登入、公司政策或 Win+L 已驗收；請在排程主機測試並從手機確認所有附件。



更新需保留 config.json、sample_images、edge_profile 與整個 %LOCALAPPDATA%\E3TeamsCdpSendTest。收據在 receipts\日期，阻擋在 blocked，登入在 profile。Windows 需維持登入及運作，网络與 Teams 登入有效；未驗證 Windows 登出或跨帳號執行。





## 來源與歷史調整（原 SOURCE_NOTES.md）





多圖更新：原單圖模組延伸為最多 4 張、25 MiB 的批次，保留逐張 hash 與畫素檢查、編輯器順序／張數及 model 全部完成核對；一個多檔 DataTransfer，一次送出。原 adapter 的單圖正文樹辨識延伸為多個圖片段落，receipt 核對整批附件。實機多檔貼上相容性待驗收。



正式整合版新增 Delivery.ps1 與 receipt.js。保留送出前圖片 hash／畫素／model ready，送出後在原圖不可讀或變為縮圖時用新穩定訊息、時間、完整文字、附件及狀態核對。此為 DOM 回讀，不等同伺服器 API 確認。允許使用者明確綁定群組聊天室，仍要求帳號證據與固定 chatId／標題；不靠同名自動搜尋。



來源：使用者提供的 `D:\00058897\測試用\teams\46518_Teams與Skills完整來源.zip`，
內部 `teams-bridge/extension/adapter.js`、`outbound-images.js`、`image-frame-bootstrap.js`，來源版本 1.0.36。



本包只沿用網頁編輯器、圖片完整性核對與有界背景動畫處理。不安裝來源擴充功能、Native Messaging、AI runner 或其排程。



調整：
- 0.2 修正初次綁定時帳號選單尚未開啟：PowerShell 驅動 beginBinding／有界輪詢／endBinding，自動開啟一次並收起自己開啟的選單。保留原始帳號與本人對話驗證，不要求使用者在回到 console 時維持選單。
- adapter 僅接受本測試的 body-v1／output-image-v1，不要求 Codex 前綴或圖示。
- 圖片驗證即使沒有 Codex 圖示也執行；完整多行圖片說明使用 imageBodyText 保留換行。
- 真正按送出前增加 PowerShell 端持久化記錄、期限／桌面狀態再檢查，之後再次同步核對綁定、草稿與按鈕。
- frame bootstrap 的有效期間由 5 秒改為 60 秒，仍有超時且可停止；不會啟用分頁或解除鎖定。
- runtime 在 CDP isolated world 執行；等待由本機 CDP 輪詢推進，MAIN world 僅處理有界動畫與讀取圖片 model ready。



本機 fixture 驗證不代表 Microsoft Teams 真實租戶或 Windows 鎖定驗收。相關結果見專案 tools/validation_cdp_send_20261104。





2026-11-05 background1: added CDP focus emulation and renderer background flags; scoped receipt state to each delivery; retained content/account/image/model guards and single-click policy; added bounded 30-second image processing wait and content-free editor diagnostics. Local fixtures now cover real Chromium hidden-target focus, delayed four-image paste, edited drafts, and sequential-job receipts. Real Windows lock and tenant delivery remain unverified.





2026-11-05 headless1: Added Headless.ps1 and navigation.js, adopting the NEW project's per-run headless lifecycle concept. Retained this project's independent Teams profile, strict account/chat identity, pixel/model/receipt guards, and cancellation recovery. Added durable per-destination pending blocks across browser restarts. No NEW runtime or weaker send-success criteria were copied. Navigation uses saved chat ID and exact-label fallback followed by strict identity verification. Loopback fixtures do not establish live tenant or Windows lock acceptance.





2026-11-05 workflow1：新增逐批預覽、綁定後 headless 驗證、設定對象完整檢查。teams_cdp 仍只有 Delivery.ps1／README.md，內嵌傳送腳本與 runtime headless1 不變。部署包：SendTeamsMsg_CDP_Compact_v2.zip。





## Edge 原始診斷（diagnostics1）



Start-E3TestBrowser 將原始 stderr/stdout 分別寫入專案目錄下的 `logs/日期`，正式位置為 `專案目錄\logs`。每次啟動採時間＋GUID 檔名；主控台顯示 stderr 紀錄位置，DevTools／EDGE_IDENTITY／Chromium 內部 ERROR 不再混入檢查結果。未降低日誌等級，也未停用 Edge 身分功能。



這項調整處理輸出顯示，不表示 Chromium 內部問題已修復。仍由原核對條件判斷成功；真正的啟動、登入與傳送錯誤持續回報。啟動失敗訊息保留原原因與診斷目錄，並清理僅本次建立的瀏覽器。stdoutLog/stderrLog 隨 browser 結果回傳；日誌不會自動刪除。程式碼仍只有兩個檔案，測試 profile 的日誌留在 TEMP，不寫正式狀態。



部署包：SendTeamsMsg_CDP_Compact_v8.zip；登入、收件綁定及防重送狀態保留，不必因診斷顯示調整重綁。



## 伺服器確認（serverack1）



PowerShell host 將 DOM 收件視為暫定，另被動觀察同聊天室 messages POST 的 HTTP 200/201 完成回應與資源 ID，關聯本次訊息 ID；收到後再核對畫面。最多額外等待 45 秒，不重送。沒有相符確認、202、失敗、快取或重新導向都不回報成功；不支援的訊息 API 也保守停止。此機制證明支援端點已接受訊息，不能代替手機／另一端同步驗收。



新的收據在專案 `logs/日期/receipts/工作ID.json`，附 serverReceipt 與不含正文、cookie、headers、URL 的 network 摘要。所有 CDP 模式都保留結果不明的防重送檔；帳號與登入狀態位置不變。更新包為 SendTeamsMsg_CDP_Compact_v8.zip。



## 載入逾時恢復（navigation1）



載入探測最多等 30 秒，總等待 120 秒；Socket 逾時失效時，最多重連原分頁兩次。只有傳送前的導航階段可恢復，不重播傳送指令。失去導航回覆時只重連再檢查，不重複導航。聊天室清單／選取已有進度時不跳回首頁；未知 JS 錯誤立即回報。



啟動失敗診斷在 `logs/日期/startup_工作ID.json`，記錄階段、最後 CDP 指令、錯誤及 Edge log 路徑，不記錄指令參數或頁面正文。新版仍沿用帳號與聊天 ID 核對，仍需在原主機驗證 headless；更新包 SendTeamsMsg_CDP_Compact_v8.zip。



## 未辨識端點診斷（endpoint1）



`network[].endpoint` 含 host、遮蔽任意識別值的 route 樣板與 classification；另附 method、sequence、hasPostData、observedAfterClickCheckpoint。保存路徑固定字詞，隱藏 query、帳號、聊天 ID、header、body。PUT/PATCH 僅記錄，成功資格仍限原本的 POST。



desktopAtStart、desktopBeforeClick、desktop 分別表示開始／按送出前／結束時的桌面快照。未知端點回覆 201 仍保持 uncertain，不重送。v7 是診斷補強，不能據此宣稱 headless 實機傳送已修好。



## Worker 網路確認（worker1）



透過目前分頁的 Target.setAutoAttach（flatten=true、不暫停）觀察關聯 Worker；各 Worker 使用獨立 session 開啟 Network，取得回應內容時使用原 session。附加事件只排入佇列，由外層迴圈初始化，避免巢狀 receive 吃掉指令回覆。請求以 session+request ID 區分，收據可查 workerObserver 與 network[].source。



未擴張未知端點的送達資格。主頁面的 objects 建立／上傳 201 不是訊息確認。包為 SendTeamsMsg_CDP_Compact_v8.zip。



2026-11-05 15:06 實機驗證：保留有視窗 Teams Edge，開始／送出前／結束均為 Windows 桌面 unavailable；Worker 訊息 POST 201、DOM 核對及使用者手機收件確認均通過（1 則文字＋1 張測試圖）。只證實本機此模式；headless 尚未做同等真人鎖定驗收。正式配置與登入資料未改動。



### 2026-11-06 排程多收件對象



`Get-E3ConfiguredRoutes` 使用共用 `Get-TeamsScheduleTargets`，列出所有啟用排程 target_chat_names；缺新欄位才讀舊 target_chat_name。去空白／重複且保留大小寫差異。各收件名稱分別 BIND，同一專用 Edge 保留多個分頁，不需要每個排程一個視窗。設定及連線檢查涵蓋全部名稱，個別失敗或 blocked 不影響後續項目檢查。清單只擴充設定／路由列舉，瀏覽器 runtime 與七段內嵌 JS 未變，既有對象不因本次更新重綁。
 