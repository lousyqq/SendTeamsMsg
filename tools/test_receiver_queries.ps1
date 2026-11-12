# Isolated tests of the friendlier commands and the read-only questions: wording, name
# suggestions, check replies, schedule results, host status, site reachability, and the shared
# page judgment (Invoke-E3PageAnalysis) on generated pictures. Stand-in config, files in a
# temporary folder, a loopback web server for the site test. No Teams, Edge, capture, send,
# Windows task change or connection outside this computer.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$fixture=Join-Path $env:TEMP ('E3ReceiverQueries_'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
. (Join-Path $root 'teams_receiver.ps1') -LibraryOnly
$script:E3CdpLogRoot=Join-Path $fixture 'logs\teams_receiver'
$script:E3WorkControlRoot=Join-Path $fixture 'work'
$script:E3ReceiverQueryLogRoot=Join-Path $fixture 'logs'
$passed=0
function Check([bool]$ok,[string]$name){if(-not $ok){throw "FAIL $name"};$script:passed++;Write-Host "PASS $name"}
$rules=@([pscustomobject]@{name='CPU';enabled=$true;measure_mode='numeric'})
$cfg=[pscustomobject]@{
    pages=@([pscustomobject]@{id='p14d3';name='P14_D3';enabled=$true;url='http://a.invalid/charts.php';rules=$rules},
            [pscustomobject]@{id='p14d7';name='P14_D7';enabled=$true;url='http://a.invalid/charts.php';rules=@()},
            [pscustomobject]@{id='cms';name='CMS';enabled=$true;url='http://b.invalid/report.aspx';rules=@()},
            [pscustomobject]@{id='old';name='OLD';enabled=$false;url='http://c.invalid/';rules=$rules})
    schedules=@([pscustomobject]@{id='morning';name='MSD日管Index';time='08:00';enabled=$true;pages=@('p14d7','cms')},
                [pscustomobject]@{id='evening';name='Night';time='19:30';enabled=$true;pages=@('p14d3')})
    teams=[pscustomobject]@{prefer_window='cdp';target_chat_name='Me'}
}
function Get-E3ReceiverConfig{return $cfg}
function Ask([string]$text){return Resolve-E3ReceiverRequest $text $cfg}
function Names($r){return (@($r.pages|ForEach-Object{$_.name}) -join ',')}

