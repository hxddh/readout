// The change rail: one tick per unread change, positioned by document offset.
import { strings, quicklook } from './core.js';
import { unreadElements } from './marks.js';

const rail = document.getElementById('ro-rail');
let railQueued = false;

export function scheduleRail() {
  if (railQueued || quicklook) return;
  railQueued = true;
  requestAnimationFrame(() => { railQueued = false; drawRail(); });
}

function drawRail() {
  const list = unreadElements();
  const total = document.scrollingElement.scrollHeight;
  if (!list.length || total <= window.innerHeight) { rail.replaceChildren(); return; }
  const scrollTop = document.scrollingElement.scrollTop;
  const h = window.innerHeight;
  // All reads before any write, so the page is laid out once.
  const tops = list.map(el => el.getBoundingClientRect().top + scrollTop);
  rail.replaceChildren();
  for (let i = 0; i < list.length; i++) {
    const el = list[i];
    const top = tops[i];
    const tick = document.createElement('button');
    tick.type = 'button';
    const kindKey = el.classList.contains('m-modified') ? 'railEdited'
      : el.classList.contains('del-mark') ? 'railRemoved' : 'railAdded';
    const kind = strings[kindKey] || kindKey;
    if (el.classList.contains('m-modified')) tick.className = 'mod';
    tick.style.top = `${Math.min(h - 4, (top / total) * h)}px`;
    tick.setAttribute('aria-label', (strings.railChange || 'Unread change %d of %d: %@')
      .replace('%d', i + 1).replace('%d', list.length).replace('%@', kind));
    tick.addEventListener('click', () => el.scrollIntoView({ block: 'center' }));
    rail.appendChild(tick);
  }
}

window.addEventListener('resize', scheduleRail);
