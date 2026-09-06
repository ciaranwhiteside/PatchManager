// Generate fixtures with Invoke-PatchManager.Static.Tests.ps1 -VisualArtifactPath <directory>.
// Requires Playwright with Chromium installed; run: node Tests/Report.Usability.Tests.cjs <directory>
const { chromium } = require('playwright');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const root = path.resolve(process.argv[2] || '.impeccable/review/report-usability');
const fleetDir = path.join(root, 'FleetOutput');
const fleetFile = fs.readdirSync(fleetDir).filter(name => name.endsWith('.html')).sort().pop();
const targets = [
  { name: 'device', file: path.join(root, 'DeviceReport.html'), rows: 'tr.data-row', search: '#searchInput', empty: '#reportFilterEmpty', reset: '#resetReportEmpty' },
  { name: 'fleet', file: path.join(fleetDir, fleetFile), rows: 'tr.fleet-row', search: '#fleetSearch', empty: '#fleetFilterEmpty', reset: '#resetFleetEmpty' }
];
(async () => {
  const browser = await chromium.launch({ headless: true });
  try {
    for (const target of targets) {
      for (const width of [1440, 768, 390]) {
        const page = await browser.newPage({ viewport: { width, height: 900 }, reducedMotion: 'reduce' });
        const errors = [];
        page.on('pageerror', error => errors.push(error.message));
        await page.goto(pathToFileURL(target.file).href);
        const count = await page.locator(target.rows).count();
        assert.ok(count > 0, 'Fixture must contain report rows');
        await page.locator(target.search).fill('no-matching-host-or-package-9281');
        assert.equal(await page.locator(target.rows + ':visible').count(), 0, 'Filters must actually hide rows at every width');
        assert.ok(await page.locator(target.empty).isVisible(), 'No matches must offer recovery');
        await page.emulateMedia({ media: 'print' });
        assert.equal(await page.locator(target.rows + ':visible').count(), count, 'Printing must preserve every filtered row');
        assert.equal(await page.locator(target.empty).isVisible(), false, 'Print must omit filter messages');
        await page.emulateMedia({ media: 'screen' });
        assert.equal(await page.locator(target.rows + ':visible').count(), 0, 'Printing must preserve the screen filter');
        await page.locator(target.reset).click();
        assert.equal(await page.locator(target.search).inputValue(), '', 'Recovery must clear search');
        assert.equal(await page.locator(target.rows + ':visible').count(), count, 'Recovery must restore rows');
        assert.ok(await page.locator(target.search).evaluate(el => el === document.activeElement), 'Recovery must restore keyboard focus');
        assert.equal(await page.locator(target.empty).isVisible(), false);
        const overflow = await page.evaluate(() => document.documentElement.scrollWidth > innerWidth);
        assert.equal(overflow, false, 'Report must fit the viewport');
        if (target.name === 'device' && width <= 820) {
          assert.equal(await page.locator('.version-flow').first().evaluate(el => getComputedStyle(el).whiteSpace), 'normal', 'Long versions must wrap on mobile');
        }
        if (target.name === 'fleet') {
          await page.locator('[data-risk-filter="failure"]').click();
          assert.equal(await page.locator('tr.fleet-row:visible').count(), 2, 'Execution lane count must match filtered hosts');
          await page.locator(target.search).fill('does-not-exist');
          await page.locator(target.reset).click();
          assert.equal(await page.locator('[data-risk-filter][aria-pressed="true"]').count(), 0, 'Recovery must clear risk selection');
        }
        assert.deepEqual(errors, [], 'Report must run without JavaScript errors');
        await page.close();
        console.log(`${target.name} ${width}px: filter, recovery, print, layout passed`);
      }
      const noJs = await browser.newPage({ javaScriptEnabled: false });
      await noJs.goto(pathToFileURL(target.file).href);
      assert.equal(await noJs.locator(target.rows + ':visible').count(), await noJs.locator(target.rows).count(), 'No-JavaScript output must retain every row');
      assert.equal(await noJs.locator(target.empty).isVisible(), false, 'No-JavaScript output must not show a false empty state');
      await noJs.close();
    }
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });