param(
    [int]$Port = 8765,
    [int]$DebugPort = 9356
)
# ==============================================================================
# 重新產生 USER_MANUAL.html 的設定工具截圖，並直接嵌入手冊 (calibrator.html 介面改版後執行一次)
# - 在暫存資料夾建立「示範環境」：複製目前的 calibrator.html / e3_monitor_native.ps1，
#   搭配 _demo_config.json (假的 Teams 連結) 與 sample_data.js 內建範例圖，不會讀寫您的 config.json、Teams 或排程
# - 用 headless Edge (獨立暫存設定檔) 截圖，寫入 USER_MANUAL.html 的 MANUAL_IMAGES 區塊，不另外留下圖片檔
# 執行前請先關閉 open_calibrator.bat 的黑色視窗 (示範環境需要使用 8765 連接埠)
# ==============================================================================
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
$here = $PSScriptRoot
$root = Split-Path $here -Parent
$manual = Join-Path $root "USER_MANUAL.html"
$demo = Join-Path $env:TEMP "e3_manual_demo"
$edgeProfile = Join-Path $env:TEMP "e3_manual_demo_edge"
$shotDir = Join-Path $env:TEMP "e3_manual_shots"

if (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue) {
    Write-Host "❌ 連接埠 $Port 正在使用中，請先關閉 open_calibrator.bat 的黑色視窗再執行" -ForegroundColor Red
    exit 1
}

# ---- 1. 建立示範環境 ----
Remove-Item $demo, $shotDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path (Join-Path $demo "sample_images"), $shotDir | Out-Null
Copy-Item (Join-Path $root "calibrator.html"), (Join-Path $root "e3_monitor_native.ps1"), (Join-Path $root "sample_data.js") -Destination $demo
Copy-Item (Join-Path $here "_demo_config.json") (Join-Path $demo "config.json")
$js = Get-Content (Join-Path $root "sample_data.js") -Raw
foreach ($m in [regex]::Matches($js, "(page\d+):\s*'data:image/png;base64,([^']+)'")) {
    [IO.File]::WriteAllBytes((Join-Path $demo "sample_images\$($m.Groups[1].Value).png"), [Convert]::FromBase64String($m.Groups[2].Value))
}

# page5 的「整頁畫面」：用 4 張範例圖拼成 1920x1080 的監控首頁，給 ✂️ 擷取範圍截圖使用
$full = New-Object System.Drawing.Bitmap 1920, 1080
$g = [System.Drawing.Graphics]::FromImage($full)
$g.Clear([System.Drawing.Color]::White)
$g.FillRectangle((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(30, 41, 59))), 0, 0, 1920, 56)
$g.DrawString("監控首頁（示範）", (New-Object System.Drawing.Font("Microsoft JhengHei", 18, [System.Drawing.FontStyle]::Bold)), [System.Drawing.Brushes]::White, 30, 12)
$slots = @{ page1 = @(40, 90); page2 = @(836, 90); page3 = @(40, 450); page4 = @(836, 450) }
foreach ($k in $slots.Keys) {
    $img = [System.Drawing.Image]::FromFile((Join-Path $demo "sample_images\$k.png"))
    $g.DrawImage($img, $slots[$k][0], $slots[$k][1], $img.Width, $img.Height)
    $img.Dispose()
}
$g.Dispose()
$full.Save((Join-Path $demo "sample_images\page5_full.png"), [System.Drawing.Imaging.ImageFormat]::Png)
$full.Dispose()

