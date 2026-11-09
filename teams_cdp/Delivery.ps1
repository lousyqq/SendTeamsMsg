# ==============================================================================
# CDP 背景傳送 (teams.prefer_window = "cdp")
# 由 e3_monitor_native.ps1 在需要時 dot-source，沿用主程式的函數與變數：
#   $profileDir、Get-BrowserPath、Stop-ProfileEdge、Connect-CdpPage、Invoke-CdpCommand、Invoke-CdpEval、
#   Close-CaptureBrowser、Resolve-ChatTarget、Test-ChatTitle、Get-ChatNameFromTitle、$ChatPrefix、
#   Split-TeamsImageBatches、Get-TeamsBatchText (teams_delivery.ps1)
# 做法：用專用 edge_profile 啟動「背景 (headless) Edge」開啟 Teams 網頁版，以 CDP 在網頁內操作：
#   點左側「聊天」→ 在聊天清單點對話名稱 → 確認網頁標題的對話名稱完全相同 → 貼上圖片 (DataTransfer)
#   → 輸入文字 (Input.insertText) → 點「傳送」→ 確認輸入框清空。
# 不使用系統剪貼簿、SendKeys、滑鼠或前景視窗，所以 Windows 鎖定或螢幕關閉時也能執行 (不可登出、睡眠)。
# 主程式提供的三個入口：Send-GroupToTeamsCdp、Test-E3CdpConnection (-DetectTeams)、Set-E3CdpBinding (-CdpSetup)
# ==============================================================================

$CdpTeamsPort = 9334
$CdpDefaultTeamsUrl = "https://teams.cloud.microsoft/"



