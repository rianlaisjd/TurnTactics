// End-to-end browser test: the REAL frontend in headless Chrome against the REAL SQL in the local
// PostgreSQL ("tt", built by tests/db/release.sh). Only Supabase Auth and its HTTP transport are
// replaced: a stub client forwards each RPC to psql with the caller's user id as the JWT subject.
// So this exercises the UI and the database functions together, but NOT Supabase Auth, PostgREST,
// Edge Functions or real push delivery.
// Run: tests/db/pg.sh start && tests/db/baseline.sh && tests/db/release.sh && node tests/e2e/run.mjs
// No packages needed (Node 22+ and a Chrome/Chromium binary; set CHROME_PATH to override).
import http from 'node:http';
import { spawn, spawnSync } from 'node:child_process';
import { readFileSync, existsSync, mkdtempSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..'), PUBLIC = path.join(ROOT, 'public');
const PORT = 8091, CDP_PORT = 9339, ORIGIN = `http://localhost:${PORT}`;
const PG = { ...process.env, PGHOST: '127.0.0.1', PGPORT: process.env.TT_PG_PORT || '54329', PGUSER: 'postgres', PGDATABASE: 'tt' };
const SHOTS = path.join(ROOT, 'tests/e2e/screenshots'); mkdirSync(SHOTS, { recursive: true });
const results = []; const faults = new Map();

// ---------- database bridge ----------
const lit = (v) => (v === null || v === undefined ? 'NULL' : typeof v === 'number' || typeof v === 'boolean' ? String(v)
  : typeof v === 'object' ? `'${JSON.stringify(v).replace(/'/g, "''")}'::jsonb` : `'${String(v).replace(/'/g, "''")}'`);
function sql(text) {
  const run = spawnSync('psql', ['-Atq', '-v', 'ON_ERROR_STOP=1', '-c', text], { env: PG, encoding: 'utf8' });
  if (run.status !== 0) { const m = /ERROR:\s+(.*)/.exec(run.stderr); throw Object.assign(Error(m ? m[1] : run.stderr.trim()), { code: 'P0001' }); }
  return run.stdout.trim().split('\n').pop();
}
function callRpc(uid, name, args) {
  if (!/^tt_[a-z_]+$/.test(name)) throw Error('bad function');
  const list = Object.entries(args || {}).map(([k, v]) => { if (!/^p_[a-z0-9_]+$/.test(k)) throw Error('bad arg'); return `${k} => ${lit(v)}`; }).join(', ');
  const out = sql(`select set_config('request.jwt.claim.sub', ${lit(uid || '')}, false); select public.${name}(${list});`);
  try { return JSON.parse(out); } catch { return out === '' ? null : out; }
}
function account(name) {
  const id = randomUUID();
  sql(`insert into auth.users(id, email) values ('${id}', '${name.toLowerCase()}-${id.slice(0, 6)}@e2e.invalid'); select set_config('request.jwt.claim.sub', '${id}', false); select public.tt_profile_save('${name.toLowerCase().replace(/[^a-z0-9]/g, '').slice(0, 12)}_${id.slice(0, 6)}', '${name}');`);
  return id;
}

// ---------- static server with the auth/transport stub ----------
const STUB = `export const createClient = () => { const uid = localStorage.getItem('e2e-user');
  const user = uid ? { id: uid, is_anonymous: localStorage.getItem('e2e-anon') === '1', user_metadata: {} } : null;
  return { auth: { getSession: async () => ({ data: { session: user ? { user } : null } }), onAuthStateChange: () => ({ data: { subscription: { unsubscribe() {} } } }),
      signOut: async () => { localStorage.removeItem('e2e-user'); return {}; } },
    rpc: async (name, args) => { try { const r = await fetch('/__rpc', { method: 'POST', body: JSON.stringify({ uid, name, args }) }); return await r.json(); }
      catch (e) { return { data: null, error: { message: 'TypeError: Failed to fetch', code: '' } }; } } }; };`;
const TYPES = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.svg': 'image/svg+xml', '.png': 'image/png', '.webmanifest': 'application/manifest+json' };
const server = http.createServer((req, res) => {
  const url = new URL(req.url, ORIGIN);
  if (url.pathname === '/__rpc') {
    let body = ''; req.on('data', (c) => { body += c; }); req.on('end', async () => {
      const { uid, name, args } = JSON.parse(body); let payload;
      try { payload = { data: callRpc(uid, name, args), error: null }; } catch (e) { payload = { data: null, error: { message: e.message, code: e.code || 'P0001' } }; }
      const fault = faults.get(name);
      if (fault?.kind === 'drop' && (!fault.match || fault.match(args))) { faults.delete(name); res.writeHead(504); res.end('gateway timeout'); return; } // executed on the server, but the answer never reaches the app
      if (fault?.kind === 'delay' && (!fault.match || fault.match(args))) await new Promise((r) => setTimeout(r, fault.ms));
      res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(payload));
    }); return;
  }
  // Test-only public configuration, served from memory. The real online-config.js is never read or changed.
  if (url.pathname === '/online-config.js') { res.writeHead(200, { 'Content-Type': 'text/javascript' }); res.end("export const SUPABASE_URL='https://tt-e2e.invalid';export const SUPABASE_PUBLISHABLE_KEY='e2e';"); return; }
  const file = path.join(PUBLIC, path.normalize(url.pathname === '/' ? '/index.html' : url.pathname));
  if (!file.startsWith(PUBLIC) || !existsSync(file)) { res.writeHead(404); res.end('not found'); return; }
  // The same Content-Security-Policy recommended for production (RELEASE_HANDOFF.md), so the app is proven to run under it.
  res.writeHead(200, { 'Content-Type': TYPES[path.extname(file)] || 'application/octet-stream', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
    'Content-Security-Policy': "default-src 'self'; script-src 'self' https://esm.sh; style-src 'self'; img-src 'self' data:; connect-src 'self' https://esm.sh; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'" });
  res.end(readFileSync(file));
});

