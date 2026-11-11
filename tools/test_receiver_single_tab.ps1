# Isolated tests of the single-work-tab receiver. A temporary headless Edge shows a fixture
# page for the chat-switch script; the browser, navigation and Teams identity checks are
# replaced by stand-ins for the PowerShell logic. No Teams navigation, sign-in, send or task change.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path $env:TEMP ('E3ReceiverSingleTab_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
. (Join-Path $root 'teams_receiver.ps1') -LibraryOnly
. (Join-Path $root 'teams_receiver_watchdog.ps1')
$script:E3CdpLogRoot=Join-Path $fixture 'logs'
$script:E3WorkControlRoot=Join-Path $fixture 'work'
$script:E3ReceiverProfileRoot=Join-Path $fixture 'state'
[void][IO.Directory]::CreateDirectory($script:E3ReceiverProfileRoot)
$passed=0
function Check([bool]$ok,[string]$name){if(-not $ok){throw "FAIL $name"};$script:passed++;Write-Host "PASS $name"}
function New-Target([string]$route,[string]$chat,[string]$tab='OLD'){return [pscustomobject]@{route=$route;targetId=$tab;binding=[pscustomobject]@{accountId='fixture';chatId=$chat;label=$route}}}
function New-Source($target){return @{target=$target;active=$false;cutoff=[DateTimeOffset]::UtcNow;retryAt=[DateTimeOffset]::MinValue;visitedAt=[DateTimeOffset]::MinValue;seen=[Collections.Generic.HashSet[string]]::new();lastOkUtc=$null;error=$null;failures=0;reload=$false;warned=$null}}

# ---- A. Chat switch script in a real page; headless launch switches ----
$browser=$null
try{
    $browser=Start-E3TestBrowser (Join-Path $fixture 'profile') -Headless -ExtraArguments (Get-E3ReceiverBrowserArguments)
    $agent=Invoke-E3Js '({ua:navigator.userAgent,width:window.innerWidth})'
    Check ($agent.ua -notmatch 'Headless' -and $agent.ua -match 'Edg/\d+') 'headless receiver Edge reports the normal product token from launch'
    Check ([int]$agent.width -ge 1200) 'headless receiver Edge starts with a desktop-sized window'
    $a=New-Target 'Chat A' '19:a';$b=New-Target 'Chat B' '19:b';$twin=New-Target 'Twin' '19:twin';$missing=New-Target 'Not listed' '19:missing';$stuck=New-Target 'Stuck' '19:stuck'
    $raw=Get-E3ReceiverScript 'receiver-switch.js' $a
    $guard="['teams.cloud.microsoft', 'teams.microsoft.com'].includes(location.hostname)"
    Check (([regex]::Matches($raw,[regex]::Escape($guard))).Count -eq 1) 'switch script has one Teams host guard'
    $outside=Invoke-E3Js $raw
    Check (-not $outside.ok -and $outside.reopen) 'switch script refuses to act on a page that is not Teams'
    # The fixture page is about:blank; only the host guard is replaced for the remaining cases.
    function Switch-Fixture($target){return Invoke-E3Js ((Get-E3ReceiverScript 'receiver-switch.js' $target).Replace($guard,'true'))}
    $page=@'
globalThis.resetChats=()=>{
document.body.innerHTML='<div role="tree" id="list"></div><div id="pane"><div id="header"></div><div contenteditable="true" id="editor">keep draft</div><button id="send">send</button></div>';
globalThis.current={chatId:'19:a',label:'Chat A'};globalThis.sendCount=0;globalThis.clicks=0;
document.getElementById('send').onclick=()=>sendCount++;
const add=(label,chatId,works=true,preview='preview line',real=label.trim())=>{const item=document.createElement('div');item.setAttribute('role','treeitem');item.style.height='30px';item.innerText=label+'\n'+preview;
  item.onclick=()=>{clicks++;if(works)current={chatId,label:real};};document.getElementById('list').append(item);};
add('Chat A','19:a');add(' Chat'+String.fromCharCode(0x200B)+'  B ','19:b',true,'@日管 狀態','Chat B');add('Twin','19:twin');add('Twin','19:other');add('Stuck','19:stuck',false);
globalThis.BridgeAdapter={
  inspect:(doc,href,expected)=>current.chatId===expected.chatId?{ok:true,binding:{...expected,label:current.label}}:{ok:false,error:'different chat'},
  sameBinding:(x,y)=>!!x&&!!y&&x.accountId===y.accountId&&x.chatId===y.chatId
};
delete globalThis.__E3ReceiverSwitch;return true;};
resetChats();
'@
    Invoke-E3Js $page|Out-Null
    $r=Switch-Fixture $a
    Check ($r.ok -and $r.ready -and (Invoke-E3Js 'clicks===0')) 'chat already shown: ready without any click'
    $r=Switch-Fixture $b
    Check ($r.ok -and -not $r.ready -and $r.stage -eq 'clicked') 'other chat: clicks the uniquely named list item (first line, extra spaces ignored)'
    $r=Switch-Fixture $b
    Check ($r.ok -and $r.ready -and (Invoke-E3Js "clicks===1&&current.chatId==='19:b'")) 'after the click the requested chat is verified by its ID'
    $r=Switch-Fixture $twin
    Check (-not $r.ok -and $r.reopen -and (Invoke-E3Js 'clicks===1')) 'two chats with the same name: no click, reopen by chat link'
    $r=Switch-Fixture $missing
    Check (-not $r.ok -and $r.reopen -and (Invoke-E3Js 'clicks===1')) 'chat not in the visible list: no click, reopen by chat link'
    $r=Switch-Fixture $stuck
    Check ($r.ok -and $r.stage -eq 'clicked') 'list item that does not switch: clicked once'
    $r=Switch-Fixture $stuck
    Check ($r.ok -and $r.stage -eq 'waiting' -and (Invoke-E3Js 'clicks===2')) 'while waiting the item is not clicked again'
    Invoke-E3Js '__E3ReceiverSwitch.at-=7000;true'|Out-Null
    $r=Switch-Fixture $stuck
    Check (-not $r.ok -and $r.reopen) 'chat still not shown after 6 seconds: reopen by chat link'
    Invoke-E3Js "current={chatId:'19:a',label:'Renamed group'};true"|Out-Null
    $r=Switch-Fixture $a
    Check (-not $r.ok -and $r.fatal) 'chat renamed since binding: stops for this source and asks to bind again'
    Invoke-E3Js "resetChats();const p=document.createElement('input');p.type='password';document.body.append(p);true"|Out-Null
    $r=Switch-Fixture $b
    Check (-not $r.ok -and $r.login -and (Invoke-E3Js 'clicks===0')) 'sign-in form on the page: reports login, clicks nothing'
    Check (Invoke-E3Js "sendCount===0&&document.getElementById('editor').textContent==='keep draft'") 'switching never touches the send button or the draft'
}finally{if($browser){Close-E3TestBrowser $browser}}

