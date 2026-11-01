param(
    [string]$ConfigPath = "",          # 留空 = 與本程式同資料夾的 config.json
    [switch]$Calibrator = $false,      # 啟動設定工具本機服務 (open_calibrator.bat 使用)
    [int]$Port = 8765,
    [switch]$NoBrowser = $false,       # 搭配 -Calibrator：啟動後不自動開啟瀏覽器 (截圖工具 / 測試用)
    [string]$Schedule = "",            # 指定要執行的排程 id (config.schedules[].id)；留空 = 執行所有啟用頁面
    [switch]$RegisterSchedules = $false, # 依 config.schedules 一次註冊 / 更新 / 移除所有 Windows 工作排程
    [switch]$ListSchedules = $false,     # 僅列出目前設定的排程與對應頁面
    [switch]$PreviewCapture = $false,    # calibrator「📸 抓圖」：用已登入的 edge_profile 截單一頁面的整頁畫面 (不裁切、不發送)
    [string]$PageId = "",
    [string]$Url = "",
    [string]$OutFile = "",
    [switch]$TestSample = $false,
    [switch]$LoginMode = $false,
    [switch]$NoSend = $false,
    [switch]$DryRun = $false,
    [int]$CountdownSeconds = 0
)

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

# Win32 視窗前景控制 (Windows 內建 user32.dll，以 .NET 內建編譯器即時載入，免安裝)
# 用途：Teams 縮小 / 在背景時，WScript AppActivate 會被 Windows 前景鎖定擋下，改用 Win32 API 還原並拉到最前
$script:Win32Ready = $false
try {
    Add-Type -ErrorAction Stop -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class E3Win {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, IntPtr lpdwProcessId);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
}
"@
    $script:Win32Ready = $true
} catch {
    Write-Host "⚠️ 無法載入 Win32 視窗控制 ($($_.Exception.Message))，改用 AppActivate" -ForegroundColor Yellow
}

if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot "config.json" }
if (-not (Test-Path $ConfigPath)) {
    Write-Host "❌ 找不到設定檔: $ConfigPath" -ForegroundColor Red
    exit 1
}
$ConfigPath = (Resolve-Path $ConfigPath).Path

$config = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json

$TaskPrefix = "E3_Monitor_"
$LegacyTaskName = "E3_Daily_Monitor_Teams"

# ==============================================================================
# 排程設定：讀取 config.schedules (舊版只有 schedule_time 時，自動視為一個「全部頁面」的排程)
# ==============================================================================
function Get-ScheduleList($cfg) {
    if ($cfg.schedules -and @($cfg.schedules).Count -gt 0) {
        return @($cfg.schedules)
    }
    $legacyTime = if ($cfg.schedule_time) { $cfg.schedule_time } else { "07:30" }
    return @([pscustomobject]@{
        id = "daily"; enabled = $true; name = "每日巡檢 (舊版 schedule_time)"; time = $legacyTime
        days = @(); pages = @($cfg.pages | ForEach-Object { $_.id }); target_chat_name = ""; title = ""
    })
}

# 依排程挑出要擷取的頁面 (依排程 pages 清單順序；頁面本身被停用則一律略過)
function Resolve-SchedulePages($cfg, $sched) {
    $result = @()
    foreach ($pageId in @($sched.pages)) {
        $page = $cfg.pages | Where-Object { $_.id -eq $pageId } | Select-Object -First 1
        if (-not $page) {
            Write-Host "⚠️ 排程 [$($sched.id)] 指定的頁面 '$pageId' 不存在於 pages，已略過" -ForegroundColor Yellow
            continue
        }
        if ($page.enabled -eq $false) {
            Write-Host "⏸️ 排程 [$($sched.id)] 的頁面 '$pageId' 已停用，已略過" -ForegroundColor DarkGray
            continue
        }
        $result += $page
    }
    return $result
}

function Convert-DayNames($days) {
    $map = @{ MON = "Monday"; TUE = "Tuesday"; WED = "Wednesday"; THU = "Thursday"; FRI = "Friday"; SAT = "Saturday"; SUN = "Sunday" }
    $out = @()
    foreach ($d in @($days)) {
        if (-not $d) { continue }
        $key = $d.ToString().Trim().Substring(0, [Math]::Min(3, $d.ToString().Trim().Length)).ToUpper()
        if (-not $map.ContainsKey($key)) { throw "無法辨識的星期 '$d' (請使用 MON/TUE/WED/THU/FRI/SAT/SUN)" }
        $out += $map[$key]
    }
    return $out
}

function Show-ScheduleList($cfg) {
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "📅 config.json 中的排程設定" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    foreach ($s in Get-ScheduleList $cfg) {
        $state = if ($s.enabled -ne $false) { "✅ 啟用" } else { "⏸️ 停用" }
        $dayText = if (@($s.days | Where-Object { $_ }).Count -gt 0) { ($s.days -join ",") } else { "每天" }
        Write-Host ("{0} [{1}] {2}  {3} {4}" -f $state, $s.id, $s.name, $dayText, $s.time) -ForegroundColor White
        Write-Host ("     頁面 ({0} 張): {1}" -f @($s.pages).Count, ($s.pages -join ", ")) -ForegroundColor Gray
    }
}