// ---------- minimal Chrome DevTools client ----------
let ws, nextId = 0; const waiting = new Map(), listeners = [];
const cdp = (method, params = {}, sessionId) => new Promise((resolve, reject) => { const id = ++nextId; waiting.set(id, { resolve, reject, method }); ws.send(JSON.stringify({ id, method, params, sessionId })); });
async function launch() {
  const bin = process.env.CHROME_PATH || ['/usr/local/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser', '/usr/bin/google-chrome'].find(existsSync);
  if (!bin) throw Error('No Chrome/Chromium found. Set CHROME_PATH.');
  const proc = spawn(bin, ['--headless=new', '--no-sandbox', '--disable-gpu', `--remote-debugging-port=${CDP_PORT}`, `--user-data-dir=${mkdtempSync(path.join(tmpdir(), 'tt-e2e-'))}`, 'about:blank'], { stdio: 'ignore' });
  let info;
  for (let i = 0; i < 50 && !info; i++) { await new Promise((r) => setTimeout(r, 200)); try { info = await (await fetch(`http://127.0.0.1:${CDP_PORT}/json/version`)).json(); } catch { /* not up yet */ } }
  if (!info) throw Error('Chrome did not start');
  ws = new WebSocket(info.webSocketDebuggerUrl); await new Promise((r) => { ws.onopen = r; });
  ws.onmessage = (e) => { const m = JSON.parse(e.data);
    if (m.id) { const w = waiting.get(m.id); waiting.delete(m.id); if (m.error) w.reject(Error(w.method + ': ' + m.error.message)); else w.resolve(m.result); }
    else listeners.forEach((l) => l(m)); };
  return proc;
}
async function newPage(uid, { width = 390, height = 844, anon = false } = {}) {
  const { browserContextId } = await cdp('Target.createBrowserContext');
  const { targetId } = await cdp('Target.createTarget', { url: 'about:blank', browserContextId });
  const { sessionId } = await cdp('Target.attachToTarget', { targetId, flatten: true });
  const page = { sessionId, errors: [], send: (m, p) => cdp(m, p, sessionId) };
  listeners.push((m) => {
    if (m.sessionId !== sessionId) return;
    if (m.method === 'Runtime.exceptionThrown') page.errors.push(m.params.exceptionDetails.exception?.description || m.params.exceptionDetails.text);
    if (m.method === 'Fetch.requestPaused') page.send('Fetch.fulfillRequest', { requestId: m.params.requestId, responseCode: 200,
      responseHeaders: [{ name: 'Content-Type', value: 'text/javascript' }, { name: 'Access-Control-Allow-Origin', value: '*' }], body: Buffer.from(STUB).toString('base64') });
  });
  await page.send('Runtime.enable'); await page.send('Page.enable');
  await page.send('Fetch.enable', { patterns: [{ urlPattern: 'https://esm.sh/*' }] });
  await page.send('Emulation.setFocusEmulationEnabled', { enabled: true });
  await page.send('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 1, mobile: width < 700 });
  await page.send('Page.addScriptToEvaluateOnNewDocument', { source: `if (!sessionStorage.getItem('e2e-init')) { sessionStorage.setItem('e2e-init', '1'); ${uid ? `localStorage.setItem('e2e-user', '${uid}');` : ''} ${anon ? "localStorage.setItem('e2e-anon','1');" : ''} }` });
  page.eval = async (expression) => { const r = await page.send('Runtime.evaluate', { expression: `(async () => { ${expression} })()`, awaitPromise: true, returnByValue: true }); if (r.exceptionDetails) throw Error(r.exceptionDetails.exception?.description || r.exceptionDetails.text); return r.result.value; };
  page.goto = async (query = '') => { await page.send('Page.navigate', { url: `${ORIGIN}/online.html${query}` }); await page.wait(`document.readyState === 'complete' && document.getElementById('connection').textContent !== 'Offline'`); };
  page.wait = async (condition, what = condition, ms = 8000) => { const end = Date.now() + ms; while (Date.now() < end) { if (await page.eval(`return !!(${condition});`).catch(() => false)) return; await new Promise((r) => setTimeout(r, 80)); } throw Error('Timed out waiting for: ' + what); };
  page.click = (selector) => page.eval(`const el = document.querySelector(${JSON.stringify(selector)}); if (!el) throw Error('Missing ${selector.replace(/'/g, '')}'); if (el.disabled) throw Error('Disabled: ${selector.replace(/'/g, '')}'); el.click();`);
  page.fill = (selector, value) => page.eval(`const el = document.querySelector(${JSON.stringify(selector)}); el.value = ${JSON.stringify(value)}; el.dispatchEvent(new Event('input', { bubbles: true })); el.dispatchEvent(new Event('change', { bubbles: true }));`);
  page.text = (selector) => page.eval(`return document.querySelector(${JSON.stringify(selector)})?.textContent ?? '';`);
  page.view = async (name) => { await page.eval(`document.querySelector('#menu [data-view="${name}"]').click();`); await page.wait(`!document.getElementById('view-${name}').hidden`); };
  page.confirm = async () => { await page.wait(`document.getElementById('decisionDialog').open`, 'confirmation dialog'); await page.click('#dialogConfirm'); await new Promise((r) => setTimeout(r, 120)); };
  page.settled = async () => { await new Promise((r) => setTimeout(r, 120)); return page.wait(`!document.querySelector('#requestText').textContent.startsWith('Waiting')`, 'server confirmation'); };
  page.shot = async (name) => { const { data } = await page.send('Page.captureScreenshot', { format: 'png' }); writeFileSync(path.join(SHOTS, name + '.png'), Buffer.from(data, 'base64')); };
  page.noOverflow = () => page.eval(`return document.documentElement.scrollWidth <= innerWidth + 1;`);
  return page;
}
async function check(name, fn) { try { await fn(); results.push(['PASS', name]); console.log('PASS', name); } catch (e) { results.push(['FAIL', name, e.message]); console.log('FAIL', name, '—', e.message.split('\n')[0]); } }
const must = (cond, what) => { if (!cond) throw Error(what); };

// ---------- scenarios ----------
await new Promise((r) => server.listen(PORT, r));
const chrome = await launch();
try {
  const H = account('Hostess'), A = account('Ada'), B = account('Bram');
  const host = await newPage(H), ada = await newPage(A), bram = await newPage(B, { width: 1280, height: 860 });
  let invite, code;

  await check('theme: no flash — remembered dark theme is applied before the app script runs', async () => {
    await host.goto(); await host.view('settings'); await host.click('[data-pref="tt-theme"] button[value="dark"]');
    must(await host.eval(`return document.documentElement.dataset.theme;`) === 'dark', 'dark not applied');
    await host.send('Page.navigate', { url: `${ORIGIN}/online.html` });
    await host.wait(`document.documentElement.dataset.theme === 'dark' && document.readyState !== 'loading'`, 'dark theme on reload');
    must(await host.eval(`return getComputedStyle(document.body).backgroundColor;`) === 'rgb(18, 22, 31)', 'midnight ink background missing');
    await host.wait(`document.getElementById('connection').textContent !== 'Offline'`); await host.view('settings');
    await host.click('[data-pref="tt-theme"] button[value="light"]'); must(await host.eval(`return localStorage.getItem('tt-theme');`) === 'light', 'choice not remembered'); await host.eval(`document.querySelector('#menu [data-view="field"]').click();`);
    await host.wait(`!document.getElementById('view-home').hidden`);
  });

  await check('accounts: signed-in profile shown; host creates a room with a six-character invitation', async () => {
    must((await host.text('#whoAmI')).startsWith('Hostess (@'), 'profile not shown');
    await host.click('#createRoom'); await host.wait(`!document.getElementById('lobby').hidden`);
    invite = await host.text('#lobbyCode'); must(/^[A-HJ-KM-NP-Z2-9]{6}$/.test(invite), 'invite format: ' + invite);
    code = sql(`select code from tt_rooms where invite = '${invite}'`); must(code.length === 12, 'canonical code kept');
    must(await host.noOverflow(), 'horizontal overflow in lobby'); await host.shot('01-lobby-mobile');
  });

  await check('menu: left panel, focus moves in, Tab stays inside, Escape closes and restores focus, current page marked', async () => {
    must(await host.eval(`return document.querySelector('.navigation, nav.bottom') === null && getComputedStyle(document.getElementById('menu')).visibility === 'hidden';`), 'menu should start closed; no bottom navigation');
    await host.eval(`document.getElementById('menuButton').focus(); document.getElementById('menuButton').click();`);
    must(await host.eval(`return document.getElementById('menu').contains(document.activeElement) && document.getElementById('menuButton').getAttribute('aria-expanded') === 'true';`), 'focus not moved into menu');
    await new Promise((r) => setTimeout(r, 300)); must(await host.eval(`return document.querySelector('#menu [aria-current="page"]').dataset.view === 'field' && document.getElementById('menu').getBoundingClientRect().left === 0;`), 'current location / left side');
    await host.shot('02-menu-open');
    await host.eval(`const items=[...document.querySelectorAll('#menu button:not([hidden])')]; items[items.length-1].focus(); items[items.length-1].dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',bubbles:true,cancelable:true}));`);
    must(await host.eval(`return document.activeElement === document.querySelector('#menu button:not([hidden])');`), 'Tab escaped the menu');
    await host.eval(`document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}));`);
    must(await host.eval(`return document.activeElement.id === 'menuButton' && !document.body.classList.contains('menu-open') && document.getElementById('menu').inert;`), 'Escape did not close/restore focus');
  });

  await check('invitation: lowercase/spaced code joins; default display name; room-specific name; wrong code is generic', async () => {
    await ada.goto(`?join=${invite.toLowerCase()}`); must(await ada.eval(`return document.getElementById('joinCode').value;`) === invite, 'invite link did not prefill');
    await ada.fill('#joinCode', 'zzzzzz'); await ada.eval(`document.getElementById('joinForm').requestSubmit();`); await ada.settled();
    must((await ada.text('#homeFeedback')).includes('not available'), 'generic invalid-invite message missing');
    await ada.fill('#joinCode', ` ${invite.slice(0, 3).toLowerCase()}-${invite.slice(3).toLowerCase()} `); await ada.eval(`document.getElementById('joinForm').requestSubmit();`);
    await ada.wait(`!document.getElementById('lobby').hidden`); must((await ada.text('#lobbyPeople')).includes('Ada (you)'), 'default display name not used');
    await bram.goto(); await bram.fill('#joinCode', invite); await bram.fill('#joinName', 'A Remarkably Long Name!!'); await bram.eval(`document.getElementById('joinForm').requestSubmit();`);
    await bram.wait(`!document.getElementById('lobby').hidden`); must((await bram.text('#lobbyPeople')).includes('A Remarkably Long Name!!'), 'room-specific name not used');
    must(await bram.eval(`return getComputedStyle(document.getElementById('menu')).visibility === 'visible' && getComputedStyle(document.getElementById('menuButton')).display === 'none';`), 'wide screens should show the side menu persistently');
  });

  await check('test room start: 8 × 8 board, a–h / 8–1 edge labels with a1 lower-left, labelled resource row, crest tokens', async () => {
    await host.eval(`document.getElementById('refresh').click();`); await host.wait(`document.getElementById('lobbyCount').textContent.startsWith('2 of 20')`, 'host sees both players');
    await host.view('desk'); await host.click('#fillTest'); await host.confirm(); await host.settled();
    await host.click('#start'); await host.confirm(); await host.settled(); await host.view('field');
    must(!(await host.eval(`return document.getElementById('testBanner').hidden;`)), 'test room must be labelled');
    sql(`update tt_rooms set state = jsonb_set(jsonb_set(jsonb_set(state, '{players,0}', state->'players'->0 || '{"x":0,"y":7,"points":6}'), '{players,1}', state->'players'->1 || '{"x":2,"y":6,"points":6}'), '{players,2}', state->'players'->2 || '{"x":6,"y":1}') where code = '${code}'; update tt_rooms set state = jsonb_set(jsonb_set(state, '{players,3}', state->'players'->3 || '{"x":7,"y":4}'), '{players,4}', state->'players'->4 || '{"x":4,"y":3}') where code = '${code}'`);
    await ada.eval(`document.getElementById('refresh').click();`); await ada.wait(`document.querySelectorAll('#board .cell').length === 64 && document.querySelector('#board .cell.self')?.dataset.x === '0'`, 'board render').catch(async (e) => { throw Error(e.message + ' :: ' + await ada.eval(`return JSON.stringify([document.querySelectorAll('#board .cell').length, document.querySelector('#board .cell.self')?.dataset.x, document.getElementById('phaseLabel').textContent, document.getElementById('battle').hidden, document.body.dataset.view, document.getElementById('requestText').textContent]);`)); });
    must(await ada.eval(`return [...document.querySelectorAll('#board .file')].map(n => n.textContent).join('') === 'abcdefgh' && [...document.querySelectorAll('#board .rank')].map(n => n.textContent).join('') === '87654321';`), 'edge labels wrong');
    must(await ada.eval(`const c = document.querySelector('#board .cell.self'); return c.getAttribute('aria-label').startsWith('a1, Ada (you)') && c.dataset.y === '7' && !!c.querySelector('svg.crest') && c.querySelector('.you-tag').textContent === 'you';`), 'a1 lower-left / own token');
    must(await ada.eval(`return [...document.querySelectorAll('#resources .resource')].map(n => n.textContent).join('|');`) === 'Points6|Hearts3|Range4|ShieldNone', 'resource row: ' + await ada.text('#resources'));
    must(await ada.eval(`return document.querySelectorAll('#board .token').length === 5 && document.querySelector('#board .token').textContent.trim() === '';`), 'tokens should be crests, not 01/02 numbers');
    must(await ada.eval(`return document.querySelector('#board .cell[data-x="2"][data-y="6"]').classList.contains('in-range') && !document.querySelector('#board .cell[data-x="6"][data-y="1"]').classList.contains('in-range');`), 'range marking (L-shaped offset in, far square out)');
    must(await ada.noOverflow(), 'horizontal overflow on field'); await ada.shot('03-field-mobile'); await bram.eval(`document.getElementById('refresh').click();`); await bram.wait(`document.querySelectorAll('#board .cell').length === 64`); await bram.shot('04-field-desktop');
  });

  await check('move: confirmation names the square; Dispatch shows the same chess coordinate; other players see it', async () => {
    await ada.click('#board .cell[data-x="1"][data-y="7"]'); must(await ada.text('#selectedSquare') === 'b1', 'selected coordinate not shown');
    await ada.click('#actionList button'); await ada.wait(`document.getElementById('decisionDialog').open`); must((await ada.text('#dialogTitle')) === 'Move from a1 to b1?', await ada.text('#dialogTitle'));
    await ada.click('#dialogConfirm'); await ada.settled(); must((await ada.text('#latestDispatch')).includes('Ada moved to b1.'), 'dispatch: ' + await ada.text('#latestDispatch'));
    must(sql(`select state->'players'->0->>'x' || ',' || (state->'players'->0->>'y') || ',' || (state->'players'->0->>'points') from tt_rooms where code='${code}'`) === '1,7,5', 'server position/charge');
    await bram.eval(`document.getElementById('refresh').click();`); await bram.wait(`document.getElementById('latestDispatch').textContent.includes('Ada moved to b1.')`);
  });

  await check('privacy in the UI: a player sees only their own resources; the referee sees all; host log hidden from players', async () => {
    await bram.view('players'); must(await bram.eval(`return [...document.querySelectorAll('#playerList .player')].filter(n => /heart/.test(n.textContent)).length;`) === 1, 'opponent resources visible');
    must(await bram.eval(`return document.getElementById('deskNav').hidden && document.getElementById('hostLog').children.length === 0;`), 'host controls leaked');
    await host.view('players'); must(await host.eval(`return [...document.querySelectorAll('#playerList .player')].filter(n => /heart/.test(n.textContent)).length;`) === 5, 'referee view incomplete'); await bram.view('field');
  });

  await check('lost response: action applied once; UI blocks new actions, survives reload, retries the SAME request', async () => {
    faults.set('tt_command', { kind: 'drop', match: (a) => a.p_action === 'shield' });
    await ada.click('#board .cell.self'); await ada.click('#actionList .action:nth-child(1) button'); await ada.confirm();
    await ada.wait(`document.getElementById('requestText').textContent.includes('No confirmation arrived') && !document.getElementById('retry').hidden`, 'retry prompt');
    must(await ada.eval(`return [...document.querySelectorAll('#actionList button')].every(b => b.disabled);`), 'actions not blocked while unconfirmed');
    await ada.goto(); await ada.wait(`!document.getElementById('retry').hidden`, 'pending request restored after reload'); await ada.shot('05-pending-retry');
    await ada.click('#retry'); await ada.wait(`document.getElementById('retry').hidden`);
    must(sql(`select (state->'players'->0->>'points') || ',' || (state->'players'->0->>'shield') from tt_rooms where code='${code}'`) === '3,true', 'shield charged other than exactly once');
    must((await ada.text('#resources')).includes('ShieldActive'), 'shield not shown to its owner');
    await bram.eval(`document.getElementById('refresh').click();`); await new Promise((r) => setTimeout(r, 400));
    must(await bram.eval(`return document.querySelectorAll('#board .shield-badge').length;`) === 0, 'another player can see a shield marker');
  });

  await check('chat: confirmed “Sent”, avatars, host label, quoted reply, DM hidden from the host, HTML rendered as text', async () => {
    await ada.view('chat'); await ada.wait(`!document.getElementById('chatSend').disabled || document.getElementById('chatBody').value === ''`);
    await ada.fill('#chatBody', 'Truce until day three? <img src=x onerror="window.__xss=1">'); await ada.wait(`!document.getElementById('chatSend').disabled`); await ada.click('#chatSend');
    await ada.wait(`document.getElementById('chatFeedback').textContent === 'Sent.'`, 'Sent confirmation'); await ada.wait(`document.querySelectorAll('#chatMessages .message.own').length === 1`); must(await ada.eval(`return document.querySelectorAll('#chatMessages .message.own .avatar svg.crest').length === 1 && window.__xss === undefined && document.querySelectorAll('#chatMessages img').length === 0;`), 'avatar / XSS');
    await bram.view('chat'); await bram.wait(`document.querySelectorAll('#chatMessages .message').length === 1`); await bram.click('#chatMessages .reply-button');
    must((await bram.text('#chatReplyText')).startsWith('Replying to Ada: Truce'), 'reply chip'); await bram.fill('#chatBody', 'Agreed.'); await bram.click('#chatSend'); await bram.wait(`document.getElementById('chatFeedback').textContent === 'Sent.'`);
    await ada.wait(`document.querySelector('#chatMessages blockquote')?.textContent.includes('Truce until day three')`, 'quoted reply visible'); await ada.shot('06-chat-mobile');
    await new Promise((r) => setTimeout(r, 1100)); await ada.fill('#chatThreadSelect', '1'); await ada.wait(`document.getElementById('chatThreadTitle').textContent === 'A Remarkably Long Name!!'`);
    await ada.fill('#chatBody', 'Between us only.'); await ada.wait(`!document.getElementById('chatSend').disabled`); await ada.click('#chatSend'); await ada.wait(`document.getElementById('chatFeedback').textContent === 'Sent.'`);
    await host.view('chat'); await host.wait(`document.querySelectorAll('#chatMessages .message').length === 2`); await new Promise((r) => setTimeout(r, 1100));
    await host.fill('#chatBody', 'Play nicely.'); await host.wait(`!document.getElementById('chatSend').disabled`); await host.click('#chatSend'); await host.wait(`document.getElementById('chatFeedback').textContent === 'Sent.'`);
    await host.fill('#chatThreadSelect', '0'); await host.wait(`document.getElementById('chatThreadTitle').textContent === 'Ada'`); await host.wait(`document.querySelector('#chatMessages .chat-empty')?.textContent === 'No messages yet.'`, 'host must not see the Ada–Bram DM');
    must(!(await host.eval(`return document.body.textContent;`)).includes('Between us only.'), 'DM text reached the host page');
    await bram.wait(`document.querySelector('#chatMessages .from-host .role-tag')?.textContent === 'Host'`, 'host label'); await bram.shot('07-chat-desktop');
    must(await bram.eval(`return document.querySelector('.chat-threads .count') !== null || document.getElementById('chatBadge').hidden === false;`), 'unread DM not indicated');
  });

  await check('late chat response after switching conversations is discarded', async () => {
    faults.set('tt_chat_list', { kind: 'delay', ms: 1500, match: (a) => a.p_peer === 0 });
    await bram.eval(`document.querySelector('#chatThreads [data-chat-peer="0"]').click();`); await new Promise((r) => setTimeout(r, 150));
    await bram.eval(`document.querySelector('#chatThreads [data-chat-peer="room"]').click();`); await new Promise((r) => setTimeout(r, 2200)); faults.delete('tt_chat_list');
    must(await bram.text('#chatThreadTitle') === 'Room chat' && !(await bram.text('#chatMessages')).includes('Between us only.'), 'a DM page rendered into room chat');
  });

  await check('rules desk: typed effects → server preview → publish; players see the new rule; written rule is host-enforced text', async () => {
    await host.view('desk'); await host.wait(`document.querySelectorAll('#effectKey option').length >= 15`, 'catalog');
    must(await host.eval(`return document.getElementById('publishAmend').hidden;`), 'publish must need a preview first');
    await host.fill('#effectKey', 'costMove'); await host.fill('#effectValue', '2'); await host.click('#addEffect');
    await host.fill('#effectType', 'adjust'); await host.fill('#adjustResource', 'points'); await host.fill('#adjustAmount', '2'); await host.fill('#effectWhen', 'next_reset'); await host.click('#addEffect');
    await host.fill('#effectType', 'written'); await host.fill('#writtenText', 'No alliances of more than two. <script>window.__xss=2</script>'); await host.click('#addEffect');
    await host.click('#previewAmend'); await host.wait(`!document.getElementById('amendPreview').hidden`);
    const preview = await host.text('#amendPreview'); must(preview.includes('Move cost: 1 → 2 point(s).') && preview.includes('Next midnight reset') && preview.includes('Host-enforced') && preview.includes('Everyone in this room'), 'preview: ' + preview);
    await host.shot('08-rules-desk-preview'); await host.click('#publishAmend'); must((await host.text('#deskFeedback')).includes('title'), 'title/reason must be required');
    await host.fill('#amendTitle', 'Slower marches'); await host.fill('#amendReason', 'Agreed in room chat.'); await host.click('#publishAmend'); await host.confirm(); await host.settled();
    must(sql(`select (public.tt_rules(state)->>'costMove') || ',' || jsonb_array_length(state->'pending') from tt_rooms where code='${code}'`) === '2,1', 'amendment not stored');
    await bram.view('council'); await bram.eval(`document.getElementById('refresh').click();`);
    await bram.wait(`document.getElementById('rulesSummary').textContent.includes('2 points · one orthogonal square') && document.getElementById('ruleHistory').textContent.includes('Slower marches')`, 'player sees amended rules');
    must(await bram.eval(`return window.__xss === undefined && document.getElementById('ruleHistory').textContent.includes('<script>') && document.getElementById('ruleHistory').textContent.includes('Host-enforced') && document.getElementById('ruleHistory').textContent.includes('Host amendment');`), 'written rule rendering'); await bram.shot('09-council-desktop');
    await host.wait(`document.getElementById('effectList').textContent.includes('No effects yet')`, 'composer reset after publish');
  });

  await check('notifications: nothing is requested on load; missing push configuration is labelled, not faked', async () => {
    await ada.view('settings'); const status = await ada.text('#notifyStatus');
    must(/Pending setup|does not support|Not available/.test(status), 'status: ' + status);
    must(await ada.eval(`return typeof Notification === 'undefined' || Notification.permission === 'default';`), 'permission was requested without a user action'); await ada.shot('10-settings-mobile');
  });

  await check('large board: 17 players on 15 × 15 pans inside its own viewport on a phone; page never scrolls sideways', async () => {
    const big = callRpc(H, 'tt_create', {}), ids = [];
    for (let i = 0; i < 17; i++) { const id = account('Player Number ' + String(i).padStart(2, '0')); ids.push(id); callRpc(id, 'tt_join', { p_code: big.invite }); }
    callRpc(H, 'tt_command', { p_code: big.code, p_request: randomUUID(), p_action: 'start' });
    sql(`update tt_rooms set state = state || jsonb_build_object('nextReset', ((now() at time zone 'America/Los_Angeles')::date)::text) where code='${big.code}'`);
    const phone = await newPage(ids[0], { width: 360, height: 740 }); await phone.goto(`?room=${big.code}`);
    await phone.wait(`document.querySelectorAll('#board .cell').length === 225`, '15 × 15 board');
    must(await phone.eval(`const v = document.getElementById('boardViewport'); return v.scrollWidth > v.clientWidth && [...document.querySelectorAll('#board .file')].map(n => n.textContent).join('') === 'abcdefghijklmno';`), 'board should pan inside its viewport');
    must(await phone.noOverflow(), 'page scrolls sideways'); must(await phone.eval(`const v = document.getElementById('boardViewport'), c = document.querySelector('.cell.self').getBoundingClientRect(), r = v.getBoundingClientRect(); return c.left >= r.left - 2 && c.right <= r.right + 2;`), 'own token not brought into view');
    const before = await phone.eval(`const v = document.getElementById('boardViewport'); v.scrollLeft = 120; return v.scrollLeft;`); await phone.eval(`document.getElementById('refresh').click();`); await new Promise((r) => setTimeout(r, 600));
    must(await phone.eval(`return document.getElementById('boardViewport').scrollLeft;`) === before, 'polling moved the map'); await phone.shot('11-large-board-phone');
    must(phone.errors.length === 0, 'page errors: ' + phone.errors.join('; '));
  });

  await check('guest identity from the earlier version: existing seat opens; hosting or joining asks for an account', async () => {
    const guestId = randomUUID(); sql(`insert into auth.users(id, is_anonymous) values ('${guestId}', true); update tt_rooms set state = jsonb_set(state, '{players,3}', state->'players'->3 || jsonb_build_object('uid', '${guestId}', 'isTestSeat', false, 'name', 'Old Guest')) where code='${code}'`);
    const guest = await newPage(guestId, { anon: true }); await guest.goto(`?room=${code}`); await guest.wait(`document.querySelectorAll('#board .cell').length === 64`, 'guest seat opens');
    await guest.view('settings'); must((await guest.text('#accountStatus')).startsWith('Guest identity'), 'guest status'); await guest.click('#leaveRoom');
    must(await guest.eval(`return !document.getElementById('guestPanel').hidden && document.getElementById('entryPanel').hidden && !document.getElementById('guestUpgradeNote').hidden === false || !document.getElementById('authPanel').hidden;`), 'guest should be offered an account, not the join form');
    let refused; try { callRpc(guestId, 'tt_create', {}); } catch (e) { refused = e.message; } must(/Create an account/.test(refused || ''), 'server allowed a guest to host');
  });

  await check('no uncaught page errors in any session', async () => { const all = [...host.errors, ...ada.errors, ...bram.errors]; must(all.length === 0, all.join(' | ')); });
} finally {
  chrome.kill(); server.close();
  const failed = results.filter((r) => r[0] === 'FAIL').length;
  console.log(`\n${results.length - failed} passed, ${failed} failed. Auth/PostgREST/Edge Functions/push delivery are stubbed or absent here (see header).`);
  process.exit(failed ? 1 : 0);
}
