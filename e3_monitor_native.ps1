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
    [int]$PreviewZoom = 0,            # -PreviewCapture：目前選擇的網頁縮放百分比，0 = 讀 config
    [int]$PreviewWaitSeconds = 0,     # -PreviewCapture：目前選擇的載入等待秒數，0 = 讀 config
    [switch]$InteractiveCapture,     # -PreviewCapture：等待使用者捲動並按「擷取目前畫面」
    [switch]$TestSample = $false,
    [switch]$LoginMode = $false,
    [switch]$NoSend = $false,
    [switch]$DryRun = $false,
    [switch]$DetectTeams = $false,     # 只偵測開著的 Teams (PWA / 桌面版 / Edge 分頁) 並寫入 logs\teams_detect.txt，不切換、不貼上
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
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc f, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    public static string GetTitle(IntPtr h) { var sb = new System.Text.StringBuilder(1024); GetWindowText(h, sb, 1024); return sb.ToString(); }
    // 可見的頂層視窗：「hwnd|pid|標題」
    public static string[] ListWindows() {
        var r = new System.Collections.Generic.List<string>();
        EnumWindows((h, l) => { if (IsWindowVisible(h)) { var t = GetTitle(h); if (t.Length > 0) { uint p; GetWindowThreadProcessId(h, out p); r.Add(h.ToInt64() + "|" + p + "|" + t); } } return true; }, IntPtr.Zero);
        return r.ToArray();
    }
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



try {
    $config = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
} catch {
    # 設定工具服務照常啟動，讓網頁顯示格式錯誤的原因；其他模式 (排程、抓圖、測試) 不能用壞掉的設定執行
    Write-Host "❌ config.json 格式錯誤，無法讀取：$($_.Exception.Message)" -ForegroundColor Red
    if (-not $Calibrator) { exit 1 }
    $config = $null
}



$TaskPrefix = "E3_Monitor_"
$LegacyTaskName = "E3_Daily_Monitor_Teams"
# teams.normal_summary / abnormal_header 留空時的預設文字 (與 calibrator.html 預覽相同)
$DefaultNormalSummary = "目前E3系統正常"
$DefaultAbnormalHeader = "⚠️ 系統異常通知："
# 排程截圖 (captures\<日期>\) 保留天數；logs\*.log 另外保留 30 天
$CaptureKeepDays = 7



# 設定工具的範例圖 sample_images\ 中屬於某頁面的檔案：<id>.png、<id>_full.png、annotated_<id>.png、抓圖暫存 tmp_<id>_full.png(.json)
function Get-SampleImagePageId([string]$fileName) {
    if ($fileName -match '^(?:annotated_|tmp_)?(?<id>[A-Za-z0-9_-]+?)(?:_full)?\.png(?:\.json)?$') { return $Matches['id'] }
    return $null
}



# 刪除不在 config.pages 中的頁面留下的範例圖 (頁面被刪除後不再使用)；設定檔讀不到頁面時不刪任何檔案
function Remove-OrphanSampleImages($cfg, [string]$sampleDir) {
    if (-not (Test-Path $sampleDir)) { return 0 }
    $ids = @($cfg.pages | ForEach-Object { [string]$_.id } | Where-Object { $_ })
    if ($ids.Count -eq 0) { return 0 }
    $removed = 0
    foreach ($f in @(Get-ChildItem $sampleDir -File -ErrorAction SilentlyContinue)) {
        $id = Get-SampleImagePageId $f.Name
        if ($id -and $id -notin $ids) {
            try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $removed++ } catch {}
        }
    }
    return $removed
}



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
    $captureJob = $null   # 背景抓圖 (/api/capture-url → /api/capture-status)



    # 寫入設定工具送來的 config.json：先確認是可解析、含 pages 陣列的 JSON，再寫到暫存檔後整檔取代，
    # 避免格式錯誤或寫到一半的內容蓋掉原本的設定。格式不對時 throw，由呼叫端回 400。
    function Save-ConfigBody([string]$body) {
        try { $parsed = $body | ConvertFrom-Json -ErrorAction Stop } catch { throw "設定內容不是有效的 JSON，未儲存（$($_.Exception.Message)）" }
        if (-not $parsed -or $parsed -is [array] -or -not ($parsed.PSObject.Properties.Name -contains 'pages') -or $parsed.pages -isnot [array]) {
            throw "設定內容缺少 pages 清單，未儲存"
        }
        $tmp = "$configPath.saving"
        [System.IO.File]::WriteAllText($tmp, $body, (New-Object System.Text.UTF8Encoding($false)))
        try { [System.IO.File]::Replace($tmp, $configPath, $null) }
        catch { [System.IO.File]::Copy($tmp, $configPath, $true); Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }



    function Send-JsonError($res, [int]$status, [string]$message) {
        $res.StatusCode = $status
        $bytes = [System.Text.Encoding]::UTF8.GetBytes((@{ ok = $false; error = $message } | ConvertTo-Json -Compress))
        $res.ContentType = "application/json; charset=utf-8"
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
        $res.Close()
    }



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
    # 已刪除頁面留下的範例圖 (舊版刪除頁面時沒有一併刪圖)
    $orphans = Remove-OrphanSampleImages $config (Join-Path $rootDir "sample_images")
    if ($orphans -gt 0) { Write-Host "🧹 已刪除 $orphans 個不再使用的範例圖 (頁面已不在設定中)" -ForegroundColor DarkGray }
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



                try { Save-ConfigBody $body } catch {
                    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ❌ $($_.Exception.Message)" -ForegroundColor Red
                    Send-JsonError $res 400 $_.Exception.Message
                    continue
                }
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
                $requestedZoom = 0; $requestedWait = 0
                $validZoom = -not ($payload.PSObject.Properties.Name -contains 'browser_zoom') -or
                    ([int]::TryParse([string]$payload.browser_zoom, [ref]$requestedZoom) -and $requestedZoom -ge 50 -and $requestedZoom -le 200)
                $validWait = -not ($payload.PSObject.Properties.Name -contains 'wait_seconds') -or
                    ([int]::TryParse([string]$payload.wait_seconds, [ref]$requestedWait) -and $requestedWait -ge 1 -and $requestedWait -le 60)



                if ($pageId -notmatch '^[A-Za-z0-9_-]+$' -or $targetUrl -notmatch '^https?://' -or -not $validZoom -or -not $validWait) {
                    $respJson = @{ ok = $false; error = "頁面 id、網址、網頁縮放 (50～200%) 或等待秒數 (1～60) 格式不正確" } | ConvertTo-Json -Compress
                } elseif ($captureJob -and -not $captureJob.Proc.HasExited) {
                    $respJson = @{ ok = $false; error = "已有一個抓圖正在進行（$($captureJob.PageId)），請先在那個 Edge 視窗按「擷取目前畫面」或「取消」" } | ConvertTo-Json -Compress
                } else {
                    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] 📸 正在用已登入的 edge_profile 抓取畫面 ($pageId): $targetUrl" -ForegroundColor Cyan
                    $sampleDir = Join-Path $rootDir "sample_images"
                    if (-not (Test-Path $sampleDir)) { New-Item -ItemType Directory -Force -Path $sampleDir | Out-Null }
                    # 整頁原圖存成 <id>_full.png；裁切後的 <id>.png 由 calibrator 依擷取範圍產生後透過 /api/save-sample 寫回
                    $fullPng = Join-Path $sampleDir "${pageId}_full.png"
                    $tmpPng = Join-Path $sampleDir "tmp_${pageId}_full.png"
                    Remove-Item $tmpPng -Force -ErrorAction SilentlyContinue
                    Remove-Item ($tmpPng + '.json') -Force -ErrorAction SilentlyContinue



                    # 與正式排程使用同一個引擎與 edge_profile (含自動登入、網頁縮放、Zabbix 7d/now；-InteractiveCapture 由使用者捲動後選擇可視範圍)
                    $scriptPath = $PSCommandPath
                    $engineArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -ConfigPath `"$configPath`" -PreviewCapture -PageId $pageId -Url `"$targetUrl`" -OutFile `"$tmpPng`""
                    if ($requestedZoom) { $engineArgs += " -PreviewZoom $requestedZoom" }
                    if ($requestedWait) { $engineArgs += " -PreviewWaitSeconds $requestedWait" }
                    $engineArgs += ' -InteractiveCapture'
                    # 背景執行：使用者最多花 10 分鐘捲動、選擇位置，期間服務仍要處理自動存檔等請求；
                    # 結果由 GET /api/capture-status 取得 (前端每秒詢問一次)
                    Remove-Item (Join-Path $rootDir "logs\preview_last.txt") -Force -ErrorAction SilentlyContinue
                    $proc = Start-Process powershell -ArgumentList $engineArgs -WindowStyle Hidden -PassThru
                    $null = $proc.Handle   # 先取得程序 handle，結束後才讀得到 ExitCode
                    $captureJob = @{ Proc = $proc; PageId = $pageId; TmpPng = $tmpPng; FullPng = $fullPng }
                    $respJson = @{ ok = $true; pending = $true } | ConvertTo-Json -Compress
                }



                $respBytes = [System.Text.Encoding]::UTF8.GetBytes($respJson)
                $res.ContentType = "application/json; charset=utf-8"
                $res.OutputStream.Write($respBytes, 0, $respBytes.Length)
                $res.Close()
                continue
            }



            # 抓圖進度：進行中回傳 pending；完成後才把暫存圖移成 <id>_full.png 並回傳圖片 (結果只回傳一次)
            if ($path -eq "/api/capture-status" -and $req.HttpMethod -eq "GET") {
                if (-not $captureJob) {
                    $respJson = @{ ok = $false; error = "沒有進行中的抓圖" } | ConvertTo-Json -Compress
                } elseif (-not $captureJob.Proc.HasExited) {
                    $respJson = @{ ok = $true; pending = $true; pageId = $captureJob.PageId } | ConvertTo-Json -Compress
                } else {
                    $job = $captureJob
                    $captureJob = $null
                    $tmpPng = $job.TmpPng; $fullPng = $job.FullPng
                    if ($job.Proc.ExitCode -eq 0 -and (Test-Path $tmpPng) -and (Test-Path ($tmpPng + '.json'))) {
                        Move-Item $tmpPng $fullPng -Force
                        $imgBytes = [System.IO.File]::ReadAllBytes($fullPng)
                        $b64 = [Convert]::ToBase64String($imgBytes)
                        $bmp = [System.Drawing.Bitmap]::new($fullPng)
                        $w = $bmp.Width
                        $h = $bmp.Height
                        $bmp.Dispose()



                        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ✅ 成功擷取畫面 (${w}x${h}) -> $fullPng" -ForegroundColor Green
                        $captureView = (Get-Content -LiteralPath ($tmpPng + '.json') -Raw -Encoding UTF8 | ConvertFrom-Json).capture_view
                        Remove-Item ($tmpPng + '.json') -Force -ErrorAction SilentlyContinue
                        $respJson = @{ ok = $true; pageId = $job.PageId; width = $w; height = $h; capture_view = $captureView; dataUrl = "data:image/png;base64,$b64" } | ConvertTo-Json -Depth 5 -Compress
                    } else {
                        Remove-Item $tmpPng, ($tmpPng + '.json') -Force -ErrorAction SilentlyContinue
                        $reportFile = Join-Path $rootDir "logs\preview_last.txt"
                        $errText = if (Test-Path $reportFile) { [System.IO.File]::ReadAllText($reportFile, [System.Text.Encoding]::UTF8) } else { "無法連線或擷取該網址畫面" }
                        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ❌ 抓圖失敗: $errText" -ForegroundColor Red
                        $respJson = @{ ok = $false; pageId = $job.PageId; error = $errText } | ConvertTo-Json -Compress
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



                try { Save-ConfigBody $body } catch {
                    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ❌ $($_.Exception.Message)，未啟動測試" -ForegroundColor Red
                    Send-JsonError $res 400 $_.Exception.Message
                    continue
                }
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



            # 設定工具刪除頁面時，一併刪除該頁的範例圖 (<id>.png、<id>_full.png、annotated_<id>.png、抓圖暫存)
            if ($path -eq "/api/delete-sample" -and $req.HttpMethod -eq "POST") {
                $reader = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                $payload = $reader.ReadToEnd() | ConvertFrom-Json
                $reader.Close()
                $pageId = [string]$payload.pageId
                if ($pageId -match '^[A-Za-z0-9_-]+$') {
                    $sampleDir = Join-Path $rootDir "sample_images"
                    $removed = 0
                    foreach ($f in @(Get-ChildItem $sampleDir -File -ErrorAction SilentlyContinue)) {
                        if ((Get-SampleImagePageId $f.Name) -eq $pageId) {
                            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
                            if (-not (Test-Path -LiteralPath $f.FullName)) { $removed++ }
                        }
                    }
                    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] 🗑️ 已刪除頁面 $pageId 的 $removed 個範例圖" -ForegroundColor DarkGray
                    $respJson = (@{ ok = $true; removed = $removed } | ConvertTo-Json -Compress)
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



                try { Save-ConfigBody $body } catch {
                    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ❌ $($_.Exception.Message)，未同步排程" -ForegroundColor Red
                    Send-JsonError $res 400 $_.Exception.Message
                    continue
                }
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



            # 「🔍 偵測 Teams 視窗」：先存檔 (用畫面上最新的發送對象)，再以 -DetectTeams 列出開著的 Teams，不切換、不貼上
            if ($path -eq "/api/teams-detect" -and $req.HttpMethod -eq "POST") {
                $reader = New-Object System.IO.StreamReader($req.InputStream, [System.Text.Encoding]::UTF8)
                $body = $reader.ReadToEnd()
                $reader.Close()
                if ($body.Trim()) {
                    try { Save-ConfigBody $body } catch {
                        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] ❌ $($_.Exception.Message)，未偵測" -ForegroundColor Red
                        Send-JsonError $res 400 $_.Exception.Message
                        continue
                    }
                }



                $reportFile = Join-Path $rootDir "logs\teams_detect.txt"
                Remove-Item $reportFile -Force -ErrorAction SilentlyContinue
                Write-Host "[$(Get-Date -Format 'HH:mm:ss')] 🔍 正在偵測開著的 Teams..." -ForegroundColor Cyan
                $proc = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -ConfigPath `"$configPath`" -DetectTeams" -WindowStyle Hidden -Wait -PassThru
                $report = if (Test-Path $reportFile) { [System.IO.File]::ReadAllText($reportFile, [System.Text.Encoding]::UTF8) } else { "沒有產生偵測結果 (logs\teams_detect.txt)" }
                Write-Host $report



                $respBytes = [System.Text.Encoding]::UTF8.GetBytes((@{ ok = ($proc.ExitCode -eq 0); report = $report } | ConvertTo-Json -Compress))
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



# Teams 被關掉、又沒有 Teams PWA 捷徑與桌面版時，用預設瀏覽器開的 Teams 網頁版網址 (使用者現有的登入)
$TeamsWebHome = "https://teams.cloud.microsoft/"



# 透過 .NET 內建 ClientWebSocket 發送 Chrome/Edge DevTools Protocol (CDP) 指令 (零外掛依賴)
# 每個指令最多等 $TimeoutSeconds 秒：Edge 卡住時不會一直等到排程 1 小時上限 (逾時後這條連線會被中止，下一頁會重新連線)
function Invoke-CdpCommand($ws, [int]$id, [string]$method, [hashtable]$params = @{}, [int]$TimeoutSeconds = 60) {
    $payload = @{ id = $id; method = $method; params = $params } | ConvertTo-Json -Depth 10 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
    $segment = [System.ArraySegment[byte]]::new($bytes)
    $cts = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))
    try {
        $ws.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $cts.Token).GetAwaiter().GetResult() | Out-Null



        $buffer = New-Object byte[] 65536
        $sb = New-Object System.Text.StringBuilder
        while ($true) {
            $seg = [System.ArraySegment[byte]]::new($buffer)
            $res = $ws.ReceiveAsync($seg, $cts.Token).GetAwaiter().GetResult()
            if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { throw "Edge 已中斷除錯連線（$method）" }
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
    } catch {
        if ($cts.IsCancellationRequested) { throw "Edge 沒有回應（$method 超過 $TimeoutSeconds 秒）" }
        throw
    } finally {
        $cts.Dispose()
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
        Write-Host "🧹 關閉專用 Edge，等待正常結束" -ForegroundColor DarkGray
        $running = @($procs | ForEach-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue })
        foreach ($edgeProcess in $running) {
            try { $edgeProcess.CloseMainWindow() | Out-Null } catch {}
        }
        $closeDeadline = (Get-Date).AddSeconds(5)
        do {
            $remaining = @($running | Where-Object { -not $_.HasExited })
            if ($remaining.Count -eq 0) { break }
            Start-Sleep -Milliseconds 200
        } while ((Get-Date) -lt $closeDeadline)
        $remaining = @($running | Where-Object { -not $_.HasExited })
        if ($remaining.Count -gt 0) {
            Write-Host "  ⚠️ 專用 Edge 關閉逾時，強制清理剩餘程序" -ForegroundColor Yellow
            $remaining | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue }
            Start-Sleep -Seconds 2
        }
    }
}



