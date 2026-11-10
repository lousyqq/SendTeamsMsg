param([switch]$Setup,[switch]$Listen,[switch]$LibraryOnly,[switch]$Continuous,[ValidateRange(10,1800)][int]$TimeoutSeconds=600)
$ErrorActionPreference='Stop'
# work_control.ps1 has no import side effects and loads quickly, so QuickEdit is
# disabled before the slower CDP module load (same helper as the settings service).
. (Join-Path $PSScriptRoot 'work_control.ps1')
if($Listen -and -not $LibraryOnly){
    Disable-E3ConsoleQuickEdit
    Write-Host '正在啟動日管指令接收，請稍候…' -ForegroundColor Cyan
}
. (Join-Path $PSScriptRoot 'teams_cdp\Delivery.ps1')
. (Join-Path $PSScriptRoot 'teams_receiver_commands.ps1')
$script:E3WorkEntryScript=$PSCommandPath
$script:E3WorkMayTerminate=[bool]$Setup -and -not $LibraryOnly
$script:E3ReceiverProfileRoot=Join-Path $env:LOCALAPPDATA 'E3TeamsCommandReceiver'
$script:E3CdpLogRoot=Join-Path $PSScriptRoot 'logs\teams_receiver'
function Get-E3CdpStateRoot {return $script:E3ReceiverProfileRoot}



