(() => {
  // Bring the receiver's single work tab to one bound chat without reloading Teams.
  // Clicks only a uniquely named chat-list item; the caller re-verifies the chat ID
  // and falls back to the chat link whenever this script answers {reopen:true}.
  const binding = /*E3_BINDING*/null;
  if (!binding?.accountId || !binding?.chatId || !binding?.label) return {ok:false,fatal:true,error:'接收來源綁定不完整'};
  const clean = value => String(value || '').replace(/[\u200b-\u200d\u2060\ufeff]/g, '').replace(/\u00a0/g, ' ').replace(/\s+/g, ' ').trim();
  const visible = node => !!node?.isConnected && node.getClientRects().length > 0;
  const login = /(^|\.)login\.(microsoftonline|live|microsoft)\.com$|(^|\.)account\.live\.com$/i.test(location.hostname)
    || [...document.querySelectorAll('input[type="password"]')].some(visible);
  if (login) return {ok:false,login:true,error:'Teams 登入已過期或需要互動驗證'};
  if (!['teams.cloud.microsoft', 'teams.microsoft.com'].includes(location.hostname)) return {ok:false,reopen:true,error:'工作分頁目前不在 Teams'};
  const state = globalThis.__E3ReceiverSwitch || (globalThis.__E3ReceiverSwitch = {chatId:'',at:0});
  const current = BridgeAdapter.inspect(document, location.href, binding);
  if (!current.ok && current.error === 'GROUP_REPORT_ACCOUNT_NOT_VERIFIED')
    return {ok:false,reauth:true,error:current.error};
  if (current.ok && BridgeAdapter.sameBinding(current.binding, binding)) {
    state.chatId = '';
    if (current.binding.label !== binding.label) return {ok:false,fatal:true,error:'對話名稱與保存的綁定不同，請重新執行 setup_teams_receiver.bat 綁定'};
    return {ok:true,ready:true};
  }
  if (state.chatId === binding.chatId) {
    // One click per request; then only wait for Teams to show the requested chat.
    if (Date.now() - state.at < 6000) return {ok:true,ready:false,stage:'waiting'};
    state.chatId = '';
    return {ok:false,reopen:true,error:'點選聊天清單後沒有切換到綁定的對話'};
  }
  const wanted = clean(binding.label);
  const matches = [...document.querySelectorAll('[role="treeitem"]')].filter(visible)
    .filter(node => clean((node.innerText || '').split('\n')[0]) === wanted || clean(node.getAttribute('aria-label')) === wanted);
  if (matches.length > 1) return {ok:false,reopen:true,error:'聊天清單有多個同名對話'};
  if (!matches.length) return {ok:false,reopen:true,error:'聊天清單目前看不到此對話'};
  state.chatId = binding.chatId;
  state.at = Date.now();
  matches[0].scrollIntoView({block:'nearest'});
  matches[0].click();
  return {ok:true,ready:false,stage:'clicked'};
})();
