// Usage: node wasm-shot.mjs <distDir> <outDir> <id>...  — renders <distDir>/<id>.rc in the Wasm player.
// Every id is tried and reported. One that does not settle in the player's ready state (it times
// out, ends in the error state, or leaves ready while it settles) gets no screenshot, and the
// script then exits non-zero after listing them all.
import { createRequire } from 'node:module';
import { createServer } from 'node:http';
import { createReadStream, statSync, mkdirSync } from 'node:fs';
import { join, extname, resolve, sep } from 'node:path';
const require = createRequire(new URL('../../../scripts/wasm-smoke/package.json', import.meta.url));
const { chromium } = require('playwright');
const [dist, out, ...ids] = process.argv.slice(2);
const root = resolve(dist);
mkdirSync(out, { recursive: true });
const types = { '.html': 'text/html', '.mjs': 'text/javascript', '.js': 'text/javascript', '.json': 'application/json', '.wasm': 'application/wasm', '.ttf': 'font/ttf' };
const server = createServer((req, res) => {
  let p;
  try { p = resolve(root, '.' + decodeURIComponent(new URL(req.url, 'http://x').pathname)); } catch { res.writeHead(400).end(); return; }
  // Serve only files under the dist directory: `..` segments, encoded or not, are refused.
  if (p !== root && !p.startsWith(root + sep)) { res.writeHead(403).end(); return; }
  try { if (!statSync(p).isFile()) throw 0; } catch { res.writeHead(404).end(); return; }
  res.writeHead(200, { 'content-type': types[extname(p)] ?? 'application/octet-stream' });
  createReadStream(p).pipe(res);
}).listen(0, '127.0.0.1');
await new Promise(r => server.once('listening', r));
const port = server.address().port;
const browser = await chromium.launch();
const failed = [];
try {
  const page = await browser.newPage({ viewport: { width: 300, height: 160 } });
  for (const id of ids) {
    let state;
    try {
      await page.goto(`http://127.0.0.1:${port}/index.html?src=${encodeURIComponent(id)}.rc&handoffDelayMs=0`);
      await page.waitForSelector('[data-rc-player-state="ready"],[data-rc-player-state="error"]', { state: 'attached', timeout: 90000 });
      // Let the first frames settle, then read the state the screenshot would show.
      await page.waitForTimeout(500);
      state = await page.evaluate(() => document.querySelector('[data-rc-player-state]')?.getAttribute('data-rc-player-state'));
    } catch (error) {
      state = `failed: ${error.message.split('\n')[0]}`;
    }
    console.log(id, state);
    if (state !== 'ready') { failed.push(`${id} (${state})`); continue; }
    await page.screenshot({ path: join(out, `${id}.png`), omitBackground: true });
  }
} finally {
  await browser.close();
  server.close();
}
if (failed.length) {
  console.error(`not ready, no screenshot: ${failed.join(', ')}`);
  process.exit(1);
}
