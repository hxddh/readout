// Privacy probe: renders hostile remote-resource constructs and counts how
// many external requests escape. Run with:
//   BROWSER=webkit node test/privacy.test.mjs   (CI; the shipping engine)
// Usage: node test/privacy.test.mjs [TRACK_HOST]
// Requires web/build.mjs to have run. Exits nonzero on any failure.
import { chromium, webkit, firefox } from 'playwright';
import http from 'node:http';
import { readFileSync, existsSync } from 'node:fs';
import { extname, join } from 'node:path';

const TRACK = process.argv[2] || 'track.example';

const types = { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css' };
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
page.on('pageerror', e => errors.push(String(e)));

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

check('no page errors', errors.length === 0, errors.join('; ').slice(0, 500));

await browser.close();
server.close();
process.exit(failures ? 1 : 0);