# Browser.close 會中斷 CDP 連線，因此只限時送出，不等待一般指令的回覆。
# 使用本次截圖既有的連線，不連到可能由其他瀏覽器占用的除錯埠。
function Close-CaptureBrowser($ws) {
    if (-not $ws -or $ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) { return }
    $closeToken = [System.Threading.CancellationTokenSource]::new(3000)
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"id":2147483647,"method":"Browser.close"}')
        $ws.SendAsync([System.ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text,
            $true, $closeToken.Token).GetAwaiter().GetResult() | Out-Null
        Write-Host "🧹 已要求專用 Edge 正常關閉" -ForegroundColor DarkGray
        Start-Sleep -Seconds 2
    } catch {
        Write-Host "  ⚠️ 無法透過 CDP 關閉專用 Edge，改用視窗關閉流程" -ForegroundColor Yellow
    } finally {
        $closeToken.Dispose()
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


# 在頁面執行 JavaScript，回傳結果值 (字串)
function Invoke-CdpEval($ws, [int]$id, [string]$js) {
    $r = Invoke-CdpCommand $ws $id "Runtime.evaluate" @{ expression = $js; returnByValue = $true }
    return [string]$r.result.result.value
}



function Test-AuthConfigured($authCfg) {
    return [bool]($authCfg -and $authCfg.enabled -and $authCfg.username -and $authCfg.username -ne "YOUR_USERNAME")
}



# ---- 自動登入用的頁面腳本 ----
# 看得到的「Login / Log in / Sign in / 登入」按鈕或連結 (例如 Zabbix「You are not logged in」提示頁的 Login 按鈕)
$JsFindLoginButton = @'
function e3FindLoginButton() {
    var rx = /^(log\s*in|sign\s*in|登入|登錄|登录)$/i;
    var els = document.querySelectorAll('button, a, input[type="button"], input[type="submit"], [role="button"]');
    for (var i = 0; i < els.length; i++) {
        var t = (els[i].innerText || els[i].value || els[i].textContent || '').replace(/\s+/g, ' ').trim();
        if (els[i].offsetParent !== null && rx.test(t)) return els[i];
    }
    return null;
}
'@
# 回傳 PASSWORD (有看得到的密碼框) / LOGIN_BUTTON (只有 Login 按鈕) / NONE
$JsLoginState = $JsFindLoginButton + @'
(function () {
    var ps = document.querySelectorAll('input[type="password"]');
    for (var i = 0; i < ps.length; i++) if (ps[i].offsetParent !== null) return 'PASSWORD';
    return e3FindLoginButton() ? 'LOGIN_BUTTON' : 'NONE';
})()
'@
$JsClickLoginButton = $JsFindLoginButton + @'
(function () { var b = e3FindLoginButton(); if (b) { b.click(); return 'CLICKED'; } return 'NOT_FOUND'; })()
'@



# 填入帳密並送出的腳本；沒有看得到的密碼框時回傳 NO_LOGIN_NEEDED
# 帳號框依優先順序找 (Zabbix 為 #name)，只取看得到的欄位，避免填到隱藏欄位；有「記住我」(Zabbix #autologin) 就勾起來
function Get-JsFillLogin($authCfg) {
    $u = ConvertTo-Json ([string]$authCfg.username)
    $pw = ConvertTo-Json ([string]$authCfg.password)
    return @"
(function () {
    function vis(el) { return !!el && el.offsetParent !== null; }
    var pwd = null, ps = document.querySelectorAll('input[type="password"]');
    for (var i = 0; i < ps.length && !pwd; i++) if (vis(ps[i])) pwd = ps[i];
    if (!pwd) return 'NO_LOGIN_NEEDED';
    var scope = pwd.form || document;
    var sels = ['input#name', 'input[name="name"]', 'input[type="email"]', 'input[name*="user" i]', 'input[name*="login" i]',
                'input[name*="account" i]', 'input[name*="id" i]', 'input[type="text"]'];
    var user = null;
    for (var s = 0; s < sels.length && !user; s++) {
        var cand = scope.querySelectorAll(sels[s]);
        for (var c = 0; c < cand.length && !user; c++) if (vis(cand[c]) && cand[c] !== pwd) user = cand[c];
    }
    function setVal(el, v) {
        Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(el, v);   // React 等框架也收得到
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
    }
    if (user) setVal(user, $u);
    setVal(pwd, $pw);
    var rem = scope.querySelector('input#autologin, input[name="autologin"], input[type="checkbox"][name*="remember" i]');
    if (rem && !rem.checked) rem.click();
    var btn = scope.querySelector('button#enter, button[type="submit"], input[type="submit"]');
    if (btn) { btn.click(); return 'CLICKED_SUBMIT'; }
    if (pwd.form) { pwd.form.submit(); return 'FORM_SUBMITTED'; }
    return 'FILLED';
})()
"@
}



# Zabbix 舊版 scrollbar：使用實際按鈕，不以螢幕座標或全文的第一個「7d」定位。
# 依本機網站快取的 CScrollBar：dom.right = navigateRight，.zoom a[zoom=604800] = setZoom。
function Get-JsZabbixTimeStep([string]$action = "inspect") {
    $actionJson = ConvertTo-Json $action -Compress
    $script = @'
(function () {
    var action = __ACTION__, week = 604800;
    function result(status, details) { return JSON.stringify(Object.assign({status: status}, details || {})); }
    function visible(el) { return !!el && el.isConnected && el.getClientRects().length > 0; }
    var tc = window.timeControl, root = document.getElementById('scrollbar_cntr');
    if (!tc || !tc.timeline || !tc.scrollbar || !root) return result('WAIT', {reason: '尚未找到 Zabbix 時間控制列'});
    var tl = tc.timeline, bar = tc.scrollbar, dom = bar.dom || {};
    if (typeof tl.period !== 'function' || typeof tl.now !== 'function' || typeof tl.usertime !== 'function')
        return result('ERROR', {reason: '不支援此版本的 Zabbix 時間控制介面'});
    var right = dom.right, zoom = root.querySelector('.zoom a[zoom="604800"]');
    if (!visible(right) || !root.contains(right) || !right.querySelector('.arrow-right') || !visible(zoom)
            || !visible(dom.info_right) || !visible(dom.info_left))
        return result('WAIT', {reason: '找不到右箭頭、Zoom 7d 或時間標籤'});
    if (bar.disabled || document.readyState !== 'complete') return result('WAIT', {reason: '頁面或時間控制列尚未就緒'});
    var nowLabel = (dom.info_right.textContent || '').trim();
    var atNow = !!tl.now() && /\(\s*now\s*!?\s*\)/i.test(nowLabel);
    var period = Number(tl.period()), end = Number(tl.usertime());
    if (!Number.isFinite(period) || !Number.isFinite(end)) return result('ERROR', {reason: '時間範圍不是有效數值'});
    var state = {atNow: atNow, period: period, end: end, label: nowLabel, signature: period + ':' + end + ':' + atNow};
    var screens = window.flickerfreeScreen && window.flickerfreeScreen.screens;
    if (screens) {
        for (var id in screens) {
            if (!Object.prototype.hasOwnProperty.call(screens, id)) continue;
            var screen = screens[id];
            if (!screen) continue;
            if (screen.error > 0) return result('WAIT', {reason: '圖表載入錯誤，等待網站重試'});
            if (screen.isRefreshing || screen.isReRefreshRequire) return result('WAIT', {reason: '圖表正在重新載入'});
        }
    }
    var charts = Array.from(document.images).filter(function (img) {
        return visible(img) && /\/chart\d*\.php$/i.test(new URL(img.currentSrc || img.src, location.href).pathname);
    });
    if (!charts.length || charts.some(function (img) { return !img.complete || img.naturalWidth === 0; }))
        return result('WAIT', {reason: '等待監控圖表圖片載入'});
    if (action === 'right' && !atNow) {
        // 延後點擊，讓 CDP 先收到回覆；網站若整頁重載，下次輪詢會取得新的元件。
        setTimeout(function () { right.click(); }, 0);
        return result('CLICK_RIGHT', state);
    }
    if (action === 'zoom' && atNow && period !== week) {
        setTimeout(function () { zoom.click(); }, 0);
        return result('CLICK_ZOOM', state);
    }
    if (atNow && period === week) {
        var leftStamp = Number(dom.info_left.getAttribute('data-timestamp'));
        var rightStamp = Number(dom.info_right.getAttribute('data-timestamp'));
        if (rightStamp - leftStamp !== week || Math.abs(rightStamp - end) > 1)
            return result('WAIT', {reason: '時間標籤尚未更新為七天到現在'});
        var stale = charts.some(function (img) {
            var args = new URL(img.currentSrc || img.src, location.href).searchParams;
            return Number(args.get('period')) !== week || (args.has('isNow') && args.get('isNow') !== '1');
        });
        if (stale) return result('WAIT', {reason: '圖表圖片尚未更新為 7d / now'});
        state.charts = charts.length;
        return result('DONE', state);
    }
    return result('READY', state);
})()
'@
    return $script.Replace('__ACTION__', $actionJson)
}



function Set-ZabbixRecentWeek($ws, [ref]$commandId, [string]$url, [int]$waitSeconds = 5, [int]$timeoutSeconds = 180) {
    # 只處理本專案使用的舊版 Zabbix screens / charts 頁面，其他報表照原流程截圖。
    $pageUri = $null
    if (-not [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$pageUri) -or
        $pageUri.AbsolutePath -notmatch '/(screens|charts)\.php$') { return $false }



    Write-Host "🕒 [Zabbix] 截圖前調整：右箭頭移到 (now)，再選 Zoom 7d" -ForegroundColor Cyan
    $deadline = (Get-Date).AddSeconds($timeoutSeconds)
    $stableSince = $null
    $pendingSignature = $null
    $pendingSince = $null
    $clickCount = 0
    $lastReason = '等待時間控制列'
    while ((Get-Date) -lt $deadline) {
        $id = $commandId.Value; $commandId.Value++
        $rawState = Invoke-CdpEval $ws $id (Get-JsZabbixTimeStep)
        if (-not $rawState) {
            # 整頁重載時 Runtime.evaluate 可能暫時沒有結果。
            $stableSince = $null
            $lastReason = '頁面正在重新載入'
            Start-Sleep -Milliseconds 500
            continue
        }
        $state = $rawState | ConvertFrom-Json
        if ($state.status -eq 'ERROR') { throw "Zabbix 時間調整失敗：$($state.reason)" }
        if ($state.status -eq 'WAIT') {
            $stableSince = $null
            $lastReason = $state.reason
        } else {
            if ($pendingSignature) {
                if ($state.signature -ne $pendingSignature) { $pendingSignature = $null }
                elseif (((Get-Date) - $pendingSince).TotalSeconds -ge 15) {
                    throw 'Zabbix 時間調整失敗：點擊後時間範圍沒有變化'
                } else {
                    Start-Sleep -Milliseconds 500
                    continue
                }
            }
            if ($state.status -eq 'DONE') {
                if (-not $stableSince) { $stableSince = Get-Date }
                if (((Get-Date) - $stableSince).TotalSeconds -ge [Math]::Max(1, $waitSeconds)) {
                    Write-Host "  ✅ [Zabbix] 已確認 7d → (now)，$($state.charts) 張圖表載入完成" -ForegroundColor Green
                    return $true
                }
                $lastReason = '7d / now 已設定，等待圖表穩定'
            } elseif ($state.status -eq 'READY') {
                $stableSince = $null
                if ($clickCount -ge 120) { throw 'Zabbix 時間調整超過 120 次操作' }
                $action = if ($state.atNow) { 'zoom' } else { 'right' }
                $id = $commandId.Value; $commandId.Value++
                $clicked = Invoke-CdpEval $ws $id (Get-JsZabbixTimeStep $action) | ConvertFrom-Json
                if ($clicked.status -in @('CLICK_RIGHT', 'CLICK_ZOOM')) {
                    $clickCount++
                    $pendingSignature = $clicked.signature
                    $pendingSince = Get-Date
                    if ($action -eq 'zoom') { Write-Host '  🕒 [Zabbix] 已到 (now)，點選上方 Zoom 7d' -ForegroundColor Cyan }
                    else { Write-Host "  🕒 [Zabbix] 點選右箭頭 ($clickCount)，前進到現在" -ForegroundColor DarkGray }
                }
                $lastReason = '等待時間範圍更新'
            }
        }
        Start-Sleep -Milliseconds 500
    }
    throw "Zabbix 時間調整逾時 ($timeoutSeconds 秒)：$lastReason，未確認 7d / now"
}



# ==============================================================================
# 模式 A：首次手動登入記憶模式 (-LoginMode)
# ==============================================================================
if ($LoginMode) {
    $browserExe = Get-BrowserPath
    $enabledPages = @($config.pages | Where-Object { $_.enabled -ne $false })
    $urls = @($enabledPages | ForEach-Object { "`"$($_.url)`"" })
    # 僅停用監控專用瀏覽器的翻譯提示，保留網站原文；不改日常 Edge 設定。
    $argStr = "--user-data-dir=`"$profileDir`" --disable-features=Translate,msEdgeTranslate --new-window " + ($urls -join " ")



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
function Get-BrowserZoom($page) {
    $zoom = 100
    if ($page -and $page.PSObject.Properties.Name -contains 'browser_zoom') {
        if (-not [int]::TryParse([string]$page.browser_zoom, [ref]$zoom) -or $zoom -lt 50 -or $zoom -gt 200) {
            throw '網頁縮放必須是 50～200 的整數百分比'
        }
    }
    return $zoom
}



function Set-CaptureViewport($ws, [ref]$commandId, [int]$zoom, $view = $null, [switch]$FitWindow) {
    $factor = $zoom / 100.0
    $width = [int][Math]::Round(1920 / $factor); $height = [int][Math]::Round(1080 / $factor)
    if ($FitWindow) {
        $id = $commandId.Value; $commandId.Value++
        $window = Invoke-CdpCommand $ws $id 'Browser.getWindowForTarget'
        $id = $commandId.Value; $commandId.Value++
        Invoke-CdpCommand $ws $id 'Browser.setWindowBounds' @{windowId=$window.result.windowId; bounds=@{windowState='maximized'}} | Out-Null
        $id = $commandId.Value; $commandId.Value++
        Invoke-CdpCommand $ws $id 'Emulation.clearDeviceMetricsOverride' | Out-Null
        Start-Sleep -Milliseconds 500
        $id = $commandId.Value; $commandId.Value++
        $native = (Invoke-CdpEval $ws $id 'JSON.stringify({w:innerWidth,h:innerHeight})') | ConvertFrom-Json
        $width = [int][Math]::Floor($native.w / $factor); $height = [int][Math]::Floor($native.h / $factor)
    } elseif ($view) {
        if ($view.zoom -ne $zoom) { throw '網頁縮放已變更，請重新抓圖並選擷取目前畫面，更新捲動位置' }
        foreach ($key in @('width','height','x','y')) {
            if ($null -eq $view.$key -or [double]$view.$key -ne [Math]::Floor([double]$view.$key) -or [double]$view.$key -lt 0) {
                throw '儲存的可視範圍或捲動位置無效，請重新抓圖'
            }
        }
        $width = [int]$view.width; $height = [int]$view.height
    }
    if ($width -lt 1 -or $height -lt 1 -or $width*$factor -gt 16384 -or $height*$factor -gt 16384 -or $width*$height*$factor*$factor -gt 64000000) {
        throw '可視範圍尺寸無效或過大，請重新抓圖'
    }
    # 以 CSS 可視範圍與輸出像素密度模擬網頁縮放；固定實體視窗基準，讓文字與圖表一起放大並重新排版。
    $id = $commandId.Value; $commandId.Value++
    Invoke-CdpCommand $ws $id 'Emulation.setDeviceMetricsOverride' @{
        width = $width; height = $height
        deviceScaleFactor = $factor; mobile = $false; scale = $(if ($FitWindow) { $factor } else { 1 })
    } | Out-Null
    $id = $commandId.Value; $commandId.Value++
    Invoke-CdpCommand $ws $id 'Emulation.setPageScaleFactor' @{ pageScaleFactor = 1 } | Out-Null
}



# $zoom：設定工具的「網頁縮放」。在 Edge 裡手動縮放 (Ctrl＋滾輪 / Ctrl＋加減號) 時 devicePixelRatio 會偏離 zoom/100，
# 面板會即時提示按 Ctrl+0，且不接受擷取 (Edge 會記住手動縮放，排程時再套用一次而無法還原位置)
function Get-JsCaptureControls([int]$zoom = 100) {
    $script = @'
(() => {
if (document.getElementById('__e3_capture_controls')) return 'READY';
window.__e3CaptureChoice = null;
const expected = __EXPECTED__;
const host = document.createElement('div'); host.id='__e3_capture_controls';
host.style.cssText='position:fixed;top:12px;right:32px;z-index:2147483647;';
const root=host.attachShadow({mode:'open'});
root.innerHTML='<style>:host{all:initial}div{font:14px "Microsoft JhengHei",sans-serif;background:#102238;color:white;padding:14px;border:2px solid #38bdf8;border-radius:9px;box-shadow:0 3px 16px #0008;max-width:320px}p{margin:0 0 10px;line-height:1.5}#warn{color:#fca5a5;font-weight:bold}button{font:inherit;cursor:pointer;padding:8px 12px;border:0;border-radius:5px;margin-right:8px;background:#0ea5e9;color:white}button:last-child{background:#475569}</style><div><p>請先捲動網頁到要擷取的位置。<br>完成後按下方按鈕，再回設定工具框選。</p><p id="warn" hidden></p><button id="capture">擷取目前畫面</button><button id="cancel">取消</button></div>';
const warn = root.getElementById('warn');
function zoomed() { return Math.abs(devicePixelRatio - expected) > 0.01; }
function check() {
   warn.hidden = !zoomed();
   if (zoomed()) warn.textContent = '偵測到網頁被手動縮放（約 ' + Math.round(devicePixelRatio / expected * 100) + '%）。請在這個視窗按 Ctrl+0 還原後再擷取；要改比例請用設定工具的「網頁縮放」。';
}
function choose(cancel){
   if (!cancel && zoomed()) { check(); return; }
   window.__e3CaptureChoice = cancel ? {cancel:true} : {width:innerWidth,height:innerHeight,x:Math.round(scrollX),y:Math.round(scrollY)};
   removeEventListener('resize', check);
   host.remove();
}
root.getElementById('capture').onclick=()=>choose(false);
root.getElementById('cancel').onclick=()=>choose(true);
addEventListener('resize', check);   // 縮放改變時會觸發 resize
document.documentElement.appendChild(host); check(); return 'READY';
})()
'@
    return $script.Replace('__EXPECTED__', ($zoom / 100.0).ToString([System.Globalization.CultureInfo]::InvariantCulture))
}



# 排程與抓圖擷取前確認沒有手動縮放 (devicePixelRatio 應等於網頁縮放)，否則給出明確原因而不是「無法還原捲動位置」
function Assert-NoManualZoom($ws, [ref]$commandId, [int]$zoom) {
    $id = $commandId.Value; $commandId.Value++
    $dpr = [double](Invoke-CdpEval $ws $id 'String(devicePixelRatio)')
    $expected = $zoom / 100.0
    if ($dpr -gt 0 -and [Math]::Abs($dpr - $expected) -gt 0.01) {
        $manual = [int][Math]::Round($dpr / $expected * 100)
        throw "專用 Edge 記住了此網站的手動縮放（約 $manual%）：請按 🔐 登入監控網站，開啟此網站按 Ctrl+0 還原後關閉，再重新 📸 抓圖"
    }
}



function Wait-InteractiveCapture($ws, [ref]$commandId, [int]$zoom, [int]$TimeoutSeconds = 600) {
    $id = $commandId.Value; $commandId.Value++
    Invoke-CdpEval $ws $id (Get-JsCaptureControls $zoom) | Out-Null
    Write-Host '🖱️ 請捲動 Edge 網頁，完成後按「擷取目前畫面」（10 分鐘內）；按「取消」可結束。' -ForegroundColor Cyan
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 300
        $id = $commandId.Value; $commandId.Value++
        $state = Invoke-CdpCommand $ws $id 'Runtime.evaluate' @{expression="JSON.stringify({choice:window.__e3CaptureChoice,ready:!!document.getElementById('__e3_capture_controls')})"; returnByValue=$true}
        if ($state.error -or $state.result.exceptionDetails -or -not $state.result.result.value) { throw '抓圖視窗已關閉或無法讀取，請重新抓圖' }
        $status = $state.result.result.value | ConvertFrom-Json
        if ($status.choice) {
            if ($status.choice.cancel) { throw '已取消抓圖，原設定與圖片保持不變' }
            $status.choice | Add-Member -NotePropertyName zoom -NotePropertyValue $zoom
            return $status.choice
        }
        if (-not $status.ready) { throw '網頁已重新載入或跳轉，請重新抓圖並再次選擇位置' }
    }
    throw '等待擷取逾時（10 分鐘），請重新抓圖'
}



function Restore-CaptureScroll($ws, [ref]$commandId, $view, [int]$waitSeconds = 1) {
    $x=[int]$view.x; $y=[int]$view.y
    $id = $commandId.Value; $commandId.Value++
    Invoke-CdpEval $ws $id "window.scrollTo({left:$x,top:$y,behavior:'instant'}); 'OK'" | Out-Null
    Start-Sleep -Seconds ([Math]::Max(1,$waitSeconds))
    $id = $commandId.Value; $commandId.Value++
    $state = (Invoke-CdpEval $ws $id 'JSON.stringify({x:Math.round(scrollX),y:Math.round(scrollY),w:innerWidth,h:innerHeight})') | ConvertFrom-Json
    if (-not $state -or [Math]::Abs($state.x-$x) -gt 1 -or [Math]::Abs($state.y-$y) -gt 1 -or $state.w -ne $view.width -or $state.h -ne $view.height) {
        throw '無法還原設定的捲動位置或可視範圍，請重新抓圖'
    }
    Write-Host "  ↕️ 已還原捲動位置 X=$x, Y=$y；可視範圍 $($view.width) × $($view.height)" -ForegroundColor DarkGray
}



function Save-RenderedPage($ws, [ref]$commandId, $page, [string]$outDir, [int]$zoom) {
    Assert-NoManualZoom $ws $commandId $zoom
    if ($page.capture_view) {
        Restore-CaptureScroll $ws $commandId $page.capture_view ([int]$page.wait_seconds)
        $id = $commandId.Value; $commandId.Value++
        $shot = Invoke-CdpCommand $ws $id 'Page.captureScreenshot' @{format='png';fromSurface=$true;captureBeyondViewport=$false}
    } else {
    $id = $commandId.Value; $commandId.Value++
    Invoke-CdpEval $ws $id 'window.scrollTo(0, 0); "OK"' | Out-Null
    $id = $commandId.Value; $commandId.Value++
    $layout = Invoke-CdpCommand $ws $id 'Page.getLayoutMetrics'
    $size = $layout.result.cssContentSize
    if (-not $size) { throw '無法取得網頁完整尺寸' }
    $width = [Math]::Ceiling($size.width); $height = [Math]::Ceiling($size.height)
    $factor = $zoom / 100.0
    if ($width -lt 1 -or $height -lt 1 -or $width * $factor -gt 16384 -or $height * $factor -gt 16384 -or
        $width * $height * $factor * $factor -gt 64000000) {
        throw '完整網頁圖片過大（上限單邊 16384 像素、總計 6400 萬像素），請降低網頁縮放或改用較短的報表網址'
    }
    $id = $commandId.Value; $commandId.Value++
    $shot = Invoke-CdpCommand $ws $id 'Page.captureScreenshot' @{
        format = 'png'; fromSurface = $true; captureBeyondViewport = $true
        clip = @{ x = 0; y = 0; width = $width; height = $height; scale = 1 }
    }
    }
    if (-not $shot.result.data) { throw 'Edge 沒有回傳完整網頁圖片' }
    $bytes = [Convert]::FromBase64String($shot.result.data)
    $fullPath = Join-Path $outDir "$($page.id)_full.png"
    $outFile = Join-Path $outDir "$($page.id).png"
    [IO.File]::WriteAllBytes($fullPath, $bytes)
    $bitmap = [Drawing.Bitmap]::new($fullPath)
    try {
        Write-Host "  🔎 網頁縮放 $zoom%，來源圖片 $($bitmap.Width) × $($bitmap.Height)" -ForegroundColor DarkGray
        $crop = $page.crop_region
        if ($crop -and $crop.enabled) {
            $values = @($crop.x, $crop.y, $crop.w, $crop.h)
            foreach ($value in $values) {
                if ($null -eq $value -or [double]$value -ne [Math]::Floor([double]$value)) { throw '擷取範圍必須是完整圖片上的整數像素座標' }
            }
            $x = [int]$crop.x; $y = [int]$crop.y; $w = [int]$crop.w; $h = [int]$crop.h
            if ($x -lt 0 -or $y -lt 0 -or $w -le 0 -or $h -le 0 -or $x + $w -gt $bitmap.Width -or $y + $h -gt $bitmap.Height) {
                throw '擷取範圍超出目前畫面，請重新抓圖並框選'
            }
            # 與 calibrator 的 drawImage 裁切相同：座標一律是最終圖片像素，不再當成網頁 CSS 座標。
            $cropped = $bitmap.Clone([Drawing.Rectangle]::new($x,$y,$w,$h), [Drawing.Imaging.PixelFormat]::Format32bppArgb)
            try { $cropped.Save($outFile, [Drawing.Imaging.ImageFormat]::Png) } finally { $cropped.Dispose() }
        } else { [IO.File]::WriteAllBytes($outFile, $bytes) }
    } finally { $bitmap.Dispose() }
    $length = (Get-Item -LiteralPath $outFile).Length
    if ($length -gt 10485760) { Write-Host "  ⚠️ 警告: 單張截圖超過 Teams 10 MiB 上限 ($length bytes)" -ForegroundColor Yellow }
    Write-Host "  📸 已擷取畫面 ($length bytes) -> $outFile" -ForegroundColor Green
    return $outFile
}



# 連到專用 Edge 的分頁並啟用需要的 CDP 功能；Edge 啟動時與連線被中止後的重新連線共用
# -NewTab：上一頁的網頁卡死時，重連同一個分頁一樣不會回應，改開新分頁並關閉舊分頁 (由瀏覽器程序處理，不經過卡住的網頁)
function Connect-CdpPage([int]$port, [ref]$commandId, [switch]$NewTab) {
    # PowerShell 5.1 的 Invoke-RestMethod 把 JSON 陣列當成單一物件輸出，經過管線展開成各個分頁
    $targets = @(Wait-CdpTargets $port | ForEach-Object { $_ })
    if ($NewTab) {
        $pageTarget = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/new?about:blank" -Method Put -TimeoutSec 10
        foreach ($old in @($targets | Where-Object { $_.type -eq "page" -and $_.id -ne $pageTarget.id })) {
            try { Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/close/$($old.id)" -TimeoutSec 5 | Out-Null } catch {}
        }
    } else {
        $pageTarget = $targets | Where-Object { $_.type -eq "page" -and $_.url -notlike "chrome-extension://*" -and $_.url -notlike "edge://*" } | Select-Object -First 1
        if (-not $pageTarget) {
            $pageTarget = $targets | Where-Object { $_.type -eq "page" } | Select-Object -First 1
        }
    }
    if (-not $pageTarget -or -not $pageTarget.webSocketDebuggerUrl) { throw "專用 Edge 沒有可操作的分頁" }



    $ws = [System.Net.WebSockets.ClientWebSocket]::new()
    $connectToken = [System.Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(15))
    try {
        $ws.ConnectAsync([Uri]$pageTarget.webSocketDebuggerUrl, $connectToken.Token).GetAwaiter().GetResult() | Out-Null
    } catch {
        $ws.Dispose()
        throw "無法連線到專用 Edge 的除錯通道（$($_.Exception.Message)）"
    } finally { $connectToken.Dispose() }



    foreach ($method in @("Page.enable", "Runtime.enable", "Page.bringToFront")) {
        $id = $commandId.Value; $commandId.Value++
        Invoke-CdpCommand $ws $id $method | Out-Null
    }
    # 強制喚醒背景分頁狀態為 active (避免 Edge 背景凍結導致延遲，參考 46518 10/29 修正)
    $id = $commandId.Value; $commandId.Value++
    try { Invoke-CdpCommand $ws $id "Page.setWebLifecycleState" @{ state = "active" } | Out-Null } catch {}
    return $ws
}



# 開啟網址；連線失敗 (DNS、拒絕連線、逾時等) 時 Page.navigate 會回傳 errorText，此時 Edge 顯示的是錯誤頁
function Open-PageUrl($ws, [ref]$commandId, [string]$url) {
    $id = $commandId.Value; $commandId.Value++
    $nav = Invoke-CdpCommand $ws $id "Page.navigate" @{ url = $url }
    if ($nav.result.errorText) { throw "網頁無法開啟（$($nav.result.errorText)）" }
}



# 載入等待後確認不是 Edge 錯誤頁或網站錯誤頁 (HTTP 4xx / 5xx)，避免把錯誤畫面當成監控結果送出
function Assert-PageLoaded($ws, [ref]$commandId) {
    $id = $commandId.Value; $commandId.Value++
    $raw = Invoke-CdpEval $ws $id "JSON.stringify({href:location.href,status:((performance.getEntriesByType('navigation')[0]||{}).responseStatus)||0})"
    if (-not $raw) { throw '無法讀取網頁狀態（網頁可能還在重新載入）' }
    $state = $raw | ConvertFrom-Json
    if ($state.href -like 'chrome-error://*' -or $state.href -like 'edge-error://*') { throw '網頁無法開啟（Edge 顯示錯誤頁）' }
    # Edge 內部頁面 (例如設定檔首次使用、edge:// 頁面) 蓋掉了目標網頁
    if ($state.href -notmatch '^https?://') { throw "Edge 顯示的不是網站內容（目前：$($state.href)）" }
    if ([int]$state.status -ge 400) { throw "網站回應錯誤（HTTP $($state.status)）" }
}



function Capture-PagesNative($pagesToCapture, $authCfg, [string]$outDir, [switch]$Interactive) {
    $browserExe = Get-BrowserPath
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }



    Stop-ProfileEdge
    $debugPort = 9333
    # 參考公司內部 46518 實測經驗：加入防止 Edge 背景分頁休眠/凍結參數
    # --force-device-scale-factor=1：筆電顯示比例 125%/150% 時，截圖座標仍與設定工具一致
    # Translate (Chromium) / msEdgeTranslate (Edge)：停用翻譯提示，避免詢問中文是否轉英文。
    $argList = "--remote-debugging-port=$debugPort --user-data-dir=`"$profileDir`" --disable-features=Translate,msEdgeTranslate --window-size=1920,1080 --force-device-scale-factor=1 --hide-crash-restore-bubble --disable-background-timer-throttling --disable-backgrounding-occluded-windows --disable-renderer-backgrounding about:blank"
    $proc = Start-Process -FilePath $browserExe -ArgumentList $argList -PassThru



    $capturedMap = @{}
    $failures = [ordered]@{}
    $ws = $null
    try {
        $cmdId = 1
        $ws = Connect-CdpPage $debugPort ([ref]$cmdId)



        # 逐頁處理：一頁失敗 (網頁打不開、登入失敗、Zabbix 時間無法確認、捲動位置無法還原…) 只記錄原因並繼續下一頁，
        # 由主流程在 Teams 訊息中標示失敗的頁面，其餘正常的頁面照常送出
        $idx = 0
        foreach ($p in $pagesToCapture) {
            $idx++
            try {
            # 上一頁因 Edge 沒有回應而中止連線時，重新連線後再處理這一頁
            if ($ws.State -ne [System.Net.WebSockets.WebSocketState]::Open) {
                Write-Host "  🔄 重新連線到專用 Edge (開新分頁)..." -ForegroundColor Yellow
                $ws.Dispose()
                $ws = Connect-CdpPage $debugPort ([ref]$cmdId) -NewTab
            }
            $pageZoom = Get-BrowserZoom $p
            Set-CaptureViewport $ws ([ref]$cmdId) $pageZoom $p.capture_view -FitWindow:$Interactive
            Write-Host "🌐 [$idx/$($pagesToCapture.Count)] 正在開啟 $($p.name): $($p.url)" -ForegroundColor Cyan
            Invoke-CdpCommand $ws ($cmdId++) "Page.bringToFront" | Out-Null
            try { Invoke-CdpCommand $ws ($cmdId++) "Page.setWebLifecycleState" @{ state = "active" } | Out-Null } catch {}
            Open-PageUrl $ws ([ref]$cmdId) $p.url
            Start-Sleep -Seconds 3



            # 自動登入：
            #   1. 頁面有密碼框 → 填入帳密送出
            #   2. 沒有密碼框、但有「Login / Sign in / 登入」按鈕 (例如 Zabbix「You are not logged in」提示頁) → 先點它，等登入頁出現再填帳密
            #   之後重新開啟原本的網址，仍停在登入畫面就判定此頁失敗 (不把登入畫面當成監控結果送出)
            $loginState = Invoke-CdpEval $ws ($cmdId++) $JsLoginState
            if ($loginState -ne "NONE") {
                $triedLogin = Test-AuthConfigured $authCfg
                if (-not $triedLogin) {
                    Write-Host "  ⚠️ 頁面需要登入 ($loginState)，但沒有設定網站帳密：請到設定工具「⚙️ 全域設定」填帳密，或按 🔐 登入監控網站" -ForegroundColor Yellow
                } else {
                    if ($loginState -eq "LOGIN_BUTTON") {
                        Invoke-CdpEval $ws ($cmdId++) $JsClickLoginButton | Out-Null
                        Write-Host "  🔘 偵測到未登入提示頁，已自動點選 Login 按鈕，等待登入畫面..." -ForegroundColor Yellow
                    }
                    $jsFill = Get-JsFillLogin $authCfg
                    $loginStatus = "NO_LOGIN_NEEDED"
                    for ($try = 0; $try -lt 8 -and $loginStatus -eq "NO_LOGIN_NEEDED"; $try++) {
                        Start-Sleep -Seconds $(if ($try -eq 0 -and $loginState -eq "PASSWORD") { 0 } else { 2 })
                        $loginStatus = Invoke-CdpEval $ws ($cmdId++) $jsFill
                    }
                    if ($loginStatus -eq "NO_LOGIN_NEEDED") {
                        Write-Host "  ⚠️ 點選 Login 後 16 秒內沒有出現密碼框，無法自動登入" -ForegroundColor Yellow
                    } else {
                        Write-Host "  🔐 已自動填入帳密送出 ($loginStatus)，等待跳轉..." -ForegroundColor Yellow
                        Start-Sleep -Seconds 4
                    }
                    Open-PageUrl $ws ([ref]$cmdId) $p.url
                    Start-Sleep -Seconds 3
                    $loginState = Invoke-CdpEval $ws ($cmdId++) $JsLoginState
                }
                # 仍有密碼框 = 停在登入畫面；試過自動登入後仍有 Login 按鈕 = 登入沒有成功。
                # 沒設定帳密、只有 Login / Sign in 連結時，可能是允許訪客瀏覽的頁面，照常截圖。
                if ($loginState -eq "PASSWORD" -or ($triedLogin -and $loginState -ne "NONE")) {
                    if ($triedLogin) { throw "停在登入畫面，自動登入沒有成功（請確認「⚙️ 全域設定」的帳密，或按 🔐 登入監控網站）" }
                    throw "停在登入畫面，且沒有設定網站帳密（請按 🔐 登入監控網站，或到「⚙️ 全域設定」填帳密）"
                }
                if ($triedLogin) { Write-Host "  ✅ 自動登入成功" -ForegroundColor Green }
            }



            $waitSec = if ($p.wait_seconds) { [int]$p.wait_seconds } else { 5 }
            Start-Sleep -Seconds $waitSec
            Assert-PageLoaded $ws ([ref]$cmdId)
            Set-ZabbixRecentWeek $ws ([ref]$cmdId) $p.url $waitSec | Out-Null



            if ($Interactive) {
                $selection = Wait-InteractiveCapture $ws ([ref]$cmdId) $pageZoom
                $p | Add-Member -NotePropertyName capture_view -NotePropertyValue $selection -Force
            }
            $outFile = Save-RenderedPage $ws ([ref]$cmdId) $p $outDir $pageZoom
            $capturedMap[$p.id] = $outFile
            } catch {
                $failures[$p.id] = $_.Exception.Message
                Write-Host "  ❌ [$($p.id)] $($p.name) 擷取失敗：$($_.Exception.Message)" -ForegroundColor Red
            }
        }



    } finally {
        try { Close-CaptureBrowser $ws } finally {
            if ($ws) { $ws.Dispose() }
            Stop-ProfileEdge
        }
    }
    # Files：頁面 id → 截圖路徑；Failures：頁面 id → 失敗原因 (依頁面順序)
    return @{ Files = $capturedMap; Failures = $failures }
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
# 使用「已經開著、已登入」的 Teams 發送 (不另開瀏覽器、不需另外登入、不開 msteams: 連結)
# 尋找順序：Teams PWA 視窗 (Edge 應用程式視窗) → 桌面版 Teams → Edge 分頁中的 Teams；都沒開才重新開啟
# 用 UI Automation 在聊天清單點選對話名稱 → 確認視窗標題是該對話 → 貼上 → 等圖片出現 → 送出 → 切回原本的對話
# 任何一步確認失敗就停止，絕不盲貼到其他視窗或其他對話
# ==============================================================================
$UIA = [System.Windows.Automation.AutomationElement]
$UIAll = [System.Windows.Automation.TreeScope]::Descendants
$UIAny = [System.Windows.Automation.Condition]::TrueCondition
$ChatPrefix = '(群組聊天|會議聊天|聊天|Group chat|Meeting chat|Chat)'



function Get-TopWindows {
    foreach ($line in [E3Win]::ListWindows()) {
        $h, $procId, $title = $line -split '\|', 3
        $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
        [pscustomobject]@{ Hwnd = [IntPtr][long]$h; Proc = $(if ($p) { $p.ProcessName } else { "" }); Title = $title }
    }
}



function Find-UIA($root, [string]$type, [scriptblock]$filter) {
    $cond = New-Object System.Windows.Automation.PropertyCondition($UIA::ControlTypeProperty, [System.Windows.Automation.ControlType]::$type)
    @($root.FindAll($UIAll, $cond) | Where-Object $filter)
}



function Select-UIAElement($el) {
    try { $el.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Select(); return } catch {}
    try { $el.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); return } catch {}
    $r = $el.Current.BoundingRectangle   # 都不支援時改用滑鼠點一下 (視窗已在最前面)
    [E3Win]::SetCursorPos([int]($r.X + $r.Width / 2), [int]($r.Y + $r.Height / 2)) | Out-Null
    [E3Win]::mouse_event(0x2, 0, 0, 0, [UIntPtr]::Zero)
    [E3Win]::mouse_event(0x4, 0, 0, 0, [UIntPtr]::Zero)
}



$TeamsKinds = @("pwa", "desktop", "edge-tab")   # 尋找順序
$TeamsKindText = @{ pwa = "Teams 應用程式 (PWA)"; desktop = "桌面版 Teams"; "edge-tab" = "Edge 分頁中的 Teams" }
$EdgeSuffix = 'Microsoft[\s\u200B]*Edge\s*$'   # 一般 Edge 瀏覽器視窗的標題結尾 (中間可能有零寬空白)



# Edge 視窗的分頁 (TabItem)。只走瀏覽器外框、跳過網頁內容 (Document)：
# 目前分頁是 Teams 時，整個視窗的協助工具樹非常大，FindAll(Descendants) 可能要好幾分鐘
function Get-EdgeTabs([IntPtr]$hwnd) {
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
    $level = @($UIA::FromHandle($hwnd))
    $tabs = @()
    for ($depth = 0; $depth -lt 12 -and $level.Count -gt 0; $depth++) {
        $next = @()
        foreach ($el in $level) {
            $child = $walker.GetFirstChild($el)
            while ($child) {
                $type = $child.Current.ControlType
                if ($type -eq [System.Windows.Automation.ControlType]::TabItem) { $tabs += $child }
                elseif ($type -ne [System.Windows.Automation.ControlType]::Document) { $next += $child }
                $child = $walker.GetNextSibling($child)
            }
        }
        $level = $next
    }
    return $tabs
}



# 列出開著的 Teams (只列出，不切換分頁)：回傳 @{ Kind; Hwnd; Title; Tab (edge-tab 才有) } 陣列，依 $kinds 順序
# $firstOnly：找到第一個就停止 (發送時用，省去逐一掃描 Edge 分頁的時間)
function Get-TeamsCandidates([string[]]$kinds = $TeamsKinds, [switch]$firstOnly) {
    $wins = @(Get-TopWindows)
    $list = @()
    foreach ($k in $kinds) {
        if ($k -eq "pwa") {
            # PWA / Edge 應用程式視窗：msedge 的視窗、標題含 Microsoft Teams，且不是一般 Edge 瀏覽器視窗 (沒有分頁，標題不會以 Microsoft Edge 結尾)
            # 不限定結尾：Edge 可能在標題前加上應用程式名稱，例如「Microsoft Teams (PWA) - 聊天 | …」
            $found = @($wins | Where-Object { $_.Proc -eq "msedge" -and $_.Title -match 'Microsoft Teams' -and $_.Title -notmatch $EdgeSuffix } |
                ForEach-Object { @{ Kind = "pwa"; Hwnd = $_.Hwnd; Title = $_.Title } })
        } elseif ($k -eq "desktop") {
            # 桌面版 Teams (新版 ms-teams / 舊版 Teams)
            $found = @($wins | Where-Object { $_.Proc -in @("ms-teams", "Teams") -and $_.Title -match 'Teams' } |
                ForEach-Object { @{ Kind = "desktop"; Hwnd = $_.Hwnd; Title = $_.Title } })
        } else {
            # 一般 Edge 視窗裡標題含 Microsoft Teams 的分頁 (teams.cloud.microsoft / teams.microsoft.com)
            $found = @()
            foreach ($w in ($wins | Where-Object { $_.Proc -eq "msedge" -and $_.Title -match $EdgeSuffix })) {
                foreach ($tab in (Get-EdgeTabs $w.Hwnd | Where-Object { $_.Current.Name -match 'Microsoft Teams' })) {
                    $found += @{ Kind = "edge-tab"; Hwnd = $w.Hwnd; Title = $w.Title; Tab = $tab }
                    if ($firstOnly) { break }
                }
                if ($firstOnly -and $found.Count -gt 0) { break }
            }
        }
        $list += $found
        if ($firstOnly -and $list.Count -gt 0) { return $list }
    }
    return $list
}



# 回傳 @{ Hwnd; Kind = pwa | desktop | edge-tab; Title }；找不到回傳 $null。Edge 分頁會被切成目前分頁
# $prefer (config teams.prefer_window，選填)：只找指定種類；空白 = 依 PWA → 桌面版 → Edge 分頁
function Find-TeamsWindow([string]$prefer = "") {
    if ($prefer -and $prefer -notin $TeamsKinds) { throw "teams.prefer_window 只能是 pwa / desktop / edge-tab (目前：$prefer)" }
    $kinds = if ($prefer) { @($prefer) } else { $TeamsKinds }
    $c = Get-TeamsCandidates $kinds -firstOnly | Select-Object -First 1
    if (-not $c) { return $null }
    if ($c.Kind -eq "edge-tab") {
        Select-UIAElement $c.Tab
        Start-Sleep -Milliseconds 800
    }
    return $c
}



# 「開始」功能表 / 桌面上的 Teams PWA 捷徑 (Edge 安裝的應用程式，參數含 --app-id)；沒有回傳 $null
# 桌面只看最上層：桌面常被重新導向到 OneDrive / 網路磁碟，整個往下搜尋可能要一分鐘以上
function Find-TeamsPwaShortcut {
    $sh = New-Object -ComObject WScript.Shell
    $menus = @("$env:APPDATA\Microsoft\Windows\Start Menu\Programs", "$env:ProgramData\Microsoft\Windows\Start Menu\Programs") | Where-Object { Test-Path $_ }
    $desktop = [Environment]::GetFolderPath("Desktop")
    $lnks = @($menus | ForEach-Object { Get-ChildItem $_ -Recurse -Filter "*Teams*.lnk" -ErrorAction SilentlyContinue })
    if ($desktop -and (Test-Path $desktop)) { $lnks += @(Get-ChildItem $desktop -Filter "*Teams*.lnk" -ErrorAction SilentlyContinue) }
    $lnks | Where-Object { $sh.CreateShortcut($_.FullName).Arguments -match '--app-id' } | Select-Object -First 1
}



function Test-TeamsDesktopInstalled { Test-Path "Registry::HKEY_CLASSES_ROOT\msteams\shell\open\command" }



# Teams 被關掉時才重新開啟 (都用您現有的登入)。自動：PWA 捷徑 → 桌面版 → Edge 開 Teams 網頁版；有指定 prefer_window 時只開該種類
function Open-TeamsApp([string]$prefer = "") {
    $lnk = if (-not $prefer -or $prefer -eq "pwa") { Find-TeamsPwaShortcut } else { $null }
    $hasDesktop = (-not $prefer -or $prefer -eq "desktop") -and (Test-TeamsDesktopInstalled)
    if ($lnk) {
        Write-Host "🔄 Teams 沒有開著，正在開啟 Teams 應用程式 ($($lnk.BaseName))..." -ForegroundColor Yellow
        Start-Process $lnk.FullName
    } elseif ($hasDesktop) {
        Write-Host "🔄 Teams 沒有開著，正在開啟桌面版 Teams..." -ForegroundColor Yellow
        Start-Process "msteams:"
    } elseif (-not $prefer -or $prefer -eq "edge-tab") {
        Write-Host "🔄 Teams 沒有開著，正在用 Edge 開啟 Teams 網頁版..." -ForegroundColor Yellow
        Start-Process -FilePath (Get-BrowserPath) -ArgumentList $TeamsWebHome
    } else {
        throw "Teams 沒有開著，而且找不到可以自動開啟的$($TeamsKindText[$prefer])，請手動開啟並登入 Teams 後再試"
    }
    for ($i = 0; $i -lt 45; $i++) {
        Start-Sleep -Seconds 2
        $t = Find-TeamsWindow $prefer
        if ($t) {
            Write-Host "  ⏳ Teams 已開啟，等待載入完成..." -ForegroundColor DarkGray
            Start-Sleep -Seconds 20   # 剛開的 Teams 會在背景載入對話與草稿，太早操作會被清掉
            return $t
        }
    }
    throw "Teams 沒有開著，自動開啟後 90 秒內仍找不到 Teams 視窗，請手動開啟並登入 Teams 後再試"
}



# 設定的發送對象 → 聊天清單要找的對話。回傳 @{ Self = $true/$false; Name = 對話名稱 }
function Resolve-ChatTarget([string]$target) {
    $t = if ($target) { $target.Trim() } else { "" }
    if ($t -match '48(:|%3A)notes' -or $t -in @("自己", "self")) { return @{ Self = $true; Name = "自己（個人對話）" } }
    if ($t -match '^(https?|msteams):' -or $t -match '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
        throw "發送對象「$t」是連結或 Email：使用已開啟的 Teams 時請改填「對話名稱」（Teams 聊天清單上顯示的名稱），傳給自己請按 📨 傳給自己"
    }
    if (-not $t) { throw "沒有設定發送對象" }
    return @{ Self = $false; Name = $t }
}



# 從視窗標題取出目前對話名稱，不是聊天畫面時回傳 $null。標題格式：「聊天 | 對話名稱 | 組織 | … | Microsoft Teams」
# PWA 可能在前面加「Microsoft Teams (PWA) - 」；Edge 分頁會在後面加「 和其他 N 個頁面 - 設定檔 - Microsoft Edge」
# 聊天前可能有未讀數量，例如「Microsoft Teams (PWA) - (1) 聊天 | ...」。
function Get-ChatNameFromTitle([string]$title) {
    if ($title -match "(?:^|\s-\s)(?:\(\d+\)\s*)?${ChatPrefix}\s*\|\s*(?<name>[^|]+?)\s*(?:\||$)") { return $Matches['name'].Trim() }
    return $null
}



# 視窗標題是否為該對話：對話名稱必須完全相同 (避免「E3」誤認成「E3 乖乖」)；自己的個人對話名稱以 (您) / (You) 結尾
function Test-ChatTitle([string]$title, $chat) {
    $name = Get-ChatNameFromTitle $title
    if (-not $name) { return $false }
    if ($chat.Self) { return $name -match '\((您|You)\)$' }
    return $name -eq $chat.Name
}



# 聊天清單項目的比對條件 (項目名稱前面可能有「群組聊天」等字)
function Get-ChatItemFilter($chat) {
    if ($chat.Self) { return { $_.Current.Name -match '\((您|You)\)' } }
    # PowerShell 允許 ? 出現在變數名稱；$ChatPrefix? 會被當成另一個未定義變數。
    # 用 ${ChatPrefix} 明確結束變數名稱，保留正規表示式的可選「聊天」前綴。
    $rx = "^${ChatPrefix}?\s*$([regex]::Escape($chat.Name))(\s|$)"
    return { $_.Current.Name -match $rx }.GetNewClosure()
}



# 左側導覽列的「聊天」
function Find-TeamsChatNav($root) {
    $nav = Find-UIA $root "Button" { $_.Current.Name -match "^(聊天|Chat)(\s|\(|$)" } | Select-Object -First 1
    if (-not $nav) { $nav = Find-UIA $root "ListItem" { $_.Current.Name -match "^(聊天|Chat)(\s|\(|$)" } | Select-Object -First 1 }
    return $nav
}



# 在聊天清單找對話，不在畫面上時往下捲動 (最多 10 頁)
function Find-ChatListItem($root, [scriptblock]$match) {
    for ($scroll = 0; $scroll -le 10; $scroll++) {
        $item = Find-UIA $root "TreeItem" $match | Select-Object -First 1
        if ($item) { return $item }
        $tree = Find-UIA $root "Tree" { @(Find-UIA $_ "TreeItem" { $true }).Count -gt 0 } | Select-Object -First 1
        if (-not $tree) { return $null }
        try { $tree.GetCurrentPattern([System.Windows.Automation.ScrollPattern]::Pattern).ScrollVertical([System.Windows.Automation.ScrollAmount]::LargeIncrement) } catch { return $null }
        Start-Sleep -Milliseconds 700
    }
    return $null
}



# 在聊天清單找到並點選對話，確認視窗標題是該對話；找不到就停止
function Open-TeamsChat([IntPtr]$hwnd, $chat) {
    if (Test-ChatTitle ([E3Win]::GetTitle($hwnd)) $chat) { return }   # 已經在這個對話
    $root = $UIA::FromHandle($hwnd)
    $match = Get-ChatItemFilter $chat



    # 等 Teams 畫面載入 (剛開啟、或 Edge 睡眠中的分頁剛被喚醒時)，最多 30 秒
    $nav = $null
    for ($w = 0; $w -lt 15; $w++) {
        $root.FindAll($UIAll, $UIAny) | Out-Null   # 喚醒 Teams (Chromium) 的協助工具樹
        if (@(Find-UIA $root "TreeItem" { $true }).Count -gt 0) { break }
        $nav = Find-TeamsChatNav $root
        if ($nav) { break }
        Start-Sleep -Seconds 2
    }
    if ($nav) { Select-UIAElement $nav; Start-Sleep -Seconds 2 }   # 目前不在「聊天」畫面：先點左側的「聊天」



    $item = Find-ChatListItem $root $match
    if (-not $item -and -not $nav) {
        # 可能停在「團隊」等其他也有樹狀清單的畫面：點「聊天」後再找一次
        $nav = Find-TeamsChatNav $root
        if ($nav) { Select-UIAElement $nav; Start-Sleep -Seconds 2; $item = Find-ChatListItem $root $match }
    }
    if (-not $item) { throw "Teams 聊天清單裡找不到「$($chat.Name)」：請確認名稱與 Teams 上顯示的一模一樣（建議把該對話加到「我的最愛」）" }
    Select-UIAElement $item
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        if (Test-ChatTitle ([E3Win]::GetTitle($hwnd)) $chat) { return }
    }
    throw "已點選「$($chat.Name)」，但 Teams 視窗標題沒有變成該對話（目前：$([E3Win]::GetTitle($hwnd))），為避免傳錯已停止"
}



# 目前對話名稱 (從視窗標題取出)，不是聊天畫面時回傳 $null
function Get-CurrentChatName([IntPtr]$hwnd) { Get-ChatNameFromTitle ([E3Win]::GetTitle($hwnd)) }



# 輸入框裡的圖片數 (Teams 把貼上的圖片顯示成名為「影像 / Image」的按鈕) 與文字長度 (不含提示字「輸入訊息」)
function Get-ComposeState([IntPtr]$hwnd) {
    $box = Find-TeamsComposeBox $hwnd
    if (-not $box) { return @{ Found = $false; Images = 0; Text = 0 } }
    $all = @($box.FindAll($UIAll, $UIAny))
    $imgs = @($all | Where-Object { $_.Current.Name -match '^(影像|圖像|圖片|Image)$' -and $_.Current.ControlType.ProgrammaticName -match 'Button|Image' })
    $btn = @($imgs | Where-Object { $_.Current.ControlType.ProgrammaticName -match 'Button' })
    $imgCount = if ($btn.Count -gt 0) { $btn.Count } else { $imgs.Count }
    $text = (@($all | Where-Object { $_.Current.ControlType.ProgrammaticName -match 'Text' -and $_.Current.Name -notmatch '^(輸入訊息|Type a (new )?message)$' } | ForEach-Object { $_.Current.Name }) -join "")
    # Teams 在貼上的圖片旁會放不可見的字元 (U+2060 等)，不能算成文字
    $text = ($text -replace '[\u200B-\u200D\u2060\uFEFF\s]', '')
    return @{ Found = $true; Images = $imgCount; Text = $text.Length }
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
    $root = $UIA::FromHandle($hwnd)
    $editCond = New-Object System.Windows.Automation.PropertyCondition($UIA::ControlTypeProperty, [System.Windows.Automation.ControlType]::Edit)
    for ($i = 0; $i -lt 12; $i++) {
        # Teams (WebView2 / Edge) 的協助工具樹要先被完整查詢過一次才會建立，第一次查不到輸入框屬正常
        if ($i % 4 -eq 0) { $root.FindAll($UIAll, $UIAny) | Out-Null }
        $boxes = @($root.FindAll($UIAll, $editCond) | Where-Object {
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
function Confirm-TeamsReady([IntPtr]$hwnd, $chat) {
    if ([E3Win]::GetForegroundWindow() -ne $hwnd) {
        Write-Host "🔁 Teams 不在最前面，重新切回 Teams..." -ForegroundColor Yellow
        if (-not (Set-WindowForeground $hwnd)) { throw "無法把 Teams 視窗切到最前面，已停止貼上 (避免貼到其他視窗)" }
        if (-not (Set-TeamsComposeFocus $hwnd)) { throw "找不到 Teams「輸入訊息」框，已停止貼上" }
    }
    if (-not (Test-ChatTitle ([E3Win]::GetTitle($hwnd)) $chat)) { throw "Teams 目前不在「$($chat.Name)」對話 (可能被切走了)，已停止貼上" }
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
            $cardBody += @{ type = "Image"; url = "data:image/jpeg;base64,$b64"; size = "Stretch" }
        }
        $cardBody += @{ type = "TextBlock"; text = $messageText; wrap = $true; weight = "Bolder" }
        $payload = @{
            type = "message"
            attachments = @(@{
                contentType = "application/vnd.microsoft.card.adaptive"
                content = @{ '$schema' = "http://adaptivecards.io/schemas/adaptive-card.json"; type = "AdaptiveCard"; version = "1.4"; body = $cardBody }
            })
        } | ConvertTo-Json -Depth 15 -Compress
        Invoke-RestMethod -Uri $teamsCfg.webhook_url.Trim() -Method Post -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($payload)) | Out-Null
        Write-Host "✅ [Teams Webhook] 已成功從背景直接傳送至您的指定 Teams 對話！" -ForegroundColor Green
        return
    }



    # 【模式 B】使用已開啟的 Teams (PWA → 桌面版 → Edge 分頁)
    if (-not $script:Win32Ready) { throw "無法載入 Windows 視窗控制 (可能被公司政策封鎖)，無法操作 Teams 視窗" }
    # 先檢查文字，避免貼完圖片才發現文字無法貼上，讓圖片留在輸入框成為草稿
    if ([string]::IsNullOrWhiteSpace($messageText)) { throw "總結文字是空的，未貼上任何內容" }
    $chat = Resolve-ChatTarget $targetChatName
    $prefer = if ($teamsCfg.prefer_window) { [string]$teamsCfg.prefer_window } else { "" }
    $win = Find-TeamsWindow $prefer
    if (-not $win) { $win = Open-TeamsApp $prefer }
    $hwnd = $win.Hwnd
    $kindText = $TeamsKindText[$win.Kind]
    if (-not (Set-WindowForeground $hwnd)) { throw "無法把 Teams 視窗切到最前面 (可能螢幕已鎖定)，已停止貼上" }
    Write-Host "🪟 [Teams] 使用已開啟的 $kindText，已切到最前面（視窗標題：$([E3Win]::GetTitle($hwnd))）" -ForegroundColor Gray



    $originalChat = Get-CurrentChatName $hwnd
    Open-TeamsChat $hwnd $chat
    Write-Host "💬 [Teams] 已切換到對話：$($chat.Name)（視窗標題：$([E3Win]::GetTitle($hwnd))）" -ForegroundColor Cyan
    Start-Sleep -Seconds 2   # 等對話與輸入框載入



    if (-not (Set-TeamsComposeFocus $hwnd)) { throw "找不到 Teams「輸入訊息」框 (對話可能還沒載入完成)，已停止貼上" }
    $start = Get-ComposeState $hwnd
    if ($start.Images -gt 0 -or $start.Text -gt 0) {
        throw "「$($chat.Name)」的輸入框裡已經有您還沒送出的內容 (草稿)，為避免一起送出已停止，請先處理後再試"
    }



    & {
        # 參考同事 46518 實測限制：Teams 單一訊息最多夾帶 4 張圖片，超過自動分批
        $batchSize = 4
        $batches = [Math]::Max(1, [Math]::Ceiling($imageFiles.Count / $batchSize))
        for ($b = 0; $b -lt $batches; $b++) {
            $batchImgs = @($imageFiles | Select-Object -Skip ($b * $batchSize) -First $batchSize | Where-Object { Test-Path $_ })
            foreach ($imgFile in $batchImgs) {
                Confirm-TeamsReady $hwnd $chat
                Write-Host "📋 [Teams -> $($chat.Name)] 正在貼上圖片: $([System.IO.Path]::GetFileName($imgFile))" -ForegroundColor Gray
                $imgObj = [System.Drawing.Image]::FromFile($imgFile)
                [System.Windows.Forms.Clipboard]::SetImage($imgObj)
                $imgObj.Dispose()
                Start-Sleep -Milliseconds 400
                [System.Windows.Forms.SendKeys]::SendWait("^v")
                Start-Sleep -Seconds 1
            }
            # 等這一批圖片全部出現在輸入框 (Teams 處理貼上的圖片可能要數十秒)，最多 90 秒
            $deadline = (Get-Date).AddSeconds(90)
            do {
                Start-Sleep -Seconds 2
                # 等待期間若有人把 Teams 切到別的對話，立刻停止 (草稿留在原對話，不會送錯)
                if (-not (Test-ChatTitle ([E3Win]::GetTitle($hwnd)) $chat)) { throw "等待圖片時 Teams 被切到其他對話，已停止 (內容留在「$($chat.Name)」的輸入框，未送出)" }
                $st = Get-ComposeState $hwnd
            } while ($st.Images -lt $batchImgs.Count -and (Get-Date) -lt $deadline)
            if ($st.Images -lt $batchImgs.Count) { throw "90 秒內只有 $($st.Images)/$($batchImgs.Count) 張圖片出現在 Teams 輸入框，已停止 (內容留在輸入框，未送出)" }



            if ($b -eq $batches - 1) {
                Confirm-TeamsReady $hwnd $chat
                Write-Host "📝 [Teams -> $($chat.Name)] 正在貼上總結文字..." -ForegroundColor Gray
                [System.Windows.Forms.Clipboard]::SetText($messageText)
                Start-Sleep -Milliseconds 400
                [System.Windows.Forms.SendKeys]::SendWait("^v")
                Start-Sleep -Seconds 2
                if ((Get-ComposeState $hwnd).Text -eq 0) { throw "總結文字沒有出現在 Teams 輸入框，已停止 (未送出)" }
            }
            Write-Host "🔎 [Teams] 輸入框已有 $($st.Images) 張圖片$(if ($b -eq $batches - 1) { '與總結文字' })" -ForegroundColor DarkGray



            if ($isDryRun -or $teamsCfg.auto_press_enter -eq $false) {
                Write-Host "⏸️ [Teams -> $($chat.Name)] 已貼上圖文 (未按 Enter 送出)，請到 Teams 確認。" -ForegroundColor Yellow
                return   # 測試模式：停在該對話讓您確認，不切回原本的對話
            }
            Confirm-TeamsReady $hwnd $chat
            [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
            # 確認真的送出：輸入框被清空
            $sent = $false
            for ($i = 0; $i -lt 15 -and -not $sent; $i++) {
                Start-Sleep -Seconds 1
                if (-not (Test-ChatTitle ([E3Win]::GetTitle($hwnd)) $chat)) { throw "按下 Enter 後 Teams 被切到其他對話，無法確認是否送出，請到「$($chat.Name)」查看" }
                $st = Get-ComposeState $hwnd
                $sent = $st.Found -and $st.Images -eq 0 -and $st.Text -eq 0
            }
            if (-not $sent) { throw "按下 Enter 後 Teams 輸入框沒有清空，訊息可能沒有送出，請到 Teams 確認" }
            Write-Host "✅ [Teams -> $($chat.Name)] 已送出第 $($b + 1)/$batches 則訊息" -ForegroundColor Green
            Start-Sleep -Seconds 2
        }



        # 切回原本的對話
        if ($originalChat -and -not (Test-ChatTitle "聊天 | $originalChat" $chat)) {
            try {
                Open-TeamsChat $hwnd @{ Self = ($originalChat -match '\((您|You)\)'); Name = $originalChat }
                Write-Host "↩️ [Teams] 已切回原本的對話：$originalChat" -ForegroundColor DarkGray
            } catch { Write-Host "  (沒有切回原本的對話：$($_.Exception.Message))" -ForegroundColor DarkGray }
        }
    }
}


# ==============================================================================
# 模式：calibrator「🔍 偵測 Teams 視窗」(-DetectTeams)
# 列出開著的 Teams、發送時會用哪一個、能否讀到目前對話 / 輸入框 / 聊天清單；不切換分頁、不點選、不貼上
# 結果同時寫入 logs\teams_detect.txt (供設定工具顯示，也方便複製回報)
# ==============================================================================
if ($DetectTeams) {
    $out = New-Object System.Collections.Generic.List[string]
    $say = { param($s) $out.Add($s); Write-Host $s }
    try {
        & $say "🔍 Teams 視窗偵測  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        if (-not $script:Win32Ready) { throw "無法載入 Windows 視窗控制 (可能被公司政策封鎖)，無法操作 Teams 視窗" }
        $prefer = if ($config.teams.prefer_window) { [string]$config.teams.prefer_window } else { "" }
        & $say "使用哪種 Teams (teams.prefer_window)：$(if ($prefer) { $TeamsKindText[$prefer] } else { '自動 (PWA → 桌面版 → Edge 分頁)' })"



        & $say ""
        & $say "【找到的 Teams】"
        $cands = @(Get-TeamsCandidates)
        foreach ($c in $cands) {
            if ($c.Kind -eq "edge-tab") {
                $sel = try { $c.Tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected } catch { $false }
                & $say "  • $($TeamsKindText[$c.Kind])：分頁「$($c.Tab.Current.Name)」$(if ($sel) { '(目前分頁)' } else { '(不是目前分頁，發送時會自動切過去)' })"
            } else {
                & $say "  • $($TeamsKindText[$c.Kind])：$($c.Title)"
            }
        }
        if ($cands.Count -eq 0) { & $say "  ❌ 沒有找到開著的 Teams" }



        & $say ""
        & $say "【所有 Edge / Teams 視窗標題】(PWA 沒被認出時，請回報這段)"
        Get-TopWindows | Where-Object { $_.Proc -in @("msedge", "ms-teams", "Teams") } | ForEach-Object { & $say "  [$($_.Proc)] $($_.Title)" }
        $lnk = Find-TeamsPwaShortcut
        & $say "Teams PWA 捷徑：$(if ($lnk) { $lnk.FullName } else { '沒有' })"
        & $say "桌面版 Teams (msteams: 連結)：$(if (Test-TeamsDesktopInstalled) { '已安裝' } else { '沒有' })"



        & $say ""
        & $say "【發送時會使用】"
        $pick = $cands | Where-Object { -not $prefer -or $_.Kind -eq $prefer } | Sort-Object { $TeamsKinds.IndexOf($_.Kind) } | Select-Object -First 1
        if (-not $pick) {
            & $say "  ❌ 沒有可用的 Teams 視窗。發送時會自動開啟 Teams，但建議先手動開好並登入"
        } else {
            $hwnd = $pick.Hwnd
            & $say "  ✅ $($TeamsKindText[$pick.Kind])"
            $canInspect = $true
            if ($pick.Kind -eq "edge-tab") {
                $sel = try { $pick.Tab.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected } catch { $false }
                if (-not $sel) {
                    $canInspect = $false
                    & $say "  ⚠️ Teams 分頁不是目前分頁，無法檢查畫面內容。請在 Edge 切到 Teams 分頁後再按一次偵測"
                }
            }
            if ($canInspect) {
                $cur = Get-CurrentChatName $hwnd
                & $say "  目前對話：$(if ($cur) { $cur } else { '⚠️ 無法從視窗標題判斷 (請到 Teams 點開任一聊天再偵測；若仍失敗請回報上面的視窗標題)' })"
                $box = Find-TeamsComposeBox $hwnd
                & $say "  「輸入訊息」框：$(if ($box) { '✅ 找到' } else { '❌ 找不到 (請先點開任一聊天；若仍找不到，程式無法貼上)' })"
                $root = $UIA::FromHandle($hwnd)
                $items = @(Find-UIA $root "TreeItem" { $true })
                & $say "  聊天清單：畫面上有 $($items.Count) 個項目$(if ($items.Count -eq 0) { ' (不在「聊天」畫面，發送時會自動點左側「聊天」)' })"



                # 檢查設定的發送對象 (預設 + 各啟用排程)
                $targets = @()
                if ($config.teams.target_chat_name) { $targets += [string]$config.teams.target_chat_name }
                foreach ($s in @(Get-ScheduleList $config | Where-Object { $_.enabled -ne $false -and $_.target_chat_name })) { $targets += [string]$s.target_chat_name }
                foreach ($t in ($targets | Select-Object -Unique)) {
                    try {
                        $chat = Resolve-ChatTarget $t
                        $state = if (Test-ChatTitle ([E3Win]::GetTitle($hwnd)) $chat) { "✅ 就是目前對話" }
                                 elseif (Find-UIA $root "TreeItem" (Get-ChatItemFilter $chat) | Select-Object -First 1) { "✅ 在聊天清單畫面上" }
                                 else { "⚠️ 不在目前畫面上 (發送時會往下捲動尋找；建議加到「我的最愛」)" }
                        & $say "  發送對象「$($chat.Name)」：$state"
                    } catch {
                        & $say "  發送對象「$t」：❌ $($_.Exception.Message)"
                    }
                }
            }
        }
    } catch {
        & $say "❌ 偵測失敗：$($_.Exception.Message)"
    }
    $logDir = Join-Path $PSScriptRoot "logs"
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
    [System.IO.File]::WriteAllText((Join-Path $logDir "teams_detect.txt"), ($out -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    exit 0
}



# ==============================================================================
# 主流程：支援任意數量頁面、任意警戒線、以及分流發送到特定 Teams 群組
# ==============================================================================
# ==============================================================================
# 模式：calibrator「📸 抓圖」預覽 (-PreviewCapture -PageId <id> -Url <網址> -OutFile <png>)
# 與正式排程同一個已登入的 edge_profile、相同網頁縮放與整頁擷取，但不裁切，供設定工具框選
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
        if ($PreviewWaitSeconds -gt 0) { $wait = $PreviewWaitSeconds }
        $zoom = if ($PreviewZoom -ne 0) { Get-BrowserZoom ([pscustomobject]@{ browser_zoom = $PreviewZoom }) } else { Get-BrowserZoom $cfgPage }
        $previewPage = [pscustomobject]@{
            id = $PageId; name = "抓圖預覽 $PageId"; url = $Url; wait_seconds = $wait
            browser_zoom = $zoom
            crop_region = [pscustomobject]@{ enabled = $false }
        }
        $tmpDir = Join-Path $env:TEMP "e3_preview_capture"
        $capture = Capture-PagesNative @($previewPage) $config.auth $tmpDir -Interactive:$InteractiveCapture
        if ($capture.Failures.Contains($PageId)) { throw $capture.Failures[$PageId] }
        $shot = $capture.Files[$PageId]
        if (-not $shot -or -not (Test-Path $shot)) { throw "沒有擷取到畫面" }
        Move-Item -Path $shot -Destination $OutFile -Force
        if ($InteractiveCapture) {
            [IO.File]::WriteAllText(($OutFile + '.json'), (@{capture_view=$previewPage.capture_view} | ConvertTo-Json -Depth 5), $utf8NoBom)
        }
        $previewOk = $true
        [System.IO.File]::WriteAllText($reportFile, "OK", $utf8NoBom)
    } catch {
        Write-Host "❌ 抓圖失敗: $($_.Exception.Message)" -ForegroundColor Red
        [System.IO.File]::WriteAllText($reportFile, $_.Exception.Message, $utf8NoBom)
    } finally {
        if ($hasLock) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
        # 抓圖暫存資料夾 (%TEMP%\e3_preview_capture) 用完即刪，結果已移到 -OutFile
        if ($tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
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



# 排程截圖 captures\<yyyy-MM-dd>\ 保留 $CaptureKeepDays 天：依資料夾名稱的日期判斷 (不看修改時間)，只刪除日期格式的資料夾
$captureRoot = Join-Path $PSScriptRoot "captures"
if (Test-Path $captureRoot) {
    $keepFrom = (Get-Date).Date.AddDays(-$CaptureKeepDays)
    $removedDays = 0
    foreach ($dayDir in @(Get-ChildItem $captureRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}$' })) {
        $day = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($dayDir.Name, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$day)) { continue }
        if ($day -lt $keepFrom) {
            try { Remove-Item -LiteralPath $dayDir.FullName -Recurse -Force -ErrorAction Stop; $removedDays++ }
            catch { Write-Host "⚠️ 無法刪除舊截圖資料夾 $($dayDir.Name)：$($_.Exception.Message)" -ForegroundColor Yellow }
        }
    }
    if ($removedDays -gt 0) { Write-Host "🧹 已刪除超過 $CaptureKeepDays 天的排程截圖 ($removedDays 天)" -ForegroundColor DarkGray }
}



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
    try {
        $capture = Capture-PagesNative $enabledPages $config.auth $outDir
        $capturedFiles = $capture.Files
        $captureFailures = $capture.Failures
    } catch {
        # 整個截圖流程無法開始 (例如 Edge 啟動失敗)：每頁都標示失敗，仍通知 Teams，避免排程無聲無息地沒有送出
        Write-Host "❌ 截圖流程失敗: $($_.Exception.Message)" -ForegroundColor Red
        $capturedFiles = @{}
        $captureFailures = [ordered]@{}
        foreach ($p in $enabledPages) { $captureFailures[$p.id] = "截圖流程無法執行（$($_.Exception.Message)）" }
    }
}
if (-not $captureFailures) { $captureFailures = [ordered]@{} }
if ($captureFailures.Count -gt 0) { $exitCode = 1 }



# 發送對象優先順序：排程 target_chat_name > 頁面 target_chat_name > teams.target_chat_name
$defaultChat = if ($config.teams.target_chat_name) { $config.teams.target_chat_name } else { "預設Teams群組" }
$scheduleChat = if ($runSchedule -and $runSchedule.target_chat_name) { $runSchedule.target_chat_name.Trim() } else { "" }
# 用有序字典，讓多個群組依頁面順序發送
$chatGroups = [ordered]@{}
$sendFailures = @()



foreach ($page in $enabledPages) {
    $targetChat = if ($scheduleChat -ne "") {
        $scheduleChat
    } elseif ($page.target_chat_name -and $page.target_chat_name.Trim() -ne "") {
        $page.target_chat_name.Trim()
    } else {
        $defaultChat
    }



    $imgPath = $capturedFiles[$page.id]
    $failReason = $captureFailures[$page.id]
    if (-not $failReason -and (-not $imgPath -or -not (Test-Path $imgPath))) {
        Write-Host "⚠️ [$($page.id)] 沒有擷取到截圖，已略過" -ForegroundColor Yellow
        continue
    }



    if (-not $chatGroups.Contains($targetChat)) {
        $chatGroups[$targetChat] = @{
            images = @()
            alerts = @()
            failures = @()
        }
    }



    # 擷取失敗的頁面不送圖，改在訊息中標示原因 (不把錯誤頁 / 登入畫面當成正常結果)
    if ($failReason) {
        Write-Host "⚠️ [$($page.id)] $($page.name) (目標Teams: $targetChat) -> 擷取失敗，將在訊息中標示" -ForegroundColor Yellow
        $chatGroups[$targetChat].failures += "⚠️ $($page.name) 無法擷取：$failReason"
        continue
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
    $problems = @($alerts) + @($grp.failures)



    # 文字留空時使用與設定工具預覽相同的預設文字 (空字串無法放進剪貼簿，會讓已貼上的圖片留在輸入框成為草稿)
    $normalText = if ([string]::IsNullOrWhiteSpace($config.teams.normal_summary)) { $DefaultNormalSummary } else { $config.teams.normal_summary }
    $abnormalText = if ([string]::IsNullOrWhiteSpace($config.teams.abnormal_header)) { $DefaultAbnormalHeader } else { $config.teams.abnormal_header }
    if ($problems.Count -eq 0) {
        $msg = $normalText
    } else {
        $msg = $abnormalText + "`r`n" + ($problems -join "`r`n")
    }
    if ($runSchedule -and $runSchedule.title) {
        $msg = $runSchedule.title + "`r`n" + $msg
    }



    Write-Host "`n------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "🎯 目標 Teams 群組/聊天室: 【$chatName】 (共 $($imgs.Count) 張圖)" -ForegroundColor Cyan
    Write-Host $msg -ForegroundColor $(if ($problems.Count -eq 0) { "Green" } else { "Yellow" })
    Write-Host "------------------------------------------------------------" -ForegroundColor DarkGray



    # 發送對象仍是預設佔位文字時不貼，避免貼到目前開著的任意對話
    if (-not $NoSend -and ($chatName -match '請將.*連結|貼在這裡|^預設Teams群組$')) {
        Write-Host "⚠️ 尚未設定 Teams 發送對象 (目前為「$chatName」)，略過發送。請在 calibrator「排程與發送」填入 Teams 對話名稱。" -ForegroundColor Yellow
        $exitCode = 1
        continue
    }
    if (-not $NoSend) {
        # 逐個對話發送：一個對話失敗 (找不到對話名稱、被切走、草稿…) 只記錄並繼續送下一個對話
        try {
            Send-GroupToTeams -targetChatName $chatName -imageFiles $imgs -messageText $msg -teamsCfg $config.teams -isDryRun $DryRun
        } catch {
            $sendFailures += "【$chatName】$($_.Exception.Message)"
            $exitCode = 1
            Write-Host "❌ 發送到【$chatName】失敗：$($_.Exception.Message)" -ForegroundColor Red
            if ($chatGroups.Count -gt 1) { Write-Host "   繼續發送到其他對話..." -ForegroundColor DarkGray }
        }
    }
}
if ($sendFailures.Count -gt 0) {
    Write-Host "`n❌ 共有 $($sendFailures.Count)/$($chatGroups.Count) 個對話沒有送出：" -ForegroundColor Red
    $sendFailures | ForEach-Object { Write-Host "   $_" -ForegroundColor Red }
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
 
