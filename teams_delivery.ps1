# Common batching contract for desktop/PWA/Edge UI and CDP transports.
function Start-E3RunDeadline([string]$LogPath,[ValidateRange(1,3600)][int]$Seconds=600) {
    if(-not ('E3RunDeadline' -as [type])){
        Add-Type -TypeDefinition @'
using System;using System.IO;using System.Threading;
public sealed class E3RunDeadline:IDisposable {
private Timer timer; private int done; private string path; private int seconds;
public E3RunDeadline(string file,int limit){path=file;seconds=limit;timer=new Timer(Expire,null,limit*1000,Timeout.Infinite);}
private void Expire(object ignored){
  if(Interlocked.Exchange(ref done,1)!=0)return;
  var writer=new Thread(()=>{try{Directory.CreateDirectory(Path.GetDirectoryName(path));File.WriteAllText(path,
   "{\"state\":\"timed_out\",\"exitCode\":124,\"limitSeconds\":"+seconds+",\"utc\":\""+DateTime.UtcNow.ToString("o")+"\",\"message\":\"Worker deadline exceeded. Delivery outcome may be unknown; no automatic resend.\"}");}catch{}});
  writer.IsBackground=true;writer.Start();writer.Join(1000);
  // Native/UIA calls may never return. End only this worker and release its OS locks.
  Environment.Exit(124);
}
public void Dispose(){Interlocked.Exchange(ref done,1);if(timer!=null)timer.Dispose();}
}
'@
    }
    return [E3RunDeadline]::new($LogPath,$Seconds)
}
function Get-TeamsScheduleMessages($teamsCfg,$schedule) {
    $result=@{}
    $custom=$schedule.messages
    if ($null -ne $custom -and $custom -isnot [Collections.IDictionary] -and $custom -isnot [pscustomobject]) { throw '排程 messages 必須是訊息設定物件' }
    foreach($key in @('default_message','normal_summary','abnormal_header')) {
        $has = $null -ne $custom -and (($custom.PSObject.Properties.Name -contains $key) -or ($custom -is [Collections.IDictionary] -and $custom.Contains($key)))
        $value=if($has){$custom.$key}else{$teamsCfg.$key}
        if($null -ne $value -and $value -isnot [string]){throw "排程訊息 $key 必須是文字"}
        $result[$key]=[string]$value
    }
    return $result
}
function Get-TeamsMessageText($teamsCfg,[string]$title,[string[]]$problems,$schedule=$null) {
    $messages=Get-TeamsScheduleMessages $teamsCfg $schedule
    $status=if(@($problems).Count){$messages.abnormal_header}else{$messages.normal_summary}
    $parts=@($title,$messages.default_message,$status)+@($problems)
    return (@($parts|Where-Object{-not [string]::IsNullOrWhiteSpace($_)}) -join "`n")
}
function Get-TeamsScheduleTargets($schedule) {
    if (-not $schedule) { return }
    $hasList = ($schedule.PSObject.Properties.Name -contains 'target_chat_names') -or
        ($schedule -is [Collections.IDictionary] -and $schedule.Contains('target_chat_names'))
    if ($hasList) {
        if ($null -ne $schedule.target_chat_names -and $schedule.target_chat_names -isnot [System.Array]) {
            throw '排程 target_chat_names 必須是收件名稱陣列'
        }
        $names = @($schedule.target_chat_names)
    } else { $names = @($schedule.target_chat_name) }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in $names) {
        if ($null -eq $name) { continue }
        if ($name -isnot [string]) { throw '排程收件對象必須是文字名稱' }
        $route = $name.Trim()
        if ($route -and $seen.Add($route)) { Write-Output $route }
    }
}



function Split-TeamsImageBatches([object[]]$images) {
    $result=[Collections.Generic.List[object]]::new();$items=@();$total=0L
    foreach($entry in $images){
        if($entry.size -lt 1 -or $entry.size -gt 10MB){throw 'Teams 單張圖片必須介於 1 byte 至 10 MiB'}
        if($items.Count -ge 4 -or $total+[long]$entry.size -gt 25MB){$result.Add(@{Items=@($items);Bytes=$total});$items=@();$total=0L}
        $items+=,$entry;$total+=[long]$entry.size
    }
    if($items.Count -or -not $result.Count){$result.Add(@{Items=@($items);Bytes=$total})}
    foreach($batch in $result){Write-Output $batch}
}
function Get-TeamsBatchText([string]$message,[int]$index,[int]$count){
    if([string]::IsNullOrWhiteSpace($message)){return ''}
    if($count -gt 1){return "$message`n（第 $index/$count 批）"}
    return $message
}
 