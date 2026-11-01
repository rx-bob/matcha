// Regenerate the committed favicon assets from the official mascot:
// node client/scripts/generate-favicons.cjs (requires Playwright Chromium).
const { chromium } = require('playwright');
const fs = require('node:fs/promises');
const path = require('node:path');
const root = path.resolve(__dirname, '../..');

(async () => {
  const source = await fs.readFile(path.join(root, 'assets/mascot_mono_light_bg.png'));
  const browser = await chromium.launch({ headless: true });
  try {
    const page = await browser.newPage();
    const variants = [
      { design: 'coral', color: '#e33920', background: '#f5f3ef', radius: 28 },
      { design: 'chonk', color: '#ff842a', background: '#0b0b12', radius: 12 },
      { design: 'eva-01', color: '#bdff39', background: '#0d0d13', radius: 0 },
    ];
    for (const variant of variants) {
      const png = await page.evaluate(async ({ source, color, background, radius }) => {
        const image = new Image();
        image.src = source;
        await image.decode();
        const mask = document.createElement('canvas');
        mask.width = image.width;
        mask.height = image.height;
        const ctx = mask.getContext('2d');
        ctx.drawImage(image, 0, 0);
        ctx.globalCompositeOperation = 'source-in';
        ctx.fillStyle = color;
        ctx.fillRect(0, 0, mask.width, mask.height);
        const canvas = document.createElement('canvas');
        canvas.width = canvas.height = 128;
        const out = canvas.getContext('2d');
        out.fillStyle = background;
        out.beginPath();
        out.roundRect(0, 0, 128, 128, radius);
        out.fill();
        out.imageSmoothingQuality = 'high';
        out.drawImage(mask, 4, 4, 120, 120);
        return canvas.toDataURL('image/png').split(',')[1];
      }, { source: `data:image/png;base64,${source.toString('base64')}`, ...variant });
      await fs.writeFile(path.join(root, `assets/favicon-${variant.design}.png`), Buffer.from(png, 'base64'));
    }
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
