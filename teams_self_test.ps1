# Self-test uses an immutable preview snapshot, never the configured recipient routes.
function Restore-E3SelfTestWorkers([string]$folder) {
    $jobs=@{}
    if(-not [IO.Directory]::Exists($folder)){return $jobs}
    foreach($dir in Get-ChildItem -LiteralPath $folder -Directory){
        if($dir.Name -cnotmatch '^[a-f0-9]{32}$'){continue}
        $p=$null
        try{
            $record=Read-E3WorkJson (Join-Path $dir.FullName 'worker.json')
            if(-not $record -or $record.controlToken -cnotmatch '^[a-f0-9]{32}$'){continue}
            $p=Get-Process -Id ([int]$record.pid) -ErrorAction Stop
            if($p.HasExited -or $p.ProcessName -notin @('powershell','pwsh') -or $p.StartTime.ToUniversalTime().Ticks.ToString() -cne [string]$record.processStart){continue}
            $line=[string](Get-CimInstance Win32_Process -Filter ('ProcessId='+$p.Id)).CommandLine
            $entry=Join-Path $PSScriptRoot 'e3_monitor_native.ps1'
            if($line.IndexOf($entry,[StringComparison]::OrdinalIgnoreCase) -lt 0 -or $line -notmatch ('(?i)-(SelfTestJob|SelfScheduleJob)\s+"?'+[regex]::Escape($dir.FullName)+'"?(?:\s|$)')){continue}
            $jobs[$dir.Name]=@{directory=$dir.FullName;process=$p;controlToken=$record.controlToken;startedUtc=$record.startedUtc;label=$record.label}
            $p=$null # Keep the verified handle for this exact process.
        }catch{continue}finally{if($p){$p.Dispose()}}
    }
    return $jobs
}
function Stop-E3SelfTestWorker($job,[string]$token) {
    if($token -cnotmatch '^[a-f0-9]{32}$' -or $job.controlToken -cne $token){throw '測試已變更，請重新查詢後選擇'}
    # Original Process handle from this server's Start-Process; never look up a new PID.
    if(-not $job.process){throw '無法辨識原測試程序'}
    if($job.process.HasExited){return} # Preserve a result completed while the dialog was open.
    $job.process.Kill();if(-not $job.process.WaitForExit(5000)){throw '原測試尚未停止，未啟動新工作'}
    Save-E3SelfTestStatus 'stopped' '使用者已強制停止本次測試。已送出的內容不會撤回或重送；尚未送出的內容不再繼續。' $job.directory
    Remove-E3SelfScheduleConfig $job.directory
}
function Save-E3SelfTestStatus([string]$state,[string]$message,[string]$directory=$script:E3SelfTestDirectory,$confirmation=$null) {
    if (-not $directory) { return }
    $path=Join-Path $directory 'status.json'
    $status=@{state=$state;message=$message}
    if($confirmation){$status.confirmation=$confirmation}
    $json=$status|ConvertTo-Json -Depth 8 -Compress
    [IO.File]::WriteAllText($path+'.tmp',$json,[Text.UTF8Encoding]::new($false))
    # Publish a complete file without a delete/rename gap while the page polls.
    for($attempt=0;;$attempt++){
        try {
            if([IO.File]::Exists($path)){[IO.File]::Replace($path+'.tmp',$path,[NullString]::Value)}
            else{[IO.File]::Move($path+'.tmp',$path)}
            break
        } catch [IO.IOException] {
            if($attempt -ge 9){throw}
            Start-Sleep -Milliseconds 30
        }
    }
}



function Read-E3SelfTestStatus([string]$directory) {
    $path=Join-Path $directory 'status.json'
    for($attempt=0;;$attempt++){
        $stream=$null;$reader=$null
        try {
            $stream=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
            $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8)
            return ($reader.ReadToEnd()|ConvertFrom-Json -ErrorAction Stop)
        } catch {
            if($attempt -ge 9){throw}
            Start-Sleep -Milliseconds 30
        } finally {if($reader){$reader.Dispose()}elseif($stream){$stream.Dispose()}}
    }
}



