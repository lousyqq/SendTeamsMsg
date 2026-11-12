(() => {
  const binding = /*E3_BINDING*/null;
  if (!binding?.accountId || !binding?.chatId || !binding?.label) return {ok:false,error:'接收來源綁定不完整'};
  // The receiver owns a dedicated chat tab. Keep it at the live edge without
  // focusing the editor, sending keys, or using the sender's history-follow state.
  const context = BridgeAdapter.inspect(document, location.href, binding);
  if (!context.ok || !BridgeAdapter.sameBinding(context.binding, binding)
      || context.binding.label !== binding.label) {
    return {ok:false,latest:false,error:context.error || '接收對話與保存綁定不一致'};
  }
  const root = context.root;
  const rowSelector = '[data-message-id], [data-mid], [data-tid="chat-pane-message"]';
  const listSelector = '[data-tid="chat-message-list"], [data-tid="message-pane-list-viewport"]';
  const visible = node => node.getClientRects().length > 0
    && getComputedStyle(node).visibility !== 'hidden' && getComputedStyle(node).display !== 'none';
  const lists = [...root.querySelectorAll(listSelector)].filter(visible);
  const candidates = new Set();
  for (const list of lists) {
    for (let node = list; node && root.contains(node); node = node.parentElement) {
      if (!node.clientHeight || !node.querySelector(rowSelector)) continue;
      if (/^(auto|scroll)$/.test(getComputedStyle(node).overflowY)) candidates.add(node);
    }
  }
  // A non-overflowing list is already at its end. Do not guess an unrelated
  // scroller when Teams changes markup or has multiple independent viewports.
  if (!candidates.size) {
    for (const list of lists) {
      if (list.clientHeight && list.querySelector(rowSelector)) candidates.add(list);
    }
  }
  const deepest = [...candidates].filter(node => ![...candidates].some(other => other !== node && node.contains(other)));
  if (deepest.length !== 1) return {ok:false,latest:false,error:'接收端無法唯一辨識訊息捲動區，請確認專用分頁仍在綁定對話'};
  const list = deepest[0];
  const style = getComputedStyle(list);
  const reverse = style.display.includes('flex') && style.flexDirection === 'column-reverse';
  const end = reverse ? 0 : Math.max(0, list.scrollHeight - list.clientHeight);
  const before = list.scrollTop;
  const jumps = [...root.querySelectorAll('[data-tid="jump-to-latest"], [data-tid="jump-to-latest-button"]')].filter(visible);
  if (jumps.length > 1) return {ok:false,latest:false,error:'接收端找到多個回到最新訊息按鈕，暫停操作'};
  const state = globalThis.__E3ReceiverViewport || (globalThis.__E3ReceiverViewport = {jumpAt:0});
  if (jumps.length === 1 && Date.now() - state.jumpAt >= 2000
      && !jumps[0].disabled && jumps[0].getAttribute('aria-disabled') !== 'true') {
    state.jumpAt = Date.now();
    jumps[0].click();
    // The click can grow or replace a virtualized list synchronously. Never
    // restore the pre-click end offset; doing so could move the new live edge up.
    return {ok:true,latest:false,ids:[],commands:[],error:'已要求回到最新訊息，等待對話重新載入'};
  }
  // Do not act on a stale element if a jump synchronously replaced the list.
  if (!list.isConnected) return {ok:true,latest:false,ids:[],commands:[],error:'已要求回到最新訊息，等待對話重新載入'};
  if (Math.abs(before - end) > 2) list.scrollTo({top:end,left:list.scrollLeft,behavior:'instant'});
  const distance = Math.abs(list.scrollTop - (reverse ? 0 : Math.max(0, list.scrollHeight - list.clientHeight)));
  const viewport = {version:'receiver-latest2',reverse,top:list.scrollTop,height:list.scrollHeight,clientHeight:list.clientHeight,distance};
  // Wait for another poll after movement/jump, so a virtualized history row can
  // never become a command merely because its old viewport was moved down.
  if (Math.abs(before - end) > 2 || distance > 2 || jumps.some(visible)) {
    return {ok:true,latest:false,ids:[],commands:[],viewport,error:'已要求回到最新訊息，等待畫面穩定'};
  }
  // Rows are read here, not through BridgeAdapter.snapshot: that reader stops at the
  // first row it cannot fully parse (cards, call records, deleted messages), which
  // would silence the whole chat. A row that cannot be parsed can never become a
  // command, so it is skipped and counted; a command row is still parsed strictly
  // (unique id, exactly one body, one full timestamp with time zone).
  const bodySelector = '[data-tid="message-body"], [data-tid="chat-pane-message-content"], [data-message-content]';
  const emojiSelector = '[data-emoji], [data-tid*="emoji"], [class*="emoji"], [class*="emoticon"]';
  const rowId = row => row.getAttribute('data-message-id') || row.getAttribute('data-mid') || row.id || '';
  const pending = row => /pending|sending|failed|error/i.test(
    [row.getAttribute('data-message-status'), row.getAttribute('data-status'),
     row.querySelector('[data-tid*="sending"], [data-tid*="failed"], [data-tid*="retry"]') ? 'pending' : ''].join(' '));
  const readTime = row => {
    let times = [...row.querySelectorAll('time[datetime]')];
    if (!times.length && !row.getAttribute('data-timestamp')) {
      const item = row.closest('[data-tid="chat-pane-item"]');
      // The tenant timestamp is a sibling. Never reuse one from a grouped second message.
      const siblings = item && [...item.querySelectorAll(rowSelector)].filter(node => !node.parentElement?.closest(rowSelector));
      if (siblings?.length === 1 && siblings[0] === row) times = [...item.querySelectorAll('time[datetime]')];
    }
    if (times.length > 1) return null;
    const stamp = times[0]?.getAttribute('datetime') || row.getAttribute('data-timestamp');
    if (!stamp) return null;
    const epoch = /^(?:\d{10}|\d{13})$/.test(stamp);
    if (!epoch && !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(stamp)) return null;
    const date = new Date(epoch ? Number(stamp) * (stamp.length === 10 ? 1000 : 1) : stamp);
    return Number.isNaN(date.getTime()) ? null : date.toISOString();
  };
  const rows = [...root.querySelectorAll(rowSelector)].filter(row => !row.parentElement?.closest(rowSelector));
  const seen = new Map();
  for (const row of rows) { const id = rowId(row); if (id) seen.set(id, (seen.get(id) || 0) + 1); }
  const ids = [], commands = [];
  let skipped = 0;
  for (const row of rows) {
    const id = rowId(row);
    if (!id || seen.get(id) !== 1) { skipped++; continue; }
    ids.push(id);
    const bodies = [...row.querySelectorAll(bodySelector)].filter(node => !node.parentElement?.closest(bodySelector));
    const time = readTime(row);
    if (bodies.length !== 1 || !time) { skipped++; continue; }
    const body = bodies[0];
    const text = String(body.innerText || body.textContent || '').replace(/\r\n?/g, '\n').replace(/\u00a0/g, ' ').trim();
    // Candidates only; the PowerShell side decides (a space or a known command word must follow).
    if (text.length > 400 || !/^@日管[ 　]*\S/u.test(text)) continue;
    // Commands are plain text: no picture, quote or unsent state.
    if ([...body.querySelectorAll('img')].some(image => !image.closest(emojiSelector)) || body.querySelector('inlineimage, [data-inline-image]')) continue;
    if (pending(row) || row.querySelector('blockquote,[data-tid*="quoted-reply"]')) continue;
    commands.push({id, time, text});
  }
  return {ok:true, latest:true, viewport, skipped, ids, commands};
})();