# ---- B. Reading order, back-off and recovery (no browser) ----
$t0=[DateTimeOffset]::new(2026,11,12,1,0,0,[TimeSpan]::Zero)
$script:E3ReceiverHold=@{until=[DateTimeOffset]::MinValue;reason=''}
$sources=@((New-Source (New-Target 'A' '19:a')),(New-Source (New-Target 'B' '19:b')),(New-Source (New-Target 'C' '19:c')))
$order=@();$attemptsB=0
for($i=0;$i -lt 60;$i++){
    $now=$t0.AddSeconds($i)
    $next=Get-E3ReceiverNextSource $sources $now
    if(-not $next){continue}
    $order+=$next.target.route
    if($next.target.route -eq 'B'){$attemptsB++;$null=Set-E3ReceiverSourceFailure $next 'chat removed' $now}
    else{Set-E3ReceiverSourceOk $next $now;$next.active=$true}
}
$countA=@($order|Where-Object{$_ -eq 'A'}).Count;$countC=@($order|Where-Object{$_ -eq 'C'}).Count
Check ($countA -ge 25 -and $countC -ge 25 -and [Math]::Abs($countA-$countC) -le 1) 'healthy chats keep being read in turn while another chat fails'
Check ($attemptsB -eq 3) 'failing chat is retried with growing pauses (10 s, 20 s, 40 s) instead of every round'
Check ($sources[1].reload -and -not $sources[1].active -and $sources[1].error -eq 'chat removed') 'failing chat reopens its chat link next time and shows its reason'
$probe=New-Source (New-Target 'P' '19:p');$delays=@()
for($i=1;$i -le 8;$i++){$f=Set-E3ReceiverSourceFailure $probe 'x' $t0;$delays+=[int]($probe.retryAt-$t0).TotalSeconds}
Check (($delays -join ',') -eq '10,20,40,80,160,300,300,300') 'retry pause doubles from 10 seconds up to 5 minutes'
Set-E3ReceiverSourceOk $probe $t0
Check ($probe.failures -eq 0 -and -not $probe.reload -and $probe.retryAt -eq $t0 -and -not $probe.error) 'one good read clears the failure state'
$first=Set-E3ReceiverSourceFailure $probe 'same reason' $t0;$again=Set-E3ReceiverSourceFailure $probe 'same reason' $t0;$other=Set-E3ReceiverSourceFailure $probe 'new reason' $t0
Check ($first.announce -and -not $again.announce -and $other.announce) 'the same failure is printed once; a different reason is printed at once'
$script:E3ReceiverHold=@{until=[DateTimeOffset]::MinValue;reason=''};$script:E3ReceiverTab=@{ready=$true}
$login=Set-E3ReceiverSourceFailure $probe 'E3_RECEIVER_LOGIN：Teams 需要重新登入' $t0
Check ($login.scope -eq 'login' -and $script:E3ReceiverHold.until -eq $t0.AddSeconds(60) -and $probe.error -eq 'Teams 需要重新登入' -and $script:E3ReceiverTab) 'sign-in problem pauses every chat for 60 seconds and keeps the tab'
Check ($null -eq (Get-E3ReceiverNextSource $sources $t0.AddSeconds(30)) -and $null -ne (Get-E3ReceiverNextSource $sources $t0.AddSeconds(400))) 'nothing is read during the pause; reading resumes afterwards'
$broken=Set-E3ReceiverSourceFailure $probe 'E3_RECEIVER_BROWSER：專用 Edge 啟動失敗' $t0
Check ($broken.scope -eq 'browser' -and $null -eq $script:E3ReceiverTab -and $script:E3ReceiverHold.until -eq $t0.AddSeconds(20)) 'browser problem drops the tab so it is rebuilt, at most every 20 seconds'
$script:E3ReceiverHold=@{until=[DateTimeOffset]::MinValue;reason=''}

