// Remote media placeholders. The page itself cannot fetch (CSP): a click asks
// the native side, which downloads with an ephemeral, cookie-free session and
// serves the bytes back over readout:.
import { strings, post, quicklook } from './core.js';

let remoteSeq = 0;
/** Addresses the reader loaded before (in any window, while Readout runs), with the local URL of their kept bytes. */
const known = new Map();
/** Hosts whose remaining placeholders offer to load all their images at once. */
const offered = new Set();

function hostOf(src) {
  try { return new URL(src, 'https://x/').host; } catch { return src; }
}

/** Images are proxied; video and audio open externally. */
function proxied(span) {
  const tag = (span.dataset.tag || 'img').toLowerCase();
  return tag === 'img' || tag === 'source' || tag === 'track';
}

/** Quick Look cannot load anything: the placeholder shows its text, with nothing to click. */
function placeholder(span) {
  const text = document.createElement('span');
  text.className = 'remote-ph';
  text.textContent = strings.loadImage.replace('%@', hostOf(span.dataset.src));
  span.replaceChildren(text);
}

/** Turns the placeholders already set up into text (Quick Look's mode arrived after them). */
export function staticRemoteImages() {
  for (const btn of document.querySelectorAll('#ro-doc .remote-img > button')) placeholder(btn.parentElement);
}

function image(span, url) {
  const img = document.createElement('img');
  img.src = url;
  img.alt = span.dataset.alt || '';
  span.replaceChildren(img);
  return img;
}

/** An image loaded before, from its kept bytes; should they be gone (the cache is bounded), the placeholder again. */
function showKnown(span, url) {
  const img = image(span, url);
  img.addEventListener('error', () => {
    if (known.get(span.dataset.src) === url) known.delete(span.dataset.src);
    if (img.parentNode !== span) return;
    span.replaceChildren();
    delete span.dataset.remoteId;
    setupRemoteImage(span);
  }, { once: true });
}

/** The placeholders of `host` that can still be clicked. */
function pending(host) {
  return [...document.querySelectorAll('#ro-doc .remote-img')]
    .filter(s => proxied(s) && hostOf(s.dataset.src) === host && s.querySelector(':scope > button:not([disabled])'));
}

function label(btn, host) {
  btn.textContent = (offered.has(host) ? strings.loadAllImages : strings.loadImage).replace('%@', host);
}

/** Asks the app for the image (only ever after a click). */
function request(span) {
  const btn = span.querySelector(':scope > button');
  const id = `r${++remoteSeq}`;
  span.dataset.remoteId = id;
  if (btn) btn.disabled = true;
  post({ type: 'loadRemote', url: span.dataset.src, id });
}

export function setupRemoteImage(span) {
  if (span.firstChild) return;
  if (quicklook) { placeholder(span); return; }
  const src = span.dataset.src;
  const host = hostOf(src);
  // Loaded before: drawn again (an edit, Undo, the window opened again) without asking again.
  const url = known.get(src);
  if (url && proxied(span)) { showKnown(span, url); return; }
  const btn = document.createElement('button');
  btn.type = 'button';
  label(btn, host);
  btn.addEventListener('click', () => {
    if (!proxied(span)) {
      // Video and audio are never proxied: open externally.
      const abs = src.startsWith('//') ? `https:${src}` : src;
      post({ type: 'open', href: abs });
      return;
    }
    // The offer taken: every image of the host in the document, with this one click.
    if (offered.has(host)) { for (const s of pending(host)) request(s); return; }
    request(span);
    // The other placeholders of the host now offer to load them all.
    const rest = pending(host);
    if (rest.length) {
      offered.add(host);
      for (const s of rest) label(s.querySelector(':scope > button'), host);
    }
  });
  span.appendChild(btn);
}

/** Shows the images of `src` still waiting as placeholders (not those being loaded). */
function showWaiting(src) {
  const url = known.get(src);
  if (!url) return;
  for (const span of document.querySelectorAll('#ro-doc .remote-img')) {
    if (span.dataset.src === src && proxied(span) && span.querySelector(':scope > button:not([disabled])')) showKnown(span, url);
  }
}

// Called by the native side with {address: local URL} for images loaded
// before, while Readout runs: placeholders of them show the image, now and
// whenever their block is drawn again. No request: the bytes are the app's.
export function remoteKnown(map) {
  if (quicklook || !map) return;
  for (const [src, url] of Object.entries(map)) {
    if (typeof url !== 'string') continue;
    known.set(src, url);
    showWaiting(src);
  }
}

// Called by the native side with {id, url} once bytes are cached.
export function remoteReady(o) {
  const span = document.querySelector(`.remote-img[data-remote-id="${o.id}"]`);
  if (!span) return;
  image(span, o.url);
  known.set(span.dataset.src, o.url);
  // The same image elsewhere in the document.
  showWaiting(span.dataset.src);
}

// Called by the native side with {id, error} when the download fails.
export function remoteFailed(o) {
  const span = document.querySelector(`.remote-img[data-remote-id="${o.id}"]`);
  if (!span) return;
  const btn = span.querySelector('button');
  const msg = (strings.remoteError || 'Could not load image: %@').replace('%@', o.error || 'failed');
  if (btn) { btn.disabled = false; btn.textContent = msg; }
  else span.textContent = msg;
}
