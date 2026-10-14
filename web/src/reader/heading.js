// Reports the heading at the top of the viewport so the native TOC can follow.
import { doc, slots, post, onKeptScroll } from './core.js';
import { topInset } from './anchor.js';

let lastActive = null;
let headings = null;   // in document order; reset whenever blocks change

// The section the reader jumped to from the TOC is the current one until they
// scroll: {slot, y}. Scrolls that keep the place (compensation) move y along.
let pin = null;
onKeptScroll(dy => { if (pin) pin.y += dy; });

/** Reports `slot` as the current section until the page scrolls away from here. */
export function pinActiveHeading(slot) {
  pin = { slot, y: document.scrollingElement.scrollTop };
  report(slot);
}

export function headingsChanged() { headings = null; }

function report(slot) {
  if (slot !== lastActive) { lastActive = slot; post({ type: 'activeHeading', slot }); }
}

export function reportActiveHeading() {
  if (pin) {
    if (slots.has(pin.slot) && Math.abs(document.scrollingElement.scrollTop - pin.y) <= 2) return report(pin.slot);
    pin = null;
  }
  if (!headings) headings = Array.from(doc.querySelectorAll('.k-heading'));
  // Headings are in document order, so their tops increase: binary search
  // for the last one at or above the line. This relies on headings never
  // being hidden ("Show Only Changes" keeps them as context).
  // Below the window toolbar: jumps land a heading 16 px under it.
  const line = 80 + topInset();
  let lo = 0, hi = headings.length - 1, active = null;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (headings[mid].getBoundingClientRect().top <= line) { active = headings[mid]; lo = mid + 1; } else hi = mid - 1;
  }
  const slot = active ? +active.dataset.slot : (headings[0] ? +headings[0].dataset.slot : 0);
  report(slot);
}
