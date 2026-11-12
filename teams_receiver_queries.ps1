# Read-only questions answered on the host for @日管: schedule results, host status and site
# reachability. Loaded by teams_receiver.ps1. Import has no side effects. Nothing here changes
# settings, tasks or files outside the receiver's own logs, and chat text is never executed:
# it only selects saved pages / schedules.

function Get-E3ReceiverTaipeiTime([DateTime]$utc,[string]$format='MM/dd HH:mm') {
    return [TimeZoneInfo]::ConvertTimeFromUtc($utc,[TimeZoneInfo]::FindSystemTimeZoneById('Taipei Standard Time')).ToString($format)
}

# ---- 排程結果 ----
function Get-E3ReceiverScheduleLogLines([string]$id,[string]$logRoot=$null,[DateTime]$Now=[DateTime]::Now) {
    # Problem lines (❌ / ⚠️) of the newest log of this schedule from the last 26 hours, so a
    # "why" can be answered without opening the host. Returns @{at;lines} or $null.
    if($id -notmatch '^[A-Za-z0-9_-]+$'){return $null}
    # Tests point $script:E3ReceiverQueryLogRoot at a fixture folder.
    if(-not $logRoot){$logRoot=if($script:E3ReceiverQueryLogRoot){$script:E3ReceiverQueryLogRoot}else{Join-Path $PSScriptRoot 'logs'}}
    if(-not [IO.Directory]::Exists($logRoot)){return $null}
    $pattern='^(\d{4}-\d\d-\d\d_\d{4})_'+[regex]::Escape($id)+'\.log$'
    $newest=@(Get-ChildItem -LiteralPath $logRoot -Filter ('*_'+$id+'.log') -File -ErrorAction SilentlyContinue|Where-Object{$_.Name -match $pattern -and $_.LastWriteTime -gt $Now.AddHours(-26)}|Sort-Object Name -Descending)|Select-Object -First 1
    if(-not $newest){return $null}
    $at=[DateTime]::MinValue
    [void][DateTime]::TryParseExact(($newest.Name -replace $pattern,'$1'),'yyyy-MM-dd_HHmm',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$at)
    $reader=$null;$lines=@()
    try{
        # A transcript can still be open by a running schedule; share it.
        $stream=[IO.File]::Open($newest.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
        $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true)
        while($null -ne ($line=$reader.ReadLine())){
            $clean=$line.Trim()
            if($clean -match '^(❌|⚠️|🚨)' -and $clean -notmatch '繼續發送到其他對話'){
                if($clean.Length -gt 150){$clean=$clean.Substring(0,150)+'…'}
                if($lines -notcontains $clean){$lines+=$clean}
            }
        }
    }catch{return $null}finally{if($reader){$reader.Dispose()}}
    return @{at=$at;lines=@($lines|Select-Object -First 6);more=[Math]::Max(0,$lines.Count-6)}
}
function Get-E3ReceiverScheduleReport($request,$cfg=$null,$tasks='read') {
    if(-not $cfg){$cfg=Get-E3ReceiverConfig}
    if($tasks -is [string] -and $tasks -eq 'read'){
        $tasks=$null
        try{Import-Module ScheduledTasks -ErrorAction Stop;$tasks=@(Get-ScheduledTask -ErrorAction Stop|Where-Object{$_.TaskPath -eq '\'})}catch{}
    }
    $picked=@($request.schedules|Where-Object{$_})
    $lines=@('✦ [日管]')
    if(-not @($cfg.schedules).Count){return (@($lines)+'目前沒有設定任何排程。') -join "`n"}
    if(-not $picked.Count){
        $lines+="沒有找到「$($request.label)」的排程。目前的排程："
        $lines+=@($cfg.schedules|ForEach-Object{'• '+$_.name+'（'+$_.time+'）'})
        return ($lines -join "`n")
    }
    $lines+=$(if($request.label -and $request.label -ne '全部排程'){"「$($request.label)」的排程最近一輪："}else{'各排程最近一輪：'})
    $view=[pscustomobject]@{schedules=$picked}
    $lines+=@(Get-E3ReceiverScheduleLines $view $tasks)
    foreach($s in $picked){
        if($s.enabled -eq $false){continue}
        $log=Get-E3ReceiverScheduleLogLines ([string]$s.id)
        if($log -and @($log.lines).Count){
            $name=([string]$s.name).Trim();if(-not $name){$name=[string]$s.id}
            $lines+="$name 主機紀錄（$($log.at.ToString('MM/dd HH:mm'))）的錯誤與提醒："
            $lines+=@($log.lines)
            if($log.more){$lines+="（另有 $($log.more) 行，請到主機 logs 資料夾查看）"}
        }
    }
    $lines+='這裡只查結果，不會執行或補跑排程。'
    return ($lines -join "`n")
}

# ---- 主機狀況 ----
function Get-E3ReceiverHostFacts {
    # Separate so the reply can be tested with fixed numbers. Each part fails on its own.
    $facts=@{computer=$env:COMPUTERNAME;errors=@()}
    try{
        $os=Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $facts.boot=[DateTime]$os.LastBootUpTime
        $facts.memTotalKb=[double]$os.TotalVisibleMemorySize;$facts.memFreeKb=[double]$os.FreePhysicalMemory
    }catch{$facts.errors+='系統資訊：'+$_.Exception.Message}
    try{$facts.cpu=[int](@(Get-CimInstance Win32_Processor -ErrorAction Stop|Measure-Object LoadPercentage -Average)[0].Average)}catch{$facts.errors+='CPU：'+$_.Exception.Message}
    try{$facts.disks=@(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction Stop|ForEach-Object{@{name=[string]$_.DeviceID;size=[double]$_.Size;free=[double]$_.FreeSpace}})}catch{$facts.errors+='磁碟：'+$_.Exception.Message}
    $facts.projectDrive=([IO.Path]::GetPathRoot($PSScriptRoot)).TrimEnd('\')
    return $facts
}
function Format-E3ReceiverBytes([double]$bytes) {
    if($bytes -ge 1TB){return ('{0:N1} TB' -f ($bytes/1TB))}
    return ('{0:N1} GB' -f ($bytes/1GB))
}
function Get-E3ReceiverHostReply($facts=$null,$cfg=$null,$tasks='read',$sources=$null,[DateTime]$Now=[DateTime]::Now) {
    if(-not $facts){$facts=Get-E3ReceiverHostFacts}
    if(-not $cfg){$cfg=Get-E3ReceiverConfig}
    if($null -eq $sources){$sources=$script:E3ReceiverLiveSources}
    if($tasks -is [string] -and $tasks -eq 'read'){
        $tasks=$null
        try{Import-Module ScheduledTasks -ErrorAction Stop;$tasks=@(Get-ScheduledTask -ErrorAction Stop|Where-Object{$_.TaskPath -eq '\'})}catch{}
    }
    $lines=@('✦ [日管]',"主機：$($facts.computer)")
    $warn=@()
    if($facts.boot){
        $up=$Now-$facts.boot
        $lines+=('開機時間：'+$facts.boot.ToString('MM/dd HH:mm')+'（已開機 '+$(if($up.TotalDays -ge 1){'{0} 天 {1} 小時' -f [int][Math]::Floor($up.TotalDays),$up.Hours}else{'{0} 小時 {1} 分' -f [int][Math]::Floor($up.TotalHours),$up.Minutes})+'）')
    }
    if($null -ne $facts.cpu){$lines+="CPU 使用率：$($facts.cpu)%";if($facts.cpu -ge 90){$warn+='CPU 使用率很高'}}
    if($facts.memTotalKb){
        $used=$facts.memTotalKb-$facts.memFreeKb;$pct=[int][Math]::Round(100*$used/$facts.memTotalKb)
        $lines+=('記憶體：已用 {0:N1}／{1:N1} GB（{2}%）' -f ($used/1MB),($facts.memTotalKb/1MB),$pct)
        if($pct -ge 90){$warn+='記憶體快用完'}
    }
    foreach($d in @($facts.disks|Sort-Object {$_.name})){
        if(-not $d.size){continue}
        $pct=[int][Math]::Round(100*$d.free/$d.size)
        $mark=if($pct -lt 10 -or $d.free -lt 5GB){' ⚠ 空間不足'}else{''}
        $lines+=("磁碟 $($d.name)：剩 $(Format-E3ReceiverBytes $d.free)／共 $(Format-E3ReceiverBytes $d.size)（$pct%）"+$(if($d.name -ieq $facts.projectDrive){'，程式與截圖在這顆'}else{''})+$mark)
        if($mark){$warn+="磁碟 $($d.name) 空間不足"}
    }
    # The receiver is answering, so its own Teams login works; list the chats it reads.
    $list=@($sources|Where-Object{$_})
    if($list.Count){
        $bad=@($list|Where-Object{-not $_.active -or $_.error})
        $lines+=$(if($bad.Count){"接收對話：$($list.Count) 個，其中 $($bad.Count) 個目前讀不到："}else{"接收對話：$($list.Count) 個都正常讀取"})
        foreach($s in $bad){$lines+=('• '+[string]$s.target.route+'：'+$(if($s.error){Format-E3ReceiverReason ([string]$s.error) 120}else{'尚未成功讀取'}))}
    }
    try{$lines+=@(Get-E3ReceiverHealthLines $cfg $tasks '')}catch{$lines+='其他狀態暫時無法讀取：'+$_.Exception.Message}
    foreach($e in @($facts.errors)){$lines+='讀不到 '+(Format-E3ReceiverReason $e 120)}
    $lines+=$(if($warn.Count){'⚠ 需要注意：'+($warn -join '、')}else{'整體看起來正常。'})
    return ($lines -join "`n")
}

# ---- 網站連線 ----
function Test-E3ReceiverSite([string]$url,[int]$TimeoutMs=8000) {
    # One GET without credentials or cookies (no site login, no Windows sign-in sent), headers only.
    $uri=$null
    if(-not [Uri]::TryCreate($url,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -notin @('http','https')){return @{ok=$false;text='網址不是 http／https，無法測試'}}
    try{[Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12}catch{}
    $watch=[Diagnostics.Stopwatch]::StartNew();$response=$null
    try{
        $req=[Net.HttpWebRequest]::Create($uri)
        $req.Method='GET';$req.Timeout=$TimeoutMs;$req.ReadWriteTimeout=$TimeoutMs;$req.AllowAutoRedirect=$true;$req.UseDefaultCredentials=$false
        $req.UserAgent='E3MonitorConnectivityCheck'
        $response=$req.GetResponse()
        $code=[int]$response.StatusCode
        return @{ok=$true;code=$code;seconds=$watch.Elapsed.TotalSeconds;text=('連得到（HTTP {0}，{1:N1} 秒）' -f $code,$watch.Elapsed.TotalSeconds)}
    }catch [Net.WebException]{
        $ex=$_.Exception
        if($ex.Response){
            $code=[int]$ex.Response.StatusCode;$ex.Response.Dispose()
            if($code -in @(401,403)){return @{ok=$true;code=$code;text=('連得到，網站要求登入（HTTP {0}，{1:N1} 秒）' -f $code,$watch.Elapsed.TotalSeconds)}}
            return @{ok=$false;code=$code;text=('網站回應錯誤（HTTP {0}，{1:N1} 秒）' -f $code,$watch.Elapsed.TotalSeconds)}
        }
        $why=switch([string]$ex.Status){
            'NameResolutionFailure' {'找不到這個主機名稱（DNS 查不到）'}
            'ConnectFailure' {'連不上（主機沒回應、服務沒開或被防火牆擋住）'}
            'Timeout' {"超過 $([int]($TimeoutMs/1000)) 秒沒有回應"}
            'TrustFailure' {'憑證不受信任'}
            'SecureChannelFailure' {'加密連線建立失敗（TLS）'}
            'ProxyNameResolutionFailure' {'找不到 Proxy 主機'}
            default {Format-E3ReceiverReason $ex.Message 120}
        }
        return @{ok=$false;text=$why}
    }catch{
        return @{ok=$false;text=(Format-E3ReceiverReason $_.Exception.Message 120)}
    }finally{if($response){$response.Dispose()};$watch.Stop()}
}
function Get-E3ReceiverConnectReply($request,[scriptblock]$Probe=$null) {
    if(-not $Probe){$Probe={param($url) Test-E3ReceiverSite $url}}
    $lines=@('✦ [日管]',"網站連線測試（$(Get-E3ReceiverTaipeiTime ([DateTime]::UtcNow))）：")
    $cache=@{};$bad=0
    foreach($page in @($request.pages)){
        $url=[string]$page.url
        if(-not $cache.ContainsKey($url)){$cache[$url]=& $Probe $url}
        $r=$cache[$url]
        if(-not $r.ok){$bad++}
        $lines+=($(if($r.ok){'✅ '}else{'❌ '})+$page.name+'：'+$r.text)
    }
    if(@($request.warnings).Count){$lines+=@($request.warnings)}
    if($bad){$lines+="有 $bad 頁連不上；網站或網路恢復前，這些頁的截圖與排程也會失敗。"}
    $lines+='這只測網站有沒有回應，不登入、不截圖；連得到不代表登入或圖表一定正常。'
    return ($lines -join "`n")
}
