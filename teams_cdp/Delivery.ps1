# E3 Teams CDP — pending2 recovery preserves old receipts and verifies new-delivery readiness; browser runtime receipt2 supports image-only messages and stable receipt reconciliation.
# Production entry points: Set-E3CdpBinding, Test-E3CdpConnection, Send-GroupToTeamsCdp.
# Dot-sourcing only defines functions and loads the shared batching helper; no browser or send.
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'teams_delivery.ps1')
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'work_control.ps1')
 
#region Transport
# Shared transport. Import has no browser, network or send side effects.
$script:E3CdpLogRoot=Join-Path (Split-Path $PSScriptRoot -Parent) 'logs'
$script:CdpSocket=$null
$script:CdpId=0
$script:E3SendNetwork=$null
$script:CdpEndpoint=$null
$script:E3CdpLastCommand=$null
function Get-E3LocalJson([string]$url) {
    $req=[Net.HttpWebRequest]::Create($url); $req.Proxy=$null; $req.Timeout=1500; $req.ReadWriteTimeout=1500
    $res=$req.GetResponse()
    try {$reader=[IO.StreamReader]::new($res.GetResponseStream()); try{return ($reader.ReadToEnd()|ConvertFrom-Json)}finally{$reader.Dispose()}}finally{$res.Dispose()}
}
function Connect-E3Cdp([string]$url,[ValidateRange(250,60000)][int]$TimeoutMs=10000) {
    $u=[Uri]$url
    if($u.Scheme -ne 'ws' -or $u.Host -notin @('127.0.0.1','localhost')){throw '拒絕非本機 CDP 位址'}
    if($script:CdpSocket){$script:CdpSocket.Dispose()}
    $script:CdpSocket=[Net.WebSockets.ClientWebSocket]::new()
    $script:CdpEndpoint=$null
    $cancel=[Threading.CancellationTokenSource]::new(); $cancel.CancelAfter($TimeoutMs)
    try{$script:CdpSocket.ConnectAsync($u,$cancel.Token).GetAwaiter().GetResult()|Out-Null;$script:CdpEndpoint=$url}
    catch{throw "CDP_CONNECT_FAILED：無法連接原專用 Edge（等待 $TimeoutMs ms）；$($_.Exception.GetBaseException().Message)"}
    finally{$cancel.Dispose()}
}
function Invoke-E3Cdp([string]$method,[hashtable]$parameters=@{},[ValidateRange(250,60000)][int]$TimeoutMs=10000,[string]$SessionId='') {
    $id=++$script:CdpId
    $cancel=[Threading.CancellationTokenSource]::new();$cancel.CancelAfter($TimeoutMs)
    $script:E3CdpLastCommand=@{method=$method;phase='send';timeoutMs=$TimeoutMs;status='running';utc=[DateTime]::UtcNow.ToString('o')}
    try {
        if(-not $script:CdpSocket -or $script:CdpSocket.State -ne [Net.WebSockets.WebSocketState]::Open){throw 'CDP_CLOSED：專用連線已失效'}
        $command=@{id=$id;method=$method;params=$parameters}
        if($SessionId){$command.sessionId=$SessionId}
        $payload=[Text.Encoding]::UTF8.GetBytes(($command|ConvertTo-Json -Depth 40 -Compress))
        $script:CdpSocket.SendAsync([ArraySegment[byte]]::new($payload),[Net.WebSockets.WebSocketMessageType]::Text,$true,$cancel.Token).GetAwaiter().GetResult()|Out-Null
        $script:E3CdpLastCommand.phase='receive'
        while($true) {
            $stream=[IO.MemoryStream]::new()
            try {
                do {
                    $buf=New-Object byte[] 32768
                    $received=$script:CdpSocket.ReceiveAsync([ArraySegment[byte]]::new($buf),$cancel.Token).GetAwaiter().GetResult()
                    if($received.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close){throw 'CDP 連線已關閉'}
                    $stream.Write($buf,0,$received.Count)
                    if($stream.Length -gt 2MB){throw 'CDP 回應超過上限'}
                }while(-not $received.EndOfMessage)
                $value=[Text.Encoding]::UTF8.GetString($stream.ToArray())|ConvertFrom-Json
            }finally{$stream.Dispose()}
            if($value.id -eq $id){if($value.error){throw "CDP $method : $($value.error.message)"};$script:E3CdpLastCommand.status='ok';return $value.result}
            if($script:E3SendNetwork){
                if($value.method -like 'Network.*'){Receive-E3SendNetwork $value ([string]$value.sessionId)}
                elseif($value.method -eq 'Target.attachedToTarget'){
                    $info=$value.params.targetInfo
                    if($info.type -in @('worker','shared_worker','service_worker') -and $script:E3SendNetwork.workers.Count -lt 32){
                        $sid=[string]$value.params.sessionId
                        $script:E3SendNetwork.workers[$sid]=@{type=[string]$info.type;enabled=$false;attempted=$false;error=''}
                    }
                }
                elseif($value.method -eq 'Target.detachedFromTarget'){$script:E3SendNetwork.workers.Remove([string]$value.params.sessionId)}
            }
        }
    }catch{
        $script:E3CdpLastCommand.status='failed'
        $script:E3CdpLastCommand.socketState=if($script:CdpSocket){[string]$script:CdpSocket.State}else{'None'}
        if($cancel.IsCancellationRequested){throw "CDP_TIMEOUT：$method 等待 $TimeoutMs ms 逾時；階段=$($script:E3CdpLastCommand.phase)；連線=$($script:E3CdpLastCommand.socketState)"}
        throw "CDP_COMMAND_FAILED：$method；階段=$($script:E3CdpLastCommand.phase)；$($_.Exception.GetBaseException().Message)"
    }finally{$cancel.Dispose()}
}
function Invoke-E3Js([string]$expression,[int]$context=0,[ValidateRange(250,60000)][int]$TimeoutMs=10000) {
    $p=@{expression=$expression;returnByValue=$true}
    if($context){$p.contextId=$context}
    $r=Invoke-E3Cdp 'Runtime.evaluate' $p -TimeoutMs $TimeoutMs
    if($r.exceptionDetails){throw "網頁程式錯誤：$($r.exceptionDetails.exception.description) $($r.exceptionDetails.text)"}
    return $r.result.value
}
function Test-E3MessageEndpoint([string]$url,[string]$chatId) {
    $u=$null
    if(-not [Uri]::TryCreate($url,[UriKind]::Absolute,[ref]$u)){return $false}
    if($u.Scheme -ne 'https' -or -not $u.IsDefaultPort -or $u.UserInfo){return $false}
    if($u.Host -notmatch '(^|\.)(teams\.microsoft\.com|teams\.cloud\.microsoft|msg\.skype\.com)$'){return $false}
    return [Uri]::UnescapeDataString($u.AbsolutePath).EndsWith('/conversations/'+$chatId+'/messages',[StringComparison]::Ordinal)
}
function Get-E3EndpointDiagnostic([string]$url,[string]$chatId) {
    $u=$null
    if(-not [Uri]::TryCreate($url,[UriKind]::Absolute,[ref]$u)){return @{host='';route='';classification='invalid_url'}}
    $path=[Uri]::UnescapeDataString($u.AbsolutePath)
    # Retain API route words only. Never log query strings, user/chat IDs or arbitrary path values.
    $safe=@($path.Split('/')|Where-Object{$_}|ForEach-Object{
        if($_ -match '^(v\d+(\.\d+)?|api|beta|chatsvc|chatservice|chat|chats|messages|message|users|me|conversations|teams|send|sendmessage|upload|uploads|files|objects|views|original|image|images|attachments|graphql|batch|events|telemetry|collector|amer|emea|apac|notification|notifications)$'){$_}else{'{value}'}
    })
    $reason='unsupported_message_path'
    if($u.Scheme -ne 'https' -or -not $u.IsDefaultPort -or $u.UserInfo){$reason='unsupported_origin'}
    elseif($u.Host -notmatch '(^|\.)(teams\.microsoft\.com|teams\.cloud\.microsoft|msg\.skype\.com)$'){$reason='unrecognized_host'}
    elseif(Test-E3MessageEndpoint $url $chatId){$reason='recognized'}
    elseif($path -match '/conversations/([^/]+)/messages/?$'){$reason=if($Matches[1] -ceq $chatId){'unsupported_path_suffix'}else{'different_chat_id'}}
    return @{host=$u.DnsSafeHost;route=('/'+($safe -join '/'));classification=$reason}
}
function Start-E3SendNetwork($target) {
    $workers=@{}
    if($script:E3SendNetwork -and $script:E3SendNetwork.workers){$workers=$script:E3SendNetwork.workers}
    $script:E3SendNetwork=$null
    Invoke-E3Cdp 'Network.enable' @{maxPostDataSize=65536;maxResourceBufferSize=262144;maxTotalBufferSize=1048576}|Out-Null
    $script:E3SendNetwork=@{armed=$false;chatId=[string]$target.binding.chatId;requests=@{};workers=$workers;workerObserverError=''}
    try{Invoke-E3Cdp 'Target.setAutoAttach' @{autoAttach=$true;waitForDebuggerOnStart=$false;flatten=$true}|Out-Null}
    catch{$script:E3SendNetwork.workerObserverError=$_.Exception.Message}
    Update-E3NetworkWorkers
}
function Update-E3NetworkWorkers {
    if(-not $script:E3SendNetwork){return}
    # Queue worker setup outside the receive loop so parent command replies are never consumed recursively.
    foreach($sid in @($script:E3SendNetwork.workers.Keys)){
        $worker=$script:E3SendNetwork.workers[$sid]
        if($worker.attempted){continue};$worker.attempted=$true
        try{
            Invoke-E3Cdp 'Network.enable' @{maxPostDataSize=65536;maxResourceBufferSize=262144;maxTotalBufferSize=1048576} -SessionId $sid|Out-Null
            $worker.enabled=$true
        }catch{$worker.error=$_.Exception.Message}
    }
}
function Get-E3WorkerSummary {
    if(-not $script:E3SendNetwork){return $null}
    return @{error=$script:E3SendNetwork.workerObserverError;workers=@($script:E3SendNetwork.workers.Values|ForEach-Object{@{type=$_.type;enabled=$_.enabled;error=$_.error}})}
}
function Receive-E3SendNetwork($event,[string]$SessionId='') {
    # Passive CDP observer. Never persist request bodies, cookies, headers or full URLs.
    $s=$script:E3SendNetwork;$p=$event.params;$key=$SessionId+':'+[string]$p.requestId
    if($event.method -eq 'Network.requestWillBeSent'){
        if($s.requests.ContainsKey($key)){$s.requests[$key].redirected=$true;return}
        if($p.request.method -notin @('POST','PUT','PATCH') -or $s.requests.Count -ge 128){return}
        $matched=$p.request.method -eq 'POST' -and (Test-E3MessageEndpoint ([string]$p.request.url) $s.chatId)
        $endpoint=Get-E3EndpointDiagnostic ([string]$p.request.url) $s.chatId
        if($p.request.method -ne 'POST'){$endpoint.classification='unsupported_method'}
        elseif($matched){$endpoint.classification=if($s.armed){'recognized'}else{'before_send_checkpoint'}}
        $clientId=''
        if($matched -and $p.request.postData){
            try{$body=ConvertFrom-Json -InputObject $p.request.postData -ErrorAction Stop;$clientId=[string]$body.clientmessageid}catch{}
        }
        $s.requests[$key]=@{requestId=[string]$p.requestId;sessionId=$SessionId;source=$(if($SessionId){'worker'}else{'page'});sequence=($s.requests.Count+1);method=[string]$p.request.method;endpoint=$endpoint;observedAfterClickCheckpoint=[bool]$s.armed;hasPostData=[bool]$p.request.hasPostData;kind=$(if($matched){'message_send'}else{'other_post'});eligible=($matched -and $s.armed);clientId=$clientId;status=0;finished=$false;failed=$false;redirected=$false;cached=$false;read=$false;serverId='';error=''}
        return
    }
    if(-not $s.requests.ContainsKey($key)){return}
    $r=$s.requests[$key]
    switch($event.method){
        'Network.responseReceived' {
            $r.status=[int]$p.response.status
            $r.cached=[bool]($p.response.fromDiskCache -or $p.response.fromServiceWorker -or $p.response.fromPrefetchCache)
            if($r.kind -eq 'message_send' -and -not(Test-E3MessageEndpoint ([string]$p.response.url) $s.chatId)){$r.redirected=$true}
            # Teams can return the new resource ID via Location instead of a JSON body.
            if($r.eligible -and $p.response.headers.Location){
                $location=[string]$p.response.headers.Location
                $resourcePath=($location -split '[?#]',2)[0]
                $prefix='/conversations/'+$s.chatId+'/messages/'
                $decoded=[Uri]::UnescapeDataString($resourcePath)
                $index=$decoded.IndexOf($prefix,[StringComparison]::Ordinal)
                if($index -ge 0){$tail=$decoded.Substring($index+$prefix.Length);if($tail -match '^[A-Za-z0-9_-]{1,100}$'){$r.serverId=$tail}}
            }
        }
        'Network.loadingFinished' {$r.finished=$true}
        'Network.loadingFailed' {$r.failed=$true;$r.finished=$true;$r.error=[string]$p.errorText}
    }
}
function Get-E3ServerReceipt([string]$messageId) {
    $s=$script:E3SendNetwork
    if(-not $s){return @{ok=$false;reason='observer_not_started'}}
    foreach($r in @($s.requests.Values)){
        if(-not $r.eligible -or -not $r.finished -or $r.failed -or $r.cached -or $r.redirected -or $r.status -notin @(200,201)){continue}
        if(-not $r.read){
            $r.read=$true
            try {
                $response=Invoke-E3Cdp 'Network.getResponseBody' @{requestId=$r.requestId} -SessionId ([string]$r.sessionId)
                $raw=[string]$response.body
                if($response.base64Encoded){$raw=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($raw))}
                if($raw.Length -le 131072 -and $raw.Trim().StartsWith('{')){
                    $json=ConvertFrom-Json -InputObject $raw -ErrorAction Stop
                    if($json.error){$r.failed=$true;$r.error='server_error_body'}
                    elseif($json.id){$r.serverId=[string]$json.id}
                }
            }catch{$r.error='response_body_unavailable'}
        }
        # A numeric DOM ID, an empty editor or HTTP 202 alone is not a delivery receipt.
        if(-not $r.failed -and $r.serverId -and ($messageId -ceq $r.serverId -or ($r.clientId -and $messageId -ceq $r.clientId))){
            return @{ok=$true;reason='server_accepted';status=$r.status;messageId=$messageId;serverId=$r.serverId;serverAcceptanceObserved=$true;domMessageMatched=$true}
        }
    }
    $reason='server_ack_not_confirmed'
    if(@($s.requests.Values|Where-Object{$_.eligible -and ($_.failed -or $_.status -ge 400)}).Count){$reason='message_request_failed'}
    $accepted=@($s.requests.Values|Where-Object{$_.eligible -and $_.finished -and -not $_.failed -and -not $_.cached -and -not $_.redirected -and $_.status -in @(200,201) -and $_.serverId})
    if($accepted.Count -gt 0 -and $reason -ne 'message_request_failed'){$reason='server_accepted_dom_unmatched'}
    # Acceptance without matching DOM evidence never makes ok=true or permits a retry.
    return @{ok=$false;reason=$reason;serverAcceptanceObserved=($accepted.Count -gt 0);acceptedMessageIds=@($accepted|Select-Object -First 8|ForEach-Object{$_.serverId});domMessageMatched=$false}
}
function Get-E3NetworkSummary {
    if(-not $script:E3SendNetwork){return @()}
    return @($script:E3SendNetwork.requests.Values|Sort-Object { [int]$_.sequence }|ForEach-Object{@{source=$_.source;sequence=$_.sequence;method=$_.method;endpoint=$_.endpoint;observedAfterClickCheckpoint=$_.observedAfterClickCheckpoint;hasPostData=$_.hasPostData;kind=$_.kind;eligible=$_.eligible;status=$_.status;finished=$_.finished;failed=$_.failed;cached=$_.cached;redirected=$_.redirected;clientId=$_.clientId;serverId=$_.serverId;error=$_.error}})
}
function Enable-E3CdpBackgroundFocus {
    # Browser-level focus/visibility emulation; no Windows foreground or keyboard input.
    Invoke-E3Cdp 'Page.setWebLifecycleState' @{state='active'}|Out-Null
    Invoke-E3Cdp 'Emulation.setFocusEmulationEnabled' @{enabled=$true}|Out-Null
}
function Disable-E3CdpBackgroundFocus {
    if($script:CdpSocket -and $script:CdpSocket.State -eq [Net.WebSockets.WebSocketState]::Open){
        try{Invoke-E3Cdp 'Emulation.setFocusEmulationEnabled' @{enabled=$false}|Out-Null}
        catch{Write-Host '⚠️ 無法解除本次 CDP 焦點模擬；請檢查專用 Edge 連線' -ForegroundColor Yellow}
    }
}
function Assert-E3DebugPolicy {
    foreach($key in @('HKLM:\SOFTWARE\Policies\Microsoft\Edge','HKCU:\SOFTWARE\Policies\Microsoft\Edge')) {
        if(Test-Path -LiteralPath $key) {
            $p=Get-ItemProperty -LiteralPath $key
            if($p.PSObject.Properties.Name -contains 'RemoteDebuggingAllowed' -and [int]$p.RemoteDebuggingAllowed -eq 0){throw '公司原則禁止 Remote Debugging，未開啟瀏覽器；請交由 IT 核准'}
        }
    }
}
function Get-E3SelfBinding([int]$context,[switch]$AllowGroup) {
    # One synthetic profile click, bounded reads, strict original account/self proof.
    # The user can stay in PowerShell; no foreground activation or system input is needed.
    $token='bind-'+[guid]::NewGuid().ToString('N')
    $began=$false
    try {
        Invoke-E3Cdp 'Page.setWebLifecycleState' @{state='active'}|Out-Null
        $frame=Invoke-E3Js "globalThis[Symbol.for('d46518.teamsCodex.imageFrameProbe')]?.control('start','$token')"
        if(-not $frame.ok){return @{ok=$false;error='帳號選單背景處理初始化失敗，請關閉測試 Edge 後重開'}}
        $started=[DateTime]::UtcNow
        $begin=Invoke-E3Js 'E3Cdp.beginBinding()' $context
        $began=$true
        if(-not $begin.ok){return $begin}
        $last=$null
        do {
            $elapsed=[int]([DateTime]::UtcNow-$started).TotalMilliseconds
            Invoke-E3Js "globalThis[Symbol.for('d46518.teamsCodex.imageFrameProbe')]?.control('pulse','$token',$elapsed)"|Out-Null
            $allow=if($AllowGroup){'true'}else{'false'}
            $last=Invoke-E3Js "E3Cdp.bind($allow)" $context
            if($last.ok){return $last}
            Start-Sleep -Milliseconds 150
        }while(([DateTime]::UtcNow-$started).TotalSeconds -lt 10)
        return $last
    } finally {
        if($began){try{Invoke-E3Js 'E3Cdp.endBinding()' $context|Out-Null}catch{}}
        try{Invoke-E3Js "globalThis[Symbol.for('d46518.teamsCodex.imageFrameProbe')]?.control('stop','$token')"|Out-Null}catch{}
    }
}
function Test-E3ProfileCommandLine([string]$commandLine,[string]$profile) {
    # Match the complete switch value, never a substring (profile_other is a different browser).
    $matches=[regex]::Matches($commandLine,'(?:^|\s)(?:"--user-data-dir=(?<whole>[^"]+)"|--user-data-dir(?:=|\s+)(?:"(?<quoted>[^"]+)"|(?<plain>[^\s"]+)))(?=\s|$)',[Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if($matches.Count -ne 1){return $false}
    $value=@('whole','quoted','plain')|ForEach-Object{if($matches[0].Groups[$_].Success){$matches[0].Groups[$_].Value}}
    try {
        if(-not [IO.Path]::IsPathRooted([string]$value)){return $false}
        return [IO.Path]::GetFullPath(([string]$value).Replace('/','\')).TrimEnd('\') -ieq [IO.Path]::GetFullPath($profile).TrimEnd('\')
    } catch {return $false}
}
function Get-E3ProfileEdgeProcesses([string]$profile) {
    return @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction Stop | Where-Object {
        $_.CommandLine -and (Test-E3ProfileCommandLine $_.CommandLine $profile)
    })
}
function Get-E3UnchangedProfileProcesses([string]$profile,$original) {
    return @(Get-E3ProfileEdgeProcesses $profile | Where-Object {
        $current=$_
        @($original | Where-Object {$_.ProcessId -eq $current.ProcessId -and $_.CreationDate -and $_.CreationDate -eq $current.CreationDate}).Count -gt 0
    })
}
function Close-E3ProfileGracefully([string]$profile,$original) {
    foreach($item in @(Get-E3UnchangedProfileProcesses $profile $original)) {
        $process=$null
        try {$process=Get-Process -Id $item.ProcessId -ErrorAction Stop;[void]$process.CloseMainWindow()}catch{}
        finally {if($process){$process.Dispose()}}
    }
    # A stale port file must never let recovery close an unrelated browser.
    $portFile=Join-Path $profile 'DevToolsActivePort'
    try {
        $lines=[IO.File]::ReadAllLines($portFile);$port=0
        if($lines.Count -lt 2 -or -not [int]::TryParse($lines[0],[ref]$port) -or $port -lt 1 -or $port -gt 65535 -or $lines[1] -notmatch '^/devtools/browser/[a-zA-Z0-9-]+$'){return}
        $owned=@(Get-E3UnchangedProfileProcesses $profile $original)
        $listeners=@(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction Stop)
        if(-not @($listeners | Where-Object {$_.OwningProcess -in $owned.ProcessId}).Count){return}
        $version=Get-E3LocalJson "http://127.0.0.1:$port/json/version"
        $uri=[Uri]$version.webSocketDebuggerUrl
        if($uri.Scheme -ne 'ws' -or $uri.Host -notin @('127.0.0.1','localhost') -or $uri.Port -ne $port -or $uri.AbsolutePath -cne $lines[1]){return}
        Connect-E3Cdp $uri.AbsoluteUri -TimeoutMs 2000
        Invoke-E3Cdp 'Browser.close' @{} -TimeoutMs 2000 | Out-Null
    } catch {} finally {if($script:CdpSocket){$script:CdpSocket.Dispose();$script:CdpSocket=$null}}
}
function Stop-E3ProfileProcesses([string]$profile,$original) {
    foreach($item in @(Get-E3UnchangedProfileProcesses $profile $original)) {
        $process=$null
        try {$process=Get-Process -Id $item.ProcessId -ErrorAction SilentlyContinue;if($process){Stop-Process -InputObject $process -Force -ErrorAction Stop}}
        catch {if(@(Get-E3UnchangedProfileProcesses $profile @($item)).Count){Write-Host "⚠️ 無法結束專用 Edge PID $($item.ProcessId)：$($_.Exception.Message)" -ForegroundColor Yellow}}
        finally {if($process){$process.Dispose()}}
    }
}
function Request-E3ProfileRestart([string]$profile) {
    # Only the interactive binding entry calls this while owning E3TeamsCdpShared.
    $allowed=[IO.Path]::GetFullPath((Join-Path (Get-E3CdpStateRoot) 'profile')).TrimEnd('\')
    if([IO.Path]::GetFullPath($profile).TrimEnd('\') -ine $allowed){throw '拒絕重啟非 CDP 專用登入資料的 Edge'}
    if($script:E3SendNetwork){throw '仍有傳送工作，不能重啟專用 Edge'}
    $original=@(Get-E3ProfileEdgeProcesses $profile)
    if(-not $original.Count){return $false}
    $pending=@(Get-ChildItem -LiteralPath (Join-Path (Get-E3CdpRecordRoot) 'blocked') -Filter '*.json' -File -ErrorAction SilentlyContinue)
    Write-Host "⚠️ CDP 專用 Edge 仍在背景執行（PID：$($original.ProcessId -join ', ')）。" -ForegroundColor Yellow
    Write-Host '可先正常關閉；若仍未結束，會強制關閉這些專用程序，再繼續設定。登入資料會保留，日常 Edge 不受影響。'
    Write-Host '此專用 Edge 的所有分頁會關閉；未送出的草稿可能遺失，其他使用分頁模式的收件對象需重新綁定。' -ForegroundColor Yellow
    if($pending.Count){Write-Host "⚠️ 有 $($pending.Count) 筆待核對傳送紀錄，重啟不會清除或重送；請核對已送訊息後再解除。" -ForegroundColor Yellow}
    if((Read-Host '是否關閉上述專用 Edge 並重新開啟？輸入 Y 確認，Enter／其他輸入取消') -ine 'Y'){throw '已取消重啟，專用 Edge 與登入資料保持原狀'}
    Close-E3ProfileGracefully $profile $original
    $until=[DateTime]::UtcNow.AddSeconds(4)
    do {if(-not @(Get-E3ProfileEdgeProcesses $profile).Count){return $true};Start-Sleep -Milliseconds 200}while([DateTime]::UtcNow -lt $until)
    Write-Host '⏳ 專用 Edge 尚未結束，正在關閉先前確認的背景程序…' -ForegroundColor Yellow
    Stop-E3ProfileProcesses $profile $original
    $until=[DateTime]::UtcNow.AddSeconds(5)
    do {if(-not @(Get-E3ProfileEdgeProcesses $profile).Count){return $true};Start-Sleep -Milliseconds 200}while([DateTime]::UtcNow -lt $until)
    throw '專用 Edge 仍被占用，未啟動另一個瀏覽器；請檢查程序權限或稍後再試'
}
function Wait-E3DevToolsEndpoint([string]$portFile,[int]$TimeoutMs=30000) {
    $until=[DateTime]::UtcNow.AddMilliseconds($TimeoutMs);$last='尚未產生連線檔案'
    do {
        $stream=$null;$reader=$null
        try {
            $stream=[IO.File]::Open($portFile,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            $reader=[IO.StreamReader]::new($stream);$portText=$reader.ReadLine();$browserPath=$reader.ReadLine()
            $reader.Dispose();$reader=$null;$stream=$null
            $port=0
            if(-not [int]::TryParse($portText,[ref]$port) -or $port -lt 1 -or $port -gt 65535 -or $browserPath -notmatch '^/devtools/browser/[a-zA-Z0-9-]+$'){throw '連線檔案尚未寫入完整'}
            $version=Get-E3LocalJson "http://127.0.0.1:$port/json/version"
            $uri=[Uri]$version.webSocketDebuggerUrl
            if($uri.Scheme -ne 'ws' -or $uri.Host -notin @('127.0.0.1','localhost') -or $uri.Port -ne $port -or $uri.AbsolutePath -cne $browserPath){throw '瀏覽器連線資訊尚未一致'}
            return @{port=$port;version=$version}
        } catch {$last=$_.Exception.Message}
        finally {if($reader){$reader.Dispose()}elseif($stream){$stream.Dispose()}}
        Start-Sleep -Milliseconds 100
    }while([DateTime]::UtcNow -lt $until)
    throw "等待 Edge 連線就緒逾時：$last"
}
function Reset-E3HeadlessBrowserForNewDelivery {
    # Called only after the sender owns E3TeamsCdpShared. Never close interactive setup/day-to-day Edge.
    if($script:E3SendNetwork){throw '目前仍有傳送工作，不能重啟瀏覽器'}
    $profile=[IO.Path]::GetFullPath((Join-Path (Get-E3CdpStateRoot) 'profile'))
    $original=@(Get-E3ProfileEdgeProcesses $profile)
    if(-not $original.Count){return}
    $main=@($original|Where-Object {$_.CommandLine -notmatch '(?:^|\s)--type='})
    if(-not $main.Count -or @($main|Where-Object {$_.CommandLine -notmatch '(?:^|\s)--headless(?:=\S+)?(?:\s|$)'}).Count){throw 'CDP 設定或有視窗 Edge 仍開啟，請正常關閉後再執行；未關閉其他視窗'}
    Write-Host '🧹 正在結束上次遺留的專用無視窗 Edge，再準備本次排程；登入資料保留。' -ForegroundColor Gray
    Close-E3ProfileGracefully $profile $original
    $until=[DateTime]::UtcNow.AddSeconds(3)
    do {if(-not @(Get-E3ProfileEdgeProcesses $profile).Count){return};Start-Sleep -Milliseconds 100}while([DateTime]::UtcNow -lt $until)
    Stop-E3ProfileProcesses $profile $original
    $until=[DateTime]::UtcNow.AddSeconds(5)
    do {if(-not @(Get-E3ProfileEdgeProcesses $profile).Count){return};Start-Sleep -Milliseconds 100}while([DateTime]::UtcNow -lt $until)
    throw '舊專用 Edge 尚未結束，未啟動重複瀏覽器'
}
function Start-E3TestBrowser([string]$profile,[switch]$Headless,[switch]$InteractiveRestart) {
    Assert-E3DebugPolicy
    $edge=@((Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'),(Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),(Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\Application\msedge.exe'))|Where-Object{Test-Path -LiteralPath $_}|Select-Object -First 1
    if(-not $edge){throw '找不到 Edge'}
    $fullProfile=[IO.Path]::GetFullPath($profile)
    $restartedProfile=$false
    $running=@(Get-E3ProfileEdgeProcesses $fullProfile)
    if($running.Count -and $InteractiveRestart){$restartedProfile=Request-E3ProfileRestart $fullProfile;$running=@(Get-E3ProfileEdgeProcesses $fullProfile)}
    if($running.Count){throw 'CDP 專用登入資料正被 Edge 使用；請先正常關閉舊版 CDP／設定用 Edge，再執行。不要關閉日常 Edge，也不用刪除登入資料'}
    [IO.Directory]::CreateDirectory($fullProfile)|Out-Null
    $portFile=Join-Path $fullProfile 'DevToolsActivePort'
    if(Test-Path -LiteralPath $portFile){Remove-Item -LiteralPath $portFile -Force}
    $argList='--remote-debugging-address=127.0.0.1 --remote-debugging-port=0 --user-data-dir="'+$fullProfile+'" --no-first-run --no-default-browser-check --disable-background-timer-throttling --disable-backgrounding-occluded-windows --disable-renderer-backgrounding about:blank'
    if($Headless){$argList+=' --headless=new'}
    $style=if($Headless){'Hidden'}else{'Normal'}
    # Raw Chromium logs are opt-in. Drain both pipes without retaining their output
    # so logging noise neither creates files nor fills a pipe and blocks Edge.
    $rawDiagnostics=$env:E3_EDGE_RAW_LOGS -eq '1'
    $diagnostics=$null;$stderrLog=$null;$stdoutLog=$null
    if($rawDiagnostics){
        $diagnostics=Join-Path $script:E3CdpLogRoot ([DateTime]::Now.ToString('yyyy-MM-dd'))
        try {[IO.Directory]::CreateDirectory($diagnostics)|Out-Null}
        catch {throw "無法建立 Edge 診斷目錄，尚未啟動瀏覽器：$($_.Exception.Message)"}
        $logId='edge_'+[DateTime]::Now.ToString('HHmmss')+'_'+[guid]::NewGuid().ToString('N')
        $stderrLog=Join-Path $diagnostics ($logId+'.stderr.log')
        $stdoutLog=Join-Path $diagnostics ($logId+'.stdout.log')
    }
    $process=$null;$ver=$null
    try {
    if($rawDiagnostics){
        $process=Start-Process -FilePath $edge -ArgumentList $argList -WindowStyle $style -RedirectStandardError $stderrLog -RedirectStandardOutput $stdoutLog -PassThru -ErrorAction Stop
        Write-Host "📝 Edge 原始診斷已另存：$stderrLog" -ForegroundColor DarkGray
    }else{
        $process=[Diagnostics.Process]::new()
        $process.StartInfo=[Diagnostics.ProcessStartInfo]::new($edge,$argList)
        $process.StartInfo.UseShellExecute=$false
        $process.StartInfo.CreateNoWindow=[bool]$Headless
        $process.StartInfo.WindowStyle=[Diagnostics.ProcessWindowStyle]::$style
        $process.StartInfo.RedirectStandardOutput=$true
        $process.StartInfo.RedirectStandardError=$true
        if(-not $process.Start()){throw '無法啟動 Edge 處理序'}
        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()
    }
    $ready=Wait-E3DevToolsEndpoint $portFile
    $port=$ready.port;$ver=$ready.version
    $targets=@(Get-E3LocalJson "http://127.0.0.1:$port/json/list"|ForEach-Object{$_})
    $target=$targets|Where-Object{$_.type -eq 'page' -and $_.url -eq 'about:blank'}|Select-Object -First 1
    if(-not $target){throw '找不到空白分頁'}
    Connect-E3Cdp $target.webSocketDebuggerUrl
    Invoke-E3Cdp 'Page.enable'|Out-Null
    return @{port=$port;targetId=$target.id;browserUrl=$ver.webSocketDebuggerUrl;process=$process;profile=$fullProfile;version=$ver.Browser;stderrLog=$stderrLog;stdoutLog=$stdoutLog;restartedProfile=$restartedProfile}
    } catch {
        $reason=$_.Exception.Message
        # Startup failed before any website navigation/paste. Clean up only this newly launched process.
        if($ver -and $ver.webSocketDebuggerUrl){try{Connect-E3Cdp $ver.webSocketDebuggerUrl;Invoke-E3Cdp 'Browser.close'|Out-Null}catch{}}
        if($process){
            try{if(-not $process.HasExited){[void]$process.CloseMainWindow();if(-not $process.WaitForExit(3000)){$process.Kill();[void]$process.WaitForExit(3000)}}}catch{}
            $process.Dispose()
        }
        if($script:CdpSocket){$script:CdpSocket.Dispose();$script:CdpSocket=$null}
        if($rawDiagnostics){throw "專用 Edge 啟動失敗：$reason；Edge 診斷目錄：$diagnostics"}
        throw "專用 Edge 啟動失敗：$reason（Edge 原始輸出未記錄）"
    }
}
function Initialize-E3DesktopProbe {
    if('E3CdpDesktop' -as [type]){return}
    Add-Type -TypeDefinition @'
using System;using System.Text;using System.Runtime.InteropServices;
public static class E3CdpDesktop {
[DllImport("user32.dll",SetLastError=true)] static extern IntPtr OpenInputDesktop(uint flags,bool inherit,uint access);
[DllImport("user32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool GetUserObjectInformation(IntPtr obj,int index,StringBuilder value,int length,out int needed);
[DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr desktop);
[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint flags);
public static string State(){IntPtr d=OpenInputDesktop(0,false,1);if(d==IntPtr.Zero)return "unavailable";try{var s=new StringBuilder(256);int n;if(!GetUserObjectInformation(d,2,s,s.Capacity*2,out n))return "unknown";return s.ToString()=="Default"?"interactive":"unavailable";}finally{CloseDesktop(d);}}
}
'@
}
function Close-E3TestBrowser($browser) {
    if($browser) {
        try {Connect-E3Cdp $browser.browserUrl;Invoke-E3Cdp 'Browser.close'|Out-Null}catch{}
        if($browser.process){$browser.process.Dispose()}
    }
    if($script:CdpSocket){$script:CdpSocket.Dispose();$script:CdpSocket=$null}
}
 
#endregion
 
#region Owned browser lifecycle
# Owned headless browser lifecycle. Loaded by Delivery.ps1; import has no side effects.
function Test-E3UseHeadless($teamsCfg) {
    return -not ($teamsCfg -and $teamsCfg.cdp_headless -eq $false)
}
function Test-E3TeamsPage([string]$url) {
    $u=$null
    return [Uri]::TryCreate($url,[UriKind]::Absolute,[ref]$u) -and $u.Scheme -eq 'https' -and $u.Host -in @('teams.cloud.microsoft','teams.microsoft.com') -and -not $u.UserInfo -and $u.IsDefaultPort
}
function Get-E3CdpChatUrl($target) {
    if($target.binding.chatId -notmatch '^(19|48):[^\s]+$'){throw 'CDP 聊天室識別無效，請重新綁定'}
    return 'https://teams.cloud.microsoft/l/chat/'+[Uri]::EscapeDataString([string]$target.binding.chatId)+'/conversations'
}
function Get-E3TeamsHomeUrl { return 'https://teams.cloud.microsoft/' }
function Get-E3CdpBlockPath($target) {
    $identity=[string]$target.binding.accountId+"`n"+[string]$target.binding.chatId
    $sha=[Security.Cryptography.SHA256]::Create()
    try{$key=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($identity)))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
    return Join-Path (Get-E3CdpRecordRoot) ('blocked\'+$key+'.json')
}
function Assert-E3CdpNotBlocked($target) {
    $path=Get-E3CdpBlockPath $target
    if(Test-Path -LiteralPath $path){throw "此收件對象有舊工作紀錄。連線檢查不解除紀錄；再次傳給自己或執行正式新工作時，會先確認舊工作已停止、對話正確且無草稿或傳送中訊息，通過即可執行本次內容。紀錄：$path"}
}
function Set-E3CdpPending($target,[string]$id,[string]$receipt) {
    Save-E3CdpState (Get-E3CdpBlockPath $target) @{id=$id;receipt=$receipt;utc=[DateTime]::UtcNow.ToString('o');reason='delivery_started_not_yet_confirmed';endpoint=$script:CdpEndpoint}
}
function Clear-E3CdpPending($target) {
    $path=Get-E3CdpBlockPath $target
    if(Test-Path -LiteralPath $path){Remove-Item -LiteralPath $path -ErrorAction Stop}
}
# Called under the shared send mutex, after connection; readiness checks never release blocks.
function Resume-E3CdpPendingForNewDelivery($target,[int]$context,[string]$nextId,$ownedBrowser=$null) {
    $path=Get-E3CdpBlockPath $target
    if(-not(Test-Path -LiteralPath $path)){return}
    $original=[IO.File]::ReadAllText($path)
    try{$pending=$original|ConvertFrom-Json -ErrorAction Stop}catch{throw '舊工作紀錄無法讀取，保留阻擋；請人工核對，本次未送出'}
    if($pending.id -notmatch '^[a-f0-9]{32}$' -or $nextId -notmatch '^[a-f0-9]{32}$' -or $nextId -ceq $pending.id){throw '舊／新工作識別不完整或相同，保留阻擋；不重送舊工作'}
    $actual=Get-E3SelfBinding $context -AllowGroup
    if(-not $actual.ok){throw '無法核對目前 Teams 帳號與聊天室，保留舊工作阻擋'}
    foreach($key in @('accountId','chatId','label')){if($actual.binding.$key -cne $target.binding.$key){throw "Teams $key 不符，保留舊工作阻擋，本次未送出"}}
    $status=Invoke-E3Js 'E3Cdp.recover()' $context
    if($status -and $status.stage -notin @('idle','finished') -and $status.cancelled){
        $until=[DateTime]::UtcNow.AddSeconds(3)
        do{Start-Sleep -Milliseconds 100;$status=Invoke-E3Js 'E3Cdp.recover()' $context}while($status.stage -ne 'finished' -and [DateTime]::UtcNow -lt $until)
    }
    if(-not $status -or $status.stage -notin @('idle','finished')){throw '上一筆 CDP 工作仍在執行或無法確認已停止；保留阻擋，本次未貼圖、未送出'}
    if($status.stage -eq 'finished' -and (-not $status.id -or -not $status.result)){throw '上一筆 CDP 結束證據不完整，保留阻擋'}
    $receipt=$null
    if($pending.receipt){try{$receipt=[IO.File]::ReadAllText([string]$pending.receipt)|ConvertFrom-Json -ErrorAction Stop}catch{}}
    if($receipt -and $receipt.id -cne $pending.id){throw '舊收據與工作 ID 不符，保留阻擋，請人工核對'}
    $receiptStopped=$receipt -and (($receipt.stage -eq 'finished' -and $receipt.result) -or ($receipt.stage -eq 'cleanup' -and $receipt.previous.stage -eq 'finished' -and $receipt.previous.id -ceq $pending.id -and $receipt.previous.result))
    $liveStopped=$status.stage -eq 'finished' -and $status.id -ceq $pending.id
    $samePageIdle=$status.stage -eq 'idle' -and $pending.endpoint -and $pending.endpoint -ceq $script:CdpEndpoint
    # A fresh owned browser starts only after proving no process owns this exact profile.
    $freshProfile=$ownedBrowser -and $ownedBrowser.profile -and [IO.Path]::GetFullPath($ownedBrowser.profile) -ieq [IO.Path]::GetFullPath((Join-Path (Get-E3CdpStateRoot) 'profile'))
    if(-not ($receiptStopped -or $liveStopped -or $samePageIdle -or $freshProfile)){throw '無法證明舊工作已停止（可能是其他分頁）；保留阻擋，請人工核對'}
    $bindingJson=ConvertTo-Json -InputObject $target.binding -Depth 8 -Compress
    $check=(Get-E3CdpRuntimeSource 'resume-check.js').Replace('/*E3_BINDING*/null',$bindingJson)
    $proof=Invoke-E3Js $check $context
    if(-not $proof -or -not $proof.ok){throw '聊天室或傳送中訊息狀態無法核對，保留舊工作阻擋'}
    if($proof.pendingRows -ne 0){throw 'Teams 還有傳送中／等待中的訊息，保留舊工作阻擋；不自動取消或重送'}
    Assert-E3CdpComposerEmpty $context
    $evidence=if($liveStopped){'runtime_finished'}elseif($receiptStopped){'saved_terminal_receipt'}elseif($samePageIdle){'original_page_idle'}else{'fresh_exclusive_profile'}
    $reviewRoot=Join-Path (Get-E3CdpRecordRoot) 'review'
    $stem=$pending.id+'_'+[guid]::NewGuid().ToString('N')
    $review=Join-Path $reviewRoot ($stem+'.review.json')
    $archived=Join-Path $reviewRoot ($stem+'.pending.json')
    $reviewState=if($receipt.result.outcome -eq 'sent' -and $receipt.serverReceipt.ok){'previous_delivery_confirmed'}else{'pending_manual_review'}
    Save-E3CdpState $review @{version='pending2';state=$reviewState;decision='eligible_for_new_delivery';oldWorkRetried=$false;nextDeliveryId=$nextId;target=$target.route;binding=$target.binding;previousPending=$pending;previousReceipt=$receipt;previousRuntime=$status;stopEvidence=$evidence;pendingRows=$proof.pendingRows;composerEmpty=$true;utc=[DateTime]::UtcNow.ToString('o')}
    # Preserve original bytes. Any write/move failure leaves the block and stops the new send.
    if([IO.File]::ReadAllText($path) -cne $original){throw '舊工作紀錄已變更，停止解除阻擋，請重新檢查'}
    [IO.File]::Move($path,$archived)
    Write-Host "⚠️ 舊工作 $($pending.id) 已停止，已保留原結果與檢查紀錄：$review" -ForegroundColor Yellow
    Write-Host '  不補送舊內容；帳號、聊天室、空白輸入框及無傳送中訊息已核對，接續本次新工作。' -ForegroundColor Yellow
}
function Assert-E3CdpComposerEmpty([int]$context) {
    $d=Invoke-E3Js 'BridgeAdapter.diagnostics(document,location.href,true).deliveryEvidence' $context
    if($d.composerCount -ne 1 -or $d.hasTextDraft -or $d.hasRichDraft -or $d.hasAttachments){throw '輸入框仍有草稿或附件，請先核對並處理；本次未貼圖、未送出'}
}
function Clear-E3HeadlessDraftForNewDelivery($target,[int]$context,$ownedBrowser,[switch]$Visible) {
    # Explicit user policy: discard old unsent composer content only in the exclusive owned headless browser.
    $profile=Join-Path (Get-E3CdpStateRoot) 'profile'
    if($Visible){
        $endpoint=[Uri]$script:CdpEndpoint
        if($target.targetId -notmatch '^[A-Za-z0-9]+$' -or $endpoint.AbsolutePath -cne ('/devtools/page/'+$target.targetId)){throw '目前連線不是已綁定的 CDP 分頁，未清除草稿'}
    }elseif(-not $ownedBrowser -or -not $ownedBrowser.profile -or [IO.Path]::GetFullPath($ownedBrowser.profile) -ine [IO.Path]::GetFullPath($profile)) {
        throw '無法確認無視窗專用瀏覽器的擁有權，未清除草稿'
    }
    $actual=Get-E3SelfBinding $context -AllowGroup
    if(-not $actual.ok){throw '無法核對收件對話，未清除草稿'}
    foreach($key in @('accountId','chatId','label')){if($actual.binding.$key -cne $target.binding.$key){throw "Teams $key 不符，未清除草稿"}}
    $status=Invoke-E3Js 'E3Cdp.recover()' $context
    if(-not $status){throw '無法確認舊工作狀態，未清除草稿'}
    if($status.stage -notin @('idle','finished')){
        if(-not $status.id){throw '舊工作識別不明，未清除草稿'}
        $status=Stop-E3CdpDelivery $context $status.id
        if($status.stage -ne 'finished'){throw '舊工作尚未停止，無法安全清除草稿；本次未送出'}
    }
    $bindingJson=ConvertTo-Json -InputObject $target.binding -Depth 8 -Compress
    $check=(Get-E3CdpRuntimeSource 'resume-check.js').Replace('/*E3_BINDING*/null',$bindingJson)
    $proof=Invoke-E3Js $check $context
    if(-not $proof.ok -or $proof.pendingRows -ne 0){throw 'Teams 仍有傳送中的訊息或對話無法核對，無法確認取消完成；本次未送出'}
    $source=(Get-E3CdpRuntimeSource 'discard-draft.js').Replace('/*E3_BINDING*/null',$bindingJson)
    $until=[DateTime]::UtcNow.AddSeconds(15);$stable=$null;$clears=0;$removed=0
    Write-Host '🧹 CDP 新工作：正在清除目標對話先前未送出的文字與附件…' -ForegroundColor Cyan
    do {
        $step=Invoke-E3Js $source $context
        if(-not $step -or -not $step.ok){throw "無法清除舊草稿：$($step.reason)；本次未貼圖、未送出"}
        if($step.state -eq 'empty'){
            if(-not $stable){$stable=[DateTime]::UtcNow}
            if(([DateTime]::UtcNow-$stable).TotalMilliseconds -ge 1000){
                Assert-E3CdpComposerEmpty $context
                $proof=Invoke-E3Js $check $context
                if(-not $proof.ok -or $proof.pendingRows -ne 0){throw '清除後仍有傳送中的訊息，停止本次傳送'}
                return @{editorClears=$clears;attachmentRemovals=$removed;oldRuntime=$status;composerEmpty=$true}
            }
        }else{
            $stable=$null
            if($step.state -eq 'clear_editor'){
                if($clears -ge 3){throw '舊草稿持續恢復，未確認清除完成；本次未貼圖、未送出'}
                # Native editing keys notify Teams/CKEditor and update its model; never just erase DOM.
                Invoke-E3Cdp 'Input.dispatchKeyEvent' @{type='rawKeyDown';key='a';code='KeyA';windowsVirtualKeyCode=65;modifiers=2}|Out-Null
                Invoke-E3Cdp 'Input.dispatchKeyEvent' @{type='keyUp';key='a';code='KeyA';windowsVirtualKeyCode=65;modifiers=2}|Out-Null
                $focus=Invoke-E3Js ($source.Replace('/*E3_CHECK_FOCUS*/false','true')) $context
                if(-not $focus.ok -or $focus.state -ne 'focused'){throw '清除前焦點或對話已變更，未刪除內容'}
                Invoke-E3Cdp 'Input.dispatchKeyEvent' @{type='rawKeyDown';key='Backspace';code='Backspace';windowsVirtualKeyCode=8}|Out-Null
                Invoke-E3Cdp 'Input.dispatchKeyEvent' @{type='keyUp';key='Backspace';code='Backspace';windowsVirtualKeyCode=8}|Out-Null
                $clears++
            }elseif($step.state -eq 'removed_attachment'){$removed++}
            else{throw '無法辨識草稿清除進度，本次未送出'}
        }
        Start-Sleep -Milliseconds 250
    }while([DateTime]::UtcNow -lt $until)
    throw '清除舊草稿逾時，未確認輸入區完全清空；本次未貼圖、未送出'
}
function Retire-E3HeadlessPending($target,[string]$nextId,$discardProof) {
    if($nextId -notmatch '^[a-f0-9]{32}$' -or -not $discardProof.composerEmpty -or $discardProof.oldRuntime.stage -notin @('idle','finished')){throw '缺少舊工作停止與草稿清除證據'}
    $path=Get-E3CdpBlockPath $target
    if(-not(Test-Path -LiteralPath $path)){return}
    $original=[IO.File]::ReadAllBytes($path)
    $reviewRoot=Join-Path (Get-E3CdpRecordRoot) 'review'
    $stem='discard_'+[guid]::NewGuid().ToString('N')
    $review=Join-Path $reviewRoot ($stem+'.review.json')
    Save-E3CdpState $review @{version='discard1';decision='user_requested_new_content';nextDeliveryId=$nextId;oldWorkRetried=$false;previousOutcome='not_reclassified';binding=$target.binding;cleanup=$discardProof;utc=[DateTime]::UtcNow.ToString('o')}
    if([Convert]::ToBase64String([IO.File]::ReadAllBytes($path)) -cne [Convert]::ToBase64String($original)){throw '舊工作紀錄被其他程序修改，停止本次傳送'}
    [IO.File]::Move($path,(Join-Path $reviewRoot ($stem+'.pending.json')))
    Write-Host '🧹 舊工作紀錄已封存，不補送、不把不確定結果改成成功；接續本次選定內容。' -ForegroundColor Gray
}
function Close-E3OwnedBrowser($browser) {
    if(-not $browser){return}
    try {
        Close-E3TestBrowser $browser
        # Closing retains uncertain receipts. The next formal headless job separately
        # owns the mutex and verifies orphan/profile identity before its authorized reset.
        $until=[DateTime]::UtcNow.AddSeconds(8)
        do {
            $alive=@(Get-E3ProfileEdgeProcesses $browser.profile)
            if(-not $alive.Count){return}
            Start-Sleep -Milliseconds 200
        }while([DateTime]::UtcNow -lt $until)
        Write-Host '⚠️ 專用 Edge 尚未完全結束；下次正式無視窗工作會先核對並清理殘留程序，有視窗設定 Edge 請正常關閉。' -ForegroundColor Yellow
    } catch {Write-Host "⚠️ 關閉專用 Edge 失敗：$($_.Exception.Message)" -ForegroundColor Yellow}
}
function Initialize-E3HeadlessPage {
    Invoke-E3Cdp 'Page.addScriptToEvaluateOnNewDocument' @{source=(Get-E3CdpRuntimeSource 'vendor\image-frame-bootstrap.js')}|Out-Null
    $version=Invoke-E3Cdp 'Browser.getVersion'
    $ua=([string]$version.userAgent) -replace 'HeadlessEdg','Edg' -replace 'HeadlessChrome','Chrome'
    Invoke-E3Cdp 'Emulation.setUserAgentOverride' @{userAgent=$ua;acceptLanguage='zh-TW,zh;q=0.9,en;q=0.8'}|Out-Null
    Invoke-E3Cdp 'Emulation.setDeviceMetricsOverride' @{width=1600;height=1000;deviceScaleFactor=1;mobile=$false}|Out-Null
    Invoke-E3Cdp 'Runtime.disable'|Out-Null
    Enable-E3CdpBackgroundFocus
}
function Restore-E3NavigationConnection([string]$endpoint,[int]$TimeoutMs=10000) {
    # Only pre-send navigation may reconnect. Never replay paste, upload or send commands.
    if($script:E3SendNetwork){throw 'CDP_NAVIGATION_RECOVERY_FORBIDDEN：傳送階段禁止自動重連'}
    $uri=$null
    if(-not [Uri]::TryCreate($endpoint,[UriKind]::Absolute,[ref]$uri) -or $uri.AbsolutePath -notlike '/devtools/page/*'){throw '無法確認原專用分頁，停止重連'}
    Connect-E3Cdp $endpoint -TimeoutMs $TimeoutMs
}
function Move-E3HeadlessPage([string]$url,[int]$TimeoutMs=30000) {
    $endpoint=$script:CdpEndpoint
    try {
        $nav=Invoke-E3Cdp 'Page.navigate' @{url=$url} -TimeoutMs $TimeoutMs
        if($nav.errorText){throw "Teams 導航失敗：$($nav.errorText)"}
    }catch{
        if($_.Exception.Message -notmatch 'CDP_TIMEOUT'){throw}
        Write-Host "⚠️ $($_.Exception.Message)；只重連原分頁並檢查載入結果，不重複導航。" -ForegroundColor Yellow
        Restore-E3NavigationConnection $endpoint
    }
}
function Wait-E3HeadlessChat($target,[int]$TimeoutSeconds=120) {
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $label=ConvertTo-Json -InputObject ([string]$target.binding.label) -Compress
    $chatId=ConvertTo-Json -InputObject ([string]$target.binding.chatId) -Compress
    $source=(Get-E3CdpRuntimeSource 'navigation.js').Replace('/*E3_LABEL*/null',$label).Replace('/*E3_CHAT_ID*/null',$chatId)
    $last='loading';$nextLog=[DateTime]::UtcNow.AddSeconds(20);$fallbackAt=[DateTime]::UtcNow.AddSeconds(45);$fallback=$false;$loginSince=$null
    $endpoint=$script:CdpEndpoint;$reconnects=0;$contextChanges=0;$progress=$false
    while([DateTime]::UtcNow -lt $deadline){
        if([DateTime]::UtcNow -ge $nextLog){Write-Host "  等待 headless Teams 載入綁定對話（$last；重連 $reconnects/2；navigation1）…";$nextLog=[DateTime]::UtcNow.AddSeconds(20)}
        $remaining=[int]($deadline-[DateTime]::UtcNow).TotalMilliseconds
        if($remaining -lt 250){break}
        try{$st=Invoke-E3Js $source -TimeoutMs ([Math]::Min(30000,$remaining));$contextChanges=0}
        catch{
            $reason=$_.Exception.Message
            $disconnected=-not $script:CdpSocket -or $script:CdpSocket.State -ne [Net.WebSockets.WebSocketState]::Open
            if($reason -match 'CDP_TIMEOUT|CDP_CLOSED' -or $disconnected){
                if($reconnects -ge 2 -or [DateTime]::UtcNow -ge $deadline){throw "聊天室載入無法恢復（$last；已重連 $reconnects 次）：$reason"}
                $reconnects++
                Write-Host "⚠️ 聊天室載入連線中斷（$last），重連原專用分頁 $reconnects/2；本次尚未貼圖、未送出。原因：$reason" -ForegroundColor Yellow
                $remaining=[int]($deadline-[DateTime]::UtcNow).TotalMilliseconds
                if($remaining -lt 250){throw $reason}
                Restore-E3NavigationConnection $endpoint -TimeoutMs ([Math]::Min(10000,$remaining))
                continue
            }
            # Redirects can briefly invalidate the renderer's execution context.
            if($reason -match 'Execution context was destroyed|Cannot find context|Inspected target navigated' -and $contextChanges -lt 3){$contextChanges++;Start-Sleep -Milliseconds 500;continue}
            throw "聊天室載入檢查失敗（$last）：$reason"
        }
        # Existing SSO sessions can briefly redirect through the login host without user input.
        if($st.login){
            if(-not $loginSince){$loginSince=[DateTime]::UtcNow}
            if(([DateTime]::UtcNow-$loginSince).TotalSeconds -ge 20){throw 'Teams 登入已過期或需要互動驗證；請在解鎖後執行「設定 CDP 收件對象」重新登入，本次未貼圖、未送出'}
            Start-Sleep -Milliseconds 500;continue
        }
        $loginSince=$null
        if($st.ambiguous){throw 'Teams 清單中有多個同名對話，無法唯一選取；本次未貼圖、未送出'}
        if($st.mismatch){throw '選取後的聊天室 ID 與綁定不同，已停止；本次未貼圖、未送出'}
        if($st.ready){return}
        $last=[string]$st.stage
        if($last -in @('chat_list','select_chat','verify_chat_id','web_launcher')){$progress=$true}
        if(-not $fallback -and -not $progress -and $last -in @('loading','redirect') -and [DateTime]::UtcNow -ge $fallbackAt){
            $fallback=$true
            $remaining=[int]($deadline-[DateTime]::UtcNow).TotalMilliseconds
            if($remaining -lt 250){break}
            Move-E3HeadlessPage (Get-E3TeamsHomeUrl) -TimeoutMs ([Math]::Min(30000,$remaining))
        }
        Start-Sleep -Milliseconds 500
    }
    throw "headless Teams 未在 $TimeoutSeconds 秒內開啟綁定對話（$last）；請用「設定 CDP 收件對象」檢查登入與對話，或取消勾選無視窗模式；本次未貼圖、未送出"
}
function Open-E3HeadlessTarget($target) {
    $profile=Join-Path (Get-E3CdpStateRoot) 'profile'
    if(-not(Test-Path -LiteralPath (Join-Path $profile 'Default'))){throw '尚無 CDP 專用登入資料，請先在解鎖後執行「設定 CDP 收件對象」'}
    $browser=$null;$stage='start_browser';$script:E3CdpLastCommand=$null
    try {
        Write-Host '🌐 準備無視窗 Teams（navigation1）：載入逾時會檢查並重連原分頁；尚未貼圖、未送出。' -ForegroundColor Gray
        $browser=Start-E3TestBrowser $profile -Headless
        $stage='initialize_headless'
        Initialize-E3HeadlessPage
        $stage='navigate_chat'
        Move-E3HeadlessPage (Get-E3CdpChatUrl $target)
        $stage='wait_chat'
        Wait-E3HeadlessChat $target
        # A fresh browser has a new target ID; persistent account/chat identity stays unchanged.
        $temporary=@{route=$target.route;targetId=$browser.targetId;binding=$target.binding}
        $session=@{port=$browser.port;browserUrl=$browser.browserUrl}
        $stage='verify_binding'
        $context=Connect-E3CdpTarget $session $temporary
        Write-Host '🌐 已啟動無視窗 Teams，帳號與聊天室識別核對通過' -ForegroundColor Gray
        return @{browser=$browser;context=$context}
    } catch {
        $reason=$_.Exception.Message;$command=$script:E3CdpLastCommand
        $diagnostic=Join-Path $script:E3CdpLogRoot ([DateTime]::Now.ToString('yyyy-MM-dd')+'\startup_'+[guid]::NewGuid().ToString('N')+'.json')
        try{Save-E3CdpState $diagnostic @{version='navigation1';stage=$stage;error=$reason;lastCommand=$command;edgeStderr=$browser.stderrLog;pasteAttempted=$false;sendAttempted=$false;utc=[DateTime]::UtcNow.ToString('o')}}
        catch{$diagnostic='紀錄檔寫入失敗：'+$_.Exception.Message}
        Close-E3OwnedBrowser $browser
        throw "Teams 無視窗啟動失敗（$stage）：$reason。本次未貼圖、未送出。診斷：$diagnostic"
    }
}
 
#endregion
 
#region Binding and delivery
function Get-E3CdpStateRoot { Join-Path $env:LOCALAPPDATA 'E3TeamsCdpSendTest' }
function Assert-E3CdpRecordPath([string]$path) {
    $current=[IO.Path]::GetFullPath($path)
    while($current){
        if(Test-Path -LiteralPath $current){
            if((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw '紀錄路徑含連結，未自動搬移'}
        }
        $current=[IO.Path]::GetDirectoryName($current)
    }
}
function Move-E3CdpLegacyRecord([string]$source,[string]$destination,[string]$recordRoot) {
    # The source stays locked against writes while copying, and is removed only
    # after a durable destination with the same SHA-256 is available.
    $inputStream=$null;$outputStream=$null;$temp=$null;$verified=$false
    try {
        if([IO.Path]::GetFullPath($source) -ieq [IO.Path]::GetFullPath($destination)){throw '紀錄來源與目的地不能相同'}
        Assert-E3CdpRecordPath $source
        Assert-E3CdpRecordPath $destination
        $inputStream=[IO.File]::Open($source,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $sha=[Security.Cryptography.SHA256]::Create()
        try{$sourceHash=([BitConverter]::ToString($sha.ComputeHash($inputStream))).Replace('-','')}finally{$sha.Dispose()}
        $inputStream.Position=0
        if(Test-Path -LiteralPath $destination){
            if((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -cne $sourceHash){
                # Retain the existing active block and archive the conflicting legacy
                # record. Never overwrite one uncertain job with another.
                $destination=Join-Path $recordRoot ('review\migration_conflicts\'+$sourceHash+'.json')
                Assert-E3CdpRecordPath $destination
            }
        }
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))|Out-Null
        if(-not(Test-Path -LiteralPath $destination)){
            $temp=Join-Path $recordRoot ('.migrate_'+[guid]::NewGuid().ToString('N')+'.tmp')
            $outputStream=[IO.File]::Open($temp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
            $inputStream.CopyTo($outputStream);$outputStream.Flush($true);$outputStream.Dispose();$outputStream=$null
            if((Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash -cne $sourceHash){throw '搬移後內容核對失敗'}
            [IO.File]::Move($temp,$destination);$temp=$null
        }
        if((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -cne $sourceHash){throw '目的紀錄內容不符'}
        $verified=$true
    } finally {
        if($outputStream){$outputStream.Dispose()}
        if($inputStream){$inputStream.Dispose()}
        if($temp -and [IO.File]::Exists($temp)){[IO.File]::Delete($temp)}
    }
    if($verified){
        # A concurrent old worker must not lose a newer version of its record.
        if((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -cne $sourceHash){throw '搬移期間舊紀錄已變更，保留原檔'}
        [IO.File]::Delete($source)
    }
}
function Get-E3CdpRecordRoot {
    $root=[IO.Path]::GetFullPath((Join-Path $script:E3CdpLogRoot 'teams_cdp')).TrimEnd('\')
    $legacy=[IO.Path]::GetFullPath((Get-E3CdpStateRoot)).TrimEnd('\')
    if($root -ieq $legacy){throw '紀錄目錄不能與登入資料目錄相同'}
    # No import-time mutation. Migrate only when a record is actually accessed,
    # under the same reentrant mutex used by sending and binding setup.
    $sources=@(foreach($kind in @('blocked','review')){
        $folder=Join-Path $legacy $kind
        if(Test-Path -LiteralPath $folder){$folder}
    })
    if(-not $sources.Count){return $root}
    $mutex=[Threading.Mutex]::new($false,'Local\E3TeamsCdpShared');$locked=$false
    try {
        try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
        if(-not $locked){throw '其他 CDP 工作仍在執行，稍後再搬移舊紀錄'}
        foreach($folder in $sources){
            if($root -ieq $folder -or $root.StartsWith($folder+'\',[StringComparison]::OrdinalIgnoreCase)){throw '紀錄目的地不可位於舊紀錄目錄內'}
            $nodes=@(Get-Item -LiteralPath $folder -Force)+@(Get-ChildItem -LiteralPath $folder -Recurse -Force)
            if(@($nodes|Where-Object{$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw '舊紀錄含連結目錄，未自動搬移'}
            foreach($file in @($nodes|Where-Object{-not $_.PSIsContainer})){
                $relative=$file.FullName.Substring($legacy.Length+1)
                $destination=[IO.Path]::GetFullPath((Join-Path $root $relative))
                if(-not $destination.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){throw '紀錄搬移路徑超出 logs'}
                Move-E3CdpLegacyRecord $file.FullName $destination $root
            }
        }
    } catch {throw "CDP 紀錄搬移未完成，原紀錄保留；本次不傳送：$($_.Exception.Message)"}
    finally {if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
    return $root
}
function Save-E3CdpState([string]$path,$value) {
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))|Out-Null
    $temp=$path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    [IO.File]::WriteAllText($temp,($value|ConvertTo-Json -Depth 25),[Text.UTF8Encoding]::new($false))
    if(Test-Path -LiteralPath $path){Move-Item -LiteralPath $temp -Destination $path -Force}else{[IO.File]::Move($temp,$path)}
}
function Get-E3CdpBindings {
    $path=Join-Path (Get-E3CdpStateRoot) 'bindings.json'
    if(Test-Path -LiteralPath $path){$parsed=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json;foreach($entry in $parsed){Write-Output $entry};return}
    return @()
}
function Get-E3CdpSession {
    Assert-E3DebugPolicy
    $path=Join-Path (Get-E3CdpStateRoot) 'session.json'
    if(-not(Test-Path -LiteralPath $path)){throw '請先執行「設定 CDP 收件對象」，並保持專用 Edge 開啟'}
    $s=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
    if([int]$s.port -lt 1 -or [int]$s.port -gt 65535){throw 'CDP 連線設定無效，請重新設定'}
    $ver=Get-E3LocalJson "http://127.0.0.1:$($s.port)/json/version"
    if($ver.webSocketDebuggerUrl -cne $s.browserUrl){throw '原本的 CDP Edge 已結束；請重新設定，不會連接其他瀏覽器'}
    return $s
}
function Test-E3SelfRoute([string]$name) {
    $t=([string]$name).Trim()
    return ($t -match '48(:|%3A)notes' -or $t -in @('自己','self'))
}
function Resolve-E3CdpTarget([string]$name,[switch]$Headless) {
    $all=@(Get-E3CdpBindings)
    $matches=@($all|Where-Object{$_.route -ceq $name.Trim()})
    if(-not $matches.Count -and (Test-E3SelfRoute $name)){
        # Older settings stored "self" as a Teams link. Both spellings mean the same personal
        # chat; accept only a unique binding that setup verified as the signed-in user's own chat.
        $matches=@($all|Where-Object{(Test-E3SelfRoute ([string]$_.route)) -and $_.binding.isSelf -eq $true})
    }
    if($matches.Count -ne 1){throw "CDP 收件對象尚未唯一綁定：$name。請執行「設定 CDP 收件對象」"}
    $m=$matches[0]
    if($m.binding.chatId -notmatch '^(19|48):\S+$' -or -not $m.binding.accountId -or -not $m.binding.label -or (-not $Headless -and $m.targetId -notmatch '^[A-Za-z0-9]+$')){throw 'CDP 綁定不完整，請重新設定'}
    return $m
}
function Stop-E3PriorPreparation([int]$context) {
    $state=Invoke-E3Js 'E3Cdp.recover()' $context
    if($state.stage -notin @('idle','finished')){$state=Stop-E3CdpDelivery $context $state.id}
    if($state.stage -notin @('idle','finished')){throw '上一筆工作無法結束，本次停止，不等待佇列'}
    if($state.id){$id=$state.id|ConvertTo-Json -Compress;Invoke-E3Js "globalThis[Symbol.for('d46518.teamsCodex.imageFrameProbe')]?.control('stop',$id)"|Out-Null}
}
function Update-E3CdpReceiptRuntime([int]$context) {
    # Upgrade the compatible receipttext1 runtime without refreshing the Teams tab.
    # Check and replace in one JS evaluation; never replace an in-flight delivery.
    $receiptSource=Get-E3CdpRuntimeSource 'receipt.js'
    $runtimeSource=Get-E3CdpRuntimeSource 'runtime.js'
    $version=[regex]::Match($runtimeSource,"version:'([^']+)'").Groups[1].Value
    if(-not $version){throw 'CDP runtime version missing'}
    $expected=$version|ConvertTo-Json -Compress
    $upgrade=@"
(() => {
const current=globalThis.E3Cdp;
if(current?.version===$expected)return {updated:false,version:current.version};
if(current?.version!=='2026-11-11-receipttext1')throw Error('CDP_RUNTIME_REFRESH_REQUIRED');
if(!['idle','finished'].includes(current.status()?.stage))throw Error('DELIVERY_STILL_ACTIVE');
$receiptSource
delete globalThis.E3Cdp;
$runtimeSource
if(globalThis.E3Cdp?.version!==$expected)throw Error('CDP_RUNTIME_UPDATE_FAILED');
return {updated:true,version:globalThis.E3Cdp.version};
})()
"@
    try{$result=Invoke-E3Js $upgrade $context}
    catch{
        $reason=$_.Exception.Message
        if($reason -match 'CDP_RUNTIME_REFRESH_REQUIRED'){throw '原 Teams 分頁的控制程式是較舊版本，無法在不重新整理的情況下更新。請先核對已送訊息與草稿，再重新整理該分頁並回到綁定對話；不需刪除登入資料或重新綁定。本次未貼圖、未送出。'}
        if($reason -match 'DELIVERY_STILL_ACTIVE'){throw '原 Teams 分頁仍有一筆傳送在進行，暫不更新控制程式；請待該筆結束後再試。本次未貼圖、未送出。'}
        throw
    }
    if($result.version -cne $version){throw 'CDP runtime update verification failed'}
    if($result.updated){Write-Host "CDP 已載入更新：$version" -ForegroundColor Cyan}
}
function Connect-E3CdpTarget($session,$target,[switch]$PrepareNew) {
    $tabs=@(Get-E3LocalJson "http://127.0.0.1:$($session.port)/json/list"|ForEach-Object{$_})
    $matches=@($tabs|Where-Object{$_.id -ceq $target.targetId -and $_.type -eq 'page'})
    if($matches.Count -ne 1){throw "CDP 專用分頁已關閉：$($target.route)。請重新設定該收件對象"}
    $tab=$matches[0];$uri=[Uri]$tab.url;$wsUri=[Uri]$tab.webSocketDebuggerUrl
    if(-not(Test-E3TeamsPage $tab.url) -or $wsUri.Port -ne [int]$session.port){throw '專用分頁不是 Teams 或已離開登入頁；請重新登入並綁定'}
    Connect-E3Cdp $tab.webSocketDebuggerUrl
    Invoke-E3Cdp 'Page.enable'|Out-Null
    Enable-E3CdpBackgroundFocus
    $frame=(Invoke-E3Cdp 'Page.getFrameTree').frameTree.frame.id
    $world=Invoke-E3Cdp 'Page.createIsolatedWorld' @{frameId=$frame;worldName='E3ProductionCdp'}
    $context=[int]$world.executionContextId
    $runtime=Invoke-E3Js '({exists:!!globalThis.E3Cdp,version:globalThis.E3Cdp?.version})' $context
    if($runtime.exists -and $runtime.version -notin @('2026-11-05-headless1','2026-11-06-optionaltext1','2026-11-06-receipt2','2026-11-09-preflight1','2026-11-10-preparation1','2026-11-10-captionspace1','2026-11-11-receipttext1','2026-11-10-receiptbreak1')){throw 'Teams 分頁控制程式版本不符。請先核對已送訊息與草稿，再重新整理原分頁並回到綁定對話；不用清除登入資料'}
    if(-not $runtime.exists){
        foreach($file in @('vendor\adapter.js','vendor\outbound-images.js','receipt.js','runtime.js')) {
            Invoke-E3Js (Get-E3CdpRuntimeSource $file) $context|Out-Null
        }
    }
    if($PrepareNew){Stop-E3PriorPreparation $context}
    $actual=Get-E3SelfBinding $context -AllowGroup
    if(-not $actual.ok){throw "無法驗證 Teams 帳號／聊天室：$($actual.error)"}
    foreach($key in @('accountId','chatId','label')){if($actual.binding.$key -cne $target.binding.$key){throw "Teams $key 與保存的收件對象不同，已停止；請回到專用聊天室或重新綁定"}}
    Update-E3CdpReceiptRuntime $context
    return $context
}
# Configured destinations, including missing bindings; ignore disabled page/schedule overrides.
function Get-E3ConfiguredRoutes($cfg) {
    $names=@($cfg.teams.target_chat_name)+@($cfg.pages|Where-Object{$_.enabled -ne $false}|ForEach-Object{$_.target_chat_name})+@($cfg.schedules|Where-Object{$_.enabled -ne $false}|ForEach-Object{Get-TeamsScheduleTargets $_})
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($name in $names){
        $route=([string]$name).Trim()
        if($route -and $seen.Add($route)){Write-Output $route}
    }
}
# Caller owns the shared mutex. This check never pastes, sends, recovers or clears pending blocks.
# ConfigurationOnly verifies saved identity and live login; delivery/draft gates remain in send readiness.
function Test-E3CdpTargetReady([string]$route,[bool]$Headless,[switch]$ConfigurationOnly) {
    $opened=$null
    try {
        $target=Resolve-E3CdpTarget $route -Headless:$Headless
        if(-not $ConfigurationOnly){Assert-E3CdpNotBlocked $target}
        if($Headless){$opened=Open-E3HeadlessTarget $target;$context=$opened.context}
        else{$session=Get-E3CdpSession;$context=Connect-E3CdpTarget $session $target}
        if(-not $ConfigurationOnly){Assert-E3CdpComposerEmpty $context}
    } finally {
        try { Disable-E3CdpBackgroundFocus }
        finally {
            try { if($opened){Close-E3OwnedBrowser $opened.browser} }
            finally { if($script:CdpSocket){$script:CdpSocket.Dispose();$script:CdpSocket=$null} }
        }
    }
}
function Get-E3BrowserSelectedRoute($binding,$existing) {
    $label=([string]$binding.label).Trim()
    if(-not $label -or -not $binding.accountId -or -not $binding.chatId){throw '選取的對話識別不完整'}
    $others=@($existing|Where-Object{$_.binding.accountId -cne $binding.accountId -or $_.binding.chatId -cne $binding.chatId})
    $route=$label;$suffix=1
    while(@($others|Where-Object{$_.route -ieq $route}).Count){$suffix++;$route="$label ($suffix)"}
    return $route
}
# ---- Read-only checks that share one background Edge (sending keeps its own per-delivery browser) ----
function Open-E3HeadlessBrowser {
    $profile=Join-Path (Get-E3CdpStateRoot) 'profile'
    if(-not(Test-Path -LiteralPath (Join-Path $profile 'Default'))){throw '尚無 CDP 專用登入資料，請先在解鎖後執行「設定 CDP 收件對象」'}
    return Start-E3TestBrowser $profile -Headless
}
function Open-E3HeadlessChat($browser,$target) {
    # Reuse the browser's first tab. Page emulation and the bootstrap script belong to the CDP
    # session, so they are applied again on the current connection before every navigation.
    $tab=@(Get-E3LocalJson "http://127.0.0.1:$($browser.port)/json/list"|ForEach-Object{$_})|Where-Object{$_.id -ceq $browser.targetId -and $_.type -eq 'page'}|Select-Object -First 1
    if(-not $tab){throw '背景 Edge 的分頁已關閉'}
    Connect-E3Cdp $tab.webSocketDebuggerUrl
    Invoke-E3Cdp 'Page.enable'|Out-Null
    Initialize-E3HeadlessPage
    Move-E3HeadlessPage (Get-E3CdpChatUrl $target)
    Wait-E3HeadlessChat $target
    $temporary=@{route=$target.route;targetId=$browser.targetId;binding=$target.binding}
    return Connect-E3CdpTarget @{port=$browser.port;browserUrl=$browser.browserUrl} $temporary
}
function Test-E3CdpRoutesReady([string[]]$Routes,[bool]$Headless,[switch]$ConfigurationOnly) {
    # Caller owns E3TeamsCdpShared. Never pastes, sends, recovers or clears pending blocks.
    $results=[Collections.Generic.List[object]]::new()
    if(-not $Headless){
        foreach($route in $Routes){
            Assert-E3WorkNotCancelled
            try{Test-E3CdpTargetReady $route $false -ConfigurationOnly:$ConfigurationOnly;$results.Add(@{route=$route;ok=$true;error=$null})}
            catch{$results.Add(@{route=$route;ok=$false;error=$_.Exception.Message})}
        }
        return $results.ToArray()
    }
    $browser=$null
    try{
        foreach($route in $Routes){
            Assert-E3WorkNotCancelled
            $phase='binding'
            try{
                $target=Resolve-E3CdpTarget $route -Headless
                if(-not $ConfigurationOnly){Assert-E3CdpNotBlocked $target}
                $phase='browser'
                if(-not $browser){$browser=Open-E3HeadlessBrowser}
                $phase='chat'
                $context=Open-E3HeadlessChat $browser $target
                if(-not $ConfigurationOnly){Assert-E3CdpComposerEmpty $context}
                $results.Add(@{route=$route;ok=$true;error=$null})
            }catch{
                $results.Add(@{route=$route;ok=$false;error=$_.Exception.Message})
                # After a browser or chat failure the shared tab is in an unknown state: start fresh.
                if($phase -ne 'binding' -and $browser){
                    try{Disable-E3CdpBackgroundFocus}catch{}
                    Close-E3OwnedBrowser $browser;$browser=$null
                }
            }
        }
    }finally{
        try{Disable-E3CdpBackgroundFocus}catch{}
        if($browser){Close-E3OwnedBrowser $browser}
        if($script:CdpSocket){$script:CdpSocket.Dispose();$script:CdpSocket=$null}
    }
    return $results.ToArray()
}
function Select-E3BindingRoutes($cfg) {
    $routes=@(Get-E3ConfiguredRoutes $cfg)
    if(-not $routes){throw '請先在設定工具填入收件對話名稱'}
    $bound=@{}
    foreach($r in $routes){try{$bound[$r]=[string](Resolve-E3CdpTarget $r -Headless).binding.label}catch{}}
    Write-Host '請選擇要綁定的程式收件名稱：'
    for($i=0;$i -lt $routes.Count;$i++){
        Write-Host ("{0}. {1}  {2}" -f ($i+1),$routes[$i],$(if($bound.ContainsKey($routes[$i])){'（已綁定：'+$bound[$routes[$i]]+'）'}else{'（尚未綁定）'}))
    }
    $answer=([string](Read-Host '輸入編號（多個用逗號，例如 1,3）；A＝依序設定全部尚未綁定的對象；Enter 取消')).Trim()
    if(-not $answer){throw '已取消'}
    if($answer -ieq 'A'){
        $pick=@($routes|Where-Object{-not $bound.ContainsKey($_)})
        if(-not $pick.Count){throw '全部對象都已綁定；要重新綁定請輸入編號'}
        return $pick
    }
    $pick=@()
    foreach($part in ($answer -split '[,，、\s]+'|Where-Object{$_})){
        $n=0
        if(-not [int]::TryParse($part,[ref]$n) -or $n -lt 1 -or $n -gt $routes.Count){throw "編號「$part」無效，已取消"}
        if($routes[$n-1] -notin $pick){$pick+=[string]$routes[$n-1]}
    }
    return $pick
}
function Open-E3BindingTab($session) {
    Connect-E3Cdp $session.browserUrl
    $tabId=[string](Invoke-E3Cdp 'Target.createTarget' @{url='about:blank'}).targetId
    $tabs=@(Get-E3LocalJson "http://127.0.0.1:$($session.port)/json/list"|ForEach-Object{$_})
    Connect-E3Cdp ($tabs|Where-Object{$_.id -eq $tabId}|Select-Object -First 1).webSocketDebuggerUrl
    Invoke-E3Cdp 'Page.enable'|Out-Null
    return $tabId
}
function Set-E3CdpBinding($cfg,[switch]$SelectInBrowser) {
    $mutex=[Threading.Mutex]::new($false,'Local\E3TeamsCdpShared')
    $locked=$false;$ownedBrowser=$null;$headless=Test-E3UseHeadless $cfg.teams;$restartedProfile=$false
    try {
        try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
        if(-not $locked){$locked=Enter-E3WorkLock $mutex 'cdp' '設定 Teams CDP 綁定'}else{Register-E3WorkOwner 'cdp' '設定 Teams CDP 綁定'}
        # Several destinations can be bound in one session. Receiver mode asks after each one.
        $queue=[Collections.Generic.List[object]]::new()
        if($SelectInBrowser){$queue.Add($null)}else{foreach($r in @(Select-E3BindingRoutes $cfg)){$queue.Add($r)}}
        $stateRoot=Get-E3CdpStateRoot
        $session=$null;$tabId=$null;$saved=[Collections.Generic.List[string]]::new();$skipped=[Collections.Generic.List[string]]::new()
        for($index=0;$index -lt $queue.Count;$index++){
            $route=$queue[$index]
            if($index -eq 0){
                if(-not $headless){try{$session=Get-E3CdpSession}catch{Write-Host '正在開啟 CDP 專用 Edge…'}}
                if(-not $session){
                    $opened=Start-E3TestBrowser (Join-Path $stateRoot 'profile') -InteractiveRestart
                    $restartedProfile=[bool]$opened.restartedProfile
                    if($headless){$ownedBrowser=$opened}
                    $session=@{port=$opened.port;browserUrl=$opened.browserUrl}
                    Save-E3CdpState (Join-Path $stateRoot 'session.json') $session
                    $tabId=$opened.targetId
                    if(-not $headless){$opened.process.Dispose()}
                }else{$tabId=Open-E3BindingTab $session}
                Invoke-E3Cdp 'Page.addScriptToEvaluateOnNewDocument' @{source=(Get-E3CdpRuntimeSource 'vendor\image-frame-bootstrap.js')}|Out-Null
                Invoke-E3Cdp 'Page.navigate' @{url=(Get-E3TeamsHomeUrl)}|Out-Null
            }elseif(-not $headless){
                # Tab mode keeps one dedicated tab per destination.
                $tabId=Open-E3BindingTab $session
                Invoke-E3Cdp 'Page.addScriptToEvaluateOnNewDocument' @{source=(Get-E3CdpRuntimeSource 'vendor\image-frame-bootstrap.js')}|Out-Null
                Invoke-E3Cdp 'Page.navigate' @{url=(Get-E3TeamsHomeUrl)}|Out-Null
                Write-Host '已開啟新分頁；請在新分頁選擇下一個對話（前一個分頁請保持開啟）。' -ForegroundColor Cyan
            }else{Write-Host '請在同一個 Edge 分頁切換到下一個對話。' -ForegroundColor Cyan}
            $progressText=if($queue.Count -gt 1 -and -not $SelectInBrowser){"（$($index+1)/$($queue.Count)）"}else{''}
            if($SelectInBrowser){Write-Host '請直接在 Teams 選擇要接收指令的對話：自己的聊天、其他個人聊天或群組都可以。'}
            else{Write-Host "在 Teams 選擇要對應「$route」的本人或群組聊天室$progressText。"}
            Write-Host '輸入框請保持空白。帳號選單會自動驗證，不需手動開啟。'
            $result=$null
            while($true){
                $answer=[string](Read-Host $(if($SelectInBrowser){'選好聊天室後按 Enter'}else{'選好聊天室後按 Enter；輸入 S 略過此對象'}))
                if(-not $SelectInBrowser -and $answer.Trim() -ieq 'S'){break}
                $frame=(Invoke-E3Cdp 'Page.getFrameTree').frameTree.frame.id
                $context=[int](Invoke-E3Cdp 'Page.createIsolatedWorld' @{frameId=$frame;worldName='E3ProductionCdp'}).executionContextId
                foreach($file in @('vendor\adapter.js','vendor\outbound-images.js','receipt.js','runtime.js')){Invoke-E3Js (Get-E3CdpRuntimeSource $file) $context|Out-Null}
                Enable-E3CdpBackgroundFocus
                $result=Get-E3SelfBinding $context -AllowGroup
                if($result.ok){break}
                Write-Host "⚠ 無法辨識目前對話：$($result.error)。請確認已開啟正確的聊天室後再按 Enter。" -ForegroundColor Yellow
                $result=$null
            }
            if(-not $result){$skipped.Add([string]$route);Write-Host "已略過「$route」，原綁定不變。" -ForegroundColor Yellow;continue}
            if($SelectInBrowser){$route=Get-E3BrowserSelectedRoute $result.binding @(Get-E3CdpBindings)}
            elseif($route -in @('自己','self') -and -not $result.binding.isSelf){Write-Host '「自己」只能綁定目前登入帳號的本人對話，此對象未儲存。' -ForegroundColor Yellow;$skipped.Add([string]$route);continue}
            Write-Host "程式名稱：$route`n實際帳號：$($result.binding.accountId)`n實際聊天室：$($result.binding.label)"
            if((Read-Host '確認對應無誤，輸入 BIND 儲存；其他輸入略過此對象，不會發訊息') -cne 'BIND'){$skipped.Add([string]$route);Write-Host "已略過「$route」，原綁定不變。" -ForegroundColor Yellow;continue}
            Assert-E3CdpComposerEmpty $context
            if($restartedProfile -and (Test-Path -LiteralPath (Get-E3CdpBlockPath @{binding=$result.binding}))) {
                if((Read-Host '此對象有待核對的舊傳送。請先核對已送訊息與草稿；已確認後輸入 CHECKED，否則 Enter 保留阻擋') -cne 'CHECKED'){$skipped.Add([string]$route);Write-Host '尚未確認舊傳送，保留原綁定與待核對紀錄；不會重送。' -ForegroundColor Yellow;continue}
            }
            $all=@(Get-E3CdpBindings|Where-Object{$_.route -cne $route})
            if($SelectInBrowser){$all=@($all|Where-Object{$_.binding.accountId -cne $result.binding.accountId -or $_.binding.chatId -cne $result.binding.chatId})}
            $all+=@{route=$route;targetId=$tabId;binding=$result.binding}
            Save-E3CdpState (Join-Path $stateRoot 'bindings.json') @($all)
            Clear-E3CdpPending @{binding=$result.binding}
            $saved.Add([string]$route)
            Write-Host "✅ 已儲存「$route」。" -ForegroundColor Green
            if($SelectInBrowser -and (Read-Host '要再綁定另一個接收對話嗎？輸入 Y 繼續，Enter 結束') -ieq 'Y'){$queue.Add($null)}
        }
        if($skipped.Count){Write-Host "略過：$($skipped -join '、')" -ForegroundColor Yellow}
        if(-not $saved.Count){throw '沒有儲存任何綁定，原綁定未變更'}
        if($headless){
            Write-Host "🔎 已儲存 $($saved.Count) 個綁定，正在關閉設定 Edge，並以一個無視窗 Edge 依序驗證能否沿用登入…" -ForegroundColor Cyan
            Disable-E3CdpBackgroundFocus
            Close-E3OwnedBrowser $ownedBrowser;$ownedBrowser=$null
            $checks=@(Test-E3CdpRoutesReady $saved.ToArray() $true)
            foreach($c in $checks){
                if($c.ok){Write-Host "✅ $($c.route)：登入、帳號、聊天室及空白輸入框均通過" -ForegroundColor Green}
                else{Write-Host "❌ $($c.route)：$($c.error)" -ForegroundColor Red}
            }
            $bad=@($checks|Where-Object{-not $_.ok})
            if($bad.Count){throw "綁定已儲存，但 $($bad.Count) 個對象無視窗驗證失敗。請先排除登入、對話或草稿問題，再檢查 CDP 連線；本次未貼圖、未送出"}
            Write-Host '✅ 綁定與無視窗驗證完成；未貼圖、未送出。' -ForegroundColor Green
        }else{Write-Host "✅ 已綁定 $($saved.Count) 個對象。分頁模式需保持專用 Edge 與各分頁開啟並停留在對應聊天室。" -ForegroundColor Green}
    }finally{
        try {
            try { Disable-E3CdpBackgroundFocus }
            finally { try {if($ownedBrowser){Close-E3OwnedBrowser $ownedBrowser}}finally{if($script:CdpSocket){$script:CdpSocket.Dispose();$script:CdpSocket=$null}} }
        }finally{
            try {if($locked){try{Unregister-E3WorkOwner 'cdp'}finally{$mutex.ReleaseMutex()}}}finally{$mutex.Dispose()}
        }
    }
}
function Test-E3CdpConnection($cfg,[switch]$PassThru) {
    $mutex=[Threading.Mutex]::new($false,'Local\E3TeamsCdpShared');$locked=$false
    $lines=[Collections.Generic.List[string]]::new()
    $headless=Test-E3UseHeadless $cfg.teams
    try {
        try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
        if(-not $locked){throw 'CDP 正在傳送或設定中，請完成後再檢查'}
        Register-E3WorkOwner 'cdp' '檢查 CDP 連線'
        $routes=@(Get-E3ConfiguredRoutes $cfg)
        $lines.Add("🔍 CDP 設定檢查（$(if($headless){'無視窗模式'}else{'分頁模式'})）")
        # Headless mode checks every destination in one background Edge.
        $results=@(Test-E3CdpRoutesReady $routes $headless -ConfigurationOnly)
        foreach($r in $results){
            if($r.ok){$lines.Add("✅ $($r.route)：已設定完成（登入與收件對象確認通過）")}
            else{$lines.Add("❌ $($r.route)：設定尚未確認完成；$($r.error)")}
        }
        $failed=@($results|Where-Object{-not $_.ok}).Count
        $ok=$routes.Count -gt 0 -and $failed -eq 0
        if(-not $routes.Count){$lines.Add('❌ 尚未設定任何收件對象，請先填入預設或啟用頁面／排程的對話名稱')}
        $lines.Add("$(if($ok){'✅ CDP 已設定完成'}else{'❌ CDP 尚未全部確認完成'})（$($routes.Count-$failed)/$($routes.Count) 個收件對象通過）")
        if($PassThru){return @{ok=$ok;results=$results;lines=$lines.ToArray()}}
        Write-Output $lines.ToArray()
    } finally {try{if($locked){try{Unregister-E3WorkOwner 'cdp'}finally{$mutex.ReleaseMutex()}}}finally{$mutex.Dispose()}}
}
function Reset-E3CdpDelivery([int]$context,[string]$root,[string]$target) {
    $status=Invoke-E3Js 'E3Cdp.recover()' $context
    if($status.stage -notin @('idle','finished')){
        if(-not $status.cancelled){throw "上一筆 CDP 工作仍在執行（$($status.id)，階段 $($status.stage)），本次不重設、不重送；請待上一筆結束"}
        Write-Host "🧹 正在結束上一筆已取消／逾時的 CDP 工作 $($status.id)，不會重送…" -ForegroundColor Yellow
        $until=[DateTime]::UtcNow.AddSeconds(3)
        do{Start-Sleep -Milliseconds 100;$status=Invoke-E3Js 'E3Cdp.recover()' $context}while($status.stage -ne 'finished' -and [DateTime]::UtcNow -lt $until)
        if($status.stage -ne 'finished'){throw '上一筆 CDP 工作無法結束。請核對草稿與已送訊息後，正常關閉 CDP Edge 並重新綁定；本次未送出'}
    }
    if($status.id){Save-E3CdpState (Join-Path $root ('recovered_'+$status.id+'.json')) @{target=$target;previous=$status;utc=[DateTime]::UtcNow.ToString('o')}}
    Invoke-E3Js 'E3Cdp.reset()' $context|Out-Null
}
function Stop-E3CdpDelivery([int]$context,[string]$token) {
    $idJson=ConvertTo-Json -InputObject $token -Compress
    $status=Invoke-E3Js "E3Cdp.cancel($idJson)" $context
    $until=[DateTime]::UtcNow.AddSeconds(3)
    while($status.id -eq $token -and $status.stage -ne 'finished' -and [DateTime]::UtcNow -lt $until){Start-Sleep -Milliseconds 100;$status=Invoke-E3Js 'E3Cdp.status()' $context}
    return $status
}
function Send-GroupToTeamsCdp([string]$targetChatName,[string[]]$imageFiles,[string]$messageText,$teamsCfg,[bool]$isDryRun,[switch]$SelfTest) {
    if([string]::IsNullOrWhiteSpace($messageText)){$messageText=''}
    if(-not $messageText -and -not @($imageFiles).Count){throw '沒有圖片或文字可傳送'}
    if([Text.Encoding]::UTF8.GetByteCount($messageText) -gt 24000){throw 'CDP 訊息超過 24000 bytes'}
    $headless=Test-E3UseHeadless $teamsCfg
    $target=if($SelfTest){$null}else{Resolve-E3CdpTarget $targetChatName -Headless:$headless}
    $images=@()
    # Validate all inputs before the first real send.
    foreach($file in $imageFiles){
        $bytes=[IO.File]::ReadAllBytes($file)
        if($bytes.Length -lt 8 -or $bytes.Length -gt 10MB -or [BitConverter]::ToString($bytes[0..7]) -ne '89-50-4E-47-0D-0A-1A-0A'){throw 'CDP 只接受每張不超過 10 MiB 的 PNG'}
        $ms=[IO.MemoryStream]::new($bytes);$bmp=$null
        try{$bmp=[Drawing.Bitmap]::new($ms);if($bmp.Width -gt 4096 -or $bmp.Height -gt 4096 -or ([long]$bmp.Width*$bmp.Height) -gt 16000000){throw 'CDP 圖片超過 4096 邊長／1600 萬畫素'}}finally{if($bmp){$bmp.Dispose()};$ms.Dispose()}
        $sha=[Security.Cryptography.SHA256]::Create();try{$hash=([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
        $images+=@{bytes=$bytes;size=$bytes.Length;hash=$hash;name=[IO.Path]::GetFileName($file)}
    }
    if($isDryRun -or $teamsCfg.auto_press_enter -eq $false){Write-Host "✅ CDP 綁定與 $($images.Count) 張 PNG 檢查通過；未貼圖、未送出。請用「檢查 CDP 連線」另查專用 Edge。";return}
    $batches=@(Split-TeamsImageBatches $images)
    $mutex=[Threading.Mutex]::new($false,'Local\E3TeamsCdpShared');$locked=$false;$context=0;$token=$null;$started=$false;$finished=$false;$ownedBrowser=$null;$discard=$null
    try{
        $locked=Enter-E3WorkLock $mutex 'cdp' $(if($SelfTest){'Teams 本人測試'}else{'Teams 傳送：'+$targetChatName})
        # A binding may have changed while this new job waited for exclusive access.
        if(-not $SelfTest){$target=Resolve-E3CdpTarget $targetChatName -Headless:$headless}
        if($headless){Reset-E3HeadlessBrowserForNewDelivery}
        if($SelfTest){
            $opened=Open-E3SelfTestCdp $headless;$ownedBrowser=$opened.browser;$context=$opened.context;$target=$opened.target
            Confirm-E3SelfTestDestination "Teams 方式：CDP（無視窗=$headless）`r`n實際帳號：$($target.binding.accountId)`r`n實際對話：$($target.binding.label)`r`n聊天室識別：$($target.binding.chatId)`r`n已驗證為此帳號的個人自聊" $images.Count
            Assert-E3SelfTestCdpBinding $context $target.binding
        }else{
            if($headless){$opened=Open-E3HeadlessTarget $target;$ownedBrowser=$opened.browser;$context=$opened.context}
            else{$s=Get-E3CdpSession;$context=Connect-E3CdpTarget $s $target -PrepareNew}
        }
        $activeRuntime=Invoke-E3Js '({version:E3Cdp.version,imageOnly:E3Cdp.supportsImageOnly === true})' $context
        if(-not $messageText -and -not $activeRuntime.imageOnly){
            throw '原 Teams 分頁尚未載入純圖片功能；本次未貼圖、未送出。請先核對已送訊息與草稿，再重新整理原分頁並回到綁定對話，不需刪除登入資料或重新綁定。'
        }
        $count=$batches.Count
        Initialize-E3DesktopProbe
        $root=Join-Path $script:E3CdpLogRoot ([DateTime]::Now.ToString('yyyy-MM-dd')+'\receipts')
        [IO.Directory]::CreateDirectory($root)|Out-Null
        for($i=0;$i -lt $count;$i++){
            Assert-E3WorkNotCancelled
            $token=[guid]::NewGuid().ToString('N');$started=$false;$finished=$false
            $desktopAtStart=[E3CdpDesktop]::State();$desktopBeforeClick=$null
            $path=Join-Path $root ($token+'.json')
            # Each invocation sends only new content. Check the live browser, never
            # read, migrate, archive or clear a previous job's stored records.
            if($i -eq 0){
                $discard=Clear-E3HeadlessDraftForNewDelivery $target $context $ownedBrowser -Visible:(-not $headless)
            }
            Reset-E3CdpDelivery $context $root $targetChatName
            $batch=@($batches[$i].Items);$payloads=@();$refs=@()
            $item=@{id=$token;text=(Get-TeamsBatchText $messageText ($i+1) $count);state='pending';format='body-v1'}
            foreach($p in $batch){$payloads+=,[Convert]::ToBase64String($p.bytes);$refs+=@{id=$p.hash;sha256=$p.hash;bytes=$p.bytes.Length;mime='image/png'}}
            if($batch.Count){$item.format='output-image-v1';$item.images=@($refs)}
            $payloadJson=ConvertTo-Json -InputObject @($payloads) -Compress
            $itemJson=$item|ConvertTo-Json -Depth 8 -Compress;$bindingJson=$target.binding|ConvertTo-Json -Depth 8 -Compress
            Save-E3CdpState $path @{id=$token;target=$targetChatName;stage='prepared';index=$i+1;count=$count;imageCount=$batch.Count;utc=[DateTime]::UtcNow.ToString('o')}
            Start-E3SendNetwork $target
            # The unique receipt above is this job's durable record. A per-target
            # pending marker would make unrelated future jobs depend on this one.
            $started=$true # A lost transport reply does not prove that start was not executed.
            $init=Invoke-E3Js "E3Cdp.start($itemJson,$bindingJson,$payloadJson)" $context
            if(-not $init.ok){throw $init.error};$started=$true
            Write-Host "🌐 CDP 傳送 $targetChatName 第 $($i+1)/$count 批，共 $($batch.Count) 張圖（文字選填；工作 $token；版本 $($activeRuntime.version)；核對 receipt2；診斷 worker1；headless=$headless），不需解鎖" -ForegroundColor Cyan
            $grant=0;$armed=$false;$lastStage='';$serverUntil=$null;$finalUntil=$null;$finalStableSince=$null;$finalHistory=[Collections.Generic.List[object]]::new();$deadline=[DateTime]::UtcNow.AddSeconds(135);$nextLog=[DateTime]::UtcNow.AddSeconds(20)
            $model=(Get-E3CdpRuntimeSource 'model-ready.js').Replace('/*E3_IMAGE_COUNT*/1',[string]$batch.Count)
            while([DateTime]::UtcNow -lt $deadline){
                Assert-E3WorkNotCancelled
                Update-E3NetworkWorkers
                $status=Invoke-E3Js 'E3Cdp.status()' $context
                if($status.stage -ne $lastStage){Write-Host "  CDP $($status.stage)；桌面=$([E3CdpDesktop]::State())；visibility=$($status.visibility)";$lastStage=$status.stage}
                if($status.result){
                    $serverProof=Get-E3ServerReceipt ([string]$status.result.messageId)
                    if($status.result.outcome -eq 'sent' -and -not $serverProof.ok){
                        if(-not $serverUntil){$serverUntil=[DateTime]::UtcNow.AddSeconds(45);Write-Host '  畫面已出現訊息，等待 Teams 伺服器確認；尚未判定成功…' -ForegroundColor Yellow}
                        if($serverProof.reason -ne 'message_request_failed' -and [DateTime]::UtcNow -lt $serverUntil -and [DateTime]::UtcNow -lt $deadline.AddSeconds(-1)){
                            Start-Sleep -Milliseconds 200
                            continue
                        }
                        $status.result=[pscustomobject]@{outcome='uncertain';error=('畫面有訊息，但未取得相符的 Teams 伺服器確認：'+$serverProof.reason);messageId=$status.result.messageId}
                    }
                    if($status.result.outcome -eq 'sent' -and $serverProof.ok){
                        # Reconcile only this message after server acknowledgement. Never click/paste again.
                        if(-not $finalUntil){$finalUntil=[DateTime]::UtcNow.AddSeconds(12);Write-Host '  伺服器已回應，等待圖片與訊息畫面穩定核對…' -ForegroundColor Yellow}
                        $freshProof=Invoke-E3Js 'E3Receipt.inspect()' $context
                        $status.receipt=Invoke-E3Js 'E3Receipt.diagnostics()' $context
                        $now=[DateTime]::UtcNow
                        if($finalHistory.Count -lt 32 -and ($finalHistory.Count -eq 0 -or $finalHistory[$finalHistory.Count-1].reason -cne $status.receipt.reason)){
                            $finalHistory.Add(@{utc=$now.ToString('o');reason=$status.receipt.reason;images=$status.receipt.images})
                        }
                        $sameMessage=$freshProof -and $freshProof.messageId -ceq $status.result.messageId
                        if($sameMessage){if(-not $finalStableSince){$finalStableSince=$now}}else{$finalStableSince=$null}
                        $stable=$sameMessage -and ($now-$finalStableSince).TotalMilliseconds -ge 1500
                        $terminal=$status.receipt.reason -in @('binding_changed','message_failed') -or ($freshProof -and -not $sameMessage)
                        if(-not $stable -and -not $terminal -and $now -lt $finalUntil -and $now -lt $deadline.AddSeconds(-1)){
                            Start-Sleep -Milliseconds 200
                            continue
                        }
                        if(-not $stable){
                            $status.result=[pscustomobject]@{outcome='uncertain';error='伺服器已有回應，但最終畫面未能穩定通過核對；請人工確認，不自動重送';messageId=$status.result.messageId}
                        }
                    }
                    if($status.result.outcome -eq 'uncertain' -and $status.receipt.reason -eq 'message_text_mismatch'){
                        $status.result.error=if($serverProof.serverAcceptanceObserved){'Teams 伺服器已接受訊息，但送出後文字核對不符；可能已送達，請查看收件內容，不自動重送'}else{'已按送出，但送出後文字核對不符；請查看收件內容，不自動重送'}
                    }
                    Save-E3CdpState $path @{id=$token;target=$targetChatName;stage='finished';runtime=$activeRuntime.version;verification='2026-11-06-receipt2';finalReceiptHistory=@($finalHistory.ToArray());diagnostics='worker1';workerObserver=(Get-E3WorkerSummary);desktopAtStart=$desktopAtStart;desktopBeforeClick=$desktopBeforeClick;headless=$headless;imageCount=$batch.Count;result=$status.result;receipt=$status.receipt;serverReceipt=$serverProof;network=(Get-E3NetworkSummary);preparationCleanup=$discard;editor=$status.editor;preSend=$status.preSend;imageObservations=$status.imageObservations;modelReady=$status.modelReady;focus=$status.focus;visibility=$status.visibility;desktop=[E3CdpDesktop]::State();utc=[DateTime]::UtcNow.ToString('o')}
                    $finished=$true
                    if($status.result.outcome -eq 'not_sent' -and -not $status.clicked -and $status.receipt.reason -in @('not_armed','not_clicked')){
                        # This attempt provably never clicked Send. Remove its partial draft,
                        # retain its failure receipt, and leave the next schedule independent.
                        try {
                            Invoke-E3Js "globalThis[Symbol.for('d46518.teamsCodex.imageFrameProbe')]?.control('stop','$token')"|Out-Null
                            $cleared=Clear-E3HeadlessDraftForNewDelivery $target $context $ownedBrowser -Visible:(-not $headless)
                            Save-E3CdpState ($path+'.draft-cleanup.json') @{version='preparation1';ok=$true;deliveryId=$token;proof=$cleared;retried=$false}
                            Write-Host '🧹 本次尚未按送出，已清除準備失敗留下的草稿；下次排程會重新準備自己的內容。' -ForegroundColor Gray
                        }catch{
                            Save-E3CdpState ($path+'.draft-cleanup.json') @{version='preparation1';ok=$false;deliveryId=$token;error=$_.Exception.Message;retried=$false}
                            Write-Host '⚠️ 本次草稿未完全清除；下次排程開始前會再次核對並清除。' -ForegroundColor Yellow
                        }
                    }
                    if($status.result.outcome -ne 'sent'){throw "第 $($i+1)/$count 批 $($status.result.outcome)：$($status.result.error)；checks=$(@($status.result.failedChecks) -join ',')；receipt=$($status.receipt.reason)。前 $i 批已完成；停止此對象後續圖片，不自動重送。紀錄：$path"}
                    Write-Host "✅ Teams 伺服器已接受訊息 $($serverProof.serverId)，畫面文字與附件核對通過；紀錄：$path" -ForegroundColor Green
                    break
                }
                if($status.checkpoint -and [int]$status.checkpoint.serial -gt $grant){
                    if($status.checkpoint.stage -eq 'before_click'){Update-E3NetworkWorkers;$desktopBeforeClick=[E3CdpDesktop]::State();$script:E3SendNetwork.armed=$true}
                    Save-E3CdpState $path @{id=$token;target=$targetChatName;stage=$status.checkpoint.stage;desktop=[E3CdpDesktop]::State();utc=[DateTime]::UtcNow.ToString('o')};$grant=[int]$status.checkpoint.serial
                }
                if($status.stage -eq 'prepared' -and -not $armed){$f=Invoke-E3Js "globalThis[Symbol.for('d46518.teamsCodex.imageFrameProbe')]?.control('start','$token')";if(-not $f.ok){throw '背景圖片處理未初始化，請重新綁定該分頁'};$armed=$true;$frameStart=[DateTime]::UtcNow}
                if($armed){$elapsed=[int]([DateTime]::UtcNow-$frameStart).TotalMilliseconds;Invoke-E3Js "globalThis[Symbol.for('d46518.teamsCodex.imageFrameProbe')]?.control('pulse','$token',$elapsed)"|Out-Null}
                $ready=if($armed){[bool](Invoke-E3Js $model)}else{$false}
                $readyJs=if($ready){'true'}else{'false'};$armedJs=if($armed){'true'}else{'false'}
                Invoke-E3Js "E3Cdp.tick($readyJs,$grant,$armedJs,false)" $context|Out-Null
                if([DateTime]::UtcNow -gt $nextLog){Write-Host '  等待 Teams 新訊息與附件核對，不會重送…';$nextLog=[DateTime]::UtcNow.AddSeconds(20)}
                Start-Sleep -Milliseconds 100
            }
            if(-not $finished){throw 'CDP 逾時、結果不明；請檢查 Teams，停止後續圖片且不重送'}
            Invoke-E3Js "globalThis[Symbol.for('d46518.teamsCodex.imageFrameProbe')]?.control('stop','$token')"|Out-Null
        }
    }finally{
        if($context -and $started -and -not $finished){
            try {
                $stopped=Stop-E3CdpDelivery $context $token
                Save-E3CdpState $path @{id=$token;target=$targetChatName;stage='cleanup';previous=$stopped;outcome='uncertain';network=(Get-E3NetworkSummary);utc=[DateTime]::UtcNow.ToString('o')}
                if($stopped.stage -ne 'finished'){Write-Host '⚠️ 本次傳送尚未確認停止；後續新工作會核對瀏覽器即時狀態，避免同時操作。' -ForegroundColor Yellow}
            } catch {Write-Host "⚠️ CDP 清理未完成：$($_.Exception.Message)；請先核對 Teams，不要直接重跑" -ForegroundColor Yellow}
        }
        if($token){try{Invoke-E3Js "globalThis[Symbol.for('d46518.teamsCodex.imageFrameProbe')]?.control('stop','$token')"|Out-Null}catch{}}
        Disable-E3CdpBackgroundFocus
        $script:E3SendNetwork=$null
        if($ownedBrowser){Close-E3OwnedBrowser $ownedBrowser}
        if($script:CdpSocket){$script:CdpSocket.Dispose();$script:CdpSocket=$null}
        if($locked){Unregister-E3WorkOwner 'cdp';$mutex.ReleaseMutex()};$mutex.Dispose()
    }
}
 
#endregion
 
#region Browser scripts
# Browser sources are literal here-strings: no PowerShell interpolation or runtime extraction.
# Historical source names below are section identifiers, not filesystem dependencies.
function Get-E3CdpRuntimeSource([string]$file) {
    switch ($file.Replace('\','/')) {
        'vendor/adapter.js' {
            return @'
/* Teams DOM adapter. Selectors must be verified against the signed-in tenant.
   Initial binding requires account evidence; operation uses the saved chat binding. */
(() => {
  'use strict';
  const normalize = (value) => String(value || '').replace(/\r\n?/g, '\n').replace(/\u00a0/g, ' ').trim();
  const deliveryText = (value) => String(value || '').replace(/\r\n?/g, '\n').replace(/\u00a0/g, ' ');
  // Chromium/CKEditor can omit terminal horizontal whitespace from innerText.
  // Keep leading/interior whitespace and every real newline significant.
  const comparableText = value => deliveryText(value).replace(/[ \t]+$/, '');
  const draftOwners = new WeakMap();
  const editorComparisons = new WeakMap();
  const verifiedIcons = new WeakMap();
  const imagePastes = new WeakMap();
  const cleanFormat = (item) => ['body-v1', 'body-v2', 'image-test-v1', 'image-test-v2', 'output-image-v1'].includes(item.format);
  const imageFormat = (item) => ['body-v2', 'image-test-v1', 'image-test-v2', 'output-image-v1'].includes(item.format);
  const iconSource = (image) => image.currentSrc || image.getAttribute('src') || '';
  const knownIcon = (image) => globalThis.BridgeOutgoingImages?.known(image) || (!!globalThis.BridgeCodexIcon && (iconSource(image) === BridgeCodexIcon.src || verifiedIcons.get(image) === iconSource(image)));
  const iconProof = (node) => { const images = [...node.querySelectorAll('img')]; return images.length === 1 && knownIcon(images[0]); };
  const imageProofFor = (node,item) => item.format === 'output-image-v1'
    ? !!globalThis.BridgeOutgoingImages?.proof(node) : iconProof(node);
  function completeImageTree(node) {
    if (![...node.querySelectorAll('img')].length || ![...node.querySelectorAll('img')].every(knownIcon)) return false;
    if ([...node.querySelectorAll('img')].some(image=>!image.complete || (!globalThis.BridgeOutgoingImages?.known(image) && (image.naturalWidth !== 48 || image.naturalHeight !== 48)))) return false;
    let fillers = 0;
    const valid = (child) => {
      if (child.nodeType === 3) {
        if (!child.nodeValue) return true;
        return child.parentNode.nodeName === 'P' && /^(?:\u2060{7})+$/.test(child.nodeValue) && ++fillers <= node.querySelectorAll('img').length;
      }
      if (!['P', 'DIV', 'INLINEIMAGE', 'IMG'].includes(child.nodeName)) return false;
      return [...child.childNodes].every(valid);
    };
    return valid(node);
  }
  function imageBodyText(node) {
    // With no message text CKEditor can contain only verified image paragraphs.
    if (node.childNodes.length && [...node.childNodes].every(child => child.nodeName === 'P' && completeImageTree(child))) return '';
    // Tenant CKEditor puts a stateful image and an inline caret filler in a
    // separate paragraph. Neither contributes a model text paragraph.
    if (node.childNodes.length < 2 || node.firstChild.nodeName !== 'P'
      || ![...node.childNodes].slice(1).every(child=>child.nodeName==='P'&&completeImageTree(child))) return null;
    let text = '';
    let valid = true;
    const read = (child) => {
      if (child.nodeType === 3) text += child.nodeValue;
      else if (child.nodeName === 'BR') {
        if (child.getAttribute('data-cke-filler') === 'true' && child === node.firstChild.lastChild) return;
        text += '\n';
      } else if (['P', 'SPAN', 'A', 'B', 'STRONG', 'I', 'EM', 'U', 'S', 'CODE'].includes(child.nodeName)) {
        for (const nested of child.childNodes) read(nested);
      } else valid = false;
    };
    read(node.firstChild);
    return valid ? deliveryText(text) : null;
  }
  async function verifyIcons(root, wait) {
    if (!globalThis.BridgeCodexIcon && !globalThis.BridgeOutgoingImages) return;
    for (const image of root.querySelectorAll('img')) {
      if (await globalThis.BridgeOutgoingImages?.verify(image,wait)) continue;
      if (!globalThis.BridgeCodexIcon) continue;
      if (knownIcon(image)) continue;
      for (let attempt = 0; !image.complete && attempt < 8; attempt++) await wait(40);
      if (!image.complete || image.naturalWidth !== 48 || image.naturalHeight !== 48) continue;
      try {
        const canvas = image.ownerDocument.createElement('canvas'); canvas.width = canvas.height = 48;
        const ctx = canvas.getContext('2d'); ctx.drawImage(image, 0, 0);
        const pixels = btoa(String.fromCharCode(...ctx.getImageData(0, 0, 48, 48).data));
        if (pixels === BridgeCodexIcon.pixels) verifiedIcons.set(image, iconSource(image));
      } catch (_) { /* Unreadable or altered pixels never become icon evidence. */ }
    }
  }
  function recordImageObservation(composer, expected, stage) {
    const paste = imagePastes.get(composer);
    if (!paste) return;
    const describe = (node) => ({tag: node.tagName.toLowerCase(),
      attributeNames: node.getAttributeNames().sort(),
      editorClasses: [...node.classList].filter((name) => /^ck-[a-z_-]{1,60}$/i.test(name)).slice(0, 8),
      contentEditable: ['true', 'false'].includes(node.getAttribute('contenteditable')) ? node.getAttribute('contenteditable') : '',
      children: node.childElementCount, textLength: (node.textContent || '').length,
      textKind: !node.textContent ? 'empty' : node.textContent === '\u2060'.repeat(7) ? 'cke-inline-filler'
        : /^\s+$/.test(node.textContent) ? 'whitespace' : 'other',
      imageCount: node.querySelectorAll('img').length});
    const ancestors = [];
    let node = composer.querySelector('img')?.parentElement;
    while (node && node !== composer && ancestors.length < 6) {
      ancestors.push(describe(node)); node = node.parentElement;
    }
    const observation = {stage, visibility: composer.ownerDocument.visibilityState,
      textMatches: composerTextMatches(composer, expected),
      renderedLength: deliveryText(composer.innerText || composer.textContent).length,
      knownImage: iconProof(composer),
      children: [...composer.children].slice(0, 8).map(describe),
      imageAncestors: ancestors,
      descendants: [...composer.querySelectorAll('*')].slice(0, 32).map(describe)};
    const observations = paste.observations || (paste.observations = []);
    if (JSON.stringify(observations.at(-1)) === JSON.stringify(observation)) return;
    observations.push(observation);
    if (observations.length > 8) observations.shift();
  }
  const latestPositions = new WeakMap();
  let latestViewport = null;
  const listSelector = '[data-tid="chat-message-list"], [data-tid="message-pane-list-viewport"]';
  const account = (value) => normalize(value).toLowerCase();
  const paneSelector = '[data-tid="chat-pane"], [data-tid="chat-pane-layout"], [data-tid="message-pane-layout"]';
  const headerSelector = '[data-tid="chat-header"], [data-tid="chat-header-bar"], [data-tid="entity-header"]';
  const titleSelector = '[data-tid="chat-header-title"], [data-tid="chat-title"]';
  const sendSelector = '[data-tid="send-message-button"], [data-tid="send-button"], [data-tid="sendMessageCommands-send"], [data-tid="newMessageCommands-send"]';
  const composeAreaSelector = '[data-tid="compose-box"], [data-tid="message-composer-container"], [data-tid="chat-pane-compose-message-footer"]';
  const rowSelector = '[data-message-id], [data-tid="chat-pane-message"]';
  const bodySelector = '[data-tid="message-body"], [data-tid="chat-pane-message-content"], [data-message-content]';
  const composerSelector = '[data-tid="ckeditor"][contenteditable="true"], [data-tid="message-composer"][contenteditable="true"], [data-tid="compose-box"] [role="textbox"][contenteditable="true"]';
  const fail = (error) => ({ok: false, error});
  // Isolated-world memory only; saved bindings do not depend on this proof.
  const identityState = globalThis.BridgeAdapter?.identityState || {proof: null};
  const selfSuffixPattern = /[（(]\s*(?:您|你|自己|you)\s*[）)]\s*$/i;
  const displayName = (value) => normalize(value).replace(/\s+/g, ' ');
  const emails = (value) => [...new Set((String(value || '').match(/[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9.-]+\.[a-z]{2,}/gi) || []).map(account))];
  const profileFingerprint = (node) => JSON.stringify([node.id, node.getAttribute('aria-label'),
    node.getAttribute('data-account-email'), node.getAttribute('data-account-id'),
    [...node.querySelectorAll('[data-tid="me-control-avatar"]')].map((avatar) => [avatar.id, avatar.getAttribute('aria-label'), avatar.textContent])]);
 
  function refreshIdentity(doc) {
    const profiles = [...doc.querySelectorAll('[data-tid="me-control-avatar-trigger"]')];
    const profile = profiles.length === 1 ? profiles[0] : null;
    const menus = [...doc.querySelectorAll('[data-tid="me-control-menu-dialog"]')];
    const evidence = {profileCount: profiles.length, menuCount: menus.length,
      profileExpanded: profile?.getAttribute('aria-expanded') === 'true', accountMenuCount: 0,
      signoutCount: 0, displayNameCount: 0, signoutEmailCount: 0, leafEmailCount: 0,
      emailsAgree: false, cachedProofValid: false};
    const finish = (code, proof = null) => {
      identityState.evidence = {...evidence, code, cachedProofValid: !!proof};
      return proof;
    };
    let proof = identityState.proof;
    if (proof && (!profile || profile !== proof.profile || !profile.isConnected || profileFingerprint(profile) !== proof.fingerprint)) {
      identityState.proof = null;
      proof = null;
    }
    const reject = (code) => { identityState.proof = null; return finish(code); };
    if (!profile) return reject('ACCOUNT_PROFILE_AMBIGUOUS');
    if (menus.length) {
      if (menus.length !== 1) return reject('ACCOUNT_MENU_AMBIGUOUS');
      const menu = menus[0];
      const accountMenus = [...menu.querySelectorAll('[data-tid="me-control-menu"]')];
      const signouts = [...menu.querySelectorAll('[data-tid="me-control-sign-out-button"]')];
      const names = [...menu.querySelectorAll('[data-tid="me-control-displayname"]')];
      Object.assign(evidence, {accountMenuCount: accountMenus.length, signoutCount: signouts.length, displayNameCount: names.length});
      if (accountMenus.length !== 1 || signouts.length !== 1 || names.length !== 1) return reject('ACCOUNT_FIELDS_MISSING_OR_AMBIGUOUS');
      const ids = emails(signouts[0].getAttribute('aria-label'));
      evidence.signoutEmailCount = ids.length;
      if (ids.length !== 1) return reject('ACCOUNT_SIGNOUT_EMAIL_AMBIGUOUS');
      // Ignore arbitrary status-note text; compare the visible account email independently.
      const leafIds = [...new Set([...accountMenus[0].querySelectorAll('span[dir]')]
        .filter((node) => !node.childElementCount && !node.closest('[data-tid="me-control-status-note-container"]'))
        .flatMap((node) => emails(node.textContent)))];
      evidence.leafEmailCount = leafIds.length;
      evidence.emailsAgree = leafIds.length === 1 && leafIds[0] === ids[0];
      if (leafIds.length !== 1) return reject('ACCOUNT_LEAF_EMAIL_AMBIGUOUS');
      if (!evidence.emailsAgree) return reject('ACCOUNT_EMAIL_CONFLICT');
      const name = displayName(names[0].textContent);
      if (!name) return reject('ACCOUNT_DISPLAY_NAME_EMPTY');
      if (evidence.profileExpanded) {
        proof = identityState.proof = {profile, fingerprint: profileFingerprint(profile), accountId: ids[0], name};
      } else {
        // Pointerdown outside Teams' flyout collapses it before our button click.
        // Reuse only an already verified, unchanged account; never acquire from a closed menu.
        if (!proof) return finish('ACCOUNT_MENU_CLOSED_UNVERIFIED');
        if (proof.accountId !== ids[0] || proof.name !== name) return reject('ACCOUNT_CHANGED');
      }
    }
    return proof ? finish(evidence.profileExpanded ? 'ACCOUNT_VERIFIED' : 'ACCOUNT_VERIFIED_CACHED', proof) : finish('ACCOUNT_MENU_NOT_OPEN');
  }
 
  function accountEvidence(doc) {
    refreshIdentity(doc);
    return {...identityState.evidence};
  }
 
  function chatFromUrl(href) {
    try {
      const url = new URL(href);
      if (!['teams.microsoft.com', 'teams.cloud.microsoft'].includes(url.hostname)) return '';
      const route = url.pathname + url.hash.replace(/^#/, '');
      const match = route.match(/\/chat\/([^/?#]+)/);
      const id = match ? decodeURIComponent(match[1]) : '';
      return /^19:[^\s]+$/.test(id) ? id : '';
    } catch (_) {
      return '';
    }
  }
 
  function inspect(doc, href, expected, allowGroup = false) {
    if (expected?.groupReport && !globalThis.BridgeGroupReportRuntime?.accountMatches(expected))
      return fail('GROUP_REPORT_ACCOUNT_NOT_VERIFIED');
    try {
      if (!['teams.microsoft.com', 'teams.cloud.microsoft'].includes(new URL(href).hostname)) return fail('目前分頁不是 Teams');
    } catch (_) { return fail('無法辨識目前 Teams 網址'); }
    const roots = [...doc.querySelectorAll(paneSelector)].filter((node) => !node.parentElement?.closest(paneSelector));
    if (roots.length !== 1) return fail('目前聊天區域無法唯一辨識');
    const root = roots[0];
    const headers = [...doc.querySelectorAll(headerSelector)];
    if (headers.length !== 1) return fail('無法唯一辨識目前聊天標題');
    const header = headers[0];
    const title = normalize(header.querySelector(titleSelector)?.textContent || header.getAttribute('aria-label'));
    const explicitSelf = header.getAttribute('data-is-self-chat') === 'true' || !!header.querySelector('[data-tid="self-chat-indicator"], [data-tid="note-to-self"]') || /^(note to self|與自己聊天|传送给自己|傳送給自己|給自己的訊息)$/i.test(title);
    const selfAccount = account(header.getAttribute('data-self-account-id') || header.querySelector('[data-tid="self-chat-indicator"], [data-tid="note-to-self"]')?.getAttribute('data-account-id') || header.querySelector('[data-tid="chat-header-participant"][data-is-self="true"]')?.getAttribute('data-account-email'));
    const domId = root.getAttribute('data-chat-id') || header.getAttribute('data-chat-id') || '';
    const urlId = chatFromUrl(href);
    if (domId && urlId && domId !== urlId) return fail('網址與聊天識別不一致');
    const sendIds = [...new Set([...root.querySelectorAll(sendSelector)].map((node) => node.getAttribute('data-track-thread-id') || '').filter((value) => /^(?:19|48):[^\s]+$/.test(value)))];
    if (sendIds.length > 1 || (sendIds.length && (domId || urlId) && sendIds[0] !== (domId || urlId))) return fail('送出鈕與聊天識別不一致');
    const chatId = domId || urlId || sendIds[0] || '';
    if (!/^(?:19|48):[^\s]+$/.test(chatId)) return fail('缺少穩定的聊天識別');
    // The user-selected dedicated tab uses its saved binding during operation.
    // Account flyout and avatar DOM lifetime are required only for first binding.
    if (expected && typeof expected.accountId === 'string' && expected.accountId.trim()
      && expected.chatId === chatId) {
      return {ok: true, root, binding: {...expected, label: title || expected.label || '自聊'}};
    }
    if (expected) return fail('目前聊天室與保存的自聊不同');
    const verifiedAccount = refreshIdentity(doc);
    const profiles = [...doc.querySelectorAll('[data-tid="me-control-avatar-trigger"], [data-tid="me-control-profile"], [data-tid="me-control-account-info"]')];
    const profileIds = [...new Set(profiles.map((node) => account(node.getAttribute('data-account-email') || node.getAttribute('data-account-id') || node.querySelector('[data-tid="me-control-email"]')?.textContent)).filter(Boolean))];
    if (verifiedAccount) profileIds.push(verifiedAccount.accountId);
    const accountIds = [...new Set(profileIds)];
    if (accountIds.length !== 1) return fail('無法驗證登入帳號；請在 Teams 頁內開啟帳號選單並驗證綁定（' + identityState.evidence.code + '）');
    const notesSelf = !!verifiedAccount && /^48:/.test(chatId) && selfSuffixPattern.test(title)
      && displayName(title.replace(selfSuffixPattern, '')) === verifiedAccount.name;
    if (!allowGroup && !(explicitSelf && selfAccount === accountIds[0]) && !notesSelf) return fail('此分頁尚未驗證為登入帳號的自聊');
    if (selfAccount && selfAccount !== accountIds[0]) return fail('本人標記與登入帳號不一致');
    return {ok: true, root, binding: {accountId: accountIds[0], chatId, label: title || '自聊', isSelf: notesSelf || (explicitSelf && selfAccount === accountIds[0])}};
  }
function sameBinding(actual, expected) {
    return !!actual && !!expected && actual.accountId === expected.accountId && actual.chatId === expected.chatId;
  }
 
  function diagnostics(doc, href = '', deliveryOnly = false) {
    const groups = {pane: paneSelector, profile: '[data-tid="me-control-avatar-trigger"], [data-tid="me-control-profile"], [data-tid="me-control-account-info"]', header: headerSelector, composer: composerSelector, sendButton: sendSelector};
    const report = Object.fromEntries(Object.entries(groups).map(([name, selector]) => {
      const nodes = [...doc.querySelectorAll(selector)];
      return [name, {count: nodes.length, attributeNames: [...new Set(nodes.flatMap((node) => node.getAttributeNames()))].sort()}];
    }));
    report.versions = {adapter: '1.0.36'};
    report.accountVerification = accountEvidence(doc);
    const safeTid = (node) => {
      const value = node?.getAttribute('data-tid') || '';
      return value.length <= 100 && /^[a-z][a-z0-9_-]*$/i.test(value) && !/\d{7}|@|https?:/i.test(value) ? value : '';
    };
    const describe = (node) => ({tag: node.tagName.toLowerCase(), tid: safeTid(node),
      role: /^(button|textbox|main|heading|list|listitem|region|toolbar|group|dialog|presentation)$/.test(node.getAttribute('role') || '') ? node.getAttribute('role') : '',
      attributeNames: node.getAttributeNames().sort(), children: node.childElementCount});
    const tids = new Map();
    for (const node of deliveryOnly ? [] : doc.querySelectorAll('[data-tid]')) {
      const tid = safeTid(node);
      if (tid && /chat|message|compose|send|profile|account|header|me-control|ckeditor|participant|self/i.test(tid)) tids.set(tid, (tids.get(tid) || 0) + 1);
    }
    const composer = doc.querySelector(composerSelector);
    const composeRoot = composer?.closest(composeAreaSelector);
    const viewport = doc.querySelector(paneSelector)?.querySelector(listSelector);
    report.outboundImages = globalThis.BridgeOutgoingImages?.diagnostics?.() || [];
    report.deliveryEvidence = {composerCount: doc.querySelectorAll(composerSelector).length,
      positionPolicy: 'any-position',
      sendCount: doc.querySelectorAll(sendSelector).length, composerInsidePane: !!composer?.closest(paneSelector),
      hasTextDraft: !!composer?.textContent?.length,
      hasRichDraft: !!composer?.querySelector('inlineimage,img,video,audio,canvas,svg,iframe,object,embed,input,button,[contenteditable="false"],[data-tid*="attachment"],[data-attachment-id]'),
      hasAttachments: !!composeRoot?.querySelector('[data-tid*="attachment"],[data-attachment-id]'),
      codeBlockCount: composer?.querySelectorAll('[data-tid="code-block-editor-header-container"]').length || 0,
      sendDisabled: !!doc.querySelector(sendSelector)?.disabled,
      sendAriaDisabled: doc.querySelector(sendSelector)?.getAttribute('aria-disabled') === 'true',
      editorKind: composer?.classList.contains('ck-editor__editable') || composer?.classList.contains('ck-content') ? 'ckeditor' : composer ? 'contenteditable' : 'missing',
      editorComparison: composer ? editorComparisons.get(composer) || null : null,
      imagePaste: composer && imagePastes.has(composer) ? {...imagePastes.get(composer),
        imageCount: composer.querySelectorAll('img').length,
        loadedImageCount: [...composer.querySelectorAll('img')].filter((image) => image.complete && image.naturalWidth > 0).length,
        knownImage: iconProof(composer)} : null,
      viewport: {found: !!viewport, atLatest: atLatest(doc), visibility: doc.visibilityState,
        observedLatestIntent: !!(viewport && latestPositions.get(viewport)?.following),
        latestButtonPresent: !!doc.querySelector(paneSelector)?.querySelector('[data-tid="jump-to-latest"], [data-tid="jump-to-latest-button"]'),
        height: viewport?.clientHeight || 0, distanceFromBottom: viewport ? Math.max(0, viewport.scrollHeight - viewport.scrollTop - viewport.clientHeight) : null}};
    report.inboundImages = {downloads: globalThis.BridgeInboundImages?.diagnostics?.() || [],
      displayed: [...doc.querySelectorAll(paneSelector)].flatMap(pane => [...pane.querySelectorAll(bodySelector)]).slice(-12).flatMap(body => [...body.querySelectorAll('img')].slice(0,4).map(image => ({
        attributeNames: image.getAttributeNames().sort(), width: image.naturalWidth, height: image.naturalHeight, complete: image.complete,
        currentSourceKind: image.currentSrc ? new URL(image.currentSrc,doc.baseURI).protocol : 'empty',
        sourceAttributes: ['src','data-src','data-original','srcset'].filter(name => image.hasAttribute(name)),
        wrapperTags: [image.parentElement?.tagName, image.parentElement?.parentElement?.tagName].filter(Boolean)})))};
    if (deliveryOnly) return report;
    const ancestors = [];
    const seenCommands = new Set();
    let ancestor = composer?.parentElement;
    for (let depth = 0; ancestor && depth < 8; depth += 1, ancestor = ancestor.parentElement) {
      const commands = [...ancestor.querySelectorAll('button,[role="button"]')].filter((node) => {
        const tid = safeTid(node);
        if (!tid || !/send|compose|message|attachment/i.test(tid) || seenCommands.has(tid)) return false;
        seenCommands.add(tid);
        return true;
      }).slice(0, 20).map(describe);
      ancestors.push({...describe(ancestor), commands});
    }
    report.structure = {markers: [...tids].slice(0, 100).map(([tid, count]) => ({tid, count})),
      composerAncestors: ancestors, headers: [...doc.querySelectorAll('header,[role="heading"]')].slice(0, 12).map(describe)};
    const hasEmail = (value) => /[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9.-]+\.[a-z]{2,}/i.test(value || '');
    const selfSuffix = (value) => /[（(]\s*(?:您|你|自己|本人|you)\s*[）)]\s*$/i.test(normalize(value));
    const timeKind = (value) => {
      const text = normalize(value);
      if (!text) return 'empty';
      if (/^(?:\d{10}|\d{13})$/.test(text)) return 'epoch';
      if (/^\d{4}-\d{2}-\d{2}T.*(?:Z|[+-]\d{2}:\d{2})$/.test(text)) return 'iso-with-zone';
      if (/\d{1,2}:\d{2}/.test(text)) return 'local-time';
      return 'other';
    };
    const identityNode = (node) => ({...describe(node), emailInAriaLabel: hasEmail(node.getAttribute('aria-label')),
      emailInTitle: hasEmail(node.getAttribute('title')), emailInText: hasEmail(node.textContent),
      selfSuffix: selfSuffix(node.textContent) || selfSuffix(node.getAttribute('aria-label')),
      explicitSelf: node.getAttribute('data-is-self-chat') === 'true',
      hasAccountAttribute: !!(node.getAttribute('data-account-email') || node.getAttribute('data-account-id') || node.getAttribute('data-self-account-id'))});
    report.bindingEvidence = {
      panes: [...doc.querySelectorAll(paneSelector)].slice(0, 3).map(describe),
      profile: [...doc.querySelectorAll(groups.profile)].slice(0, 6).map(identityNode),
      accountMenu: [...doc.querySelectorAll('[data-tid*="me-control"]')].filter((node) => !node.matches('[data-tid="me-control-avatar-trigger"], [data-tid="me-control-avatar"], [data-tid="me-control-avatar-presence"]')).slice(0, 24).map(identityNode),
      headers: [...doc.querySelectorAll(headerSelector)].slice(0, 3).map(identityNode),
      titles: [...doc.querySelectorAll(titleSelector)].slice(0, 3).map(identityNode),
      selfIndicators: [...doc.querySelectorAll('[data-tid="self-chat-indicator"], [data-tid="note-to-self"]')].slice(0, 3).map(identityNode),
      sendCommands: [...doc.querySelectorAll(sendSelector)].slice(0, 3).map((node) => ({...describe(node),
        hasStableThreadId: /^19:[^\s]+$/.test(node.getAttribute('data-track-thread-id') || '')}))
    };
    const idKind = (value) => !value ? 'empty' : /^19:[^\s]+$/.test(value) ? 'teams-thread' : /^48:[^\s]+$/.test(value) ? 'notes-thread' : /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(value) ? 'uuid' : /^[\[{]/.test(value) ? 'encoded-object' : 'other';
    try {
      const url = new URL(href || doc.location?.href || '');
      const route = url.pathname + url.hash.replace(/^#/, '');
      const match = route.match(/\/chat\/([^/?#]+)/);
      const queryIds = [...url.searchParams].filter(([key]) => /thread|chat|conversation/i.test(key));
      report.routeEvidence = {hostIsTeams: ['teams.microsoft.com', 'teams.cloud.microsoft'].includes(url.hostname),
        queryKeys: [...url.searchParams.keys()].filter((key) => /^[a-z][a-z0-9_-]{0,50}$/i.test(key)),
        hasHash: !!url.hash, hasChatPath: !!match, chatIdKind: idKind(match ? decodeURIComponent(match[1]) : ''),
        queryIdKinds: queryIds.map(([key, value]) => ({key, kind: idKind(value)}))};
    } catch (_) { report.routeEvidence = {error: 'unavailable'}; }
    report.bindingEvidence.threadSources = [...doc.querySelectorAll('[data-chat-id], [data-track-thread-id]')].slice(0, 8).map((node) => ({
      ...describe(node), chatIdKind: idKind(node.getAttribute('data-chat-id')), threadIdKind: idKind(node.getAttribute('data-track-thread-id'))}));
    const menuRoots = [...doc.querySelectorAll('[role="dialog"], [role="menu"], [data-tid*="me-control"], [id^="mectrl"], [id^="meControl"]')].filter((node) => !node.closest(paneSelector) && !node.closest('[data-teams-codex-diagnostic]'));
    const menuCandidates = new Set(menuRoots);
    for (const root of menuRoots) for (const node of root.querySelectorAll('*')) {
      if ((node.childElementCount === 0 || node.hasAttribute('data-tid')) && (hasEmail(node.textContent) || node.hasAttribute('data-tid'))) menuCandidates.add(node);
    }
    report.bindingEvidence.accountMenu = [...menuCandidates].slice(0, 40).map((node) => ({...identityNode(node),
      idKind: /^(?:mectrl|meControl)[a-z0-9_-]*$/i.test(node.id) ? node.id : node.id ? 'other' : 'empty'}));
    report.bindingEvidence.profileExpanded = doc.querySelector('[data-tid="me-control-avatar-trigger"]')?.getAttribute('aria-expanded') === 'true';
    report.bindingEvidence.frames = [...doc.querySelectorAll('iframe')].slice(0, 8).map((node) => {
      let originKind = 'other';
      try { const host = new URL(node.src, href || doc.location?.href).hostname; originKind = /(?:^|\.)microsoft\.com$|(?:^|\.)live\.com$/.test(host) ? 'microsoft-account' : host === doc.location?.hostname ? 'same-origin' : 'other'; } catch (_) {}
      return {...describe(node), originKind};
    });
    const messageNodes = [...doc.querySelectorAll('[data-tid="chat-pane-message"]')];
    report.messageEvidence = {count: messageNodes.length, samples: messageNodes.slice(-2).map((node) => ({
      ...describe(node), hasId: !!node.id, hasMessageId: !!node.getAttribute('data-message-id'),
      timestampKind: timeKind(node.getAttribute('data-timestamp')),
      ancestors: [node.parentElement, node.parentElement?.parentElement].filter(Boolean).map(describe),
      descendants: [...node.querySelectorAll('*')].slice(0, 16).map((child) => ({...describe(child),
        idKind: /^content-/.test(child.id) ? 'content-prefix' : /^message-/.test(child.id) ? 'message-prefix' : /^\d+$/.test(child.id) ? 'numeric' : child.id ? 'other' : 'empty'})),
      timeNodes: [...(node.closest('[data-tid="chat-pane-item"]') || node).querySelectorAll('time,[datetime],[data-timestamp],[title],[aria-label]')].slice(0, 12).map((child) => ({
        ...describe(child), datetimeKind: timeKind(child.getAttribute('datetime')), timestampKind: timeKind(child.getAttribute('data-timestamp')),
        titleKind: timeKind(child.getAttribute('title')), ariaLabelKind: timeKind(child.getAttribute('aria-label')),
        textKind: child.tagName === 'TIME' ? timeKind(child.textContent) : 'not-read'}))
    }))};
    return report;
  }
 
  function readRows(root) {
    const messages = [];
    const ids = new Set();
    for (const row of root.querySelectorAll(rowSelector)) {
      if (row.parentElement?.closest(rowSelector)) continue;
      const id = row.getAttribute('data-message-id') || row.getAttribute('data-mid') || row.id;
      const bodies = [...row.querySelectorAll(bodySelector)].filter((node) => !node.parentElement?.closest(bodySelector));
      if (bodies.length !== 1) return fail('訊息正文容器缺少或無法唯一辨識；已暫停擷取');
      const body = bodies[0];
      const text = imageBodyText(body) ?? deliveryText(body.innerText || body.textContent);
      let times = [...row.querySelectorAll('time[datetime]')];
      if (!times.length && !row.getAttribute('data-timestamp')) {
        const item = row.closest('[data-tid="chat-pane-item"]');
        // The tenant timestamp is a sibling. Never reuse one from a grouped second message.
        const siblings = item && [...item.querySelectorAll(rowSelector)].filter((node) => !node.parentElement?.closest(rowSelector));
        if (siblings?.length === 1 && siblings[0] === row) times = [...item.querySelectorAll('time[datetime]')];
      }
      if (times.length > 1) return fail('timestamp 無法唯一對應訊息；已暫停擷取');
      const stamp = times[0]?.getAttribute('datetime') || row.getAttribute('data-timestamp');
      const epoch = stamp && /^(?:\d{10}|\d{13})$/.test(stamp);
      const fullTime = stamp && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(stamp);
      if (!epoch && !fullTime) return fail('timestamp 缺少完整時間與時區；已暫停擷取');
      const numeric = epoch ? Number(stamp) * (stamp.length === 10 ? 1000 : 1) : stamp;
      const timestamp = numeric ? new Date(numeric) : null;
      if (!id || !timestamp || Number.isNaN(timestamp.getTime())) return fail('message id / timestamp 缺少或無法解析；已暫停擷取');
      if (ids.has(id)) return fail('訊息識別重複；已暫停擷取');
      ids.add(id);
      const photos = [...body.querySelectorAll('img')].filter(image => !image.closest('[data-emoji], [data-tid*="emoji"], [class*="emoji"], [class*="emoticon"]'));
      const images = photos.map((image,index) => {
        const sources = [...new Set([image.currentSrc, image.getAttribute('src'), image.getAttribute('data-src'), image.getAttribute('data-original')].filter(Boolean)
          .map(src => new URL(src, body.ownerDocument.baseURI).href))];
        return {index, src: sources[0] || '', sources};
      });
      if (!images.length && body.querySelector('inlineimage, [data-inline-image]')) images.push({index: 0, src: ''});
      let inputText = text;
      if (images.length && imageBodyText(body) === null && !/^\s*(?:✦\s*)?\[Codex\]/.test(text)) {
        const plain = body.cloneNode(true);
        for (const image of plain.querySelectorAll('img, inlineimage, [data-inline-image]')) image.remove();
        const walker = body.ownerDocument.createTreeWalker(plain, 4);
        while (walker.nextNode()) if (walker.currentNode.nodeValue === '\u2060'.repeat(7)) walker.currentNode.nodeValue = '';
        inputText = deliveryText(plain.innerText || plain.textContent).trim();
      }
      messages.push({id, text: inputText, time: timestamp.toISOString(), ...(iconProof(body) ? {icon: 'codex'} : {}),
        ...(imageProofFor(body,{format:'output-image-v1'}) ? {outputImage:true} : {}), ...(images.length ? {images} : {})});
    }
    return {ok: true, messages};
  }
 
  function snapshot(doc, href, expected) {
    const context = inspect(doc, href, expected);
    if (!context.ok) return context;
    if (expected && !sameBinding(context.binding, expected)) return fail('目前分頁已切換帳號或聊天');
    const rows = readRows(context.root);
    return rows.ok ? {ok: true, binding: context.binding, messages: rows.messages} : rows;
  }
 
  function hasContinuity(prior, messages) {
    if (!prior.length) return true;
    const ids = new Set(messages.map((message) => message.id));
    return prior.some((id) => ids.has(id));
  }
 
  function atLatest(doc) {
    const root = doc.querySelector(paneSelector);
    const list = root?.querySelector(listSelector);
    if (!root || !list || !list.clientHeight || root.querySelector('[data-tid="jump-to-latest"], [data-tid="jump-to-latest-button"]')) return false;
    return list.scrollTop + list.clientHeight >= list.scrollHeight - 2 && root.querySelectorAll(rowSelector).length > 0;
  }
 
  function followLatest(doc, binding) {
    const current = inspect(doc, doc.location.href, binding);
    if (!current.ok || !sameBinding(current.binding, binding)) return false;
    const list = current.root.querySelector(listSelector);
    if (!list || !list.clientHeight) return false;
    let position = latestPositions.get(list);
    if (!position || !sameBinding(position.binding, binding)) {
      const prior = latestViewport;
      const rows = [...list.querySelectorAll(rowSelector)].map((row) => row.getAttribute('data-message-id') || row.getAttribute('data-mid') || row.id);
      const transfer = prior && !prior.node.isConnected && prior.position.following
        && sameBinding(prior.position.binding, binding) && hasContinuity(prior.position.ids, rows.map((id) => ({id})))
        && !current.root.querySelector('[data-tid="jump-to-latest"], [data-tid="jump-to-latest-button"]');
      if (transfer) list.scrollTop = list.scrollHeight;
      position = {binding, following: atLatest(doc), top: list.scrollTop, ids: rows,
        height: list.scrollHeight, clientHeight: list.clientHeight};
      latestPositions.set(list, position);
      const manual = (event) => {
        if (event.type !== 'keydown' || ['ArrowUp', 'ArrowDown', 'PageUp', 'PageDown', 'Home', 'End', ' '].includes(event.key)) position.following = false;
      };
      for (const type of ['wheel', 'touchstart', 'pointerdown', 'keydown']) list.addEventListener(type, manual, {passive: true});
      list.addEventListener('scroll', () => {
        if (latestPositions.get(list) !== position) return;
        // Preserve only a previously observed bottom position during layout
        // growth; a scroll within unchanged geometry is a history position.
        const resized = position.height !== list.scrollHeight || position.clientHeight !== list.clientHeight;
        if (doc.visibilityState !== 'hidden' && !resized && list.scrollTop !== position.top) position.following = atLatest(doc);
      }, {passive: true});
    }
    const resized = position.height !== list.scrollHeight || position.clientHeight !== list.clientHeight;
    // A hidden Teams renderer may move its viewport or display its latest button
    // when messages arrive. Retain only an already observed bottom intent;
    // wheel/touch/pointer/navigation events still revoke it even while hidden.
    const hiddenFollowing = doc.visibilityState === 'hidden' && position.following;
    if (!hiddenFollowing && current.root.querySelector('[data-tid="jump-to-latest"], [data-tid="jump-to-latest-button"]')) position.following = false;
    if (!hiddenFollowing && !resized && list.scrollTop !== position.top) position.following = atLatest(doc);
    if (position.following && (resized || hiddenFollowing)) list.scrollTop = list.scrollHeight;
    const latest = atLatest(doc);
    // Never send while the latest button still exists. Preserve intent so a
    // subsequent render can remove that button after reaching the bottom.
    position.following = latest || hiddenFollowing;
    position.top = list.scrollTop;
    position.height = list.scrollHeight;
    position.clientHeight = list.clientHeight;
    position.ids = [...list.querySelectorAll(rowSelector)].map((row) => row.getAttribute('data-message-id') || row.getAttribute('data-mid') || row.id);
    latestViewport = {node: list, position};
    return latest;
  }
 
  function mergeMessages(windows) {
    const rows = new Map();
    for (const messages of windows) for (const message of messages) if (!rows.has(message.id)) rows.set(message.id, message);
    return [...rows.values()].sort((left, right) => Date.parse(left.time) - Date.parse(right.time));
  }
 
  function eligibleMessages(messages, boundary) {
    if (!boundary?.time) return messages;
    const initialIds = new Set(boundary.ids || []);
    const cutoff = Date.parse(boundary.time);
    let lastAnchor = -1;
    messages.forEach((message, index) => { if (initialIds.has(message.id) && Date.parse(message.time) === cutoff) lastAnchor = index; });
    return messages.filter((message, index) => initialIds.has(message.id) || Date.parse(message.time) > cutoff || (lastAnchor !== -1 && index > lastAnchor && Date.parse(message.time) === cutoff));
  }
 
  async function catchUp(doc, href, expected, anchors, options = {}) {
    let result = snapshot(doc, href(), expected);
    if (!result.ok) return result;
    if (hasContinuity(anchors, result.messages)) return {...result, continuity: true};
    const windows = [result.messages];
    let connected = true;
    let previousWindow = result.messages;
    const context = inspect(doc, href(), expected);
    const list = context.root?.querySelector(listSelector);
    if (!list) return {...result, continuity: false};
    const savedTop = list.scrollTop;
    const savedHeight = list.scrollHeight;
    try {
      for (let attempt = 0; attempt < (options.attempts || 16); attempt += 1) {
        if (!sameBinding(inspect(doc, href(), expected).binding, expected)) return fail('補讀期間聊天已切換');
        list.scrollTop = Math.max(0, list.scrollTop - Math.max(1, list.clientHeight / 2));
        list.dispatchEvent(new Event('scroll', {bubbles: true}));
        await (options.wait ? options.wait(options.waitMs || 350) : new Promise((resolve) => setTimeout(resolve, options.waitMs || 350)));
        const next = snapshot(doc, href(), expected);
        if (!next.ok) return next;
        if (!hasContinuity(previousWindow.map((message) => message.id), next.messages)) connected = false;
        previousWindow = next.messages;
        windows.unshift(next.messages);
        result = {...next, messages: mergeMessages(windows)};
        if (hasContinuity(anchors, result.messages)) return {...result, continuity: connected};
      }
      return {...result, continuity: false};
    } finally {
      if (list.isConnected && sameBinding(inspect(doc, href(), expected).binding, expected)) list.scrollTop = savedTop + Math.max(0, list.scrollHeight - savedHeight);
    }
  }
 
  async function reconcile(doc, href, binding, item, wait) {
    if (imageFormat(item)) await verifyIcons(doc.querySelector(paneSelector) || doc, wait);
    const current = snapshot(doc, href, binding);
    if (!current.ok) return null;
    if (cleanFormat(item)) {
      if (!['sending', 'uncertain'].includes(item.state)) return null;
      const boundary = item.boundary;
      if (!validDeliveryBoundary(boundary) || !hasContinuity(boundary.ids, current.messages)) return null;
      const excluded = new Set(boundary.ids);
      const cutoff = boundary.time === null ? -Infinity : Date.parse(boundary.time);
      let lastCutoffAnchor = -1;
      current.messages.forEach((message, index) => {
        if (excluded.has(message.id) && Date.parse(message.time) === cutoff) lastCutoffAnchor = index;
      });
      const matches = current.messages.filter((message, index) => !excluded.has(message.id)
        && (Date.parse(message.time) > cutoff || (lastCutoffAnchor >= 0 && index > lastCutoffAnchor && Date.parse(message.time) === cutoff))
        && comparableText(message.text) === comparableText(item.text)
        && (!imageFormat(item) || (item.format === 'output-image-v1' ? message.outputImage === true : message.icon === 'codex')));
      return matches.length === 1 ? matches[0] : null;
    }
    if (!item.id || !normalize(item.text).includes(item.id)) return null;
    return current.messages.find((message) => message.text.includes(item.id) && normalize(message.text) === normalize(item.text)) || null;
  }
 
  function validDeliveryBoundary(boundary) {
    return !!boundary && Array.isArray(boundary.ids) && boundary.ids.length <= 500
      && boundary.ids.every((id) => typeof id === 'string' && id.length > 0 && id.length <= 512 && !/[\x00-\x1f\x7f]/.test(id))
      && new Set(boundary.ids).size === boundary.ids.length
      && new TextEncoder().encode(JSON.stringify(boundary)).length <= 12000
      && (boundary.ids.length === 0 ? boundary.time === null : typeof boundary.time === 'string'
        && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(boundary.time) && Number.isFinite(Date.parse(boundary.time)));
  }
 
  function hasRichDraft(composer, root, allowIcon = false) {
    if ([...composer.querySelectorAll('inlineimage')].some((node) => !allowIcon || !completeImageTree(node))) return true;
    if ([...composer.querySelectorAll('img')].some((image) => !allowIcon || !knownIcon(image))) return true;
    if ([...composer.querySelectorAll('[contenteditable="false"]')].some((node) => !allowIcon || !iconProof(node) || node.textContent || [...node.querySelectorAll('*')].some((child) => !['SPAN', 'IMG'].includes(child.nodeName)))) return true;
    if (composer.querySelector('video,audio,canvas,svg,iframe,object,embed,input,button,[data-tid*="attachment"],[data-attachment-id]')) return true;
    const composeArea = composer.closest(composeAreaSelector) || root;
    return !!composeArea.querySelector('[data-tid*="attachment"], [data-attachment-id]');
  }
 
  function hasDraft(composer, root) {
    return (composer.textContent || '').length > 0 || hasRichDraft(composer, root);
  }
 
  function matchesPendingDraft(composer, root, item, overwriteText = false) {
    const owner = draftOwners.get(composer);
    return isClipboardEditor(composer) && item.state === 'pending' && (!cleanFormat(item)
      || overwriteText || (owner?.id === item.id && owner.html === composer.innerHTML && owner.root === root && !owner.edited))
      && composerTextMatches(composer, item.text)
      && (!imageFormat(item) || imageProofFor(composer,item))
      && !hasRichDraft(composer, root, imageFormat(item))
      && !(composer.closest(composeAreaSelector) || root).querySelector('[data-tid*="attachment"], [data-attachment-id]');
  }
 
  function isClipboardEditor(composer) {
    return composer.classList.contains('ck-editor__editable') || composer.classList.contains('ck-content');
  }
 
  function composerTextMatches(composer, expected) {
    const actual = comparableText(composer.innerText || composer.textContent);
    const wanted = comparableText(expected);
    const imageText = isClipboardEditor(composer) ? imageBodyText(composer) : null;
    if (imageText !== null) return comparableText(imageText) === wanted;
    const fillers = [...composer.querySelectorAll('[data-cke-filler]')];
    if (!isClipboardEditor(composer) || fillers.length === 0) return actual === wanted;
    // A CKEditor terminal BR fills the caret position; it is not a model newline.
    // Verify the complete single-paragraph structure, rather than trimming text.
    const paragraph = composer.childNodes.length === 1 ? composer.firstChild : null;
    const filler = fillers.length === 1 ? fillers[0] : null;
    if (paragraph?.nodeName !== 'P' || filler?.nodeName !== 'BR'
      || filler.getAttribute('data-cke-filler') !== 'true' || filler.hasChildNodes()) return false;
    let text = '';
    let lastLeaf = null;
    let valid = true;
    const read = (node) => {
      if (node.nodeType === 3) { text += node.nodeValue; if (node.nodeValue.length) lastLeaf = node; }
      else if (node.nodeName === 'IMG' && knownIcon(node)) { lastLeaf = node; }
      else if (node.nodeName === 'BR') { if (node !== filler) text += '\n'; lastLeaf = node; }
      else if (['P', 'SPAN', 'A', 'B', 'STRONG', 'I', 'EM', 'U', 'S', 'CODE'].includes(node.nodeName)) {
        for (const child of node.childNodes) read(child);
      } else valid = false;
    };
    read(paragraph);
    return valid && lastLeaf === filler && comparableText(text) === wanted
      && (actual === wanted || (actual.endsWith('\n') && comparableText(actual.slice(0, -1)) === wanted));
  }
 
  function clipboardText(doc, text, icon = false, binaryImage = false) {
    // CKEditor owns its model. Use its paste pipeline, never overwrite its rendered DOM.
    const paragraph = doc.createElement('p');
    if (icon && !binaryImage) {
      const image = doc.createElement('img'); image.src = BridgeCodexIcon.src; image.alt = 'Codex';
      image.width = image.height = 24; image.style.cssText = 'width:24px;height:24px;vertical-align:middle';
      paragraph.append(image);
    }
      String(text).replace(/\r\n?/g, '\n').split('\n').forEach((line, index) => {
        if (index) paragraph.append(doc.createElement('br'));
        paragraph.append(doc.createTextNode(line));
      });
      const fenced = !icon && !binaryImage && /(^|\n)[ \t]*```/.test(String(text));
      if (fenced) {
        const code = doc.createElement('code');
        code.append(...paragraph.childNodes);
        paragraph.append(code);
      }
      const data = new DataTransfer();
      if (!fenced) data.setData('text/plain', text);
    data.setData('text/html', paragraph.outerHTML);
    if (binaryImage) {
      const bytes = Uint8Array.from(atob(BridgeCodexIcon.src.split(',')[1]), (character) => character.charCodeAt(0));
      data.items.add(new File([bytes], 'codex-background-test.png', {type: 'image/png'}));
    }
    return data;
  }
 
  function clipboardImage() {
    const data = new DataTransfer();
    const bytes = Uint8Array.from(atob(BridgeCodexIcon.src.split(',')[1]), (character) => character.charCodeAt(0));
    data.items.add(new File([bytes], 'codex-background-test.png', {type: 'image/png'}));
    return data;
  }

let failedPastes = new WeakMap();
  function resetDeliveryRetries() { failedPastes = new WeakMap(); }
 
  function recordEditorComparison(composer, expected, edited) {
    const actual = deliveryText(composer.innerText || composer.textContent);
    const wanted = deliveryText(expected);
    let mismatch = 0;
    while (mismatch < Math.min(actual.length, wanted.length) && actual[mismatch] === wanted[mismatch]) mismatch++;
    const kind = (character) => !character ? 'end' : character === '\n' ? 'newline'
      : /[\t\r \u00a0]/.test(character) ? 'space' : /[\u200b-\u200f\u2060\ufeff]/.test(character) ? 'format-control' : 'text';
    editorComparisons.set(composer, {editEventObserved: edited, renderedTextMatches: actual === wanted,
      composerTextMatches: composerTextMatches(composer, expected),
      expectedLength: wanted.length, renderedLength: actual.length, textContentLength: (composer.textContent || '').length,
      expectedNewlines: (wanted.match(/\n/g) || []).length, renderedNewlines: (actual.match(/\n/g) || []).length,
      expectedTrailingNewlines: wanted.length - wanted.replace(/\n+$/, '').length,
      renderedTrailingNewlines: actual.length - actual.replace(/\n+$/, '').length,
      firstDifference: actual === wanted ? null : mismatch,
      expectedDifferenceKind: kind(wanted[mismatch]), actualDifferenceKind: kind(actual[mismatch]),
      fillerNodeCount: composer.querySelectorAll('[data-cke-filler]').length,
      directChildTags: [...composer.children].slice(0, 12).map((node) => node.tagName.toLowerCase())});
  }
 
  async function deliver(doc, binding, item, ack, options = {}) {
    const phase = (name) => options.phase?.(name);
    const href = options.url || (() => location.href);
    let sendingRecorded = false;
    let watchingComposer = null;
    let internalInput = false;
    let draftEdited = false;
    let pasteAttempted = false;
    let clicked = false;
    let editorCheck = null;
    let textPastePending = false, textPasteEvents = 0;
    const watchEdit = event => {
      if (internalInput) return;
      // CKEditor can finish our paste asynchronously. Accept only untrusted editor
      // notifications in this bounded text phase; exact content is still required.
      if (textPastePending && !event.isTrusted && ['beforeinput','input'].includes(event.type)
        && ['', 'insertFromPaste','insertText','insertParagraph'].includes(event.inputType || '')) {textPasteEvents++;return;}
      draftEdited = true;
    };
    const draftEvents = ['beforeinput', 'paste', 'drop', 'input'];
    const result = (outcome, error, messageId, messageTime) => {
      if (outcome === 'not_sent' && ['image-test-v1', 'image-test-v2'].includes(item.format)) {
        const editor = doc.querySelector(composerSelector);
        if (editor) recordImageObservation(editor, item.text, 'not_sent');
      }
      if (pasteAttempted && !clicked && outcome === 'not_sent' && watchingComposer?.isConnected) {
        failedPastes.set(watchingComposer, {id: item.id, text: item.text, html: watchingComposer.innerHTML, error});
      }
      if (watchingComposer) for (const event of draftEvents) watchingComposer.removeEventListener(event, watchEdit);
      return {outcome, sendingRecorded, ...(error ? {error} : {}), ...(editorCheck?.failedChecks.length ? {failedChecks:editorCheck.failedChecks} : {}), ...(messageId ? {messageId} : {}), ...(messageTime ? {messageTime} : {})};
    };
    const clean = cleanFormat(item);
    const icon = imageFormat(item);
    const wait = options.wait || ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));
    const imageReady = options.imageReady || (globalThis.chrome?.runtime?.id ? () => chrome.runtime.sendMessage({
      type: binding.groupReport ? 'report:image-frame' : 'bridge:image-frame', binding, deliveryId: item.id, operation: 'ready'
    }) : null);
    // E3 sends only user-configured text and real report images; no model/icon protocol.
    if (!item.id || typeof item.text !== 'string' || (!normalize(item.text) && !(item.format === 'output-image-v1' && (item.images?.length || item.image))) || !['body-v1', 'output-image-v1'].includes(item.format)) return result('not_sent', '訊息格式或識別資料不完整');
    const exists = await reconcile(doc, href(), binding, item, wait);
    if (exists) return result('sent', '', exists.id, exists.time);
    if (item.state !== 'pending') return result('uncertain', '等待原回覆確認；不會重新送出');
    phase('inspect');
    let context = inspect(doc, href(), binding);
    if (!context.ok || !sameBinding(context.binding, binding)) return result('not_sent', '自聊綁定已失效');
    const composers = [...context.root.querySelectorAll(composerSelector)];
    let commands = [...context.root.querySelectorAll(sendSelector)];
    if (composers.length !== 1 || commands.length !== 1) return result('not_sent', '無法唯一辨識訊息輸入區或送出鈕');
    const composer = composers[0];
    if (['image-test-v1', 'image-test-v2'].includes(item.format) && !isClipboardEditor(composer)) return result('not_sent', '背景貼圖測試需要 Teams 圖片貼上編輯器');
    if (icon || (item.format === 'body-v1' && options.overwriteText === true)) await verifyIcons(composer, wait);
    let sendButton = commands[0];
    const overwriteText = options.overwriteText === true;
    const previousIconDraft = () => overwriteText && item.format === 'body-v1' && isClipboardEditor(composer)
      && item.text.startsWith('✦ [Codex]\n') && iconProof(composer)
      && composerTextMatches(composer, '[Codex]\n' + item.text.slice('✦ [Codex]\n'.length))
      && !hasRichDraft(composer, context.root, true);
    const resumeDraft = matchesPendingDraft(composer, context.root, item, overwriteText);
    const failedPaste = failedPastes.get(composer);
    const imageWaitError = () => ['image-test-v1', 'image-test-v2'].includes(item.format)
      && (composer.querySelector('inlineimage') || (imagePastes.has(composer) && iconProof(composer)))
      ? '圖片正在由 Teams 處理；保留圖片佔位與正文，不重貼' : null;
    if (!resumeDraft && failedPaste?.id === item.id && failedPaste.text === item.text && failedPaste.html === composer.innerHTML) {
      return result('not_sent', imageWaitError() || failedPaste.error);
    }
    const blockedDraft = () => overwriteText ? hasRichDraft(composer, context.root, previousIconDraft()) : hasDraft(composer, context.root);
    if (blockedDraft() && !resumeDraft) return result('not_sent', imageWaitError() || (overwriteText ? '輸入區有附件或嵌入內容；保留內容並等待' : '輸入區有草稿或附件；保留內容並等待'));
    if (clean) {
      watchingComposer = composer;
      for (const event of draftEvents) composer.addEventListener(event, watchEdit);
    }
    let delivery = item;
    let boundary;
    if (clean) {
      const before = snapshot(doc, href(), binding);
      if (!before.ok) return result('not_sent', '無法讀取原自聊訊息；回覆保留待送');
      boundary = {ids: before.messages.map((message) => message.id), time: before.messages.length
        ? before.messages.reduce((latest, message) => Date.parse(message.time) > Date.parse(latest) ? message.time : latest, before.messages[0].time) : null};
      if (!validDeliveryBoundary(boundary)) return result('not_sent', '目前訊息範圍超出送達核對限制；回覆保留待送');
      delivery = {...item, boundary, state: 'sending'};
    }
    let marked;
    try { marked = await ack({deliveryId: item.id, outcome: 'sending', text: item.text, ...(clean ? {boundary} : {})}); }
    catch (_) { return result('not_sent', '無法記錄送出狀態'); }
    if (!marked?.ok) return result('not_sent', '無法記錄送出狀態');
    sendingRecorded = true;
    phase('sending_recorded');
    context = inspect(doc, href(), binding);
    if (!context.ok || !sameBinding(context.binding, binding) || !composer.isConnected || !context.root.contains(composer)
      || draftEdited || (resumeDraft ? !matchesPendingDraft(composer, context.root, item, overwriteText) : blockedDraft())) return result('not_sent', '送出前綁定或草稿已變動');
    let ownedHtml = null;
    const clipboardEditor = isClipboardEditor(composer);
    const composeArea = composer.closest(composeAreaSelector) || context.root;
    const attachments = () => composeArea.querySelector('[data-tid*="attachment"], [data-attachment-id]');
    const clearOwnedDraft = () => {
      if (!draftEdited && !clipboardEditor && composer.isConnected && ownedHtml !== null && composer.innerHTML === ownedHtml && !attachments() && sameBinding(inspect(doc, href(), binding).binding, binding) && comparableText(composer.innerText || composer.textContent) === comparableText(item.text)) {
        composer.textContent = '';
        composer.dispatchEvent(new InputEvent('input', {bubbles: true, inputType: 'deleteContentBackward'}));
      }
    };
    try {
      internalInput = true;
      if (resumeDraft) {
        ownedHtml = composer.innerHTML;
      } else if (clipboardEditor) {
        phase('editor_paste');
        editorComparisons.delete(composer);
        // Focus stays inside the CDP page; the host emulates focus even on a locked desktop.
        composer.focus({preventScroll:true});
        // An empty CKEditor has no old text to replace. Background pages may not
        // retain a DOM selection; paste still has to pass the model/content checks.
        if (overwriteText && (composer.textContent || '').length > 0) {
          const selectedHtml = composer.innerHTML;
          composer.focus({preventScroll: true});
          const range = doc.createRange();
          range.selectNodeContents(composer);
          const selection = doc.getSelection();
          selection.removeAllRanges();
          selection.addRange(range);
          // CKEditor maintains a separate model selection. A DOM range alone is
          // not synchronous evidence that its paste target covers the old text.
          doc.dispatchEvent(new Event('selectionchange'));
          internalInput = false;
          await (options.wait ? options.wait(250) : new Promise((resolve) => setTimeout(resolve, 250)));
          context = inspect(doc, href(), binding);
          const selectedRange = selection.rangeCount === 1 ? selection.getRangeAt(0) : null;
          if (draftEdited || !context.ok || !sameBinding(context.binding, binding) || normalize(context.binding?.label) !== normalize(binding.label) || !context.root.contains(composer)
            || composer.innerHTML !== selectedHtml || blockedDraft()
            || !selectedRange || !composer.contains(selectedRange.startContainer) || !composer.contains(selectedRange.endContainer)
            || selectedRange.toString() !== composer.textContent) {
            return result('not_sent', 'Teams 編輯器選取尚未完成；回覆保留待送');
          }
          internalInput = true;
        }
        // Cancellation is normal for paste: CKEditor prevents the browser default
        // and inserts through its model. The rendered content is the acceptance check.
        const pureImage = ['image-test-v2','output-image-v1'].includes(item.format);
        const clipboardData = clipboardText(doc, item.text, icon && !pureImage, item.format === 'image-test-v1');
        const paste = new ClipboardEvent('paste', {bubbles: true, cancelable: true, clipboardData});
        if (item.format === 'image-test-v1') imagePastes.set(composer, {fileCount: clipboardData.files.length,
          fileType: clipboardData.files[0]?.type || '', fileBytes: clipboardData.files[0]?.size || 0,
          trustedEvent: paste.isTrusted, visibility: doc.visibilityState, clipboardTypes: [...clipboardData.types]});
        // Cache a failed paste only after dispatch. A pre-paste selection failure
        // must remain retryable when the page's selection becomes available.
        // Image-only messages must not insert filler text or dispatch an empty text paste.
        if (item.text.length || !pureImage) {
          textPastePending = pureImage;
          pasteAttempted = true;
          composer.dispatchEvent(paste);
        }
        if (pureImage) {
          internalInput = false;
          const textDeadline=Date.now()+5000;let stableSince=null, textReady=false, textChecks={}, textAttempts=0;
          do {
            await wait(50);textAttempts++;
            context=inspect(doc,href(),binding);
            textChecks={draftUnchanged:!draftEdited,bindingMatches:!!context.ok&&sameBinding(context.binding,binding)&&normalize(context.binding?.label)===normalize(binding.label),
              composerConnected:composer.isConnected&&!!context.root?.contains(composer),
              noUnexpectedRichContent:!!context.root&&!hasRichDraft(composer,context.root),textMatches:composerTextMatches(composer,item.text)};
            if(!textChecks.draftUnchanged||!textChecks.bindingMatches||!textChecks.composerConnected||!textChecks.noUnexpectedRichContent)break;
            if(textChecks.textMatches){if(stableSince===null)stableSince=Date.now();if(Date.now()-stableSince>=200){textReady=true;break;}}
            else stableSince=null;
          }while(Date.now()<textDeadline&&textAttempts<100);
          textPastePending=false;
          if(!textReady){
            recordEditorComparison(composer,item.text,draftEdited);
            editorCheck={phase:'text_before_images',checks:textChecks,failedChecks:Object.keys(textChecks).filter(key=>!textChecks[key]),
              attempts:textAttempts,asynchronousInputEvents:textPasteEvents,comparison:editorComparisons.get(composer)||null};
            if(!editorCheck.failedChecks.length)editorCheck.failedChecks.push('textStable');
            options.editorDiagnostic?.(editorCheck);
            return result('not_sent','貼圖前文字未能穩定核對（'+editorCheck.failedChecks.join(',')+'）；本次未貼圖、未按送出');
          }
          const textHtml = composer.innerHTML;
          internalInput = true;
          const range = doc.createRange();range.selectNodeContents(composer);range.collapse(false);
          const selection = doc.getSelection();selection.removeAllRanges();selection.addRange(range);
          doc.dispatchEvent(new Event('selectionchange'));
          internalInput = false;
          await wait(250);
          context = inspect(doc, href(), binding);
          const caret = selection.rangeCount === 1 ? selection.getRangeAt(0) : null;
          if (draftEdited || !context.ok || !sameBinding(context.binding, binding) || normalize(context.binding?.label) !== normalize(binding.label) || !context.root.contains(composer)
            || !composer.isConnected || composer.innerHTML !== textHtml || hasRichDraft(composer, context.root)
            || !caret?.collapsed || !composer.contains(caret.startContainer))
            return result('not_sent', '貼圖前游標或內容已變；已保留輸入區');
          const imageData = item.format === 'output-image-v1' ? BridgeOutgoingImages.clipboard() : clipboardImage();
          const imagePaste = new ClipboardEvent('paste', {bubbles: true, cancelable: true, clipboardData: imageData});
          imagePastes.set(composer, {fileCount: imageData.files.length, fileType: imageData.files[0]?.type || '',
            fileBytes: imageData.files[0]?.size || 0, trustedEvent: imagePaste.isTrusted,
            visibility: doc.visibilityState, clipboardTypes: [...imageData.types], mode: 'file-only'});
          internalInput = true;
          pasteAttempted = true;
          composer.dispatchEvent(imagePaste);
        }
      } else {
        const accepted = composer.dispatchEvent(new InputEvent('beforeinput', {bubbles: true, cancelable: true, inputType: 'insertText', data: item.text}));
        if (!accepted) return result('not_sent', 'Teams 拒絕輸入變更；已保留輸入區');
        if (icon) composer.innerHTML = clipboardText(doc, item.text, true).getData('text/html');
        else composer.textContent = item.text;
        ownedHtml = composer.innerHTML;
        composer.dispatchEvent(new InputEvent('input', {bubbles: true, inputType: 'insertText', data: item.text}));
      }
      internalInput = false;
      await (options.wait ? options.wait(options.inputWaitMs ?? 120) : new Promise((resolve) => setTimeout(resolve, options.inputWaitMs ?? 120)));
      if (clipboardEditor) {
        if (item.format === 'output-image-v1' && pasteAttempted) {
          // Teams creates its image element after asynchronous file processing.
          // Keep the existing bounded frame session alive without pasting again.
          const processingDeadline = Date.now() + 30000;
          while (Date.now() < processingDeadline) {
            if (draftEdited || !composer.isConnected || !sameBinding(inspect(doc, href(), binding).binding, binding)) break;
            await verifyIcons(composer, wait);
            if(imageProofFor(composer,item))break;
            await wait(40);
          }
          recordImageObservation(composer, item.text, composer.querySelector('img') ? 'image_processed' : 'image_processing_timeout');
        }
        if (icon) await verifyIcons(composer, wait);
        recordEditorComparison(composer, item.text, draftEdited);
        const checks = {draftUnchanged:!draftEdited,composerConnected:composer.isConnected,
          noUnexpectedRichContent:!hasRichDraft(composer,context.root,icon),
          textMatches:composerTextMatches(composer,item.text),imagesMatch:!icon||imageProofFor(composer,item)};
        const editorImages=[...composer.querySelectorAll('img')];
        editorCheck={checks,failedChecks:Object.keys(checks).filter(key=>!checks[key]),
          expectedImages:item.images?.length||(item.image?1:0),actualImages:editorImages.length,
          loadedImages:editorImages.filter(image=>image.complete&&image.naturalWidth>0).length,
          verifiedImages:editorImages.filter(image=>globalThis.BridgeOutgoingImages?.known(image)).length,
          focus:doc.hasFocus(),composerFocused:doc.activeElement===composer||composer.contains(doc.activeElement),
          visibility:doc.visibilityState,comparison:editorComparisons.get(composer)||null};
        options.editorDiagnostic?.(editorCheck);
        if (editorCheck.failedChecks.length) {
          recordImageObservation(composer, item.text, 'editor_blocked');
          return result('not_sent', imageWaitError() || 'Teams 編輯器尚未接受貼上或內容已變；已保留輸入區');
        }
        ownedHtml = composer.innerHTML;
        if (clean && !resumeDraft) {
          const owner = {id: item.id, html: ownedHtml, root: context.root, edited: false};
          draftOwners.set(composer, owner);
          for (const event of ['beforeinput', 'paste', 'drop', 'input']) composer.addEventListener(event, () => { owner.edited = true; }, {once: true});
        }
        if (icon && imageReady) {
          let ready = false;
          const readinessDeadline = Date.now() + 20000;
          for (let attempt = 0; attempt < 200 && Date.now() < readinessDeadline; attempt++) {
            if (draftEdited || !composer.isConnected || !sameBinding(inspect(doc, href(), binding).binding, binding)) break;
            const response = await imageReady();
            if (!response?.ok) break;
            if (response.ready) { ready = true; break; }
            await wait(100);
          }
          if (!draftEdited && composer.isConnected) {
            await verifyIcons(composer, wait);
            if (!hasRichDraft(composer, context.root, icon) && composerTextMatches(composer, item.text) && imageProofFor(composer, item)) {
              ownedHtml = composer.innerHTML;
              const owner = draftOwners.get(composer);
              if (owner?.id === item.id && !owner.edited) owner.html = ownedHtml;
            }
          }
          phase(ready ? 'image_model_ready' : 'image_model_not_ready');
          if (!ready) {
            recordImageObservation(composer, item.text, 'image_model_not_ready');
            return result('not_sent', 'Teams 圖片仍在載入；回覆保留待送');
          }
        }
      }
      // The CDP host durably records intent and rechecks the test deadline/desktop before clicking.
      if (options.beforeSend && !(await options.beforeSend())) return result('not_sent', '送出前授權已失效；保留草稿，不重送');
      if (clean) {
        // Virtualized history can mount an old row or briefly omit its body/time while
        // pasted images resize the composer. Retry reading only; never paste/click again.
        const deadline = Date.now() + 2500;
        let beforeClick, attempts = 0, readError = '';
        do {
          attempts++;
          const current = inspect(doc, href(), binding);
          if (!current.ok || !sameBinding(current.binding, binding) || normalize(current.binding?.label) !== normalize(binding.label)) {
            beforeClick = fail('目前帳號或收件對話已改變'); break;
          }
          beforeClick = snapshot(doc, href(), binding);
          if (beforeClick.ok) break;
          readError = beforeClick.error || '無法讀取聊天紀錄';
          if (draftEdited || !composer.isConnected || Date.now() >= deadline || attempts >= 26) break;
          await wait(100);
        } while (true);
        const matching = beforeClick.ok ? beforeClick.messages.filter(message =>
          comparableText(message.text) === comparableText(item.text) && !boundary.ids.includes(message.id)) : [];
        // Only rows older than the original latest message are historical materialization.
        // Equal/newer timestamps remain ambiguous and must block a possible duplicate.
        const historical = matching.filter(message => boundary.time && Date.parse(message.time) < Date.parse(boundary.time));
        const conflicts = matching.length - historical.length;
        const check = {version:'preflight1',historyReadable:!!beforeClick.ok,attempts,
          readError:beforeClick.ok ? '' : (beforeClick.error || readError),
          recoveredReadError:beforeClick.ok ? readError : '',
          olderMatchingRows:historical.length,conflictingRows:conflicts};
        options.preSendDiagnostic?.(check);
        if (!beforeClick.ok || conflicts) {
          clearOwnedDraft();
          return {...result('not_sent', !beforeClick.ok
            ? '送出前聊天紀錄尚未完整：' + check.readError + '；本次未按送出，保留草稿'
            : '送出前出現時間較新或無法排除重複的相同正文；本次未按送出，保留草稿'),
            failedChecks:[!beforeClick.ok ? 'historyReadable' : 'noNewMatchingMessage'],preSendCheck:check};
        }
      }
      // Revalidate editor, binding and button after any history-read waits.
      // Teams swaps compact/expanded send commands when its editor accepts text.
      // Requery after rendering; never click the pre-paste element or use a cached thread.
      context = inspect(doc, href(), binding);
      commands = context.ok ? [...context.root.querySelectorAll(sendSelector)] : [];
      sendButton = commands.length === 1 ? commands[0] : null;
      if (draftEdited || !context.ok || !sameBinding(context.binding, binding) || normalize(context.binding?.label) !== normalize(binding.label) || !context.root.contains(composer) || context.root.querySelectorAll(composerSelector).length !== 1 || (resumeDraft && !matchesPendingDraft(composer, context.root, item, overwriteText)) || composer.innerHTML !== ownedHtml || hasRichDraft(composer, context.root, icon) || !composerTextMatches(composer, item.text) || (icon && !imageProofFor(composer,item)) || !sendButton?.isConnected || sendButton.disabled || sendButton.getAttribute('aria-disabled') === 'true') {
        clearOwnedDraft();
        return result('not_sent', '送出前聊天、內容或按鈕已變動');
      }
      clicked = true;
      phase('send_clicked');
      recordImageObservation(composer, item.text, 'send_click');
      draftOwners.delete(composer);
      sendButton.click();
      const limit = Date.now() + (options.timeoutMs || 10000);
      let waited = 0;
      do {
        const found = await reconcile(doc, href(), binding, delivery, wait);
        if (found) return result('sent', '', found.id, found.time);
        if (!sameBinding(inspect(doc, href(), binding).binding, binding)) break;
        await (options.wait ? options.wait(40) : new Promise((resolve) => setTimeout(resolve, 40)));
        waited += 40;
      } while (Date.now() < limit && waited < (options.timeoutMs || 10000));
      return result('uncertain', '已按送出但無法確認完整訊息；不會自動重送');
    } catch (_) {
      if (!clicked) clearOwnedDraft();
      return result(clicked ? 'uncertain' : 'not_sent', '訊息送出流程中斷');
    }
  }
 
  function imageFrameEligible(doc, binding, item) {
    const context = inspect(doc, doc.location.href, binding);
    return context.ok && sameBinding(context.binding, binding) && item.state === 'pending'
      && (['image-test-v1', 'image-test-v2', 'output-image-v1'].includes(item.format)
        || (doc.visibilityState === 'hidden' && ['body-v1', 'body-v2'].includes(item.format)))
      && context.root.querySelectorAll(composerSelector).length === 1
      && isClipboardEditor(context.root.querySelector(composerSelector));
  }
  globalThis.BridgeAdapter = {version: '1.0.36', inspect, diagnostics, snapshot, sameBinding, hasContinuity, atLatest, followLatest, mergeMessages, eligibleMessages, catchUp, deliver, resetDeliveryRetries, normalize, refreshIdentity, identityState, accountEvidence, imageFrameEligible};
})();
 
'@
        }
        'vendor/outbound-images.js' {
            return @'
(() => {
  'use strict';
  let active = null;
  const verified = new WeakMap();
  const observations = [];
  const digest = async bytes => [...new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))].map(b=>b.toString(16).padStart(2,'0')).join('');
  const source = image => image.currentSrc || image.getAttribute('src') || '';
  const record = (stage, values={}) => {
    observations.push({stage,at:new Date().toISOString(),...values});
    if (observations.length > 12) observations.shift();
  };
  function canvasFor(bitmap) {
    const width=bitmap.naturalWidth || bitmap.width, height=bitmap.naturalHeight || bitmap.height;
    if (!width || !height || width > 4096 || height > 4096 || width*height > 16000000)
      throw new Error('OUTPUT_IMAGE_PIXEL_LIMIT');
    const canvas=document.createElement('canvas');canvas.width=width;canvas.height=height;
    canvas.getContext('2d').drawImage(bitmap,0,0);return canvas;
  }
  async function prepareSingle(item,binding,send) {
    const ref=item.image;
    if (!ref || !/^[a-f0-9]{64}$/.test(ref.id) || ref.id!==ref.sha256 || !['image/png','image/jpeg'].includes(ref.mime)
      || !Number.isInteger(ref.bytes) || ref.bytes<1 || ref.bytes>10*1024*1024) throw new Error('OUTPUT_IMAGE_INVALID_METADATA');
    let stage='chunks';
    try {
      const bytes=new Uint8Array(ref.bytes);
      for(let offset=0;offset<bytes.length;offset+=65536) {
        const response=await send({type:'bridge:output-image',binding,deliveryId:item.id,offset});
        const chunk=response?.imageChunk;
        if (!response?.ok) throw new Error(/^OUTPUT_IMAGE_[A-Z_]+$/.test(response?.error || '')?response.error:'OUTPUT_IMAGE_CHUNK_FAILED');
        if (chunk?.offset!==offset || typeof chunk.data!=='string' || chunk.data.length>90000) throw new Error('OUTPUT_IMAGE_CHUNK_FAILED');
        const part=Uint8Array.from(atob(chunk.data),c=>c.charCodeAt(0));
        if(part.length!==Math.min(65536,bytes.length-offset)) throw new Error('OUTPUT_IMAGE_CHUNK_SIZE');
        bytes.set(part,offset);
      }
      stage='hash';
      if(await digest(bytes)!==ref.sha256) throw new Error('OUTPUT_IMAGE_HASH_MISMATCH');
      stage='decode';
      const bitmap=await createImageBitmap(new Blob([bytes],{type:ref.mime}));
      stage='pixels';
      let canvas;
      try {canvas=canvasFor(bitmap);} finally {bitmap.close();}
      const pixels=canvas.getContext('2d').getImageData(0,0,canvas.width,canvas.height).data;
      const png=Uint8Array.from(atob(canvas.toDataURL('image/png').split(',')[1]),c=>c.charCodeAt(0));
      if(png.length>10*1024*1024) throw new Error('OUTPUT_IMAGE_PNG_SIZE_LIMIT');
      record('prepared',{bytes:ref.bytes,width:canvas.width,height:canvas.height});
      return {deliveryId:item.id,ref:{...ref},binding,send,width:canvas.width,height:canvas.height,pixelHash:await digest(pixels),png};
    } catch(error) {
      record('prepare_failed',{operation:stage,exceptionType:error.name,code:/^OUTPUT_IMAGE_[A-Z_]+$/.test(error.message)?error.message:'OUTPUT_IMAGE_DECODE_FAILED'});
      throw new Error(/^OUTPUT_IMAGE_/.test(error.message)?error.message:'OUTPUT_IMAGE_DECODE_FAILED');
    }
  }
  async function prepare(item,binding,send) {
    active=null;
    observations.length=0;
    const refs=item.images || (item.image?[item.image]:[]);
    if(!Array.isArray(refs)||refs.length<1||refs.length>4||refs.reduce((n,r)=>n+r.bytes,0)>25*1024*1024)throw new Error('OUTPUT_IMAGE_BATCH_LIMIT');
    const entries=[];
    for(let index=0;index<refs.length;index++)entries.push(await prepareSingle({...item,image:refs[index]},binding,req=>send({...req,index})));
    if(entries.reduce((n,e)=>n+e.png.length,0)>25*1024*1024)throw new Error('OUTPUT_IMAGE_BATCH_LIMIT');
    active={deliveryId:item.id,entries};
  }

async function verifySingle(image,wait,expected) {
    if(!expected)return false;
    const prior=verified.get(image);
    if(prior?.deliveryId===expected.deliveryId&&prior.src===source(image)&&prior.pixelHash===expected.pixelHash)return true;
    for(let attempt=0;!image.complete && attempt<8;attempt++)await wait(40);
    if(!image.complete || !image.naturalWidth || !image.naturalHeight)return false;
    let canvas;
    try {canvas=canvasFor(image);canvas.getContext('2d').getImageData(0,0,canvas.width,canvas.height);}
    catch(_) {
      try {
        const row=image.closest('[data-message-id], [data-mid]');
        const id=row?.getAttribute('data-message-id') || row?.getAttribute('data-mid');
        if(!id || !globalThis.BridgeInboundImages?.readBytes)return false;
        const snapshot=BridgeAdapter.snapshot(document,location.href,expected.binding);
        const message=snapshot.messages?.find(value=>value.id===id);
        const index=message?.images?.findIndex(value=>value.sources?.includes(source(image)) || value.src===source(image));
        if(!snapshot.ok || index<0 || index===undefined)return false;
        const bytes=await BridgeInboundImages.readBytes(source(image),expected.binding,id,index,expected.send);
        const bitmap=await createImageBitmap(new Blob([bytes]));
        try {canvas=canvasFor(bitmap);} finally {bitmap.close();}
      } catch(_) {return false;}
    }
    if(canvas.width!==expected.width || canvas.height!==expected.height)return false;
    const pixels=canvas.getContext('2d').getImageData(0,0,canvas.width,canvas.height).data;
    if(await digest(pixels)!==expected.pixelHash)return false;
    verified.set(image,{deliveryId:expected.deliveryId,src:source(image),pixelHash:expected.pixelHash});return true;
  }
  async function verify(image,wait){
    const batch=active;if(!batch)return false;
    for(const entry of batch.entries){if(await verifySingle(image,wait,entry))return active===batch;}
    return false;
  }
  function known(image) {
    const proof=verified.get(image);
    return !!active && proof?.deliveryId===active.deliveryId && proof.src===source(image) && active.entries.some(e=>e.pixelHash===proof.pixelHash);
  }
  function proof(node){
    const images=[...node.querySelectorAll('img')];
    return !!active&&images.length===active.entries.length&&images.every((image,index)=>known(image)&&verified.get(image).pixelHash===active.entries[index].pixelHash);
  }
  function clipboard() {
    if(!active)throw new Error('OUTPUT_IMAGE_NOT_PREPARED');
    const data=new DataTransfer();active.entries.forEach((e,i)=>data.items.add(new File([e.png],`e3-report-${i+1}.png`,{type:'image/png'})));return data;
  }
  globalThis.BridgeOutgoingImages={prepare,verify,known,proof,clipboard,count:()=>active?.entries.length||0,dimensions:()=>active?.entries.map(e=>({width:e.width,height:e.height}))||[],diagnostics:()=>observations.map(row=>({...row}))};
})();
 
'@
        }
        'discard-draft.js' {
            return @'
(() => {
  const expected=/*E3_BINDING*/null, checkFocus=/*E3_CHECK_FOCUS*/false;
  const fail=reason=>({ok:false,reason});
  const c=BridgeAdapter.inspect(document,location.href,expected);
  if(!c.ok||!c.binding||['accountId','chatId','label'].some(k=>c.binding[k]!==expected[k]))return fail('收件帳號或對話不符');
  const runtime=E3Cdp.status();
  if(!runtime||!['idle','finished'].includes(runtime.stage))return fail('舊工作仍在執行');
  const row='[data-message-id], [data-tid="chat-pane-message"], [data-tid="message-body"], [data-tid="chat-message-list"], [data-tid="message-pane-list-viewport"]';
  const selector='[data-tid="ckeditor"][contenteditable="true"], [data-tid="message-composer"][contenteditable="true"], [data-tid="compose-box"] [role="textbox"][contenteditable="true"]';
  const editors=[...c.root.querySelectorAll(selector)];
  if(editors.length!==1)return fail('輸入框不唯一');
  const editor=editors[0], area=editor.closest('[data-tid="compose-box"], [data-tid="message-composer-container"], [data-tid="chat-pane-compose-message-footer"]');
  if(!area||!c.root.contains(area)||editor.closest(row)||area.querySelector(row))return fail('無法確認獨立的草稿輸入區');
  if(area.matches('[data-editing-message-id],[data-tid="message-edit-form"]')||area.querySelector('[data-editing-message-id],[data-tid="message-edit-form"],[data-tid="edit-message-banner"]'))return fail('目前正在編輯既有訊息，不能當成未送出草稿清除');
  if(document.querySelector('[role="dialog"][aria-modal="true"]'))return fail('有對話框遮住輸入區');
  if(checkFocus){
    const selection=document.getSelection();
    return document.activeElement===editor&&selection?.rangeCount&&editor.contains(selection.anchorNode)&&editor.contains(selection.focusNode)
      ? {ok:true,state:'focused'} : fail('刪除前輸入焦點已變更');
  }
  const rich='inlineimage,img,video,audio,canvas,svg,iframe,object,embed,input,button,[contenteditable="false"],[data-tid*="attachment"],[data-attachment-id]';
  if(editor.textContent.length||editor.querySelector(rich)){
    editor.focus();
    const range=document.createRange();range.selectNodeContents(editor);
    const selection=document.getSelection();selection.removeAllRanges();selection.addRange(range);
    if(document.activeElement!==editor)return fail('無法聚焦草稿輸入框');
    return {ok:true,state:'clear_editor'};
  }
  const attachment='[data-tid*="attachment"],[data-attachment-id]';
  if(area.querySelector(attachment)){
    const remove=[...area.querySelectorAll('button,[role="button"]')].filter(button=>{
      const label=(button.getAttribute('aria-label')||button.getAttribute('title')||button.textContent||'').trim();
      const card=button.closest(attachment);
      return card&&area.contains(card)&&!editor.contains(button)&&!button.closest(row)&&button.isConnected&&!button.disabled&&button.getAttribute('aria-disabled')!=='true'
        &&button.getClientRects().length>0&&/移除|刪除|删除|取消上傳|取消上传|remove|delete|cancel upload/i.test(label)
        &&!/(send|傳送|发送)/i.test(button.getAttribute('data-tid')||'');
    });
    if(!remove.length)return fail('找不到附件的移除按鈕，已停止以免誤刪其他內容');
    remove[0].click();
    return {ok:true,state:'removed_attachment'};
  }
  return {ok:true,state:'empty'};
})()
'@
        }
        'resume-check.js' {
            return @'
(() => {
  const expected=/*E3_BINDING*/null;
  const c=BridgeAdapter.inspect(document,location.href,expected);
  if(!c.ok||!c.binding||['accountId','chatId','label'].some(k=>c.binding[k]!==expected[k]))return {ok:false};
  const selector='[data-message-id], [data-tid="chat-pane-message"]';
  const pending='[data-tid*="sending"], [data-tid*="pending"], [data-message-status="pending"], [data-message-status="sending"], [aria-busy="true"], [role="progressbar"]';
  const rows=[...c.root.querySelectorAll(selector)].filter(n=>!n.parentElement?.closest(selector));
  let count=0;
  for(const row of rows){
    const wrap=row.closest('[data-tid="chat-pane-item"]')||row;
    const labels=[...wrap.querySelectorAll('[data-tid*="status"],[data-tid*="delivery"]')].filter(n=>!n.closest('[data-tid="message-body"],[data-tid="chat-pane-message-content"],[data-message-content]')).map(n=>(n.getAttribute('aria-label')||'')+' '+(n.getAttribute('title')||'')).join(' ');
    if(wrap.matches(pending)||wrap.querySelector(pending)||/sending|pending|正在傳送|傳送中/i.test(labels))count++;
  }
  return {ok:true,pendingRows:count};
})()
'@
        }
        'receipt.js' {
            return @'
/* A server thumbnail is not the original bitmap. Keep pre-send pixel/model proof;
   reconcile the new outgoing row independently without weakening uncertain failures. */
(() => {
  'use strict';
  let state=null;
  let deliveryId=null;
  function reset(id=null){state=null;deliveryId=id;}
  const rowSelector='[data-message-id], [data-tid="chat-pane-message"]';
  const bodySelector='[data-tid="message-body"], [data-tid="chat-pane-message-content"], [data-message-content]';
  const normalize=text=>String(text||'').replace(/\r\n?/g,'\n').replace(/\u00a0/g,' ').replace(/\u2060/g,'').replace(/(\p{Extended_Pictographic})[\uFE0E\uFE0F]/gu,'$1').trim();
  const emojiSelector='[data-emoji],[data-tid*="emoji"],[class*="emoji"],[class*="emoticon"]';
  function emojiText(image){
    // Only a marked emoji with a complete Unicode emoji value is text.
    // Do not interpret attachment alt labels or English names as message text.
    const value=image.getAttribute('alt')||'';
    return image.closest(emojiSelector)&&/^(?:\p{Extended_Pictographic}[\uFE0E\uFE0F]?(?:\p{Emoji_Modifier})?)(?:\u200D\p{Extended_Pictographic}[\uFE0E\uFE0F]?(?:\p{Emoji_Modifier})?)*$/u.test(value)?value:'';
  }
  const failed='[data-tid*="retry"], [data-tid*="send-error"], [data-tid*="message-error"], [data-tid*="failed"], [data-message-status="failed"]';
  const pending='[data-tid*="sending"], [data-tid*="pending"], [data-message-status="pending"], [aria-busy="true"], [role="progressbar"]';
  function rows(root){return [...root.querySelectorAll(rowSelector)].filter(n=>!n.parentElement?.closest(rowSelector));}
  const id=row=>row.getAttribute('data-message-id')||row.getAttribute('data-mid')||row.id||'';
  function text(body){
    // innerText on a detached clone loses BRs and paragraph boundaries in Chromium.
    // Teams serializes BR followed by CRLF. Under normal HTML whitespace this
    // source newline is not another visible break. Preserve preformatted text.
    const textNode=n=>n.previousSibling?.nodeName==='BR'&&['normal','nowrap'].includes(getComputedStyle(n.parentElement).whiteSpace)
      ?n.nodeValue.replace(/^\r?\n/,''):n.nodeValue;
    const read=n=>n.nodeType===3?textNode(n):n.nodeType!==1?'':n.tagName==='IMG'?emojiText(n):n.matches('inlineimage,[data-inline-image],[data-cke-filler]')?'':
      n.tagName==='BR'?'\n':[...n.childNodes].map(read).join('')+(['P','DIV'].includes(n.tagName)?'\n':'');
    return normalize(read(body));
  }
  function textComparison(body,actual,expected,messageId){
    let at=0;while(at<Math.min(actual.length,expected.length)&&actual[at]===expected[at])at++;
    const kind=c=>!c?'end':c==='\n'?'newline':/\s/u.test(c)?'space':/[\u200B-\u200F\u2060\uFE0E\uFE0F\uFEFF]/u.test(c)?'format-control':/\p{Extended_Pictographic}/u.test(c)?'emoji':'text';
    return {messageId,expectedLength:expected.length,actualLength:actual.length,firstDifference:actual===expected?null:at,
      expectedKind:kind(expected[at]),actualKind:kind(actual[at]),expectedNewlines:(expected.match(/\n/g)||[]).length,actualNewlines:(actual.match(/\n/g)||[]).length,
      emojiImages:[...body.querySelectorAll('img')].filter(i=>!!i.closest(emojiSelector)).length,
      readableEmojiImages:[...body.querySelectorAll('img')].filter(i=>!!emojiText(i)).length,
      directChildTags:[...body.children].slice(0,12).map(n=>n.tagName.toLowerCase())};
  }
  function context(binding){const c=BridgeAdapter.inspect(document,location.href,binding);return c.ok&&c.binding.label===binding.label?c:null;}
  function arm(item,binding){
    const c=context(binding);if(!c)throw new Error('RECEIPT_BINDING_CHANGED');
    deliveryId=item.id;
    state={item,binding,ids:new Set(rows(c.root).map(id)),at:Date.now(),candidate:null,clicked:false,reason:'not_clicked',counts:{},images:[],textComparisons:[]};
  }
  function clicked(){if(state){state.clicked=true;state.at=Date.now();}}
  function inspect(){
    if(!state?.clicked)return null;
    const c=context(state.binding);if(!c){state.reason='binding_changed';state.candidate=null;return null;}
    const editors=[...c.root.querySelectorAll('[data-tid="ckeditor"][contenteditable="true"], [data-tid="message-composer"][contenteditable="true"], [data-tid="compose-box"] [role="textbox"][contenteditable="true"]')];
    if(editors.length!==1||normalize(editors[0].textContent)||editors[0].querySelector('img,inlineimage')){state.reason='composer_not_empty';state.candidate=null;return null;}
    const candidates=[];state.images=[];state.textComparisons=[];
    const counts=state.counts={rows:0,oldId:0,missingId:0,temporaryId:0,bodyMismatch:0,textMismatch:0,timeMismatch:0,imageNotReady:0,imageMismatch:0};
    state.reason='matching_row_not_found';
    for(const row of rows(c.root)){
      counts.rows++;
      const messageId=id(row);
      // Virtual lists may reuse a DOM node for a genuinely new message ID.
      if(!messageId){counts.missingId++;continue;}
      if(state.ids.has(messageId)){counts.oldId++;continue;}
      if(/^(temp|pending|client)[-_:]/i.test(messageId)){counts.temporaryId++;continue;}
      const bodies=[...row.querySelectorAll(bodySelector)].filter(n=>!n.parentElement?.closest(bodySelector));
      if(bodies.length!==1){counts.bodyMismatch++;state.reason='message_body_not_unique';continue;}
      const actualText=text(bodies[0]),expectedText=normalize(state.item.text);
      state.textComparisons.push(textComparison(bodies[0],actualText,expectedText,messageId));
      if(state.textComparisons.length>8)state.textComparisons.shift();
      const unknownEmoji=[...bodies[0].querySelectorAll('img')].some(i=>i.closest(emojiSelector)&&!emojiText(i));
      if(unknownEmoji||actualText!==expectedText){counts.textMismatch++;state.reason='message_text_mismatch';continue;}
      const wrap=row.closest('[data-tid="chat-pane-item"]')||row;
      const deliveryLabels=[...wrap.querySelectorAll('[data-tid*="status"],[data-tid*="delivery"]')].filter(n=>!bodies[0].contains(n)).map(n=>(n.getAttribute('aria-label')||'')+' '+(n.getAttribute('title')||'')).join(' ');
      if(/failed|not delivered|無法傳送|傳送失敗|未送達/i.test(deliveryLabels)){state.reason='message_failed';state.candidate=null;return null;}
      if(/sending|pending|正在傳送|傳送中/i.test(deliveryLabels)){state.reason='message_pending';state.candidate=null;return null;}
      if(wrap.matches(failed)||wrap.querySelector(failed)){state.reason='message_failed';state.candidate=null;return null;}
      if(wrap.matches(pending)||wrap.querySelector(pending)){state.reason='message_pending';state.candidate=null;return null;}
      const stamp=row.getAttribute('data-timestamp')||wrap.querySelector('time[datetime]')?.getAttribute('datetime');
      let time=null;
      if(stamp){const value=/^\d{10,13}$/.test(stamp)?Number(stamp)*(stamp.length===10?1000:1):stamp;time=new Date(value);}
      if(!time||!Number.isFinite(time.getTime())||time.getTime()<state.at-60000){counts.timeMismatch++;state.reason='missing_or_old_timestamp';continue;}
      const images=[...bodies[0].querySelectorAll('img')].filter(i=>!i.closest(emojiSelector));
      if(state.item.image||state.item.images){
        const dimensions=BridgeOutgoingImages.dimensions();
        // Sizes only: do not put attachment URLs, tokens, image bytes or message text in diagnostics.
        if(state.images.length<8)state.images.push({messageId,expected:dimensions,actualCount:images.length,actual:images.slice(0,8).map((image,index)=>({index,width:image.naturalWidth,height:image.naturalHeight,complete:image.complete,ratioMatches:!!dimensions[index]&&!!image.naturalHeight&&Math.abs(image.naturalWidth/image.naturalHeight-dimensions[index].width/dimensions[index].height)<=0.03*Math.max(1,image.naturalWidth/image.naturalHeight)}))});
        if(!dimensions.length||images.length!==dimensions.length||images.some(image=>!image.complete||!image.naturalWidth)){counts.imageNotReady++;state.reason='image_count_or_loading_mismatch';continue;}
        if(images.some((image,index)=>{const ratio=image.naturalWidth/image.naturalHeight;return Math.abs(ratio-dimensions[index].width/dimensions[index].height)>0.03*Math.max(1,ratio);})){counts.imageMismatch++;state.reason='image_shape_mismatch';continue;}
      }else if(images.length){state.reason='unexpected_image';continue;}
      candidates.push({messageId,time:time.toISOString(),signature:JSON.stringify(images.map(image=>[image.currentSrc||image.src,image.naturalWidth,image.naturalHeight]))});
    }
    if(candidates.length!==1){if(candidates.length)state.reason='ambiguous_rows';state.candidate=null;return null;}
    const match=candidates[0];
    if(!state.candidate||state.candidate.messageId!==match.messageId||state.candidate.signature!==match.signature){state.candidate={...match,firstSeen:Date.now()};state.reason='stabilizing';return null;}
    if(Date.now()-state.candidate.firstSeen<1500){state.reason='stabilizing';return null;}
    state.reason='confirmed_new_row';return {outcome:'sent',messageId:match.messageId,messageTime:match.time,evidence:'new_stable_message_and_loaded_attachment'};
  }
  globalThis.E3Receipt={reset,arm,clicked,inspect,diagnostics:()=>({deliveryId,reason:state?.reason||'not_armed',counts:state?.counts||{},images:state?.images||[],textComparisons:state?.textComparisons||[]})};
})();
 
'@
        }
        'runtime.js' {
            return @'
/* Runs in an isolated CDP world. No extension, network service, global clipboard or model. */
(() => {
  'use strict';
  if (globalThis.E3Cdp) return;
  let session = null;
  let bindingProfile = null, openedProfile = false;
  const clean = value => String(value || '').replace(/\s+/g, ' ').trim();
  const same = (a, b) => BridgeAdapter.sameBinding(a, b) && clean(a?.label) === clean(b?.label);
  globalThis.BridgeGroupReportRuntime = {
    accountMatches(binding) {
      const proof = BridgeAdapter.refreshIdentity(document);
      return !!proof && proof.accountId === binding.accountId;
    }
  };
  function inspect(binding) {
    const result = BridgeAdapter.inspect(document, location.href, binding);
    if (!result.ok || (binding && !same(result.binding, binding))) throw new Error(result.error || 'CHAT_OR_TITLE_CHANGED');
    return result;
  }
  function beginBinding() {
    const profiles = [...document.querySelectorAll('[data-tid="me-control-avatar-trigger"]')];
    if (profiles.length !== 1) return {ok:false,error:'ACCOUNT_PROFILE_AMBIGUOUS',profileCount:profiles.length};
    bindingProfile = profiles[0];
    openedProfile = bindingProfile.getAttribute('aria-expanded') !== 'true';
    if (openedProfile) bindingProfile.click();
    return {ok:true};
  }
  function endBinding() {
    if (openedProfile && bindingProfile?.isConnected && bindingProfile.getAttribute('aria-expanded') === 'true') bindingProfile.click();
    openedProfile = false; bindingProfile = null;
    return {ok:true};
  }
  function bind(allowGroup = false) {
    try {
      // Initial binding intentionally uses the original strict self-chat/account verification.
      const inspected = BridgeAdapter.inspect(document,location.href,null,allowGroup);
      if(!inspected.ok) throw new Error(inspected.error);
      if (!BridgeAdapter.refreshIdentity(document)) throw new Error('帳號選單尚未提供可驗證的登入資料');
      const binding = {...inspected.binding, groupReport: true};
      inspect(binding);
      return {ok: true, binding};
    } catch (error) {
      return {ok: false, error: error.message, account: BridgeAdapter.accountEvidence(document),
        selectors: Object.fromEntries(Object.entries({pane:'[data-tid="chat-pane"], [data-tid="chat-pane-layout"], [data-tid="message-pane-layout"]',
          profile:'[data-tid="me-control-avatar-trigger"]', header:'[data-tid="chat-header"], [data-tid="chat-header-bar"], [data-tid="entity-header"]',
          composer:'[data-tid="ckeditor"][contenteditable="true"], [data-tid="message-composer"][contenteditable="true"]'}).map(([k,v])=>[k,document.querySelectorAll(v).length]))};
    }
  }
  function check() {
    if (!session || session.cancelled || Date.now() > session.expires) throw new Error('TEST_CANCELLED_OR_EXPIRED');
    inspect(session.binding);
  }
  function sleep(ms) {
    check();
    return new Promise((resolve, reject) => session.waiters.push({due:Date.now()+ms, resolve, reject}));
  }
  async function permit(stage, boundary) {
    check();
    const serial = ++session.request;
    session.checkpoint = {serial, stage, boundary: boundary || null};
    while (session.granted < serial) await sleep(40);
    check(); return true;
  }
  function tick(ready, grant, frameReady, cancel) {
    if (!session) return status();
    session.modelReady = ready === true;
    session.granted = Math.max(session.granted, Number(grant) || 0);
    session.frameReady = session.frameReady || frameReady === true;
    session.cancelled = session.cancelled || cancel === true;
    const remaining = [];
    for (const waiter of session.waiters) {
      if (session.cancelled || Date.now() > session.expires) waiter.reject(new Error('TEST_CANCELLED_OR_EXPIRED'));
      else if (waiter.due <= Date.now()) waiter.resolve();
      else remaining.push(waiter);
    }
    session.waiters = remaining;
    return status();
  }
  function status() {
    if (!session) return {stage:'idle'};
    return {stage:session.stage,id:session.id,expiresAt:session.expires,cancelled:session.cancelled,clicked:!!session.clicked, checkpoint:session.checkpoint, result:session.result,
      visibility:document.visibilityState,focus:document.hasFocus(),imageCount:session.imageCount,editor:session.editor||null,preSend:session.preSend||null,
      imageObservations:session.imageCount?BridgeOutgoingImages.diagnostics():[],modelReady:session.modelReady,receipt:globalThis.E3Receipt?.diagnostics()};
  }
  function start(item, binding, base64) {
    if (session) return {ok:false,error:'ONE_ATTEMPT_PER_PAGE_REOPEN_REQUIRED'};
    inspect(binding);
    if (!/^[a-f0-9]{32}$/.test(item.id) || !['output-image-v1','body-v1'].includes(item.format) || typeof item.text !== 'string' || (!item.text.trim() && !(item.format === 'output-image-v1' && (item.images?.length || item.image))) || item.text.length > 24000) throw new Error('INVALID_TEST_ITEM');
    globalThis.E3Receipt?.reset(item.id);
    session = {id:item.id,binding,stage:'preparing',waiters:[],expires:Date.now()+90000,cancelled:false,modelReady:false,
      frameReady:false,request:0,granted:0,checkpoint:null,result:null,preSend:null,imageCount:item.images?.length||(item.image?1:0)};
    // This promise is polled by the PowerShell host; never automatically restarted on failure.
    (async () => {
      try {
        const payloads=Array.isArray(base64)?base64:[base64||''];
        const blobs=payloads.map(value=>Uint8Array.from(atob(value), c=>c.charCodeAt(0)));
        if (item.image || item.images) await BridgeOutgoingImages.prepare(item,binding, async req=> {
          check();
          const bytes=blobs[req.index||0];
          if(!bytes)return {ok:false};
          if (req.type !== 'bridge:output-image' || req.deliveryId !== item.id || !same(req.binding,binding) || req.offset%65536 || req.offset<0 || req.offset>=bytes.length) return {ok:false};
          const part = bytes.subarray(req.offset,req.offset+65536);
          let data=''; for (const value of part) data+=String.fromCharCode(value);
          return {ok:true,imageChunk:{offset:req.offset,data:btoa(data)}};
        });
        check();
        session.stage='prepared';
        while (!session.frameReady) await sleep(40);
        let outcome = await BridgeAdapter.deliver(document,binding,item, async delivery => {
          await permit('before_paste',delivery.boundary); return {ok:true};
        }, {wait:sleep,overwriteText:false,timeoutMs:20000,
          phase:stage=>{session.stage=stage;if(stage==='send_clicked'){session.clicked=true;globalThis.E3Receipt?.clicked();}},
          imageReady:async()=>{check(); return {ok:true,ready:session.modelReady};},
          editorDiagnostic:evidence=>{session.editor=evidence;},
          preSendDiagnostic:evidence=>{session.preSend=evidence;},
          beforeSend:async()=>{await permit('before_click');globalThis.E3Receipt?.arm(item,binding);return true;}});
        if(session.clicked&&['sent','uncertain'].includes(outcome.outcome)&&globalThis.E3Receipt){
          // Inspect the submitted row even when pixels match: pending/failed rows are not success.
          outcome={outcome:'uncertain',error:'NEW_MESSAGE_RECEIPT_NOT_CONFIRMED'};
          session.stage='verify_receipt';
          const until=Date.now()+12000;
          while(Date.now()<until){check();const proof=E3Receipt.inspect();if(proof){outcome=proof;break;}await sleep(150);}
        }
        session.result=outcome;
      } catch (error) {
        session.result={outcome:session.clicked?'uncertain':'not_sent',error:error.message};
      } finally {session.stage='finished';}
    })();
    return {ok:true};
  }
  function reset(){if(session&&session.stage!=='finished')throw new Error('DELIVERY_STILL_ACTIVE');session=null;globalThis.E3Receipt?.reset();return true;}
  function cancel(id){
    if(session&&session.id===id&&session.stage!=='finished')tick(false,0,false,true);
    return status();
  }
  function recover(){
    if(session&&session.stage!=='finished'&&(session.cancelled||Date.now()>session.expires))cancel(session.id);
    return status();
  }
  globalThis.E3Cdp = {version:'2026-11-10-receiptbreak1',supportsImageOnly:true,beginBinding,endBinding,bind,start,tick,status,reset,cancel,recover};
})();
 
'@
        }
        'vendor/image-frame-bootstrap.js' {
            return @'
/* Install before Teams captures its host functions. Passive outside a probe. */
(() => {
  'use strict';
  const key = Symbol.for('d46518.teamsCodex.imageFrameProbe');
  if (globalThis[key]) return;
  const originalRequest = globalThis.requestAnimationFrame;
  const originalCancel = globalThis.cancelAnimationFrame;
  const callbacks = new Map();
  let session = null;
  let completed = null;
  const run = (id, time) => {
    const entry = callbacks.get(id);
    if (!entry) return;
    callbacks.delete(id);
    entry.callback.call(globalThis, time);
  };
  const request = (callback) => {
    if (session && Date.now() - session.wallStarted > 60000) stop();
    if (!session) return originalRequest.call(globalThis, callback);
    if (typeof callback !== 'function') return originalRequest.call(globalThis, callback);
    const id = originalRequest.call(globalThis, (time) => run(id, time));
    callbacks.set(id, {callback, at: performance.now(), token: session.token});
    return id;
  };
  const cancel = (id) => {
    callbacks.delete(id);
    originalCancel.call(globalThis, id);
  };
  const stop = () => {
    if (!session) return {ok: true, fallback: 0};
    const fallback = session.fallback;
    completed = {token: session.token, fallback};
    clearTimeout(session.expiry);
    session = null;
    return {ok: true, fallback};
  };
  const control = (operation, token, elapsed = 0) => {
    if (operation === 'start') {
      if (session) return {ok: false};
      completed = null;
      session = {token, started: performance.now(), wallStarted: Date.now(), fallback: 0, expiry: setTimeout(stop, 61000)};
      return {ok: true};
    }
    if (!session || session.token !== token) {
      return operation === 'stop' && completed?.token === token ? {ok: true, fallback: completed.fallback} : {ok: false};
    }
    if (operation === 'stop') return stop();
    if (operation !== 'pulse') return {ok: false};
    if (elapsed > 60000 || Date.now() - session.wallStarted > 60000) return stop();
    if (document.visibilityState !== 'hidden') return {ok: true};
    const active = session;
    const time = active.started + elapsed;
    for (const [id, entry] of [...callbacks]) if (session === active && entry.token === active.token && time - entry.at >= 40) {
      active.fallback++;
      originalCancel.call(globalThis, id);
      try { run(id, time); } catch (_) { /* One failed callback must not block the rest. */ }
    }
    return {ok: true};
  };
  globalThis[key] = {control, active: () => !!session};
  globalThis.requestAnimationFrame = request;
  globalThis.cancelAnimationFrame = cancel;
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') stop();
  });
})();
 
'@
        }
        'navigation.js' {
            return @'
/* Navigation only. Final account/chat ID verification is performed by the delivery adapter. */
(() => {
  const label=/*E3_LABEL*/null, chatId=/*E3_CHAT_ID*/null;
  const clean=s=>String(s||'').replace(/[\u200B-\u200D\u2060\uFEFF]/g,'').replace(/\s+/g,' ').trim();
  const visible=n=>n?.isConnected&&n.getClientRects().length>0;
  const login=/(^|\.)login\.(microsoftonline|live|microsoft)\.com$|(^|\.)account\.live\.com$/i.test(location.hostname)
    || [...document.querySelectorAll('input[type="password"]')].some(visible);
  if(login)return {login:true};
  if(!['teams.cloud.microsoft','teams.microsoft.com'].includes(location.hostname))return {stage:'redirect'};
  const roots=[...document.querySelectorAll('[data-tid="chat-pane"], [data-tid="chat-pane-layout"], [data-tid="message-pane-layout"]')]
    .filter(n=>!n.parentElement?.closest('[data-tid="chat-pane"], [data-tid="chat-pane-layout"], [data-tid="message-pane-layout"]'));
  const root=roots.length===1?roots[0]:null;
  const header=document.querySelector('[data-tid="chat-header"], [data-tid="chat-header-bar"], [data-tid="entity-header"]');
  const ids=[root?.getAttribute('data-chat-id'),header?.getAttribute('data-chat-id'),
    ...[...(root?.querySelectorAll('[data-track-thread-id]')||[])].map(n=>n.getAttribute('data-track-thread-id'))].filter(Boolean);
  const composer=root?.querySelector('[data-tid="ckeditor"][contenteditable="true"], [data-tid="message-composer"][contenteditable="true"], [data-tid="compose-box"] [role="textbox"][contenteditable="true"]');
  if(composer&&ids.length&&ids.every(id=>id===chatId))return {ready:true};
  // Some Teams versions route self chats through the chat list instead of resolving a deep link.
  // Select only an exact saved label; duplicate names are blocked and IDs are verified afterwards.
  const s=globalThis.__e3HeadlessNav||(globalThis.__e3HeadlessNav={clicked:false,nav:false,top:false});
  const buttons=[...document.querySelectorAll('a,button,[role="button"],[role="tab"]')].filter(visible);
  const web=buttons.find(n=>/^(改用網頁|使用網頁版|Use the web app|Continue on this browser|在此瀏覽器上繼續)/i.test(clean(n.innerText||n.getAttribute('aria-label'))));
  if(web&&!s.launcher){s.launcher=true;web.click();return {stage:'web_launcher'};}
  if(s.clicked&&composer&&ids.length&&!ids.every(id=>id===chatId))return {stage:'verify_chat_id',mismatch:Date.now()-s.clickedAt>5000};
  if(!s.clicked){
    const items=[...document.querySelectorAll('[role="treeitem"]')].filter(visible);
    const matches=items.filter(n=>clean((n.innerText||'').split('\n')[0])===clean(label)||clean(n.getAttribute('aria-label'))===clean(label));
    if(matches.length>1)return {ambiguous:true};
    if(matches.length===1){s.clicked=true;s.clickedAt=Date.now();matches[0].scrollIntoView({block:'center'});matches[0].click();return {stage:'select_chat'};}
    const nav=buttons.find(n=>/^(Chat|聊天)(\s|\(|$)/i.test(clean(n.getAttribute('aria-label')||n.innerText)));
    if(!s.nav&&nav){s.nav=true;nav.click();return {stage:'chat_list'};}
    let scroll=document.querySelector('[role="tree"]');
    while(scroll&&scroll.scrollHeight<=scroll.clientHeight+2)scroll=scroll.parentElement;
    if(scroll&&scroll!==document.documentElement){if(!s.top){scroll.scrollTop=0;s.top=true;}else{scroll.scrollTop+=Math.max(200,scroll.clientHeight*.8);}}
  }
  return {stage:composer?'locate_chat':'loading'};
})()
 
'@
        }
        'model-ready.js' {
            return @'
(() => {
  const elements=[...document.querySelectorAll('[data-tid="ckeditor"][contenteditable="true"], [contenteditable="true"].ck-content')];
  if(elements.length!==1) return false;
  const editor=elements[0].ckeditorInstance;
  if(!editor?.model?.document?.getRoot) return false;
  const states=[];
  function walk(node) {
    if(node.name==='inlineImage') {
      let props=node.getAttribute('itemprops');
      if(typeof props==='string') {try{props=JSON.parse(props);}catch(_){props=null;}}
      states.push(props?.['data-loading-state'] || 'unknown');
    }
    for(const child of node.getChildren?.() || []) walk(child);
  }
  walk(editor.model.document.getRoot());
  const expectedCount = /*E3_IMAGE_COUNT*/1;
  return states.length===expectedCount && states.every(state=>state==='success');
})()
 
'@
        }
        default { throw "未知的 CDP 網頁腳本：$file" }
    }
}
 
#endregion