function Invoke-Cdp($ws, [int]$id, [string]$method, [hashtable]$params = @{}) {
    $payload = @{ id = $id; method = $method; params = $params } | ConvertTo-Json -Depth 10 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $ct = [Threading.CancellationToken]::None
    $ws.SendAsync([ArraySegment[byte]]::new($bytes), [Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).GetAwaiter().GetResult() | Out-Null
    $buffer = New-Object byte[] 1048576
    $sb = New-Object Text.StringBuilder
    while ($true) {
        $res = $ws.ReceiveAsync([ArraySegment[byte]]::new($buffer), $ct).GetAwaiter().GetResult()
        $sb.Append([Text.Encoding]::UTF8.GetString($buffer, 0, $res.Count)) | Out-Null
        if ($res.EndOfMessage) {
            $msg = $sb.ToString(); $sb.Clear() | Out-Null
            try { $j = $msg | ConvertFrom-Json; if ($j.id -eq $id) { return $j } } catch {}
        }
    }
}

# PNG 與 JPEG 取較小者 (大張截圖用 JPEG 可大幅縮小手冊檔案)
function Get-DataUri([string]$pngPath) {
    $png = [IO.File]::ReadAllBytes($pngPath)
    $bmp = [System.Drawing.Image]::FromFile($pngPath)
    $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq "image/jpeg" }
    $ep = New-Object System.Drawing.Imaging.EncoderParameters 1
    $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality), 88L
    $ms = New-Object IO.MemoryStream
    $bmp.Save($ms, $codec, $ep)
    $bmp.Dispose()
    $jpg = $ms.ToArray(); $ms.Dispose()
    if ($jpg.Length -lt $png.Length * 0.8) { return "data:image/jpeg;base64," + [Convert]::ToBase64String($jpg) }
    return "data:image/png;base64," + [Convert]::ToBase64String($png)
}

