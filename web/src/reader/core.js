// Shared page state: document containers, block registry, localized strings,
// and the message channel to the native side.

export const doc = document.getElementById('ro-doc');
export const root = document.documentElement;

export const slots = new Map();          // slot -> element
export const heights = new WeakMap();    // element -> last observed height

export let strings = { copy: 'Copy', copied: 'Copied', loadImage: 'Load image from %@', remoteError: 'Could not load image: %@', rewritten: 'Rewritten since you last looked', diagramError: 'Diagram could not be drawn', caughtUp: 'All caught up', copyLink: 'Copy Link to Section', railChange: 'Unread change %d of %d: %@', railAdded: 'added', railEdited: 'edited', railRemoved: 'removed' };
export function mergeStrings(s) { strings = { ...strings, ...s }; }

/** Quick Look renders statically: no marks, no rail. */
export let quicklook = false;
export function enableQuicklook() { quicklook = true; root.dataset.mode = 'quicklook'; }

export function post(msg) {
  try { window.webkit.messageHandlers.readout.postMessage(msg); } catch { /* not hosted */ }
}

export function inViewport(el, margin = 0) {
  const r = el.getBoundingClientRect();
  return r.bottom > -margin && r.top < window.innerHeight + margin;
}
