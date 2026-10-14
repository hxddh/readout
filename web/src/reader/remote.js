// Remote media placeholders. The page itself cannot fetch (CSP): a click asks
// the native side, which downloads with an ephemeral, cookie-free session and
// serves the bytes back over readout:.
import { strings, post, quicklook } from './core.js';

let remoteSeq = 0;

function hostOf(src) {
  try { return new URL(src, 'https://x/').host; } catch { return src; }
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

export function setupRemoteImage(span) {
  if (span.firstChild) return;
  if (quicklook) { placeholder(span); return; }
  const src = span.dataset.src;
  const host = hostOf(src);
  const btn = document.createElement('button');
  btn.type = 'button';
  btn.textContent = strings.loadImage.replace('%@', host);
  btn.addEventListener('click', () => {
    const tag = (span.dataset.tag || 'img').toLowerCase();
    if (tag !== 'img' && tag !== 'source' && tag !== 'track') {
      // Video and audio are never proxied: open externally.
      const abs = src.startsWith('//') ? `https:${src}` : src;
      post({ type: 'open', href: abs });
      return;
    }
    const id = `r${++remoteSeq}`;
    span.dataset.remoteId = id;
    btn.disabled = true;
    post({ type: 'loadRemote', url: src, id });
  });
  span.appendChild(btn);
}

// Called by the native side with {id, url} once bytes are cached.
export function remoteReady(o) {
  const span = document.querySelector(`.remote-img[data-remote-id="${o.id}"]`);
  if (!span) return;
  const img = document.createElement('img');
  img.src = o.url;
  img.alt = span.dataset.alt || '';
  span.replaceChildren(img);
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
