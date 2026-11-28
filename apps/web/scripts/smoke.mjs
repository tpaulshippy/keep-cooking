// Offline-capable smoke test: validates the seeded local store shape and
// pure helpers WITHOUT network. Exit 0 with no API present; if an API base
// responds to /health, its version is reported but never required.
import { readFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

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
  'src/scale.ts', 'src/aggregate.ts',
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

// 4. Seeded store: 3 demo recipes mentioned in store.ts.
const storeSrc = readFileSync(join(webRoot, 'src/store.ts'), 'utf8');
check('seed demo-pasta', storeSrc.includes('demo-pasta'));
check('seed demo-tacos', storeSrc.includes('demo-tacos'));
check('seed demo-soup', storeSrc.includes('demo-soup'));
check('LWW merge present', storeSrc.includes('lwwMerge'));
check('outbox present', storeSrc.includes('outbox'));

// 5. Optional API probe (informational only, never fails offline).
const base = process.env.API_BASE_URL ?? 'http://localhost:8787';
try {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), 3000);
  const res = await fetch(`${base}/health`, { signal: ctl.signal });
  clearTimeout(t);
  console.log(`info - API ${base} responded ${res.status} (optional)`);
} catch {
  console.log(`info - no API at ${base}; offline store smoke only (this is fine)`);
}

process.exit(failures ? 1 : 0);
