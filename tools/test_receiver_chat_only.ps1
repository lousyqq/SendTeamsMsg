# Isolated tests of the receiver's chat-only checks: reading and switching use the saved chat ID
# and name without the per-read account proof, opening a chat does not wait for the avatar, and
# the full account check is still used everywhere else. Uses the real adapter / runtime scripts on
# a fixture page in a temporary headless Edge; no Teams navigation, sign-in or send.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path $env:TEMP ('E3ChatOnly_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
. (Join-Path $root 'teams_receiver.ps1') -LibraryOnly
$script:E3CdpLogRoot=Join-Path $fixture 'logs'
$script:E3WorkControlRoot=Join-Path $fixture 'work'
$passed=0
function Check([bool]$ok,[string]$name){if(-not $ok){throw "FAIL $name"};$script:passed++;Write-Host "PASS $name"}
$binding=[pscustomobject]@{accountId='user@corp.example';chatId='19:fixture@thread.v2';label='Fixture Chat';groupReport=$true;isSelf=$false}
$target=[pscustomobject]@{route='Fixture';targetId='TAB';binding=$binding}

# ---- A. The chat-only binding ----
$c=Get-E3ChatOnlyBinding $target
Check ($null -eq $c.PSObject.Properties['groupReport'] -and $c.accountId -eq 'user@corp.example' -and $c.chatId -eq '19:fixture@thread.v2' -and $c.label -eq 'Fixture Chat') 'chat-only binding drops only the per-read account flag'
$h=Get-E3ChatOnlyBinding ([pscustomobject]@{binding=@{accountId='a';chatId='19:x';label='L';groupReport=$true}})
Check ($null -eq $h.PSObject.Properties['groupReport'] -and $h.chatId -eq '19:x') 'works for a hashtable binding too'
Check ($binding.groupReport -eq $true) 'the saved binding itself is not changed'
foreach($file in 'receiver-snapshot.js','receiver-switch.js'){
    $src=Get-E3ReceiverScript $file $target
    Check ($src -notmatch 'groupReport' -and $src -match [regex]::Escape('"chatId":"19:fixture@thread.v2"')) "$file gets the chat-only binding"
}

# ---- B. Real adapter on a fixture chat ----
$teamsUrl='https://teams.cloud.microsoft/l/chat/19%3Afixture%40thread.v2/conversations'
$page=@'
document.body.innerHTML='<div data-tid="me-control-avatar-trigger" aria-label="User, Available"><span data-tid="me-control-avatar">U</span></div>'+
 '<div data-tid="chat-pane" data-chat-id="19:fixture@thread.v2"><div data-tid="chat-header" data-chat-id="19:fixture@thread.v2"><span data-tid="chat-header-title">Fixture Chat</span></div>'+
 '<div data-tid="ckeditor" contenteditable="true"></div></div>';