# 在 Teams 網頁內執行的輔助函數 (每次使用前確認已安裝；換頁後會重新安裝)
$CdpTeamsJs = @'
(() => {
if (window.__e3t && window.__e3t.v === 1) return 'READY';
const clean = s => (s || '').replace(/[\u200B-\u200D\u2060\uFEFF]/g, '').replace(/\s+/g, ' ').trim();
const visible = el => !!el && el.isConnected && el.getClientRects().length > 0;
function compose() {
  const c = document.querySelector('[id^="new-message-"]');
  if (!c) return null;
  if (c.isContentEditable) return c;
  return c.querySelector('[contenteditable="true"]') || null;
}
function composeState() {
  const c = compose();
  if (!c) return { found: false, images: 0, text: 0, loaded: 0 };
  const imgs = [...c.querySelectorAll('img')];
  const text = (c.innerText || '').replace(/[\u200B-\u200D\u2060\uFEFF\s]/g, '');
  return { found: true, images: imgs.length, loaded: imgs.filter(i => i.complete && i.naturalWidth > 0).length, text: text.length };
}
function loginPage() {
  if (/(^|\.)login\.(microsoftonline|live|microsoft)\.com$|(^|\.)account\.live\.com$/i.test(location.hostname)) return true;
  const pwd = [...document.querySelectorAll('input[type="password"]')].some(visible);
  return pwd && !compose() && !document.querySelector('[role="treeitem"]');
}
function chatNav() {
  const rx = /^(聊天|Chat)(\s|\(|$)/;
  return [...document.querySelectorAll('button,[role="button"],[role="tab"],[role="menuitem"]')]
    .find(b => visible(b) && rx.test(clean(b.getAttribute('aria-label') || b.innerText)) && !/新聊天|New chat/i.test(b.getAttribute('aria-label') || '')) || null;
}
function sendButton() {
  const rx = /^(傳送|发送|Send)(\s|\(|$)/i;
  const all = [...document.querySelectorAll('button,[role="button"]')].filter(b => visible(b) && rx.test(clean(b.getAttribute('aria-label') || b.getAttribute('title') || b.innerText)));
  const c = compose();
  if (c) { let box = c; for (let i = 0; i < 10 && box; i++) { box = box.parentElement; const near = all.find(b => box && box.contains(b)); if (near) return near; } }
  return all[0] || null;
}
function countText(line) {
  if (!line) return 0;
  const main = document.querySelector('[role="main"]') || document.body;
  const n = s => s ? s.split(line).length - 1 : 0;
  const c = compose();
  return n(main.innerText) - (c && main.contains(c) ? n(c.innerText) : 0);
}
function caretEnd(c) {
  c.focus();
  const sel = getSelection(), r = document.createRange();
  r.selectNodeContents(c); r.collapse(false); sel.removeAllRanges(); sel.addRange(r);
}
window.__e3t = {
  v: 1,
  state() {
    const launcher = [...document.querySelectorAll('a,button,[role="button"]')].find(b => visible(b) && /改用網頁|使用網頁版|Use the web app|Continue on this browser|在此瀏覽器上繼續/i.test(clean(b.innerText || b.getAttribute('aria-label'))));
    return JSON.stringify({ href: location.href, title: document.title, ready: document.readyState, login: loginPage(),
      chatNav: !!chatNav(), items: document.querySelectorAll('[role="treeitem"]').length, compose: composeState(), launcher: !!launcher, send: !!sendButton() });
  },
  clickLauncher() {
    const b = [...document.querySelectorAll('a,button,[role="button"]')].find(b => visible(b) && /改用網頁|使用網頁版|Use the web app|Continue on this browser|在此瀏覽器上繼續/i.test(clean(b.innerText || b.getAttribute('aria-label'))));
    if (!b) return 'NOT_FOUND'; b.click(); return 'CLICKED';
  },
  clickChatNav() { const b = chatNav(); if (!b) return 'NOT_FOUND'; b.click(); return 'CLICKED'; },
  // 先找名稱完全相同的項目 (項目文字第一行 = 對話名稱)，避免「E3」點到排在前面的「E3 乖乖」；
  // loose=true 時 (整份清單都找過仍沒有完全相同) 才接受前綴比對，最後仍由網頁標題確認
  findChat(src, name, self, loose) {
    const rx = new RegExp(src), exactRx = new RegExp(src.replace(/\(\\s\|\$\)$/, '$'));
    const items = [...document.querySelectorAll('[role="treeitem"]')].filter(visible);
    const first = it => clean((it.innerText || '').split('\n')[0]);
    const label = it => clean(it.getAttribute('aria-label') || '');
    let pick = self
      ? items.find(it => /\((您|You)\)$/.test(first(it))) || (loose && items.find(it => /\((您|You)\)/.test(label(it))))
      : items.find(it => first(it) === name || exactRx.test(label(it))) || (loose && items.find(it => rx.test(label(it)) || rx.test(first(it))));
    if (pick) { pick.scrollIntoView({ block: 'center' }); pick.click(); return 'CLICKED'; }
    const tree = document.querySelector('[role="tree"]');
    let s = tree; while (s && s.scrollHeight <= s.clientHeight + 2) s = s.parentElement;
    if (!s || s === document.documentElement) return 'END';
    const before = s.scrollTop; s.scrollTop = before + Math.max(200, s.clientHeight * 0.9);
    return s.scrollTop > before ? 'SCROLLED' : 'END';
  },
  listTop() { const tree = document.querySelector('[role="tree"]'); let s = tree; while (s && s.scrollHeight <= s.clientHeight + 2) s = s.parentElement; if (s && s !== document.documentElement) s.scrollTop = 0; return 'OK'; },
  focusEnd() { const c = compose(); if (!c) return 'NO_COMPOSE'; caretEnd(c); return document.activeElement === c || c.contains(document.activeElement) ? 'OK' : 'NO_FOCUS'; },
  // 選取輸入框全部內容 (之後以 CDP 按 Backspace 刪除，讓編輯器自己處理)
  selectAll() {
    const c = compose(); if (!c) return 'NO_COMPOSE';
    c.focus();
    const sel = getSelection(), r = document.createRange();
    r.selectNodeContents(c); sel.removeAllRanges(); sel.addRange(r);
    return 'OK';
  },
  // 以 DataTransfer 模擬貼上 (不經系統剪貼簿)；list = [{ name, b64 }]
  paste(list) {
    const c = compose(); if (!c) return 'NO_COMPOSE';
    caretEnd(c);
    const dt = new DataTransfer();
    for (const it of list) {
      const bin = atob(it.b64), u = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i);
      dt.items.add(new File([u], it.name, { type: 'image/png' }));
    }
    c.dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true }));
    return 'OK';
  },
  clickSend() {
    const b = sendButton(); if (!b) return 'NOT_FOUND';
    if (b.disabled || b.getAttribute('aria-disabled') === 'true') return 'DISABLED';
    b.click(); return 'CLICKED';
  },
  count(line) { return countText(line); }
};
return 'READY';
})()
'@



