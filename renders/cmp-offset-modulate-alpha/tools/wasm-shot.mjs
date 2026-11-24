// Usage: node wasm-shot.mjs <distDir> <outDir> <id>...  — renders <distDir>/<id>.rc in the Wasm player.
import { createRequire } from 'node:module';
import { createServer } from 'node:http';
import { createReadStream, statSync, mkdirSync } from 'node:fs';
import { join, extname } from 'node:path';
const require = createRequire(new URL('../../../scripts/wasm-smoke/package.json', import.meta.url));
const { chromium } = require('playwright');
const [dist, out, ...ids] = process.argv.slice(2);
mkdirSync(out, { recursive: true });
const types = { '.html': 'text/html', '.mjs': 'text/javascript', '.js': 'text/javascript', '.json': 'application/json', '.wasm': 'application/wasm', '.ttf': 'font/ttf' };
const server = createServer((req, res) => {
  const p = join(dist, decodeURIComponent(new URL(req.url, 'http://x').pathname));
  try { if (!statSync(p).isFile()) throw 0; } catch { res.writeHead(404).end(); return; }
  res.writeHead(200, { 'content-type': types[extname(p)] ?? 'application/octet-stream' });
  createReadStream(p).pipe(res);
}).listen(0);
const port = server.address().port;
const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 300, height: 160 } });
for (const id of ids) {
  await page.goto(`http://127.0.0.1:${port}/index.html?src=${id}.rc&handoffDelayMs=0`);
  await page.waitForSelector('[data-rc-player-state="ready"],[data-rc-player-state="error"]', { timeout: 90000 });
  await page.waitForTimeout(500);
  await page.screenshot({ path: join(out, `${id}.png`), omitBackground: true });
  console.log(id, await page.evaluate(() => document.querySelector('[data-rc-player-state]')?.getAttribute('data-rc-player-state')));
}
await browser.close(); server.close();
