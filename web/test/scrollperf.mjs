// Scrolling a large document, measured in the page (perf.test.mjs): frame
// gaps, the page's own longest callback, and blank area, while the reader
// scrolls down through parts not seen yet three ways: a steady 2400 px/s,
// flings (9000 px/s decaying), and the browser's own wheel events (120 px
// notches every 50 ms, the platform's scrolling path).
//
// Blank: the viewport rows over blocks whose content WebKit skipped
// (content-visibility), measured at the start of each frame, which is the
// state the last frame painted. A block counts when its first child is not
// visible to checkVisibility({contentVisibilityAuto: true}).

/** Before the page loads: times the page's own callbacks (not the harness's, tagged __h). */
export async function instrument(page) {
  await page.addInitScript(() => {
    const log = window.__own = [];
    window.__ownOn = false;
    const wrap = f => {
      if (typeof f !== 'function' || f.__h) return f;
      return function (...a) {
        const t = performance.now();
        try { return f.apply(this, a); } finally { if (window.__ownOn) log.push(performance.now() - t); }
      };
    };
    const raf = window.requestAnimationFrame.bind(window);
    window.requestAnimationFrame = f => raf(wrap(f));
    const st = window.setTimeout.bind(window);
    window.setTimeout = (f, ...a) => st(wrap(f), ...a);
    for (const O of ['IntersectionObserver', 'ResizeObserver', 'MutationObserver']) {
      const C = window[O];
      window[O] = class extends C { constructor(f, o) { super(wrap(f), o); } };
    }
    const ael = EventTarget.prototype.addEventListener;
    EventTarget.prototype.addEventListener = function (t, f, o) { return ael.call(this, t, /^(scroll|wheel)$/.test(t) ? wrap(f) : f, o); };
  });
}

const MODES = ['wheel', 'fling', 'input'];

/** Scrolls `page` (a document applied and settled) each way for `ms`, from three places not seen yet. */
export async function scrollPasses(page, { ms = 6000, inset = 0 } = {}) {
  const out = { gaps: [], blank: [], own: [] };
  await page.mouse.move(450, 450);
  for (const [i, mode] of MODES.entries()) {
    await page.evaluate(i => window.scrollTo(0, Math.round(document.scrollingElement.scrollHeight * (0.15 + 0.25 * i))), i);
    await page.waitForTimeout(1000);
    await page.evaluate(() => { window.__own.length = 0; window.__ownOn = true; window.__stop = false; });
    const run = page.evaluate(({ mode, ms, inset }) => new Promise(resolve => {
      const se = document.scrollingElement, vh = innerHeight;
      // Viewport rows over content WebKit has not rendered, whatever holds
      // the blocks: from what is under the top of the viewport, block by block
      // through chunks laid out, and a chunk at a time through one skipped
      // (a hit on a chunk itself is one: its blocks fill it). Asking a block
      // in a skipped chunk where it is would lay the chunk out: never done.
      const cvAuto = { contentVisibilityAuto: true };
      const isChunk = e => !!e && e.classList.contains('chunk');
      const unitOf = c => { const f = c.querySelector('.blk'); return f && (f.firstElementChild ?? f).checkVisibility(cvAuto) ? f : c; };
      const next = u => {
        if (isChunk(u)) return isChunk(u.nextElementSibling) ? unitOf(u.nextElementSibling) : null;
        for (let n = u.nextElementSibling; n; n = n.nextElementSibling) if (n.classList.contains('blk')) return n;
        return isChunk(u.parentElement) && isChunk(u.parentElement.nextElementSibling) ? unitOf(u.parentElement.nextElementSibling) : null;
      };
      const blank = () => {
        let u = null;
        for (let y = inset + 2; !u && y < vh; y += 16) { const hit = document.elementFromPoint(450, y); u = hit && (hit.closest('.blk') || hit.closest('.chunk')); }
        let px = 0;
        for (; u; u = next(u)) {
          const r = u.getBoundingClientRect();
          if (r.top >= vh) break;
          const shown = !isChunk(u) && (u.firstElementChild ?? u).checkVisibility(cvAuto);
          if (!shown) px += Math.max(0, Math.min(r.bottom, vh) - Math.max(r.top, inset));
        }
        return Math.round(px);
      };
      const gaps = [], blanks = [];
      let last = performance.now(), v = 0, flingAt = -1e9;
      const t0 = last;
      const frame = Object.assign(now => {
        const dt = now - last;
        gaps.push(dt); last = now;
        blanks.push(blank());
        if (se.scrollTop >= se.scrollHeight - vh - 1 || now - t0 > ms || window.__stop) return resolve({ gaps: gaps.slice(1), blanks: blanks.slice(1) });
        const s = Math.min(dt, 100) / 1000;
        if (mode === 'wheel') window.scrollBy(0, 2400 * s);
        else if (mode === 'fling') {
          if (now - flingAt > 1200) { flingAt = now; v = 9000; }
          window.scrollBy(0, v * s);
          v *= Math.exp(-s / 0.35);
        }
        requestAnimationFrame(frame);
      }, { __h: true });
      requestAnimationFrame(frame);
    }), { mode, ms, inset });
    if (mode === 'input') {
      const t0 = Date.now();
      while (Date.now() - t0 < ms - 100) { await page.mouse.wheel(0, 120); await new Promise(r => setTimeout(r, 50)); }
      await page.evaluate(() => { window.__stop = true; });
    }
    const r = await run;
    out.gaps.push(...r.gaps);
    out.blank.push(...r.blanks);
    out.own.push(...await page.evaluate(() => { window.__ownOn = false; return window.__own.slice(); }));
  }
  return out;
}