# Bindings: every source points at the one work tab; a changed binding file reloads the receiver.
$one=New-Target 'One' '19:one' 'TAB1';$two=New-Target 'Two' '19:two' 'TAB2'
Save-E3CdpState (Join-Path $script:E3ReceiverProfileRoot 'bindings.json') @($one,$two)
$loaded=@(Get-E3ReceiverTargets)
Check ($loaded.Count -eq 2) 'bindings load without one tab per chat'
$pair=@((New-Source $loaded[0]),(New-Source $loaded[1]))
Set-E3ReceiverBindingTab $pair 'WORKTAB'
$saved=@(Get-E3CdpBindings)
Check (@($saved|Where-Object{$_.targetId -ceq 'WORKTAB'}).Count -eq 2 -and $pair[0].target.targetId -ceq 'WORKTAB' -and $pair[1].target.targetId -ceq 'WORKTAB') 'all bindings are pointed at the single work tab'
Check ((Resolve-E3CdpTarget 'Two').targetId -ceq 'WORKTAB') 'the shared send path resolves a reply to the work tab'
Save-E3CdpState (Join-Path $script:E3ReceiverProfileRoot 'bindings.json') @($one)
$reason='';try{Set-E3ReceiverBindingTab $pair 'WORKTAB'}catch{$reason=$_.Exception.Message}
Check ($reason -match 'E3_RECEIVER_RELOAD') 'binding removed while running: receiver reloads its bindings'
Save-E3CdpState (Join-Path $script:E3ReceiverProfileRoot 'bindings.json') @($one,(New-Target 'Copy' '19:one' 'TAB9'))
$reason='';try{$null=@(Get-E3ReceiverTargets)}catch{$reason=$_.Exception.Message}
Check ($reason -match '重複') 'the same chat bound twice is refused at start'

# Open-E3ReceiverChat: stand-ins record what the receiver asked the browser to do.
$script:calls=[Collections.Generic.List[string]]::new();$script:switchAnswers=@();$script:tabUrl='https://teams.cloud.microsoft/v2/';$script:waitError=''
function Invoke-E3Js([string]$expression,[int]$context=0,[int]$TimeoutMs=10000){
    $script:calls.Add('js')
    if(-not $script:switchAnswers.Count){throw 'Cannot find context with specified id'}
    $answer=$script:switchAnswers[0];$script:switchAnswers=@($script:switchAnswers|Select-Object -Skip 1)
    return $answer
}
function Get-E3ReceiverTabList($session){if($script:tabUrl){return @([pscustomobject]@{id='WORKTAB';type='page';url=$script:tabUrl;webSocketDebuggerUrl='ws://127.0.0.1:1/devtools/page/WORKTAB'})};return @()}
function Connect-E3Cdp([string]$url,[int]$TimeoutMs=10000){$script:calls.Add('connect');$script:CdpEndpoint=$url}
function Invoke-E3Cdp([string]$method,[hashtable]$parameters=@{},[int]$TimeoutMs=10000,[string]$SessionId=''){$script:calls.Add($method);return @{}}
function Enable-E3CdpBackgroundFocus{}
function Move-E3HeadlessPage([string]$url,[int]$TimeoutMs=30000){$script:calls.Add('navigate '+$url)}
function Wait-E3HeadlessChat($target,[int]$TimeoutSeconds=120){$script:calls.Add('wait');if($script:waitError){throw $script:waitError}}
function Connect-E3CdpTarget($session,$target,[switch]$PrepareNew){$script:calls.Add('verify '+$target.route);$script:CdpEndpoint='ws://127.0.0.1:1/devtools/page/WORKTAB';return 77}
function Reset-Tab([bool]$ready){$script:calls.Clear();$script:waitError='';$script:tabUrl='https://teams.cloud.microsoft/v2/';$script:E3ReceiverHeadless=$false
    $script:E3ReceiverTab=@{session=@{port=1;browserUrl='ws://127.0.0.1:1/devtools/browser/x'};tabId='WORKTAB';endpoint='ws://127.0.0.1:1/devtools/page/WORKTAB';context=5;ready=$ready;loadedAt=[DateTimeOffset]::UtcNow;chatId=$null;loginAt=$null;windowAt=[DateTimeOffset]::MaxValue;windowNoteAt=[DateTimeOffset]::MinValue}}