# ==============================================================================
# 模式：依 config.schedules 一次註冊所有 Windows 工作排程 (每個排程一個任務 E3_Monitor_<id>)
# 以「目前登入使用者 / 僅在登入時執行」註冊，不需系統管理員權限 (貼 Teams 需互動桌面)
# ==============================================================================
function Register-AllSchedules($cfg) {
    $logDir = Join-Path $PSScriptRoot "logs"
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
    $report = New-Object System.Collections.Generic.List[string]
    $ok = $true

    $scriptPath = Join-Path $PSScriptRoot "e3_monitor_native.ps1"
    $userId = "$env:USERDOMAIN\$env:USERNAME"
    $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew

    $wanted = @{}
    foreach ($s in Get-ScheduleList $cfg) {
        if ($s.enabled -eq $false) { continue }
        $taskName = "$TaskPrefix$($s.id)"
        try {
            if ($s.id -notmatch '^[A-Za-z0-9_-]+$') { throw "排程 id 只能使用英數字、底線、減號" }
            if ($s.time -notmatch '^([01]?\d|2[0-3]):[0-5]\d$') { throw "時間格式需為 HH:mm (目前: '$($s.time)')" }
            $at = [datetime]::ParseExact($s.time.PadLeft(5, '0'), "HH:mm", $null)
            $dayNames = Convert-DayNames $s.days
            $trigger = if ($dayNames.Count -gt 0) {
                New-ScheduledTaskTrigger -Weekly -DaysOfWeek $dayNames -At $at
            } else {
                New-ScheduledTaskTrigger -Daily -At $at
            }
            $argStr = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Minimized -File `"$scriptPath`" -ConfigPath `"$ConfigPath`" -Schedule $($s.id)"
            $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $argStr -WorkingDirectory $PSScriptRoot
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
                -Description "E3 監控自動截圖：$($s.name)" -Force | Out-Null
            $wanted[$taskName] = $true
            $dayText = if ($dayNames.Count -gt 0) { ($s.days -join ",") } else { "每天" }
            $report.Add("✅ 已註冊 $taskName  ($dayText $($s.time)，$(@($s.pages).Count) 個頁面)")
        } catch {
            $ok = $false
            $report.Add("❌ 註冊 $taskName 失敗: $($_.Exception.Message)")
        }
    }

    # 移除 config 中已刪除或停用的排程任務，以及舊版單一排程任務
    foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like "$TaskPrefix*" -or $_.TaskName -eq $LegacyTaskName })) {
        if ($wanted.ContainsKey($t.TaskName)) { continue }
        try {
            Unregister-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -Confirm:$false
            $report.Add("🗑️ 已移除不再使用的排程任務 $($t.TaskName)")
        } catch {
            $ok = $false
            $report.Add("❌ 移除 $($t.TaskName) 失敗: $($_.Exception.Message)")
        }
    }

    foreach ($line in $report) {
        Write-Host $line -ForegroundColor $(if ($line.StartsWith("❌")) { "Red" } else { "Green" })
    }
    # 寫一份結果供設定工具 (-Calibrator 模式) 讀取顯示
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $logDir "register_last.txt"), ($report -join "`r`n"), $utf8NoBom)
    return $ok
}

if ($ListSchedules) {
    Show-ScheduleList $config
    exit 0
}

if ($RegisterSchedules) {
    Show-ScheduleList $config
    Write-Host ""
    $regOk = Register-AllSchedules $config
    exit $(if ($regOk) { 0 } else { 1 })
}

# ==============================================================================
# 模式：設定工具本機服務 (-Calibrator)，由 open_calibrator.bat 啟動 (原 server.ps1)
# 提供 http://127.0.0.1:<Port>/calibrator.html 與其 API；只接受本機、本工具頁面的請求
# ==============================================================================
if ($Calibrator) {
    $port = $Port
    $url = "http://127.0.0.1:$port/"
    $rootDir = $PSScriptRoot
    $configPath = $ConfigPath

    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add($url)
    try {
        $listener.Start()
    } catch {
        Write-Host "ℹ️ 設定工具服務已在執行中，正在開啟瀏覽器..." -ForegroundColor Cyan
        Start-Process "${url}calibrator.html"
        exit 0
    }

    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "🛠️ E3 視覺化設定工具本機服務已啟動: ${url}calibrator.html" -ForegroundColor Green
    Write-Host "👉 所有設定、抓圖、登入監控網站、測試與排程都在網頁中操作，修改會自動儲存" -ForegroundColor Yellow
    Write-Host "⚠️ 使用設定工具期間請勿關閉此視窗；關閉後設定工具將無法儲存。" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Cyan
    if (-not $NoBrowser) { Start-Process "${url}calibrator.html" }

    while ($listener.IsListening) {
        try {
            $context = $listener.GetContext()
            $req = $context.Request
            $res = $context.Response
            $path = $req.Url.AbsolutePath

            # 安全：只接受本工具自己的頁面 (http://127.0.0.1:8765) 發出的請求。
            # 不送 CORS 允許標頭，並拒絕帶有其他網站 Origin 的請求，避免任何網頁偷讀 config.json (含密碼)、
            # 改寫設定、觸發 Teams 發送或註冊排程。沒有 Origin 的請求 (本機 PowerShell 等) 照常允許。
            # 不讓瀏覽器快取：更新 calibrator.html / 手冊 / 截圖後，重新整理就是最新版
            $res.AddHeader("Cache-Control", "no-store")

            $origin = $req.Headers["Origin"]
            if ($req.HttpMethod -eq "OPTIONS" -or ($origin -and $origin -ne "http://127.0.0.1:$port")) {
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ⛔ 已拒絕來自其他來源的請求: $($req.HttpMethod) $path (Origin: $origin)" -ForegroundColor DarkYellow
                $res.StatusCode = 403
                $res.Close()
                continue
            }

            if ($path -eq "/api/config" -and $req.HttpMethod -eq "GET") {
                $jsonBytes = [System.IO.File]::ReadAllBytes($configPath)
                $res.ContentType = "application/json; charset=utf-8"
                $res.OutputStream.Write($jsonBytes, 0, $jsonBytes.Length)
                $res.Close()
                continue
            }

            if ($path -eq "/api/save" -and $req.HttpMethod -eq "POST") {
                $reader = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                $body = $reader.ReadToEnd()
                $reader.Close()

                $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
                [System.IO.File]::WriteAllText($configPath, $body, $utf8NoBom)
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] 💾 已直接儲存設定至 $configPath" -ForegroundColor Green

                $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                $res.ContentType = "application/json; charset=utf-8"
                $res.OutputStream.Write($respBytes, 0, $respBytes.Length)
                $res.Close()
                continue
            }

            # 即時抓取使用者輸入的新網址畫面並更新中間截圖！
            if ($path -eq "/api/capture-url" -and $req.HttpMethod -eq "POST") {
                $reader = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                $body = $reader.ReadToEnd()
                $reader.Close()
                $payload = $body | ConvertFrom-Json

                $targetUrl = [string]$payload.url
                $pageId = if ($payload.pageId) { [string]$payload.pageId } else { "page1" }

                if ($pageId -notmatch '^[A-Za-z0-9_-]+$' -or $targetUrl -notmatch '^https?://') {
                    $respJson = @{ ok = $false; error = "頁面 id 或網址格式不正確" } | ConvertTo-Json -Compress
                } else {
                    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] 📸 正在用已登入的 edge_profile 抓取整頁畫面 ($pageId): $targetUrl" -ForegroundColor Cyan
                    $sampleDir = Join-Path $rootDir "sample_images"
                    if (-not (Test-Path $sampleDir)) { New-Item -ItemType Directory -Force -Path $sampleDir | Out-Null }
                    # 整頁原圖存成 <id>_full.png；裁切後的 <id>.png 由 calibrator 依擷取範圍產生後透過 /api/save-sample 寫回
                    $fullPng = Join-Path $sampleDir "${pageId}_full.png"
                    $tmpPng = Join-Path $sampleDir "tmp_${pageId}_full.png"
                    Remove-Item $tmpPng -Force -ErrorAction SilentlyContinue

                    # 與正式排程使用同一個引擎與 edge_profile (含自動登入、1920x1080 固定可視範圍)
                    $scriptPath = $PSCommandPath
                    $engineArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -ConfigPath `"$configPath`" -PreviewCapture -PageId $pageId -Url `"$targetUrl`" -OutFile `"$tmpPng`""
                    $proc = Start-Process powershell -ArgumentList $engineArgs -WindowStyle Hidden -Wait -PassThru

                    if ($proc.ExitCode -eq 0 -and (Test-Path $tmpPng)) {
                        Move-Item $tmpPng $fullPng -Force
                        $imgBytes = [System.IO.File]::ReadAllBytes($fullPng)
                        $b64 = [Convert]::ToBase64String($imgBytes)
                        $bmp = [System.Drawing.Bitmap]::new($fullPng)
                        $w = $bmp.Width
                        $h = $bmp.Height
                        $bmp.Dispose()

                        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ✅ 成功擷取整頁畫面 (${w}x${h}) -> $fullPng" -ForegroundColor Green
                        $respJson = @{ ok = $true; width = $w; height = $h; dataUrl = "data:image/png;base64,$b64" } | ConvertTo-Json -Compress
                    } else {
                        Remove-Item $tmpPng -Force -ErrorAction SilentlyContinue
                        $reportFile = Join-Path $rootDir "logs\preview_last.txt"
                        $errText = if (Test-Path $reportFile) { [System.IO.File]::ReadAllText($reportFile, [System.Text.Encoding]::UTF8) } else { "無法連線或擷取該網址畫面" }
                        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ❌ 抓圖失敗: $errText" -ForegroundColor Red
                        $respJson = @{ ok = $false; error = $errText } | ConvertTo-Json -Compress
                    }
                }

                $respBytes = [System.Text.Encoding]::UTF8.GetBytes($respJson)
                $res.ContentType = "application/json; charset=utf-8"
                $res.OutputStream.Write($respBytes, 0, $respBytes.Length)
                $res.Close()
                continue
            }

            if ($path -eq "/api/test-teams" -and $req.HttpMethod -eq "POST") {
                $reader = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                $body = $reader.ReadToEnd()
                $reader.Close()

                $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
                [System.IO.File]::WriteAllText($configPath, $body, $utf8NoBom)
                $modeText = if ($req.QueryString["send"] -eq "1") { "正式送出" } else { "只貼上不送出" }
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] 🚀 已儲存設定並啟動 Teams 發送測試 ($modeText)..." -ForegroundColor Cyan

                $scriptPath = $PSCommandPath
                $testArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -ConfigPath `"$configPath`" -TestSample"
                # ?schedule=<id>：只測試該排程的頁面組合
                $schedId = $req.QueryString["schedule"]
                if ($schedId -and $schedId -match '^[A-Za-z0-9_-]+$') { $testArgs += " -Schedule $schedId" }
                # 預設只貼上不按 Enter；明確帶 ?send=1 才正式送出
                if ($req.QueryString["send"] -ne "1") { $testArgs += " -DryRun" }
                Start-Process powershell -ArgumentList $testArgs

                $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                $res.ContentType = "application/json; charset=utf-8"
                $res.OutputStream.Write($respBytes, 0, $respBytes.Length)
                $res.Close()
                continue
            }

            # calibrator 依擷取範圍裁切後的圖 (kind=crop -> <id>.png) 或載入的整頁圖 (kind=full -> <id>_full.png)
            # 寫回 sample_images，讓測試按鈕 (-TestSample) 與下次開啟設定工具都用同一張圖
            if ($path -eq "/api/save-sample" -and $req.HttpMethod -eq "POST") {
                $reader = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                $body = $reader.ReadToEnd()
                $reader.Close()
                $payload = $body | ConvertFrom-Json

                $pageId = [string]$payload.pageId
                $dataUrl = [string]$payload.dataUrl
                $suffix = if ($payload.kind -eq "full") { "_full" } else { "" }
                if ($pageId -match '^[A-Za-z0-9_-]+$' -and $dataUrl.StartsWith("data:image/png;base64,")) {
                    $sampleDir = Join-Path $rootDir "sample_images"
                    if (-not (Test-Path $sampleDir)) { New-Item -ItemType Directory -Force -Path $sampleDir | Out-Null }
                    $bytes = [Convert]::FromBase64String($dataUrl.Substring("data:image/png;base64,".Length))
                    [System.IO.File]::WriteAllBytes((Join-Path $sampleDir "$pageId$suffix.png"), $bytes)
                    $respJson = '{"ok":true}'
                } else {
                    $res.StatusCode = 400
                    $respJson = '{"ok":false}'
                }
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes($respJson)
                $res.ContentType = "application/json; charset=utf-8"
                $res.OutputStream.Write($respBytes, 0, $respBytes.Length)
                $res.Close()
                continue
            }

            # 目前 Windows 工作排程器中的 E3_Monitor_* 任務與下次執行時間 (設定工具顯示同步狀態用)
            if ($path -eq "/api/schedule-status" -and $req.HttpMethod -eq "GET") {
                $tasks = @(Get-ScheduledTask -TaskName "E3_Monitor_*" -ErrorAction SilentlyContinue | ForEach-Object {
                    $info = $_ | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
                    $next = if ($info -and $info.NextRunTime -and $info.NextRunTime.Year -gt 2000) { $info.NextRunTime.ToString("MM/dd HH:mm") } else { "" }
                    @{ id = $_.TaskName.Substring("E3_Monitor_".Length); state = "$($_.State)"; next = $next }
                })
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes((@{ tasks = $tasks } | ConvertTo-Json -Depth 4 -Compress))
                $res.ContentType = "application/json; charset=utf-8"
                $res.OutputStream.Write($respBytes, 0, $respBytes.Length)
                $res.Close()
                continue
            }

            # 儲存設定後，依 config.schedules 一次同步所有 Windows 工作排程
            if ($path -eq "/api/register-schedules" -and $req.HttpMethod -eq "POST") {
                $reader = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                $body = $reader.ReadToEnd()
                $reader.Close()

                $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
                [System.IO.File]::WriteAllText($configPath, $body, $utf8NoBom)
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] 📅 已儲存設定並同步 Windows 工作排程..." -ForegroundColor Cyan

                $scriptPath = $PSCommandPath
                $reportFile = Join-Path $rootDir "logs\register_last.txt"
                Remove-Item $reportFile -Force -ErrorAction SilentlyContinue
                $proc = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -ConfigPath `"$configPath`" -RegisterSchedules" -WindowStyle Hidden -Wait -PassThru
                $report = if (Test-Path $reportFile) { [System.IO.File]::ReadAllText($reportFile, [System.Text.Encoding]::UTF8) } else { "未產生註冊結果，請查看 logs\register_last.txt" }
                Write-Host $report

                $respJson = @{ ok = ($proc.ExitCode -eq 0); report = $report } | ConvertTo-Json -Compress
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes($respJson)
                $res.ContentType = "application/json; charset=utf-8"
                $res.OutputStream.Write($respBytes, 0, $respBytes.Length)
                $res.Close()
                continue
            }

            # 「🔐 登入監控網站」：開啟專用 Edge (edge_profile) 讓使用者手動登入一次 (取代 login_setup.bat)
            if ($path -eq "/api/login-setup" -and $req.HttpMethod -eq "POST") {
                Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -ConfigPath `"$configPath`" -LoginMode" -WindowStyle Minimized
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] 🔐 已開啟專用 Edge 供登入監控網站，登入完成後關閉該視窗即可" -ForegroundColor Cyan
                $respBytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                $res.ContentType = "application/json; charset=utf-8"
                $res.OutputStream.Write($respBytes, 0, $respBytes.Length)
                $res.Close()
                continue
            }

            # 靜態檔案白名單：只提供設定工具、使用手冊與其圖片；config.json 等其他檔案一律不直接提供
            $relPath = $path.TrimStart('/')
            if ($relPath -eq "") { $relPath = "calibrator.html" }
            $allowed = $relPath -in @("calibrator.html", "sample_data.js", "USER_MANUAL.html") -or
                $relPath -match '^sample_images/[A-Za-z0-9_-]+\.png$'
            $filePath = Join-Path $rootDir ($relPath -replace '/', '\')

            if ($allowed -and (Test-Path $filePath -PathType Leaf)) {
                $ext = [System.IO.Path]::GetExtension($filePath).ToLower()
                $mime = switch ($ext) {
                    ".html" { "text/html; charset=utf-8" }
                    ".js"   { "application/javascript; charset=utf-8" }
                    ".png"  { "image/png" }
                    ".jpg"  { "image/jpeg" }
                    ".svg"  { "image/svg+xml" }
                    default { "application/octet-stream" }
                }
                $fileBytes = [System.IO.File]::ReadAllBytes($filePath)
                $res.ContentType = $mime
                $res.OutputStream.Write($fileBytes, 0, $fileBytes.Length)
            } else {
                $res.StatusCode = 404
            }
            $res.Close()
        } catch {
            # 單一請求出錯不可讓整個服務結束 (否則之後的儲存都會失敗，畫面卻看不出來)
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ⚠️ 處理請求時發生錯誤: $($_.Exception.Message)" -ForegroundColor Yellow
            try { $res.StatusCode = 500; $res.Close() } catch {}
            if (-not $listener.IsListening) { break }
        }
    }
    exit 0
}

