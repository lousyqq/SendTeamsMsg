# Isolated tests of the Teams page-open retry (Move-E3HeadlessPage): network errors are retried
# before anything is pasted, other errors are not, the receiver passes 0 retries, and a real
# headless Edge recovers when a local page becomes reachable between attempts. Temporary profile,
# loopback only; no Teams, send, config or Windows task change.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path $env:TEMP ('E3NavRetry_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
. (Join-Path $root 'teams_receiver.ps1') -LibraryOnly
$script:E3CdpLogRoot=Join-Path $fixture 'logs'
$script:E3WorkControlRoot=Join-Path $fixture 'work'
$passed=0
function Check([bool]$ok,[string]$name){if(-not $ok){throw "FAIL $name"};$script:passed++;Write-Host "PASS $name"}
$realInvoke=${function:Invoke-E3Cdp}

# ---- A. Rules, with the browser and the waits replaced ----
$script:navResults=@();$script:navCalls=0;$script:sleeps=@();$script:restored=0
function Invoke-E3Cdp([string]$method,$params,[int]$TimeoutMs){
    if($method -ne 'Page.navigate'){throw "unexpected $method"}
    $script:navCalls++;$next=$script:navResults[0];$script:navResults=@($script:navResults|Select-Object -Skip 1)
    if($next -is [string] -and $next -eq 'CDP_TIMEOUT'){throw 'CDP_TIMEOUT：Page.navigate'}
    return $next
}
function Start-Sleep{param([int]$Seconds,[int]$Milliseconds) $script:sleeps+=$Seconds}
function Restore-E3NavigationConnection([string]$endpoint){$script:restored++}
function Reset-Case([object[]]$results){$script:navResults=$results;$script:navCalls=0;$script:sleeps=@();$script:restored=0;$script:E3SendNetwork=$null}
$timeout=@{errorText='net::ERR_TIMED_OUT'};$ok=@{frameId='F'}

Reset-Case @($timeout,$ok)
Move-E3HeadlessPage 'https://teams.invalid/x' 6>$null
Check ($script:navCalls -eq 2 -and (@($script:sleeps) -join ',') -eq '10' -and @($script:E3CdpNavigationAttempts).Count -eq 2) 'one network timeout: waits 10 s and opens the page again'
Reset-Case @($timeout,$timeout,$timeout)
$r='';try{Move-E3HeadlessPage 'https://teams.invalid/x' 6>$null}catch{$r=$_.Exception.Message}
Check ($r -eq 'Teams 導航失敗：net::ERR_TIMED_OUT（共試 3 次）' -and (@($script:sleeps) -join ',') -eq '10,20') 'still failing: three attempts (waits 10 s, 20 s), then the reason with the count'
Check (@($script:E3CdpNavigationAttempts|ForEach-Object{$_.error}) -join ',' -eq 'net::ERR_TIMED_OUT,net::ERR_TIMED_OUT,net::ERR_TIMED_OUT') 'every attempt is recorded for the diagnostic file'
foreach($e in 'net::ERR_CONNECTION_RESET','net::ERR_NAME_NOT_RESOLVED','net::ERR_NETWORK_CHANGED','net::ERR_INTERNET_DISCONNECTED','net::ERR_PROXY_CONNECTION_FAILED'){
    Reset-Case @(@{errorText=$e},$ok);Move-E3HeadlessPage 'https://teams.invalid/x' 6>$null
    Check ($script:navCalls -eq 2) "$e is retried"
}
Reset-Case @(@{errorText='net::ERR_ABORTED'},$ok)
$r='';try{Move-E3HeadlessPage 'https://teams.invalid/x' 6>$null}catch{$r=$_.Exception.Message}
Check ($r -eq 'Teams 導航失敗：net::ERR_ABORTED' -and $script:navCalls -eq 1 -and -not @($script:sleeps).Count) 'other errors are not retried'
Reset-Case @($timeout,$ok)
$r='';try{Move-E3HeadlessPage 'https://teams.invalid/x' -NetworkRetries 0 -RetriedLater 6>$null}catch{$r=$_.Exception.Message}
Check ($r -match '稍後會自動再試' -and $script:navCalls -eq 1 -and -not @($script:sleeps).Count) 'receiver (0 retries) gives up at once and says it will try again later'
Reset-Case @($timeout,$ok);$script:E3SendNetwork=@{}
$r='';try{Move-E3HeadlessPage 'https://teams.invalid/x' 6>$null}catch{$r=$_.Exception.Message}
Check ($r -match 'ERR_TIMED_OUT' -and $script:navCalls -eq 1) 'never retried once a send has started'
Reset-Case @('CDP_TIMEOUT')
Move-E3HeadlessPage 'https://teams.invalid/x' 6>$null
Check ($script:navCalls -eq 1 -and $script:restored -eq 1) 'a CDP command timeout still only reconnects, it does not navigate again'
$script:E3SendNetwork=$null
Set-Item function:Invoke-E3Cdp $realInvoke
Remove-Item function:Restore-E3NavigationConnection