$src=New-Source (New-Target 'Two' '19:two' 'WORKTAB')
function Navigations{return @($script:calls|Where-Object{$_ -like 'navigate *'}).Count}
Reset-Tab $true;$script:switchAnswers=@(@{ok=$true;ready=$false;stage='clicked'},@{ok=$true;ready=$true})
$context=Open-E3ReceiverChat $src
Check ($context -eq 5 -and (Navigations) -eq 0 -and $script:E3ReceiverTab.chatId -eq '19:two') 'prepared page: the chat is switched inside Teams, no reload'
Reset-Tab $true;$script:switchAnswers=@(@{ok=$false;reopen=$true;error='not listed'})
$context=Open-E3ReceiverChat $src
Check ($context -eq 77 -and (Navigations) -eq 1 -and ($script:calls -contains 'verify Two') -and ($script:calls -contains 'Page.addScriptToEvaluateOnNewDocument') -and $script:E3ReceiverTab.ready) 'chat not reachable from the list: opened by chat link and verified strictly'
Check (@($script:calls|Where-Object{$_ -like 'navigate *'})[0] -eq 'navigate https://teams.cloud.microsoft/l/chat/19%3Atwo/conversations') 'the chat link is built from the saved chat ID'
Reset-Tab $true;$script:switchAnswers=@()
$context=Open-E3ReceiverChat $src
Check ($context -eq 77 -and (Navigations) -eq 1) 'page reloaded by someone else (script context gone): chat link is opened again'
Reset-Tab $true;$script:switchAnswers=@(@{ok=$false;fatal=$true;error='renamed'})
$reason='';try{$null=Open-E3ReceiverChat $src}catch{$reason=$_.Exception.Message}
Check ($reason -match 'E3_RECEIVER_SOURCE' -and (Navigations) -eq 0) 'renamed chat stops this source without reloading the page'
Reset-Tab $true;$script:switchAnswers=@(@{ok=$true;ready=$true})
$context=Open-E3ReceiverChat $src -Reload
Check ($context -eq 77 -and (Navigations) -eq 1 -and -not ($script:calls -contains 'js')) 'forced reload skips the in-page switch'
Reset-Tab $false
$context=Open-E3ReceiverChat $src
Check ($context -eq 77 -and (Navigations) -eq 1) 'tab not prepared yet: first read opens the chat link'
Reset-Tab $false;$script:tabUrl='https://login.microsoftonline.com/common/oauth2';$script:E3ReceiverTab.loginAt=[DateTimeOffset]::UtcNow.AddMinutes(-2)
$reason='';try{$null=Open-E3ReceiverChat $src}catch{$reason=$_.Exception.Message}
Check ($reason -match 'E3_RECEIVER_LOGIN' -and (Navigations) -eq 0) 'visible sign-in page is left alone so the user can finish signing in'
$script:E3ReceiverTab.loginAt=[DateTimeOffset]::UtcNow.AddMinutes(-20);$script:calls.Clear()
$null=Open-E3ReceiverChat $src
Check ((Navigations) -eq 1) 'sign-in page older than 15 minutes: one new attempt to open the chat'
Reset-Tab $false;$script:E3ReceiverHeadless=$true;$script:tabUrl='https://login.microsoftonline.com/common/oauth2';$script:E3ReceiverTab.loginAt=[DateTimeOffset]::UtcNow.AddMinutes(-2)
$null=Open-E3ReceiverChat $src
Check ((Navigations) -eq 1) 'headless mode has no sign-in window to protect and tries again'
Reset-Tab $false;$script:waitError='Teams 登入已過期或需要互動驗證；請重新登入'
$reason='';try{$null=Open-E3ReceiverChat $src}catch{$reason=$_.Exception.Message}
Check ($reason -match 'E3_RECEIVER_LOGIN' -and -not $script:E3ReceiverTab.ready -and $script:E3ReceiverTab.loginAt) 'expired sign-in is reported as a login problem, not as a lost chat'
Reset-Tab $true;$script:tabUrl='';$script:switchAnswers=@(@{ok=$false;reopen=$true})
$reason='';try{$null=Open-E3ReceiverChat $src}catch{$reason=$_.Exception.Message}
Check ($reason -match 'CDP_CLOSED') 'closed work tab is reported so the tab is rebuilt'

