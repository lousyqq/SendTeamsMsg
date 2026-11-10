// Navigation only; strict account/chat self proof runs afterwards in the isolated world.
(() => {
  const clean = v => String(v || '').replace(/\s+/g, ' ').trim();
  if (!['teams.cloud.microsoft', 'teams.microsoft.com'].includes(location.hostname)) return {stage:'等待 Teams 登入'};
  const visible = n => n.getClientRects().length > 0;
  const buttons = [...document.querySelectorAll('button,[role="button"]')].filter(visible);
  const web = buttons.filter(n => /^(改用網頁|使用網頁版|(?:改用|使用)\s*Web\s*應用程式|Use the web app|Continue on this browser|在此瀏覽器上繼續)/i.test(clean(n.innerText || n.getAttribute('aria-label'))));
  if (web.length === 1) { web[0].click(); return {stage:'開啟網頁版'}; }
  const heads = [...document.querySelectorAll('[data-tid="chat-header"], [data-tid="chat-header-bar"], [data-tid="entity-header"]')].filter(visible);
  const self = /[（(]\s*(您|你|自己|you)\s*[）)]\s*$/i;
  const panes = document.querySelectorAll('[data-tid="chat-pane"], [data-tid="chat-pane-layout"], [data-tid="message-pane-layout"]');
  const title = heads.length === 1 ? clean(heads[0].querySelector('[data-tid="chat-header-title"], [data-tid="entity-header-title"], [data-tid="chat-title"]')?.textContent || heads[0].getAttribute('aria-label') || heads[0].innerText) : '';
  if (heads.length === 1 && panes.length && (self.test(title) || heads[0].getAttribute('data-is-self-chat') === 'true' || heads[0].querySelector('[data-tid="self-chat-indicator"], [data-tid="note-to-self"]'))) return {ready:true};
  const items = [...document.querySelectorAll('[role="treeitem"]')].filter(visible);
  const matches = items.filter(n => self.test(clean((n.innerText || '').split('\n')[0])) || self.test(clean(n.getAttribute('aria-label'))));
  if (matches.length > 1) return {error:'找到多個本人標記對話，無法唯一辨識，已停止。'};
  const state = globalThis.__e3SelfNavigation || (globalThis.__e3SelfNavigation = {});
  if (matches.length === 1 && !state.clicked) { state.clicked = true; matches[0].click(); return {stage:'確認自己對話'}; }
  const nav = buttons.filter(n => /^(Chat|聊天)(\s|\(|$)/i.test(clean(n.getAttribute('aria-label') || n.innerText)));
  if (!state.nav && !state.clicked && nav.length === 1) { state.nav = true; nav[0].click(); }
  return {stage:'尋找自己對話'};
})();
 