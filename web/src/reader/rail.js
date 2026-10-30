// The change rail: one tick per unread change, positioned by document offset.
import { strings, quicklook } from './core.js';
import { unreadElements, focusBlock, visit, pulse, once } from './marks.js';
import { scrollToElement } from './anchor.js';
import { roughRect } from './chunks.js';

const rail = document.getElementById('ro-rail');
let railQueued = false;
let lastDraw = -Infinity;
// Blocks resize as they are laid out while the reader scrolls (each one a
// ResizeObserver callback): the rail is redrawn at most this often. A request
// is never dropped, only delayed, so the last one always draws.
const RAIL_INTERVAL_MS = 250;
const TICK_MIN_PX = 6;   // reader.css: #ro-rail > button min-height

export function scheduleRail() {
  if (railQueued || quicklook) return;
  railQueued = true;
  const draw = () => requestAnimationFrame(() => { railQueued = false; lastDraw = performance.now(); drawRail(); });
  const wait = lastDraw + RAIL_INTERVAL_MS - performance.now();
  if (wait > 0) setTimeout(draw, wait); else draw();
}

function kindKey(el) {
  if (el.classList.contains('m-modified')) return 'railEdited';
  if (el.classList.contains('m-state')) return 'railTask';   // a checkbox changed: an edit, not an addition
  if (el.classList.contains('del-mark')) return 'railRemoved';
  return 'railAdded';
}

function drawRail() {
  rail.setAttribute('aria-label', strings.railLabel || 'Unread changes');
  const list = unreadElements();
  // Nothing unread: nothing to measure (a measurement here forces a layout).
  if (!list.length) { if (rail.firstChild) rail.replaceChildren(); return; }
  const total = document.scrollingElement.scrollHeight;
  if (total <= window.innerHeight) { rail.replaceChildren(); return; }
  const scrollTop = document.scrollingElement.scrollTop;
  const track = window.innerHeight;
  // All reads before any write, so the page is laid out once.
  const rects = list.map(roughRect);
  // The ticks are kept and moved, not made again: the rail is drawn again
  // after every scroll that changes what is unread, and every patch.
  targets = list;
  while (rail.children.length > list.length) rail.lastChild.remove();
  for (let i = 0; i < list.length; i++) {
    const el = list[i];
    const top = rects[i].top + scrollTop;
    let tick = rail.children[i];
    if (!tick) {
      tick = document.createElement('button');
      tick.type = 'button';
      tick.dataset.i = String(i);
      rail.appendChild(tick);
    }
    const key = kindKey(el);
    // Task changes fall back to "edited" until the app sends a word for them.
    const kind = strings[key] || (key === 'railTask' && strings.railEdited) || key;
    const height = Math.max(TICK_MIN_PX, (rects[i].height / total) * track);
    tick.style.top = `${Math.min(window.innerHeight - height, (top / total) * track)}px`;
    tick.style.height = height > TICK_MIN_PX ? `${height}px` : '';
    const label = (strings.railChange || 'Unread change %d of %d: %@')
      .replace('%d', i + 1).replace('%d', list.length).replace('%@', kind);
    if (tick.title !== label) { tick.setAttribute('aria-label', label); tick.title = label; }
  }
}

// The unread block each tick stands for, by its index (drawRail).
let targets = [];
rail.addEventListener('click', e => {
  const tick = e.target instanceof Element ? e.target.closest('button[data-i]') : null;
  const el = tick ? targets[+tick.dataset.i] : null;
  if (!el?.isConnected) return;
  // (Read once it lands: a jump onto code not coloured yet waits for it.)
  scrollToElement(el, { center: true, landed: once(() => visit(el)) }); focusBlock(el); pulse(el);
});

window.addEventListener('resize', scheduleRail);