# ---- B. Real headless Edge: the page becomes reachable between attempts ----
$probe=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$probe.Start();$port=$probe.LocalEndpoint.Port;$probe.Stop()
$script:server=$null
function Start-Sleep{param([int]$Seconds,[int]$Milliseconds)
    if($Seconds -and -not $script:server){
        # Bring the local "Teams" up during the first retry wait.
        $script:server=[powershell]::Create().AddScript({param($port)
            $l=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,$port);$l.Start()
            $until=(Get-Date).AddSeconds(40)
            while((Get-Date) -lt $until){
                if(-not $l.Pending()){Start-Sleep -Milliseconds 100;continue}
                $c=$l.AcceptTcpClient();$s=$c.GetStream();$buf=New-Object byte[] 4096;[void]$s.Read($buf,0,$buf.Length)
                $b=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: text/html`r`nContent-Length: 25`r`nConnection: close`r`n`r`n<html><b>ready</b></html>")
                $s.Write($b,0,$b.Length);$c.Close()
            }
            $l.Stop()}).AddArgument($port)
        [void]$script:server.BeginInvoke()
        Microsoft.PowerShell.Utility\Start-Sleep -Seconds 1
        return
    }
    if($Milliseconds){Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds $Milliseconds}elseif($Seconds){Microsoft.PowerShell.Utility\Start-Sleep -Seconds $Seconds}
}
$browser=$null
try{
    $browser=Start-E3TestBrowser (Join-Path $fixture 'profile') -Headless
    Invoke-E3Cdp 'Page.enable'|Out-Null
    Move-E3HeadlessPage "http://127.0.0.1:$port/" 6>$null
    $text=Invoke-E3Js 'document.body ? document.body.innerText : ""'
    $first=[string]@($script:E3CdpNavigationAttempts)[0].error
    Write-Host "first attempt: $first"
    Check ($first -match '^net::ERR_' -and @($script:E3CdpNavigationAttempts).Count -eq 2 -and $text -eq 'ready') 'real Edge: the first open fails with a network error, the retry loads the page'
}finally{
    if($script:CdpSocket){$script:CdpSocket.Dispose();$script:CdpSocket=$null}
    if($browser){Close-E3OwnedBrowser $browser}
    if($script:server){$script:server.Stop();$script:server.Dispose()}
    Remove-Item function:Start-Sleep -ErrorAction SilentlyContinue
    $until=(Get-Date).AddSeconds(20)
    do{$alive=@(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'"|Where-Object{$_.CommandLine -like "*$fixture*"}|Where-Object{Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue});if(-not $alive.Count){break};Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 500}while((Get-Date) -lt $until)
    Remove-Item $fixture -Recurse -Force -ErrorAction SilentlyContinue
}
Check (-not $alive.Count) 'the test Edge is closed afterwards'
"PASS $passed checks."