$server = $null; $edge = $null; $shots = [ordered]@{}
try {
    # ---- 2. 啟動示範用本機服務與 headless Edge ----
    $server = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $demo 'e3_monitor_native.ps1')`" -Calibrator -NoBrowser" -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 2
    $edgeExe = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
    $edge = Start-Process $edgeExe -ArgumentList "--headless=new --remote-debugging-port=$DebugPort --user-data-dir=`"$edgeProfile`" --force-device-scale-factor=1 about:blank" -PassThru
    $target = $null
    for ($i = 0; $i -lt 30 -and -not $target; $i++) {
        Start-Sleep -Milliseconds 500
        try { $target = (Invoke-RestMethod "http://127.0.0.1:$DebugPort/json" -TimeoutSec 2) | Where-Object { $_.type -eq "page" } | Select-Object -First 1 } catch {}
    }
    if (-not $target) { throw "headless Edge 沒有啟動" }
    $ws = [Net.WebSockets.ClientWebSocket]::new()
    $ws.ConnectAsync([Uri]$target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
    $script:cid = 1
    Invoke-Cdp $ws ($script:cid++) "Page.enable" | Out-Null

    function Shot([string]$name, [int]$w, [int]$h, [string]$setupJs, [string]$clipSelector = "") {
        Invoke-Cdp $ws ($script:cid++) "Emulation.setDeviceMetricsOverride" @{ width = $w; height = $h; deviceScaleFactor = 1; mobile = $false } | Out-Null
        Invoke-Cdp $ws ($script:cid++) "Page.navigate" @{ url = "http://127.0.0.1:$Port/calibrator.html" } | Out-Null
        Start-Sleep -Seconds 4
        # 先關閉自動儲存：示範環境不可寫回設定，更不可自動註冊 Windows 排程
        $expr = "(async () => { autoSaveEnabled = false; $setupJs; await new Promise(r => setTimeout(r, 600)); " +
            $(if ($clipSelector) { "const r = document.querySelector('$clipSelector').getBoundingClientRect(); return JSON.stringify({x:r.x,y:r.y,width:r.width,height:r.height});" } else { "return '';" }) + " })()"
        $ev = Invoke-Cdp $ws ($script:cid++) "Runtime.evaluate" @{ expression = $expr; awaitPromise = $true; returnByValue = $true }
        if ($ev.result.exceptionDetails) { throw "$name 設定失敗: $($ev.result.exceptionDetails.exception.description)" }
        $params = @{ format = "png" }
        if ($clipSelector) {
            $r = $ev.result.result.value | ConvertFrom-Json
            $params.clip = @{ x = [Math]::Floor($r.x); y = [Math]::Floor($r.y); width = [Math]::Ceiling($r.width); height = [Math]::Ceiling($r.height); scale = 1 }
        }
        $shot = Invoke-Cdp $ws ($script:cid++) "Page.captureScreenshot" $params
        $file = Join-Path $shotDir "$name.png"
        [IO.File]::WriteAllBytes($file, [Convert]::FromBase64String($shot.result.data))
        $shots[$name] = Get-DataUri $file
        Write-Host ("📸 {0}  ({1:N0} KB)" -f $name, ($shots[$name].Length * 3 / 4 / 1KB)) -ForegroundColor Green
    }

    # ---- 3. 各張截圖 (名稱需與 USER_MANUAL.html 的 data-shot 一致) ----
    $selectRule3 = "setSideTab('pages'); currentPageIdx = 0; selectedRuleIdx = 2; setToolMode('rule'); renderAll()"
    Shot "01_overview" 1600 900 $selectRule3
    Shot "02_page_form" 1600 1100 "setSideTab('pages'); currentPageIdx = 4; renderAll(); document.querySelector('details.advanced').open = true" ".sidebar"
    Shot "03_crop_tool" 1600 900 "setSideTab('pages'); currentPageIdx = 4; renderAll(); setToolMode('crop'); renderCanvas()"
    Shot "04_rules" 1600 1500 "$selectRule3; document.querySelector('.sidebar').scrollTop = 0" ".sidebar"
    # 示範環境沒有真的 Windows 任務：顯示一組範例的「下次執行時間」與已同步狀態
    $fakeTasks = "scheduleTaskInfo = { morning: { id: 'morning', next: '11/02 08:00' }, afternoon: { id: 'afternoon', next: '11/03 17:00' }, evening: { id: 'evening', next: '11/01 20:00' } }; document.getElementById('scheduleSyncStatus').textContent = '✅ Windows 排程已同步（3 個）'; document.getElementById('scheduleSyncStatus').style.color = ''"
    Shot "05_schedule_tab" 1600 1000 "setSideTab('send'); expandedScheduleIdx = 0; previewScheduleId = 'morning'; $fakeTasks; renderAll()"
    Shot "06_preview_panel" 1600 1000 "setSideTab('send'); previewScheduleId = 'afternoon'; renderAll()" ".right-panel"
    Shot "07_global_tab" 1600 700 "setSideTab('global'); renderAll()" ".sidebar"
    Shot "08_placeholder" 1600 700 "setSideTab('pages'); document.getElementById('addPageBtn').click(); await new Promise(r => setTimeout(r, 400))"
    $ws.Dispose()

    # ---- 4. 寫入 USER_MANUAL.html 的 MANUAL_IMAGES 區塊 (每張圖一行) ----
    $lines = $shots.Keys | ForEach-Object { "  `"$_`": `"$($shots[$_])`"" }
    $block = "<!-- MANUAL_IMAGES_BEGIN：此區由 tools\make_screenshots.ps1 自動產生，請勿手動編輯 -->`n<script>window.MANUAL_IMAGES = {`n" + ($lines -join ",`n") + "`n};</script>`n<!-- MANUAL_IMAGES_END -->"
    $html = [IO.File]::ReadAllText($manual, [Text.Encoding]::UTF8)
    $pattern = '(?s)<!-- MANUAL_IMAGES_BEGIN.*?<!-- MANUAL_IMAGES_END -->'
    if (-not [regex]::IsMatch($html, $pattern)) { throw "USER_MANUAL.html 找不到 MANUAL_IMAGES_BEGIN / END 標記" }
    $html = [regex]::Replace($html, $pattern, { param($m) $block })
    [IO.File]::WriteAllText($manual, $html, (New-Object Text.UTF8Encoding($false)))
    Write-Host ("✅ 已嵌入 {0} 張截圖到 USER_MANUAL.html ({1:N0} KB)" -f $shots.Count, ((Get-Item $manual).Length / 1KB)) -ForegroundColor Green
} finally {
    if ($edge) { Stop-Process -Id $edge.Id -Force -ErrorAction SilentlyContinue }
    Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" | Where-Object { $_.CommandLine -like "*e3_manual_demo_edge*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    if ($server) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 1
    Remove-Item $demo, $edgeProfile, $shotDir -Recurse -Force -ErrorAction SilentlyContinue
}
