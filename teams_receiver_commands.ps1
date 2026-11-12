# Command interpretation and capture dispatch. Import does not capture or send.
function Get-E3ReceiverConfig {
    return Get-Content -LiteralPath (Join-Path $PSScriptRoot 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
}
function Format-E3ReceiverText([string]$text) {
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
    $verb=if($request.analyze){'檢查'}else{'截圖'}
    $parts=@('✦ [日管]',"收到！準備$verb $(@($request.pages).Count) 頁：")
    $parts+=@($request.pages|ForEach-Object{Get-E3ReceiverPageIntro $_})
    if(@($request.warnings).Count){$parts+=@($request.warnings)}
    # Say up front when a scheduled run (or another capture) holds the browser, so a long wait is expected.
    $owner=$null;try{$owner=Get-E3WorkOwner 'capture'}catch{}
    if($owner){$parts+="主機正在執行「$([string]$owner.description)」，要等它結束才會開始（最多等 3 分鐘）。"}
    $parts+=$(if($request.analyze){'完成後會回傳判定結果與標示圖。'}else{'完成後會把圖片傳回這個對話。'})
    return ($parts -join "`n")
}
function Get-E3ReceiverCatalog($cfg) {
    $lines=@('可以截圖或檢查的項目：')
    $lines+=@($cfg.pages|Where-Object{$_.enabled -ne $false}|ForEach-Object{
        $rules=@($_.rules|Where-Object{$_ -and $_.enabled -ne $false}).Count
        '• '+$_.name+$(if($rules){"（有 $rules 個監測項目）"}else{'（只截圖）'})
    })
    if(@($cfg.schedules).Count){
        $lines+='排程（會截它包含的全部頁面）：'
        $lines+=@($cfg.schedules|ForEach-Object{'• '+$_.name+"（$(@($_.pages).Count) 頁）"})
    }
    $lines+='用法：@日管 截圖 名稱、@日管 檢查 名稱；一次多個用頓號隔開，例如 @日管 截圖 P14_D3、P58_D3'
    return ($lines -join "`n")
}
function Get-E3ReceiverHelpText {
    return (@(
        '我可以幫你做這些事（前面都要加 @日管）：',
        '• 截圖：@日管 截圖 P14_D3（多張用頓號隔開，也可以填排程名稱）',
        '• 看數值、有沒有超標：@日管 檢查 P14_D3（不填名稱就檢查全部有監測的頁面）',
        '• 排程有沒有送：@日管 排程結果（可加排程名稱或「早上」「下午」）',
        '• 主機狀況：@日管 主機',
        '• 網站連得到嗎：@日管 連線 P14_D3（不填名稱就測全部）',
        '• 我自己的狀態：@日管 狀態',
        '• 上一個指令為什麼失敗：@日管 上一個指令',
        '• 有哪些名稱可以用：@日管 清單'
    ) -join "`n")
}
function Get-E3ReceiverEditDistance([string]$a,[string]$b) {
    $prev=[int[]](0..$b.Length)
    for($i=1;$i -le $a.Length;$i++){
        $cur=New-Object 'int[]' ($b.Length+1)
        $cur[0]=$i
        for($j=1;$j -le $b.Length;$j++){
            $cost=if($a[$i-1] -ceq $b[$j-1]){0}else{1}
            $cur[$j]=[Math]::Min([Math]::Min($prev[$j]+1,$cur[$j-1]+1),$prev[$j-1]+$cost)
        }
        $prev=$cur
    }
    return $prev[$b.Length]
}
function Get-E3ReceiverSuggestions([string]$word,$cfg,[int]$max=3) {
    # Names that look like what was typed (case, _ / - / spaces ignored, or one or two letters off).
    # Only offered as a suggestion; the user has to send the command again with the right name.
    $norm={param($s) (([string]$s).ToLowerInvariant() -replace '[\s_\-－—.·]','')}
    $w=& $norm $word
    if($w.Length -lt 2){return}
    $names=@(@($cfg.pages|Where-Object{$_.enabled -ne $false})+@($cfg.schedules)|ForEach-Object{([string]$_.name).Trim()}|Where-Object{$_}|Select-Object -Unique)
    $scored=foreach($name in $names){
        $n=& $norm $name
        if($n -ceq $w){@{name=$name;score=0};continue}
        if($w.Length -ge 3 -and ($n.Contains($w) -or $w.Contains($n))){@{name=$name;score=1};continue}
        # Same letters in another order (CSM for CMS).
        if($w.Length -ge 3 -and $w.Length -eq $n.Length -and (-join ($w.ToCharArray()|Sort-Object)) -ceq (-join ($n.ToCharArray()|Sort-Object))){@{name=$name;score=1};continue}
        $dist=Get-E3ReceiverEditDistance $w $n
        if($dist -le [Math]::Max(1,[Math]::Floor($w.Length/4))){@{name=$name;score=1+$dist}}
    }
    @($scored|Sort-Object {$_.score},{$_.name}|Select-Object -First $max|ForEach-Object{$_.name})
}
function Get-E3ReceiverUnknownWordText([string]$word,$cfg,[string]$verb='截圖') {
    $hint=@(Get-E3ReceiverSuggestions $word $cfg)
    if($hint.Count){return "找不到「$word」。你是不是要：$($hint -join '、')？例如 @日管 $verb $($hint[0])"}
    return "找不到「$word」。輸入 @日管 清單 可以看有哪些名稱。"
}
function New-E3ReceiverCaptureRequest([string]$label,$ids,$cfg,[string[]]$warnings=@(),[string]$kind='capture') {
    $verb=if($kind -eq 'connect'){'測試'}elseif($kind -eq 'check'){'檢查'}else{'擷取'}
    $pages=@()
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($id in $ids){
        if(-not $seen.Add([string]$id)){continue}
        $p=@($cfg.pages|Where-Object{$_.id -eq $id})
        if($p.Count -ne 1){$warnings+="頁面 $id 不存在或 ID 重複，未$verb。";continue}
        if($p[0].enabled -eq $false){$warnings+="$($p[0].name) 已停用，未$verb。";continue}
        if([string]$id -notmatch '^[A-Za-z0-9_-]+$'){$warnings+="$($p[0].name) 的頁面 ID 無效。";continue}
        $pages+=$p[0]
    }
    if(-not $pages.Count){return @{kind='help';text=(@("這次沒有可以$verb的項目，想改哪一個呢？")+@($warnings)+@(Get-E3ReceiverCatalog $cfg) -join "`n")}}
    if($pages.Count -gt 20){return @{kind='help';text="一次最多$verb 20 個項目，請減少指定名稱或選擇較小的排程。"}}
    return @{kind=$kind;label=$label;pages=$pages;warnings=@($warnings);analyze=($kind -eq 'check')}
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
function Find-E3ReceiverNameHits([string]$text,$cfg) {
    # Saved page / schedule names found in the text, longest complete name first.
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
    @($nameMatches|Where-Object{$a=$_;-not @($nameMatches|Where-Object{$_.length -gt $a.length -and $_.start -le $a.start -and ($_.start+$_.length) -ge ($a.start+$a.length)}).Count}|Sort-Object {$_.start})
}
function Get-E3ReceiverLooseWords([string]$text,$hits) {
    # Name-like words (letters / digits) that are not a saved name: probably a mistyped name.
    $masked=[Text.StringBuilder]::new($text)
    foreach($h in @($hits)){for($i=$h.start;$i -lt $h.start+$h.length;$i++){$masked[$i]=' '}}
    $common='^(?i:hi|hello|help|cpu|ram|ping|http|https|ok|okay|thanks|thx|d\d|\d+)$'
    @([regex]::Matches($masked.ToString(),'[A-Za-z0-9][A-Za-z0-9_\-]+')|ForEach-Object{$_.Value}|Where-Object{$_ -notmatch $common}|Select-Object -Unique)
}
function Resolve-E3ReceiverCaptureNames([string]$requested,[string]$whole,$cfg,[string]$kind) {
    # $requested: what follows the capture word. Keeps the original rules: a complete name wins,
    # a list with separators selects pages in order, one name otherwise.
    $verb=if($kind -eq 'check'){'檢查'}else{'截圖'}
    $requested=($requested -replace '^[\s:：]+','' -replace '[、,，。!！?？~～\s]*(?:謝謝|感謝|謝啦|thanks)?[。！!～~]*\s*$','').Trim()
    $exact=@(@($cfg.pages)+@($cfg.schedules)|Where-Object{([string]$_.name).Trim() -ieq $requested})
    if(-not $exact.Count){
        $parts=@(Split-E3ReceiverNames $requested $cfg)
        if($parts.Count -gt 1){
            $ids=@();$labels=@();$warnings=@()
            foreach($part in $parts){
                $name=($part.Trim() -replace '^頁面\s+','').Trim()
                if(-not $name){return @{kind='help';text=("清單中少了名稱，想${verb}哪些項目呢？`n"+(Get-E3ReceiverCatalog $cfg))}}
                $matchesByName=@($cfg.pages|Where-Object{([string]$_.name).Trim() -ieq $name})
                if($matchesByName.Count -ne 1){
                    $warnings+= $(if($matchesByName.Count){"$name：名稱重複，未$verb，請先調整設定名稱。"}else{(Get-E3ReceiverUnknownWordText $name $cfg $verb)+"（這一項未$verb）"})
                    continue
                }
                $ids+=[string]$matchesByName[0].id
                $labels+=[string]$matchesByName[0].name
            }
            return New-E3ReceiverCaptureRequest ((@($labels|Select-Object -Unique)) -join '、') $ids $cfg $warnings $kind
        }
    }
    $hits=@(Find-E3ReceiverNameHits $requested $cfg)
    # A name written before the capture word ("P14_D3 截圖").
    if(-not $hits.Count -and $whole){$hits=@(Find-E3ReceiverNameHits $whole $cfg);$requested=$whole}
    if($hits.Count -gt 1){
        if($requested -match '^\s*頁面\s+'){$hits=@($hits|Where-Object{$_.entry.kind -eq 'page'})}
        elseif($requested -match '^\s*排程\s+'){$hits=@($hits|Where-Object{$_.entry.kind -eq 'schedule'})}
    }
    if($hits.Count -ne 1){
        if($hits.Count){return @{kind='help';text=("符合多個名稱，你想${verb}哪個呢？請指定以下其中一個：`n"+(@($hits|ForEach-Object{$_.entry.label+' '+$_.entry.item.name}) -join "`n"))}}
        $loose=@(Get-E3ReceiverLooseWords $requested @())
        if($loose.Count){return @{kind='help';text=(@($loose|Select-Object -First 3|ForEach-Object{Get-E3ReceiverUnknownWordText $_ $cfg $verb}) -join "`n")}}
        return @{kind='help';text=("想${verb}哪個項目呢？請從下方清單選擇名稱。`n"+(Get-E3ReceiverCatalog $cfg))}
    }
    $selected=$hits[0].entry
    if($selected.kind -eq 'page'){$ids=@([string]$selected.item.id)}else{$ids=@($selected.item.pages)}
    return New-E3ReceiverCaptureRequest ([string]$selected.item.name) $ids $cfg @() $kind
}
function Resolve-E3ReceiverPageSet([string]$text,$cfg,[string]$kind) {
    # check / connect: every saved name mentioned (pages and schedules' pages). No name means all
    # pages (check: those with monitoring items). A name-like word that matches nothing is asked
    # about instead of silently widening the request to every page.
    $hits=@(Find-E3ReceiverNameHits $text $cfg)
    $loose=@(Get-E3ReceiverLooseWords $text $hits)
    if($loose.Count){
        $lines=@($loose|Select-Object -First 3|ForEach-Object{Get-E3ReceiverUnknownWordText $_ $cfg $(if($kind -eq 'connect'){'連線'}else{'檢查'})})
        return @{kind='help';text=($lines -join "`n")}
    }
    if($hits.Count){
        $ids=@();$labels=@()
        foreach($h in $hits){
            $labels+=[string]$h.entry.item.name
            if($h.entry.kind -eq 'page'){$ids+=[string]$h.entry.item.id}else{$ids+=@($h.entry.item.pages)}
        }
        return New-E3ReceiverCaptureRequest ((@($labels|Select-Object -Unique)) -join '、') $ids $cfg @() $kind
    }
    $all=@($cfg.pages|Where-Object{$_.enabled -ne $false})
    if($kind -eq 'check'){
        $all=@($all|Where-Object{@($_.rules|Where-Object{$_ -and $_.enabled -ne $false}).Count})
        if(-not $all.Count){return @{kind='help';text="目前沒有頁面設定監測項目，沒有東西可以檢查；想看圖可以用 @日管 截圖 名稱。`n"+(Get-E3ReceiverCatalog $cfg)}}
    }
    $request=New-E3ReceiverCaptureRequest $(if($kind -eq 'check'){'全部有監測的頁面'}else{'全部頁面'}) @($all|ForEach-Object{[string]$_.id}) $cfg @() $kind
    if($request.kind -eq $kind){$request.everything=$true}
    return $request
}
function Resolve-E3ReceiverScheduleFilter([string]$text,$cfg) {
    # Which schedules a "did it send" question is about: names, then words for a time of day.
    $hits=@(Find-E3ReceiverNameHits $text $cfg|Where-Object{$_.entry.kind -eq 'schedule'})
    $all=@($cfg.schedules)
    if($hits.Count){return @{schedules=@($hits|ForEach-Object{$_.entry.item});label=(@($hits|ForEach-Object{[string]$_.entry.item.name}) -join '、')}}
    $hourOf={param($s) $t=[TimeSpan]::Zero;if([TimeSpan]::TryParse([string]$s.time,[ref]$t)){$t.TotalHours}else{-1}}
    $range=$null;$label=''
    if($text -match '(\d{1,2})\s*[:：點時]\s*(\d{1,2})?'){$h=[int]$Matches[1];if($text -match '(下午|晚上)' -and $h -lt 12){$h+=12};$range=@($h,($h+1));$label="$h 點"}
    elseif($text -match '(早上|上午|早晨|一早)'){$range=@(0,12);$label='早上'}
    elseif($text -match '中午'){$range=@(11,14);$label='中午'}
    elseif($text -match '下午'){$range=@(12,18);$label='下午'}
    elseif($text -match '(晚上|傍晚|夜間)'){$range=@(17,24);$label='晚上'}
    if($range){
        $picked=@($all|Where-Object{$hr=& $hourOf $_;$hr -ge $range[0] -and $hr -lt $range[1]})
        return @{schedules=$picked;label=$label;timeOnly=$true}
    }
    return @{schedules=$all;label='全部排程'}
}
function Resolve-E3ReceiverRequest([string]$text,$cfg) {
    $text=$text.Replace([char]0x00A0,[char]0x20).Replace([char]0x3000,[char]0x20).Trim()
    # Literal typed prefix, not a Teams account mention. "@日管 狀態" and "@日管狀態" both work;
    # "@日管理員…" is not addressed to the bot, so without a space a known command word must follow.
    if($text.Length -gt 400 -or -not $text.StartsWith('@日管')){return @{kind='ignore'}}
    $rest=$text.Substring(3)
    $starts='(?i)^(?:狀態|截圖|抓圖|擷取|檢查|查|清單|列表|上一|上個|最近|指令|主機|電腦|伺服器|排程|連線|網站|說明|幫助|help|怎麼|在嗎|在不在|你好|嗨|哈囉|hi\b|hello|早安|幫我|請|麻煩|為什麼|有沒有|多少|可以)'
    if($rest -notmatch '^ ' -and $rest -notmatch $starts){return @{kind='ignore'}}
    $rest=$rest.Trim()
    if(-not $rest){return @{kind='ignore'}}
    # $q: the request without polite words around it, for recognizing what is being asked.
    $q=$rest
    do{$before=$q;$q=($q -replace '^(?:請問|請|麻煩你?|幫我|幫忙|可以|能不能|能否|想要|我想|我要)\s*','').Trim()}while($q -ne $before)
    do{$before=$q;$q=($q -replace '\s*(?:謝謝|感謝|謝啦|thanks|thx|喔|哦|啊|呢|吧|一下|[。！!？?～~，,、])$','').Trim()}while($q -ne $before)
    $qb=($q -replace '嗎$','').Trim()
    # Asked before the 截圖 test, so「為什麼截圖失敗」is a question about the last command, not a capture.
    if($q -match '^(上一個指令|上個指令|上一次指令|上一個|最近指令|最近的指令|指令紀錄)$' -or $q -match '為什麼.{0,6}(失敗|沒回|沒有回|沒反應|沒有反應|不回)'){return @{kind='history'}}
    if($qb -match '(?i)^(說明|幫助|help|怎麼用|用法|指令|指令列表|可以做什麼|你會什麼|你可以做什麼|你能做什麼|有什麼功能|功能)$'){return @{kind='help';text=(Get-E3ReceiverHelpText)}}
    if($qb -match '(?i)^(在|在不在|你好|您好|嗨|哈囉|hi|hello|早安|午安|晚安)$'){
        $up=''
        $started=[DateTimeOffset]::MinValue
        if($script:E3ReceiverStartedUtc -and [DateTimeOffset]::TryParse([string]$script:E3ReceiverStartedUtc,[ref]$started)){
            $span=[DateTimeOffset]::UtcNow-$started
            $up=if($span.TotalDays -ge 1){'（已連續執行 {0} 天 {1} 小時）' -f [int][Math]::Floor($span.TotalDays),$span.Hours}else{'（已連續執行 {0} 小時 {1} 分）' -f [int][Math]::Floor($span.TotalHours),$span.Minutes}
        }
        return @{kind='help';text=("我在！指令接收正常$up。`n"+(Get-E3ReceiverHelpText))}
    }
    if($qb -match '^(狀態|你的狀態|機器人狀態|接收端狀態|接收狀態|你還好|還活著|日管狀態)$'){return @{kind='status'}}
    if($qb -match '^(截圖清單|清單|列表|項目|名稱|名單|有哪些|有哪些項目|有哪些名稱|可以截哪些|可以截什麼|可以檢查哪些)$'){return @{kind='help';text=(Get-E3ReceiverCatalog $cfg)}}
    $captureWord='截圖|抓圖|擷取|截一?張|拍一?張|給我看'
    $checkWord='檢查|判定|多少|數值|超標|超過|門檻|最高|峰值|有沒有超|正常嗎|現在幾'
    # Host words win over check words ("主機正常嗎"), but not over a capture word.
    if($q -notmatch $captureWord -and -not @(Find-E3ReceiverNameHits $q $cfg).Count){
        if($q -match '^(主機|電腦|伺服器|機器)' -or $q -match '(主機|電腦|伺服器)的?(狀況|狀態|資訊|還好|正常|怎麼樣|如何|磁碟|硬碟|記憶體|空間)' -or $q -match '(?i)^(磁碟|硬碟|記憶體|cpu)'){return @{kind='host'}}
    }
    if($q -match $checkWord){
        # "截圖並檢查" is a check: it captures and judges.
        $named=($q -replace $captureWord,' ' -replace $checkWord,' ')
        return Resolve-E3ReceiverPageSet $named $cfg 'check'
    }
    $capture=[regex]::Match($q,$captureWord)
    if($capture.Success){
        $after=$q.Substring($capture.Index+$capture.Length)
        $before=$q.Substring(0,$capture.Index)
        return Resolve-E3ReceiverCaptureNames $after ($before+' '+$after) $cfg 'capture'
    }
    if($q -match '(?i)(連線|連得到|連不到|連不上|連的到|打得開|打不開|開得了|開不了|網站.{0,4}(正常|掛|開|通)|ping|通不通)'){
        return Resolve-E3ReceiverPageSet ($q -replace '(?i)連線測試|連線|連得到|連不到|連不上|連的到|打得開|打不開|開得了|開不了|網站|正常|ping|通不通|測試|有沒有|嗎',' ') $cfg 'connect'
    }
    if($q -match '(排程|有送|送了|送出|沒收到|收到了|有沒有送|發了|有發|寄了|傳了|定時|日報|結果)'){
        $filter=Resolve-E3ReceiverScheduleFilter $q $cfg
        return @{kind='schedule';schedules=@($filter.schedules);label=$filter.label;timeOnly=[bool]$filter.timeOnly}
    }
    # Only saved names: treat as a screenshot request ("@日管 P14_D3").
    $hits=@(Find-E3ReceiverNameHits $q $cfg)
    if($hits.Count){
        $rest2=$q
        foreach($h in @($hits|Sort-Object {$_.start} -Descending)){$rest2=$rest2.Remove($h.start,$h.length)}
        if(($rest2 -replace '以及|[、,，跟及和與\s]|頁面|排程','') -eq ''){return Resolve-E3ReceiverCaptureNames $q '' $cfg 'capture'}
    }
    $lines=@("這句我還看不懂：「$rest」")
    $loose=@(Get-E3ReceiverLooseWords $q $hits)
    foreach($word in @($loose|Select-Object -First 2)){$hint=@(Get-E3ReceiverSuggestions $word $cfg);if($hint.Count){$lines+="「$word」你是不是指：$($hint -join '、')？"}}
    $lines+=(Get-E3ReceiverHelpText)
    return @{kind='help';text=($lines -join "`n")}
}
function Invoke-E3ReceiverCapture($request,[string]$key) {
    if($key -notmatch '^[a-f0-9]{64}$'){throw 'Invalid command key'}
    $job=Join-Path $script:E3CdpLogRoot ('captures\'+[DateTime]::Now.ToString('yyyy-MM-dd')+'\'+$key)
    [void][IO.Directory]::CreateDirectory($job)
    Save-E3CdpState (Join-Path $job 'request.json') @{pageIds=@($request.pages|ForEach-Object{$_.id});analyze=[bool]$request.analyze}
    # Only fixed program paths reach PowerShell; chat text is never executed.
    $engine=Join-Path $PSScriptRoot 'e3_monitor_native.ps1'
    $configFile=Join-Path $PSScriptRoot 'config.json'
    $command="& '"+$engine.Replace("'","''")+"' -ConfigPath '"+$configFile.Replace("'","''")+"' -ReceiverCaptureJob '"+$job.Replace("'","''")+"'"
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $proc=Start-Process powershell.exe -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$encoded) -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $job 'capture.log') -RedirectStandardError (Join-Path $job 'capture-error.log')
    $timedOut=$false;$exitCode=$null
    try {
        # Child also has its own deadline, so a closed listener cannot leave a job running.
        if(-not $proc.WaitForExit(330000)){ $timedOut=$true;$proc.Kill();$proc.WaitForExit() }
        else{$exitCode=$proc.ExitCode}
    }finally{$proc.Dispose();$watch.Stop()}
    return ConvertTo-E3ReceiverCaptureReply $request $job $timedOut $exitCode $watch.Elapsed.TotalSeconds
}
function Format-E3ReceiverReason([string]$reason,[int]$max=220) {
    # One readable line for a phone: no internal prefixes, no line breaks, bounded length.
    $text=($reason -replace 'E3_RECEIVER_[A-Z]+：','' -replace 'CDP_[A-Z_]+：','' -replace '\s*[\r\n]+\s*','；').Trim()
    if(-not $text){return '沒有留下原因'}
    if($text.Length -gt $max){$text=$text.Substring(0,$max)+'…'}
    return $text
}
function Get-E3ReceiverCaptureFault([string]$job,[bool]$timedOut,$exitCode) {
    # The capture job ended without result.json. Say why as precisely as the evidence allows.
    if(Test-Path -LiteralPath (Join-Path $job 'deadline.json')){return '擷取超過 300 秒仍未完成，已中止（網站回應太慢，或一次指定太多頁）'}
    if($timedOut){return '擷取程式超過 330 秒沒有結束，已強制停止'}
    $detail=''
    try{
        $file=Join-Path $job 'capture-error.log'
        if((Test-Path -LiteralPath $file) -and (Get-Item -LiteralPath $file).Length -gt 0){
            # PowerShell writes errors of an encoded command as CLIXML in the console code page.
            $raw=[IO.File]::ReadAllText($file,[Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage))
            $detail=(($raw -replace '#< CLIXML','' -replace '<[^>]+>',' ' -replace '_x000D__x000A_',' ' -replace '\s+',' ').Trim())
        }
    }catch{$detail=''}
    $text='擷取程式沒有留下結果就結束了'+$(if($null -ne $exitCode){"（結束代碼 $exitCode）"}else{''})
    if($detail){$text+='：'+$detail}
    return $text
}
function Format-E3ReceiverNumber($value) {
    if($null -eq $value){return '?'}
    return ('{0:G4}' -f [double]$value)
}
function Format-E3ReceiverRuleLine($rule) {
    # One line per monitoring item, in plain words.
    $name=if([string]$rule.name){[string]$rule.name}else{'監測項目'}
    switch([string]$rule.status){
        'exceeded' {
            if($rule.mode -eq 'numeric'){return "🚨 ${name}：超標，最高值約 $(Format-E3ReceiverNumber $rule.maximum)，門檻 $(Format-E3ReceiverNumber $rule.threshold)"}
            return "🚨 ${name}：曲線越過警戒線（$([int]$rule.hits) 個點）"
        }
        'normal' {
            if($rule.mode -eq 'numeric'){
                if($null -eq $rule.maximum -and $null -ne $rule.below){return "✅ ${name}：正常，框內沒有曲線，最高值低於約 $(Format-E3ReceiverNumber $rule.below)，門檻 $(Format-E3ReceiverNumber $rule.threshold)"}
                return "✅ ${name}：正常，最高值約 $(Format-E3ReceiverNumber $rule.maximum)，門檻 $(Format-E3ReceiverNumber $rule.threshold)"
            }
            return "✅ ${name}：正常，沒有越過警戒線"
        }
        default {
            $why=@([string]$rule.reason,[string]$rule.detail|Where-Object{$_}) -join '；'
            return "⚠️ ${name}：無法判定。原因：$(Format-E3ReceiverReason $why 160)"
        }
    }
}
function ConvertTo-E3ReceiverCaptureReply($request,[string]$job,[bool]$timedOut=$false,$exitCode=$null,[double]$seconds=-1) {
    # Builds the reply from the capture job's own records. Every page that produced no image
    # carries its real reason, so the person on the phone does not need the host's logs.
    # A check request also lists every monitoring item with its value and verdict.
    $images=@();$captions=@();$problems=@();$notes=@($request.warnings);$lines=@()
    $counts=@{exceeded=0;normal=0;unknown=0}
    $result=$null;$fault=''
    $resultPath=Join-Path $job 'result.json'
    if(Test-Path -LiteralPath $resultPath){
        try{$result=Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8|ConvertFrom-Json}catch{$fault='擷取結果檔無法讀取：'+$_.Exception.Message}
    }elseif(-not $fault){$fault=Get-E3ReceiverCaptureFault $job $timedOut $exitCode}
    if($result -and [string]$result.error){
        $fault=[string]$result.error
        if($fault -match '等待已逾時'){$fault='排程或另一個擷取正在執行，等了 3 分鐘仍未輪到，這次沒有擷取'}
        elseif($fault -match '已取消本次等待|已選擇執行新工作'){$fault='主機上有人在設定頁取消了這次擷取'}
    }
    foreach($page in $request.pages){
        $entry=@(if($result){$result.pages|Where-Object{$_.id -ceq $page.id}})
        $expected=Join-Path $job ($page.id+'.png')
        if($entry.Count -eq 1 -and $entry[0].ok -and [IO.File]::Exists($expected)){
            if(-not $request.analyze){$images+=$expected;$captions+=(Get-E3ReceiverImageCaption $page);continue}
            $analysis=$entry[0].analysis
            $marked=if($analysis -and [string]$analysis.annotated -match '^annotated_[A-Za-z0-9_-]+\.png$'){Join-Path $job ([string]$analysis.annotated)}else{''}
            $images+=$(if($marked -and [IO.File]::Exists($marked) -and (Get-Item -LiteralPath $marked).Length -le 10MB){$marked}else{$expected})
            if(-not $analysis){$lines+="$($page.name)：有截到圖，但沒有判定結果";$counts.unknown++;$problems+="$($page.name)：沒有判定結果";continue}
            if([string]$analysis.error){
                $lines+="⚠️ $($page.name)：有截到圖，但判定時出錯。原因：$(Format-E3ReceiverReason ([string]$analysis.error) 160)"
                $counts.unknown++;$problems+="$($page.name)：判定時出錯";continue
            }
            if($analysis.captureOnly -eq $true -or -not @($analysis.rules).Count){$lines+="$($page.name)：沒有設定監測項目，只附截圖";continue}
            $lines+=[string]$page.name
            foreach($rule in @($analysis.rules)){
                $lines+=(Format-E3ReceiverRuleLine $rule)
                $state=[string]$rule.status;if($state -notin @('exceeded','normal')){$state='unknown'}
                $counts[$state]++
                if($state -eq 'unknown'){$problems+="$($page.name)／$($rule.name)：無法判定"}
            }
            continue
        }
        $why=if($entry.Count -eq 1 -and [string]$entry[0].error){[string]$entry[0].error}elseif($fault){$fault}elseif($entry.Count -eq 1 -and $entry[0].ok){'擷取程式回報成功，但找不到圖片檔'}else{'擷取程式沒有回報這一頁的結果'}
        $missing="$($page.name)：沒有截到。原因："+(Format-E3ReceiverReason $why)
        $problems+=$missing
        if($request.analyze){$lines+=('⚠️ '+$missing)}
    }
    $zone=[TimeZoneInfo]::FindSystemTimeZoneById('Taipei Standard Time')
    $when=[TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow,$zone).ToString('MM/dd HH:mm')+$(if($seconds -ge 0){"，花了 $([int][Math]::Round($seconds)) 秒"}else{''})
    if($request.analyze){
        $summary=@()
        if($counts.exceeded){$summary+="🚨 $($counts.exceeded) 項超標"}
        if($counts.unknown){$summary+="⚠️ $($counts.unknown) 項無法判定"}
        if($counts.normal){$summary+="✅ $($counts.normal) 項正常"}
        $head="檢查結果（$when）："+$(if($summary.Count){$summary -join '、'}else{'沒有可判定的項目'})
        $body=(@($head)+$lines) -join "`n"
        if($notes.Count){$body+="`n"+($notes -join "`n")}
        if($images.Count){$body+="`n圖上綠框是正常、紅框是超標，圓圈是讀到的最高點。"}
        $body+="`n這是即時檢查，只回覆這個對話，不會發給排程的收件對象。"
        if($problems.Count){$body+="`n沒有截到或無法判定的項目不會自動重做；排除原因後請再下一次指令。"}
        return @{images=$images;text=("✦ [日管]`n"+$body);problems=@($problems)}
    }
    $body=if($captions.Count){($captions -join "`n")+"`n擷取時間 $when"}else{"這次沒有截到圖片（$when）。"}
    if($problems.Count){$body+="`n"+($problems -join "`n")}
    if($notes.Count){$body+="`n"+($notes -join "`n")}
    if($problems.Count){$body+="`n沒有截到的項目不會自動重做；排除原因後請再下一次指令。"}
    return @{images=$images;text=("✦ [日管]`n"+$body);problems=@($problems)}
}function Get-E3ReceiverPhaseText([string]$phase) {
    # What the person may already have received when a command stopped at this point.
    switch($phase){
        'received' {'還沒開始回覆就失敗，這個指令沒有送出任何內容。'}
        'acknowledgement' {'傳送「已收到」通知時失敗：這則通知可能已送出，也可能沒有；截圖沒有執行。'}
        'capture' {'已回覆「已收到」，但截圖結果沒有送出。'}
        'result' {'回傳結果時失敗：結果可能已送出一部分或全部，也可能沒有，請先看一下這個對話。'}
        default {'處理到一半被中斷：回覆可能已送出一部分，也可能完全沒有，請先看一下這個對話。'}
    }
}
function Format-E3ReceiverCommandLabel($info) {
    # "11/12 10:32「截圖 P14_D3」" in Taiwan time, from the message's own timestamp.
    $command=(([string]$info.command) -replace '^@日管\s+','' -replace '\s+',' ').Trim()
    if($command.Length -gt 40){$command=$command.Substring(0,40)+'…'}
    $when=''
    $time=[DateTimeOffset]::MinValue
    $stamp=if([string]$info.messageTime){[string]$info.messageTime}else{[string]$info.at}
    if($stamp -and [DateTimeOffset]::TryParse($stamp,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal,[ref]$time)){
        $when=[TimeZoneInfo]::ConvertTimeFromUtc($time.UtcDateTime,[TimeZoneInfo]::FindSystemTimeZoneById('Taipei Standard Time')).ToString('MM/dd HH:mm')
    }
    return ($when+'「'+$command+'」')
}
function New-E3ReceiverFailureText($info,[string]$phase,[string]$reason) {
    # A separate plain-text explanation. It never repeats the failed reply or its pictures.
    return (@('✦ [日管]',
        ((Format-E3ReceiverCommandLabel $info)+'這個指令沒有完成。'),
        (Get-E3ReceiverPhaseText $phase),
        ('原因：'+(Format-E3ReceiverReason $reason 300)),
        '不會自動重做；確認後需要的話請再下一次指令。') -join "`n")
}
function Get-E3ReceiverHistoryReply([string]$route,[string]$currentKey='') {
    # Recent commands of this chat only, newest first, with what happened to each.
    $lines=@()
    $folder=Join-Path $script:E3CdpLogRoot 'commands'
    $files=@(if([IO.Directory]::Exists($folder)){Get-ChildItem -LiteralPath $folder -Filter '*.json' -File -ErrorAction SilentlyContinue|Sort-Object LastWriteTimeUtc -Descending})
    foreach($file in $files){
        if($lines.Count -ge 5){break}
        if($currentKey -and $file.BaseName -ceq $currentKey){continue}
        $c=$null;try{$c=Read-E3WorkJson $file.FullName}catch{continue}
        if(-not $c -or [string]$c.route -cne $route){continue}
        $outcome=switch([string]$c.state){
            'replied' {$bad=@($c.problems|Where-Object{$_});if($bad.Count){"已回覆，但有 $($bad.Count) 項沒有截到：`n"+(@($bad|Select-Object -First 3) -join "`n")}else{'已回覆'}}
            'not_retried' {'沒有完成。'+(Get-E3ReceiverPhaseText ([string]$c.phase))+$(if([string]$c.error){"`n原因："+(Format-E3ReceiverReason ([string]$c.error) 300)}else{''})}
            'interrupted' {'處理到一半時接收端被中斷（視窗被關閉、程式結束或主機重新開機），結果不明。'}
            default {'還在處理，或處理到一半時接收端被中斷，結果不明。'}
        }
        $lines+=('• '+(Format-E3ReceiverCommandLabel $c)+'：'+$outcome)
    }
    if(-not $lines.Count){return "✦ [日管]`n這個對話目前沒有先前的指令紀錄（紀錄保留 30 天）。"}
    return ("✦ [日管]`n這個對話最近的指令（新的在前）：`n"+($lines -join "`n")+"`n失敗或結果不明的指令不會自動重做。")
}
function Get-E3ReceiverResponse($message,[string]$key,[scriptblock]$BeforeCapture,[string]$route='') {
    $text=[string]$message.text
    $request=Resolve-E3ReceiverRequest $text (Get-E3ReceiverConfig)
    switch($request.kind){
        'status' {return @{images=@();text=(Get-E3ReceiverReply $route);problems=@()}}
        'history' {return @{images=@();text=(Get-E3ReceiverHistoryReply $route $key);problems=@()}}
        'help' {return @{images=@();text=("✦ [日管]`n"+$request.text);problems=@()}}
        {$_ -in @('capture','check')} {
            # Receipt failure here must escape: never capture or send another
            # response after an uncertain acknowledgement.
            if($BeforeCapture){& $BeforeCapture $request}
            try{return Invoke-E3ReceiverCapture $request $key}
            catch{
                $why=Format-E3ReceiverReason $_.Exception.Message
                $verb=if($request.analyze){'檢查'}else{'擷取'}
                return @{images=@();text="✦ [日管]`n$($request.label)：${verb}沒有完成。`n原因：$why`n不會自動重做；排除原因後請再下一次指令。";problems=@("$($request.label)：$why")}
            }
        }
        # Read-only questions answered on the host (teams_receiver_queries.ps1). A failure of the
        # lookup itself is answered with its reason instead of leaving the question unanswered.
        {$_ -in @('host','connect','schedule')} {
            $label=switch($request.kind){'host'{'主機狀況'}'connect'{'網站連線'}default{'排程結果'}}
            try{
                $text=switch($request.kind){
                    'host' {Get-E3ReceiverHostReply}
                    'connect' {Get-E3ReceiverConnectReply $request}
                    'schedule' {Get-E3ReceiverScheduleReport $request}
                }
                return @{images=@();text=[string]$text;problems=@()}
            }catch{
                $why=Format-E3ReceiverReason $_.Exception.Message
                return @{images=@();text="✦ [日管]`n${label}查詢沒有完成。`n原因：$why";problems=@("${label}：$why")}
            }
        }
        default {return $null}
    }
}
 