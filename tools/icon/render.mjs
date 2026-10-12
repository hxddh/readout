// Renders the app icon PNGs from tools/icon/*.svg with Playwright's Chromium.
// Needs web/'s dependencies (npm ci in web/): node tools/icon/render.mjs
import fs from 'fs';
import path from 'path';
import { createRequire } from 'module';
import { fileURLToPath } from 'url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '../..');
const { chromium } = createRequire(path.join(root, 'web/package.json'))('playwright');
const out = path.join(root, 'App/Assets.xcassets/AppIcon.appiconset');
const svg = name => 'data:image/svg+xml;base64,' + fs.readFileSync(path.join(here, name)).toString('base64');
const files = [
  ['icon_16x16.png', 16], ['icon_16x16@2x.png', 32], ['icon_32x32.png', 32], ['icon_32x32@2x.png', 64],
  ['icon_128x128.png', 128], ['icon_128x128@2x.png', 256], ['icon_256x256.png', 256],
  ['icon_256x256@2x.png', 512], ['icon_512x512.png', 512], ['icon_512x512@2x.png', 1024],
];
const browser = await chromium.launch();
const page = await browser.newPage({ deviceScaleFactor: 1 });
async function render(source, px, dest) {
  await page.setViewportSize({ width: px, height: px });
  await page.setContent(`<style>html,body{margin:0;background:transparent}</style><img src="${svg(source)}" width="${px}" height="${px}">`);
  await page.waitForFunction(() => document.images[0].complete);
  await page.screenshot({ path: dest, omitBackground: true });
}
for (const [name, px] of files) await render('readout.svg', px, path.join(out, name));
await render('readout.svg', 1024, path.join(here, 'readout-1024.png'));
await browser.close();
console.log('wrote', files.length + 1, 'PNGs');
