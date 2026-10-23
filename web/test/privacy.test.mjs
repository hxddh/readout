// Privacy probe: renders hostile remote-resource constructs and counts how
// many external requests escape. Run with:
//   BROWSER=webkit node test/privacy.test.mjs   (CI; the shipping engine)
// Usage: node test/privacy.test.mjs [TRACK_HOST]
// Requires web/build.mjs to have run. Exits nonzero on any failure.
import { chromium, webkit, firefox } from 'playwright';
import http from 'node:http';
import { readFileSync, existsSync, statSync } from 'node:fs';
import { extname, join } from 'node:path';
import { collectPageErrors } from './pageerrors.mjs';

const TRACK = process.argv[2] || 'track.example';

const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css' };
const server = http.createServer((req, res) => {
  const p = join('build/Web', decodeURIComponent(req.url.split('?')[0]));
  if (!existsSync(p)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { 'content-type': types[extname(p)] || 'application/octet-stream' });
  res.end(readFileSync(p));
}).listen(0);
const base = `http://127.0.0.1:${server.address().port}`;

const engines = { webkit, chromium, firefox };
const engineName = (process.env.BROWSER || 'webkit').toLowerCase();
const launchOpts = process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] } : {};
const browser = await engines[engineName].launch(launchOpts);
// deviceScaleFactor 2: every Mac is 2x, and srcset picks the remote candidate there.
const page = await browser.newPage({ viewport: { width: 900, height: 700 }, deviceScaleFactor: 2 });
const errors = [];
collectPageErrors(page, errors);

let escaped = 0;
await page.route(/.*/, route => {
  const url = route.request().url();
  if (url.includes(TRACK)) { escaped++; return route.abort(); }
  return route.continue();
});

await page.addInitScript(() => {
  window.__msgs = [];
  window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } };
});
await page.goto(`${base}/reader.html`);
await page.waitForFunction(() => window.readout && window.__msgs.some(m => m.type === 'ready'));
await page.evaluate(() => window.readout.setAppearance({ dark: false, accent: '#0a84ff', width: 'narrow', fontSize: 16 }));

let failures = 0;
function check(name, cond, extra = '') {
  if (cond) console.log(`ok: ${name}`);
  else { console.log(`FAIL: ${name} ${extra}`); failures++; }
}

// One block per hostile construct, exactly as Core's sanitize() would emit
// them when the regex gate misses (plus the gated placeholder form).
const T = `https://${TRACK}`;
const hostile = [
  `<img src="${T}/b.png" alt="raw html img">`,
  `<div style="background-image:url(${T}/c.png)">styled div</div>`,
  `<video poster="${T}/d.png"></video>`,
  `<svg width="10" height="10"><image href="${T}/e.png"/></svg>`,
  `<input type="image" src="${T}/f.png" alt="input image">`,
  `<table background="${T}/g.png"><tr><td>cell</td></tr></table>`,
  `<img srcset="local.png 1x, ${T}/h.png 2x" src="local.png" alt="srcset">`,
  `<span class="remote-img" data-src="${T}/a.png" data-alt=""></span>`,
];
await page.evaluate((blocks) => window.readout.apply({
  version: 1, reset: true, rewrite: false,
  ops: blocks.map((html, i) => ({ op: 'insert', slot: i + 1, after: i, html: `<div class="probe">${html}</div>`, kind: 'html' })),
  marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 },
}), hostile);
await page.waitForTimeout(2000);
check('no external requests escape at render', escaped === 0, `escaped=${escaped}`);

// Clicking the placeholder must NOT fetch directly: it posts loadRemote.
await page.evaluate(() => { window.__msgs.length = 0; });
await page.evaluate(() => document.querySelector('.remote-img button')?.click());
await page.waitForTimeout(500);
const loadMsg = await page.evaluate(() => window.__msgs.find(m => m.type === 'loadRemote'));
check('placeholder click posts loadRemote', !!loadMsg && loadMsg.url === `${T}/a.png`, JSON.stringify(loadMsg));
check('still no direct requests after click', escaped === 0, `escaped=${escaped}`);

