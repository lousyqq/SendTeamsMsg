# Real Edge layout tests of the receiver reader; only the identity adapter boundary is a
# fixture. No Teams navigation, credentials, sends or task changes.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path $env:TEMP ('E3ReceiverLatest_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
. (Join-Path $root 'teams_receiver.ps1') -LibraryOnly
$script:E3CdpLogRoot=Join-Path $fixture 'logs'
$script:E3WorkControlRoot=Join-Path $fixture 'work'
$binding=@{accountId='fixture';chatId='48:fixture';label='fixture'}
$target=@{route='fixture';binding=$binding}
$source=Get-E3ReceiverScript 'receiver-snapshot.js' $target
$browser=$null;$passed=0
function Check([bool]$ok,[string]$name){if(-not $ok){throw "FAIL $name"};$script:passed++;Write-Host "PASS $name"}
try {
    $browser=Start-E3TestBrowser (Join-Path $fixture 'profile') -Headless
    $fixtureScript=@'
globalThis.resetFixture=(kind='normal')=>{
document.body.innerHTML=`<style>#pane{width:400px}#viewport{height:200px;overflow-y:auto;scroll-behavior:smooth}.row{height:100px;flex-shrink:0}#outside{height:50px;overflow:auto}</style><div id="outside"><div style="height:400px">unrelated sidebar</div></div><div id="pane" data-tid="chat-pane"><div id="viewport" data-tid="message-pane-list-viewport"></div><div contenteditable="true" id="editor">keep draft</div><button id="send">send</button></div>`;
const viewport=document.getElementById('viewport');
if(kind==='reverse')viewport.style.cssText='display:flex;flex-direction:column-reverse';
let host=viewport;
if(kind==='nested'){viewport.removeAttribute('data-tid');host=document.createElement('div');host.setAttribute('data-tid','chat-message-list');viewport.append(host);}
globalThis.addRow=(id,text,stamp='2026-11-11T08:08:00Z')=>{const row=document.createElement('div');row.className='row';row.dataset.messageId=id;if(stamp)row.dataset.timestamp=stamp;const body=document.createElement('div');body.setAttribute('data-tid','message-body');body.textContent=text;row.append(body);host.append(row);return row;};
for(let i=0;i<10;i++)addRow('m'+i,i===9?'@日管 狀態':'fixture history');
document.getElementById('outside').scrollTop=100;
globalThis.badIdentity=false;globalThis.sendCount=0;globalThis.jumpCount=0;
document.getElementById('send').onclick=()=>sendCount++;
globalThis.BridgeAdapter={
  inspect:()=>badIdentity?{ok:false,error:'binding mismatch'}:{ok:true,root:document.getElementById('pane'),binding:{accountId:'fixture',chatId:'48:fixture',label:'fixture'}},
  sameBinding:(a,b)=>!!a&&a.accountId===b.accountId&&a.chatId===b.chatId,
  snapshot:()=>{throw Error('receiver called the strict shared reader')},
  followLatest:()=>{throw Error('receiver called old history follower')},
  atLatest:()=>{throw Error('receiver called old bottom detector')}
};
delete globalThis.__E3ReceiverViewport;
viewport.scrollTo({top:kind==='reverse'?-300:300,behavior:'instant'});
return true;
};
globalThis.toBottom=()=>{document.getElementById('viewport').scrollTo({top:100000,behavior:'instant'});return true;};
true;
'@
    Invoke-E3Js $fixtureScript|Out-Null
    foreach($kind in @('normal','reverse','nested')){
        Invoke-E3Js "resetFixture('$kind')"|Out-Null
        $first=Invoke-E3Js $source
        Check ($first.ok -and -not $first.latest -and @($first.commands).Count -eq 0) "$kind waits after forced scroll"
        $second=Invoke-E3Js $source
        Check ($second.ok -and $second.latest -and @($second.commands).Count -eq 1 -and $second.viewport.distance -le 2) "$kind reaches live edge"
        $stable=$true
        for($i=0;$i -lt 10;$i++){$poll=Invoke-E3Js $source;if(-not $poll.latest -or $poll.viewport.top -ne $second.viewport.top){$stable=$false}}
        Check $stable "$kind repeated reads never move upward"
        Check (Invoke-E3Js "sendCount===0&&document.getElementById('editor').textContent==='keep draft'&&document.getElementById('outside').scrollTop===100") "$kind leaves send, draft and sidebar alone"
    }
    Invoke-E3Js "resetFixture();toBottom();const b=document.createElement('button');b.dataset.tid='jump-to-latest';b.style.display='none';b.onclick=()=>jumpCount++;document.getElementById('pane').append(b);true"|Out-Null
    $read=Invoke-E3Js $source
    Check ($read.latest -and (Invoke-E3Js 'jumpCount===0')) 'hidden latest button does not block or get clicked'
    Invoke-E3Js "document.querySelector('[data-tid=jump-to-latest]').style.display='block';document.querySelector('[data-tid=jump-to-latest]').onclick=function(){jumpCount++;this.remove()};true"|Out-Null
    $read=Invoke-E3Js $source
    Check (-not $read.latest -and @($read.commands).Count -eq 0) 'visible jump waits for another read'
    $read=Invoke-E3Js $source
    Check ($read.latest -and (Invoke-E3Js 'jumpCount===1&&sendCount===0')) 'only latest button clicked once'
    Invoke-E3Js "const grow=document.createElement('button');grow.dataset.tid='jump-to-latest';grow.onclick=function(){const v=document.getElementById('viewport');v.firstChild.style.height='500px';v.scrollTo({top:v.scrollHeight,behavior:'instant'});this.remove()};document.getElementById('pane').append(grow);delete globalThis.__E3ReceiverViewport;true"|Out-Null
    $read=Invoke-E3Js $source
    Check (-not $read.latest -and (Invoke-E3Js "(()=>{const v=document.getElementById('viewport');return Math.abs(v.scrollHeight-v.clientHeight-v.scrollTop)<=2})()")) 'jump that grows history never restores an old upward offset'
    Invoke-E3Js "document.querySelector('.row').style.height='700px';true"|Out-Null
    $read=Invoke-E3Js $source
    $settled=Invoke-E3Js $source
    Check ($settled.latest -and $settled.viewport.distance -le 2) 'late image layout growth returns to bottom'
    Invoke-E3Js "resetFixture();badIdentity=true;true"|Out-Null
    $read=Invoke-E3Js $source
    Check (-not $read.ok -and (Invoke-E3Js "document.getElementById('viewport').scrollTop===300&&sendCount===0")) 'wrong binding cannot scroll or send'
    Invoke-E3Js "resetFixture();document.getElementById('pane').append(document.getElementById('viewport').cloneNode(true));true"|Out-Null
    $read=Invoke-E3Js $source
    Check (-not $read.ok -and $read.error -match '唯一') 'ambiguous message viewports are rejected'

    # Rows the reader cannot parse are skipped; they never silence the chat or become commands.
    Invoke-E3Js "resetFixture();const card=document.createElement('div');card.className='row';card.dataset.messageId='card';card.dataset.timestamp='2026-11-11T08:09:00Z';card.textContent='call ended';document.getElementById('viewport').append(card);addRow('notime','@日管 狀態','');addRow('localtime','@日管 狀態','2026-11-11 08:09');addRow('good','@日管 截圖清單','2026-11-11T08:10:00Z');toBottom()"|Out-Null
    $read=Invoke-E3Js $source
    Check ($read.ok -and $read.latest -and $read.skipped -eq 3 -and @($read.commands).Count -eq 2 -and @($read.commands|Where-Object{$_.id -eq 'good'}).Count -eq 1) 'unreadable rows are skipped, readable commands still found'
    Check (-not @($read.commands|Where-Object{$_.id -in @('card','notime','localtime')}).Count) 'row without body or full timestamp never becomes a command'
    Invoke-E3Js "resetFixture();addRow('m9','@日管 狀態');toBottom()"|Out-Null
    $read=Invoke-E3Js $source
    Check ($read.ok -and $read.latest -and @($read.commands).Count -eq 0 -and $read.skipped -eq 2) 'duplicate message ids are skipped, not executed'
    Invoke-E3Js "resetFixture();toBottom();document.querySelector('[data-message-id=m9]').dataset.status='sending';true"|Out-Null
    $read=Invoke-E3Js $source
    Check ($read.latest -and @($read.commands).Count -eq 0) 'pending command excluded'
    Invoke-E3Js "document.querySelector('[data-message-id=m9]').dataset.status='';document.querySelector('[data-message-id=m9] [data-tid=message-body]').append(document.createElement('img'));true"|Out-Null
    $read=Invoke-E3Js $source
    Check ($read.latest -and @($read.commands).Count -eq 0) 'image command excluded'
    Invoke-E3Js "document.querySelector('[data-message-id=m9] img').className='emoji';true"|Out-Null
    $read=Invoke-E3Js $source
    Check ($read.latest -and @($read.commands).Count -eq 1) 'emoji picture does not hide a text command'
    Invoke-E3Js "document.querySelector('[data-message-id=m9]').insertAdjacentHTML('beforeend','<blockquote>quoted</blockquote>');true"|Out-Null
    $read=Invoke-E3Js $source
    Check ($read.latest -and @($read.commands).Count -eq 0) 'quoted command excluded'
    Invoke-E3Js "resetFixture();toBottom();document.querySelector('[data-message-id=m9] [data-tid=message-body]').textContent='請 @日管 狀態';true"|Out-Null
    $read=Invoke-E3Js $source
    Check ($read.latest -and @($read.commands).Count -eq 0) 'message that only mentions the keyword is not a command'

    # Read-E3ReceiverSettled waits for the page instead of treating "not at newest yet" as a failure.
    Invoke-E3Js "resetFixture()"|Out-Null
    $settled=Read-E3ReceiverSettled $target 0 4000
    Check ($settled.ok -and $settled.latest -and @($settled.commands).Count -eq 1) 'settled read waits through the scroll to the newest message'
    Invoke-E3Js "resetFixture();badIdentity=true;true"|Out-Null
    $failure=''
    try{$null=Read-E3ReceiverSettled $target 0 1200}catch{$failure=$_.Exception.Message}
    Check ($failure -match '綁定不一致|binding mismatch') 'settled read reports the page reason after its time limit'

    $now=[DateTimeOffset]::UtcNow
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $snap=@{ok=$true;latest=$true;ids=@('fresh');commands=@(@{id='fresh';time=$now.AddSeconds(1).ToString('O');text='@日管 狀態'})}
    Check ($null -eq (Select-E3ReceiverCommand $snap $binding $now $null $seen)) 'first snapshot cannot execute a command'
    $prior=@{ok=$true;latest=$true;ids=@('fresh');commands=@($snap.commands)}
    $selected=Select-E3ReceiverCommand $snap $binding $now $prior $seen
    Check ($null -ne $selected) 'same new command in two stable snapshots can be selected'
    [void]$seen.Add($selected.key)
    Check ($null -eq (Select-E3ReceiverCommand $snap $binding $now $prior $seen)) 'seen command is not selected again'
    $snap.commands[0].time=$now.AddSeconds(-1).ToString('O');$prior.commands=@($snap.commands)
    Check ($null -eq (Select-E3ReceiverCommand $snap $binding $now $prior ([Collections.Generic.HashSet[string]]::new()))) 'startup-old command is excluded'
    "PASS $passed checks. Fixture: $fixture"
} finally {if($browser){Close-E3TestBrowser $browser}}
