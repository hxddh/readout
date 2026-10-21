// Page-side performance of a large document, in WebKit.
//
// Builds a ~1 MB document by chaining the real-agent corpus patches, then
// measures: the first apply (synchronous, and until painted), a 20-block update patch on top of it,
// the find bar's first search and its refresh after an edit, and how far the text jumps scrolling up from the end; in a ~5 MB document,
// an edit above the reader, outline jumps, Return in a one-letter find, and an agent streaming at its end
// while the reader follows; on a fresh warmed page, the first apply of a small
// document whose code block is on screen, then a small plan's private memory;
// on a fresh page not warmed, how long its first TypeScript block takes to
// highlight. Writes the numbers to
// test/out/perf-web.json; tools/perf-assert.py checks them against
// tools/perf-budgets.json.
//
// Usage: node test/perf.test.mjs
import { webkit } from 'playwright';
import http from 'node:http';
import { readFileSync, writeFileSync, existsSync, mkdirSync, readdirSync } from 'node:fs';
import { extname, join } from 'node:path';
import { execSync } from 'node:child_process';
import { collectPageErrors } from './pageerrors.mjs';

const types = { '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.css': 'text/css', '.woff2': 'font/woff2', '.woff': 'font/woff', '.ttf': 'font/ttf' };
const server = http.createServer((req, res) => {
  const p = join('build/Web', decodeURIComponent(req.url.split('?')[0]));
  if (!existsSync(p)) { res.writeHead(404); return res.end(); }
  res.writeHead(200, { 'content-type': types[extname(p)] || 'application/octet-stream' });
  res.end(readFileSync(p));
}).listen(0);
const base = `http://127.0.0.1:${server.address().port}`;

// Chain corpus patches into one document of at least `target` bytes of HTML.
const files = readdirSync('test/corpus/patches').filter(f => f.endsWith('.json')).sort();
function chain(target) {
  const ops = [];
  let slot = 0, bytes = 0;
  for (let round = 0; bytes < target; round++) {
    for (const f of files) {
      const p = JSON.parse(readFileSync(`test/corpus/patches/${f}`, 'utf8'));
      for (const op of p.ops) {
        if (op.op !== 'insert') continue;
        ++slot;
        ops.push({ ...op, slot, after: slot - 1, anchor: op.anchor ? `${op.anchor}-${round}-${slot}` : undefined });
        bytes += op.html.length;
      }
      if (bytes >= target) break;
    }
  }
  return { ops, bytes };
}
const { ops, bytes } = chain(1_000_000);
const big = { version: 1, reset: true, rewrite: false, ops, marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 } };
const paragraphs = ops.filter(o => o.kind === 'paragraph');
const step = Math.floor(paragraphs.length / 20);
const edit = {
  version: 2, reset: false, rewrite: false,
  ops: paragraphs.filter((_, i) => i % step === 0).slice(0, 20)
    .map(o => ({ ...o, op: 'replace', change: 'modified', html: o.html.replace('</p>', ' (revised)</p>') })),
  marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 },
};
edit.marks = edit.ops.map(o => ({ slot: o.slot, kind: 'modified' }));

const browser = await webkit.launch();
const page = await browser.newPage({ viewport: { width: 900, height: 900 } });
const errors = [];
collectPageErrors(page, errors);
await page.addInitScript(() => {
  window.__msgs = [];
  window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } };
});
await page.goto(`${base}/reader.html`);
await page.evaluate(() => new Promise(r => { const t = () => window.readout && window.__msgs.some(m => m.type === 'ready') ? r() : setTimeout(t, 20); t(); }));
await page.evaluate(() => window.readout.setAppearance({ dark: false, accent: '#0a84ff', width: 'narrow', fontSize: 16 }));

const median = xs => xs.slice().sort((a, b) => a - b)[Math.floor(xs.length / 2)];