# 尋找系統內建的 Microsoft Edge 或 Google Chrome (免安裝任何外部瀏覽器或外掛)
function Get-BrowserPath {
    $candidates = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
    )
    foreach ($p in $candidates) {
        if (Test-Path $p) { return $p }
    }
    throw "找不到系統內建的 Microsoft Edge 或 Chrome 瀏覽器！"
}

# 透過 .NET 內建 ClientWebSocket 發送 Chrome/Edge DevTools Protocol (CDP) 指令 (零外掛依賴)
function Invoke-CdpCommand($ws, [int]$id, [string]$method, [hashtable]$params = @{}) {
    $payload = @{ id = $id; method = $method; params = $params } | ConvertTo-Json -Depth 10 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $segment = [System.ArraySegment[byte]]::new($bytes)
    $ct = [System.Threading.CancellationToken]::None
    $ws.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $ct).GetAwaiter().GetResult() | Out-Null

    $buffer = New-Object byte[] 65536
    $sb = New-Object System.Text.StringBuilder
    while ($true) {
        $seg = [System.ArraySegment[byte]]::new($buffer)
        $res = $ws.ReceiveAsync($seg, $ct).GetAwaiter().GetResult()
        $sb.Append([System.Text.Encoding]::UTF8.GetString($buffer, 0, $res.Count)) | Out-Null
        if ($res.EndOfMessage) {
            $msgStr = $sb.ToString()
            $sb.Clear() | Out-Null
            try {
                $json = $msgStr | ConvertFrom-Json
                if ($json.id -eq $id) { return $json }
            } catch {}
        }
    }
}

$profileDir = Join-Path $PSScriptRoot "edge_profile"
if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Force -Path $profileDir | Out-Null }

