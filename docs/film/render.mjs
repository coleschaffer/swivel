// Renders the demo to an MP4, frame by frame, from the page's own deterministic timeline.
//   node render.mjs <fragment.html> <out.mp4> [fps=30]
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { open, seek } from './lib.mjs';

const [fragment, out, fpsArg] = process.argv.slice(2);
const fps = Number(fpsArg) || 30;
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'swivel-frames-'));
const { browser, page, errors } = await open({ fragment, width: 1920, height: 1080 });
const duration = await page.evaluate(() => window.__demo.duration);
const frames = Math.ceil(duration / 1000 * fps);
for (let i = 0; i < frames; i++) {
  await seek(page, i * 1000 / fps);
  await page.screenshot({ path: path.join(dir, `f${String(i).padStart(5, '0')}.png`) });
  if (i % fps === 0) process.stdout.write(`\r${Math.round(i / frames * 100)}%`);
}
await browser.close();
console.log(`\r${frames} frames; page errors: ${errors.length ? errors.join(' | ') : 'none'}`);
const ff = spawnSync('ffmpeg', ['-y', '-loglevel', 'error', '-framerate', String(fps), '-i', path.join(dir, 'f%05d.png'),
  '-c:v', 'libx264', '-preset', 'slow', '-crf', '16', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', out], { stdio: 'inherit' });
fs.rmSync(dir, { recursive: true, force: true });
if (ff.status !== 0) process.exit(ff.status ?? 1);
console.log(out);
