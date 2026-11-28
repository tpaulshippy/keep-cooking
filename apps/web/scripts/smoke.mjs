// Smoke test: scaffold checks (source-text) PLUS one real behavioral
// assertion — the pure aggregation helpers are bundled with esbuild and
// executed, no network involved. Exit 0 with no API present; if an API base
// responds to /health, its parsed version is logged but never required.
import { readFileSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { tmpdir } from 'node:os';

const here = dirname(fileURLToPath(import.meta.url));
const webRoot = join(here, '..');

let failures = 0;
function check(name, cond) {
  console.log(`${cond ? 'ok' : 'FAIL'} - ${name}`);
  if (!cond) failures++;
}

// 1. Required scaffold files exist.
for (const f of [
  'package.json', 'vite.config.ts', 'tsconfig.json', 'index.html', 'README.md',
  'src/api.ts', 'src/store.ts', 'src/router.ts', 'src/main.ts', 'src/styles.css',
  'src/scale.ts', 'src/aggregate.ts', 'src/sync.ts', 'src/lists.ts',
]) {
  check(`file ${f}`, existsSync(join(webRoot, f)));
}

// 2. index.html: mobile viewport + landmark + /app base.
const html = readFileSync(join(webRoot, 'index.html'), 'utf8');
check('index.html viewport', html.includes('name="viewport"'));
check('index.html landmark', /role="main"|aria-label/.test(html));
check('index.html references main.ts', html.includes('src/main.ts'));

// 3. vite base /app + port 5174.
const vite = readFileSync(join(webRoot, 'vite.config.ts'), 'utf8');
check("vite base '/app/'", vite.includes("'/app/'"));
check('vite port 5174', vite.includes('5174'));

// 4. Router is history-based (no hash routes shipped).
const routerSrc = readFileSync(join(webRoot, 'src/router.ts'), 'utf8');
check('router uses history API', routerSrc.includes('pushState') && routerSrc.includes("BASE = '/app'"));

// 5. BEHAVIORAL: bundle the pure helpers and run a real aggregation.
//    Doubling one recipe's servings must double its measured quantity,
//    unmeasured 'to taste' must survive, and 'ice cream' must sort Frozen.
//    Bundling uses esbuild's JS API (createRequire) so no platform-specific
//    .bin/.cmd shell shim is needed; a .bin fallback covers exotic installs.
try {
  let builtCode = null;
  try {
    const { createRequire } = await import('node:module');
    const require = createRequire(join(webRoot, 'package.json'));
    const { buildSync } = require('esbuild');
    const result = buildSync({
      entryPoints: [join(webRoot, 'src/aggregate.ts')],
      bundle: true,
      platform: 'node',
      format: 'esm',
      write: false,
    });
    builtCode = result.outputFiles[0].text;
  } catch (apiErr) {
    const exe = `esbuild${process.platform === 'win32' ? '.cmd' : ''}`;
    const esbuild = join(webRoot, 'node_modules', '.bin', exe);
    if (!existsSync(esbuild)) throw new Error(`esbuild JS API failed (${apiErr.message}) and ${exe} not installed; run npm install`);
    const out = join(tmpdir(), `kc-smoke-${process.pid}.mjs`);
    execFileSync(esbuild, ['src/aggregate.ts', '--bundle', '--platform=node', '--format=esm', `--outfile=${out}`], {
      cwd: webRoot, stdio: 'pipe', shell: process.platform === 'win32',
    });
    const agg = await import(pathToFileURL(out).href);
    checkBehavioral(agg);
  }
  if (builtCode !== null) {
    const out = join(tmpdir(), `kc-smoke-${process.pid}.mjs`);
    const { writeFileSync } = await import('node:fs');
    writeFileSync(out, builtCode);
    const agg = await import(pathToFileURL(out).href);
    checkBehavioral(agg);
  }
} catch (err) {
  check(`behavioral aggregate threw: ${err.message}`, false);
}

function checkBehavioral(agg) {
  const got = agg.aggregateWeekToList(
    agg.collectPlanIngredients(
      [
        { date: '2026-01-05', servings: 8, recipeId: 'pasta' },
        { date: '2026-02-01', servings: 4, recipeId: 'pasta' }, // outside week: excluded
      ],
      ['2026-01-05', '2026-01-06', '2026-01-07', '2026-01-08', '2026-01-09', '2026-01-10', '2026-01-11'],
      (id) => id === 'pasta'
        ? { servings: 4, ingredients: [{ name: 'Spaghetti', quantity: 12, unit: 'oz' }, { name: 'Salt', display: 'to taste' }] }
        : undefined,
    ).concat([{ name: 'Ice cream', quantity: 1, unit: 'tub' }]),
  );
  const names = got.map((i) => `${i.name}=${i.quantity}[${i.aisle}]`).join(' | ');
  check(`behavioral aggregate (${names})`,
    got.find((i) => i.name === 'Spaghetti')?.quantity === '24 oz' &&
    got.some((i) => i.name === 'Salt' && i.quantity === 'to taste') &&
    got.find((i) => i.name === 'Ice cream')?.aisle === 'Frozen');
}

// 6. Optional API probe (informational only, never fails offline). The abort
// timeout stays armed until the body is consumed (slow bodies can hang); it
// is always cleared in `finally`.
const base = process.env.API_BASE_URL ?? 'http://localhost:8787';
{
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), 3000);
  try {
    const res = await fetch(`${base}/health`, { signal: ctl.signal });
    let version = 'n/a';
    try {
      const data = await res.json();
      version = data?.version ?? 'n/a';
    } catch { /* non-JSON body */ }
    console.log(`info - API ${base} responded ${res.status} version=${version} (optional)`);
  } catch {
    console.log(`info - no API at ${base}; offline store smoke only (this is fine)`);
  } finally {
    clearTimeout(t);
  }
}

process.exit(failures ? 1 : 0);