// First apply of the whole document, timed in the page: the apply itself
// (which reads no layout: the first frame lays out only what is on screen),
// and until the frame that shows it has been painted (the moment the page
// reports 'painted': a task queued from the frame's animation callbacks runs
// after its paint). Nothing is measured in between: forcing a layout there
// would lay out every block, which the page no longer does.
const firstApply = await page.evaluate(p => new Promise(resolve => {
  const t0 = performance.now();
  window.readout.apply(p);
  const sync = performance.now() - t0;
  requestAnimationFrame(() => setTimeout(() => resolve({ sync, painted: performance.now() - t0 }), 0));
}), big);
await page.waitForTimeout(1500);

// A 20-block update in the middle of reading, three times, each with new
// text: the apply plus the layout it causes. The page settles after the
// scroll first, so what the scroll causes is not counted in the update: the
// blocks it brings on screen laid out at their real heights, the resize
// observer keeping the place (a scroll of its own, then the page laid out
// again), the code on screen highlighted. Two frames were not enough: right
// after them a layout of the whole page (70-130 ms on CI) was still due, and
// the first read of the update paid it, in every first update and in about
// one run in ten in the second too, which made the median.
const updates = [];
const settled = () => page.evaluate(() => new Promise(resolve => {
  // Eight 50 ms timers in a row on time (the main thread free for 400 ms), then two frames.
  let quiet = 0, due = performance.now() + 50;
  const tick = () => {
    quiet = performance.now() - due < 10 ? quiet + 1 : 0;
    if (quiet >= 8) return requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(resolve, 0)));
    due = performance.now() + 50;
    setTimeout(tick, 50);
  };
  setTimeout(tick, 50);
}));
for (let i = 0; i < 3; i++) {
  await page.evaluate(y => window.scrollTo(0, y), 20000 + i * 5000);
  await settled();
  const patch = { ...edit, version: 2 + i, ops: edit.ops.map(o => ({ ...o, html: o.html.replace('(revised)', `(revised ${i + 1})`) })) };
  updates.push(await page.evaluate(p => {
    const t0 = performance.now();
    window.readout.apply(p);
    void document.scrollingElement.scrollHeight;
    return performance.now() - t0;
  }, patch));
  await page.waitForTimeout(300);
}

// The find bar's first search in the 1 MB document (⌘F, a word, Return): it
// reads every block's text (no layout), counts the matches and selects the
// first one, on screen (going to one off screen is an outline jump's cost:
// web_toc_jump_5mb_ms). 3.8 laid out the whole document as the find bar
// opened, and again as it closed. Three times, from nothing found before.
const findOpen = [];
for (let i = 0; i < 3; i++) {
  findOpen.push(await page.evaluate(() => {
    getSelection().removeAllRanges();
    const blk = document.elementFromPoint(450, 450).closest('.blk');
    const word = [blk, blk.nextElementSibling, blk.previousElementSibling].map(b => b && b.textContent.match(/[A-Za-z]{6,}/)).find(Boolean)[0];
    const t0 = performance.now();
    const n = window.readout.find(word);
    const ms = performance.now() - t0;
    window.readout.findEnd();
    return n > 0 ? ms : -1;
  }));
  await settled();
}
if (findOpen.some(ms => ms < 0)) errors.push(`find found nothing: ${findOpen}`);
// While the find bar is open, an agent's one-block edit: the page searches
// again for the count and the marks (find.js refresh), per patch.
await page.evaluate(() => { window.readout.find('the'); });
const findRefresh = [];
for (let i = 0; i < 3; i++) {
  const o = paragraphs[i * 7 + 3];
  await page.evaluate(p => window.readout.apply(p), { version: 50 + i, reset: false, rewrite: false, ops: [{ ...o, op: 'replace', change: 'content', html: o.html.replace('</p>', ` the edit ${i}</p>`) }],
    marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 } });
  await page.waitForTimeout(400);
  findRefresh.push(await page.evaluate(() => performance.getEntriesByName('readout-find-refresh').pop()?.detail ?? -1));
}
await page.evaluate(() => window.readout.findEnd());
if (findRefresh.some(ms => ms < 0)) errors.push(`find refresh not measured: ${findRefresh}`);

