# Local-only numeric chart monitoring. Coordinates refer to the final cropped PNG.
function Wait-E3OcrOperation($operation, [type]$resultType) {
    $method = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.IsGenericMethodDefinition -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
    } | Select-Object -First 1
    $task = $method.MakeGenericMethod($resultType).Invoke($null, @($operation))
    if (-not $task.Wait(15000)) { throw 'Windows 刻度辨識逾時，請縮小刻度框後重試' }
    return $task.Result
}



function Select-E3OcrEngine($languages, [scriptblock]$factory) {
    # Keep the verified English path when installed; otherwise use an installed recognizer.
    # Never infer OCR availability from the Windows display language.
    $available=@($languages | Where-Object { $_ -and $_.LanguageTag } | Sort-Object @{
        Expression={if($_.LanguageTag -eq 'en-US'){0}elseif($_.LanguageTag -like 'en-*'){1}elseif($_.LanguageTag -like 'zh-*'){2}else{3}}
    }, LanguageTag)
    if(-not $available.Count){throw '此電腦尚未安裝 Windows 文字辨識引擎；純數字圖片也需要辨識引擎。請在 Windows 語言設定加入文字辨識功能，不限英文'}
    foreach($language in $available){
        try {
            $engine=& $factory $language
            if($null -ne $engine){return $engine}
        } catch { Write-Verbose "無法載入 OCR 語言：$($language.LanguageTag)" }
    }
    throw ('已安裝的 Windows 文字辨識引擎無法啟動（'+($available.LanguageTag -join '、')+'）；請檢查 Windows 語言的文字辨識功能')
}



