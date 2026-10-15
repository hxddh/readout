// Page errors every suite collects. WebKit reports a ResizeObserver loop when
// observed blocks change size again while it delivers their notifications
// (content-visibility blocks laid out by a measurement during the delivery):
// a notice, not a failure of the page, and whether it happens depends on how
// frames fall on a loaded machine.
export const benign = e => /ResizeObserver loop/.test(String(e));

/** Adds the page's errors (other than the notices above) to `errors`, each after `prefix`. */
export function collectPageErrors(page, errors, prefix = '') {
  page.on('pageerror', e => { if (!benign(e)) errors.push(`${prefix}${e}`); });
}