// Scrolling up from the end through blocks not laid out yet (each shows at
// its estimated height until WebKit lays it out, a frame after it came into
// view): 40 steps of 400 px, one per frame, and how far the text that was
// under the middle of the window moved beyond the scroll, summed.
const scrollUpJump = await page.evaluate(() => new Promise(async resolve => {
  const settle = () => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(() => setTimeout(r, 300))));
  for (let k = 0; k < 2; k++) { window.scrollTo(0, document.scrollingElement.scrollHeight); await settle(); }
  let sum = 0, steps = 0, el = null, top = 0;
  const after = () => {
    if (el) { sum += Math.abs(el.getBoundingClientRect().top - top - 400); steps++; }
    if (steps >= 40) return resolve(Math.round(sum));
    el = document.elementFromPoint(450, 450).closest('.blk');
    top = el.getBoundingClientRect().top;
    requestAnimationFrame(() => { window.scrollBy(0, -400); requestAnimationFrame(() => setTimeout(after, 0)); });
  };
  after();
}));

await page.close();

// An agent streaming at the end of a ~5 MB document, the reader following:
// every fifth patch appends a paragraph, the others write on into it (the
// agent's last block growing), each with the unread marks of the last
// fifty. The apply plus the layout it causes, per patch. What the page
// does per patch must not grow with the document (3.6: about 105 ms per
// patch at 5 MB, most of it the page's own searches and layouts).
// Reported, not gated (tools/perf-budgets.json): the engine's own layout
// of a 25,000-block page is in it.
const streamStart = Date.now();
const stream = await (async () => {
  const p5 = await browser.newPage({ viewport: { width: 900, height: 900 } });
  collectPageErrors(p5, errors, '5 MB: ');
  await p5.addInitScript(() => {
    window.__msgs = [];
    window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } };
  });
  await p5.goto(`${base}/reader.html`);
  await p5.evaluate(() => new Promise(r => { const t = () => window.readout && window.__msgs.some(m => m.type === 'ready') ? r() : setTimeout(t, 20); t(); }));
  await p5.evaluate(() => window.readout.setAppearance({ dark: false, accent: '#0a84ff', width: 'narrow', fontSize: 16 }));
  const doc5 = chain(5_000_000);
  await p5.evaluate(p => new Promise(r => { window.readout.apply(p); requestAnimationFrame(() => setTimeout(r, 0)); }),
    { version: 1, reset: true, rewrite: false, ops: doc5.ops, marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 } });
  await p5.waitForTimeout(1000);
  const frames = () => p5.evaluate(() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))));
  // An agent editing a block 50 blocks above the reader, mid-document, six
  // times: the apply plus the layout it causes (3.7: a style write on the
  // block, already laid out, made WebKit lay out every skipped block again).
  await p5.evaluate(() => window.scrollTo(0, document.scrollingElement.scrollHeight / 2));
  await frames();
  await p5.waitForTimeout(500);
  const above = await p5.evaluate(() => {
    let e = document.elementFromPoint(450, 300).closest('.blk');
    for (let i = 0; i < 50; i++) e = e.previousElementSibling;
    return +e.dataset.slot;
  });
  const aboveOp = doc5.ops.find(o => o.slot === above);
  const edits = [];
  for (let i = 0; i < 6; i++) {
    const html = aboveOp.html.replace(/<\/(p|li|h\d)>/, ` grows ${'x '.repeat((i % 3 + 1) * 25)}</$1>`);
    const patch = { version: 100 + i, reset: false, rewrite: false, ops: [{ op: 'replace', slot: above, change: 'content', kind: aboveOp.kind, html }],
      marks: [{ slot: above, kind: 'modified' }], deletions: [], toc: [], tasks: { done: 0, total: 0 } };
    edits.push(await p5.evaluate(p => { const t0 = performance.now(); window.readout.apply(p); void document.scrollingElement.scrollHeight; return performance.now() - t0; }, patch));
    await frames();
    await p5.waitForTimeout(200);
  }
  // Outline jumps from the top to headings 30%, 55% and 80% down: the jump
  // until the frame that shows where it landed is painted.
  const jumps = [];
  for (const frac of [0.3, 0.55, 0.8]) {
    await p5.evaluate(() => window.scrollTo(0, 0));
    await frames();
    await p5.waitForTimeout(300);
    jumps.push(await p5.evaluate(frac => new Promise(resolve => {
      const hs = document.querySelectorAll('#ro-doc > .blk.k-heading');
      const h = hs[Math.floor(hs.length * frac)];
      const t0 = performance.now();
      window.readout.scrollToSlot(+h.dataset.slot);
      requestAnimationFrame(() => setTimeout(() => resolve(performance.now() - t0), 0));
    }), frac));
    await p5.waitForTimeout(1200);
  }
  // Return in a find for one letter ("e": about 300,000 matches) at the top
  // of the 5 MB document, its match on screen: the two frames after the call
  // (the match is selected, in a smaller document, in the second). 3.9 before
  // the release review: 7-11 s (WebKit checking every block against the new
  // selection), the frames after a search slower with the number of matches.
  await p5.evaluate(() => window.scrollTo(0, 0));
  await frames();
  await p5.waitForTimeout(300);
  const oneLetter = [];
  const letterHits = await p5.evaluate(() => window.readout.find('e'));
  if (letterHits < 100_000) errors.push(`find "e" in 5 MB: ${letterHits} matches`);
  await p5.waitForTimeout(1500);
  for (let i = 0; i < 3; i++) {
    oneLetter.push(await p5.evaluate(() => new Promise(resolve => {
      const c0 = performance.now();
      window.readout.find('e');
      const t0 = performance.now();
      requestAnimationFrame(() => setTimeout(() => {
        const t1 = performance.now();
        requestAnimationFrame(() => setTimeout(() => resolve({ ms: performance.now() - t0, call: t0 - c0, first: t1 - t0 }), 0));
      }, 0));
    })));
    await p5.waitForTimeout(500);
  }
  await p5.evaluate(() => window.readout.findEnd());
  // To the end, again once the blocks there are laid out at their real
  // heights (the first scroll lands where their estimates put it).
  for (let k = 0; k < 3; k++) {
    await p5.evaluate(() => window.scrollTo(0, document.scrollingElement.scrollHeight));
    await frames();
    await p5.waitForTimeout(300);
  }
  let slot5 = doc5.ops.length, last = slot5;
  const marks = [];
  const times = [];
  for (let i = 0; i < 40; i++) {
    let ops5;
    if (i % 5 === 0) {
      last = ++slot5;
      marks.push({ slot: last, kind: 'inserted' });
      ops5 = [{ op: 'insert', slot: last, after: last - 1, kind: 'paragraph', html: `<p>Streaming paragraph ${i} with some words of agent output that keeps going.</p>` }];
    } else {
      ops5 = [{ op: 'replace', slot: last, change: 'content', kind: 'paragraph', html: `<p>Streaming paragraph ${i - (i % 5)} with some words of agent output that keeps going.${' more'.repeat(i % 5 * 8)}</p>` }];
    }
    const patch = { version: 2 + i, reset: false, rewrite: false, ops: ops5, marks: marks.slice(-50), deletions: [], toc: [], tasks: { done: 0, total: 0 } };
    times.push(await p5.evaluate(p => { const t0 = performance.now(); window.readout.apply(p); void document.scrollingElement.scrollHeight; return performance.now() - t0; }, patch));
    if (i % 10 === 0) await frames();
  }
  const left = await p5.evaluate(() => { const s = document.scrollingElement; return Math.round(s.scrollHeight - s.scrollTop - innerHeight); });
  await p5.close();
  return { bytes: doc5.bytes, blocks: doc5.ops.length, ms: median(times), left, edit: median(edits), jump: median(jumps), letter: median(oneLetter.map(x => x.ms)), letterSamples: oneLetter.map(x => [x.call, x.first, x.ms].map(Math.round)) };
})();
console.log(`5 MB streaming phase: ${Math.round((Date.now() - streamStart) / 1000)} s`);

