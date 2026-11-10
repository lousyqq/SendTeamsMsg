# Receiver heartbeat watchdog. Loaded by e3_monitor_native.ps1 -ReceiverWatchdog /
# -RegisterReceiverWatchdog. Never reads chat commands or captures pages.
$script:E3ReceiverWatchdogTaskName='E3 日管接收監看'
$script:E3ReceiverWatchdogStaleMinutes=10

function Get-E3ReceiverWatchdogPaths {
    $root=Join-Path $PSScriptRoot 'logs\teams_receiver'
    return @{root=$root;heartbeat=(Join-Path $root 'heartbeat.json');state=(Join-Path $root 'watchdog_state.json');log=(Join-Path $root 'watchdog_last.txt');deadline=(Join-Path $root 'watchdog.deadline.json')
        senderState=(Join-Path $root 'sender_login_state.json');senderLog=(Join-Path $root 'sender_login_last.txt');senderDeadline=(Join-Path $root 'sender_login.deadline.json');outbox=(Join-Path $root 'outbox')}
}

# ---- 排程用 Teams 登入預警 ----
# The scheduled sender's own login cannot report its own expiry, so alerts are queued for the
# phone receiver (a separate Teams login), which posts them to its own chat.
function New-E3ReceiverOutboxMessage([string]$text) {
    if($text -notmatch '^✦'){throw '通知文字必須以 ✦ 開頭，避免被當成指令'}
    $paths=Get-E3ReceiverWatchdogPaths
    $name=[DateTime]::UtcNow.ToString('yyyyMMddHHmmss')+'_'+[guid]::NewGuid().ToString('N')+'.json'
    Write-E3WorkJson (Join-Path $paths.outbox $name) @{text=$text;createdUtc=[DateTimeOffset]::UtcNow.ToString('O')}
    return $name
}

function Get-E3NextScheduleRunUtc([object[]]$Tasks=$null,[scriptblock]$InfoOf=$null) {
    # Earliest next run among this project's registered schedule tasks (Get-E3OwnedTaskId from the engine).
    # Tasks / InfoOf are injectable for offline tests; normally read from Task Scheduler.
    try{
        if($null -eq $Tasks){Import-Module ScheduledTasks -ErrorAction Stop;$Tasks=@(Get-ScheduledTask -ErrorAction Stop)}
        if(-not $InfoOf){$InfoOf={param($t) $t|Get-ScheduledTaskInfo -ErrorAction Stop}}
        $next=$null
        foreach($task in $Tasks){
            if(-not (Get-E3OwnedTaskId $task)){continue}
            $info=$null;try{$info=& $InfoOf $task}catch{}
            if($info -and $info.NextRunTime -and $info.NextRunTime.Year -gt 2000){
                $at=[DateTimeOffset]$info.NextRunTime
                if(-not $next -or $at -lt $next){$next=$at}
            }
        }
        return $next
    }catch{return $null}
}

function Test-E3SenderLoginDue($state,[DateTimeOffset]$now,$nextRun) {
    $last=if($state){ConvertTo-E3WatchdogTime $state.lastCheckUtc}else{$null}
    if(-not $last){return $true}
    $age=$now-$last
    if($age.TotalHours -ge 6){return $true}
    # About an hour before each schedule (watchdog runs every 10 minutes), at most every 3 hours.
    if($nextRun){
        $until=($nextRun-$now).TotalMinutes
        if($until -ge 0 -and $until -le 70 -and $age.TotalHours -ge 3){return $true}
    }
    # While broken, check every 30 minutes so recovery is noticed.
    if($state.ok -eq $false -and $age.TotalMinutes -ge 30){return $true}
    return $false
}

