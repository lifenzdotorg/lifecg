// Bundles the portal (src/portal) into public/ and copies the notes themes (../notes-themes) next to it.
import * as esbuild from 'esbuild';
import { createHash } from 'node:crypto';
import { cpSync, existsSync, mkdirSync, readdirSync, copyFileSync, readFileSync, writeFileSync } from 'node:fs';

const watch = process.argv.includes('--watch');
mkdirSync('public/themes', { recursive: true });
for (const id of readdirSync('../notes-themes')) {
  if (existsSync(`../notes-themes/${id}/theme.json`)) cpSync(`../notes-themes/${id}`, `public/themes/${id}`, { recursive: true });
}

copyFileSync('src/portal/styles.css', 'public/styles.css');
if (existsSync('src/portal/icon.svg')) copyFileSync('src/portal/icon.svg', 'public/icon.svg');
// pdf.js for "Import PDF" (loaded on demand, not bundled)
mkdirSync('public/vendor', { recursive: true });
for (const f of ['pdf.min.mjs', 'pdf.worker.min.mjs']) copyFileSync(`node_modules/pdfjs-dist/build/${f}`, `public/vendor/${f}`);

const opts = {
  entryPoints: ['src/portal/main.tsx'],
  bundle: true,
  format: 'esm',
  target: ['es2022', 'safari16'],
  outfile: 'public/app.js',
  jsx: 'automatic',
  jsxImportSource: 'preact',
  minify: !watch,
  sourcemap: true,
  logLevel: 'info',
};
// ProPresenter export: its own file, loaded on demand
const bundleOpts = { ...opts, entryPoints: ['src/portal/probundleEntry.ts'], outfile: 'public/probundle.js' };
if (watch) {
  await (await esbuild.context(bundleOpts)).watch();
  await (await esbuild.context({ ...opts, define: { __PROBUNDLE_VER__: '"dev"' } })).watch();
} else {
  await esbuild.build(bundleOpts);
  // the app asks for probundle.js?v=<hash> so a new version isn't served from an old cache
  const pv = createHash('sha256').update(readFileSync('public/probundle.js')).digest('hex').slice(0, 10);
  await esbuild.build({ ...opts, define: { __PROBUNDLE_VER__: JSON.stringify(pv) } });
}
// index.html with versioned links, so a deploy reaches browsers that cached the old app
const ver = (f) => createHash('sha256').update(readFileSync(f)).digest('hex').slice(0, 10);
writeFileSync(
  'public/index.html',
  readFileSync('src/portal/index.html', 'utf8')
    .replace('/app.js"', `/app.js?v=${ver('public/app.js')}"`)
    .replace('/styles.css"', `/styles.css?v=${ver('public/styles.css')}"`),
);
