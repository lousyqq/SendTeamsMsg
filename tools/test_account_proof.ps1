# Isolated tests of the Teams account re-verification (GROUP_REPORT_ACCOUNT_NOT_VERIFIED):
# the receiver read, the in-chat switch and the pre-delivery checks recover at most once,
# and only after the same account / chat / name is proven again. Every browser call is a
# stand-in; no Edge, Teams, send or file outside a temporary folder.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path $env:TEMP ('E3AccountProof_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
. (Join-Path $root 'teams_receiver.ps1') -LibraryOnly
$script:E3CdpLogRoot=Join-Path $fixture 'logs'
$script:E3WorkControlRoot=Join-Path $fixture 'work'
$passed=0
function Check([bool]$ok,[string]$name){if(-not $ok){throw "FAIL $name"};$script:passed++;Write-Host "PASS $name"}
$binding=[pscustomobject]@{accountId='acc';chatId='19:chat';label='Chat'}
$target=[pscustomobject]@{route='Chat';targetId='TAB';binding=$binding}
$realRestore=${function:Restore-E3CdpAccountProof}

# ---- A. Restore-E3CdpAccountProof itself ----
$script:jsStage='idle';$script:bindResult=@{ok=$true;binding=[pscustomobject]@{accountId='acc';chatId='19:chat';label='Chat'}}
function Invoke-E3Js($expression,[int]$context,[int]$TimeoutMs){if($expression -eq 'E3Cdp.status()'){return @{stage=$script:jsStage}};throw "unexpected script: $expression"}
function Get-E3SelfBinding([int]$context,[switch]$AllowGroup){return $script:bindResult}
$script:E3SendNetwork=$null
$null=Restore-E3CdpAccountProof $target 1 6>$null
Check $true 'same account, chat and name: verification is restored'
$script:bindResult=@{ok=$true;binding=[pscustomobject]@{accountId='other';chatId='19:chat';label='Chat'}}
$r='';try{Restore-E3CdpAccountProof $target 1}catch{$r=$_.Exception.Message}
Check ($r -match 'accountId 與原綁定不符') 'another account is refused'
$script:bindResult=@{ok=$true;binding=[pscustomobject]@{accountId='acc';chatId='19:chat';label='Renamed'}}
$r='';try{Restore-E3CdpAccountProof $target 1}catch{$r=$_.Exception.Message}
Check ($r -match 'label 與原綁定不符') 'a renamed chat is refused'
$script:bindResult=@{ok=$false;error='ACCOUNT_PROFILE_AMBIGUOUS'}
$r='';try{Restore-E3CdpAccountProof $target 1}catch{$r=$_.Exception.Message}
Check ($r -match '重新驗證失敗：ACCOUNT_PROFILE_AMBIGUOUS') 'a failed verification keeps its reason'
$script:bindResult=@{ok=$true;binding=$binding};$script:jsStage='sending'
$r='';try{Restore-E3CdpAccountProof $target 1}catch{$r=$_.Exception.Message}
Check ($r -match '仍有 Teams 工作') 'never while a Teams job is running'
$script:jsStage='idle';$script:E3SendNetwork=@{}
$r='';try{Restore-E3CdpAccountProof $target 1}catch{$r=$_.Exception.Message}
Check ($r -match '傳送期間不能重新驗證') 'never during a delivery'
$script:E3SendNetwork=$null

