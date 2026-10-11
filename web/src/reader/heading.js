// Reports the heading at the top of the viewport so the native TOC can follow.
import { doc, post } from './core.js';

let lastActive = null;

export function reportActiveHeading() {
  const headings = doc.querySelectorAll('.k-heading');
  let active = null;
  const line = 80;
  for (const h of headings) {
    if (h.getBoundingClientRect().top <= line) active = h; else break;
  }
  const slot = active ? +active.dataset.slot : (headings[0] ? +headings[0].dataset.slot : 0);
  if (slot !== lastActive) { lastActive = slot; post({ type: 'activeHeading', slot }); }
}
