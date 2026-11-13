# Receiver heartbeat watchdog. Loaded by e3_monitor_native.ps1 -ReceiverWatchdog /
# -RegisterReceiverWatchdog. Never reads chat commands or captures pages.
$script:E3ReceiverWatchdogTaskName='E3 日管接收監看'
$script:E3ReceiverWatchdogStaleMinutes=10

function Get-E3ReceiverWatchdogPaths {
    # Tests point $script:E3WatchdogLogRoot at a fixture so they never touch the real logs or outbox.
    $logs=if($script:E3WatchdogLogRoot){$script:E3WatchdogLogRoot}else{Join-Path $PSScriptRoot 'logs'}
    $root=Join-Path $logs 'teams_receiver'
    return @{root=$root;scheduleResults=(Join-Path $logs 'schedule_results');heartbeat=(Join-Path $root 'heartbeat.json');state=(Join-Path $root 'watchdog_state.json');log=(Join-Path $root 'watchdog_last.txt');deadline=(Join-Path $root 'watchdog.deadline.json')
        senderState=(Join-Path $root 'sender_login_state.json');senderLog=(Join-Path $root 'sender_login_last.txt');senderDeadline=(Join-Path $root 'sender_login.deadline.json');outbox=(Join-Path $root 'outbox');restart=(Join-Path $root 'watchdog_restart.json')
        scheduleState=(Join-Path $root 'schedule_result_state.json');privilege=(Join-Path $root 'watchdog_privilege.json');scheduleLog=(Join-Path $root 'schedule_result_last.txt')}
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
    # Do not start a check right before a schedule: both need the CDP lock and the
    # schedule may wait only 180 s for it. The next watchdog run checks instead.
    if($nextRun){$soon=($nextRun-$now).TotalMinutes;if($soon -ge 0 -and $soon -lt 5){return $false}}
    if(-not $last){return $true}
    $age=$now-$last
    # One failed check is confirmed by the next watchdog run before anyone is alerted.
    if($state.ok -eq $false -and $state.alerted -ne $true -and $age.TotalMinutes -ge 5){return $true}
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
        # A single failure can be a slow page or a leftover browser (11/12 18:39 false alarm).
        # Alert only when the previous check also failed; a real expiry fails both times.
        $confirmed=[bool]($state -and $state.ok -eq $false)
        if(-not $ok -and -not $alerted -and -not $confirmed){
            $next.pending=$true
            $logText+="`n第一次失敗，下次監看（約 10 分鐘後）再確認一次才通知"
        }elseif(-not $ok -and -not $alerted){
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

# ---- 排程傳送結果通知 ----
# A scheduled run that did not deliver (send failed, uncertain, timed out, no work lock) is
# otherwise only visible in the host log. The main engine writes logs\schedule_results\<id>.json;
# this check compares it with the Windows task's last run and queues one notice per failed run
# for the receiver (its own Teams login), because the sender's login may be the cause.
function Get-E3ScheduleCodeText([long]$code) {
    switch($code){
        1 {'執行失敗（代碼 1）'}
        124 {'超過 10 分鐘被中止（代碼 124），結果不明，可能部分已送出'}
        267014 {'被手動停止'}
        2147750687 {'前一次仍在執行，這次沒有啟動'}
        default {"結束代碼 $code"}
    }
}
# Pure decision (no I/O) so it can be tested offline. $lastRun is the task's LastRunTime.
function Get-E3ScheduleRunProblem([DateTimeOffset]$lastRun,[long]$code,$result) {
    $match=$false
    if($result){
        $started=ConvertTo-E3WatchdogTime $result.startedUtc
        $match=$started -and $started -ge $lastRun.AddMinutes(-2) -and $started -le $lastRun.AddMinutes(15)
    }
    if(-not $match){
        # Older engine or a run that ended before writing its record: only the task result is known.
        if($code -eq 0){return @{problem=$false;reason=''}}
        return @{problem=$true;reason=(Get-E3ScheduleCodeText $code)+'；沒有本次傳送紀錄，無法確認是否已送出'}
    }
    switch([string]$result.state){
        'running' {return @{problem=$true;reason=$(if($code -eq 124){Get-E3ScheduleCodeText 124}else{'工作中途結束（'+(Get-E3ScheduleCodeText $code)+'），結果不明，可能部分已送出'})}}
        'no_lock' {return @{problem=$true;reason='等不到前一個工作結束，本次未擷取、未傳送'}}
    }
    if([string]$result.skipped){return @{problem=$false;reason=''}}
    $failures=@(@($result.sendFailures)|Where-Object{$_}|ForEach-Object{[string]$_})
    if($failures.Count){
        $lines=@($failures|Select-Object -First 5|ForEach-Object{if($_.Length -gt 200){$_.Substring(0,200)+'…'}else{$_}})
        $ok=@($result.delivered).Count
        return @{problem=$true;reason=("{0} 個對象未送達或結果不明" -f $failures.Count)+$(if($ok){"（另有 $ok 個已送出）"}else{''})+"：`n"+($lines -join "`n")}
    }
    # Failed pages are listed inside a message that did arrive; only "nothing sent" needs a notice.
    if([int]$result.exitCode -ne 0 -and -not @($result.delivered).Count){
        $why=if([string]$result.error){[string]$result.error}else{'沒有任何對象收到訊息'}
        if($why.Length -gt 300){$why=$why.Substring(0,300)+'…'}
        return @{problem=$true;reason='本次沒有送出任何訊息：'+$why}
    }
    return @{problem=$false;reason=''}
}
# Short last-run status for the settings page schedule cards (pure, no I/O).
# status: none / running / ok / warn / bad. Uses the same judgment as the notice above.
function Get-E3ScheduleRunSummary($lastRun,[long]$code,$result) {
    if(-not $lastRun -or $code -eq 267011){return @{status='none';text='尚未執行過';reason=''}}
    if($code -eq 267009){return @{status='running';text='執行中';reason=''}}
    $lastRun=[DateTimeOffset]$lastRun
    $problem=Get-E3ScheduleRunProblem $lastRun $code $result
    if($problem.problem){return @{status='bad';text='可能沒有送達';reason=[string]$problem.reason}}
    $started=if($result){ConvertTo-E3WatchdogTime $result.startedUtc}else{$null}
    $match=$started -and $started -ge $lastRun.AddMinutes(-2) -and $started -le $lastRun.AddMinutes(15)
    if($match){
        switch([string]$result.skipped){
            'alert_only_normal' {return @{status='ok';text='正常，未發送（僅異常時發送）';reason=''}}
            'outside_window' {return @{status='ok';text='不在時段內，已略過';reason=''}}
        }
        if([int]$result.exitCode -ne 0){return @{status='warn';text='已送出，部分頁面失敗';reason='失敗原因已附在該則 Teams 訊息'}}
        if(-not @($result.targets).Count){return @{status='ok';text='沒有可擷取的頁面，未發送';reason=''}}
    }
    return @{status='ok';text='已送出';reason=''}
}
function Invoke-E3ScheduleResultCheck($cfg,[object[]]$Tasks=$null,[scriptblock]$InfoOf=$null,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow) {
    $paths=Get-E3ReceiverWatchdogPaths
    $resultRoot=$paths.scheduleResults
    if($null -eq $Tasks){Import-Module ScheduledTasks -ErrorAction Stop;$Tasks=@(Get-ScheduledTask -ErrorAction Stop)}
    if(-not $InfoOf){$InfoOf={param($t) $t|Get-ScheduledTaskInfo -ErrorAction Stop}}
    $state=$null;try{$state=Read-E3WorkJson $paths.scheduleState}catch{}
    $handled=@{}
    if($state -and $state.handled){foreach($p in $state.handled.PSObject.Properties){$handled[$p.Name]=[string]$p.Value}}
    $zone=[TimeZoneInfo]::FindSystemTimeZoneById('Taipei Standard Time')
    $notices=@();$changed=$false
    foreach($task in @($Tasks)){
        $id=Get-E3OwnedTaskId $task
        if(-not $id){continue}
        $info=$null;try{$info=& $InfoOf $task}catch{continue}
        if(-not $info -or -not $info.LastRunTime -or $info.LastRunTime.Year -lt 2000){continue}
        $code=[long]$info.LastTaskResult
        if($code -in @(267009,267011)){continue}   # still running / never run: decide after it ends
        $lastRun=[DateTimeOffset]$info.LastRunTime
        $done=ConvertTo-E3WatchdogTime $handled[$id]
        if($done -and $lastRun -le $done){continue}
        # Record first: a notice whose queueing fails is never repeated for the same run.
        $handled[$id]=$lastRun.ToString('O');$changed=$true
        if(($Now-$lastRun).TotalHours -gt 24){continue}   # first check after install: no old news
        $result=$null
        try{$result=Read-E3WorkJson (Join-Path $resultRoot ($id+'.json'))}catch{}
        $decision=Get-E3ScheduleRunProblem $lastRun $code $result
        if(-not $decision.problem){continue}
        $schedule=@($cfg.schedules|Where-Object{[string]$_.id -eq $id})|Select-Object -First 1
        $name=if($schedule -and ([string]$schedule.name).Trim()){([string]$schedule.name).Trim()}else{[string]$task.TaskName}
        $when=[TimeZoneInfo]::ConvertTimeFromUtc($lastRun.UtcDateTime,$zone).ToString('MM/dd HH:mm')
        $notices+="• $name（$when）：$($decision.reason)"
    }
    if($changed){Write-E3WorkJson $paths.scheduleState @{handled=$handled;lastCheckUtc=$Now.ToString('O')}}
    if(-not $notices.Count){return 0}
    $body=$notices -join "`n"
    if($body.Length -gt 1500){$body=$body.Substring(0,1500)+'…'}
    $text="✦ [日管監看]`n排程這一輪可能沒有送達。`n主機：$env:COMPUTERNAME`n$body`n不會自動重送；請到主機查看 logs 資料夾的排程紀錄與 Teams 對話，確認後再決定是否手動補跑。"
    try{$null=New-E3ReceiverOutboxMessage $text;$status='已交給日管接收端通知'}catch{$status='通知排入失敗：'+$_.Exception.Message}
    Write-E3WatchdogLog $paths.scheduleLog ($text+"`n"+$status)
    return 0
}

function ConvertTo-E3WatchdogTime($value) {
    $parsed=[DateTimeOffset]::MinValue
    if($value -and [DateTimeOffset]::TryParse([string]$value,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal,[ref]$parsed)){return $parsed}
    return $null
}

# Pure evaluation (no I/O except the injected process check) so it can be tested offline.
function Get-E3ReceiverHealth($hb,[DateTimeOffset]$now,[int]$staleMinutes=10,[scriptblock]$ProcessCheck={param($h) Test-E3WorkProcess $h}) {
    if(-not $hb){return @{ok=$false;kind='none';reason='找不到接收端心跳紀錄；接收端可能尚未用 start_teams_receiver.bat 啟動。'}}
    $limit=[TimeSpan]::FromMinutes($staleMinutes)
    if($hb.state -eq 'stopped'){
        $why=if([string]$hb.stopReason){'：'+[string]$hb.stopReason}else{'（視窗已關閉或按了 Ctrl+C）'}
        # intentional: Ctrl+C or stop_teams_receiver.bat; fatal: a setup problem a restart cannot fix.
        return @{ok=$false;kind=$(if($hb.intentional -eq $true){'intentional'}elseif($hb.fatal -eq $true){'fatal'}else{'stopped'});reason=('接收端已停止'+$why)}
    }
    if(-not (& $ProcessCheck $hb)){return @{ok=$false;kind='dead';reason='接收端程序已結束（視窗被關閉、程式當機或主機重新開機）。'}}
    $beat=ConvertTo-E3WatchdogTime $hb.utc
    $busy=ConvertTo-E3WatchdogTime $hb.busyUntilUtc
    $isBusy=$busy -and $busy -gt $now
    if(-not $beat){return @{ok=$false;kind='invalid';reason='接收端心跳紀錄格式不正確。'}}
    if(($now-$beat) -gt $limit -and -not $isBusy){
        return @{ok=$false;kind='stale';reason=('接收端已 {0} 分鐘沒有回報（可能卡住，或主機曾進入睡眠）。' -f [int]($now-$beat).TotalMinutes)}
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
        return @{ok=$false;kind='sources';reason=("接收端仍在執行並持續自動重試，但超過 $staleMinutes 分鐘無法讀取 Teams 對話（可能 Teams 登入過期或網路中斷）：`n"+($bad -join "`n"))}
    }
    return @{ok=$true;reason='正常'}
}

# ---- 執行權限比對 ----
# The watchdog ends a hung receiver before restarting it. Windows does not let a process without
# administrator rights end one that has them, so a receiver started with more rights than the
# watchdog task cannot be restarted automatically. Pure function (no I/O) for tests.
function Get-E3PrivilegeComparison($receiverElevated,$watchdogRecord) {
    $name={param($v) if($v -eq $true){'系統管理員權限'}elseif($v -eq $false){'一般權限'}else{'未知'}}
    $watch=if($watchdogRecord){$watchdogRecord.elevated}else{$null}
    $result=@{receiver=$receiverElevated;watchdog=$watch;mismatch=$false;text=''}
    if($null -eq $receiverElevated){$result.text='接收端尚未回報權限（新版接收端啟動後會記錄）';return $result}
    if($null -eq $watch){$result.text="接收端為$(& $name $receiverElevated)；監看任務尚未回報（下次執行後記錄）";return $result}
    if($receiverElevated -eq $true -and $watch -ne $true){
        $result.mismatch=$true
        $result.text='⚠ 接收端是系統管理員權限、監看任務是一般權限：接收端卡住時監看任務無法結束它，自動重新啟動會失敗，需手動關閉接收視窗後再啟動'
        return $result
    }
    if($receiverElevated -eq $watch){$result.text="一致（皆為$(& $name $watch)）";return $result}
    $result.text='接收端一般權限、監看任務系統管理員權限：不影響自動重新啟動'
    return $result
}
function Read-E3ReceiverHeartbeat([string]$path) {
    try{return @{hb=(Read-E3WorkJson $path);error=$null}}
    catch{return @{hb=$null;error=$_.Exception.Message}}
}

# ---- 接收端自動重啟 ----
# Pure decision so it can be tested offline. $history holds the UTC times of earlier
# automatic restarts. A restart is tried only for a receiver process that ended or hung;
# a requested stop, a setup problem, or a running receiver that cannot reach Teams is left alone.
function Get-E3ReceiverRestartPlan($health,$history,[DateTimeOffset]$now) {
    if($health.ok){return @{action='none';reason=''}}
    $action=switch([string]$health.kind){'dead'{'start'}'stopped'{'start'}'stale'{'kill_start'}default{'none'}}
    if($action -eq 'none'){
        $why=switch([string]$health.kind){
            'intentional'{'接收端是依要求停止的（Ctrl+C 或 stop_teams_receiver.bat），不自動重新啟動'}
            'fatal'{'接收端因設定問題停止，重新啟動無法修復'}
            'none'{'接收端尚未啟動過，不自動啟動'}
            'sources'{'接收程式仍在執行並自行重試，重新啟動無法修復登入或網路問題'}
            default{'此狀況不適用自動重新啟動'}
        }
        return @{action='none';reason=$why}
    }
    $recent=@(@($history)|ForEach-Object{ConvertTo-E3WatchdogTime $_}|Where-Object{$_ -and ($now-$_).TotalMinutes -lt 60})
    if(@($recent|Where-Object{($now-$_).TotalMinutes -lt 15}).Count){return @{action='none';waiting=$true;reason='15 分鐘內已自動重新啟動過，尚未恢復'}}
    if($recent.Count -ge 3){return @{action='none';exhausted=$true;reason='一小時內已自動重新啟動 3 次仍未恢復，暫停自動重新啟動'}}
    return @{action=$action;reason='';recent=@($recent|ForEach-Object{$_.ToString('O')})}
}
function Start-E3ReceiverAutoRestart($hb,[string]$action) {
    if($action -eq 'kill_start' -and (Test-E3WorkProcess $hb)){
        # End only the verified receiver process (same PID and start time, running teams_receiver.ps1).
        $process=Get-CimInstance Win32_Process -Filter ('ProcessId='+[int]$hb.pid) -ErrorAction SilentlyContinue
        if(-not $process -or [string]$process.CommandLine -notmatch 'teams_receiver\.ps1'){throw '無法確認卡住的程序是接收端，未結束它'}
        Stop-Process -Id ([int]$hb.pid) -Force -ErrorAction Stop
        Start-Sleep -Seconds 2
    }
    return Start-E3ReceiverProcess -WindowStyle Minimized
}
function Test-E3ReceiverRunning {
    # The receiver holds Local\E3TeamsCommandReceiver while it runs. A receiver started with
    # administrator rights may deny access to its mutex; that still means it is running.
    # Tests point $script:E3ReceiverMutexName at an isolated name.
    $name=if($script:E3ReceiverMutexName){$script:E3ReceiverMutexName}else{'Local\E3TeamsCommandReceiver'}
    $existing=$null
    try{if([Threading.Mutex]::TryOpenExisting($name,[ref]$existing)){$existing.Dispose();return $true};return $false}
    catch [UnauthorizedAccessException]{return $true}
}
function Start-E3ReceiverProcess([ValidateSet('Normal','Minimized')][string]$WindowStyle='Normal') {
    # Starts start_teams_receiver.bat, preferably through the registered "E3 日管接收端" task so the
    # receiver runs with the task's normal rights (the same as the watchdog). Never starts a second one.
    if(Test-E3ReceiverRunning){throw '仍有接收端程序在執行，未重複啟動'}
    $task=$null
    try{
        # Import only when the command is not already there (a function-local import would also hide test stand-ins).
        if(-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)){Import-Module ScheduledTasks -ErrorAction Stop}
        $task=@(Get-ScheduledTask -ErrorAction Stop|Where-Object{$_.TaskPath -eq '\' -and $_.TaskName -eq $script:E3ReceiverAutostartTaskName})|Select-Object -First 1
    }catch{$task=$null}
    if($task -and (Test-E3ReceiverTaskAction $task 'autostart') -and [string]$task.State -ne 'Disabled'){
        # A receiver that ended with an error leaves its window waiting at "pause"; that still counts
        # as a running task instance and would make Windows ignore the new start.
        if([string]$task.State -eq 'Running'){
            Stop-ScheduledTask -TaskName $script:E3ReceiverAutostartTaskName -TaskPath '\' -ErrorAction Stop
            Start-Sleep -Seconds 2
        }
        Start-ScheduledTask -TaskName $script:E3ReceiverAutostartTaskName -TaskPath '\' -ErrorAction Stop
        return '已透過 Windows 任務「'+$script:E3ReceiverAutostartTaskName+'」啟動接收端'
    }
    Start-Process -FilePath $env:ComSpec -ArgumentList ('/c "'+(Join-Path $PSScriptRoot 'start_teams_receiver.bat')+'"') -WorkingDirectory $PSScriptRoot -WindowStyle $WindowStyle
    $note=if(Test-E3ProcessElevated){'；本程式以系統管理員權限執行，接收端也會是系統管理員權限（建議先註冊開機自動啟動，改由任務以一般權限啟動）'}else{''}
    return '已執行 start_teams_receiver.bat'+$note
}
function Request-E3ReceiverStop {
    # Same as stop_teams_receiver.bat: the receiver ends by itself within a few seconds (a command in
    # progress is finished first) and the watchdog will not restart it.
    $paths=Get-E3ReceiverWatchdogPaths
    [IO.Directory]::CreateDirectory($paths.root)|Out-Null
    [IO.File]::WriteAllText((Join-Path $paths.root 'stop.request'),[DateTimeOffset]::UtcNow.ToString('O'),[Text.UTF8Encoding]::new($false))
}

function Write-E3WatchdogLog([string]$path,[string]$text) {
    # <name>_last.txt always holds the newest result. watchdog_history.log in the day's folder keeps
    # one line per change, so the repeated "正常" every 10 minutes does not fill it and the times
    # of each problem, restart and notice stay readable afterwards (30 days, cleaned by the receiver).
    try{
        $folder=[IO.Path]::GetDirectoryName($path)
        [IO.Directory]::CreateDirectory($folder)|Out-Null
        $previous=$null
        try{
            if([IO.File]::Exists($path)){
                $old=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8);$cut=$old.IndexOf("`r`n")
                if($cut -ge 0){$previous=$old.Substring($cut+2)}
            }
        }catch{$previous=$null}
        [IO.File]::WriteAllText($path,([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')+"`r`n"+$text),[Text.UTF8Encoding]::new($false))
        if($previous -cne $text){
            $day=Join-Path $folder ([DateTime]::Now.ToString('yyyy-MM-dd'))
            [IO.Directory]::CreateDirectory($day)|Out-Null
            $line=[DateTime]::Now.ToString('HH:mm:ss')+"`t"+[IO.Path]::GetFileNameWithoutExtension($path)+"`t"+(($text -replace '\s*[\r\n]+\s*',' / ').Trim())+"`r`n"
            [IO.File]::AppendAllText((Join-Path $day 'watchdog_history.log'),$line,[Text.UTF8Encoding]::new($false))
        }
    }catch{}
    Write-Host $text
}

# ---- 指令失敗說明的代發 ----
# The receiver explains a failed command with a plain-text notice from its own Teams login. When
# that send fails too (its Teams page or login is the problem), the notice is passed on once
# through the scheduled sender's login to the default chat: the two logins back each other up.
function Invoke-E3FailedNoticeRelay($cfg,[scriptblock]$Send=$null,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow) {
    $paths=Get-E3ReceiverWatchdogPaths
    if(-not [IO.Directory]::Exists($paths.outbox)){return 0}
    $files=@(Get-ChildItem -LiteralPath $paths.outbox -Filter '*.failed' -File -ErrorAction SilentlyContinue|Where-Object{($Now.UtcDateTime-$_.LastWriteTimeUtc).TotalHours -le 6}|Sort-Object Name)
    if(-not $files.Count){return 0}
    $relayLog=Join-Path $paths.root 'notice_relay_last.txt'
    $target=([string]$cfg.teams.target_chat_name).Trim()
    $code=0;$done=0;$deadline=$null
    try{
        foreach($file in $files){
            if($done -ge 3){break}   # bounded: the watchdog task has ten minutes for everything
            $item=$null;try{$item=Read-E3WorkJson $file.FullName}catch{}
            $text=[string]$item.text
            # Only explanations about a command. Other notices keep their once-only rule.
            if(-not $item -or [string]$item.kind -ne 'command_failure' -or $text -notmatch '^✦'){continue}
            $created=ConvertTo-E3WatchdogTime $item.createdUtc
            if(-not $created -or ($Now-$created).TotalHours -gt 6){continue}
            if($cfg.teams.prefer_window -ne 'cdp' -or -not $target -or $target -match '請將.*連結|貼在這裡|^預設Teams群組$'){
                Write-E3WatchdogLog $relayLog '有指令失敗說明未送出，但需要「CDP」傳送模式與預設 Teams 對話才能代發；本次未代發。'
                return 0
            }
            $base=Join-Path $paths.outbox ([IO.Path]::GetFileNameWithoutExtension($file.Name))
            # Claim by rename before sending: an attempt whose outcome is unknown is never repeated.
            try{[IO.File]::Move($file.FullName,$base+'.relaying')}catch{continue}
            $done++
            if($text.Length -gt 1800){$text=$text.Substring(0,1800)+'…'}
            $message=$text+"`n（接收端自己送不出這則說明，改由排程用的 Teams 登入轉達一次；原對話："+[string]$item.route+'）'
            try{
                if($Send){& $Send $target $message}
                else{
                    if(-not $deadline){$deadline=Start-E3RunDeadline (Join-Path $paths.root 'notice_relay.deadline.json') -Seconds 300}
                    Send-GroupToTeams -targetChatName $target -imageFiles @() -messageText $message -teamsCfg $cfg.teams -isDryRun $false|Out-Null
                }
                try{[IO.File]::Move($base+'.relaying',$base+'.relayed')}catch{}
                Write-E3WatchdogLog $relayLog ("已用排程的 Teams 登入代發指令失敗說明到「$target」：`n"+$text)
            }catch{
                $code=1
                try{[IO.File]::Move($base+'.relaying',$base+'.relayfailed')}catch{}
                Write-E3WatchdogLog $relayLog ("指令失敗說明代發失敗（不重送）："+$_.Exception.Message+"`n"+$text)
            }
        }
    }finally{if($deadline){$deadline.Dispose()}}
    return $code
}

function Invoke-E3ReceiverWatchdog($cfg,[int]$ConfirmSeconds=60) {
    $paths=Get-E3ReceiverWatchdogPaths
    $mutex=[Threading.Mutex]::new($false,'Local\E3ReceiverWatchdog');$owned=$false
    $deadline=$null
    try{
        try{$owned=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
        if(-not $owned){Write-Host '另一個監看檢查正在執行，本次略過。';return 0}
        $deadline=Start-E3RunDeadline $paths.deadline -Seconds 480
        # Record this task's rights so the receiver status and settings page can compare them.
        try{Write-E3WorkJson $paths.privilege @{elevated=(Test-E3ProcessElevated);utc=[DateTimeOffset]::UtcNow.ToString('O')}}catch{}
        $read=Read-E3ReceiverHeartbeat $paths.heartbeat
        $health=if($read.error){@{ok=$false;reason=('接收端心跳紀錄無法讀取：'+$read.error)}}else{Get-E3ReceiverHealth $read.hb ([DateTimeOffset]::UtcNow) $script:E3ReceiverWatchdogStaleMinutes}
        if(-not $health.ok -and $ConfirmSeconds -gt 0){
            # Avoid alerts for a write in progress or a receiver resuming right after wake.
            Start-Sleep -Seconds $ConfirmSeconds
            $read=Read-E3ReceiverHeartbeat $paths.heartbeat
            $health=if($read.error){@{ok=$false;reason=('接收端心跳紀錄無法讀取：'+$read.error)}}else{Get-E3ReceiverHealth $read.hb ([DateTimeOffset]::UtcNow) $script:E3ReceiverWatchdogStaleMinutes}
        }
        $restartNote=''
        if(-not $health.ok){
            # Try to bring a dead or hung receiver back before bothering anyone. The alert below
            # is sent only when the next check still finds it down.
            $history=@();try{$history=@((Read-E3WorkJson $paths.restart).attempts)}catch{}
            $plan=Get-E3ReceiverRestartPlan $health $history ([DateTimeOffset]::UtcNow)
            # stop_teams_receiver.bat leaves this request when no receiver was running to consume it.
            if($plan.action -ne 'none' -and (Test-Path -LiteralPath (Join-Path $paths.root 'stop.request'))){$plan=@{action='none';reason='已用 stop_teams_receiver.bat 要求停止，不自動重新啟動'}}
            if($plan.action -ne 'none'){
                # Record the attempt first: an attempt whose outcome is unknown still counts.
                try{Write-E3WorkJson $paths.restart @{attempts=@(@($plan.recent)+[DateTimeOffset]::UtcNow.ToString('O'));lastReason=[string]$health.reason}}catch{}
                try{
                    $done=Start-E3ReceiverAutoRestart $read.hb $plan.action
                    Write-E3WatchdogLog $paths.log ("接收端異常：$($health.reason)`n$done；下次檢查仍異常才通知。")
                    return 0
                }catch{
                    $restartNote='自動重新啟動失敗：'+$_.Exception.Message
                    $cmp=Get-E3PrivilegeComparison $read.hb.elevated @{elevated=(Test-E3ProcessElevated)}
                    if($cmp.mismatch){$restartNote+='（接收端以系統管理員權限執行，監看任務權限較低，無法結束它；請手動關閉接收視窗後重新啟動）'}
                }
            }else{$restartNote=[string]$plan.reason}
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
            $text="✦ [日管監看]`n日管接收端目前可能無法遙控。`n主機：$env:COMPUTERNAME`n原因：$($health.reason)`n最後回報（台灣時間）：$beatText$(if($restartNote){"`n自動重新啟動：$restartNote"})`n請到主機檢查接收視窗與接收端專用 Edge 的登入狀態；恢復後會再通知一次。"
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
    $execute=([string]$actions[0].Execute).Trim('"')
    if($kind -eq 'watchdog'){
        # powershell.exe … -File "<this folder>\e3_monitor_native.ps1" … -ReceiverWatchdog. The same task
        # name pointing at a copy installed in another folder belongs to that copy, not to this one.
        if([IO.Path]::GetFileName($execute) -notin @('powershell.exe','powershell')){return $false}
        $arguments=[string]$actions[0].Arguments
        if($arguments -notmatch '(?:^|\s)-ReceiverWatchdog(?:\s|$)'){return $false}
        $file=[regex]::Match($arguments,'(?:^|\s)-File\s+(?:"([^"]+)"|(\S+))')
        if(-not $file.Success){return $false}
        $script=if($file.Groups[1].Success){$file.Groups[1].Value}else{$file.Groups[2].Value}
        try{return [IO.Path]::GetFullPath($script) -ieq [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'e3_monitor_native.ps1'))}catch{return $false}
    }
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
          description='每 10 分鐘檢查日管接收端心跳（離線與恢復各通知一次），並定期檢查排程用 Teams 登入與各排程最近一輪是否送達（異常時由接收端通知）。'}
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
    $restart=$null;try{$restart=Read-E3WorkJson $paths.restart}catch{}
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
            sleepGuard=[bool]$hb.sleepGuard;stopReason=[string]$hb.stopReason;mode=[string]$hb.mode;intentional=[bool]$hb.intentional
            reloadMinutes=$(if($null -ne $hb.reloadMinutes){[int]$hb.reloadMinutes}else{$null})
            sources=@(@($hb.sources)|ForEach-Object{@{route=[string]$_.route;active=[bool]$_.active;lastOkUtc=[string]$_.lastOkUtc;error=[string]$_.error}})
        }}else{@{exists=$false}})
        health=@{ok=[bool]$health.ok;reason=[string]$health.reason}
        watchdog=$(if($state){@{alerted=[bool]$state.alerted;sinceUtc=[string]$state.sinceUtc;recoveredUtc=[string]$state.recoveredUtc;notify=[string]$state.notify}}else{@{alerted=$false}})
        senderLogin=$(if($sender){@{checked=$true;lastCheckUtc=[string]$sender.lastCheckUtc;ok=[bool]$sender.ok;reason=[string]$sender.reason;alerted=[bool]$sender.alerted;notify=[string]$sender.notify}}else{@{checked=$false}})
        pendingNotices=$pending
        privilege=$($wd=$null;try{$wd=Read-E3WorkJson $paths.privilege}catch{};$cmp=Get-E3PrivilegeComparison $(if($hb){$hb.elevated}else{$null}) $wd;@{receiver=$cmp.receiver;watchdog=$cmp.watchdog;mismatch=[bool]$cmp.mismatch;text=[string]$cmp.text})
        autoRestart=$(if($restart -and @($restart.attempts).Count){@{lastUtc=[string]@($restart.attempts)[-1];count=@($restart.attempts).Count}}else{@{count=0}})
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
