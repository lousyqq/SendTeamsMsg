# Loaded by the native engine after its capture functions are defined.
function Invoke-E3ReceiverCaptureJob($cfg,[string]$job) {
    $captureMutex=[Threading.Mutex]::new($false,'Local\E3MonitorNativeRun')
    $captureOwned=$false;$captureDeadline=$null;$result=@();$jobError=''
    try {
        $captureDeadline=Start-E3RunDeadline (Join-Path $job 'deadline.json') -Seconds 300
        $request=Get-Content -LiteralPath (Join-Path $job 'request.json') -Raw -Encoding UTF8|ConvertFrom-Json
        $ids=@($request.pageIds|Select-Object -Unique)
        if(-not $ids.Count -or $ids.Count -gt 20){throw 'Invalid capture page count'}
        foreach($id in $ids){if([string]$id -notmatch '^[A-Za-z0-9_-]+$'){throw 'Invalid capture page ID'}}
        $captureOwned=Enter-E3WorkLock $captureMutex 'capture' 'Teams 指令：擷取指定圖表'
        $selected=@()
        foreach($id in $ids){
            $found=@($cfg.pages|Where-Object{$_.id -ceq $id -and $_.enabled -ne $false})
            if($found.Count -eq 1){$selected+=$found[0]}
            else{$result+=@{id=$id;ok=$false;error='頁面不存在、停用或 ID 重複'}}
        }
        if($selected.Count){
            $capture=Capture-PagesNative $selected $cfg.auth $job -Headless
            foreach($page in $selected){
                $ok=$false;$reason='';$analysis=$null
                try{
                    $file=$capture.Files[$page.id]
                    if(-not $file -or -not [IO.File]::Exists($file)){throw [string]$capture.Failures[$page.id]}
                    # Check per page; preserve all other successful screenshots.
                    $bitmap=[Drawing.Bitmap]::new($file)
                    try{if($bitmap.Width -gt 4096 -or $bitmap.Height -gt 4096 -or [long]$bitmap.Width*$bitmap.Height -gt 16000000 -or (Get-Item -LiteralPath $file).Length -gt 10MB){throw '圖片超過 Teams 上限，請調整裁切範圍'}}finally{$bitmap.Dispose()}
                    $ok=$true
                    if($request.analyze -eq $true){
                        # @日管 檢查: the same judgment as a scheduled run. A judgment error keeps the
                        # screenshot and is reported as "could not judge", never as normal.
                        try{
                            $a=Invoke-E3PageAnalysis $page $file
                            $analysis=@{captureOnly=[bool]$a.captureOnly;rules=@($a.rules);annotated=$(if($a.annotated -and [IO.File]::Exists($a.annotated)){[IO.Path]::GetFileName($a.annotated)}else{''});error=''}
                        }catch{$analysis=@{captureOnly=$false;rules=@();annotated='';error=$_.Exception.Message}}
                    }
                }catch{$reason=$_.Exception.Message}
                $result+=@{id=$page.id;ok=$ok;error=$reason;analysis=$analysis}
            }
        }
    }catch{Write-Host ('擷取失敗：'+$_.Exception.Message);$jobError=$_.Exception.Message}
    finally{
        if($captureOwned){Unregister-E3WorkOwner 'capture';$captureMutex.ReleaseMutex()};$captureMutex.Dispose()
        if($captureDeadline){$captureDeadline.Dispose()}
    }
    [IO.File]::WriteAllText((Join-Path $job 'result.json'),(@{pages=@($result);error=$jobError;finishedUtc=[DateTimeOffset]::UtcNow.ToString('O')}|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
}
 