# ---- A. How a message is understood ----
Check ((Ask '@日管 狀態').kind -eq 'status' -and (Ask '@日管狀態').kind -eq 'status' -and (Ask '@日管　狀態').kind -eq 'status') 'status with a space, without a space, or with a full-width space'
Check ((Ask '@日管理員好').kind -eq 'ignore' -and (Ask '@日管').kind -eq 'ignore' -and (Ask '日管 狀態').kind -eq 'ignore') 'text that is not addressed to the bot is ignored'
Check ((Ask '@日管 在嗎？').text -match '^我在' -and (Ask '@日管 你好').text -match '上一個指令') 'a greeting is answered with the list of things to ask'
Check ((Ask '@日管 說明').text -match '@日管 檢查' -and (Ask '@日管 怎麼用').text -match '@日管 主機') 'help lists the new questions'
Check ((Ask '@日管 清單').text -match 'P14_D3（有 1 個監測項目）' -and (Ask '@日管 清單').text -match 'CMS（只截圖）' -and (Ask '@日管 清單').text -notmatch 'OLD') 'catalog says which pages are monitored and hides disabled ones'
$r=Ask '@日管 請幫我截圖 P14_D3、CMS 謝謝！'
Check ($r.kind -eq 'capture' -and (Names $r) -eq 'P14_D3,CMS' -and -not $r.analyze) 'polite words around a capture list are ignored'
Check ((Names (Ask '@日管 抓圖 MSD日管Index')) -eq 'P14_D7,CMS') 'other words for capture work and a schedule name gives its pages'
Check ((Ask '@日管 P14_D3').kind -eq 'capture' -and (Ask '@日管 P14_D3 截圖').kind -eq 'capture') 'a bare name, or a name before the capture word, is a capture'
$r=Ask '@日管 截圖 p14d3'
Check ($r.kind -eq 'help' -and $r.text -match '找不到「p14d3」。你是不是要：P14_D3') 'a mistyped name gets a suggestion and is not captured'
$r=Ask '@日管 截圖 P14_D3、P99'
Check ($r.kind -eq 'capture' -and (Names $r) -eq 'P14_D3' -and (@($r.warnings) -join '') -match '找不到「P99」') 'in a list a wrong name is reported and the others are still captured'
$r=Ask '@日管 P14_D3 現在多少？'
Check ($r.kind -eq 'check' -and $r.analyze -and (Names $r) -eq 'P14_D3') 'asking for a value is a check of that page'
$r=Ask '@日管 有沒有超標'
Check ($r.kind -eq 'check' -and (Names $r) -eq 'P14_D3' -and $r.everything) 'a check without a name covers every enabled page that has monitoring items'
Check ((Ask '@日管 截圖並檢查 CMS').kind -eq 'check') 'capture and check together is a check'
Check ((Ask '@日管 檢查 P99').text -match '找不到「P99」') 'a check of an unknown name asks instead of checking everything'
Check ((Ask '@日管 主機').kind -eq 'host' -and (Ask '@日管 主機正常嗎').kind -eq 'host' -and (Ask '@日管 電腦還好嗎').kind -eq 'host' -and (Ask '@日管 磁碟').kind -eq 'host') 'host questions'
$r=Ask '@日管 網站連得到嗎'
Check ($r.kind -eq 'connect' -and (Names $r) -eq 'P14_D3,P14_D7,CMS') 'a reachability question without a name tests every enabled page'
Check ((Names (Ask '@日管 連線 CMS')) -eq 'CMS') 'a reachability question for one page'
$r=Ask '@日管 早上的日管有送嗎'
Check ($r.kind -eq 'schedule' -and (@($r.schedules|ForEach-Object{$_.id}) -join ',') -eq 'morning') 'morning words pick the morning schedule'
Check ((@((Ask '@日管 晚上7點半那個有送嗎').schedules|ForEach-Object{$_.id}) -join ',') -eq 'evening') 'an hour picks the schedule at that hour'
Check ((@((Ask '@日管 Night 有送嗎').schedules|ForEach-Object{$_.id}) -join ',') -eq 'evening' -and (Ask '@日管 排程結果').schedules.Count -eq 2) 'a schedule name, or all schedules'
Check ((Ask '@日管 為什麼截圖失敗').kind -eq 'history' -and (Ask '@日管 為什麼沒收到').kind -eq 'schedule') 'a failed command and a missing scheduled message are different questions'
$r=Ask '@日管 今天天氣如何'
Check ($r.kind -eq 'help' -and $r.text -match '^這句我還看不懂' -and $r.text -match '@日管 截圖') 'an unknown question says so and shows what can be asked'
Check ((@(Get-E3ReceiverSuggestions 'CSM' $cfg)) -contains 'CMS' -and -not @(Get-E3ReceiverSuggestions 'XYZW' $cfg).Count) 'suggestions are close names only'

# ---- B. Acknowledgement says when the host is busy ----
$req=New-E3ReceiverCaptureRequest 'P14_D3' @('p14d3') $cfg @() 'check'
Check ((Get-E3ReceiverAcknowledgement $req) -match '^✦ \[日管\]\n收到！準備檢查 1 頁' -and (Get-E3ReceiverAcknowledgement $req) -notmatch '主機正在執行') 'acknowledgement of a check'
function Get-E3WorkOwner([string]$resource){return [pscustomobject]@{description='擷取與傳送：morning'}}
Check ((Get-E3ReceiverAcknowledgement $req) -match '主機正在執行「擷取與傳送：morning」') 'when a schedule holds the browser the wait is announced'
Remove-Item function:Get-E3WorkOwner