/** The numbers perf-web.json reports for a set of passes. */
export function summary({ gaps, blank, own }) {
  const s = gaps.slice().sort((a, b) => a - b);
  const r1 = x => Math.round(x * 10) / 10;
  return {
    frames: gaps.length,
    p95: r1(s[Math.floor(s.length * 0.95)] ?? 0),
    max: Math.round(s[s.length - 1] ?? 0),
    long: gaps.filter(g => g > 50).length,
    blankPx: blank.reduce((a, b) => a + b, 0),
    blankFrames: blank.filter(b => b > 0).length,
    ownMax: Math.round(Math.max(0, ...own)),
  };
}

/**
 * Interactions in a large document, each until the frame after it is
 * painted (median): a change of the selection, a mouse drag's 20 changes
 * (total), the dark/light switch, Next in a find (when the page finds).
 */
export async function interactions(page) {
  await page.evaluate(() => window.scrollTo(0, document.scrollingElement.scrollHeight * 0.4));
  await page.waitForTimeout(1500);
  return page.evaluate(async () => {
    const frame = f => new Promise(res => { const t0 = performance.now(); f(); requestAnimationFrame(() => setTimeout(() => res(performance.now() - t0), 0)); });
    const med = xs => xs.slice().sort((a, b) => a - b)[xs.length >> 1];
    const textOnScreen = () => {
      const w = document.createTreeWalker(document.elementFromPoint(450, 450).closest('.blk'), NodeFilter.SHOW_TEXT, { acceptNode: n => n.data.length > 10 ? 1 : 3 });
      return w.nextNode();
    };
    const out = {};
    const sel = [];
    for (let i = 0; i < 5; i++) { const t = textOnScreen(); sel.push(await frame(() => getSelection().setBaseAndExtent(t, 0, t, 5 + i))); }
    out.select = med(sel);
    const t = textOnScreen(), t0 = performance.now();
    for (let i = 0; i < 20; i++) await frame(() => getSelection().setBaseAndExtent(t, 0, t, Math.min(t.data.length, 1 + i)));
    out.drag = performance.now() - t0;
    getSelection().removeAllRanges();
    const theme = [];
    for (const dark of [true, false, true, false]) theme.push(await frame(() => window.readout.setAppearance({ dark })));
    out.theme = med(theme);
    if (window.readout.find) {
      // A word of one text node (a block's textContent runs table cells together).
      const w = document.createTreeWalker(document.elementFromPoint(450, 450).closest('.blk'), NodeFilter.SHOW_TEXT, { acceptNode: n => /[A-Za-z]{6,}/.test(n.data) ? 1 : 3 });
      const word = w.nextNode()?.data.match(/[A-Za-z]{6,}/)[0] || 'agent';
      out.findCount = window.readout.find(word);
      await new Promise(r => setTimeout(r, 1000));
      const next = [];
      for (let i = 0; i < 5; i++) { next.push(await frame(() => window.readout.find(word))); await new Promise(r => setTimeout(r, 300)); }
      out.findNext = med(next);
      out.findSelected = out.findCount > 0 && getSelection().toString().toLowerCase() === word.toLowerCase();
      window.readout.findEnd();
    }
    return out;
  });
}

