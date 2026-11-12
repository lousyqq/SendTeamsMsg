# Isolated tests of "say why": capture failure reasons in the reply, command records with their
# reason, the separate failure / interrupted / offline notices, routed outbox, status lines,
# watchdog history and the relay through the sender login.
# Every Teams, browser and capture boundary is a stand-in and all files live in a temporary
# folder. No Teams navigation, sign-in, send or Windows task change. Section D runs the real
# listening loop, which takes the real single-instance lock for a few seconds: stop a running
# receiver before running this on a host.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path $env:TEMP ('E3ReceiverNotice_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
. (Join-Path $root 'teams_receiver.ps1') -LibraryOnly
. (Join-Path $root 'teams_receiver_watchdog.ps1')
$script:E3CdpLogRoot=Join-Path $fixture 'logs\teams_receiver'
$script:E3WatchdogLogRoot=Join-Path $fixture 'logs'
$script:E3WorkControlRoot=Join-Path $fixture 'work'
$script:E3ReceiverProfileRoot=Join-Path $fixture 'state'
[void][IO.Directory]::CreateDirectory($script:E3ReceiverProfileRoot)
$passed=0
function Check([bool]$ok,[string]$name){if(-not $ok){throw "FAIL $name"};$script:passed++;Write-Host "PASS $name"}
function New-Target([string]$route,[string]$chat){return [pscustomobject]@{route=$route;targetId='WORKTAB';binding=[pscustomobject]@{accountId='fixture';chatId=$chat;label=$route}}}
function New-Source($target){return @{target=$target;active=$false;cutoff=[DateTimeOffset]::UtcNow;retryAt=[DateTimeOffset]::MinValue;visitedAt=[DateTimeOffset]::MinValue;seen=[Collections.Generic.HashSet[string]]::new();lastOkUtc=$null;error=$null;failures=0;reload=$false;warned=$null}}
$cfg=[pscustomobject]@{pages=@([pscustomobject]@{id='pageA';name='PageA';enabled=$true;url='http://fixture.invalid/charts.php'},[pscustomobject]@{id='pageB';name='PageB';enabled=$true;url='http://fixture.invalid/report.aspx'});schedules=@();teams=[pscustomobject]@{prefer_window='cdp';target_chat_name='Default'}}
function Get-E3ReceiverConfig{return $cfg}
$outbox=Join-Path $script:E3CdpLogRoot 'outbox';$claims=Join-Path $script:E3CdpLogRoot 'commands'
function Queue{return @(Get-ChildItem -LiteralPath $outbox -Filter '*.json' -File -ErrorAction SilentlyContinue|Sort-Object Name|ForEach-Object{Read-E3WorkJson $_.FullName})}
function Clear-Queue{if(Test-Path -LiteralPath $outbox){Remove-Item -LiteralPath $outbox -Recurse -Force}}

# ---- A. Command wording and reasons ----
Check ((Resolve-E3ReceiverRequest '@日管 上一個指令' $cfg).kind -eq 'history') 'asking for the last command is understood'
Check ((Resolve-E3ReceiverRequest '@日管 為什麼截圖失敗' $cfg).kind -eq 'history') 'asking why a capture failed shows the command history, it does not capture again'
Check ((Resolve-E3ReceiverRequest '@日管 截圖 PageA' $cfg).kind -eq 'capture') 'a capture command is still a capture'
Check ((Resolve-E3ReceiverRequest '@日管 你好' $cfg).text -match '上一個指令') 'the help text lists the new command'
Check ((Format-E3ReceiverReason "E3_RECEIVER_LOGIN：Teams 需要重新登入`r`n  請處理") -eq 'Teams 需要重新登入；請處理') 'a reason is one clean line without internal prefixes'
Check ((Format-E3ReceiverReason ('長'*400) 50).Length -eq 51 -and (Format-E3ReceiverReason '') -eq '沒有留下原因') 'a reason is bounded and never empty'

