param([switch]$Setup,[switch]$Listen,[switch]$Stop,[switch]$LibraryOnly,[switch]$Continuous,[ValidateRange(10,1800)][int]$TimeoutSeconds=600)
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
            version=2;state=$state;pid=$PID;processStart=$script:E3ReceiverProcessStart;computer=$env:COMPUTERNAME
            mode=$(if($script:E3ReceiverHeadless){'headless'}else{'window'});intentional=[bool]$script:E3ReceiverIntentional;fatal=[bool]$script:E3ReceiverFatal
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
    if(-not $snapshot.ok -or -not $snapshot.latest){throw $(if($snapshot.error){[string]$snapshot.error}else{'接收端尚未取得最新訊息，等待畫面穩定'})}
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
function Get-E3ReceiverScript([string]$file,$target) {
    $source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot ('teams_cdp\'+$file)))
    return $source.Replace('/*E3_BINDING*/null',($target.binding|ConvertTo-Json -Depth 8 -Compress))
}
function Read-E3ReceiverSnapshot($target,[int]$context) {
    return Invoke-E3Js (Get-E3ReceiverScript 'receiver-snapshot.js' $target) $context
}
function Read-E3ReceiverSettled($target,[int]$context,[int]$TimeoutMs=8000) {
    # A chat that was just opened may still be loading or moving to its newest message.
    # "Not at the newest message yet" is a wait, never a lost connection.
    $until=[DateTime]::UtcNow.AddMilliseconds($TimeoutMs);$last=$null
    do{
        $last=Read-E3ReceiverSnapshot $target $context
        if($last.ok -and $last.latest){return $last}
        Start-Sleep -Milliseconds 400
    }while([DateTime]::UtcNow -lt $until)
    throw $(if($last -and $last.error){[string]$last.error}else{'對話尚未停在最新訊息'})
}

#region Single work tab
# One Edge and one tab serve every bound chat. No chat has to stay open: each read brings
# the tab to that chat (chat list click, else chat link), verifies it and reads the newest rows.
$script:E3ReceiverTab=$null
$script:E3ReceiverHeadless=$false
$script:E3ReceiverReloadMinutes=30
$script:E3ReceiverHold=@{until=[DateTimeOffset]::MinValue;reason=''}
function Get-E3ReceiverHeadless {
    # teams.receiver_headless=true runs the receiver's Edge without a window; default is a visible window.
    try{
        $cfg=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config.json') -Raw -Encoding UTF8|ConvertFrom-Json
        return ($cfg.teams.receiver_headless -eq $true)
    }catch{return $false}
}
function Get-E3ReceiverBrowserArguments {
    # Headless Edge announces "HeadlessEdg". Set the normal product token at launch so it
    # holds for every request; per-connection emulation is lost each time CDP reconnects.
    $edge=@((Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),(Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),(Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe'))|Where-Object{Test-Path -LiteralPath $_}|Select-Object -First 1
    if(-not $edge){throw '找不到 Edge'}
    $major=[Diagnostics.FileVersionInfo]::GetVersionInfo($edge).ProductMajorPart
    if($major -lt 100){throw 'Edge 版本無法辨識，無法以無視窗模式啟動接收端'}
    return '--window-size=1600,1000 --user-agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/'+$major+'.0.0.0 Safari/537.36 Edg/'+$major+'.0.0.0"'
}
function Test-E3ReceiverHeadlessProcess($processes) {
    $main=@($processes|Where-Object{$_.CommandLine -notmatch '(?:^|\s)--type='})
    return [bool]@($main|Where-Object{$_.CommandLine -match '(?:^|\s)--headless(?:=\S+)?(?:\s|$)'}).Count
}
function Test-E3ReceiverLoginUrl([string]$url) {
    $u=$null
    if(-not [Uri]::TryCreate($url,[UriKind]::Absolute,[ref]$u)){return $false}
    return $u.Host -match '(^|\.)login\.(microsoftonline|live|microsoft)\.com$|(^|\.)account\.live\.com$'
}
function Get-E3ReceiverTargets {
    $targets=@(Get-E3CdpBindings)
    if(-not $targets.Count){throw '請先執行 setup_teams_receiver.bat 綁定要接收的對話'}
    if($targets.Count -gt 20){throw '目前最多同時接收 20 個對話'}
    $routes=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $chats=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($target in $targets){
        # The tab recorded at setup is no longer needed; every source shares the work tab.
        $resolved=Resolve-E3CdpTarget ([string]$target.route) -Headless
        if(-not $routes.Add($resolved.route) -or -not $chats.Add(($resolved.binding.accountId+"`n"+$resolved.binding.chatId))){throw '接收綁定有重複名稱或對話，請重新執行 setup_teams_receiver.bat'}
        Write-Output $resolved
    }
}
function Assert-E3ReceiverDestination($target,[int]$context) {
    # A setting can be rebound while native capture releases the shared CDP lock.
    # Verify the route still refers to the frozen originating destination before send.
    $saved=Resolve-E3CdpTarget $target.route
    if($saved.targetId -cne $target.targetId){throw '接收分頁綁定已變更，本次不回覆'}
    $actual=Get-E3SelfBinding $context -AllowGroup
    if(-not $actual.ok){throw '無法確認接收端目前的帳號與對話'}
    foreach($key in @('accountId','chatId','label')){
        if($actual.binding.$key -cne $target.binding.$key -or $saved.binding.$key -cne $target.binding.$key){throw '接收來源或綁定已變更，本次不回覆'}
    }
}
function Get-E3ReceiverTabList($session) {
    return @(Get-E3LocalJson "http://127.0.0.1:$($session.port)/json/list"|ForEach-Object{$_})
}
function Open-E3ReceiverBrowser {
    # Start the receiver's own Edge only when no process uses its profile; otherwise adopt
    # only the debugging endpoint that this profile itself published.
    $root=Get-E3CdpStateRoot
    $profile=[IO.Path]::GetFullPath((Join-Path $root 'profile'))
    if(-not(Test-Path -LiteralPath (Join-Path $profile 'Default'))){throw '尚無接收端 Teams 登入資料，請先執行 setup_teams_receiver.bat'}
    $headless=[bool]$script:E3ReceiverHeadless
    $running=@(Get-E3ProfileEdgeProcesses $profile)
    if($running.Count -and (Test-E3ReceiverHeadlessProcess $running) -ne $headless){
        # The dedicated Edge runs in the other mode (for example the setup window while
        # headless is selected). Close it normally and reopen it in the selected mode.
        $wasHeadless=Test-E3ReceiverHeadlessProcess $running
        Write-Host ("🔄 接收端專用 Edge 目前是{0}模式，設定為{1}模式；正常關閉後重新開啟（登入資料保留）…" -f $(if($wasHeadless){'無視窗'}else{'有視窗'}),$(if($headless){'無視窗'}else{'有視窗'})) -ForegroundColor Cyan
        Close-E3ProfileGracefully $profile $running
        $until=[DateTime]::UtcNow.AddSeconds(8)
        do{if(-not @(Get-E3ProfileEdgeProcesses $profile).Count){break};Start-Sleep -Milliseconds 200}while([DateTime]::UtcNow -lt $until)
        if(@(Get-E3ProfileEdgeProcesses $profile).Count -and $wasHeadless){
            # A leftover background Edge has no window to close by hand; it only ever belongs to this receiver.
            Stop-E3ProfileProcesses $profile $running
            Start-Sleep -Milliseconds 1000
        }
        if(@(Get-E3ProfileEdgeProcesses $profile).Count){throw '接收端專用 Edge 無法自動關閉；請手動關閉那個 Edge 視窗，接收端會自動重新開啟'}
        $running=@()
    }
    if($running.Count){
        try{$ready=Wait-E3DevToolsEndpoint (Join-Path $profile 'DevToolsActivePort') 3000}
        catch{throw '接收端專用 Edge 仍開著但無法連線；請關閉那個 Edge 視窗，接收端會自動重新開啟'}
        $listeners=@(Get-NetTCPConnection -State Listen -LocalPort $ready.port -ErrorAction SilentlyContinue)
        if(-not @($listeners|Where-Object{$_.OwningProcess -in $running.ProcessId}).Count){throw '接收端專用 Edge 的連線埠不屬於該登入資料，未連接'}
        $session=@{port=$ready.port;browserUrl=[string]$ready.version.webSocketDebuggerUrl}
        Save-E3CdpState (Join-Path $root 'session.json') $session
        Write-Host '🔄 已連上仍在執行的接收端專用 Edge。' -ForegroundColor Cyan
        return @{session=$session;blankTarget=$null}
    }
    Write-Host ("🔄 正在開啟接收端專用 Edge（{0}，沿用原登入資料）…" -f $(if($headless){'無視窗'}else{'有視窗'})) -ForegroundColor Cyan
    $opened=if($headless){Start-E3TestBrowser $profile -Headless -ExtraArguments (Get-E3ReceiverBrowserArguments)}else{Start-E3TestBrowser $profile}
    $session=@{port=$opened.port;browserUrl=$opened.browserUrl}
    Save-E3CdpState (Join-Path $root 'session.json') $session
    if($opened.process){$opened.process.Dispose()}
    return @{session=$session;blankTarget=$opened.targetId}
}
function Set-E3ReceiverBindingTab($sources,[string]$tabId) {
    # Caller owns E3TeamsCdpShared, the lock setup uses to write bindings. Replies go through
    # the shared send path, which finds the tab through bindings.json; point every source at
    # the one work tab.
    $path=Join-Path (Get-E3CdpStateRoot) 'bindings.json'
    $all=@(Get-E3CdpBindings);$changed=$false
    foreach($source in $sources){
        $t=$source.target
        $hits=@($all|Where-Object{$_.route -ceq $t.route -and $_.binding.accountId -ceq $t.binding.accountId -and $_.binding.chatId -ceq $t.binding.chatId -and $_.binding.label -ceq $t.binding.label})
        if($hits.Count -ne 1){throw 'E3_RECEIVER_RELOAD：接收綁定已更新，重新載入'}
        if([string]$hits[0].targetId -cne $tabId){$hits[0]|Add-Member -NotePropertyName targetId -NotePropertyValue $tabId -Force;$changed=$true}
        $t|Add-Member -NotePropertyName targetId -NotePropertyValue $tabId -Force
    }
    if($changed){Save-E3CdpState $path @($all)}
    $script:E3ReceiverBindingsStamp=Get-E3ReceiverBindingsStamp
}
function Get-E3ReceiverBindingsStamp {
    try{return [IO.File]::GetLastWriteTimeUtc((Join-Path (Get-E3CdpStateRoot) 'bindings.json')).Ticks}catch{return 0}
}
function Initialize-E3ReceiverTab($sources) {
    # Caller owns E3TeamsCdpShared. Makes sure the dedicated Edge and its one work tab exist
    # and that this process is connected to that tab.
    $tab=$script:E3ReceiverTab;$session=$null;$tabs=@();$blank=$null
    if($tab){
        try{$session=Get-E3CdpSession;$tabs=@(Get-E3ReceiverTabList $session)}catch{$session=$null}
        if($session -and [string]$session.browserUrl -ceq [string]$tab.session.browserUrl -and @($tabs|Where-Object{$_.id -ceq $tab.tabId -and $_.type -eq 'page'}).Count){
            if(-not $script:CdpSocket -or $script:CdpSocket.State -ne [Net.WebSockets.WebSocketState]::Open -or $script:CdpEndpoint -cne $tab.endpoint){
                Connect-E3Cdp $tab.endpoint
                Invoke-E3Cdp 'Page.enable'|Out-Null
                Enable-E3CdpBackgroundFocus
            }
            return
        }
        if($session -and [string]$session.browserUrl -cne [string]$tab.session.browserUrl){$session=$null}
        Write-Host $(if($session){'🔄 接收端工作分頁已關閉，重新建立…'}else{'🔄 接收端專用 Edge 已結束，重新開啟…'}) -ForegroundColor Cyan
    }
    $script:E3ReceiverTab=$null
    if(-not $session){
        $opened=Open-E3ReceiverBrowser
        $session=$opened.session;$blank=$opened.blankTarget
        $tabs=@(Get-E3ReceiverTabList $session)
    }
    $pages=@($tabs|Where-Object{$_.type -eq 'page'})
    $recorded=@($sources|ForEach-Object{[string]$_.target.targetId}|Where-Object{$_}|Select-Object -Unique)
    $tabId=[string]$blank
    if(-not $tabId){
        # Reuse a tab this tool recorded for a binding, so an adopted browser keeps one Teams tab.
        foreach($id in $recorded){if(@($pages|Where-Object{$_.id -ceq $id}).Count){$tabId=$id;break}}
    }
    if(-not $tabId){
        Connect-E3Cdp $session.browserUrl
        $tabId=[string](Invoke-E3Cdp 'Target.createTarget' @{url='about:blank'}).targetId
    }
    # The earlier design kept one tab per chat. Close only tabs recorded in this tool's own bindings.
    $closed=0
    foreach($id in $recorded){
        if($id -cne $tabId -and @($pages|Where-Object{$_.id -ceq $id}).Count){
            try{Connect-E3Cdp $session.browserUrl;Invoke-E3Cdp 'Target.closeTarget' @{targetId=$id}|Out-Null;$closed++}catch{}
        }
    }
    if($closed){Write-Host "🧹 已關閉 $closed 個舊版的每對話分頁；現在只用一個工作分頁。" -ForegroundColor DarkGray}
    $entry=@(Get-E3ReceiverTabList $session)|Where-Object{$_.id -ceq $tabId -and $_.type -eq 'page'}|Select-Object -First 1
    if(-not $entry){throw '接收端工作分頁無法建立'}
    Set-E3ReceiverBindingTab $sources $tabId
    Connect-E3Cdp $entry.webSocketDebuggerUrl
    Invoke-E3Cdp 'Page.enable'|Out-Null
    Enable-E3CdpBackgroundFocus
    $script:E3ReceiverTab=@{session=$session;tabId=$tabId;endpoint=[string]$entry.webSocketDebuggerUrl;context=0;ready=$false;loadedAt=$null;chatId=$null;loginAt=$null;windowAt=[DateTimeOffset]::MinValue;windowNoteAt=[DateTimeOffset]::MinValue}
}
function Restore-E3ReceiverWindow {
    # A minimized window stops drawing, so new messages never reach the page. Put the
    # receiver's own window back to normal size; being covered by other windows is fine.
    $tab=$script:E3ReceiverTab
    if(-not $tab -or $script:E3ReceiverHeadless){return}
    $now=[DateTimeOffset]::UtcNow
    if($now -lt $tab.windowAt){return}
    $tab.windowAt=$now.AddSeconds(15)
    try{
        $window=Invoke-E3Cdp 'Browser.getWindowForTarget' @{targetId=$tab.tabId} -TimeoutMs 3000
        if([string]$window.bounds.windowState -eq 'minimized'){
            Invoke-E3Cdp 'Browser.setWindowBounds' @{windowId=[int]$window.windowId;bounds=@{windowState='normal'}} -TimeoutMs 3000|Out-Null
            if($now -ge $tab.windowNoteAt){
                $tab.windowNoteAt=$now.AddMinutes(10)
                Write-Host '🪟 接收端專用 Edge 被最小化會停止更新畫面，已還原視窗。可以讓其他視窗蓋住它，但請不要最小化；不想看到視窗可在設定頁改用無視窗模式。' -ForegroundColor Yellow
            }
        }
    }catch{}
}
function Open-E3ReceiverChat($source,[switch]$Reload) {
    # Caller owns E3TeamsCdpShared and has called Initialize-E3ReceiverTab. Returns the
    # execution context of the work tab once it shows this source's chat.
    $tab=$script:E3ReceiverTab;$target=$source.target
    if($tab.ready -and -not $Reload){
        try{
            $script=Get-E3ReceiverScript 'receiver-switch.js' $target
            $until=[DateTime]::UtcNow.AddSeconds(10)
            do{
                $state=Invoke-E3Js $script $tab.context
                if($state.ready){$tab.chatId=[string]$target.binding.chatId;return [int]$tab.context}
                if($state.fatal){throw ('E3_RECEIVER_SOURCE：'+[string]$state.error)}
                if(-not $state.ok){break}   # reopen through the chat link below
                Start-Sleep -Milliseconds 250
            }while([DateTime]::UtcNow -lt $until)
        }catch{
            if($_.Exception.Message -match 'E3_RECEIVER_SOURCE'){throw}
            # The page was reloaded or its script context is gone: open the chat link again.
        }
    }
    $entry=@(Get-E3ReceiverTabList $tab.session)|Where-Object{$_.id -ceq $tab.tabId -and $_.type -eq 'page'}|Select-Object -First 1
    if(-not $entry){throw 'CDP_CLOSED：接收端工作分頁已關閉'}
    $now=[DateTimeOffset]::UtcNow
    if(Test-E3ReceiverLoginUrl ([string]$entry.url)){
        # A visible sign-in page is left alone for 15 minutes so the user can finish signing in.
        if(-not $script:E3ReceiverHeadless -and $tab.loginAt -and ($now-$tab.loginAt).TotalMinutes -lt 15){
            throw 'E3_RECEIVER_LOGIN：Teams 需要重新登入；請在接收端專用 Edge 視窗完成登入，完成後會自動繼續'
        }
        $tab.loginAt=$now
    }else{$tab.loginAt=$null}
    # A fresh connection registers the page bootstrap exactly once for this load.
    Connect-E3Cdp $entry.webSocketDebuggerUrl
    Invoke-E3Cdp 'Page.enable'|Out-Null
    Invoke-E3Cdp 'Page.addScriptToEvaluateOnNewDocument' @{source=(Get-E3CdpRuntimeSource 'vendor\image-frame-bootstrap.js')}|Out-Null
    Enable-E3CdpBackgroundFocus
    $tab.ready=$false;$tab.chatId=$null;$tab.context=0
    try{
        Move-E3HeadlessPage (Get-E3CdpChatUrl $target)
        Wait-E3HeadlessChat $target 75
    }catch{
        if($_.Exception.Message -match '登入已過期|互動驗證'){
            if(-not $tab.loginAt){$tab.loginAt=[DateTimeOffset]::UtcNow}
            throw ('E3_RECEIVER_LOGIN：Teams 需要重新登入；'+$(if($script:E3ReceiverHeadless){'無視窗模式無法顯示登入畫面，請停止接收端後執行 setup_teams_receiver.bat 重新登入'}else{'請在接收端專用 Edge 視窗完成登入，完成後會自動繼續'}))
        }
        throw
    }
    $context=Connect-E3CdpTarget $tab.session $target
    $tab.endpoint=$script:CdpEndpoint;$tab.context=[int]$context;$tab.ready=$true
    $tab.loadedAt=[DateTimeOffset]::UtcNow;$tab.chatId=[string]$target.binding.chatId;$tab.loginAt=$null
    return [int]$context
}
function Enter-E3ReceiverChat($sources,$source) {
    # Before a reply: bring the work tab back to the originating chat and repeat the strict
    # account / chat proof used before every send. A leftover draft is not checked here:
    # Send-GroupToTeamsCdp stops any earlier runtime work and clears the draft of this verified
    # tab before pasting. Requiring an empty box here would make one interrupted paste block
    # every later reply while reading still looks healthy.
    Initialize-E3ReceiverTab $sources
    $null=Open-E3ReceiverChat $source
    $context=Connect-E3CdpTarget $script:E3ReceiverTab.session $source.target
    $script:E3ReceiverTab.endpoint=$script:CdpEndpoint;$script:E3ReceiverTab.context=[int]$context
    Assert-E3ReceiverDestination $source.target $context
    return [int]$context
}
function Invoke-E3ReceiverVisit($sources,$source) {
    # One read of one bound chat: returns a new command candidate or $null, throws on failure.
    try{Initialize-E3ReceiverTab $sources}
    catch{
        if($_.Exception.Message -match 'E3_RECEIVER_RELOAD'){throw}
        throw ('E3_RECEIVER_BROWSER：'+$_.Exception.Message)
    }
    Restore-E3ReceiverWindow
    $tab=$script:E3ReceiverTab
    # A long-lived Teams page slowly degrades; reload it on a schedule while idle.
    $reload=[bool]$source.reload -or ($tab.ready -and $tab.loadedAt -and ([DateTimeOffset]::UtcNow-$tab.loadedAt).TotalMinutes -ge $script:E3ReceiverReloadMinutes)
    $context=Open-E3ReceiverChat $source -Reload:$reload
    $first=Read-E3ReceiverSettled $source.target $context
    Start-Sleep -Milliseconds 500
    $second=Read-E3ReceiverSettled $source.target $context 4000
    return Select-E3ReceiverCommand $second $source.target.binding $source.cutoff $first $source.seen
}
function Get-E3ReceiverNextSource($sources,[DateTimeOffset]$now) {
    # Round robin: among the sources that are due, the one read longest ago. While a
    # sign-in or browser problem is on hold nothing is read, so the hold is not extended.
    if($now -lt $script:E3ReceiverHold.until){return $null}
    return @($sources|Where-Object{$now -ge $_.retryAt}|Sort-Object {$_.visitedAt})|Select-Object -First 1
}
function Set-E3ReceiverSourceOk($source,[DateTimeOffset]$now) {
    $source.visitedAt=$now;$source.lastOkUtc=$now.ToString('O');$source.error=$null
    $source.failures=0;$source.reload=$false;$source.retryAt=$now;$source.warned=$null
}
function Set-E3ReceiverSourceFailure($source,[string]$message,[DateTimeOffset]$now) {
    # A failing chat never stops the others: it backs off on its own (10 s doubling to 5 min)
    # and its next attempt reopens the chat link instead of reusing the current page state.
    $source.visitedAt=$now;$source.active=$false;$source.failures=[int]$source.failures+1
    $clean=($message -replace '^E3_RECEIVER_(SOURCE|LOGIN|BROWSER)：','')
    $source.error=$clean
    $seconds=[Math]::Min(300,10*[Math]::Pow(2,[Math]::Min(5,$source.failures-1)))
    $source.retryAt=$now.AddSeconds($seconds)
    $source.reload=$true
    $scope='source'
    if($message -match 'E3_RECEIVER_LOGIN'){
        # One sign-in serves every chat: pause all reads instead of probing each chat in turn.
        $scope='login';$seconds=60;$script:E3ReceiverHold=@{until=$now.AddSeconds(60);reason=$clean}
        $source.retryAt=$now.AddSeconds(60)
    }elseif($message -match 'E3_RECEIVER_BROWSER'){
        # The dedicated Edge or its tab could not be prepared: try again at most every 20 seconds.
        $scope='browser';$seconds=20;$script:E3ReceiverTab=$null;$script:E3ReceiverHold=@{until=$now.AddSeconds(20);reason=$clean}
        $source.retryAt=$now.AddSeconds(20)
    }
    $changed=$source.warned -cne $clean
    $source.warned=$clean
    return @{scope=$scope;seconds=[int]$seconds;announce=$changed -or $source.failures -eq 1 -or ($source.failures % 6) -eq 0}
}
#endregion

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
        # Take the shared lock before claiming. While a schedule or another reply is sending,
        # the message stays queued and is tried again on the next pass (every 5 seconds);
        # it is never marked failed without an attempt.
        $locked=$false
        try{$locked=$shared.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
        if(-not $locked){return}
        $claimed=$base+'.sending'
        try{[IO.File]::Move($file.FullName,$claimed)}catch{$shared.ReleaseMutex();$locked=$false;continue}
        try{
            Register-E3WorkOwner 'cdp' ('轉送日管監看通知：'+$source.target.route)
            $null=Enter-E3ReceiverChat $sources $source
            Send-GroupToTeamsCdp $source.target.route @() (Format-E3ReceiverText $text) @{cdp_headless=$false;auto_press_enter=$true} $false
            try{[IO.File]::Move($claimed,$base+'.sent')}catch{}
            Write-Host "✅ 已轉送日管監看通知：$($source.target.route)" -ForegroundColor Green
        }catch{
            try{[IO.File]::Move($claimed,$base+'.failed')}catch{}
            Write-Warning ('日管監看通知未送出（不重送）：'+$_.Exception.Message)
        }finally{if($locked){Unregister-E3WorkOwner 'cdp';$shared.ReleaseMutex()}}
    }
}
function Send-E3ReceiverAcknowledgement($sources,$source,$request,[string]$claim,[string]$command,$progress) {
    $ackMutex=[Threading.Mutex]::new($false,'Local\E3TeamsCdpShared');$ackLocked=$false
    try{
        $ackLocked=Enter-E3WorkLock $ackMutex 'cdp' ('回覆 Teams 指令：'+$source.target.route)
        $target=$source.target
        $null=Enter-E3ReceiverChat $sources $source
        $progress.phase='acknowledgement'
        Save-E3CdpState $claim @{version=3;state='ack_sending';route=$target.route;command=$command;at=[DateTimeOffset]::UtcNow.ToString('O')}
        Send-GroupToTeamsCdp $target.route @() (Format-E3ReceiverText (Get-E3ReceiverAcknowledgement $request)) @{cdp_headless=$false;auto_press_enter=$true} $false
        $progress.acknowledged=$true;$progress.phase='capture'
        Save-E3CdpState $claim @{version=3;state='acknowledged';route=$target.route;command=$command;at=[DateTimeOffset]::UtcNow.ToString('O')}
    }finally{if($ackLocked){Unregister-E3WorkOwner 'cdp';$ackMutex.ReleaseMutex()};$ackMutex.Dispose()}
}
function Get-E3ReceiverStopPath {return (Join-Path $script:E3CdpLogRoot 'stop.request')}
function Invoke-E3ReceiverTest([int]$timeout=600,[switch]$Continuous) {
    $listener=[Threading.Mutex]::new($false,'Local\E3TeamsCommandReceiver')
    $shared=[Threading.Mutex]::new($false,'Local\E3TeamsCdpShared')
    $owned=$false;$locked=$false;$sources=@();$exit='interrupted'
    try{
        try{$owned=$listener.WaitOne(0)}catch [Threading.AbandonedMutexException]{$owned=$true}
        if(-not $owned){throw 'E3_RECEIVER_FATAL：指令接收已開啟，請勿重複啟動'}
        $script:E3ReceiverContinuous=[bool]$Continuous
        $script:E3ReceiverStopReason='';$script:E3ReceiverIntentional=$false;$script:E3ReceiverFatal=$false
        $script:E3ReceiverCleanupAt=[DateTimeOffset]::MinValue
        $script:E3ReceiverOutboxAt=[DateTimeOffset]::MinValue
        $script:E3ReceiverTab=$null
        $script:E3ReceiverHold=@{until=[DateTimeOffset]::MinValue;reason=''}
        if(-not $script:E3ReceiverStartedUtc){$script:E3ReceiverStartedUtc=[DateTimeOffset]::UtcNow.ToString('O')}
        # Commands are accepted from the first start of this process; an internal restart keeps that line.
        if(-not $script:E3ReceiverCutoff){$script:E3ReceiverCutoff=[DateTimeOffset]::UtcNow}
        $script:E3ReceiverHeadless=Get-E3ReceiverHeadless
        # Idle sleep would stop remote control. Lock / screen-off stay allowed; the
        # request ends with this process and does not change the power plan.
        Initialize-E3DesktopProbe
        $script:E3ReceiverSleepGuard=[E3CdpDesktop]::SetThreadExecutionState([uint32]2147483649) -ne 0
        if($script:E3ReceiverSleepGuard){Write-Host '接收期間要求系統保持清醒；螢幕可關閉或鎖定，不變更電源計畫。' -ForegroundColor Gray}
        else{Write-Warning '無法要求系統保持清醒；請將 Windows 電源設定的睡眠改為「永不」。'}
        try{$targets=@(Get-E3ReceiverTargets)}catch{throw ('E3_RECEIVER_FATAL：'+$_.Exception.Message)}
        foreach($target in $targets){
            $sources+=@{target=$target;active=$false;cutoff=$script:E3ReceiverCutoff;retryAt=[DateTimeOffset]::MinValue;visitedAt=[DateTimeOffset]::MinValue
                seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);lastOkUtc=$null;error=$null;failures=0;reload=$false;warned=$null}
        }
        $script:E3ReceiverBindingsStamp=Get-E3ReceiverBindingsStamp
        try{if(Test-Path -LiteralPath (Get-E3ReceiverStopPath)){Remove-Item -LiteralPath (Get-E3ReceiverStopPath) -Force}}catch{}
        Save-E3ReceiverStatus 'connecting' '正在開啟接收端工作分頁；暫時失敗會自動重試'
        Save-E3ReceiverHeartbeat $sources 'listening' -Force
        Write-Host ("接收 {0} 個對話，使用一個{1}工作分頁輪流讀取；不需要讓任何對話保持開啟。" -f $sources.Count,$(if($script:E3ReceiverHeadless){'無視窗'}else{'有視窗'}))
        Write-Host '可輸入 @日管 狀態、@日管 截圖清單，或 @日管 幫我截圖 名稱。'
        Write-Host $(if($Continuous){'持續接收。專用 Edge、分頁或登入出問題時會自動重試；要停止請按 Ctrl+C 或執行 stop_teams_receiver.bat。'}else{'回覆一個指令後結束；Ctrl+C 停止。'})
        $deadline=[DateTimeOffset]::UtcNow.AddSeconds($timeout);$checkAt=[DateTimeOffset]::MinValue
        while($Continuous -or [DateTimeOffset]::UtcNow -lt $deadline){
            Start-Sleep -Milliseconds $(if($sources.Count -gt 1){300}else{1000})
            $now=[DateTimeOffset]::UtcNow
            Save-E3ReceiverHeartbeat $sources 'listening'
            if($now -ge $checkAt){
                $checkAt=$now.AddSeconds(3)
                if(Test-Path -LiteralPath (Get-E3ReceiverStopPath)){
                    $script:E3ReceiverIntentional=$true;$script:E3ReceiverStopReason='已由 stop_teams_receiver.bat 要求停止'
                    try{Remove-Item -LiteralPath (Get-E3ReceiverStopPath) -Force}catch{}
                    Write-Host '⏹ 收到停止要求，接收端結束。' -ForegroundColor Cyan
                    $exit='stopped';break
                }
                if((Get-E3ReceiverBindingsStamp) -ne $script:E3ReceiverBindingsStamp){throw 'E3_RECEIVER_RELOAD：接收綁定已更新，重新載入'}
            }
            if($now -ge $script:E3ReceiverCleanupAt){
                $script:E3ReceiverCleanupAt=$now.AddHours(24)
                try{Clear-E3ReceiverOldLogs}catch{Write-Warning ('舊接收紀錄清理失敗：'+$_.Exception.Message)}
            }
            $source=Get-E3ReceiverNextSource $sources $now
            if($source){
                try{$locked=$shared.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
                if($locked){
                    $claim=$null;$replied=$false;$target=$source.target;$progress=@{phase='received';acknowledged=$false};$command=''
                    try{
                        # Opening or reloading a chat can hold the lock for a while; publish the owner then.
                        if(-not $script:E3ReceiverTab -or -not $script:E3ReceiverTab.ready -or $source.reload){Register-E3WorkOwner 'cdp' ('接收 Teams 指令（開啟對話）：'+$target.route)}
                        $candidate=Invoke-E3ReceiverVisit $sources $source
                        Set-E3ReceiverSourceOk $source ([DateTimeOffset]::UtcNow)
                        if(-not $source.active){
                            $source.active=$true
                            Write-Host "✅ 已接收：$($target.route)" -ForegroundColor Green
                            Save-E3ReceiverStatus 'listening' ("已接收："+$target.route)
                            Save-E3ReceiverHeartbeat $sources 'listening' -Force
                        }
                        if($candidate){
                            [void]$source.seen.Add($candidate.key)
                            $command=[string]$candidate.message.text
                            $claim=New-E3ReceiverClaim $candidate.key $command
                        }
                        if($claim){
                            Unregister-E3WorkOwner 'cdp';$shared.ReleaseMutex();$locked=$false
                            Save-E3ReceiverStatus 'processing' ("正在處理："+$target.route)
                            # Capture (max 330 s) plus two lock waits and sends stay within 20 minutes.
                            Save-E3ReceiverHeartbeat $sources 'processing' 1200 -Force
                            $response=Get-E3ReceiverResponse $candidate.message $candidate.key -BeforeCapture {
                                param($request)
                                Send-E3ReceiverAcknowledgement $sources $source $request $claim $command $progress
                            }
                            if($response){
                                $locked=Enter-E3WorkLock $shared 'cdp' ('回覆 Teams 指令：'+$target.route)
                                $null=Enter-E3ReceiverChat $sources $source
                                $progress.phase='result'
                                Send-GroupToTeamsCdp $target.route @($response.images) (Format-E3ReceiverText $response.text -ImageReply:($response.images.Count -gt 0)) @{cdp_headless=$false;auto_press_enter=$true} $false
                                $replied=$true
                                Save-E3CdpState $claim @{version=3;state='replied';acknowledged=$progress.acknowledged;route=$target.route;command=$command;at=[DateTimeOffset]::UtcNow.ToString('O')}
                                Save-E3ReceiverStatus $(if($Continuous){'listening'}else{'replied'}) ("已回覆："+$target.route)
                                Write-Host "✅ 已回覆：$($target.route)" -ForegroundColor Green
                                Save-E3ReceiverHeartbeat $sources 'listening' -Force
                                if(-not $Continuous){$exit='done';return}
                            }
                        }
                    }catch{
                        $reason=$_.Exception.Message
                        if($reason -match 'E3_RECEIVER_RELOAD'){throw}
                        $failure=Set-E3ReceiverSourceFailure $source $reason ([DateTimeOffset]::UtcNow)
                        # Claims remain durable even if updating their outcome fails. Never retry
                        # this command; recovery only reopens the chat and reads for new commands.
                        if($claim -and -not $replied){
                            try{Save-E3CdpState $claim @{version=3;state='not_retried';phase=$progress.phase;acknowledged=$progress.acknowledged;route=$target.route;command=$command;at=[DateTimeOffset]::UtcNow.ToString('O')}}
                            catch{Write-Warning ('指令結果暫時無法更新；保留原紀錄，不重送：'+$_.Exception.Message)}
                        }
                        if($failure.announce -or $claim){
                            Write-Host "⚠ $($target.route)：$($source.error)；$($failure.seconds) 秒後自動重試，其他對話不受影響$(if($claim){'；本次指令不重送'})。" -ForegroundColor Yellow
                            Save-E3ReceiverStatus 'recovering' ("等待重試："+$target.route+"；"+$source.error)
                            Save-E3ReceiverHeartbeat $sources 'listening' -Force
                        }
                    }finally{if($locked){Unregister-E3WorkOwner 'cdp';$shared.ReleaseMutex();$locked=$false}}
                }
            }
            if([DateTimeOffset]::UtcNow -ge $script:E3ReceiverOutboxAt){
                $script:E3ReceiverOutboxAt=[DateTimeOffset]::UtcNow.AddSeconds(5)
                try{Send-E3ReceiverOutbox $sources $shared}catch{Write-Warning ('日管監看通知處理失敗：'+$_.Exception.Message)}
            }
        }
        if($exit -eq 'interrupted'){$exit='timeout';Save-E3ReceiverStatus 'timeout' '等待指令逾時，接收已結束'}
        elseif($exit -eq 'stopped'){Save-E3ReceiverStatus 'stopped' $script:E3ReceiverStopReason}
    }catch{
        # Continuous mode restarts listening after an unexpected error; only setup problems end it.
        $exit=if($Continuous -and $_.Exception.Message -notmatch 'E3_RECEIVER_FATAL'){'restart'}else{'error'}
        $script:E3ReceiverFatal=$_.Exception.Message -match 'E3_RECEIVER_FATAL'
        if($owned){$script:E3ReceiverStopReason=($_.Exception.Message -replace '^E3_RECEIVER_(FATAL|RELOAD)：','');Save-E3ReceiverStatus $(if($exit -eq 'restart'){'recovering'}else{'stopped'}) $script:E3ReceiverStopReason}
        throw
    }
    finally{
        # Ctrl+C runs only this block: no catch ran and the loop did not end by itself.
        if($exit -eq 'interrupted'){$script:E3ReceiverIntentional=$true;$script:E3ReceiverStopReason='已按 Ctrl+C 停止'}
        if($script:E3ReceiverSleepGuard){[void][E3CdpDesktop]::SetThreadExecutionState([uint32]2147483648);$script:E3ReceiverSleepGuard=$false}
        if($owned){Save-E3ReceiverHeartbeat $sources $(if($exit -eq 'restart'){'restarting'}else{'stopped'}) -Force}
        Disable-E3CdpBackgroundFocus
        if($script:CdpSocket){$script:CdpSocket.Dispose();$script:CdpSocket=$null}
        if($locked){Unregister-E3WorkOwner 'cdp';$shared.ReleaseMutex()};$shared.Dispose()
        if($owned){$listener.ReleaseMutex()};$listener.Dispose()
    }
}
function Start-E3ReceiverSupervised([int]$timeout,[switch]$Continuous) {
    # Continuous mode never gives up on an unexpected error: it restarts listening inside
    # this process. Only setup problems (no binding, duplicate start) and a requested stop end it.
    while($true){
        try{Invoke-E3ReceiverTest $timeout -Continuous:$Continuous;return}
        catch{
            $reason=$_.Exception.Message
            if(-not $Continuous -or $reason -match 'E3_RECEIVER_FATAL'){throw ($reason -replace '^E3_RECEIVER_FATAL：','')}
            $reload=$reason -match 'E3_RECEIVER_RELOAD'
            Write-Host ("🔄 {0}；{1} 秒後重新開始接收，不重送任何指令。" -f ($reason -replace '^E3_RECEIVER_RELOAD：',''),$(if($reload){2}else{15})) -ForegroundColor Yellow
            Start-Sleep -Seconds $(if($reload){2}else{15})
        }
    }
}
if(-not $LibraryOnly){
    try{
        if($Stop){
            [IO.Directory]::CreateDirectory($script:E3CdpLogRoot)|Out-Null
            [IO.File]::WriteAllText((Get-E3ReceiverStopPath),[DateTimeOffset]::UtcNow.ToString('O'),[Text.UTF8Encoding]::new($false))
            Write-Host '已要求接收端停止；接收視窗會在幾秒內結束，監看任務也不會自動重新啟動它。要再接收請執行 start_teams_receiver.bat。'
        }elseif($Setup){
            $busy=$null
            if([Threading.Mutex]::TryOpenExisting('Local\E3TeamsCommandReceiver',[ref]$busy)){$busy.Dispose();throw '接收端正在執行。請先執行 stop_teams_receiver.bat（或在接收視窗按 Ctrl+C）停止，再進行綁定'}
            Write-Host '接收端使用獨立登入視窗。綁定完成後可以關閉分頁；接收時只用一個工作分頁輪流讀取各對話，回覆會回到下指令的對話。'
            Set-E3CdpBinding @{teams=@{cdp_headless=$false};pages=@();schedules=@()} -SelectInBrowser
        }elseif($Listen){Start-E3ReceiverSupervised $TimeoutSeconds -Continuous:$Continuous}
        else{throw '請使用 -Setup 設定接收來源、-Listen 接收 @日管 指令，或 -Stop 停止接收'}
    }catch{Write-Host ('❌ '+$_.Exception.Message) -ForegroundColor Red;exit 1}
}
