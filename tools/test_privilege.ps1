# Isolated tests of the run-rights comparison between the receiver and the watchdog task:
# detection, the comparison text, the heartbeat / watchdog records, the status line, the settings
# overview and the restart-failure hint. Temporary folders and stand-ins only; no Teams send,
# no process is ended and no Windows task is changed.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path $env:TEMP ('E3Privilege_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
. (Join-Path $root 'teams_receiver.ps1') -LibraryOnly
$script:E3WatchdogLogRoot=Join-Path $fixture 'logs'
$script:E3CdpLogRoot=Join-Path $fixture 'logs\teams_receiver'
$script:E3WorkControlRoot=Join-Path $fixture 'work'
[void][IO.Directory]::CreateDirectory($script:E3CdpLogRoot)
$passed=0
function Check([bool]$ok,[string]$name){if(-not $ok){throw "FAIL $name"};$script:passed++;Write-Host "PASS $name"}

# ---- A. Detection and comparison ----
$me=Test-E3ProcessElevated
Check ($me -is [bool]) "this process reports its rights ($me)"
Check ((Get-E3PrivilegeComparison $true @{elevated=$false}).mismatch) 'receiver admin, watchdog normal: mismatch'
Check ((Get-E3PrivilegeComparison $true @{elevated=$false}).text -match '無法結束它，自動重新啟動會失敗') 'mismatch text says what breaks and what to do'
Check ((Get-E3PrivilegeComparison $true @{elevated=$true}).text -eq '一致（皆為系統管理員權限）' -and (Get-E3PrivilegeComparison $false @{elevated=$false}).text -eq '一致（皆為一般權限）') 'same rights: consistent'
$c=Get-E3PrivilegeComparison $false @{elevated=$true}
Check (-not $c.mismatch -and $c.text -match '不影響') 'watchdog with more rights is not a problem'
Check ((Get-E3PrivilegeComparison $null @{elevated=$false}).text -match '接收端尚未回報' -and (Get-E3PrivilegeComparison $true $null).text -match '監看任務尚未回報') 'unknown sides are said plainly'

# ---- B. Status reply line ----
Write-E3WorkJson (Join-Path $script:E3CdpLogRoot 'watchdog_privilege.json') @{elevated=$false;utc=[DateTimeOffset]::UtcNow.ToString('O')}
$script:E3ReceiverElevated=$true
$cfg=[pscustomobject]@{teams=[pscustomobject]@{prefer_window='cdp';target_chat_name='自己'};schedules=@();pages=@()}
$lines=@(Get-E3ReceiverHealthLines $cfg @() 'Me')
Check (@($lines|Where-Object{$_ -match '^執行權限：⚠ 接收端是系統管理員權限'}).Count -eq 1) 'status reply shows the mismatch'
$script:E3ReceiverElevated=$false
Check (@(Get-E3ReceiverHealthLines $cfg @() 'Me'|Where-Object{$_ -eq '執行權限：一致（皆為一般權限）'}).Count -eq 1) 'status reply shows consistent rights'

# ---- C. Settings page overview ----
Write-E3WorkJson (Join-Path $script:E3CdpLogRoot 'heartbeat.json') @{version=2;state='listening';pid=$PID;processStart='0';utc=[DateTimeOffset]::UtcNow.ToString('O');startedUtc=[DateTimeOffset]::UtcNow.ToString('O');elevated=$true;sources=@()}
$o=Get-E3ReceiverOverview
Check ($o.privilege.mismatch -eq $true -and $o.privilege.receiver -eq $true -and $o.privilege.watchdog -eq $false) 'overview carries both sides and the mismatch'
Write-E3WorkJson (Join-Path $script:E3CdpLogRoot 'heartbeat.json') @{version=2;state='listening';pid=$PID;processStart='0';utc=[DateTimeOffset]::UtcNow.ToString('O');sources=@()}
Check ((Get-E3ReceiverOverview).privilege.text -match '接收端尚未回報') 'an older receiver without the field is reported as unknown'
Check ($null -eq (Get-E3ReceiverOverview).heartbeat.reloadMinutes) 'an older receiver has no reload interval in the overview'
# The heartbeat also carries the page reload interval in effect (read once at start).
$script:E3ReceiverContinuous=$true;$script:E3ReceiverReloadMinutes=0;$script:E3ReceiverHeartbeatAt=$null
Save-E3ReceiverHeartbeat @() 'listening' -Force
Check ((Read-E3WorkJson (Join-Path $script:E3CdpLogRoot 'heartbeat.json')).reloadMinutes -eq 0 -and (Get-E3ReceiverOverview).heartbeat.reloadMinutes -eq 0) 'heartbeat and overview carry the reload interval (0 = only on failure)'

# ---- D. Watchdog run: records its rights; a failed restart explains the mismatch ----
Remove-Item (Join-Path $script:E3CdpLogRoot 'watchdog_privilege.json') -Force
# A receiver that ran with administrator rights and is gone (no such PID).
Write-E3WorkJson (Join-Path $script:E3CdpLogRoot 'heartbeat.json') @{version=2;state='listening';pid=999999;processStart='1';utc=[DateTimeOffset]::UtcNow.AddMinutes(-30).ToString('O');startedUtc=[DateTimeOffset]::UtcNow.AddHours(-2).ToString('O');elevated=$true;sources=@()}
function Test-E3ProcessElevated{return $false}
function Start-E3ReceiverAutoRestart($hb,[string]$action){throw 'Access is denied'}
$script:sent=@()
function Send-GroupToTeams{param($targetChatName,$imageFiles,$messageText,$teamsCfg,$isDryRun) $script:sent+=$messageText}
$code=Invoke-E3ReceiverWatchdog $cfg 0 6>$null
$wd=Read-E3WorkJson (Join-Path $script:E3CdpLogRoot 'watchdog_privilege.json')
Check ($wd.elevated -eq $false -and $wd.utc) 'the watchdog records its own rights on every run'
Check ($script:sent.Count -eq 1 -and $script:sent[0] -match '自動重新啟動失敗：Access is denied' -and $script:sent[0] -match '監看任務權限較低，無法結束它') 'a failed restart notice explains the rights mismatch'
Remove-Item $fixture -Recurse -Force -ErrorAction SilentlyContinue
"PASS $passed checks."