// An image loaded once is drawn again from its kept bytes when its block is
// (an edit, Undo, the window opened again): no new click, no request. One
// click on a placeholder offers the host's other placeholders, and one more
// loads them all, and only them; nothing is fetched by the page meanwhile.
{
  const GIF = 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7';
  const ph = (slot, src) => ({ op: 'insert', slot, after: slot - 1, kind: 'paragraph',
    html: `<p><span class="remote-img" data-src="${src}" data-alt="i${slot}"></span></p>` });
  const draw = (version, ops) => page.evaluate(([version, ops]) => window.readout.apply({
    version, reset: true, rewrite: false, ops, marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 } }), [version, ops]);
  const state = () => page.evaluate(() => [...document.querySelectorAll('#ro-doc .remote-img')].map(s => {
    const img = s.querySelector('img'), btn = s.querySelector('button');
    return img ? `img:${img.src.slice(0, 22)}` : btn ? `${btn.disabled ? 'busy' : 'btn'}:${btn.textContent}` : s.textContent;
  }));
  const loads = () => page.evaluate(() => window.__msgs.filter(m => m.type === 'loadRemote').map(m => m.url));
  const reset = () => page.evaluate(() => { window.__msgs.length = 0; });

  await draw(10, [ph(1, `${T}/a.png`), ph(2, `https://other.example/x.png`)]);
  await reset();
  // The reader clicks the first; the app answers with its kept bytes.
  await page.evaluate(() => document.querySelector('.remote-img[data-src$="/a.png"] button').click());
  const id = await page.evaluate(() => document.querySelector('.remote-img[data-src$="/a.png"]').dataset.remoteId);
  await page.evaluate(([id, url]) => window.readout.remoteReady({ id, url }), [id, GIF]);
  // The block is drawn again (an agent's edit): the image, not the button.
  await draw(11, [ph(1, `${T}/a.png`), ph(2, `https://other.example/x.png`), ph(3, `${T}/a.png`)]);
  const redrawn = await state();
  check('an image loaded once is drawn again without asking',
    redrawn[0] === `img:${GIF.slice(0, 22)}` && redrawn[2] === redrawn[0] && redrawn[1].startsWith('btn:'), JSON.stringify(redrawn));
  check('drawing it again asks the app for nothing', (await loads()).length === 1, JSON.stringify(await loads()));

  // Images known to the app from another window (remoteKnown) show at once,
  // and whenever their block is drawn again; others stay placeholders.
  await page.evaluate(([src, url]) => window.readout.remoteKnown({ [src]: url }), ['https://other.example/x.png', GIF]);
  await draw(12, [ph(1, 'https://other.example/x.png'), ph(2, `https://${TRACK}/new.png`)]);
  const fromApp = await state();
  check('an image the app already holds shows without a click',
    fromApp[0].startsWith('img:') && fromApp[1].startsWith('btn:'), JSON.stringify(fromApp));

  // Several placeholders of one host: the first click loads that one and
  // offers the rest; the offer loads every one of that host, none of another.
  await draw(13, [ph(1, `${T}/1.png`), ph(2, `${T}/2.png`), ph(3, 'https://cdn.example/3.png'), ph(4, `${T}/4.png`)]);
  await reset();
  await page.evaluate(() => document.querySelector('.remote-img[data-src$="/1.png"] button').click());
  const offer = await state();
  check('one click loads one image', JSON.stringify(await loads()) === JSON.stringify([`${T}/1.png`]), JSON.stringify(await loads()));
  check('the host\'s other placeholders offer to load them all',
    offer[0].startsWith('busy:') && offer[1] === `btn:Load all images from ${TRACK}` && offer[3] === offer[1] && offer[2] === 'btn:Load image from cdn.example',
    JSON.stringify(offer));
  await reset();
  await page.evaluate(() => document.querySelector('.remote-img[data-src$="/4.png"] button').click());
  check('one more click loads all of that host and nothing else',
    JSON.stringify((await loads()).sort()) === JSON.stringify([`${T}/2.png`, `${T}/4.png`]), JSON.stringify(await loads()));
  await page.waitForTimeout(500);
  check('no direct requests from remembered or offered images', escaped === 0, `escaped=${escaped}`);
}

