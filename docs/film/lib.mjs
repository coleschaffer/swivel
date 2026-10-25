// Shared helpers: open an artifact fragment in headless Chrome the way the Artifact viewer wraps it.
import fs from 'node:fs';
import path from 'node:path';
import puppeteer from 'puppeteer-core';

const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';

// The Artifact tool wraps the fragment in this skeleton at publish time; mirror it so local
// renders match the published page.
export function wrap(fragmentPath) {
  fragmentPath = path.resolve(fragmentPath);
  const fragment = fs.readFileSync(fragmentPath, 'utf8');
  const html = `<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<style>:root{color-scheme:light;padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)}
body{margin:0;font:14px/1.4 system-ui,-apple-system,sans-serif;background:#fafafa}img{max-width:100%}[hidden]{display:none!important}</style>
</head><body>${fragment}</body></html>`;
  const out = path.join(path.dirname(fragmentPath), '.wrapped-' + path.basename(fragmentPath));
  fs.writeFileSync(out, html);
  return out;
}

export async function open({ fragment, width = 1920, height = 1080, scale = 1, theme = 'dark', hash = 'capture' }) {
  const browser = await puppeteer.launch({
    executablePath: CHROME,
    headless: true,
    args: ['--hide-scrollbars', '--force-color-profile=srgb', '--disable-gpu-vsync'],
    defaultViewport: { width, height, deviceScaleFactor: scale },
  });
  const page = await browser.newPage();
  await page.emulateMediaFeatures([{ name: 'prefers-color-scheme', value: theme }]);
  const errors = [];
  page.on('pageerror', e => errors.push(String(e)));
  page.on('console', m => { if (m.type() === 'error') errors.push(m.text()); });
  const url = 'file://' + wrap(fragment) + (hash ? '#' + hash : '');
  await page.goto(url, { waitUntil: 'networkidle0', timeout: 60000 });
  await page.evaluate(() => document.fonts.ready);
  return { browser, page, errors };
}

/** Pauses the demo and draws the exact frame at `ms`. */
export async function seek(page, ms) {
  await page.evaluate(t => { window.__demo.pause(); window.__demo.seek(t); }, ms);
  await page.evaluate(() => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))));
}