function Submit-E3SelfTestConfirmation([string]$directory,[string]$token,[string]$decision) {
    if($token -cnotmatch '^[a-f0-9]{32}$' -or $decision -cnotin @('approve','cancel')){throw '確認內容無效'}
    $decisionPath=Join-Path $directory 'decision.json'
    if(Test-Path -LiteralPath $decisionPath){
        $prior=Get-Content -LiteralPath $decisionPath -Raw -Encoding UTF8|ConvertFrom-Json
        if($prior.token -ceq $token -and $prior.decision -ceq $decision){return}
        throw '此測試已收到另一個決定，請查詢原測試狀態'
    }
    $status=Read-E3SelfTestStatus $directory
    $confirmation=$status.confirmation
    if($status.state -ne 'confirming' -or -not $confirmation -or $confirmation.token -cne $token){throw '確認已失效或不屬於此測試'}
    if([DateTimeOffset]::UtcNow -ge [DateTimeOffset]::Parse($confirmation.expiresUtc)){throw '確認已逾時，本次不會送出'}
    $temp=Join-Path $directory ([guid]::NewGuid().ToString('N')+'.decision.tmp')
    try {
        $json=@{token=$token;decision=$decision;utc=[DateTimeOffset]::UtcNow.ToString('o')}|ConvertTo-Json -Compress
        [IO.File]::WriteAllText($temp,$json,[Text.UTF8Encoding]::new($false))
        # Atomic, first decision wins. Never overwrite a prior approval/cancellation.
        [IO.File]::Move($temp,$decisionPath)
    } finally {if(Test-Path -LiteralPath $temp){Remove-Item -LiteralPath $temp -Force}}
}



function Show-E3SelfTestConfirmationPage([string]$token) {
    $marker='E3-SELF-CONFIRM-'+$token
    $windows=@(Get-TopWindows|Where-Object{$_.Proc -eq 'msedge' -and $_.Title.Contains($marker)})
    if($windows.Count -ne 1){return $false}
    if(Set-WindowForeground $windows[0].Hwnd){Write-Host '已將自己測試確認框帶到 Edge 設定頁面前方。'}
    else{Write-Host 'Windows 未允許切換前景，請切回 Edge 設定分頁確認；尚未送出。'}
    return $true # Attempt only once; never keep stealing focus from the user.
}



function Confirm-E3SelfTestDestination([string]$destination,[int]$imageCount,[int]$TimeoutSeconds=300) {
    Assert-InteractiveDesktop
    if(-not $script:E3SelfTestDirectory){throw '找不到本次測試，無法確認；未送出。'}
    $confirmation=@{token=[guid]::NewGuid().ToString('N');destination=$destination;label=$script:E3SelfTestLabel;kind=$script:E3SelfTestKind;imageCount=$imageCount;expiresUtc=[DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds).ToString('o')}
    Save-E3SelfTestStatus 'confirming' '請在 Edge 設定頁面中央核對對話並確認；尚未貼上或送出。逾時會取消。' $script:E3SelfTestDirectory $confirmation
    $decisionPath=Join-Path $script:E3SelfTestDirectory 'decision.json'
    $focusAttempted=$false;$approved=$false
    while([DateTimeOffset]::UtcNow -lt [DateTimeOffset]::Parse($confirmation.expiresUtc)){
        if(Get-Command Assert-E3WorkNotCancelled -ErrorAction SilentlyContinue){Assert-E3WorkNotCancelled}
        if(Test-Path -LiteralPath $decisionPath){
            $answer=Get-Content -LiteralPath $decisionPath -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json
            if($answer.token -cne $confirmation.token){throw '確認資料不符，已停止；未送出。'}
            if($answer.decision -cne 'approve'){throw '已取消；本次未貼上、未送出。'}
            $approved=$true;break
        }
        if(-not $focusAttempted){try{$focusAttempted=Show-E3SelfTestConfirmationPage $confirmation.token}catch{}}
        Start-Sleep -Milliseconds 300
    }
    if(-not $approved){throw '確認逾時；本次未貼上、未送出。'}
    Assert-InteractiveDesktop
    Save-E3SelfTestStatus 'sending' '已確認對話，正在傳送。請勿重複點選；若中斷請先檢查 Teams 訊息與草稿。'
}