function Get-E3OcrEngine {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType=WindowsRuntime] | Out-Null
    return Select-E3OcrEngine ([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages) {
        param($language)
        [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($language)
    }
}



function Get-E3OcrContext([string]$languageTag) {
    if($languageTag -match '^zh-(Hans|CN|SG)($|-)'){return @{prefix='数值';suffix='单位';font='Microsoft YaHei'}}
    if($languageTag -like 'zh-*'){return @{prefix='數值';suffix='單位';font='Microsoft JhengHei'}}
    return @{prefix='Value';suffix='units';font='Arial'}
}



function Read-E3OcrContext([string]$text, $context) {
    $prefix=[regex]::Escape($context.prefix);$suffix=[regex]::Escape($context.suffix)
    if($text -match ('^('+$prefix+')?('+$suffix+')?$')){return $null}
    if($text -notmatch ('^'+$prefix+'(.+)'+$suffix+'$')){throw '刻度文字辨識不完整，請重新框選清晰的數字'}
    return $Matches[1]
}



function Get-E3AxisWords($bitmap, $roi, [int]$scale, [switch]$NoBinarize) {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType=WindowsRuntime] | Out-Null
    [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType=WindowsRuntime] | Out-Null
    [Windows.Storage.Streams.InMemoryRandomAccessStream, Windows.Foundation, ContentType=WindowsRuntime] | Out-Null
    [Windows.Storage.Streams.DataWriter, Windows.Foundation, ContentType=WindowsRuntime] | Out-Null
    $engine = Get-E3OcrEngine
    $context = Get-E3OcrContext $engine.RecognizerLanguage.LanguageTag
    Write-Verbose "使用 Windows OCR：$($engine.RecognizerLanguage.LanguageTag)"
    $scaled=$null; $g=$null; $memory=$null; $stream=$null; $writer=$null; $software=$null
    try {
        # OCR drops isolated one-digit lines. Segment label ink, then arrange labels in a padded sheet.
        $bands=@();$start=-1;$last=-1
        for($row=0;$row -lt $roi.h;$row++) {
            $ink=$false
            for($col=0;$col -lt $roi.w;$col++) {
                $c=$bitmap.GetPixel(($roi.x+$col),($roi.y+$row))
                if ([Math]::Max($c.R,[Math]::Max($c.G,$c.B)) -lt 190 -and ([Math]::Max($c.R,[Math]::Max($c.G,$c.B))-[Math]::Min($c.R,[Math]::Min($c.G,$c.B))) -lt 65) {$ink=$true;break}
            }
            if($ink){if($start -lt 0){$start=$row};$last=$row}
            if($start -ge 0 -and (($row-$last -ge 2) -or $row -eq $roi.h-1)) {
                if($last-$start -ge 3){$bands+=@{top=$start;h=($last-$start+1);y=($roi.y+($start+$last)/2)}}
                $start=-1
            }
        }
        if($bands.Count -lt 3 -or $bands.Count -gt 40){throw '請框選至少三個左側刻度數字，不要包含軸線或標題'}
        $inkLeft=[int]$roi.w;$inkRight=0
        foreach($band in $bands){$band.left=[int]$roi.w;$band.right=0;for($row=$band.top;$row -lt $band.top+$band.h;$row++){for($col=0;$col -lt $roi.w;$col++){
            $c=$bitmap.GetPixel(($roi.x+$col),($roi.y+$row))
            if([Math]::Max($c.R,[Math]::Max($c.G,$c.B)) -lt 190){$inkLeft=[Math]::Min($inkLeft,$col);$inkRight=[Math]::Max($inkRight,$col);$band.left=[Math]::Min($band.left,$col);$band.right=[Math]::Max($band.right,$col)}
        }}}
        $inkWidth=$inkRight-$inkLeft+1
        $maxInkHeight=[int](($bands.h|Measure-Object -Maximum).Maximum)
        $prefixSpace=[int][Math]::Ceiling($maxInkHeight*$scale*4.4)
        $cellW=$inkWidth*$scale+$prefixSpace+[int][Math]::Ceiling($maxInkHeight*$scale*3.8)+50
        $cellH=$maxInkHeight*$scale+40
        $columns=1
        $scaled=[Drawing.Bitmap]::new(($cellW*$columns),([int][Math]::Ceiling($bands.Count/$columns)*$cellH))
        if ($scaled.Width -gt [Windows.Media.Ocr.OcrEngine]::MaxImageDimension -or $scaled.Height -gt [Windows.Media.Ocr.OcrEngine]::MaxImageDimension) { throw '刻度框超過辨識尺寸，請縮小範圍並只框刻度數字' }
        $g=[Drawing.Graphics]::FromImage($scaled); $g.Clear([Drawing.Color]::White)
        $g.InterpolationMode=[Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        for($index=0;$index -lt $bands.Count;$index++) {
            $band=$bands[$index];$cx=($index%$columns)*$cellW+$prefixSpace+20;$cy=[Math]::Floor($index/$columns)*$cellH+20
            # A known prefix gives isolated digits OCR context. It must be read back exactly.
            $prefixFont=[Drawing.Font]::new($context.font,([single]($band.h*$scale*1.3)),[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
            try {$g.DrawString($context.prefix,$prefixFont,[Drawing.Brushes]::Black,([single]($cx-$band.h*$scale*3.8)),([single]($cy-$band.h*$scale*0.2)));
                $g.DrawString($context.suffix,$prefixFont,[Drawing.Brushes]::Black,([single]($cx+($band.right-$band.left+1)*$scale+10)),([single]($cy-$band.h*$scale*0.2)))
            }finally{$prefixFont.Dispose()}
            $g.DrawImage($bitmap,[Drawing.Rectangle]::new($cx,$cy,(($band.right-$band.left+1)*$scale),($band.h*$scale)),[Drawing.Rectangle]::new(($roi.x+$band.left),($roi.y+$band.top),($band.right-$band.left+1),$band.h),[Drawing.GraphicsUnit]::Pixel)
        }
        $g.Dispose();$g=$null
        Initialize-E3NumericPixels
        if(-not $NoBinarize){[E3NumericPixels]::Binarize($scaled)}
        $memory=[IO.MemoryStream]::new(); $scaled.Save($memory,[Drawing.Imaging.ImageFormat]::Png)
        $stream=[Windows.Storage.Streams.InMemoryRandomAccessStream]::new()
        $writer=[Windows.Storage.Streams.DataWriter]::new($stream)
        $writer.WriteBytes($memory.ToArray())
        Wait-E3OcrOperation $writer.StoreAsync() ([uint32]) | Out-Null
        $writer.DetachStream() | Out-Null; $stream.Seek(0)
        $decoder=Wait-E3OcrOperation ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $software=Wait-E3OcrOperation ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        $result=Wait-E3OcrOperation ($engine.RecognizeAsync($software)) ([Windows.Media.Ocr.OcrResult])
        Write-Verbose "OCR scale $scale`: $($result.Text)"
        if ($result.TextAngle -and [Math]::Abs([double]$result.TextAngle) -gt 2) { throw '不支援旋轉的刻度數字' }
        $recognized=@{}
        foreach ($line in $result.Lines) { foreach($word in $line.Words) {
            $rect=$word.BoundingRect;$column=[int][Math]::Floor(($rect.X+$rect.Width/2)/$cellW);$row=[int][Math]::Floor(($rect.Y+$rect.Height/2)/$cellH)
            $index=$row*$columns+$column
            if($rect.Width -ge $cellW -or $index -ge $bands.Count){throw '刻度數字辨識位置不明確，請重新框選'}
            if(-not $recognized.ContainsKey($index)){$recognized[$index]=@()}
            $recognized[$index]+=[pscustomobject]@{x=$rect.X;text=$word.Text}
        }}
        for($index=0;$index -lt $bands.Count;$index++) {
            if(-not $recognized.ContainsKey($index)){continue}
            $text=(@($recognized[$index]|Sort-Object x).text -join '')
            $label=Read-E3OcrContext $text $context
            if($null -eq $label){continue}
            [pscustomobject]@{text=$label;y=$bands[$index].y}
        }
    } finally {
        foreach ($resource in @($software,$writer,$stream,$memory,$g,$scaled)) { if ($resource -is [IDisposable]) { $resource.Dispose() } }
    }
}



function Get-E3AxisFit($words, [switch]$AllowInteriorOutliers) {
    $ticks=@()
    foreach ($word in $words) {
        $text=([string]$word.text).Trim().Replace([char]0x2212,'-').Replace('O','0').Replace('o','0').Replace('l','1').Replace('I','1').Replace('i','1')
        # Unreadable labels supply no calibration point. Never extrapolate beyond the readable ticks.
        if ($text -notmatch '^(-?(?:\d+|\d{1,3}(?:,\d{3})+)(?:\.\d+)?)\s*([kKMGT%]?)$') { continue }
        $value=[double]::Parse($Matches[1].Replace(',',''),[Globalization.CultureInfo]::InvariantCulture)
        $unit=$Matches[2]; $factor=switch -CaseSensitive ($unit) { 'k' {1e3} 'K' {1e3} 'M' {1e6} 'G' {1e9} 'T' {1e12} default {1} }
        $ticks += [pscustomobject]@{value=($value*$factor);y=[double]$word.y;text=$text;percent=($unit -eq '%')}
    }
    $ticks=@($ticks | Sort-Object y)
    if ($ticks.Count -lt 3) { throw '至少需要三個可辨識的 Y 軸刻度' }
    if (@($ticks | Where-Object percent).Count -notin @(0,$ticks.Count)) { throw '刻度單位不一致' }
    if($AllowInteriorOutliers){
        # Anchor the image's own endpoints. Middle labels corroborate the scale;
        # a small number of OCR errors must not invalidate otherwise clear bounds.
        # Never discard an endpoint, invent a missing bound, or assume a maximum of 35.
        $top=$ticks[0];$bottom=$ticks[-1]
        if($ticks.Count -lt 6 -or $bottom.y-$top.y -lt 20 -or $top.value -le $bottom.value){throw '上下界與可讀刻度不足，無法交叉確認左軸比例'}
        $slope=($bottom.value-$top.value)/($bottom.y-$top.y)
        $good=@();$ignored=@()
        foreach($tick in $ticks){
            $distance=[Math]::Abs(($tick.value-$top.value)/$slope+$top.y-$tick.y)
            if($distance -le 1.5){$good+=$tick}else{$ignored+=$tick}
        }
        if($good.Count -lt [Math]::Ceiling($ticks.Count*0.75)){throw '中間刻度與上下界比例不一致，無法可靠換算藍線高度'}
        $fit=Get-E3AxisFit @($good|ForEach-Object{[pscustomobject]@{text=$_.text;y=$_.y}})
        $fit.ignored_ticks=$ignored
        return $fit
    }
    for ($i=1;$i -lt $ticks.Count;$i++) {
        if ($ticks[$i].y-$ticks[$i-1].y -lt 4 -or $ticks[$i].value -ge $ticks[$i-1].value) { throw ('OCR 讀到的刻度順序不一致（由上到下：'+($ticks.text -join '、')+'）') }
    }
    $meanY=($ticks.y|Measure-Object -Average).Average; $meanV=($ticks.value|Measure-Object -Average).Average
    $num=0.0; $den=0.0
    foreach ($tick in $ticks) { $num+=($tick.y-$meanY)*($tick.value-$meanV); $den+=[Math]::Pow($tick.y-$meanY,2) }
    $slope=$num/$den; $intercept=$meanV-$slope*$meanY; $error=0.0
    foreach ($tick in $ticks) { $error=[Math]::Max($error,[Math]::Abs(($tick.value-$intercept)/$slope-$tick.y)) }
    if ($error -gt 1.5) { throw '刻度與位置不符合線性比例；可能辨識錯誤或使用對數刻度' }
    return @{slope=$slope;intercept=$intercept;error=$error;ticks=$ticks;min=$ticks[-1].value;max=$ticks[0].value;top=$ticks[0].y;bottom=$ticks[-1].y}
}



function Initialize-E3NumericPixels {
    if ('E3NumericPixels' -as [type]) { return }
    Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
public static class E3NumericPixels {
    public static void Binarize(Bitmap b) {
        for(int y=0;y<b.Height;y++)for(int x=0;x<b.Width;x++) {
            Color c=b.GetPixel(x,y); b.SetPixel(x,y,c.R+c.G+c.B<540?Color.Black:Color.White);
        }
    }
    public static int[] Peak(Bitmap image, int x, int y, int w, int h, Color target, double tolerance) {
        bool[] mask=new bool[w*h]; int count=0;
        for(int j=0;j<h;j++) for(int i=0;i<w;i++) {
            Color c=image.GetPixel(x+i,y+j);
            double dr=c.R-target.R,dg=c.G-target.G,db=c.B-target.B;
            if(c.B-c.R>=15 && c.B-c.G>=15 && dr*dr+dg*dg+db*db<=tolerance*tolerance) {mask[j*w+i]=true;count++;}
        }
        // Require a connected component of at least three pixels. Preserve one-pixel-wide peaks.
        bool[] seen=new bool[mask.Length]; int[] queue=new int[mask.Length]; int bestY=int.MaxValue,bestX=0;
        for(int p=0;p<mask.Length;p++) {
            if(!mask[p]||seen[p]) continue;
            int head=0,tail=1,minY=p/w,minX=p%w; queue[0]=p;seen[p]=true;
            while(head<tail) {
                int a=queue[head++], ax=a%w,ay=a/w;
                if(ay<minY){minY=ay;minX=ax;}
                for(int dy=-1;dy<=1;dy++) for(int dx=-1;dx<=1;dx++) {
                    int nx=ax+dx,ny=ay+dy;
                    if(nx<0||nx>=w||ny<0||ny>=h)continue;
                    int n=ny*w+nx;if(mask[n]&&!seen[n]){seen[n]=true;queue[tail++]=n;}
                }
            }
            if(tail>=3 && minY<bestY){bestY=minY;bestX=minX;}
        }
        return bestY==int.MaxValue ? null : new int[]{x+bestX,y+bestY,count};
    }
}
'@
}



function Test-E3NumericRegion($roi, $bitmap) {
    if (-not $roi) { return $false }
    foreach ($key in @('x','y','w','h')) {
        $n=$roi.$key
        if ($null -eq $n -or $n -is [string] -or $n -is [bool] -or [double]::IsNaN([double]$n) -or [double]::IsInfinity([double]$n) -or [double]$n -ne [Math]::Floor([double]$n)) { return $false }
    }
    return ($roi.x -ge 0 -and $roi.y -ge 0 -and $roi.w -ge 3 -and $roi.h -ge 3 -and $roi.x+$roi.w -le $bitmap.Width -and $roi.y+$roi.h -le $bitmap.Height)
}



function Get-E3VerifiedAxisFit($bitmap,$roi) {
    $fits=@();$readings=@();$errors=@()
    foreach($attempt in @(@{scale=4;raw=$false},@{scale=6;raw=$false},@{scale=4;raw=$true},@{scale=6;raw=$true})){
        try{
            $words=@(Get-E3AxisWords $bitmap $roi $attempt.scale -NoBinarize:$attempt.raw)
            $readings+= (($words|Sort-Object y|ForEach-Object{$_.text}) -join '、')
            try{$fits+=Get-E3AxisFit $words}
            catch{$fits+=Get-E3AxisFit $words -AllowInteriorOutliers}
        }catch{$errors+=$_.Exception.Message}
        if($fits.Count -ge 2){
            $fit=$fits[0];$check=$fits[1]
            foreach($y in @($roi.y,($roi.y+$roi.h))){
                if([Math]::Abs((($fit.intercept+$fit.slope*$y)-($check.intercept+$check.slope*$y))/$fit.slope) -gt 1.5){throw ("兩次左軸比例無法互相確認（刻度 $($fit.min)～$($fit.max)／$($check.min)～$($check.max)）；請確認刻度框包含完整的左軸數字。")}
            }
            $combined=@($fit.ticks|ForEach-Object{[pscustomobject]@{text=$_.text;y=$_.y}})
            foreach($tick in $check.ticks){
                $same=@($fit.ticks|Where-Object{[Math]::Abs($_.y-$tick.y) -lt 1.5})
                if($same.Count -and $same[0].value -ne $tick.value){throw ('兩次刻度辨識結果不一致：'+($readings -join '／'))}
                if(-not $same.Count){$combined += [pscustomobject]@{text=$tick.text;y=$tick.y}}
            }
            $verified=Get-E3AxisFit $combined
            $verified.ignored_ticks=@(@($fit.ignored_ticks)+@($check.ignored_ticks)|Where-Object{$_})
            return $verified
        }
    }
    $details=@($readings|Where-Object{$_}|Select-Object -Unique) -join '／'
    if($details){throw ('無法確認左側 Y 軸：'+$errors[-1]+'。請確認刻度框包含完整的上下界及中間數字，未混入時間或右側刻度。')}
    throw ('刻度重試後仍無法辨識：'+(@($errors|Select-Object -Unique) -join '；'))
}
function Measure-E3NumericRule($bitmap, $rule) {
    try {
        if (-not (Test-E3NumericRegion $rule.roi $bitmap) -or -not (Test-E3NumericRegion $rule.axis_roi $bitmap)) { throw '請在擷取圖片內框選有效的監測範圍及左側刻度範圍' }
        if ($rule.axis_roi.w -gt 250 -or [long]$rule.axis_roi.w*$rule.axis_roi.h -gt 250000) { throw '刻度框太大，請縮小到左側刻度數字' }
        if ($rule.axis_roi.x+$rule.axis_roi.w -gt $rule.roi.x) { throw '刻度數字框應位於監測範圍左側' }
        if ($null -eq $rule.value_threshold -or $rule.value_threshold -is [string] -or $rule.value_threshold -is [bool] -or [double]::IsNaN([double]$rule.value_threshold) -or [double]::IsInfinity([double]$rule.value_threshold)) { throw '請填入有效的數值門檻' }
        if ($rule.color_mode -ne 'custom' -or $rule.target_color -notmatch '^#[0-9a-fA-F]{6}$') { throw '請用取色工具指定藍色曲線' }
        $target=[Drawing.ColorTranslator]::FromHtml($rule.target_color)
        if ($target.B-[Math]::Max($target.R,$target.G) -lt 30) { throw '請選取清晰的藍色曲線，避免背景或綠線' }
        $tol=if ($null -ne $rule.color_tolerance) {[double]$rule.color_tolerance} else {48.0}
        if ($tol -lt 10 -or $tol -gt 120 -or [double]::IsNaN($tol)) { throw '顏色容許誤差需介於 10～120' }
        $fit=Get-E3VerifiedAxisFit $bitmap $rule.axis_roi
        Initialize-E3NumericPixels
        $r=$rule.roi
        $peak=[E3NumericPixels]::Peak($bitmap,$r.x,$r.y,$r.w,$r.h,$target,$tol)
        if ($null -eq $peak) { throw '監測範圍內找不到可可靠辨識的藍色曲線' }
        if ($peak[1] -le $r.y -or $peak[1] -lt $fit.top-1.5 -or $peak[1] -gt $fit.bottom+1.5) { throw '藍色峰頂被框選範圍裁切，或超出已辨識刻度範圍' }
        $maximum=$fit.intercept+$fit.slope*$peak[1]
        $uncertainty=[Math]::Abs($fit.slope)*([Math]::Max(1.5,$fit.error+1))
        $threshold=[double]$rule.value_threshold
        $detail=('最高值約 {0:G5}／門檻 {1:G5}；刻度 {2:G5}～{3:G5}；誤差約 ±{4:G3}' -f $maximum,$threshold,$fit.min,$fit.max,$uncertainty)
        $uncertain=[Math]::Abs($maximum-$threshold) -le $uncertainty
        return @{status=$(if($uncertain){'unknown'}elseif($maximum -gt $threshold){'exceeded'}else{'normal'});exceeded=(-not $uncertain -and $maximum -gt $threshold);unknown=$uncertain;maximum=$maximum;threshold=$threshold;axis_min=$fit.min;axis_max=$fit.max;uncertainty=$uncertainty;peak_x=$peak[0];peak_y=$peak[1];threshold_y=(($threshold-$fit.intercept)/$fit.slope);ticks=@($fit.ticks);detail=$detail;reason=$(if($uncertain){'峰值接近門檻，落在圖片辨識誤差範圍內'}else{''})}
    } catch {
        return @{status='unknown';exceeded=$false;unknown=$true;reason=$_.Exception.Message;detail=''}
    }
}
 
 