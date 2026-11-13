# Cross-process work ownership and explicit choices. Import has no side effects.
function Disable-E3ConsoleQuickEdit {
    # Keep Read-Host and Ctrl+C; only prevent mouse selection from pausing the service.
    try {
        if(-not ('E3WorkConsoleMode' -as [type])){
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class E3WorkConsoleMode {
    [DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int id);
    [DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr handle, out uint mode);
    [DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr handle, uint mode);
}
'@
        }
        $handle=[E3WorkConsoleMode]::GetStdHandle(-10);$mode=[uint32]0
        if(-not [E3WorkConsoleMode]::GetConsoleMode($handle,[ref]$mode)){return}
        $desired=[uint32](($mode -bor 0x0080) -band (-bnot 0x0040))
        if(-not [E3WorkConsoleMode]::SetConsoleMode($handle,$desired)){throw 'SetConsoleMode failed'}
    }catch{Write-Warning '無法停用快速編輯；若黑色視窗標題顯示「選取」，請按 Esc 恢復操作。'}
}
function Test-E3ProcessElevated {
    # True when this process holds administrator rights (an elevated token, or UAC turned off for an
    # administrator account). Read-only; $null when Windows does not say.
    try {
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent()
        try {return ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}
        finally {$identity.Dispose()}
    } catch {return $null}
}
function Get-E3WorkRoot {
    if($script:E3WorkControlRoot){return $script:E3WorkControlRoot}
    return Join-Path $PSScriptRoot 'logs\work_control'
}
function Write-E3WorkJson([string]$path,$value) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    $temp=Join-Path ([IO.Path]::GetDirectoryName($path)) ('.work_'+[guid]::NewGuid().ToString('N')+'.tmp')
    try{
        [IO.File]::WriteAllText($temp,($value|ConvertTo-Json -Depth 8 -Compress),[Text.UTF8Encoding]::new($false))
        if([IO.File]::Exists($path)){[IO.File]::Replace($temp,$path,[NullString]::Value)}else{[IO.File]::Move($temp,$path)}
    }finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
