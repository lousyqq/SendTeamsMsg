/* Local work choices. No action is submitted until a user clicks a button. */
(() => {
  'use strict';
  const base = location.protocol === 'http:' && location.hostname === '127.0.0.1' ? location.origin : 'http://127.0.0.1:8765';
  let requests = [], dialogState = null, selfChoosing = false, polling = false;
  const dismissed = new Set();
  const panel = document.createElement('details');
  panel.id = 'workWaitPanel'; panel.hidden = true;
  panel.style.cssText = 'position:fixed;right:20px;bottom:20px;z-index:2000;max-width:min(440px,90vw);padding:12px;background:#162132;color:#edf5ff;border:1px solid #32bcff;border-radius:8px;box-shadow:0 4px 20px #0007';
  const summary = document.createElement('summary'), list = document.createElement('div');
  panel.append(summary, list); document.body.append(panel);
  async function request(path, body) {
    const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 8000);
    try {
      const response = await fetch(base + path, {cache:'no-store', signal:controller.signal,
        ...(body ? {method:'POST', headers:{'Content-Type':'application/json'}, body:JSON.stringify(body)} : {})});
      const data = await response.json();
      if (!response.ok) throw Error(data.error || data.message || '暫時無法取得工作狀態');
      return data;
    } finally { clearTimeout(timer); }
  }
  function makeDialog(owner, incoming, canReplace, cooperative = false) {
    const d = document.createElement('dialog'); d.id = 'workChoiceDialog';
    d.setAttribute('aria-labelledby','workChoiceTitle');
    d.style.cssText = 'margin:auto;width:min(620px,calc(100vw - 40px));max-height:85vh;overflow:auto;padding:24px;box-sizing:border-box;border:2px solid #32bcff;border-radius:12px;background:#162132;color:#edf5ff;font:15px/1.6 system-ui';
    d.innerHTML = `<style>#workChoiceDialog::backdrop{background:#0009}#workChoiceDialog button{padding:9px 12px}#workChoiceDialog button:disabled{opacity:.5}</style>
      <h2 id="workChoiceTitle" style="margin-top:0">工作正在執行，要如何處理？</h2>
      <div data-role="owner" style="white-space:pre-wrap;overflow-wrap:anywhere"></div>
      <div data-role="incoming" style="white-space:pre-wrap;overflow-wrap:anywhere;margin-top:8px"></div>
      <p data-role="note">強制停止不會撤回已送出的訊息。確認前一工作停止並釋放操作權後，才會執行新的。</p>
      <p data-role="status" role="status" style="white-space:pre-wrap;color:#ffd778"></p>
      <div style="display:flex;gap:8px;flex-wrap:wrap;justify-content:flex-end">
        <button type="button" data-role="cancel">取消本次新工作</button>
        <button type="button" data-role="wait" autofocus>繼續等待</button>
        <button type="button" data-role="replace">強制停止前一工作，執行新的</button>
      </div>`;
    const part = role => d.querySelector(`[data-role="${role}"]`);
    part('owner').textContent = '目前工作：' + owner;
    part('incoming').textContent = '新工作：' + incoming;
    part('replace').disabled = !canReplace;
    if (!canReplace) part('note').textContent = '目前無法確認占用者，不能強制中止未知程序。請關閉舊版工具並使用更新版本，再重新查詢。';
    if (cooperative) part('note').textContent = '將要求停止接收端目前的回覆，保留接收程式繼續待命；已送出的訊息不會撤回。確認操作權釋放後才執行新的。';
    document.body.append(d); d.showModal();
    return {dialog:d, part, close(){d.close();d.remove();}};
  }
  function showWait(item) {
    if (dialogState || selfChoosing) return;
    const ui = makeDialog(item.ownerDescription, item.description, item.canReplace, item.ownerMode === 'cooperative');
    const current = {id:item.id, token:item.token, ui, submitting:false}; dialogState = current;
    const elapsed = Math.max(0, Math.floor((Date.now() - Date.parse(item.createdUtc)) / 1000));
    ui.part('status').textContent = `已等待 ${elapsed} 秒。未選擇時不會強制停止；目前等待期限為 ${new Date(item.expiresUtc).toLocaleTimeString()}。`;
    const decide = async decision => {
      if (dialogState !== current || current.submitting) return;
      current.submitting = true;
      ui.dialog.querySelectorAll('button').forEach(b => b.disabled = true);
      ui.part('status').textContent = '正在提交你的選擇…';
      try {
        await request('/api/work-decision', {id:item.id,token:item.token,ownerId:item.ownerId,decision});
        dismissed.add(item.id + ':' + item.token); ui.close(); dialogState = null;
        await poll();
      } catch (error) {
        if (dialogState !== current) return;
        ui.part('status').textContent = '正在查詢是否已收到選擇：' + error.message;
        current.submitting = false;
        ui.part('cancel').disabled = ui.part('wait').disabled = false;
        ui.part('replace').disabled = !item.canReplace;
        // Same token is idempotent; never create or send a new command here.
      }
    };
    for (const decision of ['wait','replace','cancel']) ui.part(decision).onclick = () => decide(decision);
    ui.dialog.addEventListener('cancel', e => {e.preventDefault();decide('wait');});
  }
  async function poll() {
    if (polling) return; polling = true;
    try {
      requests = await request('/api/work-waits');
      if (!Array.isArray(requests)) throw Error('等待狀態格式無效');
      panel.hidden = requests.length === 0; summary.textContent = `等待中的工作（${requests.length}）`;
      list.replaceChildren();
      for (const item of requests) {
        const b = document.createElement('button'); b.type = 'button'; b.style.cssText='display:block;margin-top:8px;white-space:normal;text-align:left';
        b.textContent = item.description + (item.state === 'stopping' ? '：正在停止前一工作' : '：選擇處理方式');
        b.disabled = item.state === 'stopping'; b.onclick = () => showWait(item); list.append(b);
      }
      if (dialogState && !dialogState.submitting && !requests.some(r => r.id === dialogState.id && r.token === dialogState.token)) {dialogState.ui.close();dialogState = null;}
      if (!dialogState && !selfChoosing) {
        const next = requests.find(r => r.state === 'prompt' && !dismissed.has(r.id + ':' + r.token));
        if (next) showWait(next);
      }
    } catch (error) {
      if (requests.length) {panel.hidden=false;summary.textContent='等待狀態暫時無法查詢，正在重新連線';}
    } finally {polling=false;}
  }
  async function chooseSelfTest(incoming, pendingId = null) {
    const active = await request('/api/test-self-active');
    if (!Array.isArray(active)) throw Error('目前工作狀態格式無效');
    if (!active.length && pendingId) {
      const status = await request('/api/test-self-status?id=' + encodeURIComponent(pendingId));
      if (!['complete','stopped'].includes(status.state)) active.push({id:pendingId,message:status.message || '原測試狀態待確認',token:null});
    }
    if (!active.length) return {proceed:true};
    const old = active[0]; selfChoosing = true;
    const ui = makeDialog(old.message || '本人測試執行中', incoming, !!old.token);
    if(old.token) ui.part('note').textContent='繼續等待會保留目前測試；選擇強制停止後，才建立新的測試。已送出的 Teams 訊息不會撤回或重送。';
    if(Number.isFinite(Date.parse(old.startedUtc))) ui.part('status').textContent=`已執行 ${Math.max(0,Math.floor((Date.now()-Date.parse(old.startedUtc))/1000))} 秒。請選擇要繼續等待，或強制停止這個測試。`;
    return new Promise(resolve => {
      let submitting = false;
      const done = value => {ui.close();selfChoosing=false;resolve(value);};
      const choose = async decision => {
        if (submitting) return;
        if (decision === 'wait') {done({proceed:false,watch:old.id});return;}
        if (decision === 'cancel') {done({proceed:false});return;}
        submitting=true;ui.dialog.querySelectorAll('button').forEach(b=>b.disabled=true);
        ui.part('status').textContent='正在停止指定的前一個測試…';
        try {await request('/api/test-self-cancel',{id:old.id,token:old.token});done({proceed:true});}
        catch(error){
          ui.part('status').textContent='尚未啟動新工作：'+error.message;
          submitting=false;ui.dialog.querySelectorAll('button').forEach(b=>b.disabled=false);ui.part('replace').disabled=!old.token;
        }
      };
      for(const decision of ['wait','replace','cancel'])ui.part(decision).onclick=()=>choose(decision);
      ui.dialog.addEventListener('cancel',e=>{e.preventDefault();choose('cancel');});
    });
  }
  window.E3WorkUI={chooseSelfTest,refresh:poll};
  if(location.protocol === 'http:') {poll();setInterval(poll,1500);}
})();
 