function Get-E3ReceiverKey($binding,$message) {
    $time=[DateTimeOffset]::MinValue
    if(-not [DateTimeOffset]::TryParse([string]$message.time,[ref]$time)){throw '指令時間無法辨識'}
    # Timestamp also prevents temporary-to-final DOM ID changes replaying the same command.
    # Preserve the original timestamp key across all commands and later edits.
    $value=[string]$binding.accountId+"`n"+$binding.chatId+"`n"+$time.ToUniversalTime().ToString('O')+"`n/status"
    $sha=[Security.Cryptography.SHA256]::Create()
    try{return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($value))).Replace('-','').ToLowerInvariant()}
    finally{$sha.Dispose()}
}
function Save-E3ReceiverStatus([string]$state,[string]$message) {
    # Status is informational. A log write failure must not terminate reception.
    try{Save-E3CdpState (Join-Path $script:E3CdpLogRoot 'status.json') @{state=$state;message=$message;at=[DateTimeOffset]::UtcNow.ToString('O')}}
    catch{Write-Warning ('接收狀態暫時無法寫入：'+$_.Exception.Message)}
}
function Clear-E3ReceiverOldLogs([int]$CaptureDays=7,[int]$RecordDays=30,[DateTime]$Today=[DateTime]::Today) {
    # Only dated folders this receiver creates and its own command claims. Never touches
    # teams_cdp (blocked/review), heartbeat, status or watchdog files.
    $root=$script:E3CdpLogRoot
    if(-not $root -or -not [IO.Directory]::Exists($root)){return}
    $removed=0
    $remove={
        param([string]$parent,[int]$days)
        if(-not [IO.Directory]::Exists($parent)){return}
        foreach($dir in Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue){
            $date=[DateTime]::MinValue
            if($dir.Name -notmatch '^\d{4}-\d{2}-\d{2}$' -or -not [DateTime]::TryParseExact($dir.Name,'yyyy-MM-dd',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$date)){continue}
            if($dir.Attributes -band [IO.FileAttributes]::ReparsePoint){continue}
            if($date -lt $Today.AddDays(-$days)){
                try{Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction Stop;$script:E3ReceiverRemoved++}
                catch{Write-Warning ('舊接收紀錄暫時無法刪除：'+$dir.FullName)}
            }
        }
    }
    $script:E3ReceiverRemoved=0
    & $remove (Join-Path $root 'captures') $CaptureDays   # 指令截圖 PNG
    & $remove $root $RecordDays                           # 傳送收據與啟動診斷
    $outbox=Join-Path $root 'outbox'
    if([IO.Directory]::Exists($outbox)){
        # Finished watchdog notifications (.sent/.failed/.expired/.invalid); pending *.json stay.
        foreach($file in Get-ChildItem -LiteralPath $outbox -File -ErrorAction SilentlyContinue){
            if($file.Extension -in @('.sent','.failed','.expired','.invalid') -and $file.LastWriteTime -lt $Today.AddDays(-$RecordDays)){
                try{Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop;$script:E3ReceiverRemoved++}catch{}
            }
        }
    }
    $claims=Join-Path $root 'commands'
    if([IO.Directory]::Exists($claims)){
        # Claims older than the receiver start cutoff can never be re-selected.
        foreach($file in Get-ChildItem -LiteralPath $claims -Filter '*.json' -File -ErrorAction SilentlyContinue){
            if($file.LastWriteTime -lt $Today.AddDays(-$RecordDays)){
                try{Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop;$script:E3ReceiverRemoved++}catch{}
            }
        }
    }
    if($script:E3ReceiverRemoved){Write-Host "🧹 已清除 $($script:E3ReceiverRemoved) 筆過期接收紀錄（截圖保留 $CaptureDays 天、其他 $RecordDays 天）。" -ForegroundColor DarkGray}
}
function Save-E3ReceiverHeartbeat($sources,[string]$state,[int]$busySeconds=0,[switch]$Force) {
    # Evidence for the watchdog task (continuous mode only). Never stops reception.
    if(-not $script:E3ReceiverContinuous){return}
    $now=[DateTimeOffset]::UtcNow
    if(-not $Force -and $script:E3ReceiverHeartbeatAt -and ($now-$script:E3ReceiverHeartbeatAt).TotalSeconds -lt 30){return}
    try{
        if(-not $script:E3ReceiverProcessStart){
            $p=[Diagnostics.Process]::GetCurrentProcess()
            try{$script:E3ReceiverProcessStart=$p.StartTime.ToUniversalTime().Ticks.ToString()}finally{$p.Dispose()}
        }
        Write-E3WorkJson (Join-Path $script:E3CdpLogRoot 'heartbeat.json') @{
            version=1;state=$state;pid=$PID;processStart=$script:E3ReceiverProcessStart;computer=$env:COMPUTERNAME
            startedUtc=$script:E3ReceiverStartedUtc;utc=$now.ToString('O')
            busyUntilUtc=$(if($busySeconds -gt 0){$now.AddSeconds($busySeconds).ToString('O')}else{$null})
            sleepGuard=[bool]$script:E3ReceiverSleepGuard;stopReason=[string]$script:E3ReceiverStopReason
            sources=@($sources|ForEach-Object{@{route=[string]$_.target.route;active=[bool]$_.active;lastOkUtc=$_.lastOkUtc;error=[string]$_.error}})
        }
        $script:E3ReceiverHeartbeatAt=$now
    }catch{Write-Warning ('接收心跳暫時無法寫入：'+$_.Exception.Message)}
}
function New-E3ReceiverClaim([string]$key,[string]$command='status') {
    if($key -notmatch '^[a-f0-9]{64}$'){throw '指令識別不正確'}
    $folder=Join-Path $script:E3CdpLogRoot 'commands'
    [void][IO.Directory]::CreateDirectory($folder)
    $path=Join-Path $folder ($key+'.json')
    if(Test-Path -LiteralPath $path){return $null}
    # Commit before sending: restart never retries a possibly sent response.
    $stream=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{
        $bytes=[Text.Encoding]::UTF8.GetBytes((@{version=1;state='claimed';command=$command;at=[DateTimeOffset]::UtcNow.ToString('O')}|ConvertTo-Json -Compress))
        $stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)
    }finally{$stream.Dispose()}
    return $path
}
function Select-E3ReceiverCommand($snapshot,$binding,[DateTimeOffset]$cutoff,$previous,[Collections.Generic.HashSet[string]]$seen) {
    if(-not $snapshot.ok -or -not $snapshot.latest){throw '暫時無法讀取最新訊息，請讓專用 Teams 對話停留在最新訊息'}
    if($null -eq $previous){return $null}
    if(@($previous.ids).Count -and -not @($snapshot.ids|Where-Object{$_ -in $previous.ids}).Count){throw 'Teams 訊息銜接中斷，將重新確認最新訊息'}
    foreach($message in @($snapshot.commands)){
        if(-not $message.id -or ([string]$message.id).Length -gt 256){continue}
        $time=[DateTimeOffset]::MinValue
        if(-not [DateTimeOffset]::TryParse([string]$message.time,[ref]$time)){continue}
        if($time -le $cutoff -or $time -gt [DateTimeOffset]::UtcNow.AddSeconds(5)){continue}
        $key=Get-E3ReceiverKey $binding $message
        if($seen.Contains($key)){continue}
        # Require the same command in two separate snapshots, not an optimistic row.
        if(-not @($previous.commands|Where-Object{$_.id -ceq $message.id -and $_.time -ceq $message.time -and $_.text -ceq $message.text}).Count){continue}
        return @{key=$key;message=$message}
    }
    return $null
}
function Get-E3ReceiverScheduleLines($cfg,$tasks) {
    # Read-only view of the Windows tasks registered for this project's schedules.
    $engine=[regex]::Escape((Join-Path $PSScriptRoot 'e3_monitor_native.ps1'))
    foreach($s in @($cfg.schedules)){
        $name=([string]$s.name).Trim();if(-not $name){$name=[string]$s.id}
        $when=if($s.repeat.enabled -eq $true){"$($s.time)～$($s.repeat.end_time) 每 $($s.repeat.every) $(if($s.repeat.unit -eq 'hours'){'小時'}else{'分鐘'})"}else{[string]$s.time}
        $days=if(@($s.days).Count){(@($s.days) -join ',')+' '}else{'每天 '}
        if($s.enabled -eq $false){"• $name：已停用";continue}
        $task=@($tasks|Where-Object{
            $a=@($_.Actions)
            $a.Count -eq 1 -and [string]$a[0].Arguments -match ('-File\s+"'+$engine+'"') -and [string]$a[0].Arguments -match ('(?:^|\s)-Schedule\s+'+[regex]::Escape([string]$s.id)+'\s*$')
        })|Select-Object -First 1
        if($null -eq $tasks){"• $name（$days$when）：無法讀取 Windows 排程狀態";continue}
        if(-not $task){"• $name（$days$when）：尚未同步到 Windows 工作排程，請在設定工具按「重新套用」";continue}
        $info=$null;try{$info=$task|Get-ScheduledTaskInfo -ErrorAction Stop}catch{}
        $last=if(-not $info -or -not $info.LastRunTime -or $info.LastRunTime.Year -lt 2000 -or $info.LastTaskResult -eq 267011){'尚未執行過'}
            else{
                $result=switch([long]$info.LastTaskResult){0{'成功'}267009{'執行中'}1{'有頁面或傳送失敗，請查看主機紀錄'}124{'逾時被中止'}default{"結束代碼 $($info.LastTaskResult)"}}
                '上次 '+$info.LastRunTime.ToString('MM/dd HH:mm')+' '+$result
            }
        $next=if($info -and $info.NextRunTime -and $info.NextRunTime.Year -gt 2000){'；下次 '+$info.NextRunTime.ToString('MM/dd HH:mm')}else{''}
        "• $name（$days$when）：$last$next"
    }
}
function Get-E3ReceiverReply {
    $cfg=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config.json') -Raw -Encoding UTF8|ConvertFrom-Json
    $total=@($cfg.schedules).Count;$enabled=@($cfg.schedules|Where-Object{$_.enabled -ne $false}).Count
    $zone=[TimeZoneInfo]::FindSystemTimeZoneById('Taipei Standard Time')
    $now=[TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow,$zone).ToString('yyyy-MM-dd HH:mm:ss')
    $lines=@('✦ [日管]','指令接收正常。',"主機：$env:COMPUTERNAME","台灣時間：$now")
    $started=[DateTimeOffset]::MinValue
    if($script:E3ReceiverStartedUtc -and [DateTimeOffset]::TryParse([string]$script:E3ReceiverStartedUtc,[ref]$started)){
        $up=[DateTimeOffset]::UtcNow-$started
        $lines+='接收端已連續執行：'+$(if($up.TotalDays -ge 1){'{0} 天 {1} 小時' -f [int][Math]::Floor($up.TotalDays),$up.Hours}else{'{0} 小時 {1} 分' -f [int][Math]::Floor($up.TotalHours),$up.Minutes})
    }
    $lines+="已設定排程：$total 個，其中 $enabled 個啟用。"
    $tasks=$null
    # Get-ScheduledTask -TaskPath '\' throws when the root folder is empty; list all and filter.
    try{Import-Module ScheduledTasks -ErrorAction Stop;$tasks=@(Get-ScheduledTask -ErrorAction Stop|Where-Object{$_.TaskPath -eq '\'})}catch{}
    $lines+=@(Get-E3ReceiverScheduleLines $cfg $tasks)
    $lines+='本次只查詢狀態，未執行排程。'
    return ($lines -join "`n")
}
function Read-E3ReceiverSnapshot($target,[int]$context) {
    $source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'teams_cdp\receiver-snapshot.js'))
    $source=$source.Replace('/*E3_BINDING*/null',($target.binding|ConvertTo-Json -Depth 8 -Compress))
    return Invoke-E3Js $source $context
}
function Get-E3ReceiverTargets {
    $targets=@(Get-E3CdpBindings)
    if(-not $targets.Count){throw '請先執行 setup_teams_receiver.bat 綁定要接收的對話'}
    if($targets.Count -gt 20){throw '目前最多同時接收 20 個對話'}
    $routes=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $tabs=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $chats=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($target in $targets){
        $resolved=Resolve-E3CdpTarget ([string]$target.route)
        if(-not $routes.Add($resolved.route) -or -not $tabs.Add($resolved.targetId) -or -not $chats.Add(($resolved.binding.accountId+"`n"+$resolved.binding.chatId))){throw '接收綁定有重複名稱、分頁或對話，請保留每個來源唯一的綁定'}
        Write-Output $resolved
    }
}
function Assert-E3ReceiverDestination($target,[int]$context) {
    # A setting can be rebound while native capture releases the shared CDP lock.
    # Verify the route still refers to the frozen originating destination before send.
    $saved=Resolve-E3CdpTarget $target.route
    if($saved.targetId -cne $target.targetId){throw '接收分頁綁定已變更，本次不回覆，請重啟接收'}
    $actual=Get-E3SelfBinding $context -AllowGroup
    if(-not $actual.ok){throw '無法確認接收端目前的帳號與對話'}
    foreach($key in @('accountId','chatId','label')){
        if($actual.binding.$key -cne $target.binding.$key -or $saved.binding.$key -cne $target.binding.$key){throw '接收來源或綁定已變更，本次不回覆'}
    }
}
function Switch-E3ReceiverSource($source) {
    # Context IDs belong to a tab, never share one across source connections.
    if(-not $script:CdpSocket -or $script:CdpSocket.State -ne [Net.WebSockets.WebSocketState]::Open -or $script:CdpEndpoint -cne $source.endpoint){
        Disable-E3CdpBackgroundFocus
        Connect-E3Cdp $source.endpoint
        Enable-E3CdpBackgroundFocus
    }
}
function Get-E3ReceiverBrowserState($target) {
    # browser: dedicated Edge gone / restarted; tab: Edge alive but the bound tab is closed.
    try{$session=Get-E3CdpSession}catch{return @{state='browser';reason=$_.Exception.Message}}
    try{$tabs=@(Get-E3LocalJson "http://127.0.0.1:$($session.port)/json/list"|ForEach-Object{$_})}
    catch{return @{state='browser';reason=$_.Exception.Message}}
    if(-not @($tabs|Where-Object{$_.id -ceq $target.targetId -and $_.type -eq 'page'}).Count){return @{state='tab';session=$session;tabs=$tabs}}
    return @{state='ok';session=$session}
}
function Open-E3ReceiverBrowser {
    # Start the receiver's own visible Edge only when no process uses its profile;
    # otherwise adopt only the debugging endpoint that this profile itself published.
    $root=Get-E3CdpStateRoot
    $profile=[IO.Path]::GetFullPath((Join-Path $root 'profile'))
    if(-not(Test-Path -LiteralPath (Join-Path $profile 'Default'))){throw '尚無接收端 Teams 登入資料，請先執行 setup_teams_receiver.bat'}
    $running=@(Get-E3ProfileEdgeProcesses $profile)
    if($running.Count){
        try{$ready=Wait-E3DevToolsEndpoint (Join-Path $profile 'DevToolsActivePort') 3000}
        catch{throw '接收端專用 Edge 仍開著但無法連線；請關閉那個 Edge 視窗，接收端會自動重新開啟並回到綁定對話'}
        $listeners=@(Get-NetTCPConnection -State Listen -LocalPort $ready.port -ErrorAction SilentlyContinue)
        if(-not @($listeners|Where-Object{$_.OwningProcess -in $running.ProcessId}).Count){throw '接收端專用 Edge 的連線埠不屬於該登入資料，未連接'}
        $session=@{port=$ready.port;browserUrl=[string]$ready.version.webSocketDebuggerUrl}
        Save-E3CdpState (Join-Path $root 'session.json') $session
        Write-Host '🔄 已重新連上仍在執行的接收端專用 Edge。' -ForegroundColor Cyan
        return @{session=$session;blankTarget=$null}
    }
    Write-Host '🔄 接收端專用 Edge 未開啟，正在自動開啟（沿用原登入資料）…' -ForegroundColor Cyan
    $opened=Start-E3TestBrowser $profile
    $session=@{port=$opened.port;browserUrl=$opened.browserUrl}
    Save-E3CdpState (Join-Path $root 'session.json') $session
    if($opened.process){$opened.process.Dispose()}
    return @{session=$session;blankTarget=$opened.targetId}
}
function Update-E3ReceiverBindingTarget($target,[string]$tabId) {
    # Caller owns E3TeamsCdpShared, the same lock setup uses to write bindings.
    $path=Join-Path (Get-E3CdpStateRoot) 'bindings.json'
    $all=@(Get-E3CdpBindings)
    $hits=@($all|Where-Object{$_.route -ceq $target.route -and $_.binding.accountId -ceq $target.binding.accountId -and $_.binding.chatId -ceq $target.binding.chatId -and $_.binding.label -ceq $target.binding.label})
    if($hits.Count -ne 1){throw '接收綁定已被修改，未自動恢復；請重啟接收端'}
    $hits[0].targetId=$tabId
    Save-E3CdpState $path @($all)
}
function Restore-E3ReceiverTarget($target,$session,[string]$blankTarget) {
    # Reopen the saved chat (chatId deep link, exact-label fallback) and accept it only
    # after the same strict account/chatId/label proof used before every send.
    Connect-E3Cdp $session.browserUrl
    $tabId=$blankTarget
    $reuse=[string]$script:E3ReceiverRecoveryTabs[[string]$target.route]
    if(-not $tabId -and $reuse){
        $tabs=@(Get-E3LocalJson "http://127.0.0.1:$($session.port)/json/list"|ForEach-Object{$_})
        if(@($tabs|Where-Object{$_.id -ceq $reuse -and $_.type -eq 'page'}).Count){$tabId=$reuse}
    }
    if(-not $tabId){$tabId=[string](Invoke-E3Cdp 'Target.createTarget' @{url='about:blank'}).targetId}
    # Keep one recovery tab per source so a login page stays available for the user.
    $script:E3ReceiverRecoveryTabs[[string]$target.route]=$tabId
    $tab=@(Get-E3LocalJson "http://127.0.0.1:$($session.port)/json/list"|ForEach-Object{$_})|Where-Object{$_.id -ceq $tabId}|Select-Object -First 1
    if(-not $tab){throw '自動恢復建立的分頁已消失'}
    Connect-E3Cdp $tab.webSocketDebuggerUrl
    Invoke-E3Cdp 'Page.enable'|Out-Null
    Invoke-E3Cdp 'Page.addScriptToEvaluateOnNewDocument' @{source=(Get-E3CdpRuntimeSource 'vendor\image-frame-bootstrap.js')}|Out-Null
    Enable-E3CdpBackgroundFocus
    Move-E3HeadlessPage (Get-E3CdpChatUrl $target)
    Wait-E3HeadlessChat $target 90
    $restored=[pscustomobject]@{route=[string]$target.route;targetId=$tabId;binding=$target.binding}
    $null=Connect-E3CdpTarget $session $restored
    Update-E3ReceiverBindingTarget $target $tabId
    $script:E3ReceiverRecoveryTabs.Remove([string]$target.route)
    return $restored
}
function Repair-E3ReceiverSource($source) {
    # Recovery only reopens and re-verifies the bound chat. It never re-reads, retries
    # or replies to earlier commands; the cutoff and seen/claim records stay in force.
    $state=Get-E3ReceiverBrowserState $source.target
    if($state.state -eq 'ok'){return}
    $now=[DateTimeOffset]::UtcNow
    if($source.recoverAt -and $now -lt $source.recoverAt){
        throw ("{0}（{1} 秒後再嘗試自動恢復）" -f $(if($source.recoveryError){$source.recoveryError}else{'接收對話尚未恢復'}),[int]($source.recoverAt-$now).TotalSeconds)
    }
    $source.recoverAt=$now.AddSeconds(60)
    $route=[string]$source.target.route
    Write-Host "🔄 $route：$(if($state.state -eq 'browser'){'專用 Edge 已結束或重新開啟'}else{'綁定的分頁已關閉'})，嘗試自動回到原對話…" -ForegroundColor Cyan
    try{
        $session=$state.session;$blank=$null
        if($state.state -eq 'browser'){$opened=Open-E3ReceiverBrowser;$session=$opened.session;$blank=$opened.blankTarget}
        $source.target=Restore-E3ReceiverTarget $source.target $session $blank
        $source.recoveryError=$null;$source.recoverAt=$null
        Write-Host "✅ $route：已自動回到原對話，帳號與聊天室核對通過。" -ForegroundColor Green
    }catch{
        $source.recoveryError='自動恢復失敗：'+$_.Exception.Message
        throw $source.recoveryError
    }
}
function Get-E3ReceiverNotifySource($sources) {
    # Watchdog alerts go to the receiver's personal chat when one is bound; otherwise the first source.
    $self=@($sources|Where-Object{$_.target.binding.isSelf -eq $true})
    $pick=if($self.Count){$self[0]}else{@($sources)[0]}
    if($pick -and $pick.active){return $pick}
    return $null
}
function Send-E3ReceiverOutbox($sources,$shared) {
    # Messages queued by the watchdog (e.g. the scheduled sender's Teams login expired).
    # Each message is claimed by rename and attempted at most once; never re-sent.
    $folder=Join-Path $script:E3CdpLogRoot 'outbox'
    if(-not [IO.Directory]::Exists($folder)){return}
    $files=@(Get-ChildItem -LiteralPath $folder -Filter '*.json' -File -ErrorAction SilentlyContinue|Sort-Object Name)
    if(-not $files.Count){return}
    $source=Get-E3ReceiverNotifySource $sources
    foreach($file in $files){
        $base=Join-Path $folder ([IO.Path]::GetFileNameWithoutExtension($file.Name))
        $item=$null;try{$item=Read-E3WorkJson $file.FullName}catch{}
        $text=[string]$item.text
        if(-not $item -or $text -notmatch '^✦' -or $text.Length -gt 2000){try{[IO.File]::Move($file.FullName,$base+'.invalid')}catch{};continue}
        $created=[DateTimeOffset]::MinValue
        if(-not [DateTimeOffset]::TryParse([string]$item.createdUtc,[ref]$created) -or ([DateTimeOffset]::UtcNow-$created).TotalHours -gt 6){
            try{[IO.File]::Move($file.FullName,$base+'.expired')}catch{};continue
        }
        if(-not $source){return}   # keep queued until the chosen chat is connected
        $claimed=$base+'.sending'
        try{[IO.File]::Move($file.FullName,$claimed)}catch{continue}
        $locked=$false
        try{
            $locked=Enter-E3WorkLock $shared 'cdp' ('轉送日管監看通知：'+$source.target.route)
            $context=Connect-E3CdpTarget (Get-E3CdpSession) $source.target
            Assert-E3ReceiverDestination $source.target $context
            Assert-E3CdpComposerEmpty $context
            $source.context=$context;$source.endpoint=$script:CdpEndpoint
            Send-GroupToTeamsCdp $source.target.route @() (Format-E3ReceiverText $text) @{cdp_headless=$false;auto_press_enter=$true} $false
            try{[IO.File]::Move($claimed,$base+'.sent')}catch{}
            Write-Host "✅ 已轉送日管監看通知：$($source.target.route)" -ForegroundColor Green
        }catch{
            try{[IO.File]::Move($claimed,$base+'.failed')}catch{}
            Write-Warning ('日管監看通知未送出（不重送）：'+$_.Exception.Message)
        }finally{if($locked){Unregister-E3WorkOwner 'cdp';$shared.ReleaseMutex()}}
    }
}
function Send-E3ReceiverAcknowledgement($source,$request,[string]$claim,[string]$command,$progress) {
    $ackMutex=[Threading.Mutex]::new($false,'Local\E3TeamsCdpShared');$ackLocked=$false
    try{
        $ackLocked=Enter-E3WorkLock $ackMutex 'cdp' ('回覆 Teams 指令：'+$source.target.route)
        $target=$source.target
        $ackContext=Connect-E3CdpTarget (Get-E3CdpSession) $target
        Assert-E3ReceiverDestination $target $ackContext
        Assert-E3CdpComposerEmpty $ackContext
        $source.context=$ackContext;$source.endpoint=$script:CdpEndpoint
        $progress.phase='acknowledgement'
        Save-E3CdpState $claim @{version=3;state='ack_sending';route=$target.route;command=$command;at=[DateTimeOffset]::UtcNow.ToString('O')}
        Send-GroupToTeamsCdp $target.route @() (Format-E3ReceiverText (Get-E3ReceiverAcknowledgement $request)) @{cdp_headless=$false;auto_press_enter=$true} $false
        $progress.acknowledged=$true;$progress.phase='capture'
        Save-E3CdpState $claim @{version=3;state='acknowledged';route=$target.route;command=$command;at=[DateTimeOffset]::UtcNow.ToString('O')}
    }finally{if($ackLocked){Unregister-E3WorkOwner 'cdp';$ackMutex.ReleaseMutex()};$ackMutex.Dispose()}
}
function Invoke-E3ReceiverTest([int]$timeout=600,[switch]$Continuous) {
    $listener=[Threading.Mutex]::new($false,'Local\E3TeamsCommandReceiver')
    $shared=[Threading.Mutex]::new($false,'Local\E3TeamsCdpShared')
    $owned=$false;$locked=$false;$sources=@()
    try{
        try{$owned=$listener.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
        if(-not $owned){throw '指令接收已開啟，請勿重複啟動'}
        $script:E3ReceiverContinuous=[bool]$Continuous
        $script:E3ReceiverRecoveryTabs=@{}
        $script:E3ReceiverCleanupAt=[DateTimeOffset]::MinValue
        $script:E3ReceiverOutboxAt=[DateTimeOffset]::MinValue
        $script:E3ReceiverStartedUtc=[DateTimeOffset]::UtcNow.ToString('O')
        # Idle sleep would stop remote control. Lock / screen-off stay allowed; the
        # request ends with this process and does not change the power plan.
        Initialize-E3DesktopProbe
        $script:E3ReceiverSleepGuard=[E3CdpDesktop]::SetThreadExecutionState([uint32]2147483649) -ne 0
        if($script:E3ReceiverSleepGuard){Write-Host '接收期間要求系統保持清醒；螢幕可關閉或鎖定，不變更電源計畫。' -ForegroundColor Gray}
        else{Write-Warning '無法要求系統保持清醒；請將 Windows 電源設定的睡眠改為「永不」。'}
        $targets=@(Get-E3ReceiverTargets)
        foreach($target in $targets){
            $source=@{target=$target;active=$false;previous=$null;cutoff=[DateTimeOffset]::UtcNow;retryAt=[DateTimeOffset]::MinValue;seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);lastOkUtc=$null;error=$null;recoverAt=$null;recoveryError=$null}
            $sources+=$source
        }
        Save-E3ReceiverStatus 'connecting' '正在連線至已綁定的對話；暫時失敗會自動重連'
        Save-E3ReceiverHeartbeat $sources 'listening' -Force
        Write-Host '可輸入 @日管 狀態、@日管 截圖清單，或 @日管 幫我截圖 名稱。'
        Write-Host $(if($Continuous){'持續接收。專用 Edge 或分頁被關閉時，會自動重新開啟並回到原對話；Ctrl+C 停止。'}else{'回覆一個指令後結束；Ctrl+C 停止。'})
        $deadline=[DateTimeOffset]::UtcNow.AddSeconds($timeout)
        while($Continuous -or [DateTimeOffset]::UtcNow -lt $deadline){
            Start-Sleep -Milliseconds 1000
            Save-E3ReceiverHeartbeat $sources 'listening'
            if([DateTimeOffset]::UtcNow -ge $script:E3ReceiverCleanupAt){
                $script:E3ReceiverCleanupAt=[DateTimeOffset]::UtcNow.AddHours(24)
                try{Clear-E3ReceiverOldLogs}catch{Write-Warning ('舊接收紀錄清理失敗：'+$_.Exception.Message)}
            }
            foreach($source in $sources){
                if([DateTimeOffset]::UtcNow -lt $source.retryAt){continue}
                try{$locked=$shared.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
                if(-not $locked){continue}
                $claim=$null;$replied=$false;$target=$source.target;$progress=@{phase='received';acknowledged=$false}
                try{
                    if(-not $source.active){
                        # Only reconnect / recovery can hold the lock for seconds; publish the
                        # owner then. A 1 s snapshot poll holds it for milliseconds and writing
                        # an owner file every second would only churn the disk.
                        Register-E3WorkOwner 'cdp' ('接收 Teams 指令（重新連線）：'+$target.route)
                        Repair-E3ReceiverSource $source
                        $target=$source.target
                        $context=Connect-E3CdpTarget (Get-E3CdpSession) $target
                        Assert-E3ReceiverDestination $target $context
                        $source.context=$context;$source.endpoint=$script:CdpEndpoint
                        $source.previous=$null
                    }else{Switch-E3ReceiverSource $source}
                    $context=$source.context
                    $snapshot=Read-E3ReceiverSnapshot $target $context
                    $candidate=Select-E3ReceiverCommand $snapshot $target.binding $source.cutoff $source.previous $source.seen
                    $source.previous=$snapshot
                    $source.lastOkUtc=[DateTimeOffset]::UtcNow.ToString('O');$source.error=$null
                    if(-not $source.active){
                        $source.active=$true
                        Write-Host "✅ 已接收：$($target.route)" -ForegroundColor Green
                        Save-E3ReceiverStatus 'listening' ("已接收："+$target.route)
                        Save-E3ReceiverHeartbeat $sources 'listening' -Force
                    }
                    if(-not $candidate){continue}
                    [void]$source.seen.Add($candidate.key)
                    $command=[string]$candidate.message.text
                    $claim=New-E3ReceiverClaim $candidate.key $command
                    if(-not $claim){continue}
                    Unregister-E3WorkOwner 'cdp';$shared.ReleaseMutex();$locked=$false
                    Save-E3ReceiverStatus 'processing' ("正在處理："+$target.route)
                    # Capture (max 330 s) plus two lock waits and sends stay within 20 minutes.
                    Save-E3ReceiverHeartbeat $sources 'processing' 1200 -Force
                    $response=Get-E3ReceiverResponse $candidate.message $candidate.key -BeforeCapture {
                        param($request)
                        Send-E3ReceiverAcknowledgement $source $request $claim $command $progress
                    }
                    if(-not $response){continue}
                    $locked=Enter-E3WorkLock $shared 'cdp' ('回覆 Teams 指令：'+$target.route)
                    $context=Connect-E3CdpTarget (Get-E3CdpSession) $target
                    Assert-E3ReceiverDestination $target $context
                    $source.context=$context;$source.endpoint=$script:CdpEndpoint
                    Assert-E3CdpComposerEmpty $context
                    $progress.phase='result'
                    Send-GroupToTeamsCdp $target.route @($response.images) (Format-E3ReceiverText $response.text -ImageReply:($response.images.Count -gt 0)) @{cdp_headless=$false;auto_press_enter=$true} $false
                    $replied=$true
                    Save-E3CdpState $claim @{version=3;state='replied';acknowledged=$progress.acknowledged;route=$target.route;command=$command;at=[DateTimeOffset]::UtcNow.ToString('O')}
                    Save-E3ReceiverStatus $(if($Continuous){'listening'}else{'replied'}) ("已回覆："+$target.route)
                    Write-Host "✅ 已回覆：$($target.route)" -ForegroundColor Green
                    Save-E3ReceiverHeartbeat $sources 'listening' -Force
                    if(-not $Continuous){return}
                }catch{
                    $source.active=$false;$source.error=$_.Exception.Message
                    $source.retryAt=[DateTimeOffset]::UtcNow.AddSeconds(10)
                    # Claims remain durable even if updating their outcome fails. Never retry
                    # this command; recovery only reconnects and reads for new commands.
                    if($claim -and -not $replied){
                        try{Save-E3CdpState $claim @{version=3;state='not_retried';phase=$progress.phase;acknowledged=$progress.acknowledged;route=$target.route;command=$command;at=[DateTimeOffset]::UtcNow.ToString('O')}}
                        catch{Write-Warning ('指令結果暫時無法更新；保留原紀錄，不重送：'+$_.Exception.Message)}
                    }
                    Write-Host "⚠ $($target.route)：$($source.error)；10 秒後重新連線，繼續接收新指令；本次指令不重送。" -ForegroundColor Yellow
                    Save-E3ReceiverStatus 'recovering' ("等待重新連線："+$target.route+"；"+$source.error)
                }finally{if($locked){Unregister-E3WorkOwner 'cdp';$shared.ReleaseMutex();$locked=$false}}
            }
            if([DateTimeOffset]::UtcNow -ge $script:E3ReceiverOutboxAt){
                $script:E3ReceiverOutboxAt=[DateTimeOffset]::UtcNow.AddSeconds(5)
                try{Send-E3ReceiverOutbox $sources $shared}catch{Write-Warning ('日管監看通知處理失敗：'+$_.Exception.Message)}
            }
        }
        Save-E3ReceiverStatus 'timeout' '等待指令逾時，接收已結束'
    }catch{if($owned){$script:E3ReceiverStopReason=$_.Exception.Message;Save-E3ReceiverStatus 'stopped' $_.Exception.Message};throw}
    finally{
        # Ctrl+C also runs this block; the watchdog then reports a stopped receiver.
        if($script:E3ReceiverSleepGuard){[void][E3CdpDesktop]::SetThreadExecutionState([uint32]2147483648);$script:E3ReceiverSleepGuard=$false}
        if($owned){Save-E3ReceiverHeartbeat $sources 'stopped' -Force}
        Disable-E3CdpBackgroundFocus
        if($script:CdpSocket){$script:CdpSocket.Dispose();$script:CdpSocket=$null}
        if($locked){Unregister-E3WorkOwner 'cdp';$shared.ReleaseMutex()};$shared.Dispose()
        if($owned){$listener.ReleaseMutex()};$listener.Dispose()
    }
}
if(-not $LibraryOnly){
    try{
        if($Setup){
            Write-Host '接收端使用獨立登入視窗。每個來源綁定一個分頁，回覆會留在原來源。'
            Set-E3CdpBinding @{teams=@{cdp_headless=$false};pages=@();schedules=@()} -SelectInBrowser
        }elseif($Listen){Invoke-E3ReceiverTest $TimeoutSeconds -Continuous:$Continuous}
        else{throw '請使用 -Setup 設定接收來源，或 -Listen 接收 @日管 指令'}
    }catch{Write-Host ('❌ '+$_.Exception.Message) -ForegroundColor Red;exit 1}
}
 