// A TypeScript block for the first-highlight measures.
const TS_CODE = 'import { readFile } from "node:fs/promises";\n\n// Load the plan and count its open tasks.\nexport async function openTasks(path: string): Promise<number> {\n  const text = await readFile(path, "utf8");\n  return text.split("\\n").filter(l => /^- \\[ \\]/.test(l)).length;\n}';

// A page's WebContent process (Linux): the WebKit web processes this
// script started, and their private memory (smaps_rollup), in MB.
function webProcesses() {
  const rows = execSync('ps -eo pid,ppid,comm', { encoding: 'utf8' }).trim().split('\n').slice(1).map(l => l.trim().split(/\s+/));
  const kids = new Map();
  for (const [pid, ppid] of rows) kids.set(ppid, [...(kids.get(ppid) || []), pid]);
  const mine = new Set(), queue = [String(process.pid)];
  while (queue.length) for (const k of kids.get(queue.pop()) || []) { mine.add(k); queue.push(k); }
  return rows.filter(r => mine.has(r[0]) && /WebProces/.test(r[2])).map(r => r[0]);
}
function privateMemoryMB(pid) {
  try {
    const t = readFileSync(`/proc/${pid}/smaps_rollup`, 'utf8');
    const kb = k => +(t.match(new RegExp(`^${k}:\\s+(\\d+)`, 'm'))?.[1] || 0);
    return Math.round((kb('Private_Dirty') + kb('Private_Clean')) / 1024);
  } catch { return null; }
}

