# Isolated tests of the capture Edge startup (dynamic debugging port, owner check, no proxy,
# 60-second wait). Uses a temporary profile and a throw-away Edge; never touches edge_profile,
# config, Teams or Windows tasks. Only the needed functions are taken from the engine.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path $env:TEMP ('E3CaptureStartup_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
$passed=0
function Check([bool]$ok,[string]$name){if(-not $ok){throw "FAIL $name"};$script:passed++;Write-Host "PASS $name"}
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'e3_monitor_native.ps1'),[ref]$null,[ref]$null)
foreach($name in 'Get-BrowserPath','Invoke-CaptureLocalJson','Test-CaptureProcessAlive','Get-CaptureEdgeProcessIds','Wait-CaptureDevTools','Wait-CdpTargets','Stop-ProfileEdge'){
    $def=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    if(-not $def){throw "engine function missing: $name"}
    . ([scriptblock]::Create($def.Extent.Text))
}
$profileDir=Join-Path $fixture 'edge_profile'
[void][IO.Directory]::CreateDirectory($profileDir)
$portFile=Join-Path $profileDir 'DevToolsActivePort'
$savedProxy=[Net.WebRequest]::DefaultWebProxy
try{
    # ---- A. Nothing started: a short wait ends with a clear reason ----
    $reason='';try{$null=Wait-CaptureDevTools 2}catch{$reason=$_.Exception.Message}
    Check ($reason -match '等待專用 Edge 啟動逾時（2 秒）' -and $reason -match 'DevToolsActivePort') 'no Edge: times out with the reason'

    # ---- B. A port file pointing at a port this script (not the profile Edge) listens on ----
    $listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start()
    try{
        $port=$listener.LocalEndpoint.Port
        [IO.File]::WriteAllText($portFile,"$port`n/devtools/browser/fixture-0000",[Text.Encoding]::ASCII)
        $reason='';try{$null=Wait-CaptureDevTools 10}catch{$reason=$_.Exception.Message}
        Check ($reason -match "除錯埠 $port 不是專用 Edge" -and $reason -match "PID $PID") 'a port held by another process is refused at once, never connected to'
    }finally{$listener.Stop();Remove-Item -LiteralPath $portFile -Force -ErrorAction SilentlyContinue}

    # ---- C. Real Edge with the same launch arguments, behind a broken system proxy ----
    # Every request that used the system proxy would fail; local requests must not use it.
    [Net.WebRequest]::DefaultWebProxy=[Net.WebProxy]::new('http://127.0.0.1:9',$false)
    $argList="--remote-debugging-address=127.0.0.1 --remote-debugging-port=0 --user-data-dir=`"$profileDir`" --disable-features=Translate,msEdgeTranslate --window-size=1920,1080 --force-device-scale-factor=1 --hide-crash-restore-bubble --disable-background-timer-throttling --disable-backgrounding-occluded-windows --disable-renderer-backgrounding about:blank --headless=new"
    Start-Process -FilePath (Get-BrowserPath) -ArgumentList $argList -WindowStyle Hidden
    $ready=Wait-CaptureDevTools
    Write-Host ("Edge ready in {0} s on port {1}" -f $ready.seconds,$ready.port)
    Check ($ready.port -gt 0 -and $ready.port -ne 9333 -and $ready.seconds -lt 60) 'real Edge: dynamic port found and verified as the profile Edge'
    $targets=@(Wait-CdpTargets $ready.port | ForEach-Object { $_ })
    Check (@($targets|Where-Object{$_.type -eq 'page'}).Count -ge 1) 'tab list readable through the proxy-free request'
    $new=Invoke-CaptureLocalJson "http://127.0.0.1:$($ready.port)/json/new?about:blank" 'PUT' 10000
    Check ([string]$new.webSocketDebuggerUrl -match "^ws://127\.0\.0\.1:$($ready.port)/devtools/page/") 'new tab can be opened'
    $failed='';try{$null=Invoke-RestMethod -Uri "http://127.0.0.1:$($ready.port)/json/version" -TimeoutSec 3}catch{$failed=$_.Exception.Message}
    Write-Host ("(for comparison) Invoke-RestMethod with the broken system proxy: "+$(if($failed){"failed: $failed"}else{'worked (proxy bypassed for loopback)'}))
    Check ((Get-CaptureEdgeProcessIds).Count -ge 1) 'profile Edge processes are recognised by their user-data-dir'
    $reason='';try{$null=Invoke-CaptureLocalJson 'http://example.invalid/json' 'GET' 1000}catch{$reason=$_.Exception.Message}
    Check ($reason -match '非本機') 'non-local debugging addresses are refused'
}finally{
    [Net.WebRequest]::DefaultWebProxy=$savedProxy
    try{Stop-ProfileEdge 6>$null}catch{}
    Start-Sleep -Milliseconds 500
    Get-CimInstance Win32_Process|Where-Object{$_.CommandLine -like "*$fixture*"}|ForEach-Object{Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue}
    # A killed Edge can take several seconds to finish tearing down.
    $until=(Get-Date).AddSeconds(20)
    do{
        $alive=@(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'"|Where-Object{$_.CommandLine -like "*$fixture*" -and (Test-CaptureProcessAlive ([int]$_.ProcessId))})
        if(-not $alive.Count){break};Start-Sleep -Milliseconds 500
    }while((Get-Date) -lt $until)
    Remove-Item $fixture -Recurse -Force -ErrorAction SilentlyContinue
}
Check (-not $alive.Count) 'the test Edge is closed afterwards'
"PASS $passed checks."
