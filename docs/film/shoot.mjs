// Stills for review.
//   node shoot.mjs frames <fragment.html> <outdir> <ms,ms,...>        film frames (#capture mode, 1920x1080)
//   node shoot.mjs page <fragment.html> <out.png> <width> <light|dark>  the whole page as a viewer sees it
import fs from 'node:fs';
import path from 'node:path';
import { open, seek } from './lib.mjs';

const [mode, fragment, out, arg, theme] = process.argv.slice(2);
if (mode === 'frames') {
  fs.mkdirSync(out, { recursive: true });
  const { browser, page, errors } = await open({ fragment });
  const duration = await page.evaluate(() => window.__demo?.duration);
  if (!duration) throw new Error('window.__demo.duration is missing');
  for (const ms of arg.split(',').map(Number)) {
    await seek(page, ms);
    const file = path.join(out, `t-${String(ms).padStart(6, '0')}.png`);
    await page.screenshot({ path: file });
    console.log(file);
  }
  console.log(`duration ${duration}ms; errors: ${errors.length ? errors.join(' | ') : 'none'}`);
  await browser.close();
} else if (mode === 'page') {
  const width = Number(arg) || 1280;
  const { browser, page, errors } = await open({ fragment, width, height: 900, scale: 2, theme: theme || 'light', hash: '' });
  await new Promise(r => setTimeout(r, 1500));
  await page.screenshot({ path: out, fullPage: true });
  console.log(out);
  console.log(`errors: ${errors.length ? errors.join(' | ') : 'none'}`);
  await browser.close();
} else {
  console.error('usage: node shoot.mjs frames|page ...');
  process.exit(1);
}
