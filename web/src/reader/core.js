// Shared page state: document containers, block registry, localized strings,
// and the message channel to the native side.

export const doc = document.getElementById('ro-doc');
export const root = document.documentElement;

export const slots = new Map();          // slot -> element
export const heights = new WeakMap();    // element -> last observed height

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

/**
 * Whether blocks may be hidden: only the changes-only filter hides them.
 * Without it, nothing needs the whole page searched for a hidden block.
 */
export let blocksHidden = false;
export function setBlocksHidden(on) { blocksHidden = !!on; }

export let strings = { copy: 'Copy', copied: 'Copied', loadImage: 'Load image from %@', loadAllImages: 'Load all images from %@', remoteError: 'Could not load image: %@', rewritten: 'Rewritten since you last looked', diagramError: 'Diagram could not be drawn', caughtUp: 'All caught up', copyLink: 'Copy Link to Section', railChange: 'Unread change %d of %d: %@', railAdded: 'added', railEdited: 'edited', railRemoved: 'removed', wrap: 'Wrap', wrapTitle: 'Wrap long lines in code blocks' };
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
  const r = el.getBoundingClientRect();
  return r.bottom > -margin && r.top < window.innerHeight + margin;
}
