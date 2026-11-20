// One origin for the live-view bench, in front of baguette serve:
//   /bench/*            the bench pages (www/), and POST /bench/bridge/on|off, which starts or stops the spike's
//                       WHEP source (baguette stream → ffmpeg → MediaMTX), used only when a bench run asks for it
//   /whep               → MediaMTX's WHEP endpoint (the spike; baguette's own is /devices/:udid/whep)
//   /pion/*             → pion-whep, the reference WebRTC sender (pion/), prefix stripped
//   /api/*              → baguette serve, prefix stripped (the bench pages' route)
//   everything else     → baguette serve unchanged, WebSocket included: its own page, with its WebRTC choice.
//   node proxy.mjs --bridge <bridge.sh> [--listen <addr>]
// Plain http on :8777, loopback only unless --listen. baguette serve stays on loopback; the proxy rewrites
// Host/Origin to serve's own loopback address so serve's origin check passes.
import http from 'node:http';
import net from 'node:net';
import fs from 'node:fs';
import path from 'node:path';
import { spawn, execFileSync } from 'node:child_process';

const WWW = path.join(path.dirname(new URL(import.meta.url).pathname), 'www');
const SERVE = { host: '127.0.0.1', port: 8421 };
const WHEP = { host: '127.0.0.1', port: 8889, path: '/sim/whep' };
const PION = { host: '127.0.0.1', port: 8890 };
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript', '.css': 'text/css', '.json': 'application/json' };
const LOOPBACK = `http://${SERVE.host}:${SERVE.port}`;

// --- the WHEP source runs only while something needs it
const BRIDGE = process.argv[process.argv.indexOf('--bridge') + 1];
let bridge = null;
function bridgeOff() {
  if (!bridge) return;
  try { execFileSync('pkill', ['-P', String(bridge.pid)]); } catch {}
  bridge.kill(); bridge = null;
}
function bridgeOn() {
  if (bridge) return;
  bridge = spawn(BRIDGE, [], { stdio: 'ignore' });
  bridge.on('exit', () => { bridge = null; });
}
for (const sig of ['SIGINT', 'SIGTERM']) process.on(sig, () => { bridgeOff(); process.exit(0); });

function upstreamHeaders(req, target) {
  const headers = { ...req.headers, host: `${target.host}:${target.port}` };
  if (headers.origin) headers.origin = LOOPBACK;
  if (headers.referer) { try { headers.referer = LOOPBACK + new URL(headers.referer).pathname; } catch { delete headers.referer; } }
  return headers;
}

function forward(req, res, target, targetPath) {
  const headers = upstreamHeaders(req, target);
  const up = http.request({ ...target, path: targetPath, method: req.method, headers }, r => {
    res.writeHead(r.statusCode, r.headers);
    r.pipe(res);
  });
  up.on('error', e => { res.writeHead(502); res.end('upstream: ' + e.message); });
  req.pipe(up);
}

function staticFile(res, rel) {
  const file = path.join(WWW, path.normalize(rel === '' || rel === '/' ? '/index.html' : rel));
  if (!file.startsWith(WWW)) { res.writeHead(403); return res.end(); }
  fs.readFile(file, (err, body) => {
    if (err) { res.writeHead(404); return res.end('not found'); }
    res.writeHead(200, { 'content-type': TYPES[path.extname(file)] || 'application/octet-stream', 'cache-control': 'no-store' });
    res.end(body);
  });
}

function handle(req, res) {
  const url = new URL(req.url, 'http://x');
  if (!/\.(js|css|png|svg|json|woff2?)$/.test(url.pathname))
    console.log(new Date().toISOString(), req.socket.remoteAddress, req.method, req.url);
  if (url.pathname === '/bench/clock' && req.method === 'GET') {
    res.writeHead(204, { 'cache-control': 'no-store', 'x-baguette-clock-ms': Date.now() });
    return res.end();
  }
  if (url.pathname === '/bench/bridge/on' && req.method === 'POST') { bridgeOn(); res.writeHead(204); return res.end(); }
  if (url.pathname === '/bench/bridge/off' && req.method === 'POST') { bridgeOff(); res.writeHead(204); return res.end(); }
  if (url.pathname === '/bench') { res.writeHead(302, { location: '/bench/' + url.search }); return res.end(); }
  if (url.pathname.startsWith('/bench/')) return staticFile(res, url.pathname.slice(6));
  if (url.pathname === '/whep' || url.pathname.startsWith('/whep/'))
    return forward(req, res, WHEP, WHEP.path + url.pathname.slice(5) + url.search);
  if (url.pathname.startsWith('/pion/')) return forward(req, res, PION, req.url.slice(5));
  if (url.pathname.startsWith('/api/')) return forward(req, res, SERVE, req.url.slice(4));
  // baguette serve's own pages; the spike's WHEP source has no part in them (one encoder per view).
  if (/^\/(devices|simulators)\/[^/]+\/?$/.test(url.pathname)) bridgeOff();
  return forward(req, res, SERVE, req.url);
}

// WebSocket upgrades are spliced byte for byte to baguette serve (/api/ prefix stripped).
function upgrade(req, socket, head) {
  const target = req.url.startsWith('/api/') ? req.url.slice(4) : req.url;
  const up = net.connect(SERVE.port, SERVE.host, () => {
    const lines = Object.entries(upstreamHeaders(req, SERVE)).map(([k, v]) => `${k}: ${v}`);
    up.write(`GET ${target} HTTP/1.1\r\n${lines.join('\r\n')}\r\n\r\n`);
    if (head.length) up.write(head);
    up.pipe(socket); socket.pipe(up);
  });
  up.setNoDelay(true); socket.setNoDelay?.(true);
  const close = () => { up.destroy(); socket.destroy(); };
  up.on('error', close); socket.on('error', close);
}

const li = process.argv.indexOf('--listen');
const LISTEN = li > 0 ? process.argv[li + 1] : '127.0.0.1';
http.createServer(handle).on('upgrade', upgrade)
  .listen(8777, LISTEN === '127.0.0.1' ? '127.0.0.1' : '0.0.0.0', () => console.log(`http://${LISTEN}:8777`));
