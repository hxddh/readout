// Reports the heading at the top of the viewport so the native TOC can follow.
import { doc, post } from './core.js';
import { topInset } from './anchor.js';

let lastActive = null;
let headings = null;   // in document order; reset whenever blocks change

export function headingsChanged() { headings = null; }

export function reportActiveHeading() {
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
  if (slot !== lastActive) { lastActive = slot; post({ type: 'activeHeading', slot }); }
}