'@
$browser=$null
try{
    $browser=Start-E3TestBrowser (Join-Path $fixture 'profile') -Headless
    Invoke-E3Cdp 'Page.enable'|Out-Null
    $null=Invoke-E3Js $page
    foreach($file in 'vendor\adapter.js','vendor\outbound-images.js','receipt.js','runtime.js'){Invoke-E3Js (Get-E3CdpRuntimeSource $file)|Out-Null}
    function Inspect($b,[string]$url=$teamsUrl){return Invoke-E3Js ("(()=>{const r=BridgeAdapter.inspect(document,"+(ConvertTo-Json $url -Compress)+","+($b|ConvertTo-Json -Depth 8 -Compress)+");return r.ok?{ok:true,label:r.binding.label}:{ok:false,error:r.error};})()")}
    $full=Inspect $binding
    Check (-not $full.ok -and $full.error -eq 'GROUP_REPORT_ACCOUNT_NOT_VERIFIED') 'full binding without a fresh account proof is refused (the old read behaviour)'
    $chat=Inspect (Get-E3ChatOnlyBinding $target)
    Check ($chat.ok -and $chat.label -eq 'Fixture Chat') 'chat-only binding reads the same chat without the account proof'
    $null=Invoke-E3Js "document.querySelector('[data-tid=`"me-control-avatar-trigger`"]').setAttribute('aria-label','User, Away')"
    Check ((Inspect (Get-E3ChatOnlyBinding $target)).ok) 'a redrawn / changed avatar does not affect reading'
    $other=Get-E3ChatOnlyBinding ([pscustomobject]@{binding=[pscustomobject]@{accountId='user@corp.example';chatId='19:other@thread.v2';label='Fixture Chat'}})
    Check (-not (Inspect $other).ok) 'another chat ID is still refused'

    # ---- C. Waiting for the chat to load: no avatar ----
    $null=Invoke-E3Js "document.querySelector('[data-tid=`"me-control-avatar-trigger`"]').remove()"
    $nav=(Get-E3CdpRuntimeSource 'navigation.js').Replace("if(!['teams.cloud.microsoft','teams.microsoft.com'].includes(location.hostname))return {stage:'redirect'};",'')
    $nav=$nav.Replace('/*E3_LABEL*/null','"Fixture Chat"').Replace('/*E3_CHAT_ID*/null','"19:fixture@thread.v2"')
    Check (([regex]::Matches($nav,[regex]::Escape('/*E3_REQUIRE_ACCOUNT*/true'))).Count -eq 1) 'navigation script has the account switch'
    $strict=Invoke-E3Js $nav
    Check ($strict.stage -eq 'wait_account' -and $strict.profileCount -eq 0) 'scheduled sending still waits for the avatar'
    $relaxed=Invoke-E3Js ($nav.Replace('/*E3_REQUIRE_ACCOUNT*/true','false'))
    Check ($relaxed.ready -eq $true) 'receiver: the chat counts as loaded without the avatar'

    # ---- D. Connect-E3CdpTarget -ChatOnly uses no account flyout ----
    $null=Invoke-E3Js "document.querySelector('[data-tid=`"chat-header-title`"]').textContent='Fixture Chat'"
    # The fixture lives on about:blank; present the Teams address to the chat check.
    $realJs=${function:Invoke-E3Js}
    function Invoke-E3Js($expression,[int]$context,[int]$TimeoutMs=15000){return & $realJs (([string]$expression).Replace('location.href',(ConvertTo-Json $teamsUrl -Compress))) $context $TimeoutMs}
    function Connect-E3CdpPageContext($session,$target){return @{context=0;runtime=@{exists=$true;version='2026-11-12-history1'}}}
    function Update-E3CdpReceiptRuntime([int]$context){}
    $script:selfBinding=0
    function Get-E3SelfBinding([int]$context,[switch]$AllowGroup){$script:selfBinding++;return @{ok=$false;error='ACCOUNT_PROFILE_AMBIGUOUS'}}
    $null=Connect-E3CdpTarget @{} $target -ChatOnly
    Check ($script:selfBinding -eq 0) 'chat-only connect succeeds without opening the account menu'
    $r='';try{$null=Connect-E3CdpTarget @{} $target}catch{$r=$_.Exception.Message}
    Check ($script:selfBinding -eq 1 -and $r -match 'ACCOUNT_PROFILE_AMBIGUOUS') 'the normal connect (used before every reply) still verifies the account'
    $null=Invoke-E3Js "document.querySelector('[data-tid=`"chat-header-title`"]').textContent='Renamed'"
    $r='';try{$null=Connect-E3CdpTarget @{} $target -ChatOnly}catch{$r=$_.Exception.Message}
    Check ($r -match 'label 與保存的收件對象不同') 'chat-only connect still refuses a renamed chat'
}finally{
    if($script:CdpSocket){$script:CdpSocket.Dispose();$script:CdpSocket=$null}
    if($browser){Close-E3OwnedBrowser $browser 6>$null}
    $until=(Get-Date).AddSeconds(20)
    do{$alive=@(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'"|Where-Object{$_.CommandLine -like "*$fixture*"}|Where-Object{Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue});if(-not $alive.Count){break};Start-Sleep -Milliseconds 500}while((Get-Date) -lt $until)
    Remove-Item $fixture -Recurse -Force -ErrorAction SilentlyContinue
}
Check (-not $alive.Count) 'the test Edge is closed afterwards'
"PASS $passed checks."