# ---- C. Check reply ----
$job=Join-Path $fixture 'job';[void][IO.Directory]::CreateDirectory($job)
foreach($n in 'p14d3.png','annotated_p14d3.png','p14d7.png'){[IO.File]::WriteAllBytes((Join-Path $job $n),[byte[]](1,2,3))}
$result=@{error='';pages=@(
    @{id='p14d3';ok=$true;error='';analysis=@{captureOnly=$false;annotated='annotated_p14d3.png';error='';rules=@(
        @{name='CPU';mode='numeric';status='exceeded';maximum=45.25;threshold=30},
        @{name='Mem';mode='numeric';status='normal';maximum=$null;below=12;threshold=30},
        @{name='Line';mode='pixel';status='normal';hits=0},
        @{name='Disk';mode='numeric';status='unknown';reason='峰值接近門檻，落在圖片辨識誤差範圍內';detail='最高值約 29.9／門檻 30'})}},
    @{id='p14d7';ok=$true;error='';analysis=@{captureOnly=$true;annotated='';error='';rules=@()}},
    @{id='cms';ok=$false;error='網站回應錯誤（HTTP 503）';analysis=$null})}
[IO.File]::WriteAllText((Join-Path $job 'result.json'),($result|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
$req=New-E3ReceiverCaptureRequest 'x' @('p14d3','p14d7','cms') $cfg @() 'check'
$reply=ConvertTo-E3ReceiverCaptureReply $req $job $false 0 52
$text=$reply.text
Check ($text -match '檢查結果（\d\d/\d\d \d\d:\d\d，花了 52 秒）：🚨 1 項超標、⚠️ 1 項無法判定、✅ 2 項正常') 'summary line with time, duration and counts'
Check ($text -match '🚨 CPU：超標，最高值約 45.25，門檻 30' -and $text -match '✅ Mem：正常，框內沒有曲線，最高值低於約 12，門檻 30' -and $text -match '✅ Line：正常，沒有越過警戒線') 'each item states its value and verdict in words'
Check ($text -match '⚠️ Disk：無法判定。原因：峰值接近門檻' -and $text -match 'P14_D7：沒有設定監測項目，只附截圖' -and $text -match '⚠️ CMS：沒有截到。原因：網站回應錯誤（HTTP 503）') 'undecided items, capture-only pages and failed pages are each explained'
Check (@($reply.images).Count -eq 2 -and ($reply.images[0] -match 'annotated_p14d3\.png$') -and ($reply.images[1] -match 'p14d7\.png$')) 'the marked picture is sent when there is one'
Check (@($reply.problems).Count -eq 2 -and $text -match '不會發給排程的收件對象') 'problems are recorded and the reply says it went only to this chat'
$plain=ConvertTo-E3ReceiverCaptureReply (New-E3ReceiverCaptureRequest 'x' @('p14d7') $cfg) $job $false 0 7
Check ($plain.text -match '已擷取 P14_D7' -and $plain.text -match '擷取時間 \d\d/\d\d \d\d:\d\d，花了 7 秒' -and @($plain.images).Count -eq 1) 'a plain capture reply now says when it was taken and how long it took'

# ---- D. Schedule results ----
$logs=$script:E3ReceiverQueryLogRoot;[void][IO.Directory]::CreateDirectory($logs)
$stamp=[DateTime]::Now.AddHours(-1)
$file=Join-Path $logs ($stamp.ToString('yyyy-MM-dd_HHmm')+'_morning.log')
[IO.File]::WriteAllText($file,"開始`r`n⚠️ CMS 截圖失敗，本頁圖片未附上，請檢查：網站回應錯誤（HTTP 503）`r`n✅ 正常`r`n❌ 發送到【Me】失敗：CDP 逾時、結果不明`r`n   繼續發送到其他對話...`r`n",[Text.UTF8Encoding]::new($true))
[IO.File]::WriteAllText((Join-Path $logs ($stamp.AddDays(-3).ToString('yyyy-MM-dd_HHmm')+'_evening.log')),"❌ old`r`n",[Text.UTF8Encoding]::new($true))
[IO.File]::SetLastWriteTime((Join-Path $logs ($stamp.AddDays(-3).ToString('yyyy-MM-dd_HHmm')+'_evening.log')),$stamp.AddDays(-3))
$log=Get-E3ReceiverScheduleLogLines 'morning'
Check (@($log.lines).Count -eq 2 -and $log.lines[0] -match 'HTTP 503' -and $log.lines[1] -match 'CDP 逾時' -and $log.at.ToString('HHmm') -eq $stamp.ToString('HHmm')) 'the newest schedule log gives its error and warning lines'
Check ($null -eq (Get-E3ReceiverScheduleLogLines 'evening') -and $null -eq (Get-E3ReceiverScheduleLogLines '..\x')) 'an old log or an invalid id gives nothing'
$report=Get-E3ReceiverScheduleReport (Ask '@日管 早上有送嗎') $cfg $null
Check ($report -match '「早上」的排程最近一輪' -and $report -match 'MSD日管Index（每天 08:00）：無法讀取 Windows 排程狀態' -and $report -match 'MSD日管Index 主機紀錄（' -and $report -match 'CDP 逾時' -and $report -notmatch 'Night') 'schedule report: status line and the log lines that explain it'
Check ((Get-E3ReceiverScheduleReport (Ask '@日管 中午有送嗎') $cfg $null) -match '沒有找到「中午」的排程') 'no schedule at that time is said plainly'

# ---- E. Host status ----
$facts=@{computer='HOST1';boot=[DateTime]::new(2026,11,10,8,0,0);cpu=95;memTotalKb=16GB/1KB;memFreeKb=8GB/1KB;projectDrive='D:';errors=@('磁碟：存取被拒')
    disks=@(@{name='C:';size=100GB;free=50GB},@{name='D:';size=500GB;free=20GB})}
$src=@(@{target=@{route='Me'};active=$true;error=$null},@{target=@{route='Group'};active=$false;error='E3_RECEIVER_LOGIN：Teams 需要重新登入'})
$host1=Get-E3ReceiverHostReply $facts $cfg @() $src ([DateTime]::new(2026,11,12,11,30,0))
Check ($host1 -match '主機：HOST1' -and $host1 -match '開機時間：11/10 08:00（已開機 2 天 3 小時）' -and $host1 -match 'CPU 使用率：95%' -and $host1 -match '記憶體：已用 8\.0／16\.0 GB（50%）') 'host: boot time, CPU and memory'
Check ($host1 -match '磁碟 D:：剩 20\.0 GB／共 500\.0 GB（4%），程式與截圖在這顆 ⚠ 空間不足' -and $host1 -match '磁碟 C:：剩 50\.0 GB') 'host: every disk, the program disk marked, low space flagged'
Check ($host1 -match '接收對話：2 個，其中 1 個目前讀不到' -and $host1 -match '• Group：Teams 需要重新登入' -and $host1 -match '離線監看：尚未註冊') 'host: chats that cannot be read and the watchdog task'
Check ($host1 -match '讀不到 磁碟：存取被拒' -and $host1 -match '⚠ 需要注意：CPU 使用率很高、磁碟 D: 空間不足') 'host: what could not be read and a one-line verdict'

# ---- F. Site reachability ----
$req=New-E3ReceiverCaptureRequest 'x' @('p14d3','p14d7','cms') $cfg @() 'connect'
$script:probes=@()
$text=Get-E3ReceiverConnectReply $req {param($u) $script:probes+=$u;if($u -match 'b\.invalid'){@{ok=$false;text='找不到這個主機名稱（DNS 查不到）'}}else{@{ok=$true;text='連得到（HTTP 200，0.2 秒）'}}}
Check ($script:probes.Count -eq 2 -and $text -match '✅ P14_D3：連得到' -and $text -match '✅ P14_D7：連得到' -and $text -match '❌ CMS：找不到這個主機名稱' -and $text -match '有 1 頁連不上') 'reachability: one request per address, each page answered'
# A loopback server answers 200, 401 and 500 in turn; a closed port and a bad scheme are explained.
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0);$listener.Start();$port=$listener.LocalEndpoint.Port
$server=[powershell]::Create().AddScript({param($l)
    foreach($status in @('200 OK','401 Unauthorized','500 Internal Server Error')){
        $client=$l.AcceptTcpClient();$stream=$client.GetStream()
        $buffer=New-Object byte[] 4096;[void]$stream.Read($buffer,0,$buffer.Length)
        $bytes=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
        $stream.Write($bytes,0,$bytes.Length);$stream.Flush();$client.Close()
    }}).AddArgument($listener)
$handle=$server.BeginInvoke()
$ok=Test-E3ReceiverSite "http://127.0.0.1:$port/a" 5000
$login=Test-E3ReceiverSite "http://127.0.0.1:$port/b" 5000
$broken=Test-E3ReceiverSite "http://127.0.0.1:$port/c" 5000
$server.EndInvoke($handle);$server.Dispose();$listener.Stop()
Check ($ok.ok -and $ok.text -match '^連得到（HTTP 200') 'a site that answers is reachable'
Check ($login.ok -and $login.text -match '網站要求登入（HTTP 401') 'a site that asks for a login is reachable'
Check (-not $broken.ok -and $broken.text -match '網站回應錯誤（HTTP 500') 'a server error is reported with its code'
# Windows retries a refused loopback connection for about 2 seconds before reporting it.
Check ((Test-E3ReceiverSite "http://127.0.0.1:$port/" 6000).text -match '^連不上' -and (Test-E3ReceiverSite 'ftp://x/' 2000).text -match '不是 http') 'a closed port and an unsupported address are explained'

# ---- G. The shared page judgment on generated pictures ----
# The engine runs its own modes when loaded, so only the needed functions are taken from it.
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'e3_monitor_native.ps1'),[ref]$null,[ref]$null)
foreach($name in 'Test-CurvePixel','Invoke-E3PageAnalysis'){
    $def=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)
    . ([scriptblock]::Create($def.Extent.Text))
}
Add-Type -AssemblyName System.Drawing
function New-Chart([string]$path,[int]$curveY){
    $bmp=[Drawing.Bitmap]::new(200,120);$g=[Drawing.Graphics]::FromImage($bmp)
    try{$g.Clear([Drawing.Color]::White);$pen=[Drawing.Pen]::new([Drawing.Color]::FromArgb(0,0,200),2);$g.DrawLine($pen,20,100,120,$curveY);$g.DrawLine($pen,120,$curveY,180,100);$pen.Dispose();$bmp.Save($path,[Drawing.Imaging.ImageFormat]::Png)}
    finally{$g.Dispose();$bmp.Dispose()}
}
$pixel=[pscustomobject]@{name='Line';enabled=$true;roi=[pscustomobject]@{x=10;y=10;w=180;h=100};threshold_y=40;color_mode='auto';min_pixels=2}
$page=[pscustomobject]@{id='g';name='G';rules=@($pixel)}
$high=Join-Path $fixture 'high.png';$low=Join-Path $fixture 'low.png';New-Chart $high 20;New-Chart $low 80
$a=Invoke-E3PageAnalysis $page $high 6>$null
Check ($a.hasAlert -and @($a.alerts).Count -eq 1 -and $a.rules[0].status -eq 'exceeded' -and $a.rules[0].hits -ge 2 -and [IO.File]::Exists($a.annotated)) 'judgment: a curve above the line is an alert, with a marked picture'
$a=Invoke-E3PageAnalysis $page $low 6>$null
Check (-not $a.hasAlert -and $a.rules[0].status -eq 'normal' -and -not @($a.failures).Count) 'judgment: a curve below the line is normal'
$bad=[pscustomobject]@{id='g';name='G';rules=@([pscustomobject]@{name='Bad';enabled=$true;roi=[pscustomobject]@{x=150;y=10;w=100;h=50};threshold_y=30})}
$a=Invoke-E3PageAnalysis $bad $low 6>$null
Check (@($a.failures).Count -eq 1 -and $a.failures[0] -match '警戒線無法判定' -and $a.rules[0].status -eq 'unknown') 'judgment: a box outside the picture is a failure, never normal'
$a=Invoke-E3PageAnalysis ([pscustomobject]@{id='g';name='G';rules=@()}) $low 6>$null
Check ($a.captureOnly -and -not $a.annotated) 'judgment: a page without monitoring items is capture only'
$notPng=Join-Path $fixture 'x.png';[IO.File]::WriteAllBytes($notPng,[byte[]](1..20))
$reason='';try{$null=Invoke-E3PageAnalysis $page $notPng 6>$null}catch{$reason=$_.Exception.Message}
Check ([bool]$reason) 'judgment: a file that is not a picture is an error for the caller to report'