function New-E3SelfTestJob($request,[string]$directory) {
    if($request.mode -notin @('auto','pwa','desktop','edge-tab','cdp')){throw 'Teams 模式無效'}
    if([Text.Encoding]::UTF8.GetByteCount([string]$request.message) -gt 24000){throw '預覽文字不可超過 24000 bytes'}
    if([string]::IsNullOrWhiteSpace($request.message) -and -not @($request.images).Count){throw '沒有預覽圖片或文字可傳送'}
    if(@($request.images).Count -gt 1000){throw '一次測試最多 1000 張圖片'}
    if(@($request.images).Count -eq 0 -and -not $request.hasFailures){throw '沒有可測試的預覽圖片'}
    if(Test-Path -LiteralPath $directory){throw '此測試已建立；不會重複啟動，請查詢原測試結果'}
    [IO.Directory]::CreateDirectory($directory)|Out-Null
    $files=@();$total=0
    foreach($image in @($request.images)){
        $data=[string]$image.dataUrl
        if(-not $data.StartsWith('data:image/png;base64,') -or $data.Length -gt 14MB){throw '預覽圖片格式或大小無效'}
        $bytes=[Convert]::FromBase64String($data.Substring(22));$total+=$bytes.Length
        if($bytes.Length -lt 8 -or $bytes.Length -gt 10MB -or $total -gt 75MB -or [BitConverter]::ToString($bytes[0..7]) -ne '89-50-4E-47-0D-0A-1A-0A'){throw '預覽 PNG 無效或超過大小上限（單張 10 MiB／合計 75 MiB）'}
        $stream=[IO.MemoryStream]::new($bytes);$bmp=$null
        try {$bmp=[Drawing.Bitmap]::new($stream);if($bmp.Width -gt 4096 -or $bmp.Height -gt 4096 -or [long]$bmp.Width*$bmp.Height -gt 16000000){throw '預覽 PNG 超過 4096 邊長／1600 萬畫素'}} finally {if($bmp){$bmp.Dispose()};$stream.Dispose()}
        $name='image_'+$files.Count+'.png';[IO.File]::WriteAllBytes((Join-Path $directory $name),$bytes);$files+=$name
    }
    # Whitelist: no auth, routes, schedules, CDP bindings or source URLs are copied.
    $snapshot=@{label=([string]$request.label);message=([string]$request.message);files=@($files);teams=@{prefer_window=$(if($request.mode -eq 'auto'){''}else{[string]$request.mode});cdp_headless=($request.headless -ne $false);auto_press_enter=$true}}
    [IO.File]::WriteAllText((Join-Path $directory 'preview.json'),($snapshot|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
}



function New-E3SelfScheduleJob($request,[string]$directory) {
    $cfg=$request.config
    if(-not $cfg -or $cfg.pages -isnot [array] -or $cfg.schedules -isnot [array]){throw '缺少排程設定'}
    if($request.scheduleId -isnot [string] -or $request.scheduleId -notmatch '^[A-Za-z0-9_-]+$'){throw '請選擇一個排程，不可使用全部頁面'}
    $matches=@($cfg.schedules|Where-Object{$_.id -ceq $request.scheduleId})
    if($matches.Count -ne 1){throw '找不到唯一的指定排程'}
    $sched=$matches[0]
    if($sched.pages -isnot [array] -or $sched.pages.Count -eq 0 -or $sched.pages.Count -gt 1000){throw '排程頁面清單無效或為空（上限 1000 頁）'}
    foreach($id in $sched.pages){if($id -isnot [string] -or $id -notmatch '^[A-Za-z0-9_-]+$'){throw '排程頁面編號無效'}}
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($page in $cfg.pages){if($page.id -isnot [string] -or $page.id -notmatch '^[A-Za-z0-9_-]+$' -or -not $ids.Add($page.id)){throw '頁面編號無效或重複'}}
    if($cfg.teams.prefer_window -notin @($null,'','auto','pwa','desktop','edge-tab','cdp')){throw 'Teams 模式無效'}
    if(Test-Path -LiteralPath $directory){throw '此測試已建立；請查詢原測試，不會重送'}
    # A private per-run copy: do not save config.json or register/change tasks.
    $copy=$cfg|ConvertTo-Json -Depth 40|ConvertFrom-Json
    $selected=$copy.schedules|Where-Object{$_.id -ceq $request.scheduleId}|Select-Object -First 1
    $selected|Add-Member NoteProperty target_chat_names @('自己') -Force
    $selected|Add-Member NoteProperty target_chat_name '自己' -Force
    $copy.schedules=@($selected)
    $copy.pages=@($copy.pages|Where-Object{$_.id -in $selected.pages})
    foreach($page in $copy.pages){$page.PSObject.Properties.Remove('target_chat_name')}
    $copy.teams|Add-Member NoteProperty target_chat_name '自己' -Force
    $copy.teams|Add-Member NoteProperty auto_press_enter $true -Force
    if($copy.teams.prefer_window -eq 'auto'){$copy.teams.prefer_window=''}
    foreach($key in @('delivery_method','webhook_targets','webhook_url')){$copy.teams.PSObject.Properties.Remove($key)}
    [IO.Directory]::CreateDirectory($directory)|Out-Null
    try {
        [IO.File]::WriteAllText((Join-Path $directory 'run-config.json'),($copy|ConvertTo-Json -Depth 40),[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $directory 'schedule.json'),(@{id=$selected.id;label=$(if($selected.name){$selected.name}else{$selected.id})}|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
        Save-E3SelfTestStatus 'starting' '正在啟動排程實際擷取；完成後會在本頁確認自己的對話。' $directory
    } catch {Remove-E3SelfScheduleConfig $directory;throw}
}



function Remove-E3SelfScheduleConfig([string]$directory) {
    if($directory){Remove-Item -LiteralPath (Join-Path $directory 'run-config.json') -Force -ErrorAction SilentlyContinue}
}



function Find-E3SelfTestWindow([string]$prefer) {
    $kinds=if($prefer){@($prefer)}else{@('pwa','desktop','edge-tab')}
    foreach($kind in $kinds){
        $matches=@(Get-TeamsCandidates @($kind))
        if($matches.Count -gt 1){throw "有多個 $kind Teams 視窗／分頁，無法唯一決定帳號。請只保留要測試的一個，或改選其他 Teams 模式。"}
        if($matches.Count -eq 1){
            if($kind -eq 'edge-tab'){Select-UIAElement $matches[0].Tab;Start-Sleep -Milliseconds 800}
            return $matches[0]
        }
    }
    throw '找不到所選模式已開啟的 Teams；本次未貼上、未送出。'
}



function Test-E3SelfRowName([string]$row,[string]$name) {
    if($row -match '群組|群聊|Group chat'){return $false}
    $base=($name -replace '\s*[（(]\s*(您|你|You)\s*[）)]$','').Trim()
    if(-not $base){return $false}
    # UIA may append presence, last-message and time metadata after the name.
    $clean=($row -replace '^(?:聊天\s*|Chat(?:\s+with)?\s+)','').Trim()
    return $clean -match ('^'+[regex]::Escape($base)+'(?:\s|[（(]|$)')
}



function Get-E3ManagedHeadingProperty {
    $field=[Windows.Automation.AutomationElement].GetField('HeadingLevelProperty')
    if($field){return $field.GetValue($null)}
    return $null
}



function Initialize-E3NativeSelfUia {
    if('E3SelfNativeUia.Reader' -as [type]){return}
    # Windows exposes property 30173 even when the installed .NET UIA wrapper
    # has no HeadingLevelProperty. Read-only COM calls, no focus/click methods.
    Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace E3SelfNativeUia {
    [ComImport, Guid("30CBE57D-D9D0-452A-AB13-7AC5AC4825EE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IAutomation {
        void CompareElements(); void CompareRuntimeIds(); void GetRootElement();
        [PreserveSig] int ElementFromHandle(IntPtr hwnd, out IElement element);
        void ElementFromPoint(); void GetFocusedElement(); void GetRootElementBuildCache();
        void ElementFromHandleBuildCache(); void ElementFromPointBuildCache(); void GetFocusedElementBuildCache();
        void CreateTreeWalker(); void GetControlViewWalker(); void GetContentViewWalker();
        [PreserveSig] int GetRawViewWalker(out IWalker walker);
        void GetRawViewCondition(); void GetControlViewCondition(); void GetContentViewCondition();
        void CreateCacheRequest(); void CreateTrueCondition(); void CreateFalseCondition();
        [PreserveSig] int CreatePropertyCondition(int propertyId, [MarshalAs(UnmanagedType.Struct)] object value,
            [MarshalAs(UnmanagedType.Interface)] out object condition);
    }
    [ComImport, Guid("D22108AA-8AC5-49A5-837B-37BBB3D7591E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IElement {
        void SetFocus();
        [PreserveSig] int GetRuntimeId([MarshalAs(UnmanagedType.SafeArray, SafeArraySubType=VarEnum.VT_I4)] out int[] id);
        void FindFirst();
        [PreserveSig] int FindAll(int scope, [MarshalAs(UnmanagedType.Interface)] object condition, out IElementArray elements);
        void FindFirstBuildCache(); void FindAllBuildCache(); void BuildUpdatedCache();
        [PreserveSig] int GetCurrentPropertyValue(int propertyId, [MarshalAs(UnmanagedType.Struct)] out object value);
    }
    [ComImport, Guid("14314595-B4BC-4055-95F2-58F2E42C9855"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IElementArray {
        [PreserveSig] int GetLength(out int length);
        [PreserveSig] int GetElement(int index, out IElement element);
    }
    [ComImport, Guid("4042C624-389C-4AFC-A630-9DF854A541FC"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IWalker {
        [PreserveSig] int GetParentElement(IElement element, out IElement parent);
    }
    public static class Reader {
        static void Check(int hr) { Marshal.ThrowExceptionForHR(hr); }
        static void Release(object obj) { if(obj != null && Marshal.IsComObject(obj)) Marshal.ReleaseComObject(obj); }
        static string RuntimeId(IElement element) {
            int[] id; Check(element.GetRuntimeId(out id));
            if(id == null || id.Length == 0) throw new InvalidOperationException("UIA runtime ID unavailable");
            return String.Join(",", Array.ConvertAll(id, n => n.ToString(System.Globalization.CultureInfo.InvariantCulture)));
        }
        static object Property(IElement element, int propertyId) {
            object value; Check(element.GetCurrentPropertyValue(propertyId, out value)); return value;
        }
        static string ParticipantHeader(IElement element, IAutomation automation, IWalker walker) {
            // Observed Teams UI: exact self text -> chat-topic-person-* -> one
            // participant list item -> list -> generic heading -> entity header -> chat-header-*.
            IElement current=element;
            int stage=0; string personId=null, itemId=null;
            bool entityTitle=false;
            try {
                for(int depth=0;depth<16;depth++) {
                    IElement parent; Check(walker.GetParentElement(current,out parent));
                    if(current!=element)Release(current);current=parent;
                    if(current==null)return null;
                    object visible=Property(current,30022);
                    if(!(visible is bool) || (bool)visible)return null;
                    string id=Property(current,30011) as string ?? "";
                    object rawType=Property(current,30003);int type=rawType is int?(int)rawType:0;
                    if(id.StartsWith("message-",StringComparison.Ordinal) || id=="chat-pane-list")return null;
                    if(stage==0 && id.StartsWith("chat-topic-person-8:orgid:",StringComparison.Ordinal)) {
                        personId=id;stage=1;
                    } else if(stage==1 && type==50007) {
                        itemId=RuntimeId(current);stage=2;
                    } else if(stage==2 && type==50008) {
                        object condition=null; IElementArray items=null; IElement only=null;
                        try {
                            Check(automation.CreatePropertyCondition(30003,50007,out condition));
                            Check(current.FindAll(4,condition,out items));
                            int length;Check(items.GetLength(out length));
                            if(length!=1)return null;
                            Check(items.GetElement(0,out only));
                            if(RuntimeId(only)!=itemId)return null;
                        } finally {Release(only);Release(items);Release(condition);}
                        stage=3;
                    } else if(stage==3) {
                        object level=Property(current,30173);
                        if(level is int && (int)level==80052)stage=4;
                    } else if(stage==4) {
                        if(id=="entity-header-title-area-prim")entityTitle=true;
                        if(id.StartsWith("chat-header-",StringComparison.Ordinal)) {
                            if(!entityTitle)return null;
                            return RuntimeId(element)+"|"+personId+"|"+id+"|"+RuntimeId(current);
                        }
                    }
                }
                return null;
            } finally {if(current!=element)Release(current);}
        }
        public static string[] FindHeadingIds(IntPtr hwnd, string name, string expectedRootId) {
            if(hwnd == IntPtr.Zero || String.IsNullOrEmpty(name) || String.IsNullOrEmpty(expectedRootId))
                throw new ArgumentException("Missing UIA identity");
            object instance=null, condition=null; IElement root=null; IElementArray elements=null; IWalker walker=null;
            var found=new List<string>();
            try {
                instance=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("FF48DBA4-60EF-4201-AA87-54103EEF594E"),true));
                var automation=(IAutomation)instance;
                Check(automation.ElementFromHandle(hwnd,out root));
                Check(automation.GetRawViewWalker(out walker));
                if(RuntimeId(root) != expectedRootId) throw new InvalidOperationException("UIA window identity changed");
                Check(automation.CreatePropertyCondition(30005,name,out condition)); // UIA_NamePropertyId
                Check(root.FindAll(4,condition,out elements)); // TreeScope_Descendants
                int length; Check(elements.GetLength(out length));
                for(int i=0;i<length;i++) {
                    IElement element=null;
                    try {
                        Check(elements.GetElement(i,out element));
                        object level=Property(element,30173); // UIA_HeadingLevelPropertyId
                        object hidden=Property(element,30022); // UIA_IsOffscreenPropertyId
                        if(hidden is bool && !(bool)hidden && String.Equals(Property(element,30005) as string,name,StringComparison.Ordinal)) {
                            if(level is int && ((int)level==80051 || (int)level==80052))found.Add(RuntimeId(element));
                            else {
                                string participant=ParticipantHeader(element,automation,walker);
                                if(participant!=null)found.Add(participant);
                            }
                        }
                    } finally { Release(element); }
                }
                if(RuntimeId(root) != expectedRootId) throw new InvalidOperationException("UIA window identity changed");
                return found.ToArray();
            } finally { Release(walker); Release(elements); Release(condition); Release(root); Release(instance); }
        }
    }
}
'@
}



function Get-E3SelfTestUiaProof([IntPtr]$hwnd) {
    $title=[E3Win]::GetTitle($hwnd);$name=Get-ChatNameFromTitle $title
    if(-not $name -or $name -notmatch '[（(]\s*(您|你|You)\s*[）)]$'){throw '目前對話沒有 Teams 的本人標記，已停止。'}
    $root=$UIA::FromHandle($hwnd)
    $rows=@(Find-UIA $root 'TreeItem' { -not $_.Current.IsOffscreen })
    $items=@($rows|Where-Object {Test-E3SelfRowName $_.Current.Name $name})
    $selected=@($rows|Where-Object {try{$_.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Current.IsSelected}catch{$false}})
    if($items.Count -ne 1){throw "無法唯一辨識本人聊天項目（相符 $($items.Count) 個），已停止；請開啟自己的個人對話並保持聊天清單可見。"}
    $item=$items[0];$itemId=$item.GetRuntimeId() -join ','
    if($selected.Count -gt 1 -or ($selected.Count -eq 1 -and ($selected[0].GetRuntimeId() -join ',') -cne $itemId)){throw '聊天清單選取了其他對話或多個項目，已停止。'}
    # A real accessibility heading is independent of selection metadata. Do not
    # accept ordinary message text that happens to contain the user's name.
    $headingIds=@();$headingSource='managed';$headingError=''
    $headingProperty=Get-E3ManagedHeadingProperty
    if($headingProperty){
        $nameCondition=[Windows.Automation.PropertyCondition]::new($UIA::NameProperty,$name)
        $headingIds=@($root.FindAll($UIAll,$nameCondition)|Where-Object {
            -not $_.Current.IsOffscreen -and [string]$_.GetCurrentPropertyValue($headingProperty) -in @('Level1','Level2')
        }|ForEach-Object { $_.GetRuntimeId() -join ',' })
    }
    if(-not $headingIds.Count){
        $headingSource='native'
        try {
            Initialize-E3NativeSelfUia
            $headingIds=@([E3SelfNativeUia.Reader]::FindHeadingIds($hwnd,$name,($root.GetRuntimeId() -join ',')))
        }catch{
            $headingError='；原生標頭讀取失敗：'+$_.Exception.GetBaseException().Message
        }
    }
    if($headingIds.Count -gt 1){throw '找到多個相同的本人對話標頭，已停止。'}
    $legacySelected=$selected.Count -eq 1 -and $item.Current.Name.Contains($name)
    if($headingIds.Count -ne 1 -and -not $legacySelected){throw "無法交叉核對本人對話標頭與聊天清單（標頭 $($headingIds.Count)、選取 $($selected.Count)、讀取方式 $headingSource$headingError），已停止；請保持自己的對話標頭與聊天清單可見。"}
    $boxes=@(Find-UIA $root 'Edit' {
        -not $_.Current.IsOffscreen -and ($_.Current.AutomationId -like 'new-message-*' -or $_.Current.Name -match '^(輸入訊息|Type a (new )?message)$')
    })
    if($boxes.Count -ne 1){throw '自己對話的輸入框不存在或不唯一，已停止。'}
    $box=$boxes[0]
    return @{title=$title;name=$name;root=($root.GetRuntimeId() -join ',');item=$itemId;box=($box.GetRuntimeId() -join ',');process=$root.Current.ProcessId;header=$(if($headingIds.Count -eq 1){$headingIds[0]}else{''})}
}



function Assert-E3SelfTestUiaProof([IntPtr]$hwnd,$expected,[switch]$RequireFocus) {
    $actual=Get-E3SelfTestUiaProof $hwnd
    foreach($key in @('title','name','root','item','box','process','header')){if($actual[$key] -cne $expected[$key]){throw '確認後 Teams 對話或視窗已改變，已停止；請檢查原對話的訊息與草稿，不會自動重送。'}}
    if($RequireFocus -and ([E3Win]::GetForegroundWindow() -ne $hwnd -or -not (Find-TeamsComposeBox $hwnd).Current.HasKeyboardFocus)){throw 'Teams 輸入焦點已改變，停止貼上／送出。'}
}



function Open-E3ExistingSelfTestCdp {
    $session=Get-E3CdpSession # Validates the original browser endpoint; never scans other browsers.
    $tabs=@(Get-E3LocalJson "http://127.0.0.1:$($session.port)/json/list"|ForEach-Object{$_})
    $bound=@(Get-E3CdpBindings|Where-Object{$_.binding.isSelf -eq $true})
    $targets=@()
    foreach($entry in $bound){
        $live=@($tabs|Where-Object{$_.type -eq 'page' -and $_.id -ceq $entry.targetId})
        if($live.Count -ne 1){continue}
        $duplicate=@($targets|Where-Object{$_.targetId -ceq $entry.targetId})
        if($duplicate.Count){
            foreach($key in @('accountId','chatId','label')){if($duplicate[0].binding.$key -cne $entry.binding.$key){throw '同一個 CDP 分頁有不同的本人綁定，請先核對；本次未送出。'}}
        }else{$targets+=,$entry}
    }
    if($bound.Count){
        if($targets.Count -ne 1){throw '沒有唯一已開啟的 CDP 本人綁定分頁；請保留要測試的自己對話並核對 CDP 設定。本次不另開登入頁，也不送出。'}
        $target=$targets[0]
        $context=Connect-E3CdpTarget $session $target -PrepareNew
        Assert-E3SelfTestCdpBinding $context $target.binding
    }else{
        # With no stored self binding, only one existing Teams app tab is allowed.
        # Launcher/deep-link/login pages are not the chat app and cannot be selected.
        $appTabs=@($tabs|Where-Object{
            if($_.type -ne 'page' -or -not(Test-E3TeamsPage $_.url)){return $false}
            $uri=[Uri]$_.url
            return $uri.AbsolutePath -notmatch '^/(dl|l|login|signin|auth)(/|$)'
        })
        if($appTabs.Count -ne 1){throw '找不到唯一可驗證的 Teams 對話分頁；請在 CDP 專用 Edge 開啟自己的對話，或先綁定本人對話。本次不另開登入頁，也不送出。'}
        $tab=$appTabs[0];$wsUri=[Uri]$tab.webSocketDebuggerUrl
        if($wsUri.Port -ne [int]$session.port){throw 'CDP 分頁端點不符，已停止。'}
        Connect-E3Cdp $tab.webSocketDebuggerUrl
        Invoke-E3Cdp 'Page.enable'|Out-Null
        Enable-E3CdpBackgroundFocus
        Invoke-E3Js (Get-E3CdpRuntimeSource 'vendor\image-frame-bootstrap.js')|Out-Null
        $frame=(Invoke-E3Cdp 'Page.getFrameTree').frameTree.frame.id
        $context=[int](Invoke-E3Cdp 'Page.createIsolatedWorld' @{frameId=$frame;worldName='E3ProductionCdp'}).executionContextId
        $runtime=Invoke-E3Js '({exists:!!globalThis.E3Cdp,version:globalThis.E3Cdp?.version})' $context
        if($runtime.exists -and $runtime.version -notin @('2026-11-05-headless1','2026-11-06-optionaltext1','2026-11-06-receipt2','2026-11-09-preflight1','2026-11-10-preparation1','2026-11-10-captionspace1','2026-11-11-receipttext1','2026-11-10-receiptbreak1','2026-11-12-history1')){throw '原 Teams 分頁控制程式版本不符，請先核對訊息與草稿；本次停止。'}
        if(-not $runtime.exists){foreach($file in @('vendor\adapter.js','vendor\outbound-images.js','receipt.js','runtime.js')){Invoke-E3Js (Get-E3CdpRuntimeSource $file) $context|Out-Null}}
        Stop-E3PriorPreparation $context
        $result=Get-E3SelfBinding $context
        if(-not $result.ok -or $result.binding.isSelf -ne $true){throw '目前開啟的 Teams 對話無法驗證為登入者本人；請切到自己的對話。本次未送出。'}
        $target=@{route='自己（測試）';targetId=$tab.id;binding=$result.binding}
    }
    Invoke-E3Cdp 'Target.activateTarget' @{targetId=$target.targetId}|Out-Null
    Write-Host '已沿用原本開啟的 CDP 本人對話；未新增分頁或重新導向登入。'
    # No ownership: the caller must leave this browser/tab open after testing.
    return @{browser=$null;context=$context;target=$target}
}



function Open-E3SelfTestCdp([bool]$headless) {
    if(-not $headless){return (Open-E3ExistingSelfTestCdp)}
    $browser=$null
    try {
        if($headless){
            $profile=Join-Path (Get-E3CdpStateRoot) 'profile'
            if(-not(Test-Path -LiteralPath (Join-Path $profile 'Default'))){throw '尚未登入 CDP 專用 Edge，請先設定 CDP。'}
            $browser=Start-E3TestBrowser $profile -Headless
            $tabId=$browser.targetId
        }
        Initialize-E3HeadlessPage
        Move-E3HeadlessPage 'https://teams.cloud.microsoft/l/chat/48%3Anotes/conversations'
        $source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'teams_self_test.js'))
        $until=[DateTime]::UtcNow.AddSeconds(75);$last='載入中'
        do {
            $probe=Invoke-E3Js $source
            if($probe.error){throw $probe.error}
            if($probe.ready){break}
            $last=$probe.stage;Start-Sleep -Milliseconds 500
        }while([DateTime]::UtcNow -lt $until)
        if(-not $probe.ready){throw "找不到可驗證的自己對話（$last）。請在 CDP 設定中檢查原登入與本人對話；未就緒不一定代表登入過期。本次未貼上或送出。"}
        Invoke-E3Cdp 'Page.enable'|Out-Null
        $frame=(Invoke-E3Cdp 'Page.getFrameTree').frameTree.frame.id
        $context=[int](Invoke-E3Cdp 'Page.createIsolatedWorld' @{frameId=$frame;worldName='E3ProductionCdp'}).executionContextId
        foreach($file in @('vendor\adapter.js','vendor\outbound-images.js','receipt.js','runtime.js')){Invoke-E3Js (Get-E3CdpRuntimeSource $file) $context|Out-Null}
        $result=Get-E3SelfBinding $context
        if(-not $result.ok -or $result.binding.isSelf -ne $true){throw "無法驗證此對話属于目前登入帳號的自聊：$($result.error)"}
        return @{browser=$browser;context=$context;target=@{route='自己（預覽測試）';targetId=$tabId;binding=$result.binding}}
    } catch {Close-E3OwnedBrowser $browser;throw}
}



function Assert-E3SelfTestCdpBinding([int]$context,$expected) {
    $actual=Get-E3SelfBinding $context
    if(-not $actual.ok -or $actual.binding.isSelf -ne $true){throw '自聊身分驗證失敗，停止傳送。'}
    foreach($key in @('accountId','chatId','label')){if($actual.binding.$key -cne $expected.$key){throw '確認後 Teams 帳號或對話已改變，停止傳送。'}}
}



function Invoke-E3SelfTestJob([string]$directory) {
    $script:E3SelfTestDirectory=$directory
    $mutex=[Threading.Mutex]::new($false,'Local\E3MonitorNativeRun');$locked=$false
    try {
        try{$locked=$mutex.WaitOne(0)}catch [Threading.AbandonedMutexException]{$locked=$true}
        if(-not $locked){throw '排程或另一個測試正在執行；本次未貼上、未送出。'}
        Assert-InteractiveDesktop
        $snapshot=Get-Content -LiteralPath (Join-Path $directory 'preview.json') -Raw -Encoding UTF8|ConvertFrom-Json
        $script:E3SelfTestLabel=$snapshot.label
        $files=@($snapshot.files|ForEach-Object{if($_ -notmatch '^image_\d+\.png$'){throw '測試圖片名稱無效'};Join-Path $directory $_})
        Save-E3SelfTestStatus 'finding' '正在辨識自己的 Teams 對話；找到後會在 Edge 設定頁面中央顯示確認框。'
        Send-GroupToTeams -targetChatName '自己' -imageFiles $files -messageText $snapshot.message -teamsCfg $snapshot.teams -isDryRun $false -SelfTest
        Save-E3SelfTestStatus 'complete' '已完成本次傳給自己的預覽測試。正式排程與收件設定未變更。'
        return 0
    } catch {
        Save-E3SelfTestStatus 'stopped' ($_.Exception.Message+' 若已進入傳送階段，請先核對 Teams 訊息與草稿；不會自動重送。')
        return 1
    } finally {if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
 
 