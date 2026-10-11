// Remote media placeholders. The page itself cannot fetch (CSP): a click asks
// the native side, which downloads with an ephemeral, cookie-free session and
// serves the bytes back over readout:.
import { strings, post } from './core.js';

let remoteSeq = 0;

export function setupRemoteImage(span) {
  if (span.firstChild) return;
  const src = span.dataset.src;
  let host = src;
  try { host = new URL(src, 'https://x/').host; } catch { /* keep */ }
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