// Diagrams: Mermaid and every chunk it loads come from the app's own files,
// never the network. A flowchart loads the core and the flowchart's chunks,
// not every kind of diagram.
{
  const requests = [];
  const missing = [];
  page.on('request', r => requests.push(r.url()));
  page.on('response', r => { if (r.status() >= 400) missing.push(`${r.status()} ${r.url()}`); });
  const block = src => `<div class="mermaid-block"><pre class="mermaid-src">${src}</pre></div>`;
  const draw = sources => page.evaluate(async sources => {
    window.readout.apply({ version: 2, reset: true, rewrite: false, marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 },
      ops: sources.map((html, i) => ({ op: 'insert', slot: i + 1, after: i, kind: 'mermaid', html })) });
    const blocks = () => [...document.querySelectorAll('.mermaid-block')];
    for (let i = 0; i < 1500 && !blocks().every(b => b.classList.contains('done') || b.querySelector('.mermaid-error')); i++) {
      // To the first not drawn yet, and left there (a diagram is drawn once the page stops scrolling: mermaid.js).
      const b = blocks().find(b => !b.classList.contains('done') && !b.querySelector('.mermaid-error'));
      const r = b?.getBoundingClientRect();
      if (r && (r.bottom < 0 || r.top > innerHeight)) b.scrollIntoView();
      await new Promise(r => setTimeout(r, 20));
    }
    return blocks().map(b => b.classList.contains('done') ? 'done' : (b.querySelector('.mermaid-error')?.textContent || 'pending'));
  }, sources.map(block));
  const vendorBytes = () => requests.filter(u => u.startsWith(`${base}/vendor/mermaid/`))
    .reduce((n, u) => n + statSync(join('build/Web', new URL(u).pathname)).size, 0);
  const flow = await draw(['graph TD\n  A[Start] --> B{Choice}\n  B --> C[End]']);
  const flowBytes = vendorBytes();
  console.log(`Mermaid loaded for one flowchart: ${(flowBytes / 1e6).toFixed(2)} MB in ${requests.filter(u => u.includes('/vendor/mermaid/')).length} files`);
  const kinds = await draw([
    'sequenceDiagram\n  Alice->>Bob: Hi\n  Bob-->>Alice: Hello',
    'classDiagram\n  Animal <|-- Duck',
    'stateDiagram-v2\n  [*] --> Still\n  Still --> [*]',
    'erDiagram\n  CUSTOMER ||--o{ ORDER : places',
    'gantt\n  title Plan\n  dateFormat YYYY-MM-DD\n  section A\n  Task :a1, 2024-01-01, 3d',
    'pie title Pets\n  "Dogs" : 386\n  "Cats" : 85',
    'mindmap\n  root((Plan))\n    A\n    B',
    'gitGraph\n  commit\n  branch dev\n  commit',
    'journey\n  title Day\n  section Work\n  Code: 5: Me',
    'timeline\n  title History\n  2024 : Start',
  ]);
  const external = requests.filter(u => !u.startsWith(`${base}/`));
  check('a flowchart draws from the bundled ESM build, loading only what it needs',
    flow[0] === 'done' && !requests.some(u => u.endsWith('mermaid.min.js')) && flowBytes > 0 && flowBytes < 3_000_000,
    JSON.stringify({ flow, flowBytes }));
  check('every kind of diagram draws from bundled chunks', kinds.every(k => k === 'done'), JSON.stringify(kinds));
  check('diagrams make no external requests and miss no file', external.length === 0 && missing.length === 0 && escaped === 0,
    JSON.stringify({ external, missing }));
}

check('no page errors', errors.length === 0, errors.join('; ').slice(0, 500));

await browser.close();
server.close();
process.exit(failures ? 1 : 0);
