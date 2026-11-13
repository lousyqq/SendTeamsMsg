param(
    [int]$PageLoadMilliseconds = 4500
)
# ==============================================================================
# 重新產生 USER_MANUAL.html 的 14 張設定工具截圖（calibrator.html 介面改版後執行一次）
#
# 資料來源（只讀，不修改）：
#   - 專案目前的 config.json：頁面、分類、排程、收件名稱、規則都以實際設定顯示
#     （網站帳號與密碼一律改成固定遮罩字串；空白收件項目先移除，避免示範頁觸發自動儲存）
#   - 專案目前的 sample_images\：每頁 <id>_full.png／<id>.png 實際截圖
#   - 數值門檻：本機 numeric_monitor.ps1 以 Windows OCR 對上述實際圖片試算，結果注入設定頁
#   - Windows 排程同步狀態、CDP 綁定、手機遙控心跳、CDP 檢查結果：依目前設定產生的示範狀態
#
# 隔離方式：
#   - 不啟動正式設定服務、不載入 e3_monitor_native.ps1；以獨立暫存 profile 啟動 headless Edge，
#     除錯埠由 Edge 隨機選擇（--remote-debugging-port=0），不需關閉正式設定工具
#   - 以 CDP Fetch 攔截頁面所有請求，直接由記憶體回應；任何請求都不會連到真正的 127.0.0.1:8765
#   - 只回應 GET；POST 等寫入／執行請求一律回 403（不存檔、不註冊排程、不送 Teams）
#   - 14 張全部成功且與手冊 <img data-shot> 完全一致時，才以暫存檔 + File.Replace 原子替換
#     手冊的 MANUAL_IMAGES 區塊；暫存資料夾保留原手冊與 PNG 供核對
# ==============================================================================
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$here = $PSScriptRoot
$root = Split-Path $here -Parent
$manual = Join-Path $root 'USER_MANUAL.html'
$configPath = Join-Path $root 'config.json'
$imageDir = Join-Path $root 'sample_images'
$work = Join-Path $env:TEMP ('e3_manual_shots_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
$shotDir = Join-Path $work 'shots'
$profileDir = Join-Path $work 'edge_profile'
$origin = 'http://127.0.0.1:8765'
[void][IO.Directory]::CreateDirectory($shotDir)
Copy-Item -LiteralPath $manual -Destination (Join-Path $work 'USER_MANUAL.original.html')

# ---- 1. 讀取目前設定（只讀）並準備示範用副本 ----
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$configText = $utf8.GetString([IO.File]::ReadAllBytes($configPath))
if ($configText.Length -and $configText[0] -eq [char]0xFEFF) { $configText = $configText.Substring(1) }
if ($configText.Contains([char]0x00A0)) { throw 'config.json 含 NBSP（特殊空白），請先修正再產生手冊截圖' }
$cfg = $configText | ConvertFrom-Json
if (-not $cfg.pages -or -not @($cfg.pages).Count) { throw 'config.json 沒有任何頁面' }
$mask = '********'
function Hide-Credential($auth) { if ($auth -and $auth.username) { $auth.username = $mask }; if ($auth -and $auth.password) { $auth.password = $mask } }
Hide-Credential $cfg.auth
foreach ($p in $cfg.pages) { Hide-Credential $p.auth }
foreach ($s in @($cfg.schedules)) {
    if ($s -and $s.PSObject.Properties['target_chat_names']) {
        $names = [Collections.Generic.List[string]]::new()
        foreach ($n in @($s.target_chat_names)) { if ($n -is [string] -and $n.Trim() -and -not $names.Contains($n)) { $names.Add($n) } }
        $s.target_chat_names = [string[]]$names.ToArray()
    }
}
$demoConfigJson = $cfg | ConvertTo-Json -Depth 32
$demoConfigBytes = [Text.Encoding]::UTF8.GetBytes($demoConfigJson)
foreach ($p in $cfg.pages) {
    if (-not (Test-Path -LiteralPath (Join-Path $imageDir "$($p.id)_full.png")) -and -not (Test-Path -LiteralPath (Join-Path $imageDir "$($p.id).png"))) {
        Write-Host "⚠️ $($p.name) 沒有 sample_images 圖片，截圖中會顯示「這一頁還沒有畫面」" -ForegroundColor Yellow
    }
}

# 依目前設定產生示範狀態（不讀取 Windows 任務、不連 Teams）
function Get-NextRun($s, [datetime]$now) {
    $start = [datetime]::ParseExact(([string]$s.time).PadLeft(5, '0'), 'HH:mm', $null)
    $days = @($s.days)
    for ($d = 0; $d -le 8; $d++) {
        $date = $now.Date.AddDays($d)
        if ($days.Count -and $days -notcontains $date.DayOfWeek.ToString().Substring(0, 3).ToUpperInvariant()) { continue }
        $first = $date.Add($start.TimeOfDay)
        $times = @($first)
        if ($s.repeat -and $s.repeat.enabled -eq $true) {
            $step = [int]$s.repeat.every * $(if ($s.repeat.unit -eq 'hours') { 60 } else { 1 })
            $end = $date.Add([datetime]::ParseExact(([string]$s.repeat.end_time).PadLeft(5, '0'), 'HH:mm', $null).TimeOfDay)
            if ($end -le $first) { $end = $end.AddDays(1) }
            $times = @(); for ($t = $first; $t -lt $end; $t = $t.AddMinutes($step)) { $times += $t }
        }
        foreach ($t in $times) { if ($t -gt $now) { return $t.ToString('MM/dd HH:mm') } }
    }
    return ''
}
$now = Get-Date
$tasks = @(foreach ($s in @($cfg.schedules)) {
    if (-not $s -or $s.enabled -eq $false) { continue }
    $repeat = $s.repeat -and $s.repeat.enabled -eq $true
    @{ id = $s.id; task_name = $(if ([string]$s.name -and ([string]$s.name).Trim()) { ([string]$s.name).Trim() } else { [string]$s.id }); task_path = '\'
       enabled = $true; wake = $true; catch_up = $true; state = 'Ready'; next = (Get-NextRun $s $now)
       # 示範狀態：上次執行時間取最近一次的開始時刻，結果固定為「已送出」
       last = @{ at = $(try { $t = $now.Date.Add([datetime]::ParseExact(([string]$s.time).PadLeft(5, '0'), 'HH:mm', $null).TimeOfDay); if ($t -gt $now) { $t = $t.AddDays(-1) }; $t.ToString('MM/dd HH:mm') } catch { '' }); status = 'ok'; text = '已送出'; reason = '' }
       schedule = @{ supported = $true; time = ([string]$s.time).PadLeft(5, '0'); days = @($s.days)
                     repeat_interval_minutes = $(if ($repeat) { [int]$s.repeat.every * $(if ($s.repeat.unit -eq 'hours') { 60 } else { 1 }) } else { 0 })
                     end_time = $(if ($repeat) { ([string]$s.repeat.end_time).PadLeft(5, '0') } else { '' }) } }
})
$routes = [Collections.Generic.List[string]]::new()
foreach ($n in @([string]$cfg.teams.target_chat_name) + @($cfg.schedules | ForEach-Object { @($_.target_chat_names) })) {
    if ($n -is [string] -and $n.Trim() -and -not $routes.Contains($n.Trim())) { $routes.Add($n.Trim()) }
}
$selfRoute = if ($routes.Count) { $routes[0] } else { '自己' }
$utc = { param([int]$minutesAgo) [DateTime]::UtcNow.AddMinutes(-$minutesAgo).ToString('o') }
$api = @{
    '/api/schedule-status' = @{ ok = $true; tasks = $tasks }
    '/api/cdp-bindings'    = @{ ok = $true; targets = @($routes | ForEach-Object { @{ route = $_; label = $_; complete = $true; windowConfigured = $false } }) }
    '/api/receiver-control' = @{ ok = $true; running = $true; setupOpen = $false }
    '/api/receiver-status' = @{ ok = $true
        heartbeat = @{ exists = $true; alive = $true; state = 'listening'; computer = '監控主機'; startedUtc = (& $utc 185); utc = (& $utc 1); sleepGuard = $true; mode = $(if ($cfg.teams.receiver_headless -eq $true) { 'headless' } else { 'window' }); intentional = $false
                       reloadMinutes = $(if ($null -ne $cfg.teams.receiver_reload_minutes) { [int]$cfg.teams.receiver_reload_minutes } else { 240 })
                       sources = @(@{ route = $selfRoute; active = $true; lastOkUtc = (& $utc 1); error = $null }) }
        health = @{ ok = $true; reason = '' }; senderLogin = @{ checked = $true; ok = $true; lastCheckUtc = (& $utc 95) }
        pendingNotices = 0; watchdog = @{ alerted = $false }; autoRestart = @{ count = 0 }
        privilege = @{ receiver = $false; watchdog = $false; mismatch = $false; text = '一致（皆為一般權限）' }
        tasks = @{ watchdog = @{ registered = $true; enabled = $true; next = $now.AddMinutes(7).ToString('MM/dd HH:mm') }; autostart = @{ registered = $true; enabled = $true } } }
    '/api/work-waits'       = @()
    '/api/test-self-active' = @()
    '/api/capture-status'   = @{ state = 'idle' }
}
$detectReport = (@("🔍 CDP 設定檢查（$(if ($cfg.teams.cdp_headless -ne $false) { '無視窗模式' } else { '分頁模式' })）") +
    @($routes | ForEach-Object { "✅ $($_)：已設定完成（登入與收件對象確認通過）" }) +
    @("✅ CDP 已設定完成（$($routes.Count)/$($routes.Count) 個收件對象通過）")) -join "`n"

# ---- 2. 數值門檻：以本機 OCR 對實際圖片試算（與設定頁 /api/numeric-preview 相同函式，只讀） ----
. (Join-Path $root 'numeric_monitor.ps1')
$numeric = @{}
foreach ($p in $cfg.pages) {
    $rules = @($p.rules)
    if (-not ($rules | Where-Object { $_ -and $_.enabled -ne $false -and $_.measure_mode -eq 'numeric' })) { continue }
    $full = Join-Path $imageDir "$($p.id)_full.png"; $crop = Join-Path $imageDir "$($p.id).png"
    $source = $null; $bitmap = $null
    try {
        if (Test-Path -LiteralPath $full) {
            $source = [Drawing.Bitmap]::FromFile($full)
            $c = $p.crop_region
            $rect = if ($c -and $c.w -gt 0 -and $c.h -gt 0) { [Drawing.Rectangle]::new([int]$c.x, [int]$c.y, [Math]::Min([int]$c.w, $source.Width - [int]$c.x), [Math]::Min([int]$c.h, $source.Height - [int]$c.y)) } else { [Drawing.Rectangle]::new(0, 0, $source.Width, $source.Height) }
            $bitmap = $source.Clone($rect, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
        } elseif (Test-Path -LiteralPath $crop) { $bitmap = [Drawing.Bitmap]::FromFile($crop) } else { continue }
        $numeric[$p.id] = @(foreach ($r in $rules) { if ($r -and $r.enabled -ne $false -and $r.measure_mode -eq 'numeric') { Measure-E3NumericRule $bitmap $r } else { $null } })
        foreach ($res in $numeric[$p.id]) { if ($res) { Write-Host ("🔢 {0}：{1} {2}{3}" -f $p.name, $res.status, $res.detail, $res.reason) } }
    } finally { foreach ($item in @($bitmap, $source)) { if ($item) { $item.Dispose() } } }
}
$numericJson = ConvertTo-Json -InputObject $numeric -Depth 8 -Compress

# ---- 3. 頁面需要的靜態檔（只允許白名單） ----
$static = @{}
foreach ($name in 'calibrator.html', 'work_control.js') {
    $path = Join-Path $root $name
    if (Test-Path -LiteralPath $path) { $static["/$name"] = [IO.File]::ReadAllBytes($path) }
}
foreach ($p in $cfg.pages) {
    foreach ($name in "$($p.id)_full.png", "$($p.id).png", "annotated_$($p.id).png") {
        $path = Join-Path $imageDir $name
        if (Test-Path -LiteralPath $path) { $static["/sample_images/$name"] = [IO.File]::ReadAllBytes($path) }
    }
}
function Get-MimeType([string]$path) {
    switch -regex ($path) { '\.html$' { 'text/html; charset=utf-8' } '\.js$' { 'text/javascript; charset=utf-8' } '\.png$' { 'image/png' } default { 'application/octet-stream' } }
}

# ---- 4. CDP 連線（含請求攔截） ----
$script:cdpId = 1
$script:recvTask = $null
$script:recvBuffer = New-Object byte[] 1048576
$script:recvStream = New-Object IO.MemoryStream
$script:blocked = [Collections.Generic.List[string]]::new()
function Send-Cdp([string]$method, $params = @{}) {
    $id = $script:cdpId++
    $payload = @{ id = $id; method = $method; params = $params } | ConvertTo-Json -Depth 12 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $script:ws.SendAsync([ArraySegment[byte]]::new($bytes), [Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
    return $id
}
function Read-Cdp([int]$timeoutMs) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
    while ($true) {
        if (-not $script:recvTask) { $script:recvTask = $script:ws.ReceiveAsync([ArraySegment[byte]]::new($script:recvBuffer), [Threading.CancellationToken]::None) }
        $left = [int][Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if (-not $script:recvTask.Wait($left)) { return $null }
        $res = $script:recvTask.Result; $script:recvTask = $null
        if ($res.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) { throw 'Edge 已關閉 CDP 連線' }
        $script:recvStream.Write($script:recvBuffer, 0, $res.Count)
        if ($res.EndOfMessage) {
            $text = [Text.Encoding]::UTF8.GetString($script:recvStream.ToArray()); $script:recvStream.SetLength(0)
            return ($text | ConvertFrom-Json)
        }
    }
}
function Send-Fulfill([string]$requestId, [int]$status, [string]$contentType, [byte[]]$body) {
    $headers = @(@{ name = 'Content-Type'; value = $contentType }, @{ name = 'Cache-Control'; value = 'no-store' })
    Send-Cdp 'Fetch.fulfillRequest' @{ requestId = $requestId; responseCode = $status; responseHeaders = $headers; body = [Convert]::ToBase64String($body) } | Out-Null
}
function Send-JsonReply([string]$requestId, [int]$status, $value) {
    Send-Fulfill $requestId $status 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $value -Depth 12 -Compress)))
}
function Invoke-PausedRequest($params) {
    $rid = $params.requestId; $url = [Uri]$params.request.url; $method = $params.request.method
    if ($url.Scheme -ne 'http' -or $url.Host -ne '127.0.0.1' -or $url.Port -ne 8765) {
        $script:blocked.Add("$method $($url.AbsoluteUri)")
        Send-Cdp 'Fetch.failRequest' @{ requestId = $rid; errorReason = 'BlockedByClient' } | Out-Null; return
    }
    $path = [Uri]::UnescapeDataString($url.AbsolutePath)
    if ($method -ne 'GET') {
        $script:blocked.Add("$method $path")
        Send-JsonReply $rid 403 @{ ok = $false; error = '手冊截圖示範環境不接受寫入或執行請求' }; return
    }
    if ($path -eq '/api/config') { Send-Fulfill $rid 200 'application/json; charset=utf-8' $demoConfigBytes; return }
    if ($api.ContainsKey($path)) { Send-JsonReply $rid 200 $api[$path]; return }
    if ($static.ContainsKey($path)) { Send-Fulfill $rid 200 (Get-MimeType $path) $static[$path]; return }
    Send-JsonReply $rid 404 @{ ok = $false; error = 'not found' }
}
function Invoke-Cdp([string]$method, $params = @{}, [int]$timeoutMs = 60000) {
    $id = Send-Cdp $method $params
    $deadline = [DateTime]::UtcNow.AddMilliseconds($timeoutMs)
    while ($true) {
        $left = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
        if ($left -le 0) { throw "CDP $method 逾時" }
        $msg = Read-Cdp $left
        if (-not $msg) { continue }
        if ($msg.method -eq 'Fetch.requestPaused') { Invoke-PausedRequest $msg.params; continue }
        if ($msg.id -eq $id) {
            if ($msg.error) { throw "CDP $method 失敗：$($msg.error.message)" }
            return $msg.result
        }
    }
}
function Wait-Cdp([int]$milliseconds) {
    $deadline = [DateTime]::UtcNow.AddMilliseconds($milliseconds)
    while (($left = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds) -gt 0) {
        $msg = Read-Cdp $left
        if ($msg -and $msg.method -eq 'Fetch.requestPaused') { Invoke-PausedRequest $msg.params }
    }
}

# PNG 與 JPEG 取較小者（大張截圖用 JPEG 可大幅縮小手冊檔案）
function Get-DataUri([string]$pngPath) {
    $png = [IO.File]::ReadAllBytes($pngPath)
    $bmp = [Drawing.Image]::FromFile($pngPath)
    try {
        $codec = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' }
        $ep = New-Object Drawing.Imaging.EncoderParameters 1
        $ep.Param[0] = New-Object Drawing.Imaging.EncoderParameter ([Drawing.Imaging.Encoder]::Quality), 88L
        $ms = New-Object IO.MemoryStream
        $bmp.Save($ms, $codec, $ep); $jpg = $ms.ToArray(); $ms.Dispose()
    } finally { $bmp.Dispose() }
    if ($jpg.Length -lt $png.Length * 0.8) { return 'data:image/jpeg;base64,' + [Convert]::ToBase64String($jpg) }
    return 'data:image/png;base64,' + [Convert]::ToBase64String($png)
}

# 每張截圖前共用：等待設定與圖片載入、停用自動儲存與自動辨識、注入本機 OCR 試算結果
$prelude = @"
const sleep = ms => new Promise(r => setTimeout(r, ms));
const waitFor = async (fn, what, ms = 20000) => { const t = Date.now(); while (Date.now() - t < ms) { try { if (fn()) return; } catch (e) {} await sleep(100); } throw new Error('等待逾時：' + what); };
await waitFor(() => window.__e3ShotReady === true, '設定從示範服務載入');
await waitFor(() => config.pages.every(p => pageImageCanvases[p.id]), '每頁圖片載入');
await waitFor(() => !numericRunning, '自動辨識結束');
autoSaveEnabled = false; numericAutoEnabled = false;
const NUMERIC = $numericJson;
for (const [pid, list] of Object.entries(NUMERIC)) {
  const page = config.pages.find(p => p.id === pid), canvas = pageImageCanvases[pid];
  if (!page || !canvas || canvas.isPlaceholder) continue;
  (Array.isArray(list) ? list : [list]).forEach((data, i) => { const rule = page.rules[i]; if (data && rule) numericCache.set(rule, {canvas, key: numericKey(rule), result: {...data, unknown: data.status === 'unknown', count: 0, hitPoints: []}}); });
}
const selectPage = i => { currentPageIdx = i; selectedRuleIdx = 0; selectedPageCategory = pageCategoryId(config.pages[i]); };
const openFold = key => { panelLayout.folds[key] = true; };
const pageIndex = predicate => { const i = config.pages.findIndex(predicate); if (i < 0) throw new Error('目前設定沒有符合截圖需求的頁面'); return i; };
const ruleIndex = (page, predicate) => Math.max(0, (page.rules || []).findIndex(predicate));
"@

$shots = [ordered]@{}
$edge = $null
try {
    # ---- 5. 啟動獨立的 headless Edge（隨機除錯埠、暫存 profile） ----
    $edgeExe = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $edgeExe) { throw '找不到 Microsoft Edge' }
    $edge = Start-Process $edgeExe -ArgumentList "--headless=new --remote-debugging-port=0 --user-data-dir=`"$profileDir`" --no-first-run --disable-features=Translate,msEdgeTranslate --force-device-scale-factor=1 about:blank" -PassThru
    $portFile = Join-Path $profileDir 'DevToolsActivePort'; $debugPort = $null
    for ($i = 0; $i -lt 60 -and -not $debugPort; $i++) {
        Start-Sleep -Milliseconds 250
        if (Test-Path -LiteralPath $portFile) { $debugPort = (Get-Content -LiteralPath $portFile -TotalCount 1) -as [int] }
    }
    if (-not $debugPort) { throw 'headless Edge 沒有啟動' }
    $target = $null
    for ($i = 0; $i -lt 40 -and -not $target; $i++) {
        try { $target = (Invoke-RestMethod "http://127.0.0.1:$debugPort/json/list" -TimeoutSec 2) | Where-Object { $_.type -eq 'page' } | Select-Object -First 1 } catch {}
        if (-not $target) { Start-Sleep -Milliseconds 250 }
    }
    if (-not $target) { throw '找不到 headless Edge 分頁' }
    $script:ws = [Net.WebSockets.ClientWebSocket]::new()
    $script:ws.ConnectAsync([Uri]$target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
    Invoke-Cdp 'Fetch.enable' @{ patterns = @(@{ urlPattern = '*'; requestStage = 'Request' }) } | Out-Null
    Invoke-Cdp 'Page.enable' | Out-Null
    Invoke-Cdp 'Page.setDownloadBehavior' @{ behavior = 'deny' } | Out-Null
    # 設定頁一讀到設定就會開啟自動儲存與自動辨識；在第一時間關閉，並讓裁切圖不嘗試寫回 sample_images
    $guard = "(() => { const iv = setInterval(() => { try { if (autoSaveEnabled === true) { autoSaveEnabled = false; numericAutoEnabled = false; scheduleSampleSave = () => Promise.resolve(true); window.__e3ShotReady = true; clearInterval(iv); } } catch (e) {} }, 2); })();"
    Invoke-Cdp 'Page.addScriptToEvaluateOnNewDocument' @{ source = $guard } | Out-Null

    function Shot([string]$name, [int]$w, [int]$h, [string]$setupJs, [string]$clipSelector = '') {
        Invoke-Cdp 'Emulation.setDeviceMetricsOverride' @{ width = $w; height = $h; deviceScaleFactor = 1; mobile = $false } | Out-Null
        Invoke-Cdp 'Page.navigate' @{ url = "$origin/calibrator.html" } | Out-Null
        Wait-Cdp $PageLoadMilliseconds
        $clip = if ($clipSelector) { "const el = document.querySelector('$clipSelector'); if (!el) throw new Error('找不到 $clipSelector'); const r = el.getBoundingClientRect(); return JSON.stringify({x:r.x,y:r.y,width:r.width,height:r.height});" } else { "return '';" }
        $expr = "(async () => { $prelude`n$setupJs;`nawait sleep(800); $clip })()"
        $ev = Invoke-Cdp 'Runtime.evaluate' @{ expression = $expr; awaitPromise = $true; returnByValue = $true } 90000
        if ($ev.exceptionDetails) { throw "$name 設定失敗：$($ev.exceptionDetails.exception.description)" }
        Wait-Cdp 400
        $params = @{ format = 'png'; captureBeyondViewport = $false }
        if ($clipSelector) {
            $r = $ev.result.value | ConvertFrom-Json
            if ($r.width -lt 10 -or $r.height -lt 10) { throw "$name 截圖範圍太小（$clipSelector 可能被隱藏）" }
            $params.clip = @{ x = [Math]::Floor($r.x); y = [Math]::Floor($r.y); width = [Math]::Ceiling([Math]::Min($r.width, $w - $r.x)); height = [Math]::Ceiling([Math]::Min($r.height, $h - $r.y)); scale = 1 }
        }
        $shot = Invoke-Cdp 'Page.captureScreenshot' $params 90000
        $file = Join-Path $shotDir "$name.png"
        [IO.File]::WriteAllBytes($file, [Convert]::FromBase64String($shot.data))
        $shots[$name] = Get-DataUri $file
        Write-Host ('📸 {0}  ({1:N0} KB)' -f $name, ($shots[$name].Length * 3 / 4 / 1KB)) -ForegroundColor Green
    }

    # ---- 6. 各張截圖（名稱需與 USER_MANUAL.html 的 data-shot 一致） ----
    # 頁面挑選：優先有啟用數值規則的頁面、有像素規則的頁面、有 Zabbix 時間設定且有圖的頁面
    $numericPage = "pageIndex(p => (p.rules || []).some(r => r.enabled !== false && r.measure_mode === 'numeric'))"
    $numericPage2 = "(() => { const all = config.pages.map((p, i) => i).filter(i => (config.pages[i].rules || []).some(r => r.enabled !== false && r.measure_mode === 'numeric')); if (!all.length) throw new Error('目前設定沒有數值門檻頁面'); return all[all.length - 1]; })()"
    $pixelPage = "pageIndex(p => (p.rules || []).some(r => (r.measure_mode || 'pixel') === 'pixel'))"
    $cropPage = "pageIndex(p => pageImageCanvases[p.id] && !pageImageCanvases[p.id].isPlaceholder && p.crop_region && p.crop_region.w > 0)"
    $selectNumeric = "const ni = $numericPage; selectPage(ni); selectedRuleIdx = ruleIndex(config.pages[ni], r => r.measure_mode === 'numeric'); setSideTab('pages'); setPageSection('rules'); setToolMode('rule')"
    $firstSched = "(config.schedules.find(s => s.enabled !== false) || config.schedules[0] || {}).id"
    $repeatSched = "(config.schedules.find(s => s.repeat && s.repeat.enabled === true) || config.schedules.find(s => s.enabled !== false) || config.schedules[0] || {}).id"

    Shot '01_overview' 1600 900 "$selectNumeric; previewScheduleId = config.schedules.find(s => (s.pages || []).includes(config.pages[ni].id))?.id ?? $firstSched; renderAll()"
    Shot '02_page_form' 1600 1450 "const pi = $numericPage; selectPage(pi); const pid = config.pages[pi].id; openFold(JSON.stringify(['sidebarLogin', pid])); openFold(JSON.stringify(['sidebarZoom', pid])); openFold(JSON.stringify(['sidebarTime', pid])); setSideTab('pages'); setPageSection('page'); renderAll(); document.querySelector('details.advanced').open = true; document.querySelector('.sidebar').scrollTop = 0" '.sidebar'
    Shot '03_crop_tool' 1600 900 "selectPage($cropPage); setSideTab('pages'); setPageSection('page'); renderAll(); setToolMode('crop'); renderCanvas()"
    Shot '04_rules' 1600 1500 "const xi = $pixelPage; selectPage(xi); selectedRuleIdx = ruleIndex(config.pages[xi], r => (r.measure_mode || 'pixel') === 'pixel'); setSideTab('pages'); setPageSection('rules'); setToolMode('rule'); renderAll(); document.querySelectorAll('#ruleEditor details.advanced').forEach(d => d.open = true); document.querySelector('.sidebar').scrollTop = 0" '.sidebar'
    Shot '05_schedule_tab' 1600 1000 "setSideTab('schedule'); const rs = $repeatSched; expandedScheduleIdx = config.schedules.findIndex(s => s.id === rs); previewScheduleId = rs; openFold('sidebar:schedulesFold:v2'); openFold(JSON.stringify(['pages', rs])); renderAll(); await refreshScheduleStatus(); document.getElementById('scheduleList').scrollIntoView({block: 'start'})"
    Shot '06_preview_panel' 1600 1000 "setSideTab('schedule'); previewScheduleId = $firstSched; renderAll()" '.right-panel'
    Shot '07_site_tab' 1600 700 "setSideTab('site'); renderAll()" '.sidebar'
    Shot '08_placeholder' 1600 700 "setSideTab('pages'); setPageSection('page'); document.getElementById('addPageBtn').click(); await sleep(400)"
    $reportJs = ConvertTo-Json -InputObject $detectReport -Compress
    Shot '09_detect_teams' 1600 1000 "setSideTab('teams'); openFold('sidebar:teamsSettingsFold'); renderAll(); const o = document.getElementById('detectTeamsResult'); o.hidden = false; o.textContent = $reportJs; document.getElementById('teamsSettingsFold').scrollIntoView({block: 'start'})" '.sidebar'
    Shot '10_cdp_mode' 1600 1000 "setSideTab('teams'); openFold('sidebar:teamsSettingsFold'); renderAll(); await refreshSavedCdpTargets(true); renderAll(); document.getElementById('teamsSettingsFold').scrollIntoView({block: 'start'})" '.sidebar'
    Shot '11_numeric' 1600 1000 "const qi = $numericPage2; selectPage(qi); selectedRuleIdx = ruleIndex(config.pages[qi], r => r.measure_mode === 'numeric'); previewScheduleId = config.schedules.find(s => (s.pages || []).includes(config.pages[qi].id))?.id ?? $repeatSched; setSideTab('pages'); setPageSection('rules'); setToolMode('rule'); renderAll(); document.querySelectorAll('#ruleEditor details.advanced').forEach(d => d.open = true); document.getElementById('numericEditor').scrollIntoView({block: 'start'})"
    Shot '12_self_test' 1600 1000 "setSideTab('schedule'); previewScheduleId = $repeatSched; openFold('sidebar:selfHelpFold'); renderAll()" '.preview-controls'
    Shot '13_receiver' 1600 1200 "setSideTab('teams'); openFold('sidebar:receiverFold:v2'); openFold('sidebar:receiverSetupFold'); document.querySelectorAll('#receiverSetupFold details.inline-help').forEach(d => d.open = false); renderAll(); await refreshReceiverStatus(true); await waitFor(() => receiverState.data, '手機遙控狀態'); document.getElementById('receiverFold').scrollIntoView({block: 'start'})" '#receiverFold'
    Shot '14_panels_collapsed' 1600 700 "$selectNumeric; renderAll(); setPanelCollapsed('left', true, {save: false}); setPanelCollapsed('right', true, {save: false}); await sleep(300); renderCanvas()"
    $script:ws.Dispose()

    # ---- 7. 核對後原子替換手冊的 MANUAL_IMAGES 區塊 ----
    $html = $utf8.GetString([IO.File]::ReadAllBytes($manual))
    $referenced = @([regex]::Matches($html, 'data-shot="([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $made = @($shots.Keys | Sort-Object)
    if (($referenced -join '|') -ne ($made -join '|')) { throw "手冊引用的截圖（$($referenced -join ', ')）與本次產生的截圖（$($made -join ', ')）不一致，手冊未修改" }
    if ($shots.Count -ne 14) { throw "只產生 $($shots.Count) 張截圖，手冊未修改" }
    $pattern = '(?s)<!-- MANUAL_IMAGES_BEGIN.*?<!-- MANUAL_IMAGES_END -->'
    if ([regex]::Matches($html, $pattern).Count -ne 1) { throw 'USER_MANUAL.html 必須剛好有一組 MANUAL_IMAGES_BEGIN / END 標記，手冊未修改' }
    $lines = $shots.Keys | ForEach-Object { "  `"$_`": `"$($shots[$_])`"" }
    # 圖片區塊沿用手冊其餘部分的換行（目前是 LF），避免同一個檔案混用兩種換行
    $nl = if (([regex]::Matches($html, "`r`n")).Count -gt ([regex]::Matches($html, "(?<!`r)`n")).Count) { "`r`n" } else { "`n" }
    $block = "<!-- MANUAL_IMAGES_BEGIN：此區由 tools\make_screenshots.ps1 自動產生，請勿手動編輯 -->$nl<script>window.MANUAL_IMAGES = {$nl" + ($lines -join ",$nl") + "$nl};</script>$nl<!-- MANUAL_IMAGES_END -->"
    $html = [regex]::Replace($html, $pattern, { param($m) $block })
    $temp = "$manual.tmp"
    [IO.File]::WriteAllText($temp, $html, [Text.UTF8Encoding]::new($false))
    [IO.File]::Replace($temp, $manual, [NullString]::Value)
    Write-Host ('✅ 已嵌入 {0} 張截圖到 USER_MANUAL.html（{1:N0} KB）' -f $shots.Count, ((Get-Item $manual).Length / 1KB)) -ForegroundColor Green
    if ($script:blocked.Count) { Write-Host "ℹ️ 已拒絕 $($script:blocked.Count) 個非 GET 或外部請求：$((@($script:blocked) | Select-Object -Unique) -join '；')" -ForegroundColor DarkGray }
    Write-Host "📁 原手冊與 PNG 保留於：$work" -ForegroundColor Cyan
} finally {
    if ($script:ws) { try { $script:ws.Dispose() } catch {} }
    if ($edge) { Stop-Process -Id $edge.Id -Force -ErrorAction SilentlyContinue }
    Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($profileDir) } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Milliseconds 800
    Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath "$manual.tmp") { Remove-Item -LiteralPath "$manual.tmp" -Force -ErrorAction SilentlyContinue }
}
