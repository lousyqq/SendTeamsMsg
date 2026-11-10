(() => {
  const binding = /*E3_BINDING*/null;
  if (!binding?.accountId || !binding?.chatId || !binding?.label) return {ok:false,error:'接收來源綁定不完整'};
  BridgeAdapter.followLatest(document, binding);
  const snapshot = BridgeAdapter.snapshot(document, location.href, binding);
  if (!snapshot.ok) return {ok:false,error:snapshot.error};
  const rows = [...document.querySelectorAll('[data-message-id], [data-mid], [data-tid="chat-pane-message"]')];
  const pending = row => /pending|sending|failed|error/i.test(
    [row.getAttribute('data-message-status'), row.getAttribute('data-status'),
     row.querySelector('[data-tid*="sending"], [data-tid*="failed"], [data-tid*="retry"]') ? 'pending' : ''].join(' '));
  return {
    ok:true, latest:BridgeAdapter.atLatest(document),
    ids:snapshot.messages.map(m=>m.id),
    commands:snapshot.messages.filter(m=>{
      const text=m.text.replace(/\u00a0/g,' ').trim();
      return text.length<=400 && /^@日管 +(?=\S)/u.test(text) && !m.images?.length;
    }).filter(m=>{
      const matches=rows.filter(row=>(row.getAttribute('data-message-id') || row.getAttribute('data-mid') || row.id)===m.id);
      return matches.length===1 && !pending(matches[0]) && !matches[0].querySelector('blockquote,[data-tid*="quoted-reply"]');
    }).map(m=>({id:m.id,time:m.time,text:m.text.trim()}))
  };
})();
