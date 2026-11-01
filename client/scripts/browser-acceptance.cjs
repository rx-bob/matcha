// Run after task run-plan. Set PLAYWRIGHT_MODULE when Playwright is installed outside this project.
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { execFileSync } = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const out = process.env.MATCHA_BROWSER_OUTPUT || '/tmp/matcha-browser-evidence';
const url = pathToFileURL(path.join(root, 'dist/plan.html')).href;
(async () => {
 await fs.mkdir(out, { recursive: true });
 const browser = await chromium.launch({headless:true});
 const context = await browser.newContext({viewport:{width:1440,height:1000}, reducedMotion:'reduce',acceptDownloads:true,permissions:['clipboard-read','clipboard-write']});
 const page = await context.newPage(); const errors=[]; const checks=[];
 page.on('pageerror',e=>errors.push(e.message));
 const check=async(name, fn)=>{await fn();checks.push(name);console.log('PASS',name)};
 const visible=async(selector)=>page.locator(selector).waitFor({state:'visible',timeout:5000});
 const route=async(hash)=>{await page.evaluate(h=>{location.hash=h},hash);await page.waitForTimeout(300)};
 await page.goto(url); await page.locator('#view-overview').waitFor(); await page.evaluate(()=>document.fonts.ready);
 await check('Coral default and six workspace views',async()=>{
  assert.equal(await page.locator('html').getAttribute('data-design'),'coral');
  for(const view of ['overview','epics','files','context','order','criteria']){await page.locator(`[data-nav="${view}"]`).click();await visible(`#view-${view}`);assert.equal(await page.locator('.page-view:visible').count(),1)}
 });
 await check('Three designs, EVA theme persistence and reference screenshots',async()=>{
  await route('#overview');
  for(const design of ['coral','chonk','eva-01']){
   await page.locator(`[data-design-choice="${design}"]`).click();
   await page.reload(); await page.waitForTimeout(300); await page.evaluate(()=>document.fonts.ready);
   assert.equal(await page.locator('html').getAttribute('data-design'),design);
   assert.equal(await page.locator('#sidebar .brand').getAttribute('aria-label'),'Matcha — plan overview');
   assert.equal(await page.locator('#sidebar .brand svg').count(),0);
   assert.equal(await page.locator('#sidebar .brand-type, #sidebar .brand-logo').count(),0);
   await visible('#sidebar .matcha-mascot');
   assert((await page.locator('.matcha-mascot').getAttribute('style')).includes('data:image/png;base64,'));
   const mascotBounds=await page.locator('.matcha-mascot').boundingBox();
   const sidebarBounds=await page.locator('#sidebar').boundingBox();
   assert.equal(mascotBounds.width,80);assert.equal(mascotBounds.height,80);
   assert(Math.abs(mascotBounds.x+40-(sidebarBounds.x+sidebarBounds.width/2))<=1,'mascot centered');
   const brandBounds=await page.locator('#sidebar .brand').boundingBox();
   const navBounds=await page.locator('#sidebar nav').boundingBox();
   assert(brandBounds.y-sidebarBounds.y<=16,'compact mascot top spacing');
   assert(navBounds.y-(brandBounds.y+brandBounds.height)<=16,'compact mascot bottom spacing');
   if(design==='coral') assert.equal(await page.locator('.matcha-mascot').evaluate(e=>getComputedStyle(e).backgroundColor),'rgb(227, 57, 32)');
   assert((await page.locator('#dynamic-favicon').getAttribute('href')).startsWith('data:image/png;base64,'));
   const favicon=await page.locator('#dynamic-favicon').getAttribute('href');
   assert.equal(favicon,await page.locator('#dynamic-favicon').getAttribute(`data-favicon-${design}`));
   assert.deepEqual(await page.evaluate(async src=>{const img=new Image();img.src=src;await img.decode();return [img.width,img.height]},favicon),[128,128]);
   await page.screenshot({path:path.join(out,`${design}-overview.png`)});
   for(const view of ['epics','files','context','order','criteria']){await route('#'+view);await page.screenshot({path:path.join(out,`${design}-${view}.png`)})}
   await route('#overview');
  }
  for(const theme of ['light','dark']){await page.locator(`[data-theme-choice="${theme}"]`).click();await page.reload();assert.equal(await page.locator('html').getAttribute('data-theme'),theme);await page.screenshot({path:path.join(out,`eva-${theme}.png`)})}
  const reference=await context.newPage();await reference.goto(pathToFileURL(path.join(root,'references/ui/chonk.html')).href);
  for(const design of ['coral','chonk','eva-01']){await reference.locator(`[data-design-choice="${design}"]`).click();await reference.evaluate(()=>document.fonts.ready);await reference.waitForTimeout(300);await reference.screenshot({path:path.join(out,`reference-${design}.png`)})}
  await reference.close();
 });
 await check('EVA comparison previews remember color mode across reloads and design switches',async()=>{
  execFileSync(process.execPath,[path.join(root,'client/scripts/generate-plan-designs.cjs')]);
  const previews=await browser.newContext({viewport:{width:1440,height:1000}});
  try {
   for(const initial of ['dark','light']){
    const preview=await previews.newPage();
    await preview.goto(pathToFileURL(path.join(root,`dist/plan-designs/eva-01-${initial}.html`)).href);
    await preview.locator(`[data-theme-choice="${initial}"][aria-pressed="true"]`).waitFor({state:'visible'});
    for(const mode of [initial==='dark'?'light':'dark',initial]){
     await preview.locator(`[data-theme-choice="${mode}"]`).click();
     for(const design of ['coral','chonk']){
      await preview.locator(`[data-design-choice="${design}"]`).click();
      await preview.locator('[data-design-choice="eva-01"]').click();
      assert.equal(await preview.locator('html').getAttribute('data-theme'),mode);
     }
     await preview.reload();
     await preview.locator(`[data-theme-choice="${mode}"][aria-pressed="true"]`).waitFor({state:'visible'});
     assert.equal(await preview.locator('html').getAttribute('data-theme'),mode);
    }
    await preview.close();
   }
  } finally { await previews.close(); }
 });
 await check('Modal links switch views; history, focus restoration, aliases and references',async()=>{
  await route('#overview');await page.locator('.first-story a').click();await visible('#story-dialog[open]');
  assert.equal(await page.locator('#story-dialog').getAttribute('data-story'),'E1.S1');assert.equal(await page.locator('#view-epics').isVisible(),true);
  assert.equal(await page.evaluate(()=>location.hash),'#E1.S1');
  await page.goBack();await page.waitForTimeout(350);await visible('#view-overview');assert(!(await page.locator('#story-dialog').evaluate(e=>e.open)));
  await page.goForward();await page.waitForTimeout(350);await visible('#story-dialog[open]');
  await page.keyboard.press('Escape');await page.waitForTimeout(350);assert(!(await page.locator('#story-dialog').evaluate(e=>e.open)));assert.equal(await page.evaluate(()=>document.activeElement?.getAttribute('data-open-story')),'E1.S1');
  await route('#story-E1-S2');await visible('#story-dialog[open]');assert.equal(await page.locator('#story-dialog').getAttribute('data-story'),'E1.S2');
  const dependency=page.locator('#story-dialog .story-link').first();if(await dependency.count()){await dependency.click();await page.waitForTimeout(300);assert.equal(await page.locator('#story-dialog').getAttribute('data-story'),'E1.S1')}
  await route('#E4.S3');await page.locator('#story-dialog details summary').click();await page.locator('#story-dialog a[href="#reference-unit-api"]').click();await page.waitForTimeout(350);assert(await page.locator('#reference-unit-api').evaluate(e=>!e.closest('.page-view').hidden));assert(!(await page.locator('#story-dialog').evaluate(e=>e.open)));
  assert(await page.locator('#reference-unit-api').evaluate(el=>{for(let n=el.parentElement;n;n=n.parentElement)if(n.tagName==='DETAILS'&&!n.open)return false;return true}));
  await page.emulateMedia({reducedMotion:'no-preference'});await route('#E1.S1');
  await page.locator('#story-dialog.is-visible').waitFor();assert.equal(await page.locator('body').evaluate(e=>e.style.overflow),'hidden');
  await page.screenshot({path:path.join(out,'story-dialog.png')});await page.mouse.click(5,5);await page.locator('#story-dialog').waitFor({state:'hidden'});
  assert.equal(await page.locator('body').evaluate(e=>e.style.overflow),'');await page.emulateMedia({reducedMotion:'reduce'});
  for(const [alias,view] of [['#summary','overview'],['#changed-files','files'],['#sections','context'],['#recommended-order','order'],['#exit-criteria','criteria']]){await route(alias);await visible('#view-'+view)}
 });
 await check('Story filter, nested epic/story picker, empty state and route clears filters',async()=>{
  await route('#epics');await page.locator('#story-filter').fill('impossible-no-matching-story');await visible('#filter-empty');assert.equal(await page.locator('.story-card:visible').count(),0);
  await route('#E1.S1');await visible('#story-dialog[open]');await page.keyboard.press('Escape');await page.waitForTimeout(300);
  assert.equal(await page.locator('#story-filter').inputValue(),'');
  assert.equal(await page.locator('#epic-story-picker optgroup').count(),6);
  await page.locator('#epic-story-picker').selectOption('E2');await page.waitForTimeout(300);assert.equal(await page.evaluate(()=>location.hash),'#E2');
  await page.locator('#epic-story-picker').selectOption('E2.S1');await visible('#story-dialog[open]');assert.equal(await page.locator('#story-dialog').getAttribute('data-story'),'E2.S1');
  await page.keyboard.press('Escape');await page.waitForTimeout(300);
  await page.locator('#story-filter').fill('impossible-no-match');await page.locator('#epic-story-picker').selectOption('E1.S1');await visible('#story-dialog[open]');assert.equal(await page.locator('#story-filter').inputValue(),'');
  await page.keyboard.press('Escape');await page.waitForTimeout(300);
  await page.locator('.design-reference summary').first().click();await page.locator('#collapse-stories').click();assert.equal(await page.locator('#view-epics details[open]').count(),0);
 });
 await check('File expansion and linked story badges',async()=>{
  await route('#files');await page.locator('[data-expand-files]').click();assert.equal(await page.locator('#view-files details:not([open])').count(),0);
  await page.locator('[data-collapse-files]').click();assert.equal(await page.locator('#view-files details[open]:not([data-depth="0"])').count(),0);
  await page.locator('[data-expand-files]').click();await page.locator('#view-files .story-link').first().click();await visible('#story-dialog[open]');await page.keyboard.press('Escape');await page.waitForTimeout(300);
 });
 await check('Search shortcuts, highlights and keyboard navigation',async()=>{
  await page.keyboard.press('Control+k');await visible('#search-dialog[open]');await page.locator('#global-search').fill('compiler');await visible('#search-dialog mark');await page.keyboard.press('ArrowDown');assert(await page.evaluate(()=>document.activeElement.classList.contains('search-result')));await page.keyboard.press('Enter');await page.waitForTimeout(300);assert(!(await page.locator('#search-dialog').evaluate(e=>e.open)));
  await page.keyboard.press('Escape');await page.waitForTimeout(300);await page.keyboard.press('/');await visible('#search-dialog[open]');await page.keyboard.press('Escape');
 });
 await check('Native clipboard, story feedback and fallback dialog',async()=>{
  await route('#E4.S3');await page.locator('#story-dialog details summary').click();
  const copy=page.locator('#story-dialog [data-copy-path]').first();const value=await copy.getAttribute('data-copy-path');
  await copy.click();await visible('#story-dialog-feedback');assert.equal(await page.evaluate(()=>navigator.clipboard.readText()),value);
  const code=page.locator('#story-dialog [data-copy-code]').first();if(await code.count()){const expected=await code.evaluate(e=>e.closest('.code-example').querySelector('pre').textContent);await code.click();assert.equal(await page.evaluate(()=>navigator.clipboard.readText()),expected)}
  await page.evaluate(()=>{window.__nativeClipboard=navigator.clipboard;return navigator.clipboard.writeText('fallback-sentinel')});
  await page.evaluate(()=>{Object.defineProperty(navigator,'clipboard',{configurable:true,value:undefined})});await copy.click();await visible('#story-dialog-feedback');assert.equal(await page.evaluate(()=>window.__nativeClipboard.readText()),value);
  await page.evaluate(()=>{Object.defineProperty(navigator,'clipboard',{configurable:true,value:undefined});document.execCommand=()=>false});await copy.click();await visible('#copy-dialog[open]');assert.equal(await page.locator('#copy-text').inputValue(),value);await page.keyboard.press('Escape');await page.keyboard.press('Escape');await page.waitForTimeout(300);
  await page.evaluate(()=>Object.defineProperty(navigator,'clipboard',{configurable:true,value:window.__nativeClipboard}));
  await route('#reference-unit-api');
  const example=page.locator('#view-epics details[open] [data-copy-code]').first();
  const expectedCode=await example.evaluate(e=>e.closest('.code-example').querySelector('pre').textContent);
  await example.click();await visible('#toast');assert.equal(await page.evaluate(()=>navigator.clipboard.readText()),expectedCode);
 });
 await check('JSON export and downloaded standalone HTML remount/reset',async()=>{
  await route('#epics');await page.locator('#story-filter').fill('compiler');await page.locator('.design-reference summary').first().click();
  await page.locator('#export-trigger').click();const jsonPromise=page.waitForEvent('download');await page.locator('[data-export="json"]').click();const json=await jsonPromise;await json.saveAs(path.join(out,json.suggestedFilename()));assert.deepEqual(JSON.parse(await fs.readFile(path.join(out,json.suggestedFilename()),'utf8')),await page.evaluate(()=>window.PLAN_DATA));
  await page.locator('#export-trigger').click();const htmlPromise=page.waitForEvent('download');await page.locator('[data-export="html"]').click();const html=await htmlPromise;const dest=path.join(out,html.suggestedFilename());await html.saveAs(dest);
  const reopened=await context.newPage();reopened.on('pageerror',e=>errors.push(e.message));await reopened.goto(pathToFileURL(dest).href);await reopened.locator('#view-overview').waitFor();assert.equal(await reopened.locator('#sidebar').count(),1);assert.equal(await reopened.locator('#story-filter').inputValue(),'');assert.equal(await reopened.locator('dialog[open]').count(),0);assert.equal(await reopened.locator('#view-epics details[open]').count(),0);await reopened.close();
 });
 await check('Print expands all content, PDF export and restoration',async()=>{
  const before=await page.evaluate(()=>({theme:document.documentElement.dataset.theme,details:[...document.querySelectorAll('details')].map(e=>e.open),hidden:[...document.querySelectorAll('.epic-card,.story-card')].map(e=>e.hidden)}));
  await page.evaluate(()=>window.dispatchEvent(new Event('beforeprint')));assert.equal(await page.locator('html').getAttribute('data-theme'),'light');assert.equal(await page.locator('details:not([open])').count(),0);
  await page.emulateMedia({media:'print'});assert.equal(await page.locator('.page-view:visible').count(),6);assert.equal(await page.locator('.story-body:visible').count(),23);
  await page.pdf({path:path.join(out,'plan.pdf'),format:'A4'});await page.emulateMedia({media:'screen'});await page.evaluate(()=>window.dispatchEvent(new Event('afterprint')));
  const after=await page.evaluate(()=>({theme:document.documentElement.dataset.theme,details:[...document.querySelectorAll('details')].map(e=>e.open),hidden:[...document.querySelectorAll('.epic-card,.story-card')].map(e=>e.hidden)}));assert.deepEqual(after,before);
  assert.deepEqual(await page.locator('#export-menu [data-export]').evaluateAll(buttons=>buttons.map(button=>button.dataset.export)),['html','json']);
 });
 await check('Mobile drawer, focus trap, overlay and responsive widths',async()=>{
  await page.setViewportSize({width:390,height:844});await page.reload();await page.locator('#mobile-menu').click();await visible('#sidebar');assert(await page.locator('body').evaluate(e=>e.classList.contains('nav-open')));
  const buttons=page.locator('#sidebar a, #sidebar button');const visibleButtons=[];for(const el of await buttons.all())if(await el.isVisible())visibleButtons.push(el);
  await visibleButtons.at(-1).focus();await page.keyboard.press('Tab');assert(await visibleButtons[0].evaluate(e=>e===document.activeElement));await page.keyboard.press('Shift+Tab');assert(await visibleButtons.at(-1).evaluate(e=>e===document.activeElement));
  await page.keyboard.press('Escape');assert(!(await page.locator('body').evaluate(e=>e.classList.contains('nav-open'))));
  await page.locator('#mobile-menu').click();await page.locator('.nav-overlay').click({position:{x:300,y:100}});assert(!(await page.locator('body').evaluate(e=>e.classList.contains('nav-open'))));
  for(const width of [390,760,761]){await page.setViewportSize({width,height:844});await route('#overview');await page.screenshot({path:path.join(out,`mobile-${width}.png`)});assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),`overflow at ${width}`)}
 });
 await page.setViewportSize({width:390,height:844});await route('#epics');
 await visible('#epic-story-picker');assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'picker overflows on mobile');
 await page.screenshot({path:path.join(out,'mobile-epics.png')});
 assert.deepEqual(errors,[],'browser errors');await fs.writeFile(path.join(out,'results.json'),JSON.stringify({checks,errors},null,2));await browser.close();console.log('ALL',checks.length,'ACCEPTANCE GROUPS PASSED');
})().catch(e=>{console.error(e);process.exit(1)});