# 關閉上一次殘留、使用本專案 edge_profile 的 Edge (只比對命令列中的 profile 路徑，不影響日常瀏覽器)
# 若殘留的 Edge 還開著，新的 Edge 會被併入舊程序，導致 CDP 除錯埠打不開
function Stop-ProfileEdge {
    $needle = $profileDir.ToLower()
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe' OR Name='chrome.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.ToLower().Contains("--user-data-dir=`"$needle`"") })
    if ($procs.Count -gt 0) {
        Write-Host "🧹 關閉上次殘留的專用 Edge ($($procs.Count) 個程序)" -ForegroundColor DarkGray
        $procs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 2
    }
}

# 等待 Edge CDP 除錯埠就緒 (公司電腦防毒掃描時 Edge 啟動可能較慢)
function Wait-CdpTargets([int]$port, [int]$timeoutSec = 20) {
    $deadline = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $deadline) {
        try { return Invoke-RestMethod -Uri "http://127.0.0.1:$port/json" -TimeoutSec 3 } catch { Start-Sleep -Milliseconds 500 }
    }
    throw "等待 Edge 除錯埠 $port 逾時 ($timeoutSec 秒)，請確認 Edge 是否被其他程序佔用"
}

# ==============================================================================
# 模式 A：首次手動登入記憶模式 (-LoginMode)
# ==============================================================================
if ($LoginMode) {
    $browserExe = Get-BrowserPath
    $enabledPages = @($config.pages | Where-Object { $_.enabled -ne $false })
    $urls = $enabledPages | ForEach-Object { "`"$($_.url)`"" }
    $argStr = "--user-data-dir=`"$profileDir`" --new-window " + ($urls -join " ")

    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "🔓 [首次登入記憶模式] 已開啟公司內建瀏覽器 (免外掛)" -ForegroundColor Cyan
    Write-Host "👉 1. 請在彈出的瀏覽器視窗中，輸入帳號密碼登入各頁面（可勾選『記住我』或儲存密碼）。" -ForegroundColor Yellow
    Write-Host "👉 2. 確認所有分頁都能正常看到監控圖表後，請直接【關閉該瀏覽器視窗】。" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Cyan

    $proc = Start-Process -FilePath $browserExe -ArgumentList $argStr -PassThru
    $proc.WaitForExit()
    Write-Host "✅ 登入狀態與 Cookie 已永久保存於 $profileDir ！" -ForegroundColor Green
    exit 0
}

# ==============================================================================
# 函數：使用內建 Edge CDP 自動開啟網頁、自動填帳密登入、並擷取特定區域畫面
# ==============================================================================
function Capture-PagesNative($pagesToCapture, $authCfg, [string]$outDir) {
    $browserExe = Get-BrowserPath
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }

    Stop-ProfileEdge
    $debugPort = 9333
    # 參考公司內部 46518 實測經驗：加入防止 Edge 背景分頁休眠/凍結參數
    # --force-device-scale-factor=1：筆電顯示比例 125%/150% 時，截圖座標仍與設定工具一致
    $argList = "--remote-debugging-port=$debugPort --user-data-dir=`"$profileDir`" --window-size=1920,1080 --force-device-scale-factor=1 --disable-background-timer-throttling --disable-backgrounding-occluded-windows --disable-renderer-backgrounding about:blank"
    $proc = Start-Process -FilePath $browserExe -ArgumentList $argList -PassThru

    $capturedMap = @{}
    try {
        $targets = Wait-CdpTargets $debugPort
        $pageTarget = $targets | Where-Object { $_.type -eq "page" -and $_.url -notlike "chrome-extension://*" -and $_.url -notlike "edge://*" } | Select-Object -First 1
        if (-not $pageTarget) {
            $pageTarget = $targets | Where-Object { $_.type -eq "page" } | Select-Object -First 1
        }
        $wsUrl = $pageTarget.webSocketDebuggerUrl

        $ws = [System.Net.WebSockets.ClientWebSocket]::new()
        $ct = [System.Threading.CancellationToken]::None
        $ws.ConnectAsync([Uri]$wsUrl, $ct).GetAwaiter().GetResult() | Out-Null

        $cmdId = 1
        Invoke-CdpCommand $ws ($cmdId++) "Page.enable" | Out-Null
        Invoke-CdpCommand $ws ($cmdId++) "Runtime.enable" | Out-Null
        # 固定網頁可視範圍為 1920x1080、縮放 1 倍：不受視窗邊框與 Windows 顯示比例影響，抓圖預覽與排程截圖座標一致
        Invoke-CdpCommand $ws ($cmdId++) "Emulation.setDeviceMetricsOverride" @{ width = 1920; height = 1080; deviceScaleFactor = 1; mobile = $false } | Out-Null
        # 強制喚醒背景分頁狀態為 active (避免 Edge 背景凍結導致延遲，參考 46518 10/29 修正)
        Invoke-CdpCommand $ws ($cmdId++) "Page.bringToFront" | Out-Null
        try { Invoke-CdpCommand $ws ($cmdId++) "Page.setWebLifecycleState" @{ state = "active" } | Out-Null } catch {}

        $idx = 0
        foreach ($p in $pagesToCapture) {
            $idx++
            Write-Host "🌐 [$idx/$($pagesToCapture.Count)] 正在開啟 $($p.name): $($p.url)" -ForegroundColor Cyan
            Invoke-CdpCommand $ws ($cmdId++) "Page.bringToFront" | Out-Null
            try { Invoke-CdpCommand $ws ($cmdId++) "Page.setWebLifecycleState" @{ state = "active" } | Out-Null } catch {}
            Invoke-CdpCommand $ws ($cmdId++) "Page.navigate" @{ url = $p.url } | Out-Null
            Start-Sleep -Seconds 3

            # 智慧檢查頁面是否出現密碼框，若出現則自動填入帳號密碼並送出
            if ($authCfg.enabled -and $authCfg.username -and $authCfg.username -ne "YOUR_USERNAME") {
                $uEsc = $authCfg.username.Replace("'", "\'")
                $pEsc = $authCfg.password.Replace("'", "\'")
                $jsLogin = @"
(function(){
    var pwd = document.querySelector('input[type="password"]');
    if (!pwd || pwd.offsetParent === null) return 'NO_LOGIN_NEEDED';
    var user = document.querySelector('input#name, input[name="name"], input[name*="user" i], input[name*="login" i], input[name*="id" i], input[type="text"]');
    if (user) {
        user.value = '$uEsc';
        user.dispatchEvent(new Event('input', { bubbles: true }));
        user.dispatchEvent(new Event('change', { bubbles: true }));
    }
    pwd.value = '$pEsc';
    pwd.dispatchEvent(new Event('input', { bubbles: true }));
    pwd.dispatchEvent(new Event('change', { bubbles: true }));
    var btn = document.querySelector('button#enter, button[type="submit"], input[type="submit"]');
    if (btn) { btn.click(); return 'CLICKED_SUBMIT'; }
    if (pwd.form) { pwd.form.submit(); return 'FORM_SUBMITTED'; }
    return 'FILLED';
})()
"@
                $evalRes = Invoke-CdpCommand $ws ($cmdId++) "Runtime.evaluate" @{ expression = $jsLogin; returnByValue = $true }
                $loginStatus = $evalRes.result.result.value
                if ($loginStatus -and $loginStatus -ne "NO_LOGIN_NEEDED") {
                    Write-Host "  🔐 偵測到登入畫面，已自動填入帳密送出 ($loginStatus)，等待跳轉..." -ForegroundColor Yellow
                    Start-Sleep -Seconds 4
                    Invoke-CdpCommand $ws ($cmdId++) "Page.navigate" @{ url = $p.url } | Out-Null
                }
            }

            $waitSec = if ($p.wait_seconds) { [int]$p.wait_seconds } else { 5 }
            Start-Sleep -Seconds $waitSec

            $shotParams = @{ format = "png" }
            if ($p.crop_region -and $p.crop_region.enabled -and [int]$p.crop_region.w -gt 0 -and [int]$p.crop_region.h -gt 0) {
                $shotParams["clip"] = @{
                    x = [double]$p.crop_region.x
                    y = [double]$p.crop_region.y
                    width = [double]$p.crop_region.w
                    height = [double]$p.crop_region.h
                    scale = 1
                }
            }

            $shotRes = Invoke-CdpCommand $ws ($cmdId++) "Page.captureScreenshot" $shotParams
            $b64Data = $shotRes.result.data
            $outFile = Join-Path $outDir "$($p.id).png"
            $rawBytes = [Convert]::FromBase64String($b64Data)
            if ($rawBytes.Length -gt 10485760) {
                Write-Host "  ⚠️ 警告: 單張截圖超過 Teams 10 MiB 上限 ($($rawBytes.Length) bytes)" -ForegroundColor Yellow
            }
            [System.IO.File]::WriteAllBytes($outFile, $rawBytes)
            Write-Host "  📸 已擷取畫面 ($($rawBytes.Length) bytes) -> $outFile" -ForegroundColor Green
            $capturedMap[$p.id] = $outFile
        }

        $ws.Dispose()
    } finally {
        if ($proc -and -not $proc.HasExited) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
        Stop-ProfileEdge
    }
    return $capturedMap
}

# ==============================================================================
# 函數：判斷單一像素是否屬於數據趨勢曲線
# ==============================================================================
function Test-CurvePixel($r, $g, $b, $rule) {
    if ($rule.color_mode -eq "custom" -and $rule.target_color) {
        $hex = $rule.target_color.TrimStart('#')
        $tr = [Convert]::ToInt32($hex.Substring(0,2), 16)
        $tg = [Convert]::ToInt32($hex.Substring(2,2), 16)
        $tb = [Convert]::ToInt32($hex.Substring(4,2), 16)
        $dist = [Math]::Sqrt([Math]::Pow($r - $tr, 2) + [Math]::Pow($g - $tg, 2) + [Math]::Pow($b - $tb, 2))
        $tol = if ($rule.color_tolerance) { [double]$rule.color_tolerance } else { 48.0 }
        return ($dist -le $tol)
    }

    $maxC = [Math]::Max($r, [Math]::Max($g, $b))
    $minC = [Math]::Min($r, [Math]::Min($g, $b))
    $sat = $maxC - $minC
    $lum = 0.299 * $r + 0.587 * $g + 0.114 * $b

    if ($lum -gt 206 -and $sat -lt 28) { return $false }
    if ($r -gt 200 -and ($r - $g) -gt 15 -and $g -gt 160 -and $b -gt 160) { return $false }

    return ($lum -lt 192 -or $sat -ge 30)
}

# ==============================================================================
# 函數：發送指定圖片清單與文字至指定的 Teams 對話 (支援：1.直接以Email/連結喚醒指定對話 2.背景Webhook直傳 3.名稱搜尋)
# ==============================================================================
# ==============================================================================
# 桌面版 Teams 視窗定位：找視窗 → 還原縮小 → 拉到最前 → 用 UI Automation 把游標放進「輸入訊息」框
# 任何一步確認失敗就停止，絕不盲貼到其他視窗
# ==============================================================================
function Get-TeamsWindowHandle([string]$titleHint) {
    $p = Get-Process -Name ms-teams, Teams -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $p -and $titleHint) {
        $p = Get-Process | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle -like "*$titleHint" } | Select-Object -First 1
    }
    if ($p) { return $p.MainWindowHandle }
    return [IntPtr]::Zero
}