// The first code block of a warm open: a fresh page warmed as the app's
// spare page is (its grammars preloaded and compiled in idle time), then a
// small document with a TypeScript block on screen, highlighted inside the
// synchronous first apply.
const firstHighlight = await (async () => {
  const before = new Set(webProcesses());
  const p = await browser.newPage({ viewport: { width: 900, height: 900 } });
  collectPageErrors(p, errors);
  await p.addInitScript(() => {
    window.__msgs = [];
    window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } };
  });
  await p.goto(`${base}/reader.html`);
  await p.evaluate(() => new Promise(r => { const t = () => window.readout && window.__msgs.some(m => m.type === 'ready') ? r() : setTimeout(t, 20); t(); }));
  const pid = webProcesses().find(x => !before.has(x));
  await p.evaluate(() => { window.readout.warm(); window.readout.setAppearance({ dark: false, accent: '#0a84ff', width: 'narrow', fontSize: 16 }); });
  const warmed = await p.evaluate(() => new Promise(r => {
    const end = performance.now() + 40000;
    const t = () => performance.getEntriesByName('readout-hl-warm').length ? r(true) : performance.now() > end ? r(false) : setTimeout(t, 50);
    t();
  }));
  await p.waitForTimeout(200);
  const r = await p.evaluate(code => {
    const t0 = performance.now();
    window.readout.apply({ version: 1, reset: true, rewrite: false, marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 }, ops: [
      { op: 'insert', slot: 1, after: 0, kind: 'heading', anchor: 'plan', html: '<h1 id="plan">Plan</h1>' },
      { op: 'insert', slot: 2, after: 1, kind: 'paragraph', html: '<p>Count the open tasks:</p>' },
      { op: 'insert', slot: 3, after: 2, kind: 'code', html: `<div class="code-block" data-lang="ts"><pre><code>${code.replace(/&/g, '&amp;').replace(/</g, '&lt;')}</code></pre></div>` },
    ] });
    return { ms: performance.now() - t0, hl: document.querySelector('.code-block').dataset.hl };
  }, TS_CODE);
  // Then a small plan in the same tab, as a window opened from the spare
  // page shows it: the WebContent process's private memory (Linux smaps).
  await p.evaluate(plan => window.readout.apply(plan), JSON.parse(readFileSync('test/corpus/patches/01-sdd-fix-loop-plan.json', 'utf8')));
  await p.waitForTimeout(3000);
  const privateMB = privateMemoryMB(pid);
  await p.close();
  return { ...r, warmed, privateMB };
})();
if (!firstHighlight.warmed || firstHighlight.hl !== 'done') errors.push(`first highlight not measured: ${JSON.stringify(firstHighlight)}`);
if (firstHighlight.privateMB == null) errors.push('tab private memory not measured');