# Invoke-E3ReceiverVisit: scheduled reload and error classes.
$script:initError='';$script:opened=@()
function Initialize-E3ReceiverTab($sources){if($script:initError){throw $script:initError}}
function Restore-E3ReceiverWindow{}
function Open-E3ReceiverChat($source,[switch]$Reload){$script:opened+=[bool]$Reload;return 5}
function Read-E3ReceiverSettled($target,[int]$context,[int]$TimeoutMs=8000){return @{ok=$true;latest=$true;ids=@('m1');commands=@()}}
Reset-Tab $true;$src.reload=$false
$null=Invoke-E3ReceiverVisit @($src) $src
Check ($script:opened.Count -eq 1 -and -not $script:opened[0]) 'normal read does not reload the page'
$script:E3ReceiverTab.loadedAt=[DateTimeOffset]::UtcNow.AddMinutes(-31);$script:opened=@()
$null=Invoke-E3ReceiverVisit @($src) $src
Check ($script:opened[0]) 'page older than 30 minutes is reloaded on the next read'
$script:E3ReceiverTab.loadedAt=[DateTimeOffset]::UtcNow;$src.reload=$true;$script:opened=@()
$null=Invoke-E3ReceiverVisit @($src) $src
Check ($script:opened[0]) 'a chat that failed last time is reopened by its link'
$script:initError='專用 Edge 啟動失敗'
$reason='';try{$null=Invoke-E3ReceiverVisit @($src) $src}catch{$reason=$_.Exception.Message}
Check ($reason -match '^E3_RECEIVER_BROWSER') 'browser start failure is classed as a browser problem'
$script:initError='E3_RECEIVER_RELOAD：接收綁定已更新，重新載入'
$reason='';try{$null=Invoke-E3ReceiverVisit @($src) $src}catch{$reason=$_.Exception.Message}
Check ($reason -match '^E3_RECEIVER_RELOAD') 'changed bindings pass through as a reload request'