function Set-WindowForeground([IntPtr]$hwnd) {
    for ($i = 0; $i -lt 5; $i++) {
        if ([E3Win]::IsIconic($hwnd)) {
            [E3Win]::ShowWindow($hwnd, 9) | Out-Null   # SW_RESTORE：還原縮小的視窗
            Start-Sleep -Milliseconds 600
        }
        # 先按放一次 Alt 解除 Windows 前景鎖定，再暫時連結輸入佇列把視窗拉到最前
        [E3Win]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero)
        [E3Win]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
        $fgThread = [E3Win]::GetWindowThreadProcessId([E3Win]::GetForegroundWindow(), [IntPtr]::Zero)
        $myThread = [E3Win]::GetCurrentThreadId()
        [E3Win]::AttachThreadInput($myThread, $fgThread, $true) | Out-Null
        [E3Win]::BringWindowToTop($hwnd) | Out-Null
        [E3Win]::SetForegroundWindow($hwnd) | Out-Null
        [E3Win]::AttachThreadInput($myThread, $fgThread, $false) | Out-Null
        Start-Sleep -Milliseconds 400
        if ([E3Win]::GetForegroundWindow() -eq $hwnd) { return $true }
    }
    return $false
}

function Find-TeamsComposeBox([IntPtr]$hwnd) {
    $A = [System.Windows.Automation.AutomationElement]
    $scope = [System.Windows.Automation.TreeScope]::Descendants
    $root = $A::FromHandle($hwnd)
    $editCond = New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)
    for ($i = 0; $i -lt 12; $i++) {
        # Teams (WebView2) 的協助工具樹要先被完整查詢過一次才會建立，第一次查不到輸入框屬正常
        if ($i % 4 -eq 0) { $root.FindAll($scope, [System.Windows.Automation.Condition]::TrueCondition) | Out-Null }
        $boxes = @($root.FindAll($scope, $editCond) | Where-Object {
            -not $_.Current.IsOffscreen -and
            ($_.Current.AutomationId -like "new-message-*" -or $_.Current.Name -match '輸入訊息|Type a message|Type a new message')
        })
        if ($boxes.Count -gt 0) { return $boxes[-1] }
        Start-Sleep -Milliseconds 800
    }
    return $null
}

