# The Swivel film

`swivel-film.html` is the whole film: a 1920×1080 scene drawn in HTML and CSS, where every frame is a pure function of time. The same file is the interactive page (with chapters and a cheat sheet) and the source of `docs/swivel-film.mp4`.

```bash
npm install          # puppeteer-core only; it drives the Chrome you already have
npm run render       # writes ../swivel-film.mp4 (needs ffmpeg)
npm run stills       # PNG stills at a few key moments, for checking a change
```

Open `swivel-film.html#capture` to see just the film at full size, as the renderer does. The page exposes `window.__demo` (`duration`, `seek(ms)`, `play()`, `pause()`), which the scripts use to draw exact frames.

To refresh the README preview after rendering:

```bash
ffmpeg -i ../swivel-film.mp4 -vf "fps=12,scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=256:stats_mode=full[p];[b][p]paletteuse=dither=sierra2_4a:diff_mode=rectangle" ../swivel-film.gif
```
