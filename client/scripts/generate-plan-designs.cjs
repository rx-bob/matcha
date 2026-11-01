const fs = require('node:fs/promises');
const path = require('node:path');

(async () => {
  const root = path.resolve(__dirname, '../..');
  const html = await fs.readFile(path.join(root, 'dist/plan.html'), 'utf8');
  const output = path.join(root, 'dist/plan-designs');
  await fs.mkdir(output, { recursive: true });
  const variants = [
    { name: 'Coral', design: 'coral', theme: 'light', file: 'coral.html' },
    { name: 'Chonk', design: 'chonk', theme: 'dark', file: 'chonk.html' },
    { name: 'EVA-01 Dark', design: 'eva-01', theme: 'dark', file: 'eva-01-dark.html' },
    { name: 'EVA-01 Light', design: 'eva-01', theme: 'light', file: 'eva-01-light.html' },
  ];
  for (const variant of variants) {
    // Pin each preview design, with its own saved color mode and a first-visit default.
    const page = html.replace(
      /<html\b[^>]*>/,
      `<html lang="en" data-design="${variant.design}" data-theme="${variant.theme}" data-initial-design="${variant.design}" data-initial-eva-theme="${variant.theme}" data-eva-theme-storage-key="matcha-eva-theme:${variant.file}">`,
    );
    await fs.writeFile(path.join(output, variant.file), page);
  }
  await fs.writeFile(path.join(output, 'index.html'), `<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Sample plan designs</title>
<style>
body{margin:0;padding:24px;background:#efeee9;color:#242424;font:15px/1.5 system-ui}
h1{margin:0}p{margin:8px 0 24px}.grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:24px}
article{min-width:0}h2{font-size:18px;margin:0 0 8px}a{color:inherit}
iframe{display:block;width:100%;height:850px;border:1px solid #ccc;background:white;border-radius:8px}
@media(max-width:1000px){.grid{grid-template-columns:1fr}}
</style>
<h1>Sample plan designs</h1><p>Compare the same plan in every design. Open a design in its own tab for a full-width view.</p>
<div class="grid">${variants.map(v => `<article><h2><a href="${v.file}" target="_blank" rel="noopener">${v.name} ↗</a></h2><iframe src="${v.file}" title="${v.name}"></iframe></article>`).join('\n')}</div>
</html>\n`);
  console.log('Generated dist/plan-designs/index.html and four standalone sample plans.');
})().catch(error => { console.error(error); process.exitCode = 1; });
