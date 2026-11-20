// node drive.mjs <bench URL> — opens it in a Chrome started with --remote-debugging-port=9333, waits for the run to end, prints the result JSON.
const url = process.argv[2];
const t = await (await fetch('http://127.0.0.1:9333/json/new?' + encodeURIComponent(url), { method: 'PUT' })).json();
const ws = new WebSocket(t.webSocketDebuggerUrl); let id = 0; const pend = new Map();
const send = (method, params = {}) => new Promise(r => { const i = ++id; pend.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && pend.has(m.id)) { pend.get(m.id)(m.result); pend.delete(m.id); }
  if (m.method === 'Runtime.consoleAPICalled') console.error(m.params.args.map(a => a.value).join(' ')); };
await new Promise(r => ws.onopen = r);
await send('Runtime.enable'); await send('Page.bringToFront');
for (;;) {
  await new Promise(r => setTimeout(r, 2000));
  const r = await send('Runtime.evaluate', { expression: 'window.__bench && window.__bench.done ? JSON.stringify({s:__bench.summary, samples:__bench.samples}) : ""', returnByValue: true });
  if (r?.result?.value) { console.log(r.result.value); break; }
}
await fetch('http://127.0.0.1:9333/json/close/' + t.id); process.exit(0);