# ---- H. Capture job with judgment, end to end (the browser capture is replaced by the pictures above) ----
# Takes the real capture lock (Local\E3MonitorNativeRun) for a moment; run when no schedule is running.
. (Join-Path $root 'teams_receiver_capture.ps1')
function Start-E3RunDeadline([string]$LogPath,[int]$Seconds){return [pscustomobject]@{}|Add-Member -MemberType ScriptMethod -Name Dispose -Value {} -PassThru}
function Enter-E3WorkLock($mutex,[string]$resource,[string]$description){try{[void]$mutex.WaitOne(5000)}catch [Threading.AbandonedMutexException]{};return $true}
function Capture-PagesNative($pagesToCapture,$authCfg,[string]$outDir,[switch]$Headless){
    $files=@{};$failures=[ordered]@{}
    foreach($p in $pagesToCapture){
        if($p.id -eq 'down'){$failures[$p.id]='網頁無法開啟（net::ERR_CONNECTION_REFUSED）';continue}
        $target=Join-Path $outDir ($p.id+'.png');Copy-Item -LiteralPath $(if($p.id -eq 'hot'){$high}else{$low}) -Destination $target;$files[$p.id]=$target
    }
    return @{Files=$files;Failures=$failures}
}
$jobCfg=[pscustomobject]@{auth=$null;pages=@(
    [pscustomobject]@{id='hot';name='Hot';enabled=$true;rules=@($pixel)},
    [pscustomobject]@{id='calm';name='Calm';enabled=$true;rules=@()},
    [pscustomobject]@{id='down';name='Down';enabled=$true;rules=@($pixel)})}
