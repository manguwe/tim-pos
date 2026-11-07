// Builds the dashboard into dist/ with esbuild: one hashed script, one hashed stylesheet and an index.html that names them.
// `node build.mjs --watch` rebuilds when a file changes. The server serves dist/ at /dashboard/ (no extra web server needed).
import { build, context } from 'esbuild';
import { mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { basename } from 'node:path';

const watch = process.argv.includes('--watch');
const options = {
  entryPoints: { app: 'src/main.tsx' },
  bundle: true,
  format: 'esm',
  target: 'es2022',
  jsx: 'automatic',
  outdir: 'dist',
  entryNames: '[name]-[hash]',
  minify: !watch,
  sourcemap: false,
  metafile: true,
  loader: { '.css': 'css' },
  define: { 'process.env.NODE_ENV': watch ? '"development"' : '"production"' },
  logLevel: 'info',
};

function writeIndex(meta) {
  const outs = Object.keys(meta.outputs);
  const js = outs.find((f) => f.endsWith('.js'));
  const css = outs.find((f) => f.endsWith('.css'));
  if (!js) throw new Error('The build made no script');
  const html = readFileSync('src/index.html', 'utf8')
    .replace('%CSS%', css ? `<link rel="stylesheet" href="${basename(css)}">` : '')
    .replace('%JS%', `<script type="module" src="${basename(js)}"></script>`);
  writeFileSync('dist/index.html', html);
}

rmSync('dist', { recursive: true, force: true });
mkdirSync('dist', { recursive: true });
if (watch) {
  const ctx = await context({ ...options, plugins: [{ name: 'index', setup(b) { b.onEnd((r) => { if (r.metafile) writeIndex(r.metafile); }); } }] });
  await ctx.watch();
  console.log('Watching. Reload the page after a change.');
} else {
  const r = await build(options);
  writeIndex(r.metafile);
}