function Read-E3WorkJson([string]$path) {
    if(-not [IO.File]::Exists($path)){return $null}
    # Writer publishes atomically; allow it to replace while this reader holds a handle.
    $s=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $r=[IO.StreamReader]::new($s,[Text.Encoding]::UTF8)
    try{return ($r.ReadToEnd()|ConvertFrom-Json)}finally{$r.Dispose()}
}
function Test-E3WorkProcess($record) {
    if(-not $record){return $false}
    $p=$null
    try{$p=Get-Process -Id ([int]$record.pid) -ErrorAction Stop;return (-not $p.HasExited -and $p.StartTime.ToUniversalTime().Ticks.ToString() -ceq [string]$record.processStart)}
    catch{return $false}finally{if($p){$p.Dispose()}}
}
function Get-E3WorkOwner([string]$resource) {
    if($resource -notin @('cdp','capture')){throw '未知操作資源'}
    $owner=Read-E3WorkJson (Join-Path (Get-E3WorkRoot) ($resource+'.owner.json'))
    if(Test-E3WorkProcess $owner){return $owner}
    return $null
}
function Register-E3WorkOwner([string]$resource,[string]$description) {
    if(-not $script:E3WorkLeases){$script:E3WorkLeases=@{}}
    if($script:E3WorkLeases.ContainsKey($resource)){$script:E3WorkLeases[$resource].depth++;return}
    $p=[Diagnostics.Process]::GetCurrentProcess()
    try{$record=@{id=[guid]::NewGuid().ToString('N');resource=$resource;description=$description;pid=$PID;processStart=$p.StartTime.ToUniversalTime().Ticks.ToString();startedUtc=[DateTimeOffset]::UtcNow.ToString('O');entryScript=$script:E3WorkEntryScript;mode=$(if($script:E3WorkMayTerminate){'worker'}else{'cooperative'})}}
    finally{$p.Dispose()}
    Write-E3WorkJson (Join-Path (Get-E3WorkRoot) ($resource+'.owner.json')) $record
    $script:E3WorkLeases[$resource]=@{record=$record;depth=1}
}
function Unregister-E3WorkOwner([string]$resource) {
    if(-not $script:E3WorkLeases -or -not $script:E3WorkLeases.ContainsKey($resource)){return}
    $lease=$script:E3WorkLeases[$resource];$lease.depth--
    if($lease.depth -gt 0){return}
    try{
        $path=Join-Path (Get-E3WorkRoot) ($resource+'.owner.json')
        $saved=Read-E3WorkJson $path
        if($saved.id -ceq $lease.record.id){[IO.File]::Delete($path)}
    }catch{Write-Warning '工作狀態暫時無法清除；下次會重新核對程序。'}
    finally{$script:E3WorkLeases.Remove($resource)}
}
function Assert-E3WorkNotCancelled {
    if(-not $script:E3WorkLeases){return}
    foreach($lease in $script:E3WorkLeases.Values){
        if([IO.File]::Exists((Join-Path (Get-E3WorkRoot) ($lease.record.id+'.cancel.json')))){throw '使用者已選擇執行新工作，本次工作已取消；已送出的內容不會撤回或重送。'}
    }
}
function Stop-E3WorkOwner($owner) {
    $current=Get-E3WorkOwner $owner.resource
    if(-not $current -or $current.id -cne $owner.id){throw '占用工作已變更，請重新選擇；未取消其他工作。'}
    if($owner.mode -ne 'worker'){
        Write-E3WorkJson (Join-Path (Get-E3WorkRoot) ($owner.id+'.cancel.json')) @{at=[DateTimeOffset]::UtcNow.ToString('O');owner=$owner.id}
        return
    }
    # Kill only a verified, dedicated tool worker, never Edge, the server or listener.
    $p=Get-Process -Id ([int]$owner.pid) -ErrorAction Stop
    try{
        if($p.Id -eq $PID -or $p.ProcessName -notin @('powershell','pwsh') -or $p.StartTime.ToUniversalTime().Ticks.ToString() -cne [string]$owner.processStart){throw '工作程序身分已變更，未中止'}
        $entry=[IO.Path]::GetFullPath([string]$owner.entryScript)
        if($entry -notin @((Join-Path $PSScriptRoot 'e3_monitor_native.ps1'),(Join-Path $PSScriptRoot 'teams_receiver.ps1'))){throw '不是可取消的專用工作程序'}
        $info=Get-CimInstance Win32_Process -Filter ('ProcessId='+$p.Id)
        $line=[string]$info.CommandLine
        if($line -match '(?i)-EncodedCommand\s+([A-Za-z0-9+/=]+)'){$line=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1]))}
        if($line.IndexOf($entry,[StringComparison]::OrdinalIgnoreCase) -lt 0 -or $line -match '(?i)-(Calibrator|Listen)\b'){throw '此程序不是可取消的工作，未中止服務或接收端'}
        if((Get-E3WorkOwner $owner.resource).id -cne $owner.id){throw '占用工作已變更，未強制停止其他工作'}
        Write-E3WorkJson (Join-Path (Get-E3WorkRoot) ($owner.id+'.cancel.json')) @{at=[DateTimeOffset]::UtcNow.ToString('O');owner=$owner.id}
        $p.Kill()
        if(-not $p.WaitForExit(5000)){throw '前一工作尚未停止，未交接操作權'}
    }finally{$p.Dispose()}
}
function Enter-E3WorkLock($mutex,[string]$resource,[string]$description,[int]$TimeoutSeconds=180) {
    $locked=$false;$request=$null
    try{
        try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
        if(-not $locked){try{$locked=$mutex.WaitOne(1000)}catch [Threading.AbandonedMutexException]{$locked=$true}}
        if(-not $locked){
            $p=[Diagnostics.Process]::GetCurrentProcess()
            try{$request=@{id=[guid]::NewGuid().ToString('N');token=[guid]::NewGuid().ToString('N');resource=$resource;description=$description;pid=$PID;processStart=$p.StartTime.ToUniversalTime().Ticks.ToString();createdUtc=[DateTimeOffset]::UtcNow.ToString('O');expiresUtc=[DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds).ToString('O');state='prompt';owner=(Get-E3WorkOwner $resource)}}finally{$p.Dispose()}
            $path=Join-Path (Get-E3WorkRoot) ('waits\'+$request.id+'.json')
            Write-E3WorkJson $path $request
            Write-Host '工作忙碌，請在設定網頁選擇「繼續等待」或「強制停止前一工作，執行新的」；也可取消本次。' -ForegroundColor Yellow
            while(-not $locked){
                Assert-E3WorkNotCancelled
                if([DateTimeOffset]::UtcNow -ge [DateTimeOffset]::Parse($request.expiresUtc)){throw '等待已逾時，本次未取得操作權；可在設定網頁重新執行。'}
                $decision=Read-E3WorkJson (Join-Path (Get-E3WorkRoot) ('decisions\'+$request.id+'.'+$request.token+'.json'))
                if($decision -and $decision.decision -eq 'cancel'){throw '使用者已取消本次等待；未執行新工作。'}
                try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
                if($locked){break}
                if($decision){
                    if($decision.decision -eq 'replace'){
                        Stop-E3WorkOwner $request.owner
                        $request.state='stopping';$request.expiresUtc=[DateTimeOffset]::UtcNow.AddSeconds(30).ToString('O')
                    }else{$request.state='waiting';$request.expiresUtc=[DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds).ToString('O')}
                    $request.token=[guid]::NewGuid().ToString('N')
                    Write-E3WorkJson $path $request
                }
                try{$locked=$mutex.WaitOne(200)}catch [Threading.AbandonedMutexException]{$locked=$true}
                if(-not $locked -and $request.state -ne 'stopping'){
                    $owner=Get-E3WorkOwner $resource
                    if($owner.id -cne $request.owner.id){$request.owner=$owner;$request.token=[guid]::NewGuid().ToString('N');$request.state='prompt';Write-E3WorkJson $path $request}
                }
            }
        }
        Register-E3WorkOwner $resource $description
        return $true
    }catch{if($locked){$mutex.ReleaseMutex()};throw}
    finally{if($request){$request.state='closed';try{Write-E3WorkJson $path $request}catch{}}}
}
function Get-E3WorkWaits {
    $folder=Join-Path (Get-E3WorkRoot) 'waits'
    if(-not [IO.Directory]::Exists($folder)){return}
    foreach($file in Get-ChildItem -LiteralPath $folder -Filter '*.json'){
        try{
            $r=Read-E3WorkJson $file.FullName
            if($r.state -notin @('prompt','waiting','stopping') -or -not (Test-E3WorkProcess $r) -or [DateTimeOffset]::UtcNow -ge [DateTimeOffset]::Parse($r.expiresUtc)){continue}
            $owner=Get-E3WorkOwner $r.resource
            @{id=$r.id;token=$r.token;description=$r.description;state=$r.state;createdUtc=$r.createdUtc;expiresUtc=$r.expiresUtc;ownerId=$r.owner.id;ownerMode=$owner.mode;ownerDescription=$(if($owner -and $owner.id -ceq $r.owner.id){$owner.description}else{'操作正在交接，請稍候重新查詢'});canReplace=[bool]($owner -and $owner.id -ceq $r.owner.id)}
        }catch{continue}
    }
}
function Submit-E3WorkDecision([string]$id,[string]$token,[string]$decision,[string]$ownerId) {
    if($id -cnotmatch '^[a-f0-9]{32}$' -or $token -cnotmatch '^[a-f0-9]{32}$' -or $decision -notin @('wait','replace','cancel')){throw '選擇內容無效'}
    $r=Read-E3WorkJson (Join-Path (Get-E3WorkRoot) ('waits\'+$id+'.json'))
    if(-not $r -or $r.token -cne $token -or $r.state -notin @('prompt','waiting') -or -not (Test-E3WorkProcess $r) -or [DateTimeOffset]::UtcNow -ge [DateTimeOffset]::Parse($r.expiresUtc)){throw '等待狀態已變更，請重新查詢'}
    if($decision -eq 'replace'){
        $owner=Get-E3WorkOwner $r.resource
        if(-not $owner -or $owner.id -cne $ownerId -or $owner.id -cne $r.owner.id){throw '占用工作已變更，請重新確認'}
    }
    $folder=Join-Path (Get-E3WorkRoot) 'decisions';[void][IO.Directory]::CreateDirectory($folder)
    $path=Join-Path $folder ($id+'.'+$token+'.json')
    $prior=Read-E3WorkJson $path
    if($prior){if($prior.decision -eq $decision){return};throw '已收到另一個選擇，請重新查詢'}
    $temp=Join-Path $folder ('.decision_'+[guid]::NewGuid().ToString('N')+'.tmp')
    try{Write-E3WorkJson $temp @{decision=$decision};[IO.File]::Move($temp,$path)}finally{if([IO.File]::Exists($temp)){[IO.File]::Delete($temp)}}
}
 