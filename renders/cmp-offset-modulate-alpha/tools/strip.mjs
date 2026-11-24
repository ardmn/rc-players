// node strip.mjs <out.png> <in1.png> <in2.png> ... : side by side over a checkerboard, 12px gaps.
import { createRequire } from 'node:module';
import { readFileSync, writeFileSync } from 'node:fs';
const require = createRequire(new URL('../../../scripts/wasm-smoke/package.json', import.meta.url));
const { PNG } = require('pngjs');
const [out, ...ins] = process.argv.slice(2);
const imgs = ins.map(f => PNG.sync.read(readFileSync(f)));
const W = imgs[0].width, H = imgs[0].height, GAP = 12, CHECK = 10;
const res = new PNG({ width: (W + GAP) * imgs.length - GAP, height: H });
for (let y = 0; y < H; y++) for (let x = 0; x < res.width; x++) {
  const i = (y * res.width + x) * 4; res.data[i] = res.data[i+1] = res.data[i+2] = 255; res.data[i+3] = 255;
}
imgs.forEach((img, n) => {
  const left = n * (W + GAP);
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    const bg = ((Math.floor(x / CHECK) + Math.floor(y / CHECK)) % 2 === 0) ? 0xd0 : 0xff;
    const s = (y * img.width + x) * 4, d = (y * res.width + left + x) * 4, a = img.data[s+3] / 255;
    for (let c = 0; c < 3; c++) res.data[d+c] = Math.round(img.data[s+c] * a + bg * (1 - a));
  }
});
writeFileSync(out, PNG.sync.write(res));
