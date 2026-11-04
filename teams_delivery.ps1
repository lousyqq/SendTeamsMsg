# Common batching contract for desktop/PWA/Edge UI and CDP transports.
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
    if($count -gt 1){return "$message`n（第 $index/$count 批）"}
    return $message
}
 