// The first TypeScript block on a page not warmed up (the first window at
// launch takes the spare page before its warm-up; a burst of background tabs
// gets pages made for them): the page set up as a window does, the document
// applied at once, until its code block is highlighted. Every grammar
// pattern is compiled on that block's first match.
const coldHighlight = await (async () => {
  const p = await browser.newPage({ viewport: { width: 900, height: 900 } });
  collectPageErrors(p, errors);
  await p.addInitScript(() => {
    window.__msgs = [];
    window.webkit = { messageHandlers: { readout: { postMessage: m => window.__msgs.push(m) } } };
  });
  await p.goto(`${base}/reader.html`);
  await p.evaluate(() => new Promise(r => { const t = () => window.readout && window.__msgs.some(m => m.type === 'ready') ? r() : setTimeout(t, 20); t(); }));
  const ms = await p.evaluate(code => new Promise(resolve => {
    window.readout.setAppearance({ dark: false, accent: '#0a84ff', width: 'narrow', fontSize: 16 });
    const t0 = performance.now();
    window.readout.apply({ version: 1, reset: true, rewrite: false, marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 }, ops: [
      { op: 'insert', slot: 1, after: 0, kind: 'heading', anchor: 'plan', html: '<h1 id="plan">Plan</h1>' },
      { op: 'insert', slot: 2, after: 1, kind: 'code', html: `<div class="code-block" data-lang="ts"><pre><code>${code.replace(/&/g, '&amp;').replace(/</g, '&lt;')}</code></pre></div>` },
    ] });
    const wait = () => {
      const hl = document.querySelector('.code-block').dataset.hl;
      if (hl === 'done') resolve(performance.now() - t0);
      else if (performance.now() - t0 > 30000) resolve(-1);
      else setTimeout(wait, 5);
    };
    wait();
  }), TS_CODE);
  await p.close();
  return ms;
})();
if (coldHighlight < 0) errors.push('cold first highlight not measured');

const result = {
  web_doc_bytes: bytes,
  web_doc_blocks: ops.length,
  web_first_apply_1mb_ms: Math.round(firstApply.sync),
  web_first_apply_1mb_painted_ms: Math.round(firstApply.painted),
  web_update_20_blocks_1mb_ms: Math.round(median(updates) * 10) / 10,
  web_update_20_blocks_1mb_samples_ms: updates.map(Math.round),
  web_find_open_1mb_ms: Math.round(median(findOpen) * 10) / 10,
  web_find_refresh_1mb_ms: Math.round(median(findRefresh) * 10) / 10,
  web_first_highlight_warm_ms: Math.round(firstHighlight.ms),
  web_first_highlight_cold_ts_ms: Math.round(coldHighlight),
  web_tab_private_mb: firstHighlight.privateMB,
  web_stream_doc_bytes: stream.bytes,
  web_stream_doc_blocks: stream.blocks,
  web_stream_append_5mb_ms: Math.round(stream.ms * 10) / 10,
  web_stream_end_left_px: stream.left,
  web_edit_above_5mb_ms: Math.round(stream.edit * 10) / 10,
  web_toc_jump_5mb_ms: Math.round(stream.jump),
  web_find_one_letter_5mb_ms: Math.round(stream.letter),
  web_find_one_letter_5mb_samples_ms: stream.letterSamples,   // [the call, the first frame, both frames]
  web_scroll_up_jump_px: scrollUpJump,
  errors,
};
mkdirSync('test/out', { recursive: true });
writeFileSync('test/out/perf-web.json', JSON.stringify(result, null, 1) + '\n');
console.log(JSON.stringify(result, null, 1));
await browser.close();
server.close();
process.exit(errors.length ? 1 : 0);