# ---- C. Watchdog: when to restart the receiver ----
$now=[DateTimeOffset]::new(2026,11,12,2,0,0,[TimeSpan]::Zero)
$beat=@{state='listening';pid=1;processStart='1';utc=$now.AddMinutes(-1).ToString('O');startedUtc=$now.AddHours(-3).ToString('O');sources=@(@{route='A';lastOkUtc=$now.AddMinutes(-1).ToString('O')})}
$alive={param($h) $true};$dead={param($h) $false}
function Kind($hb,$check){return (Get-E3ReceiverHealth $hb $now 10 $check)}
Check ((Kind $beat $alive).ok) 'healthy receiver needs no action'
Check ((Kind $beat $dead).kind -eq 'dead' -and (Get-E3ReceiverRestartPlan (Kind $beat $dead) @() $now).action -eq 'start') 'receiver process gone: start it again'
$old=$beat.Clone();$old.utc=$now.AddMinutes(-25).ToString('O')
Check ((Kind $old $alive).kind -eq 'stale' -and (Get-E3ReceiverRestartPlan (Kind $old $alive) @() $now).action -eq 'kill_start') 'receiver process hung: end it and start again'
$busy=$old.Clone();$busy.busyUntilUtc=$now.AddMinutes(5).ToString('O')
Check ((Kind $busy $alive).ok) 'receiver busy with a capture is not treated as hung'
$stopped=$beat.Clone();$stopped.state='stopped';$stopped.intentional=$true
Check ((Kind $stopped $dead).kind -eq 'intentional' -and (Get-E3ReceiverRestartPlan (Kind $stopped $dead) @() $now).action -eq 'none') 'receiver stopped on request is not restarted'
$fatal=$beat.Clone();$fatal.state='stopped';$fatal.fatal=$true
Check ((Get-E3ReceiverRestartPlan (Kind $fatal $dead) @() $now).action -eq 'none') 'receiver stopped by a setup problem is not restarted'
$crashed=$beat.Clone();$crashed.state='stopped';$crashed.stopReason='unexpected'
Check ((Get-E3ReceiverRestartPlan (Kind $crashed $dead) @() $now).action -eq 'start') 'receiver stopped by an error is restarted'
$deaf=$beat.Clone();$deaf.sources=@(@{route='A';lastOkUtc=$now.AddMinutes(-30).ToString('O');error='Teams 需要重新登入'})
Check ((Kind $deaf $alive).kind -eq 'sources' -and (Get-E3ReceiverRestartPlan (Kind $deaf $alive) @() $now).action -eq 'none') 'running receiver that cannot read Teams is not restarted (it retries by itself)'
Check ((Get-E3ReceiverRestartPlan (Kind $null $dead) @() $now).action -eq 'none') 'receiver never started is not started automatically'
$recent=Get-E3ReceiverRestartPlan (Kind $beat $dead) @($now.AddMinutes(-10).ToString('O')) $now
Check ($recent.action -eq 'none' -and $recent.waiting) 'restart tried 10 minutes ago: wait for its result'
$third=Get-E3ReceiverRestartPlan (Kind $beat $dead) @($now.AddMinutes(-50).ToString('O'),$now.AddMinutes(-35).ToString('O'),$now.AddMinutes(-20).ToString('O')) $now
Check ($third.action -eq 'none' -and $third.exhausted) 'three restarts within an hour: stop restarting'
$aged=Get-E3ReceiverRestartPlan (Kind $beat $dead) @($now.AddMinutes(-90).ToString('O'),$now.AddMinutes(-80).ToString('O'),$now.AddMinutes(-70).ToString('O')) $now
Check ($aged.action -eq 'start' -and @($aged.recent).Count -eq 0) 'restarts older than an hour no longer count'
# ---- D. The real listening loop with stand-in chats (heartbeat, stop request, reload, setup error) ----
$script:targetLoads=0;$script:visits=@();$script:visitPlan={param($n,$route) $null}
function Get-E3ReceiverTargets{$script:targetLoads++;if($script:targetError){throw $script:targetError};return @((New-Target 'One' '19:one' 'WORKTAB'),(New-Target 'Two' '19:two' 'WORKTAB'))}
function Invoke-E3ReceiverVisit($sources,$source){$script:visits+=[string]$source.target.route;& $script:visitPlan $script:visits.Count ([string]$source.target.route);return $null}
function Read-Beat{return (Get-Content -LiteralPath (Join-Path $script:E3CdpLogRoot 'heartbeat.json') -Raw -Encoding UTF8|ConvertFrom-Json)}
$script:targetError='';$script:E3ReceiverCutoff=$null;$script:E3ReceiverStartedUtc=$null
$script:visitPlan={param($n,$route)
    if($route -eq 'Two'){throw '對話尚未停在最新訊息'}
    if($n -ge 6){[IO.File]::WriteAllText((Get-E3ReceiverStopPath),'stop')}
}
Invoke-E3ReceiverTest 600 -Continuous
$beat=Read-Beat
Check ($beat.state -eq 'stopped' -and $beat.intentional -eq $true -and $beat.mode -eq 'window' -and @($beat.sources).Count -eq 2) 'stop request ends the loop and is recorded as a requested stop'
Check (@($script:visits|Where-Object{$_ -eq 'One'}).Count -ge 4 -and @($script:visits|Where-Object{$_ -eq 'Two'}).Count -eq 1) 'in the real loop a failing chat does not stop the other chat'
$two=@($beat.sources|Where-Object{$_.route -eq 'Two'})[0];$oneBeat=@($beat.sources|Where-Object{$_.route -eq 'One'})[0]
Check ($two.error -eq '對話尚未停在最新訊息' -and -not $two.active -and $oneBeat.lastOkUtc) 'heartbeat lists each chat with its own state'
Check (-not (Test-Path -LiteralPath (Get-E3ReceiverStopPath))) 'the stop request is consumed'
$existing=$null
Check (-not [Threading.Mutex]::TryOpenExisting('Local\E3TeamsCommandReceiver',[ref]$existing)) 'the single-instance lock is released when the loop ends'
$script:targetLoads=0;$script:visits=@()
$script:visitPlan={param($n,$route)
    if($n -eq 1){throw 'E3_RECEIVER_RELOAD：接收綁定已更新，重新載入'}
    if($n -ge 3){[IO.File]::WriteAllText((Get-E3ReceiverStopPath),'stop')}
}
Start-E3ReceiverSupervised 600 -Continuous
Check ($script:targetLoads -eq 2 -and (Read-Beat).intentional -eq $true) 'changed bindings restart listening inside the same process, then it keeps running'
$script:targetError='請先執行 setup_teams_receiver.bat 綁定要接收的對話';$reason=''
try{Start-E3ReceiverSupervised 600 -Continuous}catch{$reason=$_.Exception.Message}
$beat=Read-Beat
Check ($reason -eq $script:targetError -and $beat.state -eq 'stopped' -and $beat.fatal -eq $true -and $beat.intentional -ne $true) 'setup problem ends the receiver with its reason and is marked so the watchdog does not restart it'
# ---- E. Reply path: drafts, auto-Enter switch and queued notices ----
# A leftover draft no longer blocks replies: the send path clears it after verifying the chat.
Reset-Tab $true;$script:initError=''
function Assert-E3ReceiverDestination($target,[int]$context){}
function Assert-E3CdpComposerEmpty([int]$context){throw 'draft left in the box'}
$reason='';$ctx=0;try{$ctx=Enter-E3ReceiverChat @($src) $src}catch{$reason=$_.Exception.Message}
Check (-not $reason -and $ctx -eq 77) 'a leftover draft does not stop the reply; the send path clears it'
# CDP with auto-Enter switched off must report "not sent", never a normal return.
Save-E3CdpState (Join-Path $script:E3ReceiverProfileRoot 'bindings.json') @((New-Target 'Solo' '19:solo' 'WORKTAB'))
$reason='';try{Send-GroupToTeamsCdp 'Solo' @() 'hello' @{cdp_headless=$true;auto_press_enter=$false} $false}catch{$reason=$_.Exception.Message}
Check ($reason -match '未送出') 'CDP with auto-Enter off fails as not sent instead of returning as delivered'
$reason='';try{Send-GroupToTeamsCdp 'Solo' @() 'hello' @{cdp_headless=$true;auto_press_enter=$false} $true}catch{$reason=$_.Exception.Message}
Check (-not $reason) 'a dry run still only checks and returns'
# Queued watchdog notices: claimed only after the shared lock is taken.
$script:sent=@()
function Enter-E3ReceiverChat($sources,$source){return 77}
function Send-GroupToTeamsCdp([string]$targetChatName,[string[]]$imageFiles,[string]$messageText,$teamsCfg,[bool]$isDryRun){$script:sent+=$messageText}
$outbox=Join-Path $script:E3CdpLogRoot 'outbox';$notice=Join-Path $outbox 'n1.json'
Write-E3WorkJson $notice @{text='✦ [日管監看] fixture';createdUtc=[DateTimeOffset]::UtcNow.ToString('O')}
$mutexName='Local\E3FixtureCdpShared_'+[guid]::NewGuid().ToString('N')
$shared=[Threading.Mutex]::new($false,$mutexName)
$holder=[powershell]::Create().AddScript({param($name) $m=[Threading.Mutex]::new($false,$name);[void]$m.WaitOne();Start-Sleep -Milliseconds 2500;$m.ReleaseMutex();$m.Dispose()}).AddArgument($mutexName)
$handle=$holder.BeginInvoke();Start-Sleep -Milliseconds 700
$notify=New-Source (New-Target 'Me' '19:me' 'WORKTAB');$notify.active=$true
Send-E3ReceiverOutbox @($notify) $shared
Check ((Test-Path -LiteralPath $notice) -and -not $script:sent.Count -and -not @(Get-ChildItem -LiteralPath $outbox -File|Where-Object{$_.Extension -in @('.sending','.failed')}).Count) 'while another job holds the lock the notice stays queued and is not marked failed'
$holder.EndInvoke($handle);$holder.Dispose()
Send-E3ReceiverOutbox @($notify) $shared
Check ($script:sent.Count -eq 1 -and (Test-Path -LiteralPath (Join-Path $outbox 'n1.sent')) -and -not (Test-Path -LiteralPath $notice)) 'once the lock is free the notice is sent exactly once'
$shared.Dispose()
# ---- F. Scheduled run results: notify once when a run did not deliver ----
$script:E3WatchdogLogRoot=Join-Path $fixture 'wlogs'
$run=[DateTimeOffset]::new(2026,11,12,0,0,0,[TimeSpan]::Zero)
function Result($changes){$h=@{startedUtc=$run.AddSeconds(5).ToString('O');state='finished';exitCode=0;skipped='';error='';targets=@('A');delivered=@('A');sendFailures=@()};foreach($k in $changes.Keys){$h[$k]=$changes[$k]};return [pscustomobject]$h}
Check (-not (Get-E3ScheduleRunProblem $run 0 (Result @{})).problem) 'delivered run: no notice'
Check (-not (Get-E3ScheduleRunProblem $run 1 (Result @{exitCode=1})).problem) 'failed page listed inside a delivered message: no extra notice'
$p=Get-E3ScheduleRunProblem $run 1 (Result @{exitCode=1;delivered=@();sendFailures=@('【A】結果不明')})
Check ($p.problem -and $p.reason -match '結果不明') 'send failure or uncertain result is reported with its reason'
$p=Get-E3ScheduleRunProblem $run 1 (Result @{exitCode=1;delivered=@();error='Edge 啟動失敗'})
Check ($p.problem -and $p.reason -match '沒有送出任何訊息') 'run that sent nothing is reported'
$p=Get-E3ScheduleRunProblem $run 124 (Result @{state='running'})
Check ($p.problem -and $p.reason -match '124') 'run stopped by the 10-minute limit is reported as unknown'
Check ((Get-E3ScheduleRunProblem $run 1 (Result @{state='no_lock'})).problem) 'run that never got the work lock is reported'
Check (-not (Get-E3ScheduleRunProblem $run 0 (Result @{skipped='alert_only_normal';delivered=@()})).problem) 'alert-only run with nothing abnormal: no notice'
$stale=Result @{startedUtc=$run.AddDays(-1).ToString('O')}
Check (-not (Get-E3ScheduleRunProblem $run 0 $stale).problem -and (Get-E3ScheduleRunProblem $run 1 $stale).reason -match '沒有本次傳送紀錄') 'record from another run is ignored; only the task result is used'
function Get-E3OwnedTaskId($task){return $task.id}
$info={param($t) $t.info}
$cfgF=[pscustomobject]@{schedules=@([pscustomobject]@{id='morning';name='MSD日管Index'})}
Write-E3WorkJson (Join-Path $script:E3WatchdogLogRoot 'schedule_results\morning.json') (Result @{exitCode=1;delivered=@();sendFailures=@('【A】結果不明')})
$tasks=@([pscustomobject]@{id='morning';TaskName='MSD日管Index';info=[pscustomobject]@{LastRunTime=$run.LocalDateTime;LastTaskResult=1}},
    [pscustomobject]@{id='old';TaskName='Old';info=[pscustomobject]@{LastRunTime=$run.AddDays(-3).LocalDateTime;LastTaskResult=1}},
    [pscustomobject]@{id='busy';TaskName='Busy';info=[pscustomobject]@{LastRunTime=$run.LocalDateTime;LastTaskResult=267009}})
