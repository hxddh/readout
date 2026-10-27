// The highlighting worker: Shiki off the page's main thread (highlighter.js).
import { serve } from './highlighter.js';

const handle = serve(m => postMessage(m));
onmessage = e => handle(e.data);
