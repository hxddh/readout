// The browser every suite runs in: WebKit, the engine of WKWebView, unless
// BROWSER names another (chromium, firefox: for comparison only). CHROME_PATH
// launches that browser's binary instead of Playwright's (local runs only).
import { chromium, webkit, firefox } from 'playwright';

const engines = { webkit, chromium, firefox };
const engineName = (process.env.BROWSER || 'webkit').toLowerCase();

export async function launchBrowser() {
  if (!engines[engineName]) {
    console.error(`Unknown BROWSER=${process.env.BROWSER}; want webkit | chromium | firefox`);
    process.exit(2);
  }
  console.log(`engine: ${engineName}`);
  const opts = process.env.CHROME_PATH ? { executablePath: process.env.CHROME_PATH, args: ['--no-sandbox'] } : {};
  return engines[engineName].launch(opts);
}