$box=Join-Path $script:E3WatchdogLogRoot 'teams_receiver\outbox'
function Notices{return @(Get-ChildItem -LiteralPath $box -Filter '*.json' -File -ErrorAction SilentlyContinue)}
$null=Invoke-E3ScheduleResultCheck $cfgF $tasks $info $run.AddMinutes(20)
$queued=@(Notices)
$text=if($queued.Count){[string](Read-E3WorkJson $queued[0].FullName).text}else{''}
Check ($queued.Count -eq 1 -and $text -match '^✦' -and $text -match 'MSD日管Index' -and $text -notmatch 'Old|Busy') 'one notice for the failed run; old history and a running task are left alone'
$null=Invoke-E3ScheduleResultCheck $cfgF $tasks $info $run.AddMinutes(30)
Check (@(Notices).Count -eq 1) 'the same run is never announced twice'
$tasks[2].info=[pscustomobject]@{LastRunTime=$run.LocalDateTime;LastTaskResult=124}
$null=Invoke-E3ScheduleResultCheck $cfgF $tasks $info $run.AddMinutes(40)
Check (@(Notices).Count -eq 2) 'a run is judged once it has ended'
# Settings page schedule card: last-run summary uses the same judgment.
function Sum($code,$result){return (Get-E3ScheduleRunSummary $run $code $result)}
Check ((Get-E3ScheduleRunSummary $null 0 $null).status -eq 'none' -and (Sum 267011 $null).status -eq 'none') 'card: never run'
Check ((Sum 267009 $null).status -eq 'running') 'card: running'
Check ((Sum 0 (Result @{})).text -eq '已送出' -and (Sum 0 $null).status -eq 'ok') 'card: delivered (with or without a run record)'
Check ((Sum 1 (Result @{exitCode=1})).status -eq 'warn') 'card: delivered with failed pages is a warning'
$s=Sum 1 (Result @{exitCode=1;delivered=@();sendFailures=@('【A】結果不明')})
Check ($s.status -eq 'bad' -and $s.reason -match '結果不明') 'card: not delivered shows the reason'
Check ((Sum 0 (Result @{skipped='alert_only_normal';delivered=@()})).text -match '僅異常') 'card: alert-only run with nothing abnormal'
"PASS $passed checks. Fixture: $fixture"