# ---- B. Receiver read: one recovery, then stop ----
$script:restores=0
function Restore-E3CdpAccountProof($target,[int]$context){$script:restores++}
$script:reads=@()
function Read-E3ReceiverSnapshot($target,[int]$context){$next=$script:reads[0];$script:reads=@($script:reads|Select-Object -Skip 1);return $next}
$lost=@{ok=$false;error='GROUP_REPORT_ACCOUNT_NOT_VERIFIED'};$good=@{ok=$true;latest=$true;commands=@()}
$script:reads=@($lost,$good)
$s=Read-E3ReceiverSettled $target 1 2000
Check ($s.ok -and $script:restores -eq 1) 'read: lost proof is restored once and reading continues'
$script:restores=0;$script:reads=@($lost,$lost)
$r='';try{$null=Read-E3ReceiverSettled $target 1 2000}catch{$r=$_.Exception.Message}
Check ($r -match '重新驗證後仍失效' -and $script:restores -eq 1) 'read: still lost after re-verification stops this read'
$script:restores=0;$script:reads=@($lost,@{ok=$true;latest=$false},$lost,$good)
$r='';try{$null=Read-E3ReceiverSettled $target 1 3000}catch{$r=$_.Exception.Message}
Check ($r -match '反覆失效' -and $script:restores -eq 1) 'read: losing it again in the same read is not retried a second time'

# ---- C. In-chat switch ----
$script:E3ReceiverTab=@{ready=$true;context=7;chatId='19:chat';session=@{};tabId='TAB'}
$script:switch=@()
function Invoke-E3Js($expression,[int]$context,[int]$TimeoutMs){$next=$script:switch[0];$script:switch=@($script:switch|Select-Object -Skip 1);return $next}
function Get-E3ReceiverTabList($session){throw 'REOPEN'}
$src=@{target=$target}
$script:restores=0;$script:switch=@(@{ok=$false;reauth=$true},@{ok=$true;ready=$true})
$ctx=Open-E3ReceiverChat $src
Check ($ctx -eq 7 -and $script:restores -eq 1) 'switch: the same chat is re-verified in place once'
$script:restores=0;$script:switch=@(@{ok=$false;reauth=$true},@{ok=$false;reauth=$true})
$r='';try{$null=Open-E3ReceiverChat $src}catch{$r=$_.Exception.Message}
Check ($r -match 'E3_RECEIVER_SOURCE：Teams 帳號驗證反覆失效' -and $script:restores -eq 1) 'switch: losing it twice stops with the reason'
$script:E3ReceiverTab.chatId='19:other';$script:restores=0;$script:switch=@(@{ok=$false;reauth=$true})
$r='';try{$null=Open-E3ReceiverChat $src}catch{$r=$_.Exception.Message}
Check ($r -match 'REOPEN' -and $script:restores -eq 0) 'switch: a different chat is not re-verified in place; it reopens with full checks'

# ---- D. Pre-delivery checks ----
$script:prep=@()
function Invoke-E3Js($expression,[int]$context,[int]$TimeoutMs){$next=$script:prep[0];$script:prep=@($script:prep|Select-Object -Skip 1);return $next}
$used=$false;$script:restores=0;$script:prep=@(@{ok=$false;accountProofLost=$true},[pscustomobject]@{ok=$true;pendingRows=0})
$res=Invoke-E3PreparationCheck $target 1 'check' ([ref]$used)
Check ($res.ok -and $res.accountProofRefreshed -and $used -and $script:restores -eq 1) 'delivery check: recovered once and marked as refreshed'
$script:prep=@(@{ok=$false;accountProofLost=$true})
$r='';try{$null=Invoke-E3PreparationCheck $target 1 'check' ([ref]$used)}catch{$r=$_.Exception.Message}
Check ($r -match '反覆失效' -and $r -match '未貼圖、未送出') 'delivery check: a second loss in the same delivery stops before pasting'
$used=$false;$script:restores=0;$script:prep=@(@{ok=$false;reason='收件帳號或對話不符'})
$res=Invoke-E3PreparationCheck $target 1 'check' ([ref]$used)
Check (-not $res.ok -and $script:restores -eq 0 -and -not $used) 'delivery check: other failures are not treated as a lost proof'
Set-Item function:Restore-E3CdpAccountProof $realRestore
Remove-Item $fixture -Recurse -Force -ErrorAction SilentlyContinue
"PASS $passed checks."
