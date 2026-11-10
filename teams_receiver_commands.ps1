# Command interpretation and capture dispatch. Import does not capture or send.
function Get-E3ReceiverConfig {
    return Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
}
function Format-E3ReceiverText([string]$text,[switch]$ImageReply) {
    # Keep meaningful line breaks for all replies, without empty spacer lines.
    return (@($text -split '\r\n|\r|\n' | ForEach-Object {$_.Trim()} | Where-Object {$_}) -join "`n")
}
function Get-E3ReceiverImageCaption($page) {
    $uri=$null
    if([Uri]::TryCreate([string]$page.url,[UriKind]::Absolute,[ref]$uri) -and $uri.AbsolutePath -match '/(screens|charts)\.php$'){
        $settings=$page.zabbix_time
        $range=if($null -eq $settings){'7d'}else{[string]$settings.range}
        $detail=if($settings.enabled -eq $false){'網站目前時間範圍的圖表'}
            elseif($range -eq '7d'){'最近 7 天圖表'}
            elseif($range -eq '3d'){'最近 3 天圖表'}
            elseif($range -eq 'keep'){'已切到 NOW，保留原有時間區間'}
            else{'依設定時間範圍的圖表'}
        return "已擷取 $($page.name)，$detail"
    }
    return "已擷取 $($page.name)"
}
function Get-E3ReceiverPageIntro($page) {
    $uri=$null
    $isZabbix=[Uri]::TryCreate([string]$page.url,[UriKind]::Absolute,[ref]$uri) -and $uri.AbsolutePath -match '/(screens|charts)\.php$'
    if($isZabbix){
        $settings=$page.zabbix_time
        $range=if($null -eq $settings){'7d'}else{[string]$settings.range}
        $detail=if($settings.enabled -eq $false){'依網站目前的時間範圍擷取圖表'}
            elseif($range -eq '7d'){'擷取最近 7 天（7d）的圖表'}
            elseif($range -eq '3d'){'擷取最近 3 天（3d）的圖表'}
            elseif($range -eq 'keep'){'切到 NOW，保留網站原有時間區間擷取圖表'}
            else{'依已儲存的時間設定擷取圖表'}
        $intro="提供 Zabbix $($page.name)，$detail。"
    }else{$intro="提供 $($page.name)，依已儲存的顯示範圍擷取。"}
    if(-not [string]::IsNullOrWhiteSpace([string]$page.description)){$intro+="`n"+([string]$page.description).Trim()}
    return $intro
}
function Get-E3ReceiverAcknowledgement($request) {
    $parts=@('✦ [日管]','已收到指令，準備截圖。')
    $parts+=@($request.pages|ForEach-Object{Get-E3ReceiverPageIntro $_})
    if($request.warnings.Count){$parts+=@($request.warnings)}
    $parts+='完成後會將圖片回傳到這個對話。'
    return ($parts -join "`n")
}
function Get-E3ReceiverCatalog($cfg) {
    $lines=@('可截圖的項目：')
    $lines+=@($cfg.pages|Where-Object{$_.enabled -ne $false}|ForEach-Object{'• '+$_.name})
    $lines+='可指定的排程：'
    $lines+=@($cfg.schedules|ForEach-Object{'• '+$_.name})
    $lines+='用法：'
    $lines+='@日管 截圖 名稱（可填上方項目或排程名稱）'
    $lines+='一次多張：@日管 截圖 P14_D3、P58_D3'
    return ($lines -join "`n")
}
function New-E3ReceiverCaptureRequest([string]$label,$ids,$cfg,[string[]]$warnings=@()) {
    $pages=@()
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($id in $ids){
        if(-not $seen.Add([string]$id)){continue}
        $p=@($cfg.pages|Where-Object{$_.id -eq $id})
        if($p.Count -ne 1){$warnings+="頁面 $id 不存在或 ID 重複，未擷取。";continue}
        if($p[0].enabled -eq $false){$warnings+="$($p[0].name) 已停用，未擷取。";continue}
        if([string]$id -notmatch '^[A-Za-z0-9_-]+$'){$warnings+="$($p[0].name) 的頁面 ID 無效。";continue}
        $pages+=$p[0]
    }
    if(-not $pages.Count){return @{kind='help';text=(@('這次沒有可擷取的項目，想改截哪個呢？')+@($warnings)+@(Get-E3ReceiverCatalog $cfg) -join "`n")}}
    if($pages.Count -gt 20){return @{kind='help';text='一次最多擷取 20 個項目，請減少指定名稱或選擇較小的排程。'}}
    return @{kind='capture';label=$label;pages=$pages;warnings=@($warnings)}
}
function Split-E3ReceiverNames([string]$text,$cfg) {
    # Consume complete saved names first, so words such as 和平監控 and
    # names containing punctuation are not split internally, even in a list.
    $names=@(@($cfg.pages)+@($cfg.schedules)|ForEach-Object{([string]$_.name).Trim()}|Where-Object{$_}|Sort-Object Length -Descending|Select-Object -Unique)
    $patterns=@($names|ForEach-Object{
        $pattern=[regex]::Escape($_)
        if($_ -match '^[A-Za-z0-9_]'){$pattern='(?<![A-Za-z0-9_])'+$pattern}
        if($_ -match '[A-Za-z0-9_]$'){$pattern+='(?![A-Za-z0-9_])'}
        $pattern
    })
    $separator='(?<separator>以及|[、,，跟及和與])'
    $pattern=if($patterns.Count){'(?:'+($patterns -join '|')+')|'+$separator}else{$separator}
    $start=0
    foreach($match in [regex]::Matches($text,$pattern,[Text.RegularExpressions.RegexOptions]::IgnoreCase)){
        if(-not $match.Groups['separator'].Success){continue}
        $text.Substring($start,$match.Index-$start)
        $start=$match.Index+$match.Length
    }
    $text.Substring($start)
}
function Resolve-E3ReceiverRequest([string]$text,$cfg) {
    $text=$text.Replace([char]0x00A0,[char]0x20).Trim()
    # Literal typed prefix, not a Teams account mention. Require a space and command.
    if($text.Length -gt 400 -or $text -notmatch '^@日管 +(?=\S)'){return @{kind='ignore'}}
    $text=($text -replace '^@日管 +','').Trim()
    if($text -match '^狀態[。！!？?]?$'){return @{kind='status'}}
    if($text -match '^截圖清單[。！!？?]?$'){return @{kind='help';text=(Get-E3ReceiverCatalog $cfg)}}
    if($text -notmatch '截圖'){return @{kind='help';text=(@(
        '目前只支援查詢狀態與擷取已設定的圖表，你可以這樣問我：',
        '• 查詢狀態：@日管 狀態',
        '• 查看可截圖項目：@日管 截圖清單',
        '• 擷取單張：@日管 截圖 項目名稱',
        '• 擷取多張：@日管 截圖 名稱一跟名稱二',
        '• 擷取排程內的圖片：@日管 截圖 排程名稱',
        '不知道要填什麼名稱，可以先輸入 @日管 截圖清單。'
    ) -join "`n")}}
    $requested=$text.Substring($text.IndexOf('截圖')+2).Trim()
    # Preserve complete configured names. Separators select individual screenshots
    # in the user's order; a list does not expand schedules.
    $exact=@(@($cfg.pages)+@($cfg.schedules)|Where-Object{([string]$_.name).Trim() -ieq $requested})
    if(-not $exact.Count){
        $requested=($requested -replace '[、,，]\s*(?:謝謝|感謝)[。！!]?\s*$','').Trim()
        $parts=@(Split-E3ReceiverNames $requested $cfg)
        if($parts.Count -gt 1){
            $ids=@();$labels=@();$warnings=@()
            foreach($part in $parts){
                $name=($part.Trim() -replace '^頁面\s+','').Trim()
                if(-not $name){return @{kind='help';text=("清單中少了名稱，想截哪些項目呢？`n"+(Get-E3ReceiverCatalog $cfg))}}
                $matchesByName=@($cfg.pages|Where-Object{([string]$_.name).Trim() -ieq $name})
                if($matchesByName.Count -ne 1){
                    $warnings+= $(if($matchesByName.Count){"$name：名稱重複，未擷取，請先調整設定名稱。"}else{"$name：找不到此項目，未擷取；可用 @日管 截圖清單 查詢。"})
                    continue
                }
                $ids+=[string]$matchesByName[0].id
                $labels+=[string]$matchesByName[0].name
            }
            return New-E3ReceiverCaptureRequest ((@($labels|Select-Object -Unique)) -join '、') $ids $cfg $warnings
        }
    }
    $catalog=@($cfg.pages|ForEach-Object{@{kind='page';label='頁面';item=$_}})+@($cfg.schedules|ForEach-Object{@{kind='schedule';label='排程';item=$_}})
    $nameMatches=@()
    foreach($entry in $catalog){
        $name=([string]$entry.item.name).Trim();if(-not $name){continue}
        # Identifier boundaries prevent P14 from matching P14_D3 or XP14.
        $pattern=[regex]::Escape($name)
        if($name -match '^[A-Za-z0-9_]'){$pattern='(?<![A-Za-z0-9_])'+$pattern}
        if($name -match '[A-Za-z0-9_]$'){$pattern+='(?![A-Za-z0-9_])'}
        $hit=[regex]::Match($text,$pattern,[Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if($hit.Success){$nameMatches+=@{entry=$entry;start=$hit.Index;length=$hit.Length}}
    }
    # Prefer a complete longer name when another saved name is its substring.
    $hits=@($nameMatches|Where-Object{$a=$_;-not @($nameMatches|Where-Object{$_.length -gt $a.length -and $_.start -le $a.start -and ($_.start+$_.length) -ge ($a.start+$a.length)}).Count})
    if($hits.Count -gt 1){
        if($text -match '截圖\s*頁面\s+'){$hits=@($hits|Where-Object{$_.entry.kind -eq 'page'})}
        elseif($text -match '截圖\s*排程\s+'){$hits=@($hits|Where-Object{$_.entry.kind -eq 'schedule'})}
    }
    if($hits.Count -ne 1){
        $explanation=if($hits.Count){'符合多個名稱，你想截哪個呢？請指定以下其中一個：'+"`n"+(@($hits|ForEach-Object{$_.entry.label+' '+$_.entry.item.name}) -join "`n")}else{'想截哪個項目呢？請從下方清單選擇名稱。'+"`n"+(Get-E3ReceiverCatalog $cfg)}
        return @{kind='help';text=$explanation}
    }
    $selected=$hits[0].entry
    if($selected.kind -eq 'page'){$ids=@([string]$selected.item.id)}else{$ids=@($selected.item.pages)}
    return New-E3ReceiverCaptureRequest ([string]$selected.item.name) $ids $cfg
}
function Invoke-E3ReceiverCapture($request,[string]$key) {
    if($key -notmatch '^[a-f0-9]{64}$'){throw 'Invalid command key'}
    $job=Join-Path $script:E3CdpLogRoot ('captures\'+[DateTime]::Now.ToString('yyyy-MM-dd')+'\'+$key)
    [void][IO.Directory]::CreateDirectory($job)
    Save-E3CdpState (Join-Path $job 'request.json') @{pageIds=@($request.pages|ForEach-Object{$_.id})}
    # Only fixed program paths reach PowerShell; chat text is never executed.
    $engine=Join-Path $PSScriptRoot 'e3_monitor_native.ps1'
    $configFile=Join-Path $PSScriptRoot 'config.json'
    $command="& '"+$engine.Replace("'","''")+"' -ConfigPath '"+$configFile.Replace("'","''")+"' -ReceiverCaptureJob '"+$job.Replace("'","''")+"'"
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $proc=Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $job 'capture.log') -RedirectStandardError (Join-Path $job 'capture-error.log')
    try {
        # Child also has its own deadline, so a closed listener cannot leave a job running.
        if(-not $proc.WaitForExit(330000)){ $proc.Kill();$proc.WaitForExit();throw '擷取逾時，請稍後再下新指令。' }
        $resultPath=Join-Path $job 'result.json'
        if(-not (Test-Path -LiteralPath $resultPath)){throw '擷取沒有完成，請查看本機擷取紀錄。'}
        $result=Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8|ConvertFrom-Json
        $images=@();$captions=@();$warnings=@($request.warnings)
        foreach($page in $request.pages){
            $entry=@($result.pages|Where-Object{$_.id -ceq $page.id})
            $expected=Join-Path $job ($page.id+'.png')
            if($entry.Count -eq 1 -and $entry[0].ok -and [IO.File]::Exists($expected)){$images+=$expected;$captions+=(Get-E3ReceiverImageCaption $page)}
            else{$warnings+="$($page.name)：擷取失敗，請查看本機擷取紀錄或登入狀態。"}
        }
        $body=if($captions.Count){$captions -join "`n"}else{'這次沒抓到圖片。'}
        if($warnings.Count){$body+="`n"+($warnings -join "`n")}
        return @{images=$images;text=("✦ [日管]`n"+$body)}
    }finally{$proc.Dispose()}
}
function Get-E3ReceiverResponse($message,[string]$key,[scriptblock]$BeforeCapture) {
    $text=[string]$message.text
    $request=Resolve-E3ReceiverRequest $text (Get-E3ReceiverConfig)
    switch($request.kind){
        'status' {return @{images=@();text=(Get-E3ReceiverReply)}}
        'help' {return @{images=@();text=("✦ [日管]`n"+$request.text)}}
        'capture' {
            # Receipt failure here must escape: never capture or send another
            # response after an uncertain acknowledgement.
            if($BeforeCapture){& $BeforeCapture $request}
            try{return Invoke-E3ReceiverCapture $request $key}
            catch{return @{images=@();text="✦ [日管]`n$($request.label)：擷取未完成，請查看本機擷取紀錄後再下新指令。"}}
        }
        default {return $null}
    }
}
 