/**
 * An agent streaming at the end, the reader following: a patch every 100 ms
 * (every fifth appends a paragraph, the others write on into it) for `ms`,
 * and the frame gaps meanwhile.
 */
export async function streamFrames(page, slot, ms = 4000) {
  for (let k = 0; k < 3; k++) {
    await page.evaluate(() => window.scrollTo(0, document.scrollingElement.scrollHeight));
    await page.waitForTimeout(300);
  }
  return page.evaluate(({ slot, ms }) => new Promise(resolve => {
    const gaps = [];
    let last = performance.now(), i = 0, s = slot, stop = false;
    const t0 = last;
    const frame = Object.assign(now => { gaps.push(now - last); last = now; if (!stop) requestAnimationFrame(frame); }, { __h: true });
    requestAnimationFrame(frame);
    const tick = Object.assign(() => {
      const text = n => `<p>Streaming paragraph ${n} with some words of agent output that keeps going.${' more'.repeat(i % 5 * 8)}</p>`;
      const ops = i % 5 === 0 ? [{ op: 'insert', slot: ++s, after: s - 1, kind: 'paragraph', html: text(i) }]
        : [{ op: 'replace', slot: s, change: 'content', kind: 'paragraph', html: text(i - (i % 5)) }];
      window.readout.apply({ version: 1000 + i, reset: false, rewrite: false, ops, marks: [{ slot: s, kind: 'inserted' }], deletions: [], toc: [], tasks: { done: 0, total: 0 } });
      i++;
      if (performance.now() - t0 < ms) setTimeout(tick, 100);
      else { stop = true; setTimeout(() => resolve({ gaps: gaps.slice(1), slot: s }), 50); }
    }, { __h: true });
    setTimeout(tick, 100);
  }), { slot, ms });
}

/**
 * An agent inserting three blocks in the middle of the document, far from
 * the reader (a quarter of the way down), then removing them: the apply
 * plus the layout it causes (median of six).
 */
export async function insertMiddle(page, ops, slot) {
  await page.evaluate(() => window.scrollTo(0, document.scrollingElement.scrollHeight * 0.25));
  await page.waitForTimeout(800);
  const after = ops[Math.floor(ops.length * 0.6)].slot;
  const times = [];
  for (let i = 0; i < 6; i++) {
    const slots = [slot + 1 + 3 * i, slot + 2 + 3 * i, slot + 3 + 3 * i];
    const add = slots.map((s, k) => ({ op: 'insert', slot: s, after: k ? slots[k - 1] : after, kind: 'paragraph', html: `<p>Inserted ${s} by the agent in the middle of the plan.</p>` }));
    for (const o of [add, slots.map(s => ({ op: 'remove', slot: s }))]) {
      times.push(await page.evaluate(ops => {
        const t0 = performance.now();
        window.readout.apply({ version: 3000 + Math.round(performance.now()), reset: false, rewrite: false, ops, marks: [], deletions: [], toc: [], tasks: { done: 0, total: 0 } });
        void document.scrollingElement.scrollHeight;
        return performance.now() - t0;
      }, o));
      await page.waitForTimeout(150);
    }
  }
  return times.sort((a, b) => a - b)[times.length >> 1];
}
