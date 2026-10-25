// Builds the native apps' board editor page (web/main.js + the vendored sol editor in web/sol) into dist/.
// Run through scripts/build-board-editor.sh (Xcode runs it for the app targets).
import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const fontsDir = path.join(here, 'node_modules', '@excalidraw', 'excalidraw', 'dist', 'prod', 'fonts');
const FONT_TYPES = new Set(['.woff2', '.woff', '.ttf']);

function walk(dir, base = dir) {
  return readdirSync(dir).flatMap(name => {
    const full = path.join(dir, name);
    return statSync(full).isDirectory() ? walk(full, base) : [path.relative(base, full)];
  });
}

const excalidrawFonts = {
  name: 'excalidraw-fonts',
  generateBundle() {
    if (!existsSync(fontsDir)) throw new Error(`Excalidraw fonts are missing at ${fontsDir}; run scripts/build-board-editor.sh.`);
    for (const relative of walk(fontsDir)) {
      if (!FONT_TYPES.has(path.extname(relative))) continue;
      this.emitFile({ type: 'asset', fileName: `excalidraw-assets/fonts/${relative.split(path.sep).join('/')}`, source: readFileSync(path.join(fontsDir, relative)) });
    }
  },
};

export default {
  root: path.join(here, 'web'),
  base: './',
  logLevel: 'warn',
  plugins: [excalidrawFonts],
  build: {
    outDir: path.join(here, 'dist'),
    emptyOutDir: true,
    target: 'es2022',
    modulePreload: false,
    chunkSizeWarningLimit: 8000,
  },
};