# ---- B. Capture reply carries each page's real reason ----
$request=@{label='PageA、PageB';pages=@($cfg.pages);warnings=@()}
$job=Join-Path $fixture 'job1';[void][IO.Directory]::CreateDirectory($job)
[IO.File]::WriteAllBytes((Join-Path $job 'pageA.png'),[byte[]](1,2,3))
[IO.File]::WriteAllText((Join-Path $job 'result.json'),(@{pages=@(@{id='pageA';ok=$true;error=''},@{id='pageB';ok=$false;error='停在登入畫面，自動登入沒有成功（請確認此頁的帳密，或按 🔐 登入監控網站）'});error=''}|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
$reply=ConvertTo-E3ReceiverCaptureReply $request $job
Check (@($reply.images).Count -eq 1 -and @($reply.problems).Count -eq 1) 'one page captured, one page reported as a problem'
Check ($reply.text -match 'PageB：沒有截到。原因：停在登入畫面' -and $reply.text -notmatch '請查看本機') 'the reply states the real reason instead of pointing at the host log'
Check ($reply.text -match '^✦ \[日管\]' -and $reply.text -match '已擷取 PageA') 'the captured page is still listed'
$job=Join-Path $fixture 'job2';[void][IO.Directory]::CreateDirectory($job)
[IO.File]::WriteAllText((Join-Path $job 'result.json'),(@{pages=@();error='等待已逾時，本次未取得操作權；可在設定網頁重新執行。'}|ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
$reply=ConvertTo-E3ReceiverCaptureReply $request $job
Check (-not @($reply.images).Count -and @($reply.problems).Count -eq 2 -and $reply.text -match '排程或另一個擷取正在執行') 'a busy host is explained in plain words for every page'
$job=Join-Path $fixture 'job3';[void][IO.Directory]::CreateDirectory($job)
[IO.File]::WriteAllText((Join-Path $job 'deadline.json'),'{}')
Check ((ConvertTo-E3ReceiverCaptureReply $request $job).text -match '超過 300 秒') 'a capture stopped by its time limit says so'
$job=Join-Path $fixture 'job4';[void][IO.Directory]::CreateDirectory($job)
Check ((ConvertTo-E3ReceiverCaptureReply $request $job $false 1).text -match '結束代碼 1') 'a capture that ended without a result reports its exit code'
Check ((ConvertTo-E3ReceiverCaptureReply $request $job $true $null).text -match '330 秒') 'a capture that had to be stopped by the receiver says so'

# ---- C. Notice texts ----
$info=@{route='One';command='@日管 截圖 PageA';messageTime='2026-11-12T02:32:00.000Z'}
$text=New-E3ReceiverFailureText $info 'result' 'CDP 逾時、結果不明'
Check ($text -match '^✦' -and $text -match '11/12 10:32「截圖 PageA」' -and $text -match '可能已送出' -and $text -match '原因：CDP 逾時、結果不明') 'failure notice: Taiwan time, command, what may already be there, reason'
Check ((New-E3ReceiverFailureText $info 'received' 'x') -match '沒有送出任何內容' -and (New-E3ReceiverFailureText $info 'acknowledgement' 'x') -match '截圖沒有執行' -and (New-E3ReceiverFailureText $info 'capture' 'x') -match '截圖結果沒有送出') 'failure notice wording follows the phase'
Check ($text -notmatch '^@日管' -and (Resolve-E3ReceiverRequest $text $cfg).kind -eq 'ignore') 'a notice can never be read back as a command'

# ---- D. The real loop: a failed reply leaves its reason and queues one explanation ----
$one=New-Target 'One' '19:one';$two=New-Target 'Two' '19:two'
function Get-E3ReceiverTargets{return @($one,$two)}
function Enter-E3ReceiverChat($sources,$source){return 77}
$script:sends=@();$script:sendPlan={param($n,$route,$text)}
function Send-GroupToTeamsCdp([string]$targetChatName,[string[]]$imageFiles,[string]$messageText,$teamsCfg,[bool]$isDryRun){$script:sends+=@{route=$targetChatName;text=$messageText;images=@($imageFiles).Count};& $script:sendPlan $script:sends.Count $targetChatName $messageText}
function New-Candidate($target,[string]$text,[DateTimeOffset]$time){$m=[pscustomobject]@{id=[guid]::NewGuid().ToString('N');time=$time.ToString('O');text=$text};return @{key=(Get-E3ReceiverKey $target.binding $m);message=$m}}
function Start-Loop([scriptblock]$plan){
    $script:visits=0;$script:plan=$plan;$script:sends=@();$script:given=$false
    $script:E3ReceiverCutoff=$null;$script:E3ReceiverStartedUtc=$null;$script:E3ReceiverMissedDone=$null
    Invoke-E3ReceiverTest 600 -Continuous
}
function Invoke-E3ReceiverVisit($sources,$source){
    $script:visits++
    if($script:visits -ge 8){[IO.File]::WriteAllText((Get-E3ReceiverStopPath),'stop')}
    return (& $script:plan $script:visits $source)
}
function Read-Claim([string]$key){return Read-E3WorkJson (Join-Path $claims ($key+'.json'))}
# The loop's own outbox pass is switched off in this section so queued notices can be inspected;
# the real one is restored for section F.
$realOutbox=${function:Send-E3ReceiverOutbox}
function Send-E3ReceiverOutbox($sources,$shared){}
# D1: the reply itself fails.
$c1=$null;$script:sendPlan={param($n,$route,$text) throw 'CDP 逾時、結果不明；請檢查 Teams，停止後續圖片且不重送'}
Start-Loop {param($n,$source) if(-not $script:given -and $source.target.route -eq 'One'){$script:given=$true;$script:c1=New-Candidate $source.target '@日管 你好' ([DateTimeOffset]::UtcNow);return $script:c1}}
$claim=Read-Claim $script:c1.key
Check ($claim.state -eq 'not_retried' -and $claim.phase -eq 'result' -and $claim.error -match 'CDP 逾時' -and $claim.route -eq 'One' -and $claim.messageTime) 'failed reply: the command record keeps the phase and the reason'
$queued=@(Queue)
Check ($queued.Count -eq 1 -and $queued[0].route -eq 'One' -and $queued[0].kind -eq 'command_failure' -and $queued[0].text -match '「你好」' -and $queued[0].text -match '原因：CDP 逾時') 'failed reply: one explanation is queued for the same chat'
Check ($script:sends.Count -eq 1) 'failed reply: the failed content is not sent again'
$events=[IO.File]::ReadAllText((Join-Path (Join-Path $script:E3CdpLogRoot ([DateTime]::Now.ToString('yyyy-MM-dd'))) 'receiver_events.log'),[Text.Encoding]::UTF8)
Check ($events -match "command_failed`tOne：@日管 你好" -and $events -match "`tprocessing`t") 'the event log records the command, its failure and the reason with a time'
# D2: the "received" message fails; the capture must not run.
Clear-Queue;$script:captured=0
function Invoke-E3ReceiverCapture($request,[string]$key){$script:captured++;return @{images=@();text="✦ [日管]`nfixture";problems=@()}}
$script:sendPlan={param($n,$route,$text) throw 'Teams 分頁控制程式版本不符'}
Start-Loop {param($n,$source) if(-not $script:given -and $source.target.route -eq 'One'){$script:given=$true;$script:c2=New-Candidate $source.target '@日管 截圖 PageA' ([DateTimeOffset]::UtcNow);return $script:c2}}
$claim=Read-Claim $script:c2.key;$queued=@(Queue)
Check ($claim.state -eq 'not_retried' -and $claim.phase -eq 'acknowledgement' -and -not $script:captured) 'failed acknowledgement: recorded, and nothing is captured afterwards'
Check ($queued.Count -eq 1 -and $queued[0].text -match '截圖沒有執行') 'failed acknowledgement: the explanation says the capture did not run'
# D3: a reply that worked, with one page that could not be captured.
Clear-Queue;$script:sendPlan={param($n,$route,$text)}
function Invoke-E3ReceiverCapture($request,[string]$key){return @{images=@();text="✦ [日管]`n這次沒有截到圖片。";problems=@('PageA：沒有截到。原因：網站回應錯誤（HTTP 503）')}}
Start-Loop {param($n,$source) if(-not $script:given -and $source.target.route -eq 'One'){$script:given=$true;$script:c3=New-Candidate $source.target '@日管 截圖 PageA' ([DateTimeOffset]::UtcNow);return $script:c3}}
$claim=Read-Claim $script:c3.key
Check ($claim.state -eq 'replied' -and @($claim.problems).Count -eq 1 -and $script:sends.Count -eq 2 -and -not @(Queue).Count) 'delivered reply: recorded as replied with its page problem, no extra notice'
$history=Get-E3ReceiverHistoryReply 'One'
Check ($history -match 'HTTP 503' -and $history -match '原因：Teams 分頁控制程式版本不符' -and $history -match '原因：CDP 逾時') 'history reply lists the recent commands of this chat with their reasons'
Check ((Get-E3ReceiverHistoryReply 'Two') -match '沒有先前的指令紀錄') 'history never shows another chat''s commands'
# D4: commands that arrived while no receiver was running are reported once, not run.
Clear-Queue
Write-E3WorkJson (Join-Path $script:E3CdpLogRoot 'heartbeat.json') @{version=2;state='stopped';utc=[DateTimeOffset]::UtcNow.AddMinutes(-30).ToString('O')}
$late=[pscustomobject]@{id='late1';time=[DateTimeOffset]::UtcNow.AddMinutes(-10).ToString('O');text='@日管 截圖 PageB'}
$ancient=[pscustomobject]@{id='old1';time=[DateTimeOffset]::UtcNow.AddHours(-3).ToString('O');text='@日管 狀態'}
Start-Loop {param($n,$source) $source.lastSnapshot=@{commands=@($ancient,$late)};$null}
$queued=@(Queue)
Check ($queued.Count -eq 2 -and @($queued|Where-Object{$_.kind -eq 'missed' -and $_.text -match '「截圖 PageB」' -and $_.text -notmatch '「狀態」'}).Count -eq 2 -and -not $script:sends.Count) 'offline period: each chat is told once which commands were not handled; none is run'
Check (@($queued.route|Sort-Object) -join ',' -eq 'One,Two') 'offline notice goes to the chat the command came from'

# ---- E. A receiver that ended mid-command ----
Clear-Queue
$now=[DateTimeOffset]::UtcNow
$mid=Join-Path $claims (('a'*64)+'.json');$done=Join-Path $claims (('b'*64)+'.json');$aged=Join-Path $claims (('c'*64)+'.json')
Save-E3ReceiverClaimState $mid 'acknowledged' @{route='Two';command='@日管 截圖 PageB';messageTime=$now.AddMinutes(-5).ToString('O')}
Save-E3ReceiverClaimState $done 'replied' @{route='Two';command='@日管 狀態';messageTime=$now.AddMinutes(-9).ToString('O')}
Save-E3ReceiverClaimState $aged 'claimed' @{route='Two';command='@日管 狀態';messageTime=$now.AddHours(-9).ToString('O')}
[IO.File]::SetLastWriteTimeUtc($aged,$now.UtcDateTime.AddHours(-9))
Resolve-E3ReceiverInterruptedClaims $now
$queued=@(Queue)
Check ((Read-E3WorkJson $mid).state -eq 'interrupted' -and $queued.Count -eq 1 -and $queued[0].route -eq 'Two' -and $queued[0].text -match '被中斷') 'interrupted command: marked and explained once to its chat'
Check ((Read-E3WorkJson $done).state -eq 'replied' -and (Read-E3WorkJson $aged).state -eq 'claimed') 'finished and old records are left alone'
Resolve-E3ReceiverInterruptedClaims $now
Check (@(Queue).Count -eq 1) 'the same interruption is never announced twice'

# ---- F. Outbox routing ----
Set-Item -Path function:Send-E3ReceiverOutbox -Value $realOutbox
Clear-Queue;$script:sends=@();$script:sendPlan={param($n,$route,$text)}
$sOne=New-Source $one;$sOne.active=$true;$sTwo=New-Source $two
$mutex=[Threading.Mutex]::new($false,'Local\E3FixtureNotice_'+[guid]::NewGuid().ToString('N'))
$null=Add-E3ReceiverOutbox "✦ [日管]`nfor two" 'Two' 'command_failure'
$null=Add-E3ReceiverOutbox "✦ [日管]`nfor gone" 'Gone' 'command_failure'
$null=Add-E3ReceiverOutbox "✦ [日管監看]`ngeneral" '' ''
Send-E3ReceiverOutbox @($sOne,$sTwo) $mutex
Check ($script:sends.Count -eq 1 -and $script:sends[0].route -eq 'One' -and $script:sends[0].text -match 'general') 'a general notice is sent while a routed one waits for its own chat'
Check (@(Queue).Count -eq 1 -and @(Get-ChildItem -LiteralPath $outbox -Filter '*.invalid').Count -eq 1) 'a notice for a chat that is no longer bound is set aside, never sent elsewhere'
$sTwo.active=$true
Send-E3ReceiverOutbox @($sOne,$sTwo) $mutex
Check ($script:sends.Count -eq 2 -and $script:sends[1].route -eq 'Two' -and -not @(Queue).Count) 'once its chat can be read the routed notice goes to that chat'
Check (-not (Add-E3ReceiverOutbox '@日管 狀態' 'One')) 'text that could be read as a command is refused as a notice'
# A notice whose own send fails is passed on once through the sender login.
$script:sendPlan={param($n,$route,$text) throw 'receiver page broken'}
$null=Add-E3ReceiverOutbox "✦ [日管]`n11/12 10:32「截圖 PageA」 這個指令沒有完成。" 'One' 'command_failure'
$null=Add-E3ReceiverOutbox "✦ [日管監看]`nother kind" '' ''
Send-E3ReceiverOutbox @($sOne,$sTwo) $mutex
Check (@(Get-ChildItem -LiteralPath $outbox -Filter '*.failed').Count -eq 2) 'a notice that could not be sent is marked failed, not retried by the receiver'
$mutex.Dispose()
$script:relayed=@()
$bad=[pscustomobject]@{teams=[pscustomobject]@{prefer_window='';target_chat_name='Default'}}
Check ((Invoke-E3FailedNoticeRelay $bad {param($t,$m) $script:relayed+=$m}) -eq 0 -and -not $script:relayed.Count -and @(Get-ChildItem -LiteralPath $outbox -Filter '*.failed').Count -eq 2) 'relay needs the CDP sender; without it nothing is claimed'
$null=Invoke-E3FailedNoticeRelay $cfg {param($t,$m) $script:relayed+=@{target=$t;text=$m}}
Check ($script:relayed.Count -eq 1 -and $script:relayed[0].target -eq 'Default' -and $script:relayed[0].text -match '截圖 PageA' -and $script:relayed[0].text -match '原對話：One') 'relay: the command explanation is passed on once through the sender login'
Check (@(Get-ChildItem -LiteralPath $outbox -Filter '*.relayed').Count -eq 1 -and @(Get-ChildItem -LiteralPath $outbox -Filter '*.failed').Count -eq 1) 'relay: only command explanations are relayed; other notices keep their once-only rule'
$null=Invoke-E3FailedNoticeRelay $cfg {param($t,$m) $script:relayed+=@{target=$t;text=$m}}
Check ($script:relayed.Count -eq 1) 'relay: never twice'
Write-E3WorkJson (Join-Path $outbox 'x1.failed') @{text="✦ [日管]`nagain";createdUtc=[DateTimeOffset]::UtcNow.ToString('O');route='One';kind='command_failure'}
Check ((Invoke-E3FailedNoticeRelay $cfg {param($t,$m) throw 'sender login expired'}) -eq 1 -and (Test-Path -LiteralPath (Join-Path $outbox 'x1.relayfailed'))) 'relay: a failed relay is recorded and not repeated'

# ---- G. Status lines and the watchdog task check ----
$task=[pscustomobject]@{TaskName='E3 日管接收監看';State='Ready'}
$clock=[DateTime]::new(2026,11,12,10,0,0)
function State($minutes){return (Get-E3ReceiverWatchdogTaskState @($task) {param($t) [pscustomobject]@{LastRunTime=$clock.AddMinutes(-$minutes);LastTaskResult=0}} $clock)}
Check ((Get-E3ReceiverWatchdogLine (State 4)) -match '正常（上次 09:56' -and -not (Test-E3ReceiverWatchdogLate (State 4))) 'watchdog task that ran recently is normal'
Check ((Get-E3ReceiverWatchdogLine (State 45)) -match '已 45 分鐘沒有執行' -and (Test-E3ReceiverWatchdogLate (State 45))) 'watchdog task silent for 45 minutes is flagged'
Check ((Get-E3ReceiverWatchdogLine (Get-E3ReceiverWatchdogTaskState @())) -match '尚未註冊' -and (Get-E3ReceiverWatchdogLine (Get-E3ReceiverWatchdogTaskState $null)) -match '無法讀取') 'not registered and unreadable are said plainly'
Clear-Queue;$script:E3ReceiverWatchLate=0;$script:E3ReceiverWatchWarned=$false
$silent={[pscustomobject]@{TaskName='E3 日管接收監看';State='Disabled'}}
Test-E3ReceiverWatchdogTask $silent;Test-E3ReceiverWatchdogTask $silent
Check (-not @(Queue).Count) 'a task the user disabled is not nagged about'
$never={@($task)}   # registered and enabled; the real task info cannot be read for this stand-in: never ran
Test-E3ReceiverWatchdogTask $never
Check (-not @(Queue).Count) 'one late reading is not enough (the host may just have woken up)'
Test-E3ReceiverWatchdogTask $never;Test-E3ReceiverWatchdogTask $never
$queued=@(Queue)
Check ($queued.Count -eq 1 -and -not $queued[0].route -and $queued[0].text -match '離線監看任務') 'two late readings queue exactly one notice'
Write-E3WorkJson (Join-Path $script:E3CdpLogRoot 'sender_login_state.json') @{lastCheckUtc='2026-11-12T01:40:00Z';ok=$false;alerted=$true;reason='• Default：Teams 登入已過期'}
$lines=@(Get-E3ReceiverHealthLines $cfg @($task) 'One')
Check (@($lines|Where-Object{$_ -match '排程用的 Teams 登入：⚠ 需要處理（11/12 09:40 檢查）：• Default：Teams 登入已過期'}).Count -eq 1) 'status: the sender login problem is shown with its reason'
Check (@($lines|Where-Object{$_ -match '待送通知：1 則'}).Count -eq 1 -and @($lines|Where-Object{$_ -match '有 2 個指令沒有完成'}).Count -eq 1) 'status: queued notices and unfinished commands of this chat are counted'
Check (-not @(Get-E3ReceiverHealthLines $cfg @($task) 'Two'|Where-Object{$_ -match '有 2 個指令'}).Count) 'status: another chat''s failures are not counted'

# ---- H. Watchdog history ----
$log=Join-Path $script:E3CdpLogRoot 'watchdog_last.txt'
$historyFile=Join-Path (Join-Path $script:E3CdpLogRoot ([DateTime]::Now.ToString('yyyy-MM-dd'))) 'watchdog_history.log'
if(Test-Path -LiteralPath $historyFile){Remove-Item -LiteralPath $historyFile -Force}
Write-E3WatchdogLog $log '正常：正常' 6>$null;Write-E3WatchdogLog $log '正常：正常' 6>$null;Write-E3WatchdogLog $log "接收端異常：程序已結束`n已重新啟動" 6>$null;Write-E3WatchdogLog $log '正常：正常' 6>$null
$rows=@([IO.File]::ReadAllLines($historyFile,[Text.Encoding]::UTF8))
Check ($rows.Count -eq 3 -and $rows[1] -match "^\d\d:\d\d:\d\d`twatchdog_last`t接收端異常：程序已結束 / 已重新啟動$") 'watchdog history keeps one timed line per change, not one per run'
Check ([IO.File]::ReadAllText($log,[Text.Encoding]::UTF8) -match '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\r\n正常：正常$') 'the newest result file is unchanged in format'

# ---- I. Damaged program files stop the start with a named cause ----
# A copy of the program (stand-in config, no login data) with one script stripped of its BOM.
# The receiver must end before loading anything else: no lock, no Edge, no Teams.
$copy=Join-Path $fixture 'copy'
foreach($dir in @('','teams_cdp','tools')){[void][IO.Directory]::CreateDirectory((Join-Path $copy $dir))}
foreach($file in @(Get-ChildItem -LiteralPath $root -File|Where-Object{$_.Extension -in @('.ps1','.js')})){Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $copy $file.Name)}
foreach($file in @(Get-ChildItem -LiteralPath (Join-Path $root 'teams_cdp') -File)){Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $copy ('teams_cdp\'+$file.Name))}
Copy-Item -LiteralPath (Join-Path $root 'tools\check_files.ps1') -Destination (Join-Path $copy 'tools\check_files.ps1')
[IO.File]::WriteAllText((Join-Path $copy 'config.json'),'{"pages":[],"schedules":[],"teams":{}}',[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $copy 'calibrator.html'),'<html></html>',[Text.UTF8Encoding]::new($false))
$clean=@(& (Join-Path $copy 'tools\check_files.ps1') -PassThru|Where-Object{$_.level -eq 'error'})
Check (-not $clean.Count) 'the checker accepts an undamaged copy'
$victim=Join-Path $copy 'teams_receiver_commands.ps1'
$body=[IO.File]::ReadAllText($victim,[Text.Encoding]::UTF8);if($body[0] -eq [char]0xFEFF){$body=$body.Substring(1)}
[IO.File]::WriteAllText($victim,$body,[Text.UTF8Encoding]::new($false))
$console=@(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $copy 'teams_receiver.ps1') -Listen -Continuous 2>&1|ForEach-Object{[string]$_})
$code=$LASTEXITCODE
Check ($code -eq 1 -and ($console -join "`n") -match 'teams_receiver_commands\.ps1：缺少 UTF-8 BOM') 'a script that lost its BOM stops the start and is named with its cause'
$beat=Read-E3WorkJson (Join-Path $copy 'logs\teams_receiver\heartbeat.json')
$health=Get-E3ReceiverHealth $beat ([DateTimeOffset]::UtcNow) 10 {param($h) $false}
Check ($beat.fatal -eq $true -and $health.kind -eq 'fatal' -and $health.reason -match '程式檔損壞' -and $health.reason -match 'teams_receiver_commands\.ps1') 'the watchdog sees the cause and does not restart in a loop'
Check ((Get-E3ReceiverRestartPlan $health @() ([DateTimeOffset]::UtcNow)).action -eq 'none') 'a damaged-file stop is not auto-restarted'
"PASS $passed checks. Fixture: $fixture"
