// The column's edge, dragged: the text column as wide as the reader wants
// (View ▸ Text Width, in rem, every window). The edge is the margin just
// outside the text on either side; the column stays centred, so either
// edge sets its width. A double-click on an edge goes back to Standard.
import { doc, root, post } from './core.js';
import { keepPlace } from './anchor.js';
import { measureTables } from './enhance.js';

const ZONE = 10;              // px of margin outside the text that grab the edge
const MIN = 30, MAX = 200;    // rem (ReaderLayout.customCapRange)

let drag = null;              // { rem } while the edge is held
let frame = 0;

/** The text's left and right edges (px), inside the column's gutters. */
function edges() {
  const r = doc.getBoundingClientRect();
  const g = parseFloat(getComputedStyle(doc).paddingLeft) || 0;
  return { left: r.left + g, right: r.right - g, center: r.left + r.width / 2 };
}

/** What a pointer in the margin may be over and still take the edge: not
 *  what bleeds into the margin or answers a click there (wide code and
 *  tables, diagrams, images, links, buttons, the marks' controls). */
const OWN = 'pre, table, img, svg, a, button, .mermaid-block, .math-block, [role="button"]';

/** Whether the pointer at `ev` is on an edge: in the margin beside the text. */
function onEdge(ev) {
  if (!(ev.target instanceof Element) || ev.target.closest(OWN) || !doc.contains(ev.target) && ev.target !== root && ev.target !== document.body) return false;
  const e = edges();
  return (ev.clientX > e.left - ZONE && ev.clientX < e.left + 2) || (ev.clientX > e.right - 2 && ev.clientX < e.right + ZONE);
}

/** The column `rem` wide (null: the width the app set, Standard or Wide). */
export function setColumn(rem) {
  keepPlace(() => {
    if (rem == null) {
      root.style.removeProperty('--cap');
    } else {
      root.dataset.width = 'custom';
      root.style.setProperty('--cap', `${rem}rem`);
    }
    measureTables();
  }, { ratio: true });
}

/** The drag ends (released, cancelled, or the button found up): the last
 *  width shown at once, and saved. */
function endDrag() {
  if (!drag) return;
  const { rem } = drag;
  drag = null;
  if (frame) { cancelAnimationFrame(frame); frame = 0; }
  root.classList.remove('col-dragging');
  if (rem == null) return;
  setColumn(rem);
  post({ type: 'setTextWidth', rem });
}

document.addEventListener('pointermove', ev => {
  if (!drag) {
    root.classList.toggle('col-edge', ev.buttons === 0 && onEdge(ev));
    return;
  }
  // Released where no pointerup reached the page: the drag is over.
  if (!(ev.buttons & 1)) return endDrag();
  const remPx = parseFloat(getComputedStyle(root).fontSize) || 16;
  const rem = Math.min(MAX, Math.max(MIN, (2 * Math.abs(ev.clientX - edges().center)) / remPx));
  drag.rem = Math.round(rem);
  if (frame) return;
  frame = requestAnimationFrame(() => { frame = 0; if (drag) setColumn(drag.rem); });
});

document.addEventListener('pointerdown', ev => {
  if (ev.button !== 0 || !root.classList.contains('col-edge')) return;
  ev.preventDefault();
  drag = { rem: null };
  root.classList.add('col-dragging');
  // Its moves and its release, wherever the pointer goes.
  try { root.setPointerCapture(ev.pointerId); } catch {}
});

for (const type of ['pointerup', 'pointercancel', 'lostpointercapture']) document.addEventListener(type, endDrag);

document.addEventListener('dblclick', ev => {
  if (!onEdge(ev)) return;
  ev.preventDefault();
  post({ type: 'setTextWidth', rem: null });
});
