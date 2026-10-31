// Holds: what waits for code on screen to be coloured (`then`), and for
// math there to be typeset (then the height it keeps: after the frame that
// shows it, it would move what is below it, or what is above it, the place
// kept), for HOLD_MS at most: what highlighting it on this thread took the
// frame before (the lines a block shows where the reader lands come first).
// (Diagrams and images are not waited for: enhance.js, reserve.) A
// document's first paint waits with the document hidden (a reset: none of
// the old document is left; code it shows again is coloured at once,
// keepColours, and waits for nothing); a jump waits before it scrolls
// (enhance.js: holdJump); find, before it selects a match in code
// (highlighting replaces the text). An edit shows the code it keeps
// coloured at once, the rest plain until it arrives.
import { doc, firstTimings } from './core.js';
import { typesetting } from './math.js';
import { urge as urgeCode, calm as calmCode, uncoloured } from './code.js';

const holds = new Set();
const HOLD_MS = 3000;
/** The hold, or null: nothing to wait for (`then` is not called then). */
export function hold(cbs, then, dy = 0, upto) {
  const h = { cbs: new Set(), then, all: cbs };
  for (const cb of cbs) { h.cbs.add(cb); urge(cb, dy, upto); }
  for (const cb of h.cbs) if (!waits(cb)) h.cbs.delete(cb);
  if (!h.cbs.size) return null;
  h.timer = setTimeout(() => release(h), HOLD_MS);
  holds.add(h);
  return h;
}
// A hold over: what it waited for no more urgent than the rest on screen.
function calm(h) {
  for (const cb of h.all) calmCode(cb);
}
function release(h) {
  if (!holds.delete(h)) return;
  clearTimeout(h.timer);
  calm(h);
  h.then();
}
/** Hold `h` (or none) no longer wanted: `then` is not called. */
export function drop(h) {
  if (!h) return;
  holds.delete(h);
  clearTimeout(h.timer);
  calm(h);
}

/** Whether a hold waits for `x`. */
export function held(x) {
  for (const h of holds) if (h.cbs.has(x)) return true;
  return false;
}
/**
 * `cb` shows coloured (all of it, or what the screen shows of it), math
 * typeset: what waited for it goes on.
 */
export function shown(cb) {
  for (const h of [...holds]) if (h.cbs.delete(cb) && !h.cbs.size) release(h);
}

// Code not coloured on screen yet (neither all of it, nor its lines on
// screen); math waiting for KaTeX.
export const isCode = x => x.classList.contains('code-block');
export const waits = cb => isCode(cb) ? uncoloured(cb) : typesetting.has(cb);
export const pending = blocks => blocks.flatMap(b => [...b.querySelectorAll('.code-block[data-hl="pending"], .math, .math-block')].filter(waits));
/** What a hold waits for, asked for first: code highlighted (math is typeset once KaTeX is in). */
function urge(x, dy, upto) {
  if (isCode(x)) urgeCode(x, dy, upto);
}

/**
 * `then` once the code in `blocks` is coloured as far as `line` and a
 * screen below it (find: before it selects a match there, on that line).
 * Returns a cancel.
 */
export function whenColoured(blocks, then, line = 0) {
  const h = hold(pending(blocks), then, 0, line + Math.ceil((innerHeight + 120) / 16));
  if (!h) then();
  return () => drop(h);
}

let firstPaint = null;   // the hold of a document's first paint, the document hidden meanwhile
let unshown = false;     // a document shown anew, its first frame still to come
/** A document is shown anew (renderLazy): its first frame is still to come. */
export function shownAnew() {
  unshown = true;
  requestAnimationFrame(() => { unshown = false; });
}
/** Whether a document shown anew has not been painted yet (its place restored), or its first paint waits. */
export const unpainted = () => !!firstPaint || unshown;
/** The first paint of a document shown anew waits for `xs` too (with the document hidden). */
export function holdFirst(xs, dy, upto) {
  if (!firstPaint) {
    const t0 = performance.now();
    firstPaint = hold(xs, () => {
      firstPaint = null;
      doc.classList.remove('hold');
      // How long the first paint waited for the code it shows (SmokeTest: cold_page_hold_ms).
      firstTimings.hold ??= Math.round(performance.now() - t0);
    }, dy, upto);
    if (firstPaint) doc.classList.add('hold');
  } else for (const x of xs) { firstPaint.cbs.add(x); urge(x, dy, upto); if (!waits(x)) firstPaint.cbs.delete(x); }
}
/**
 * After the frame that shows the document: rAF runs before the paint, the
 * task it queues runs after. (A first paint held since, its place restored
 * meanwhile: after the frame that shows that.)
 */
export function afterShown(f) {
  const next = () => requestAnimationFrame(() => {
    // The first frame after the first apply, page time (SmokeTest: cold_page_raf_at_ms).
    firstTimings.raf_at ??= Math.round(performance.now());
    setTimeout(() => { if (firstPaint) afterShown(f); else f(); }, 0);
  });
  if (firstPaint) { const then = firstPaint.then; firstPaint.then = () => { then(); next(); }; } else next();
}