$job2=Join-Path $fixture 'job2';[void][IO.Directory]::CreateDirectory($job2)
Save-E3CdpState (Join-Path $job2 'request.json') @{pageIds=@('hot','calm','down');analyze=$true}
Invoke-E3ReceiverCaptureJob $jobCfg $job2 6>$null
$saved=Get-Content -LiteralPath (Join-Path $job2 'result.json') -Raw -Encoding UTF8|ConvertFrom-Json
$hot=@($saved.pages|Where-Object{$_.id -eq 'hot'})[0]
Check ($hot.ok -and $hot.analysis.rules[0].status -eq 'exceeded' -and $hot.analysis.annotated -eq 'annotated_hot.png' -and [IO.File]::Exists((Join-Path $job2 'annotated_hot.png'))) 'capture job: judgment result and marked picture are saved'
$req=@{kind='check';label='x';analyze=$true;warnings=@();pages=@($jobCfg.pages)}
$reply=ConvertTo-E3ReceiverCaptureReply $req $job2 $false 0 30
Check ($reply.text -match '🚨 1 項超標' -and $reply.text -match '🚨 Line：曲線越過警戒線' -and $reply.text -match 'Calm：沒有設定監測項目' -and $reply.text -match 'Down：沒有截到。原因：網頁無法開啟') 'capture job: the reply explains every page'
Check (@($reply.images).Count -eq 2 -and $reply.images[0] -match 'annotated_hot\.png$') 'capture job: the marked picture is sent for a judged page'
Save-E3CdpState (Join-Path $job2 'request.json') @{pageIds=@('hot')}
Remove-Item -LiteralPath (Join-Path $job2 'annotated_hot.png')
Invoke-E3ReceiverCaptureJob $jobCfg $job2 6>$null
$saved=Get-Content -LiteralPath (Join-Path $job2 'result.json') -Raw -Encoding UTF8|ConvertFrom-Json
Check ($null -eq $saved.pages[0].analysis -and -not [IO.File]::Exists((Join-Path $job2 'annotated_hot.png'))) 'capture job: a plain screenshot request does not judge'
"PASS $passed checks. Fixture: $fixture"
