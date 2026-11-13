# Isolated tests of starting / stopping / setting up the receiver from the settings page:
# the running check, start through the Windows task or the .bat, the stop request, and the local
# service API with its one-setup-window guard. Uses an isolated mutex name, stand-in task cmdlets,
# a temporary copy of the program with a stand-in setup .bat and a temporary port. No receiver,
# Edge, Teams send, real config change or Windows task change.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path $env:TEMP ('E3ReceiverControl_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
. (Join-Path $root 'work_control.ps1')
. (Join-Path $root 'teams_receiver_watchdog.ps1')
$script:E3WatchdogLogRoot=Join-Path $fixture 'logs'
$script:E3ReceiverMutexName='Local\E3ReceiverControlTest_'+[guid]::NewGuid().ToString('N')
$passed=0
function Check([bool]$ok,[string]$name){if(-not $ok){throw "FAIL $name"};$script:passed++;Write-Host "PASS $name"}

# ---- A. Running check ----
Check (-not (Test-E3ReceiverRunning)) 'no receiver mutex: not running'
$held=[Threading.Mutex]::new($true,$script:E3ReceiverMutexName)
Check (Test-E3ReceiverRunning) 'receiver mutex held: running'

# ---- B. Start: through the task when it is ours, else the .bat; never a second receiver ----
$script:calls=[Collections.Generic.List[string]]::new();$script:task=$null
function Get-ScheduledTask{param($TaskName,$TaskPath,$ErrorAction) if($script:task){return $script:task}}
function Start-ScheduledTask{param($TaskName,$TaskPath,$ErrorAction) $script:calls.Add("start-task:$TaskName")}
function Stop-ScheduledTask{param($TaskName,$TaskPath,$ErrorAction) $script:calls.Add("stop-task:$TaskName")}
function Start-Process{param($FilePath,$ArgumentList,$WorkingDirectory,$WindowStyle) $script:calls.Add("process:$ArgumentList|$WindowStyle")}
function Start-Sleep{param([int]$Seconds,[int]$Milliseconds)}
function New-Task([string]$state,[string]$execute){
    return [pscustomobject]@{TaskPath='\';TaskName='E3 日管接收端';State=$state;Actions=@([pscustomobject]@{Execute=$execute;Arguments=''})}
}
$bat=Join-Path $root 'start_teams_receiver.bat'
$r='';try{$null=Start-E3ReceiverProcess}catch{$r=$_.Exception.Message}
Check ($r -match '仍有接收端程序在執行' -and -not $script:calls.Count) 'refuses to start while a receiver runs'
$held.ReleaseMutex();$held.Dispose()
$script:task=New-Task 'Ready' $bat;$script:calls.Clear()
$m=Start-E3ReceiverProcess
Check ((@($script:calls) -join ',') -eq 'start-task:E3 日管接收端' -and $m -match 'Windows 任務') 'registered task: started through the task (normal rights)'
$script:task=New-Task 'Running' $bat;$script:calls.Clear()
$null=Start-E3ReceiverProcess
Check ((@($script:calls) -join ',') -eq 'stop-task:E3 日管接收端,start-task:E3 日管接收端') 'task still at the old window''s pause: ended, then started'
$script:task=New-Task 'Disabled' $bat;$script:calls.Clear()
$null=Start-E3ReceiverProcess -WindowStyle Normal
Check ($script:calls.Count -eq 1 -and $script:calls[0] -match 'start_teams_receiver\.bat' -and $script:calls[0] -match '\|Normal$') 'disabled task: runs the .bat in a normal window'
$script:task=New-Task 'Ready' 'C:\Other\start_teams_receiver.bat';$script:calls.Clear()
$m=Start-E3ReceiverProcess
Check ($script:calls.Count -eq 1 -and $script:calls[0] -match '^process:' -and $m -match 'start_teams_receiver\.bat') 'someone else''s task of the same name is not used'
$script:task=$null;$script:calls.Clear()
$null=Start-E3ReceiverAutoRestart @{pid=0} 'start'
Check ($script:calls.Count -eq 1 -and $script:calls[0] -match '\|Minimized$') 'watchdog auto-restart still starts minimized'
Remove-Item function:Get-ScheduledTask,function:Start-ScheduledTask,function:Stop-ScheduledTask,function:Start-Process,function:Start-Sleep

# ---- B2. Which watchdog / autostart task is ours: this folder only ----
function Fake-Task([string]$execute,[string]$arguments){return [pscustomobject]@{Actions=@([pscustomobject]@{Execute=$execute;Arguments=$arguments})}}
$script=Join-Path $root 'e3_monitor_native.ps1'
Check (Test-E3ReceiverTaskAction (Fake-Task 'powershell.exe' "-NoProfile -File `"$script`" -ConfigPath `"C:\x\config.json`" -ReceiverWatchdog") 'watchdog') 'watchdog task running this folder''s script is ours'
Check (-not (Test-E3ReceiverTaskAction (Fake-Task 'powershell.exe' '-NoProfile -File "D:\OtherCopy\e3_monitor_native.ps1" -ReceiverWatchdog') 'watchdog')) 'the same task pointing at another installed copy is not ours'
Check (-not (Test-E3ReceiverTaskAction (Fake-Task 'powershell.exe' "-NoProfile -File `"$script`" -Schedule morning") 'watchdog')) 'a task without -ReceiverWatchdog is not the watchdog'
Check (-not (Test-E3ReceiverTaskAction (Fake-Task 'cmd.exe' "/c powershell -File `"$script`" -ReceiverWatchdog") 'watchdog')) 'a task that does not run powershell directly is not ours'
Check (-not (Test-E3ReceiverTaskAction ([pscustomobject]@{Actions=@((Fake-Task 'powershell.exe' "-File `"$script`" -ReceiverWatchdog").Actions[0],(Fake-Task 'x.exe' '').Actions[0])}) 'watchdog')) 'a task with an extra action is not ours'
# What this tool registers must pass its own check (the plan is only built, never registered).
$plan=@(New-E3ReceiverTaskPlan (Join-Path $root 'config.json'))
foreach($item in $plan){
    Check (Test-E3ReceiverTaskAction ([pscustomobject]@{Actions=@($item.action)}) $item.kind) "the registered $($item.kind) task is recognised as ours"
}

# ---- C. Stop request ----
Request-E3ReceiverStop
$stop=Join-Path $script:E3WatchdogLogRoot 'teams_receiver\stop.request'
Check ((Test-Path -LiteralPath $stop) -and [DateTimeOffset]::Parse([IO.File]::ReadAllText($stop)) -gt [DateTimeOffset]::UtcNow.AddMinutes(-1)) 'stop writes the same request file as stop_teams_receiver.bat'

# ---- D. start_teams_receiver.bat: a normal stop closes the window, an error keeps it ----
$text=[IO.File]::ReadAllText($bat)
Check ($text -match "(?m)^if not errorlevel 1 exit /b 0\r$" -and $text.IndexOf('exit /b 0') -lt $text.IndexOf('check_files.ps1') -and $text.TrimEnd().EndsWith('pause')) 'start .bat closes on a normal stop and pauses on an error'

# ---- E. Local service API (temporary copy, stand-in setup .bat) ----
$copy=Join-Path $fixture 'app'
[void][IO.Directory]::CreateDirectory($copy)
foreach($f in Get-ChildItem -LiteralPath $root -File){Copy-Item -LiteralPath $f.FullName -Destination $copy}
foreach($d in 'teams_cdp','tools'){Copy-Item -LiteralPath (Join-Path $root $d) -Destination $copy -Recurse}
[IO.File]::WriteAllText((Join-Path $copy 'setup_teams_receiver.bat'),"@echo off`r`nrem stand-in for the setup window`r`nping -n 40 127.0.0.1 >nul`r`n",[Text.Encoding]::ASCII)
$probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$probe.Start();$port=$probe.LocalEndpoint.Port;$probe.Stop()
$service=Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $copy 'e3_monitor_native.ps1')`" -Calibrator -Port $port -NoBrowser" -WindowStyle Hidden -PassThru
Add-Type -AssemblyName System.Net.Http
$handler=[Net.Http.HttpClientHandler]::new();$handler.UseProxy=$false
$http=[Net.Http.HttpClient]::new($handler);$http.Timeout=[TimeSpan]::FromSeconds(30)
function Api([string]$method,[string]$body=$null){
    $req=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($method),"http://127.0.0.1:$port/api/receiver-control")
    if($body){$req.Content=[Net.Http.StringContent]::new($body,[Text.Encoding]::UTF8,'application/json')}
    $resp=$http.SendAsync($req).GetAwaiter().GetResult()
    return @{status=[int]$resp.StatusCode;data=($resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()|ConvertFrom-Json)}
}
$setupPids=@()
try{
    $until=(Get-Date).AddSeconds(60);$ready=$false
    do{try{$ready=$http.GetAsync("http://127.0.0.1:$port/calibrator.html").GetAwaiter().GetResult().IsSuccessStatusCode}catch{};if(-not $ready){Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 500}}while(-not $ready -and (Get-Date) -lt $until)
    Check $ready 'temporary settings service started'
    $g=Api 'GET'
    Check ($g.status -eq 200 -and $g.data.ok -and $g.data.setupOpen -eq $false) 'GET reports the running state and no setup window'
    $runningNow=[bool]$g.data.running
    $b=Api 'POST' '{"action":"format"}'
    Check ($b.status -eq 400 -and $b.data.error -eq '不支援的操作') 'unknown action is refused'
    if(-not $runningNow){
        $s=Api 'POST' '{"action":"stop"}'
        Check ($s.status -eq 409 -and $s.data.error -eq '接收端沒有在執行') 'stop with no receiver says so and writes nothing'
        $o=Api 'POST' '{"action":"setup"}'
        Check ($o.status -eq 200 -and $o.data.message -match 'BIND') 'setup opens the setup window (stand-in)'
        $setupPids=@(Get-CimInstance Win32_Process -Filter "Name='cmd.exe'"|Where-Object{$_.CommandLine -like "*$(Split-Path $fixture -Leaf)*setup_teams_receiver.bat*"}|ForEach-Object{$_.ProcessId})
        Check ($setupPids.Count -eq 1) 'exactly one setup window was started'
        $o2=Api 'POST' '{"action":"setup"}'
        Check ($o2.status -eq 409 -and $o2.data.error -match '已經開著') 'a second setup click does not open another window'
        Check ((Api 'GET').data.setupOpen -eq $true) 'GET reports the open setup window'
        $st=Api 'POST' '{"action":"start"}'
        Check ($st.status -eq 409 -and $st.data.error -match '設定接收對話的視窗還開著') 'start is refused while the setup window is open (nothing started)'
        foreach($id in $setupPids){Get-CimInstance Win32_Process -Filter "ParentProcessId=$id"|ForEach-Object{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue};Stop-Process -Id $id -Force -ErrorAction SilentlyContinue}
        Microsoft.PowerShell.Utility\Start-Sleep -Seconds 1
        Check ((Api 'GET').data.setupOpen -eq $false) 'closing the setup window clears the guard'
    }else{Write-Host 'SKIP stop/setup API checks: a real receiver is running on this computer'}
}finally{
    # Any stand-in setup window still open (matched by this run's folder name, short or long path form).
    Get-CimInstance Win32_Process -Filter "Name='cmd.exe'"|Where-Object{$_.CommandLine -like "*$(Split-Path $fixture -Leaf)*"}|ForEach-Object{Get-CimInstance Win32_Process -Filter "ParentProcessId=$($_.ProcessId)"|ForEach-Object{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue};Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}
    if($service -and -not $service.HasExited){Stop-Process -Id $service.Id -Force -ErrorAction SilentlyContinue}
    $http.Dispose()
    Microsoft.PowerShell.Utility\Start-Sleep -Seconds 1
    Remove-Item $fixture -Recurse -Force -ErrorAction SilentlyContinue
}
"PASS $passed checks."
