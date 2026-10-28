// The page's side of syntax highlighting: Shiki runs in a worker
// (hl-worker.js, highlighter.js), so no highlighting is ever a task on the
// page's main thread. A code block asks for its HTML with a priority (on
// screen, near, far: enhance.js), and gets it back when the worker has it;
// the worker loads and compiles the grammars too (warm, prepareLangs).
//
// Where a worker cannot run (it cannot be made, or fails to start), the page
// runs the same highlighter itself, one block part a task: the same answers,
// on its own thread.
import { resolveLang, serve } from './highlighter.js';

export { resolveLang };

let early = [];           // what was posted before the highlighter was made (sent once it is)
let engine = m => early.push(m);   // posts a message to the highlighter
let worker = null;
let ready = null;         // resolves once the highlighter has started
let onReady = () => {};
const sent = [];          // what the highlighter was told besides blocks (given again to a fallback)
const asked = new Map();  // request id -> {msg, done}
let nextId = 1;
let mode = 'worker';
const READY_MS = 2000;
let alive = false;

/** Whether the highlighter has started (it answers within a part's time). */
export let started = false;

/** Where it runs: 'worker', 'page' (a worker could not), or 'starting' (the app's smoke test, Quick Look's log). */
export function engineName() { return started ? mode : 'starting'; }

function received(m) {
  if (m.op === 'done') {
    const r = asked.get(m.id);
    if (r) { asked.delete(m.id); r.done(m.html); }
  } else if (m.op === 'part') asked.get(m.id)?.part(m.html, m.lines, m.first);
  else if (m.op === 'loading') asked.get(m.id)?.loading();
  else if (m.op === 'mark') performance.mark(m.name, { detail: m.detail });
  else if (m.op === 'ready') { started = true; onReady(); }
  else if (m.op === 'hello') alive = true;
  else if (m.op === 'failed') fallBack();
  // The spare warm-up goes on only while no document is shown, as the page sees it now.
  else if (m.op === 'spare?') engine({ op: 'spare', n: m.n, ok: !shown });
}

/** The highlighter on the page's own thread, told again what the worker was. */
function fallBack() {
  if (worker) { worker.terminate(); worker = null; }
  mode = 'page';
  const handle = serve(received);
  engine = handle;
  for (const m of sent) handle(m);
  for (const r of asked.values()) handle(r.msg);
}

function tell(m) {
  // (What a fallback needs told again: the latest of each kind, the languages asked for before a document showed.)
  if (m.op !== 'prepare') for (let i = sent.length - 1; i >= 0; i--) if (sent[i].op === m.op) sent.splice(i, 1);
  if (m.op === 'shown') for (let i = sent.length - 1; i >= 0; i--) if (sent[i].op === 'warm' || sent[i].op === 'prepare') sent.splice(i, 1);
  sent.push(m);
  engine(m);
}

/** Starts the highlighter (the first appearance, or the app's warm-up): `quicklook` loads only what a preview needs. */
let quick = false;
/**
 * The highlighter is for Quick Look (it loads only the grammars a preview
 * shows), and starts a task later: making the worker is not part of the
 * appearance's task (nor of the first document's, which may ask first).
 */
let soon = false;
export function startSoon(quicklook) {
  if (soon || ready) return;   // (the first appearance says which)
  quick = quicklook;
  later();
}
// (A task from now: a block asking first, inside an apply, does not make it there either.)
function later() {
  if (soon || ready) return;
  soon = true;
  setTimeout(() => init(), 0);
}

export function init(quicklook = quick) {
  if (ready) return ready;
  ready = new Promise(r => { onReady = r; });
  try {
    worker = new Worker('hl-worker.js', { type: 'module' });
    worker.onmessage = e => { if (worker) received(e.data); };
    worker.onerror = worker.onmessageerror = () => { if (worker) fallBack(); };
    engine = m => worker.postMessage(m);
    // A worker that never says it runs (its script held up, a hang): the
    // page's own after a while. (It says so as soon as its module runs,
    // before it loads Shiki: a slow start is not taken for a hang.)
    setTimeout(() => { if (worker && !alive) fallBack(); }, READY_MS);
  } catch {
    mode = 'page';
    engine = serve(received);
  }
  tell({ op: 'init', quicklook, limit: globalThis.READOUT_TOKENIZE_LIMIT, spans: !!globalThis.READOUT_TOKEN_SPANS, cut: !!globalThis.READOUT_CUT_FIRST_PART });
  for (const m of early.splice(0)) engine(m);
  return ready;
}

/**
 * Asks for `code` highlighted as `lang` (a resolved id), `prio` 0 the most
 * urgent; `done(html)` gets the <pre>'s HTML, or null (not highlighted).
 * `upto`: the lines the screen shows of it, which `part(html, lines, true)`
 * gets first when there are more (a <pre> of the first `lines`); then, with
 * `stream`, `part(html, lines, false)` each part after (its lines' HTML,
 * `lines` done so far), the last too, and done('') (all of it sent).
 * `loading()`: its grammars are being loaded first (it will take a while).
 * Returns the request's id.
 */
export function request(code, lang, prio, upto, stream, { done, part, loading }) {
  later();
  const id = nextId++;
  const msg = { op: 'hl', id, code, lang, prio, upto, stream };
  asked.set(id, { msg, done, part, loading });
  engine(msg);
  return id;
}

/** A request more (or less) urgent now, with the lines the screen shows of it. */
export function prioritise(id, prio, upto) {
  const r = asked.get(id);
  if (!r || (r.msg.prio === prio && r.msg.upto === upto)) return;
  r.msg.prio = prio;
  r.msg.upto = upto;
  engine({ op: 'prio', id, prio, upto });
}

/** A request no longer wanted (its block replaced or removed). */
export function cancel(id) {
  if (asked.delete(id)) engine({ op: 'cancel', id });
}

/** The app's spare page: the grammars a window will most likely need loaded and compiled. */
export function warm() { init(); tell({ op: 'warm' }); return ready; }

/** The fence languages of the document being parsed (before its apply). */
export function prepareLangs(langs) { if (shown) return; init(); tell({ op: 'prepare', langs }); }

/** The tests: the grammars registered, as a 'readout-hl-langs' mark. */
export function loadedLangs() { init(); engine({ op: 'langs' }); }

let shown = false;
/** A document is shown: the spare page's warm-up stops (requested languages go on). */
export function stopWarmUp() {
  if (shown) return;
  shown = true;
  later();
  tell({ op: 'shown' });
}
