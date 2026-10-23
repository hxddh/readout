// Shared page state: document containers, block registry, localized strings,
// and the message channel to the native side.

export const doc = document.getElementById('ro-doc');
export const root = document.documentElement;

export const slots = new Map();          // slot -> element
export const heights = new WeakMap();    // element -> last observed height

// The page's items (blocks and removal markers) live in chunks of about 32,
// the chunks in the document: #ro-doc > .chunk > .blk. A large document
// skips laying out the chunks away from the screen (content-visibility):
// WebKit checks every element that can be skipped in every frame that
// scrolls, so a few hundred chunks cost what tens of thousands of blocks did not.
export const isChunk = e => !!e?.classList?.contains('chunk');
/** The item after `e`, across chunks (null: none). */
export function nextItem(e) {
  if (e.nextElementSibling) return e.nextElementSibling;
  for (let c = e.parentElement.nextElementSibling; isChunk(c); c = c.nextElementSibling) if (c.firstElementChild) return c.firstElementChild;
  return null;
}
/** The item before `e`, across chunks (null: none). */
export function prevItem(e) {
  if (e.previousElementSibling) return e.previousElementSibling;
  for (let c = e.parentElement.previousElementSibling; isChunk(c); c = c.previousElementSibling) if (c.lastElementChild) return c.lastElementChild;
  return null;
}
export function firstItem() {
  for (let c = doc.firstElementChild; c; c = c.nextElementSibling) if (isChunk(c) && c.firstElementChild) return c.firstElementChild;
  return null;
}
export function lastItem() {
  for (let c = doc.lastElementChild; c; c = c.previousElementSibling) if (isChunk(c) && c.lastElementChild) return c.lastElementChild;
  return null;
}
/** The item (a block or a removal marker) node `n` is in, or null. */
export const itemOf = n => (n && n.nodeType !== Node.ELEMENT_NODE ? n.parentElement : n)?.closest('#ro-doc > .chunk > *') ?? null;

/**
 * Whether the reader's window is the key window (the app says so, see
 * setWindowKey): null until it has. Keyboard focus in the window's outline
 * or find field takes it from the page (document.hasFocus() is false then),
 * but the reader is still in the window, reading.
 */
let windowKey = null;
export function setWindowKey(on) { windowKey = !!on; }
/** The reader is reading in this window: it is visible, and the page or its window has the focus. */
export function focused() { return !document.hidden && (document.hasFocus() || windowKey === true); }

export let strings = { copy: 'Copy', copied: 'Copied', loadImage: 'Load image from %@', loadAllImages: 'Load all images from %@', remoteError: 'Could not load image: %@', rewritten: 'Rewritten since you last read', diagramError: 'Diagram could not be drawn', railChange: 'Unread change %d of %d: %@', railAdded: 'added', railEdited: 'edited', railRemoved: 'removed', wrap: 'Wrap', wrapTitle: 'Wrap long lines in code blocks' };
export function mergeStrings(s) { strings = { ...strings, ...s }; }

/**
 * The theme the page is shown in: the app's choice (data-theme), else the
 * system's (reader.html does not set one; reader.css follows the system then).
 */
export function pageTheme() {
  const t = root.getAttribute('data-theme');
  if (t === 'dark' || t === 'light') return t;
  return window.matchMedia && matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}

/**
 * The last moves of the reading position (patches, compensation, resize
 * holds, restores the app asked for), kept so a misplaced reader can be
 * explained: the smoke test writes them out (window.readout.trace()).
 */
const traceLog = [];
/** The page's first setAppearance and first apply, in ms (the smoke test reports them). */
export const firstTimings = {};
export function trace(type, data) {
  // A caller that gives `y` (null: filled in later) spares the layout reading it costs.
  const y = data && 'y' in data ? data.y : Math.round(document.scrollingElement.scrollTop);
  const entry = { t: Math.round(performance.now()), type, ...data, y };
  traceLog.push(entry);
  if (traceLog.length > 80) traceLog.shift();
  return entry;
}
export function traceEntries() { return traceLog.slice(); }

/**
 * Scrolls that keep the reader's place (restoring it, compensating for a
 * block above that changed height, holding the end) are not the reader
 * moving: whoever tracks the reader's position hears of them here.
 */
const keptScrollListeners = [];
export function onKeptScroll(f) { keptScrollListeners.push(f); }
export function keptScroll(dy) { if (dy) for (const f of keptScrollListeners) f(dy); }

/** Quick Look renders statically: no marks, no rail. */
export let quicklook = false;
export function enableQuicklook() { quicklook = true; root.dataset.mode = 'quicklook'; }

export function post(msg) {
  try { window.webkit.messageHandlers.readout.postMessage(msg); } catch { /* not hosted */ }
}

// Registered here, in the first module to run, so errors thrown while the
// other modules set up still reach the native log.
window.addEventListener('error', e => post({ type: 'error', message: `${e.message} (${e.filename}:${e.lineno})` }));
window.addEventListener('unhandledrejection', e => post({ type: 'error', message: `unhandled: ${e.reason && (e.reason.stack || e.reason.message) || e.reason}` }));

export function inViewport(el, margin = 0) {
  // In a chunk content-visibility skips, its block's share of the chunk's
  // box (chunks.js: roughRect): asked about the block itself, WebKit would
  // lay the chunk out to answer.
  const skipped = el.closest?.('#ro-doc.cv > .chunk:not(.near)');
  let r;
  if (skipped && el !== skipped && !el.checkVisibility({ contentVisibilityAuto: true })) {
    const item = el.closest('#ro-doc > .chunk > *'), c = skipped.getBoundingClientRect(), n = skipped.childElementCount;
    const i = Array.prototype.indexOf.call(skipped.children, item);
    r = { top: c.top + c.height * i / n, bottom: c.top + c.height * (i + 1) / n };
  } else r = el.getBoundingClientRect();
  return r.bottom > -margin && r.top < window.innerHeight + margin;
}