function Invoke-E3SenderLoginCheck($cfg,[scriptblock]$Check=$null,[scriptblock]$NextRun=$null) {
    if($cfg.teams.prefer_window -ne 'cdp'){return 0}
    $paths=Get-E3ReceiverWatchdogPaths
    $mutex=[Threading.Mutex]::new($false,'Local\E3SenderLoginCheck');$owned=$false;$deadline=$null
    try{
        try{$owned=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
        if(-not $owned){return 0}
        $state=$null;try{$state=Read-E3WorkJson $paths.senderState}catch{}
        $now=[DateTimeOffset]::UtcNow
        # Variable names are case-insensitive in PowerShell: keep this distinct from the $NextRun parameter.
        $upcoming=if($NextRun){& $NextRun}else{Get-E3NextScheduleRunUtc}
        if(-not (Test-E3SenderLoginDue $state $now $upcoming)){return 0}
        $deadline=Start-E3RunDeadline $paths.senderDeadline -Seconds 420
        $result=$null
        try{
            if($Check){$result=& $Check $cfg}
            else{. (Join-Path $PSScriptRoot 'teams_cdp\Delivery.ps1');$result=Test-E3CdpConnection $cfg -PassThru}
        }catch{
            $reason=$_.Exception.Message
            # Another send/setup holds the CDP lock: skip without recording, retry on the next run.
            if($reason -match 'CDP 正在傳送或設定中'){Write-E3WatchdogLog $paths.senderLog "排程登入檢查略過：CDP 正在使用中，下次再檢查。";return 0}
            $result=@{ok=$false;results=@(@{route='（檢查）';ok=$false;error=$reason})}
        }
        $ok=[bool]$result.ok
        $failed=@(@($result.results)|Where-Object{-not $_.ok}|ForEach-Object{'• '+[string]$_.route+'：'+[string]$_.error})
        if(-not $ok -and -not $failed.Count){$failed=@('• 沒有可檢查的收件對象')}
        $alerted=[bool]($state -and $state.alerted -eq $true)
        $next=@{lastCheckUtc=$now.ToString('O');ok=$ok;reason=($failed -join "`n");alerted=$alerted;sinceUtc=[string]$state.sinceUtc;notify=[string]$state.notify}
        $zone=[TimeZoneInfo]::FindSystemTimeZoneById('Taipei Standard Time')
        $nextText=if($upcoming){[TimeZoneInfo]::ConvertTimeFromUtc($upcoming.UtcDateTime,$zone).ToString('MM/dd HH:mm')}else{'無'}
        $logText=if($ok){'排程登入檢查：正常'}else{"排程登入檢查：異常`n"+($failed -join "`n")}
        if(-not $ok -and -not $alerted){
            $text="✦ [日管監看]`n排程用的 Teams 登入需要處理，下次排程可能無法傳送。`n主機：$env:COMPUTERNAME`n原因：`n"+($failed -join "`n")+"`n下次排程（台灣時間）：$nextText`n請在主機的設定工具按「設定 CDP 收件對象」重新登入。恢復後會再通知一次。"
            try{$null=New-E3ReceiverOutboxMessage $text;$next.notify='queued'}catch{$next.notify='failed';$next.error=$_.Exception.Message}
            $next.alerted=$true;$next.sinceUtc=$now.ToString('O')
            $logText+="`n已交給日管接收端通知（$($next.notify)）"
        }elseif($ok -and $alerted){
            $text="✦ [日管監看]`n排程用的 Teams 登入已恢復正常。`n主機：$env:COMPUTERNAME"
            try{$null=New-E3ReceiverOutboxMessage $text;$next.notify='queued'}catch{$next.notify='failed';$next.error=$_.Exception.Message}
            $next.alerted=$false;$next.recoveredUtc=$now.ToString('O')
            $logText+="`n已交給日管接收端通知恢復（$($next.notify)）"
        }
        Write-E3WorkJson $paths.senderState $next
        Write-E3WatchdogLog $paths.senderLog $logText
        return $(if($ok){0}else{1})
    }finally{
        if($deadline){$deadline.Dispose()}
        if($owned){$mutex.ReleaseMutex()};$mutex.Dispose()
    }
}

function ConvertTo-E3WatchdogTime($value) {
    $parsed=[DateTimeOffset]::MinValue
    if($value -and [DateTimeOffset]::TryParse([string]$value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal,[ref]$parsed)){return $parsed}
    return $null
}

# Pure evaluation (no I/O except the injected process check) so it can be tested offline.
function Get-E3ReceiverHealth($hb,[DateTimeOffset]$now,[int]$staleMinutes=10,[scriptblock]$ProcessCheck={param($h) Test-E3WorkProcess $h}) {
    if(-not $hb){return @{ok=$false;reason='找不到接收端心跳紀錄；接收端可能尚未用 start_teams_receiver.bat 啟動。'}}
    $limit=[TimeSpan]::FromMinutes($staleMinutes)
    if($hb.state -eq 'stopped'){
        $why=if([string]$hb.stopReason){'：'+[string]$hb.stopReason}else{'（視窗已關閉或按了 Ctrl+C）'}
        return @{ok=$false;reason=('接收端已停止'+$why)}
    }
    if(-not (& $ProcessCheck $hb)){return @{ok=$false;reason='接收端程序已結束（視窗被關閉、程式當機或主機重新開機）。'}}
    $beat=ConvertTo-E3WatchdogTime $hb.utc
    $busy=ConvertTo-E3WatchdogTime $hb.busyUntilUtc
    $isBusy=$busy -and $busy -gt $now
    if(-not $beat){return @{ok=$false;reason='接收端心跳紀錄格式不正確。'}}
    if(($now-$beat) -gt $limit -and -not $isBusy){
        return @{ok=$false;reason=('接收端已 {0} 分鐘沒有回報（可能卡住，或主機曾進入睡眠）。' -f [int]($now-$beat).TotalMinutes)}
    }
    if($isBusy){return @{ok=$true;reason='正在處理指令'}}
    $started=ConvertTo-E3WatchdogTime $hb.startedUtc
    if($started -and ($now-$started) -lt $limit){return @{ok=$true;reason='剛啟動，等待第一次讀取'}}
    $bad=@(foreach($s in @($hb.sources)){
        $okAt=ConvertTo-E3WatchdogTime $s.lastOkUtc
        if(-not $okAt -or ($now-$okAt) -gt $limit){
            '• '+[string]$s.route+'：'+$(if([string]$s.error){[string]$s.error}else{'尚未成功讀取對話'})
        }
    })
    if(-not @($hb.sources).Count){$bad=@('• 沒有任何接收來源')}
    if($bad.Count){
        return @{ok=$false;reason=("接收端仍在執行，但超過 $staleMinutes 分鐘無法讀取 Teams 對話（可能登入過期、專用 Edge 已關閉或分頁離開對話）：`n"+($bad -join "`n"))}
    }
    return @{ok=$true;reason='正常'}
}

function Read-E3ReceiverHeartbeat([string]$path) {
    try{return @{hb=(Read-E3WorkJson $path);error=$null}}
    catch{return @{hb=$null;error=$_.Exception.Message}}
}

function Write-E3WatchdogLog([string]$path,[string]$text) {
    try{
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))|Out-Null
        [IO.File]::WriteAllText($path,([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')+"`r`n"+$text),[Text.UTF8Encoding]::new($false))
    }catch{}
    Write-Host $text
}

function Invoke-E3ReceiverWatchdog($cfg,[int]$ConfirmSeconds=60) {
    $paths=Get-E3ReceiverWatchdogPaths
    $mutex=[Threading.Mutex]::new($false,'Local\E3ReceiverWatchdog');$owned=$false
    $deadline=$null
    try{
        try{$owned=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
        if(-not $owned){Write-Host '另一個監看檢查正在執行，本次略過。';return 0}
        $deadline=Start-E3RunDeadline $paths.deadline -Seconds 480
        $read=Read-E3ReceiverHeartbeat $paths.heartbeat
        $health=if($read.error){@{ok=$false;reason=('接收端心跳紀錄無法讀取：'+$read.error)}}else{Get-E3ReceiverHealth $read.hb ([DateTimeOffset]::UtcNow) $script:E3ReceiverWatchdogStaleMinutes}
        if(-not $health.ok -and $ConfirmSeconds -gt 0){
            # Avoid alerts for a write in progress or a receiver resuming right after wake.
            Start-Sleep -Seconds $ConfirmSeconds
            $read=Read-E3ReceiverHeartbeat $paths.heartbeat
            $health=if($read.error){@{ok=$false;reason=('接收端心跳紀錄無法讀取：'+$read.error)}}else{Get-E3ReceiverHealth $read.hb ([DateTimeOffset]::UtcNow) $script:E3ReceiverWatchdogStaleMinutes}
        }
        $state=$null
        try{$state=Read-E3WorkJson $paths.state}catch{Write-Warning ('監看狀態無法讀取，視為尚未通知：'+$_.Exception.Message)}
        $alerted=[bool]($state -and $state.alerted -eq $true)
        if($health.ok -and -not $alerted){Write-E3WatchdogLog $paths.log ('正常：'+$health.reason);return 0}
        if(-not $health.ok -and $alerted){Write-E3WatchdogLog $paths.log ("仍異常，已於 $($state.sinceUtc) 通知過，本次不重複通知：`n"+$health.reason);return 0}
        $zone=[TimeZoneInfo]::FindSystemTimeZoneById('Taipei Standard Time')
        $nowText=[TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow,$zone).ToString('yyyy-MM-dd HH:mm')
        $beat=if($read.hb){ConvertTo-E3WatchdogTime $read.hb.utc}else{$null}
        $beatText=if($beat){[TimeZoneInfo]::ConvertTimeFromUtc($beat.UtcDateTime,$zone).ToString('yyyy-MM-dd HH:mm')}else{'無'}
        if(-not $health.ok){
            $text="✦ [日管監看]`n日管接收端目前可能無法遙控。`n主機：$env:COMPUTERNAME`n原因：$($health.reason)`n最後回報（台灣時間）：$beatText`n請到主機檢查 start_teams_receiver 視窗與專用 Teams 分頁；恢復後會再通知一次。"
            $next=@{alerted=$true;reason=$health.reason;sinceUtc=[DateTimeOffset]::UtcNow.ToString('O');notify='sending'}
        }else{
            if($state.notify -ne 'sent'){
                # The outage alert was never confirmed sent; do not announce an unseen recovery.
                Write-E3WorkJson $paths.state @{alerted=$false;recoveredUtc=[DateTimeOffset]::UtcNow.ToString('O');notify='skipped'}
                Write-E3WatchdogLog $paths.log '已恢復；先前的離線通知未確認送出，不另發恢復通知。'
                return 0
            }
            $text="✦ [日管監看]`n日管接收端已恢復，可以再用 @日管 下指令。`n主機：$env:COMPUTERNAME`n恢復時間（台灣時間）：$nowText"
            $next=@{alerted=$false;recoveredUtc=[DateTimeOffset]::UtcNow.ToString('O');notify='sending'}
        }
        $target=([string]$cfg.teams.target_chat_name).Trim()
        if($cfg.teams.prefer_window -ne 'cdp'){Write-E3WatchdogLog $paths.log ("需要「CDP」傳送模式才能在鎖定時通知；本次未通知：`n"+$health.reason);return 1}
        if(-not $target -or $target -match '請將.*連結|貼在這裡|^預設Teams群組$'){Write-E3WatchdogLog $paths.log ("尚未設定預設 Teams 對話名稱，本次未通知：`n"+$health.reason);return 1}
        # Commit the decision before sending: an uncertain send is never repeated.
        Write-E3WorkJson $paths.state $next
        $code=0
        try{
            Send-GroupToTeams -targetChatName $target -imageFiles @() -messageText $text -teamsCfg $cfg.teams -isDryRun $false|Out-Null
            $next.notify='sent'
        }catch{$next.notify='failed';$next.error=$_.Exception.Message;$code=1}
        try{Write-E3WorkJson $paths.state $next}catch{Write-Warning ('監看狀態無法更新：'+$_.Exception.Message)}
        Write-E3WatchdogLog $paths.log ("通知 $target：$($next.notify)$(if($next.error){'（'+$next.error+'）'})`n"+$text)
        return $code
    }finally{
        if($deadline){$deadline.Dispose()}
        if($owned){$mutex.ReleaseMutex()};$mutex.Dispose()
    }
}

$script:E3ReceiverAutostartTaskName='E3 日管接收端'

# A task is ours only when its single action is exactly what this tool registers.
function Test-E3ReceiverTaskAction($task,[string]$kind) {
    $actions=@($task.Actions)
    if($actions.Count -ne 1){return $false}
    if($kind -eq 'watchdog'){return [string]$actions[0].Arguments -match '(?:^|\s)-ReceiverWatchdog(?:\s|$)'}
    $execute=([string]$actions[0].Execute).Trim('"')
    try{return [IO.Path]::GetFullPath($execute) -ieq [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'start_teams_receiver.bat'))}catch{return $false}
}

function New-E3ReceiverTaskPlan([string]$configPath) {
    Import-Module ScheduledTasks -ErrorAction Stop
    $principal=New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    $scriptPath=Join-Path $PSScriptRoot 'e3_monitor_native.ps1'
    $watchArgs="-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`" -ConfigPath `"$configPath`" -ReceiverWatchdog"
    # Empty repetition duration = indefinitely, every 10 minutes from now.
    $watchTrigger=New-ScheduledTaskTrigger -Once -At ([datetime]::Now.AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 10)
    $watchSettings=New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew
    # Start the visible receiver window one minute after this user logs on.
    # A zero execution limit means the long-running receiver is never stopped by the scheduler.
    $startTrigger=New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $startTrigger.Delay='PT1M'
    $startSettings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    return @(
        @{kind='watchdog';name=$script:E3ReceiverWatchdogTaskName;principal=$principal;settings=$watchSettings;trigger=$watchTrigger
          action=(New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $watchArgs -WorkingDirectory $PSScriptRoot)
          description='每 10 分鐘檢查日管接收端心跳（離線與恢復各通知一次），並定期檢查排程用 Teams 登入（過期時由接收端通知）。'}
        @{kind='autostart';name=$script:E3ReceiverAutostartTaskName;principal=$principal;settings=$startSettings;trigger=$startTrigger
          action=(New-ScheduledTaskAction -Execute (Join-Path $PSScriptRoot 'start_teams_receiver.bat') -WorkingDirectory $PSScriptRoot)
          description='登入 Windows 後自動開啟日管指令接收視窗（接收端會自行開啟專用 Edge 並回到綁定對話）。'}
    )
}

function Register-E3ReceiverWatchdog([string]$configPath,$cfg) {
    $plan=@(New-E3ReceiverTaskPlan $configPath)
    # -TaskPath '\' throws when the root folder has no tasks; list all and filter instead.
    $existing=@(Get-ScheduledTask -ErrorAction Stop|Where-Object{$_.TaskPath -eq '\'})
    # Check both names before changing either task.
    foreach($item in $plan){
        foreach($task in @($existing|Where-Object{$_.TaskName -eq $item.name})){
            if(-not (Test-E3ReceiverTaskAction $task $item.kind)){throw "Windows 已有其他任務「$($item.name)」，兩個任務都未變更"}
        }
    }
    foreach($item in $plan){
        Register-ScheduledTask -TaskName $item.name -TaskPath '\' -Action $item.action -Trigger $item.trigger -Principal $item.principal -Settings $item.settings -Description $item.description -Force -ErrorAction Stop|Out-Null
    }
    Write-Host "✅ 已註冊「$($script:E3ReceiverWatchdogTaskName)」：每 10 分鐘檢查一次，離線時通知預設對話「$([string]$cfg.teams.target_chat_name)」。" -ForegroundColor Green
    Write-Host "✅ 已註冊「$($script:E3ReceiverAutostartTaskName)」：登入 Windows 1 分鐘後自動開啟接收視窗。" -ForegroundColor Green
    Write-Host '主機重開後仍需登入 Windows（可設定自動登入或由人登入），任務才會執行。' -ForegroundColor Yellow
}

function Get-E3ReceiverOverview {
    # Read-only summary for the settings page. No account or chat identifiers.
    $paths=Get-E3ReceiverWatchdogPaths
    $hb=$null;$hbError=$null
    try{$hb=Read-E3WorkJson $paths.heartbeat}catch{$hbError=$_.Exception.Message}
    $health=if($hbError){@{ok=$false;reason='接收端心跳紀錄無法讀取。'}}else{Get-E3ReceiverHealth $hb ([DateTimeOffset]::UtcNow) $script:E3ReceiverWatchdogStaleMinutes}
    $alive=[bool]($hb -and $hb.state -ne 'stopped' -and (Test-E3WorkProcess $hb))
    $state=$null;try{$state=Read-E3WorkJson $paths.state}catch{}
    $sender=$null;try{$sender=Read-E3WorkJson $paths.senderState}catch{}
    $pending=0;try{if([IO.Directory]::Exists($paths.outbox)){$pending=@(Get-ChildItem -LiteralPath $paths.outbox -Filter '*.json' -File).Count}}catch{}
    $tasks=$null;$taskError=$null
    try{
        Import-Module ScheduledTasks -ErrorAction Stop
        $all=@(Get-ScheduledTask -ErrorAction Stop|Where-Object{$_.TaskPath -eq '\'})
        $tasks=@{}
        foreach($item in @(@{kind='watchdog';name=$script:E3ReceiverWatchdogTaskName},@{kind='autostart';name=$script:E3ReceiverAutostartTaskName})){
            $task=@($all|Where-Object{$_.TaskName -eq $item.name})|Select-Object -First 1
            if(-not $task){$tasks[$item.kind]=@{name=$item.name;registered=$false;foreign=$false};continue}
            $own=Test-E3ReceiverTaskAction $task $item.kind
            $info=$null;try{$info=$task|Get-ScheduledTaskInfo -ErrorAction Stop}catch{}
            $tasks[$item.kind]=@{
                name=$item.name;registered=[bool]$own;foreign=-not $own;enabled=([string]$task.State -ne 'Disabled')
                next=$(if($info -and $info.NextRunTime -and $info.NextRunTime.Year -gt 2000){$info.NextRunTime.ToString('MM/dd HH:mm')}else{''})
                last=$(if($info -and $info.LastRunTime -and $info.LastRunTime.Year -gt 2000 -and $info.LastTaskResult -ne 267011){$info.LastRunTime.ToString('MM/dd HH:mm')}else{''})
            }
        }
    }catch{$tasks=$null;$taskError='無法讀取 Windows 工作排程：'+$_.Exception.Message}
    return @{
        ok=$true
        heartbeat=$(if($hb){@{
            exists=$true;state=[string]$hb.state;alive=$alive;computer=[string]$hb.computer;startedUtc=[string]$hb.startedUtc;utc=[string]$hb.utc
            sleepGuard=[bool]$hb.sleepGuard;stopReason=[string]$hb.stopReason
            sources=@(@($hb.sources)|ForEach-Object{@{route=[string]$_.route;active=[bool]$_.active;lastOkUtc=[string]$_.lastOkUtc;error=[string]$_.error}})
        }}else{@{exists=$false}})
        health=@{ok=[bool]$health.ok;reason=[string]$health.reason}
        watchdog=$(if($state){@{alerted=[bool]$state.alerted;sinceUtc=[string]$state.sinceUtc;recoveredUtc=[string]$state.recoveredUtc;notify=[string]$state.notify}}else{@{alerted=$false}})
        senderLogin=$(if($sender){@{checked=$true;lastCheckUtc=[string]$sender.lastCheckUtc;ok=[bool]$sender.ok;reason=[string]$sender.reason;alerted=[bool]$sender.alerted;notify=[string]$sender.notify}}else{@{checked=$false}})
        pendingNotices=$pending
        tasks=$tasks;taskError=$taskError
    }
}

function Unregister-E3ReceiverWatchdog {
    Import-Module ScheduledTasks -ErrorAction Stop
    foreach($item in @(@{kind='watchdog';name=$script:E3ReceiverWatchdogTaskName},@{kind='autostart';name=$script:E3ReceiverAutostartTaskName})){
        $task=@(Get-ScheduledTask -ErrorAction Stop|Where-Object{$_.TaskPath -eq '\' -and $_.TaskName -eq $item.name})
        if(-not $task.Count){Write-Host "沒有「$($item.name)」任務。";continue}
        if(-not (Test-E3ReceiverTaskAction $task[0] $item.kind)){Write-Host "「$($item.name)」不是本工具建立的任務，未刪除。" -ForegroundColor Yellow;continue}
        Unregister-ScheduledTask -TaskName $item.name -TaskPath '\' -Confirm:$false -ErrorAction Stop
        Write-Host "已移除「$($item.name)」。" -ForegroundColor Green
    }
}