function Set-TeamsComposeFocus([IntPtr]$hwnd) {
    $box = Find-TeamsComposeBox $hwnd
    if (-not $box) { return $false }
    try { $box.SetFocus() } catch {}
    Start-Sleep -Milliseconds 300
    if (-not $box.Current.HasKeyboardFocus) {
        # SetFocus 沒生效時，改用滑鼠點一下輸入框左側
        $r = $box.Current.BoundingRectangle
        [E3Win]::SetCursorPos([int]($r.X + 40), [int]($r.Y + $r.Height / 2)) | Out-Null
        [E3Win]::mouse_event(0x2, 0, 0, 0, [UIntPtr]::Zero)
        [E3Win]::mouse_event(0x4, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 400
    }
    return $true
}

# 每次貼上 / 按 Enter 前確認 Teams 仍在最前面且游標在輸入框 (使用者中途點到別的視窗時會自動拉回)
function Confirm-TeamsReady([IntPtr]$hwnd) {
    if ([E3Win]::GetForegroundWindow() -eq $hwnd) { return }
    Write-Host "🔁 Teams 不在最前面，重新切回 Teams..." -ForegroundColor Yellow
    if (-not (Set-WindowForeground $hwnd)) { throw "無法把 Teams 視窗切到最前面，已停止貼上 (避免貼到其他視窗)" }
    if (-not (Set-TeamsComposeFocus $hwnd)) { throw "找不到 Teams「輸入訊息」框，已停止貼上" }
}

function Send-GroupToTeams([string]$targetChatName, [string[]]$imageFiles, [string]$messageText, $teamsCfg, [bool]$isDryRun) {
    # 【模式 A】若設定了 Teams Webhook URL，直接從背景透過 HTTP POST 傳送 (完全不需開啟 Teams 視窗！)
    if ($teamsCfg.webhook_url -and $teamsCfg.webhook_url.Trim() -like "http*") {
        Write-Host "🌐 [Teams Webhook] 正在從背景直接發送至指定對話 (免開 Teams 視窗)..." -ForegroundColor Cyan
        $cardBody = @()
        foreach ($imgFile in $imageFiles) {
            if (-not (Test-Path $imgFile)) { continue }
            # 自動將圖片轉為壓縮 JPEG Base64 以符合 Teams Webhook 卡片限制
            $srcBmp = [System.Drawing.Bitmap]::new($imgFile)
            $ms = New-Object System.IO.MemoryStream
            $srcBmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Jpeg)
            $b64 = [Convert]::ToBase64String($ms.ToArray())
            $ms.Dispose()
            $srcBmp.Dispose()
            $cardBody += @{
                type = "Image"
                url = "data:image/jpeg;base64,$b64"
                size = "Stretch"
            }
        }
        $cardBody += @{
            type = "TextBlock"
            text = $messageText
            wrap = $true
            weight = "Bolder"
        }
        $payload = @{
            type = "message"
            attachments = @(
                @{
                    contentType = "application/vnd.microsoft.card.adaptive"
                    content = @{
                        '$schema' = "http://adaptivecards.io/schemas/adaptive-card.json"
                        type = "AdaptiveCard"
                        version = "1.4"
                        body = $cardBody
                    }
                }
            )
        } | ConvertTo-Json -Depth 15 -Compress

        Invoke-RestMethod -Uri $teamsCfg.webhook_url.Trim() -Method Post -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) | Out-Null
        Write-Host "✅ [Teams Webhook] 已成功從背景直接傳送至您的指定 Teams 對話！" -ForegroundColor Green
        return
    }

    # 【模式 B】參考同事 46518 作法：在已登入的 Edge (Teams Web) 內使用 DataTransfer + File 頁面內貼上事件 (不搶 Windows 系統剪貼簿！)
    if ($teamsCfg.send_mode -eq "edge_teams_web") {
        $browserExe = Get-BrowserPath
        $targetUrl = $targetChatName.Trim()
        if ($targetUrl -match "/l/message/([^/\?]+)") {
            $chatId = $Matches[1]
            $targetUrl = "https://teams.microsoft.com/l/chat/$chatId/0"
        }
        Write-Host "🌐 [Teams Web DataTransfer 模式] 正在開啟 Edge Teams 網頁版: $targetUrl" -ForegroundColor Cyan
        Stop-ProfileEdge
        $debugPort = 9334
        $argList = "--remote-debugging-port=$debugPort --user-data-dir=`"$profileDir`" --window-size=1600,1050 --disable-background-timer-throttling --disable-backgrounding-occluded-windows --disable-renderer-backgrounding `"$targetUrl`""
        $proc = Start-Process -FilePath $browserExe -ArgumentList $argList -PassThru
        Start-Sleep -Seconds 6

        try {
            $targets = Wait-CdpTargets $debugPort
            $pageTarget = $targets | Where-Object { $_.type -eq "page" -and $_.url -like "*teams*" } | Select-Object -First 1
            if (-not $pageTarget) { $pageTarget = $targets | Where-Object { $_.type -eq "page" } | Select-Object -First 1 }
            $ws = [System.Net.WebSockets.ClientWebSocket]::new()
            $ct = [System.Threading.CancellationToken]::None
            $ws.ConnectAsync([Uri]$pageTarget.webSocketDebuggerUrl, $ct).GetAwaiter().GetResult() | Out-Null

            $cmdId = 100
            Invoke-CdpCommand $ws ($cmdId++) "Page.enable" | Out-Null
            Invoke-CdpCommand $ws ($cmdId++) "Runtime.enable" | Out-Null
            Invoke-CdpCommand $ws ($cmdId++) "Page.bringToFront" | Out-Null
            try { Invoke-CdpCommand $ws ($cmdId++) "Page.setWebLifecycleState" @{ state = "active" } | Out-Null } catch {}

            # 依 46518 規範：每則 reply 最多 4 張圖片，以 DataTransfer File 物件注入 Teams 編輯器
            foreach ($imgFile in $imageFiles) {
                if (-not (Test-Path $imgFile)) { continue }
                $b64Img = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($imgFile))
                $fileName = [System.IO.Path]::GetFileName($imgFile)
                $jsPasteImg = @"
(function(){
    var editor = document.querySelector('div[contenteditable="true"][role="textbox"], div[data-tid="ckeditor"], div[contenteditable="true"]');
    if (!editor) return 'NO_EDITOR';
    editor.focus();
    var bin = atob('$b64Img');
    var arr = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
    var file = new File([arr], '$fileName', { type: 'image/png' });
    var dt = new DataTransfer();
    dt.items.add(file);
    var evt = new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true });
    editor.dispatchEvent(evt);
    return 'PASTED_DATA_TRANSFER';
})()
"@
                Invoke-CdpCommand $ws ($cmdId++) "Runtime.evaluate" @{ expression = $jsPasteImg; returnByValue = $true } | Out-Null
                Write-Host "  📋 [DataTransfer] 已注入圖片 File: $fileName" -ForegroundColor Green
                Start-Sleep -Seconds 2
            }

            $msgEsc = $messageText.Replace('\', '\\').Replace("'", "\'").Replace("`r", "").Replace("`n", "\n")
            $jsInsertText = @"
(function(){
    var editor = document.querySelector('div[contenteditable="true"][role="textbox"], div[data-tid="ckeditor"], div[contenteditable="true"]');
    if (!editor) return 'NO_EDITOR';
    editor.focus();
    document.execCommand('insertText', false, '$msgEsc');
    return 'TEXT_INSERTED';
})()
"@
            Invoke-CdpCommand $ws ($cmdId++) "Runtime.evaluate" @{ expression = $jsInsertText; returnByValue = $true } | Out-Null
            Start-Sleep -Seconds 3  # 等待圖片模型上傳完成 (預覽出現後需等待上傳完畢)

            if (-not $isDryRun -and $teamsCfg.auto_press_enter -ne $false) {
                $jsSend = @"
(function(){
    var sendBtn = document.querySelector('button[data-tid="newMessageCommands-send"], button[name="send"], button[title*="傳送"], button[title*="Send"]');
    if (sendBtn && !sendBtn.disabled) { sendBtn.click(); return 'SENT'; }
    return 'WAIT_OR_MANUAL';
})()
"@
                Invoke-CdpCommand $ws ($cmdId++) "Runtime.evaluate" @{ expression = $jsSend; returnByValue = $true } | Out-Null
                Write-Host "✅ [Teams Web DataTransfer] 已完成圖片模型上傳並送出訊息！" -ForegroundColor Green
                # 已送出則關閉此專用 Edge，避免殘留佔用 edge_profile 影響下一個排程 (預覽模式保留視窗供人工確認)
                Start-Sleep -Seconds 5
                $ws.Dispose()
                Stop-ProfileEdge
                return
            }
            $ws.Dispose()
        } catch {
            Write-Host "⚠️ [Teams Web DataTransfer] 發生例外: $($_.Exception.Message)" -ForegroundColor Yellow
        }
        return
    }

    # 【模式 C】透過 msteams:// 協定直接自動喚醒桌面版 Teams 並精準跳轉至「您的個人 Email」或「指定對話連結」
    $targetTrim = if ($targetChatName) { $targetChatName.Trim() } else { "" }
    $usedDeepLink = $false

    if ($targetTrim -like "*@*.*") {
        $deepLink = "msteams:/l/chat/0/0?users=$targetTrim"
        Write-Host "🎯 [Teams 自動定位] 正在自動喚醒 Teams 並直接開啟【$targetTrim】的專屬對話..." -ForegroundColor Cyan
        Start-Process $deepLink
        $usedDeepLink = $true
        Start-Sleep -Seconds 4
    } elseif ($targetTrim -like "https://teams.microsoft.com/*" -or $targetTrim -like "msteams:/*") {
        if ($targetTrim -match "/l/message/([^/\?]+)") {
            $chatId = $Matches[1]
            $deepLink = "msteams:/l/chat/$chatId/0"
        } else {
            $deepLink = $targetTrim -replace "^https://teams\.microsoft\.com/", "msteams:/"
        }
        Write-Host "🎯 [Teams 自動定位] 正在透過專屬連結直接開啟指定對話 ($deepLink)..." -ForegroundColor Cyan
        Start-Process $deepLink
        $usedDeepLink = $true
        Start-Sleep -Seconds 4
    }

    $winTitle = if ($teamsCfg.desktop_window_title) { $teamsCfg.desktop_window_title } else { "Teams" }
    $teamsHwnd = [IntPtr]::Zero
    $guarded = $false   # true = 每次貼上前都確認 Teams 在最前面

    if ($CountdownSeconds -gt 0 -and -not $usedDeepLink) {
        Write-Host ""
        Write-Host "🔒 【安全防傳錯保護】請確認 Teams 停留在您【自己的個人對話框】打字欄內！" -ForegroundColor Yellow
        for ($s = $CountdownSeconds; $s -ge 1; $s--) {
            Write-Host "   ⏳ 倒數 $s 秒後開始貼入..." -ForegroundColor Cyan
            Start-Sleep -Seconds 1
        }
    } elseif ($script:Win32Ready) {
        $teamsHwnd = Get-TeamsWindowHandle $winTitle
        if ($teamsHwnd -eq [IntPtr]::Zero) {
            Write-Host "🔄 找不到 Teams 視窗，正在啟動 Microsoft Teams..." -ForegroundColor Yellow
            Start-Process "msteams:" -ErrorAction SilentlyContinue
            for ($w = 0; $w -lt 20 -and $teamsHwnd -eq [IntPtr]::Zero; $w++) {
                Start-Sleep -Seconds 1
                $teamsHwnd = Get-TeamsWindowHandle $winTitle
            }
            if ($teamsHwnd -eq [IntPtr]::Zero) { throw "找不到桌面版 Teams 視窗，請確認 Teams 已開啟並登入" }
            if ($usedDeepLink) { Start-Process $deepLink; Start-Sleep -Seconds 4 }
        }
        if (-not (Set-WindowForeground $teamsHwnd)) {
            throw "無法把 Teams 視窗切到最前面 (可能螢幕已鎖定)，已停止貼上"
        }
        Write-Host "🪟 [Teams] 已將 Teams 視窗切到最前面" -ForegroundColor Gray
        $guarded = $true
    } else {
        $wshell = New-Object -ComObject WScript.Shell
        if (-not $wshell.AppActivate($winTitle)) {
            Write-Host "🔄 正在嘗試自動啟動 Microsoft Teams..." -ForegroundColor Yellow
            Start-Process "msteams:" -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 4
            if (-not $wshell.AppActivate($winTitle)) { throw "無法切換到 Teams 視窗，已停止貼上" }
        }
        Start-Sleep -Milliseconds 800
    }

    if (-not $usedDeepLink -and $teamsCfg.auto_switch_chat -and $targetTrim -ne "") {
        Write-Host "🔎 [Teams] 正在自動切換至指定聊天室/群組: $targetTrim" -ForegroundColor Cyan
        [System.Windows.Forms.SendKeys]::SendWait("^e")
        Start-Sleep -Milliseconds 600
        [System.Windows.Forms.Clipboard]::SetText($targetTrim)
        Start-Sleep -Milliseconds 300
        [System.Windows.Forms.SendKeys]::SendWait("^v")
        Start-Sleep -Milliseconds 1200
        [System.Windows.Forms.SendKeys]::SendWait("{DOWN}")
        Start-Sleep -Milliseconds 300
        [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
        Start-Sleep -Milliseconds 1200
    }

    if ($guarded) {
        if (-not (Set-TeamsComposeFocus $teamsHwnd)) {
            throw "找不到 Teams「輸入訊息」框 (對話可能還沒載入完成)，已停止貼上"
        }
        Write-Host "⌨️ [Teams] 已將游標放到「輸入訊息」框" -ForegroundColor Gray
    }

    # 參考同事 46518 實測限制：Teams 單一訊息最多夾帶 4 張圖片 (合計 <= 25 MiB)，若超過 4 張自動分批貼上送出
    $batchSize = 4
    for ($b = 0; $b -lt $imageFiles.Count; $b += $batchSize) {
        $batchImgs = $imageFiles[$b..([Math]::Min($b + $batchSize - 1, $imageFiles.Count - 1))]
        foreach ($imgFile in $batchImgs) {
            if (-not (Test-Path $imgFile)) { continue }
            if ($guarded) { Confirm-TeamsReady $teamsHwnd }
            Write-Host "📋 [Teams -> $targetChatName] 正在貼上圖片: $imgFile" -ForegroundColor Gray
            $imgObj = [System.Drawing.Image]::FromFile($imgFile)
            [System.Windows.Forms.Clipboard]::SetImage($imgObj)
            Start-Sleep -Milliseconds 400
            [System.Windows.Forms.SendKeys]::SendWait("^v")
            Start-Sleep -Milliseconds 1800  # 預留時間等待 Teams 圖片模型上傳完成 (避免預覽出現但尚未上傳完畢)
            $imgObj.Dispose()
        }

        # 最後一批圖片附上總結與異常罐頭語
        if (($b + $batchSize) -ge $imageFiles.Count) {
            if ($guarded) { Confirm-TeamsReady $teamsHwnd }
            Write-Host "📝 [Teams -> $targetChatName] 正在貼上總結與罐頭語..." -ForegroundColor Gray
            [System.Windows.Forms.Clipboard]::SetText($messageText)
            Start-Sleep -Milliseconds 400
            [System.Windows.Forms.SendKeys]::SendWait("^v")
            Start-Sleep -Milliseconds 1200
        }

        if (-not $isDryRun -and $teamsCfg.auto_press_enter -ne $false) {
            if ($guarded) { Confirm-TeamsReady $teamsHwnd }
            [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
            Start-Sleep -Seconds 2
            Write-Host "✅ [Teams -> $targetChatName] 已自動送出訊息！" -ForegroundColor Green
        } else {
            Write-Host "⏸️ [Teams -> $targetChatName] 已貼上圖文 (未按 Enter 送出)。" -ForegroundColor Yellow
        }
    }
}

# ==============================================================================
# 主流程：支援任意數量頁面、任意警戒線、以及分流發送到特定 Teams 群組
# ==============================================================================
# ==============================================================================
# 模式：calibrator「📸 抓圖」預覽 (-PreviewCapture -PageId <id> -Url <網址> -OutFile <png>)
# 與正式排程同一個已登入的 edge_profile、同樣 1920x1080 可視範圍，但不裁切，供設定工具框選擷取範圍
# ==============================================================================
if ($PreviewCapture) {
    $logDir = Join-Path $PSScriptRoot "logs"
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
    $reportFile = Join-Path $logDir "preview_last.txt"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $previewOk = $false
    $mutex = New-Object System.Threading.Mutex($false, "Local\E3MonitorNativeRun")
    $hasLock = $false
    try {
        if ($PageId -notmatch '^[A-Za-z0-9_-]+$') { throw "頁面 id 格式不正確: '$PageId'" }
        if ($Url -notmatch '^https?://') { throw "網址需以 http:// 或 https:// 開頭" }
        try { $hasLock = $mutex.WaitOne([TimeSpan]::FromSeconds(10)) } catch [System.Threading.AbandonedMutexException] { $hasLock = $true }
        if (-not $hasLock) { throw "排程正在執行中，請稍後再抓圖" }

        $cfgPage = $config.pages | Where-Object { $_.id -eq $PageId } | Select-Object -First 1
        $wait = if ($cfgPage -and $cfgPage.wait_seconds) { [int]$cfgPage.wait_seconds } else { 5 }
        $previewPage = [pscustomobject]@{
            id = $PageId; name = "抓圖預覽 $PageId"; url = $Url; wait_seconds = $wait
            crop_region = [pscustomobject]@{ enabled = $false }
        }
        $tmpDir = Join-Path $env:TEMP "e3_preview_capture"
        $map = Capture-PagesNative @($previewPage) $config.auth $tmpDir
        $shot = $map[$PageId]
        if (-not $shot -or -not (Test-Path $shot)) { throw "沒有擷取到畫面" }
        Move-Item -Path $shot -Destination $OutFile -Force
        $previewOk = $true
        [System.IO.File]::WriteAllText($reportFile, "OK", $utf8NoBom)
    } catch {
        Write-Host "❌ 抓圖失敗: $($_.Exception.Message)" -ForegroundColor Red
        [System.IO.File]::WriteAllText($reportFile, $_.Exception.Message, $utf8NoBom)
    } finally {
        if ($hasLock) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
    exit $(if ($previewOk) { 0 } else { 1 })
}

$runSchedule = $null
if ($Schedule) {
    $runSchedule = Get-ScheduleList $config | Where-Object { $_.id -eq $Schedule } | Select-Object -First 1
    if (-not $runSchedule) {
        Write-Host "❌ config.json 找不到排程 id '$Schedule'" -ForegroundColor Red
        Show-ScheduleList $config
        exit 1
    }
}
$runTag = if ($runSchedule) { $runSchedule.id } else { "all" }

# 每次執行寫一份 log (排程在背景執行時沒有視窗可看)，保留 30 天
$logDir = Join-Path $PSScriptRoot "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
Get-ChildItem $logDir -Filter "*.log" -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } | Remove-Item -Force -ErrorAction SilentlyContinue
$logFile = Join-Path $logDir ("{0}_{1}.log" -f (Get-Date -Format "yyyy-MM-dd_HHmm"), $runTag)
try { Start-Transcript -Path $logFile -Append | Out-Null } catch {}

# 多個排程時間相近時依序執行 (共用 edge_profile 與 Teams 視窗/剪貼簿，不能同時跑)
$runMutex = New-Object System.Threading.Mutex($false, "Local\E3MonitorNativeRun")
$hasLock = $false
try { $hasLock = $runMutex.WaitOne([TimeSpan]::FromMinutes(30)) } catch [System.Threading.AbandonedMutexException] { $hasLock = $true }
if (-not $hasLock) {
    Write-Host "❌ 等待上一個排程執行完畢逾時 (30 分鐘)，本次 [$runTag] 取消" -ForegroundColor Red
    try { Stop-Transcript | Out-Null } catch {}
    exit 1
}

try {
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host "🚀 啟動 E3 彈性化監控截圖 & 警戒線檢查 (Windows 零外掛原生版)" -ForegroundColor Cyan
if ($runSchedule) {
    Write-Host "📅 排程: [$($runSchedule.id)] $($runSchedule.name)" -ForegroundColor Cyan
}
Write-Host "============================================================" -ForegroundColor Cyan

if ($runSchedule) {
    $enabledPages = @(Resolve-SchedulePages $config $runSchedule)
} else {
    $enabledPages = @($config.pages | Where-Object { $_.enabled -ne $false })
}
Write-Host "📌 本次要擷取的頁面數量: $($enabledPages.Count) 頁" -ForegroundColor Cyan
if ($enabledPages.Count -eq 0) {
    Write-Host "⚠️ 沒有可擷取的頁面，結束。" -ForegroundColor Yellow
    exit 0
}

if ($TestSample) {
    Write-Host "🧪 [範例測試模式] 使用 sample_images 資料夾中的截圖進行驗證..." -ForegroundColor Yellow
    $capturedFiles = @{}
    foreach ($p in $enabledPages) {
        $sampleFile = Join-Path $PSScriptRoot "sample_images\$($p.id).png"
        if (-not (Test-Path $sampleFile)) {
            # 不再拿 page1.png 代替，避免測試時送出別頁的圖
            Write-Host "⚠️ [$($p.id)] $($p.name) 還沒有範例圖 (sample_images\$($p.id).png)，請先在設定工具按 📸 抓圖；本次略過此頁" -ForegroundColor Yellow
            continue
        }
        $capturedFiles[$p.id] = $sampleFile
    }
} else {
    # 同一天多個排程分開存放：captures\<日期>\<排程id>_<HHmm>\
    $outDir = Join-Path $PSScriptRoot ("captures\{0}\{1}_{2}" -f (Get-Date -Format "yyyy-MM-dd"), $runTag, (Get-Date -Format "HHmm"))
    $capturedFiles = Capture-PagesNative $enabledPages $config.auth $outDir
}

# 發送對象優先順序：排程 target_chat_name > 頁面 target_chat_name > teams.target_chat_name
$defaultChat = if ($config.teams.target_chat_name) { $config.teams.target_chat_name } else { "預設Teams群組" }
$scheduleChat = if ($runSchedule -and $runSchedule.target_chat_name) { $runSchedule.target_chat_name.Trim() } else { "" }
# 用有序字典，讓多個群組依頁面順序發送
$chatGroups = [ordered]@{}

foreach ($page in $enabledPages) {
    $imgPath = $capturedFiles[$page.id]
    if (-not $imgPath -or -not (Test-Path $imgPath)) {
        Write-Host "⚠️ [$($page.id)] 沒有擷取到截圖，已略過" -ForegroundColor Yellow
        continue
    }

    $targetChat = if ($scheduleChat -ne "") {
        $scheduleChat
    } elseif ($page.target_chat_name -and $page.target_chat_name.Trim() -ne "") {
        $page.target_chat_name.Trim()
    } else {
        $defaultChat
    }

    if (-not $chatGroups.Contains($targetChat)) {
        $chatGroups[$targetChat] = @{
            images = @()
            alerts = @()
        }
    }

    # 沒有啟用中的警戒線 = 只截圖 (設定工具不再有「處理模式」選項；舊設定的 capture_only 仍然有效)
    $hasActiveRules = @($page.rules | Where-Object { $_ -and $_.enabled -ne $false }).Count -gt 0
    if ($page.mode -eq "capture_only" -or -not $hasActiveRules) {
        Write-Host "📸 [$($page.id)] $($page.name) (目標Teams: $targetChat) -> 純擷取畫面" -ForegroundColor Gray
        $chatGroups[$targetChat].images += $imgPath
        continue
    }

    $bmp = [System.Drawing.Bitmap]::new($imgPath)
    $annotated = [System.Drawing.Bitmap]::new($bmp)
    $g = [System.Drawing.Graphics]::FromImage($annotated)
    $pageHasAlert = $false

    $enabledRules = @($page.rules | Where-Object { $_.enabled -ne $false })
    foreach ($rule in $enabledRules) {
        $rx = [Math]::Max(0, [int]$rule.roi.x)
        $ry = [Math]::Max(0, [int]$rule.roi.y)
        if ($rx -ge $bmp.Width -or $ry -ge $bmp.Height) {
            # 擷取範圍縮小後，警戒線框可能落在圖外；略過此條並提醒，不讓整次執行失敗
            Write-Host "  ⚠️ [$($page.id)] $($rule.name) : 警戒線框 ($rx, $ry) 超出截圖範圍 ($($bmp.Width)x$($bmp.Height))，已略過，請在設定工具重新框選" -ForegroundColor Yellow
            continue
        }
        $rw = [Math]::Max(1, [Math]::Min($bmp.Width - $rx, [int]$rule.roi.w))
        $rh = [Math]::Max(1, [Math]::Min($bmp.Height - $ry, [int]$rule.roi.h))
        $threshY = [int]$rule.threshold_y
        $minPx = if ($rule.min_pixels) { [int]$rule.min_pixels } else { 2 }

        $hitCount = 0
        $maxCheckY = [Math]::Min($ry + $rh - 1, $threshY)

        for ($y = $ry; $y -le $maxCheckY; $y++) {
            for ($x = $rx; $x -lt ($rx + $rw); $x++) {
                $c = $bmp.GetPixel($x, $y)
                if (Test-CurvePixel $c.R $c.G $c.B $rule) {
                    $hitCount++
                }
            }
        }

        $exceeded = ($hitCount -ge $minPx)
        if ($exceeded) {
            $pageHasAlert = $true
            Write-Host "  🚨 [$($page.id)] $($rule.name) : 超過警戒線! (越線像素: $hitCount px, Y=$threshY)" -ForegroundColor Red
            $chatGroups[$targetChat].alerts += $rule.alert_message
            $penBox = [System.Drawing.Pen]::new([System.Drawing.Color]::Red, 2)
        } else {
            Write-Host "  ✅ [$($page.id)] $($rule.name) : 正常 (越線像素: $hitCount px, Y=$threshY)" -ForegroundColor Green
            $penBox = [System.Drawing.Pen]::new([System.Drawing.Color]::LimeGreen, 2)
        }

        $g.DrawRectangle($penBox, $rx, $ry, $rw, $rh)
        $penLine = [System.Drawing.Pen]::new([System.Drawing.Color]::Red, 2)
        $g.DrawLine($penLine, $rx - 5, $threshY, $rx + $rw + 5, $threshY)
        $penBox.Dispose()
        $penLine.Dispose()
    }

    $outAnnotated = Join-Path ([System.IO.Path]::GetDirectoryName($imgPath)) "annotated_$([System.IO.Path]::GetFileName($imgPath))"
    $annotated.Save($outAnnotated, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose()
    $annotated.Dispose()
    $bmp.Dispose()

    if ($pageHasAlert -and $config.teams.attach_annotated_image_on_alert) {
        $chatGroups[$targetChat].images += $outAnnotated
    } else {
        $chatGroups[$targetChat].images += $imgPath
    }
}

# 針對每個目標 Teams 群組產生總結並發送
foreach ($chatName in @($chatGroups.Keys)) {
    $grp = $chatGroups[$chatName]
    $imgs = $grp.images
    $alerts = $grp.alerts

    if ($alerts.Count -eq 0) {
        $msg = $config.teams.normal_summary
    } else {
        $msg = $config.teams.abnormal_header + "`r`n" + ($alerts -join "`r`n")
    }
    if ($runSchedule -and $runSchedule.title) {
        $msg = $runSchedule.title + "`r`n" + $msg
    }

    Write-Host "`n------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "🎯 目標 Teams 群組/聊天室: 【$chatName】 (共 $($imgs.Count) 張圖)" -ForegroundColor Cyan
    Write-Host $msg -ForegroundColor $(if ($alerts.Count -eq 0) { "Green" } else { "Yellow" })
    Write-Host "------------------------------------------------------------" -ForegroundColor DarkGray

    # 發送對象仍是預設佔位文字時不貼，避免貼到目前開著的任意對話
    if (-not $NoSend -and ($chatName -match '請將.*連結|貼在這裡|^預設Teams群組$')) {
        Write-Host "⚠️ 尚未設定 Teams 發送對象 (目前為「$chatName」)，略過發送。請在 calibrator「排程與發送」貼上 Teams 連結。" -ForegroundColor Yellow
        $exitCode = 1
        continue
    }
    if (-not $NoSend) {
        Send-GroupToTeams -targetChatName $chatName -imageFiles $imgs -messageText $msg -teamsCfg $config.teams -isDryRun $DryRun
    }
}
} catch {
    Write-Host "❌ 執行發生錯誤: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    $exitCode = 1
} finally {
    $runMutex.ReleaseMutex()
    $runMutex.Dispose()
    try { Stop-Transcript | Out-Null } catch {}
}
if ($exitCode) { exit $exitCode }