function Get-CdpTeamsUrl($teamsCfg) {
    $u = if ($teamsCfg -and $teamsCfg.cdp_url) { [string]$teamsCfg.cdp_url } else { $CdpDefaultTeamsUrl }
    if ($u -notmatch '^https?://') { throw "teams.cdp_url 必須是 http(s) 網址（目前：$u）" }
    return $u
}



# 啟動專用 Edge (edge_profile)；預設背景 (headless)，teams.cdp_headless = false 或 -Visible 時顯示視窗
function Start-TeamsCdpBrowser($teamsCfg, [switch]$Visible) {
    $headless = -not $Visible -and -not ($teamsCfg -and $teamsCfg.PSObject.Properties.Name -contains 'cdp_headless' -and $teamsCfg.cdp_headless -eq $false)
    Stop-ProfileEdge
    $argList = "--remote-debugging-port=$CdpTeamsPort --user-data-dir=`"$profileDir`" --no-first-run --disable-features=Translate,msEdgeTranslate --hide-crash-restore-bubble --disable-background-timer-throttling --disable-backgrounding-occluded-windows --disable-renderer-backgrounding --window-size=1600,1000"
    if ($headless) { $argList += ' --headless=new' }
    $ctx = @{ Headless = $headless; Id = 1; Ws = $null }
    $idRef = [ref]$ctx.Id
    # 背景模式隱藏啟動；顯示模式 (登入設定) 要讓使用者看到視窗
    $ctx.Ws = Start-ProfileEdgeCdp "$argList about:blank" $CdpTeamsPort $idRef -Hidden:$headless
    $ctx.Id = $idRef.Value
    # 只需要 Runtime.evaluate；關閉 Runtime 事件，避免 Teams 大量 console 訊息拖慢 CDP 讀取
    Invoke-TeamsCdp $ctx 'Runtime.disable' | Out-Null
    try { Invoke-TeamsCdp $ctx 'Emulation.setFocusEmulationEnabled' @{ enabled = $true } | Out-Null } catch {}
    if ($headless) {
        # 背景 Edge 的 User-Agent 帶有 Headless，Teams 可能視為不支援的瀏覽器；改回一般 Edge 的字串
        $idRef = [ref]$ctx.Id
        Set-NormalUserAgent $ctx.Ws $idRef
        $ctx.Id = $idRef.Value
    }
    Write-Host "🌐 [CDP] 已啟動$(if ($headless) { '背景 (不顯示視窗)' } else { '' }) Edge，準備開啟 Teams 網頁版" -ForegroundColor Gray
    return $ctx
}



function Invoke-TeamsCdp($ctx, [string]$method, [hashtable]$params = @{}, [int]$TimeoutSeconds = 60) {
    $id = $ctx.Id; $ctx.Id++
    $r = Invoke-CdpCommand $ctx.Ws $id $method $params $TimeoutSeconds
    if ($r.error) { throw "Edge 回報錯誤（$method）：$($r.error.message)" }
    return $r
}



# 執行網頁輔助函數；$call 例如 "state()"、"findChat(...)"
function Invoke-TeamsJs($ctx, [string]$call) {
    $id = $ctx.Id; $ctx.Id++
    $ready = Invoke-CdpEval $ctx.Ws $id $CdpTeamsJs
    if ($ready -ne 'READY') { throw "無法在 Teams 網頁執行檢查程式（$ready）" }
    $id = $ctx.Id; $ctx.Id++
    $r = Invoke-CdpCommand $ctx.Ws $id 'Runtime.evaluate' @{ expression = "window.__e3t.$call"; returnByValue = $true }
    if ($r.result.exceptionDetails) { throw "Teams 網頁檢查程式發生錯誤：$($r.result.exceptionDetails.exception.description)" }
    return $r.result.result.value
}



function Get-TeamsState($ctx) {
    try { return (Invoke-TeamsJs $ctx 'state()') | ConvertFrom-Json } catch { return $null }   # 換頁中暫時讀不到
}



function Close-TeamsCdpBrowser($ctx) {
    if (-not $ctx) { return }
    try { Close-CaptureBrowser $ctx.Ws } finally {
        if ($ctx.Ws) { $ctx.Ws.Dispose() }
        Stop-ProfileEdge
    }
}



# 開啟 Teams 網頁版並等到聊天介面可用；-AllowLogin 時遇到登入頁不報錯 (設定時讓使用者登入)
function Open-TeamsWeb($ctx, $teamsCfg, [switch]$AllowLogin, [int]$TimeoutSeconds = 120) {
    $url = Get-CdpTeamsUrl $teamsCfg
    $nav = Invoke-TeamsCdp $ctx 'Page.navigate' @{ url = $url }
    if ($nav.result.errorText) { throw "無法開啟 Teams 網頁版（$($nav.result.errorText)）" }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $last = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $st = Get-TeamsState $ctx
        if (-not $st) { continue }
        $last = $st
        if ($st.login) {
            if ($AllowLogin) { return 'LOGIN' }
            throw "Teams 尚未登入或登入已過期（目前在登入頁）：請在設定工具按「🔐 登入並檢查 CDP 傳送」重新登入"
        }
        if ($st.launcher) { Invoke-TeamsJs $ctx 'clickLauncher()' | Out-Null; continue }
        if ($st.ready -eq 'complete' -and ($st.items -gt 0 -or $st.chatNav -or $st.compose.found)) { return 'READY' }
    }
    $where = if ($last) { "目前網址 $($last.href)，標題「$($last.title)」" } else { '讀不到網頁狀態' }
    throw "Teams 網頁 $TimeoutSeconds 秒內沒有載入完成（$where）；若 Teams 顯示不支援此瀏覽器，請把 teams.cdp_headless 設為 false 改用顯示視窗"
}



# 在 Teams 網頁切換到對話：與桌面版相同規則，以聊天清單名稱點選，再以網頁標題的對話名稱完全相同確認
function Open-TeamsChatCdp($ctx, $chat) {
    $st = Get-TeamsState $ctx
    if ($st -and (Test-ChatTitle $st.title $chat)) { return }
    $src = if ($chat.Self) { '' } else { "^${ChatPrefix}?\s*$([regex]::Escape($chat.Name))(\s|$)" }
    $srcJson = ConvertTo-Json $src -Compress
    $nameJson = ConvertTo-Json ([string]$chat.Name) -Compress
    $selfJson = if ($chat.Self) { 'true' } else { 'false' }
    $clicked = $false
    # 第 1 輪：不在聊天畫面才點「聊天」，只找名稱完全相同；第 2 輪：點「聊天」、回到清單最上方，允許前綴比對
    foreach ($pass in 0, 1) {
        if ($pass -eq 1 -or -not $st -or $st.items -eq 0) {
            if ((Invoke-TeamsJs $ctx 'clickChatNav()') -eq 'CLICKED') {
                # 等聊天清單真的出現 (Teams 載入較慢時固定秒數不夠)，最多 20 秒
                for ($w = 0; $w -lt 20; $w++) { Start-Sleep -Seconds 1; $st = Get-TeamsState $ctx; if ($st -and $st.items -gt 0) { break } }
                Start-Sleep -Seconds 1
            }
        }
        $loose = if ($pass -eq 1) { 'true' } else { 'false' }
        Invoke-TeamsJs $ctx 'listTop()' | Out-Null
        Start-Sleep -Milliseconds 500
        for ($scroll = 0; $scroll -le 10 -and -not $clicked; $scroll++) {
            $r = Invoke-TeamsJs $ctx "findChat($srcJson, $nameJson, $selfJson, $loose)"
            if ($r -eq 'CLICKED') { $clicked = $true; break }
            if ($r -eq 'END') { break }
            Start-Sleep -Milliseconds 800
        }
        if ($clicked) { break }
        $st = Get-TeamsState $ctx
    }
    if (-not $clicked) { throw "Teams 網頁的聊天清單裡找不到「$($chat.Name)」：請確認名稱與 Teams 上顯示的一模一樣（建議把該對話加到「我的最愛」）" }
    for ($i = 0; $i -lt 30; $i++) {
        Start-Sleep -Milliseconds 500
        $st = Get-TeamsState $ctx
        if ($st -and (Test-ChatTitle $st.title $chat)) { return }
    }
    throw "已點選「$($chat.Name)」，但 Teams 網頁標題沒有變成該對話（目前：$(if ($st) { $st.title })），為避免傳錯已停止"
}



function Wait-TeamsCompose($ctx, $chat, [int]$TimeoutSeconds = 30) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $st = Get-TeamsState $ctx
        if ($st -and $st.compose.found) {
            if (-not (Test-ChatTitle $st.title $chat)) { throw "Teams 網頁已不在「$($chat.Name)」對話，已停止" }
            return $st
        }
        Start-Sleep -Milliseconds 700
    }
    throw "找不到「$($chat.Name)」的「輸入訊息」框（$TimeoutSeconds 秒），已停止"
}



function Confirm-TeamsChatCdp($ctx, $chat) {
    $st = Get-TeamsState $ctx
    if (-not $st -or -not (Test-ChatTitle $st.title $chat)) { throw "Teams 網頁已不在「$($chat.Name)」對話（目前：$(if ($st) { $st.title })），已停止，尚未送出的內容留在輸入框" }
    return $st
}



# 輸入文字：每行以 Input.insertText 輸入，行與行之間按 Shift+Enter 換行 (Enter 會直接送出)
function Add-TeamsTextCdp($ctx, [string]$text) {
    if ((Invoke-TeamsJs $ctx 'focusEnd()') -ne 'OK') { throw "無法把游標移到 Teams 輸入框，已停止" }
    $lines = $text -split "`r?`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i]) { Invoke-TeamsCdp $ctx 'Input.insertText' @{ text = $lines[$i] } | Out-Null }
        if ($i -lt $lines.Count - 1) {
            Invoke-TeamsCdp $ctx 'Input.dispatchKeyEvent' @{ type = 'keyDown'; key = 'Enter'; code = 'Enter'; windowsVirtualKeyCode = 13; nativeVirtualKeyCode = 13; modifiers = 8; text = "`r"; unmodifiedText = "`r" } | Out-Null
            Invoke-TeamsCdp $ctx 'Input.dispatchKeyEvent' @{ type = 'keyUp'; key = 'Enter'; code = 'Enter'; windowsVirtualKeyCode = 13; nativeVirtualKeyCode = 13; modifiers = 8 } | Out-Null
        }
    }
}



# 清空目標對話的輸入框：選取全部內容後以 CDP 按 Backspace (由 Teams 編輯器自己刪除)，最多試 3 次。
# 先確認仍在目標對話，不會清到別的對話；回傳是否已清空。
function Clear-TeamsComposeCdp($ctx, $chat) {
    for ($try = 0; $try -lt 3; $try++) {
        $st = Confirm-TeamsChatCdp $ctx $chat
        if ($st.compose.images -eq 0 -and $st.compose.text -eq 0) { return $true }
        if ((Invoke-TeamsJs $ctx 'selectAll()') -ne 'OK') { return $false }
        foreach ($type in 'keyDown', 'keyUp') {
            Invoke-TeamsCdp $ctx 'Input.dispatchKeyEvent' @{ type = $type; key = 'Backspace'; code = 'Backspace'; windowsVirtualKeyCode = 8; nativeVirtualKeyCode = 8 } | Out-Null
        }
        Start-Sleep -Milliseconds 800
    }
    $st = Confirm-TeamsChatCdp $ctx $chat
    return ($st.compose.images -eq 0 -and $st.compose.text -eq 0)
}



function Send-GroupToTeamsCdp([string]$targetChatName, [string[]]$imageFiles, [string]$messageText, $teamsCfg, [bool]$isDryRun) {
    if ([string]::IsNullOrWhiteSpace($messageText)) { throw "總結文字是空的，未貼上任何內容" }
    $chat = Resolve-ChatTarget $targetChatName
    # 先檢查全部圖片再開 Teams，避免傳到一半才發現壞檔
    $entries = @(foreach ($f in @($imageFiles)) {
        if (-not (Test-Path -LiteralPath $f)) { throw "找不到要傳送的圖片：$f" }
        $item = Get-Item -LiteralPath $f
        $head = [byte[]]::new(8); $fs = [IO.File]::OpenRead($item.FullName); try { [void]$fs.Read($head, 0, 8) } finally { $fs.Dispose() }
        if ($head[0] -ne 0x89 -or $head[1] -ne 0x50 -or $head[2] -ne 0x4E -or $head[3] -ne 0x47) { throw "不是 PNG 圖片：$($item.Name)" }
        @{ path = $item.FullName; size = $item.Length }
    })
    $plan = @(Split-TeamsImageBatches $entries)

    $ctx = $null
    try {
        $ctx = Start-TeamsCdpBrowser $teamsCfg
        Open-TeamsWeb $ctx $teamsCfg | Out-Null
        Open-TeamsChatCdp $ctx $chat
        $st = Wait-TeamsCompose $ctx $chat
        Write-Host "💬 [CDP] 已開啟對話：$($chat.Name)（網頁標題：$($st.title)）" -ForegroundColor Cyan
        # 專用 Edge 只有本程式使用，輸入框裡的內容是先前傳送中斷留下的 (不在使用者平常的 Teams，關掉重開 Teams 也不會消失)。
        # 正式傳送前先清除，再送這次的圖文 (不會重送舊內容)；測試模式只回報、不清除。
        if ($st.compose.images -gt 0 -or $st.compose.text -gt 0) {
            $left = "$($st.compose.images) 張圖片、$($st.compose.text) 個字"
            if ($isDryRun) {
                Write-Host "⚠️ [CDP -> $($chat.Name)] 輸入框有上次中斷留下的內容（$left），正式傳送時會先清除" -ForegroundColor Yellow
            } else {
                Write-Host "🧹 [CDP -> $($chat.Name)] 輸入框有上次中斷留下的內容（$left），先清除再傳送這次的圖文" -ForegroundColor Yellow
                if (-not (Clear-TeamsComposeCdp $ctx $chat)) {
                    throw "「$($chat.Name)」的輸入框有上次中斷留下的內容，無法自動清除：請按「🔐 登入並檢查 CDP 傳送」，在開啟的 Edge 進入該對話刪除輸入框內容後再試"
                }
            }
        }
        if ($isDryRun) {
            Write-Host "⏸️ [CDP -> $($chat.Name)] 已確認對話與輸入框（共 $($entries.Count) 張圖、$($plan.Count) 批），測試模式不貼上、不送出" -ForegroundColor Yellow
            return
        }

        # $dirty：本次已貼上、尚未送出的內容；$sendPressed：已按傳送但還沒確認輸入框清空
        $dirty = $false; $sendPressed = $false
        try {
        for ($b = 0; $b -lt $plan.Count; $b++) {
            $batch = @($plan[$b].Items)
            $batchText = Get-TeamsBatchText $messageText ($b + 1) $plan.Count
            # 圖片逐張貼上，每張確認出現在輸入框後再貼下一張
            foreach ($img in $batch) {
                $st = Confirm-TeamsChatCdp $ctx $chat
                $want = $st.compose.images + 1
                $payload = ConvertTo-Json @(@{ name = [IO.Path]::GetFileName($img.path); b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($img.path)) }) -Compress
                Write-Host "📋 [CDP -> $($chat.Name)] 正在貼上圖片: $([IO.Path]::GetFileName($img.path))" -ForegroundColor Gray
                $dirty = $true
                if ((Invoke-TeamsJs $ctx "paste($payload)") -ne 'OK') { throw "找不到 Teams 輸入框，無法貼上圖片" }
                $deadline = (Get-Date).AddSeconds(60)
                do { Start-Sleep -Milliseconds 700; $st = Confirm-TeamsChatCdp $ctx $chat } while ($st.compose.images -lt $want -and (Get-Date) -lt $deadline)
                if ($st.compose.images -lt $want) { throw "圖片 $([IO.Path]::GetFileName($img.path)) 60 秒內沒有出現在 Teams 輸入框，已停止 (未送出)" }
            }
            # 等這一批圖片都載入完成 (連續 3 次確認)，Teams 上傳中就送出會變成破圖
            $stable = 0; $deadline = (Get-Date).AddSeconds(90)
            while ($stable -lt 3 -and (Get-Date) -lt $deadline) {
                Start-Sleep -Seconds 1
                $st = Confirm-TeamsChatCdp $ctx $chat
                if ($st.compose.images -eq $batch.Count -and $st.compose.loaded -eq $batch.Count) { $stable++ } else { $stable = 0 }
            }
            if ($stable -lt 3) { throw "90 秒內只有 $($st.compose.loaded)/$($batch.Count) 張圖片載入完成，已停止 (未送出)" }

            Add-TeamsTextCdp $ctx $batchText
            Start-Sleep -Milliseconds 500
            $st = Confirm-TeamsChatCdp $ctx $chat
            if ($st.compose.text -eq 0) { throw "總結文字沒有出現在 Teams 輸入框，已停止 (未送出)" }
            Write-Host "🔎 [CDP] 輸入框已有 $($st.compose.images) 張圖片與總結文字" -ForegroundColor DarkGray

            if ($teamsCfg.auto_press_enter -eq $false) {
                Write-Host "⏸️ [CDP -> $($chat.Name)] auto_press_enter=false：已貼上圖文但不送出；內容留在專用 Edge 的 Teams 輸入框，下次傳送時會先清除" -ForegroundColor Yellow
                $dirty = $false
                return
            }
            $firstLine = (($batchText -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 1)
            $before = [int](Invoke-TeamsJs $ctx "count($(ConvertTo-Json ([string]$firstLine) -Compress))")
            $sendPressed = $true
            $click = Invoke-TeamsJs $ctx 'clickSend()'
            if ($click -ne 'CLICKED') {
                # 找不到或按鈕停用時改按 Ctrl+Enter (Teams 的送出快捷鍵)
                foreach ($type in 'keyDown', 'keyUp') {
                    Invoke-TeamsCdp $ctx 'Input.dispatchKeyEvent' @{ type = $type; key = 'Enter'; code = 'Enter'; windowsVirtualKeyCode = 13; nativeVirtualKeyCode = 13; modifiers = 2 } | Out-Null
                }
            }
            $sent = $false
            for ($i = 0; $i -lt 30 -and -not $sent; $i++) {
                Start-Sleep -Seconds 1
                $st = Confirm-TeamsChatCdp $ctx $chat
                $sent = $st.compose.found -and $st.compose.images -eq 0 -and $st.compose.text -eq 0
            }
            if (-not $sent) { throw "按下傳送後 Teams 輸入框沒有清空，訊息可能沒有送出，請到 Teams 確認（不會自動重送）" }
            $dirty = $false; $sendPressed = $false
            $confirmed = $false
            for ($i = 0; $i -lt 15 -and -not $confirmed; $i++) {
                $confirmed = [int](Invoke-TeamsJs $ctx "count($(ConvertTo-Json ([string]$firstLine) -Compress))") -gt $before
                if (-not $confirmed) { Start-Sleep -Seconds 1 }
            }
            $note = if ($confirmed) { '（已在聊天記錄看到這則訊息）' } else { '（輸入框已清空；聊天記錄未讀到新訊息，請到 Teams 確認）' }
            Write-Host "✅ [CDP -> $($chat.Name)] 已送出第 $($b + 1)/$($plan.Count) 則訊息 $note" -ForegroundColor Green
            Start-Sleep -Seconds 2
        }
        } catch {
            # 還沒按傳送就失敗：清掉本次貼上的內容，下次排程才不會因殘留內容停住。
            # 已按傳送但無法確認時不動 (可能正在送出)，下次傳送開始時會再清除。
            if ($dirty -and -not $sendPressed) {
                try {
                    if (Clear-TeamsComposeCdp $ctx $chat) { Write-Host "🧹 [CDP -> $($chat.Name)] 已清除本次未送出的內容" -ForegroundColor DarkGray }
                    else { Write-Host "⚠️ [CDP -> $($chat.Name)] 無法清除本次未送出的內容，下次傳送時會再清除" -ForegroundColor Yellow }
                } catch { Write-Host "⚠️ [CDP -> $($chat.Name)] 無法清除本次未送出的內容（$($_.Exception.Message)），下次傳送時會再清除" -ForegroundColor Yellow }
            }
            throw
        }
    } finally {
        Close-TeamsCdpBrowser $ctx
    }
}



# 設定中所有會用到的發送對象 (預設、啟用排程的改送對象、舊版頁面層級)
function Get-CdpTargets($cfg) {
    $names = @()
    if ($cfg.teams.target_chat_name) { $names += [string]$cfg.teams.target_chat_name }
    foreach ($s in @(Get-ScheduleList $cfg | Where-Object { $_.enabled -ne $false -and $_.target_chat_name })) { $names += [string]$s.target_chat_name }
    foreach ($p in @($cfg.pages | Where-Object { $_.target_chat_name })) { $names += [string]$p.target_chat_name }
    return @($names | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
}



# 開啟每個發送對象的對話，確認名稱、輸入框與草稿；不貼上、不送出
function Test-TeamsTargetsCdp($ctx, $cfg) {
    $out = @()
    foreach ($t in (Get-CdpTargets $cfg)) {
        try {
            $chat = Resolve-ChatTarget $t
            Open-TeamsChatCdp $ctx $chat
            $st = Wait-TeamsCompose $ctx $chat
            $draft = if ($st.compose.images -gt 0 -or $st.compose.text -gt 0) { '⚠️ 輸入框有上次中斷留下的內容，下次傳送時會自動清除' } else { '輸入框空白' }
            $out += "  ✅ 發送對象「$($chat.Name)」：找到對話（標題：$(Get-ChatNameFromTitle $st.title)）、$draft"
        } catch {
            $out += "  ❌ 發送對象「$t」：$($_.Exception.Message)"
        }
    }
    if (-not $out.Count) { $out += '  ⚠️ 設定中沒有任何發送對象' }
    return $out
}



# 設定工具服務與排程共用的執行鎖：檢查／設定期間不和排程搶用 edge_profile
function Enter-CdpRunLock {
    $m = New-Object System.Threading.Mutex($false, "Local\E3MonitorNativeRun")
    $has = $false
    try { $has = $m.WaitOne([TimeSpan]::FromSeconds(10)) } catch [System.Threading.AbandonedMutexException] { $has = $true }
    if (-not $has) { $m.Dispose(); throw "排程或抓圖正在使用專用 Edge，請稍後再試" }
    return $m
}



# -DetectTeams (CDP 模式)：背景開啟 Teams 網頁版，確認登入與每個發送對象，不貼上、不送出
function Test-E3CdpConnection($cfg) {
    $lines = @("🔍 CDP 背景傳送檢查  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $lock = Enter-CdpRunLock
    $ctx = $null
    try {
        $ctx = Start-TeamsCdpBrowser $cfg.teams
        $lines += "  專用 Edge：$profileDir（$(if ($ctx.Headless) { '背景執行，不顯示視窗' } else { '顯示視窗 (teams.cdp_headless=false)' })）"
        Open-TeamsWeb $ctx $cfg.teams | Out-Null
        $lines += "  ✅ Teams 網頁版已登入：$(Get-CdpTeamsUrl $cfg.teams)"
        $lines += @(Test-TeamsTargetsCdp $ctx $cfg)
    } catch {
        $lines += "  ❌ $($_.Exception.Message)"
    } finally {
        Close-TeamsCdpBrowser $ctx
        $lock.ReleaseMutex(); $lock.Dispose()
    }
    return $lines
}



# -CdpSetup / setup_cdp.bat / 設定工具「🔐 登入並檢查 CDP 傳送」：
# 顯示 Edge 讓使用者在專用 edge_profile 登入 Teams 網頁版，再檢查每個發送對象，最後確認背景模式能沿用登入
function Set-E3CdpBinding($cfg) {
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host "🔐 CDP 背景傳送：登入 Teams 網頁版並檢查發送對象（不會傳送任何訊息）" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    $lock = Enter-CdpRunLock
    $ctx = $null
    try {
        $ctx = Start-TeamsCdpBrowser $cfg.teams -Visible
        $state = Open-TeamsWeb $ctx $cfg.teams -AllowLogin -TimeoutSeconds 180
        if ($state -eq 'LOGIN') {
            Write-Host "👉 請在開啟的 Edge 視窗登入 Teams（出現「保持登入？」請選「是」），看到聊天畫面後回到這個視窗按 Enter。" -ForegroundColor Yellow
        } else {
            Write-Host "✅ Teams 網頁版已登入。若要換帳號，請在 Edge 視窗登出後重新登入，完成後按 Enter。" -ForegroundColor Green
        }
        [void](Read-Host '完成後按 Enter 繼續檢查')
        Open-TeamsWeb $ctx $cfg.teams | Out-Null
        Write-Host "✅ 已確認登入，開始檢查發送對象..." -ForegroundColor Green
        Test-TeamsTargetsCdp $ctx $cfg | ForEach-Object { Write-Host $_ }
    } catch {
        Write-Host "❌ $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        Close-TeamsCdpBrowser $ctx
    }
    try {
        $wantHeadless = -not ($cfg.teams.PSObject.Properties.Name -contains 'cdp_headless' -and $cfg.teams.cdp_headless -eq $false)
        if ($wantHeadless) {
            Write-Host "`n🔎 確認背景 (headless) Edge 能沿用剛才的登入..." -ForegroundColor Cyan
            $ctx = Start-TeamsCdpBrowser $cfg.teams
            Open-TeamsWeb $ctx $cfg.teams | Out-Null
            Write-Host "✅ 背景模式可以使用 Teams（鎖定、螢幕關閉時也會用這個模式傳送）" -ForegroundColor Green
        }
    } catch {
        Write-Host "❌ 背景模式無法使用 Teams：$($_.Exception.Message)" -ForegroundColor Red
        Write-Host "   可在 config.json 的 teams 加上 `"cdp_headless`": false 改用顯示視窗的 Edge（鎖定時能否傳送需實測）" -ForegroundColor Yellow
    } finally {
        Close-TeamsCdpBrowser $ctx
        $lock.ReleaseMutex(); $lock.Dispose()
    }
}
