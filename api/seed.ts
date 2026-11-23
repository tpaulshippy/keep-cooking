// Seed: imports the frozen contract seeds (packages/contracts/seed/*.json)
// into a Store (memory or D1), creating the demo household + memberships.
// Also generates drizzle/seed.sql for `wrangler d1 execute --file`.
//
// Usage:
//   bun run seed.ts --generate-sql   # writes drizzle/seed.sql
//   npm run seed                      # same via bun

import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { MemoryStore, type Store } from './src/store';

const here = dirname(fileURLToPath(import.meta.url));
const SEED_DIR = join(here, '..', 'packages', 'contracts', 'seed');

export interface SeedRecord {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  [k: string]: any;
}

export function loadSeedRecords(): SeedRecord[] {
  const files = readdirSync(SEED_DIR).filter((f) => f.endsWith('.json')).sort();
  return files.map((f) => JSON.parse(readFileSync(join(SEED_DIR, f), 'utf8')));
}

export async function seedStore(store: Store, deviceId = 'seed'): Promise<{ households: number; recipes: number }> {
  const records = loadSeedRecords();
  let households = 0;
  let recipes = 0;
  for (const r of records) {
    const hh = r.householdId ?? 'hh-demo';
    await store.ensureHousehold(hh, 'Demo Household');
    households++;
    await store.createRecipe(
      {
        title: r.title,
        description: r.description ?? '',
        servings: r.servings ?? 4,
        prepMinutes: r.prepMinutes ?? null,
        cookMinutes: r.cookMinutes ?? null,
        rating: r.rating ?? null,
        source: r.source ?? 'Seed',
        sourceUrl: r.sourceUrl ?? '',
        categories: r.categories ?? [],
        photoKeys: r.photoKeys ?? {},
        ingredients: r.ingredients ?? [],
        steps: r.steps ?? [],
        householdId: hh,
      },
      { deviceId, id: r.id, updatedAt: r.updatedAt },
    );
    recipes++;
  }
  // Demo memberships: owner/member/viewer for local dev + tests.
  await store.ensureHousehold('hh-demo', 'Demo Household');
  await store.setMembership('hh-demo', 'u-owner', 'owner');
  await store.setMembership('hh-demo', 'u-member', 'member');
  await store.setMembership('hh-demo', 'u-viewer', 'viewer');
  await store.setMembership('hh-demo', 'dev-user', 'owner');
  return { households, recipes };
}

function sqlStr(v: unknown): string {
  if (v == null) return 'NULL';
  if (typeof v === 'number') return String(v);
  return `'${String(v).replace(/'/g, "''")}'`;
}

export function seedRecordsToSql(records: SeedRecord[]): string {
  const out: string[] = [
    '-- Generated seed from packages/contracts/seed/*.json — do not hand-edit.',
    `INSERT INTO households (id, name) VALUES ('hh-demo', 'Demo Household') ON CONFLICT(id) DO NOTHING;`,
    `INSERT INTO memberships (household_id, user_id, role) VALUES ('hh-demo', 'u-owner', 'owner') ON CONFLICT(household_id, user_id) DO NOTHING;`,
    `INSERT INTO memberships (household_id, user_id, role) VALUES ('hh-demo', 'u-member', 'member') ON CONFLICT(household_id, user_id) DO NOTHING;`,
    `INSERT INTO memberships (household_id, user_id, role) VALUES ('hh-demo', 'u-viewer', 'viewer') ON CONFLICT(household_id, user_id) DO NOTHING;`,
  ];
  for (const r of records) {
    out.push(
      `INSERT INTO recipes (id, household_id, title, description, servings, prep_minutes, cook_minutes, rating, source, source_url, categories, photo_original, photo_large1024, photo_thumb, updated_at, device_id, deleted) VALUES (${sqlStr(r.id)}, ${sqlStr(r.householdId ?? 'hh-demo')}, ${sqlStr(r.title)}, ${sqlStr(r.description ?? '')}, ${r.servings ?? 4}, ${r.prepMinutes ?? 'NULL'}, ${r.cookMinutes ?? 'NULL'}, ${r.rating ?? 'NULL'}, ${sqlStr(r.source ?? 'Seed')}, ${sqlStr(r.sourceUrl ?? '')}, ${sqlStr(JSON.stringify(r.categories ?? []))}, ${sqlStr(r.photoKeys?.original ?? '')}, ${sqlStr(r.photoKeys?.large1024 ?? '')}, ${sqlStr(r.photoKeys?.thumb ?? '')}, ${sqlStr(r.updatedAt)}, ${sqlStr(r.deviceId ?? 'seed')}, 0) ON CONFLICT(id) DO NOTHING;`,
    );
    for (const g of r.ingredients ?? []) {
      out.push(
        `INSERT INTO ingredients (id, recipe_id, name, quantity, unit, display, position) VALUES (${sqlStr(g.id)}, ${sqlStr(r.id)}, ${sqlStr(g.name)}, ${g.quantity ?? 'NULL'}, ${sqlStr(g.unit ?? '')}, ${sqlStr(g.display ?? '')}, ${g.position ?? 0}) ON CONFLICT(id) DO NOTHING;`,
      );
    }
    for (const s of r.steps ?? []) {
      out.push(
        `INSERT INTO steps (id, recipe_id, position, text, timers) VALUES (${sqlStr(s.id)}, ${sqlStr(r.id)}, ${s.position ?? 0}, ${sqlStr(s.text)}, ${sqlStr(JSON.stringify(s.timers ?? []))}) ON CONFLICT(id) DO NOTHING;`,
      );
    }
  }
  return out.join('\n') + '\n';
}

// CLI: `bun run seed.ts --generate-sql`
const args = process.argv.slice(2);
if (args.includes('--generate-sql')) {
  const sql = seedRecordsToSql(loadSeedRecords());
  writeFileSync(join(here, 'drizzle', 'seed.sql'), sql);
  console.log(`wrote drizzle/seed.sql (${loadSeedRecords().length} recipes)`);
}

// Also allow seeding a live dev server: `SEED_BASE_URL=http://localhost:8787 bun run seed.ts --push`
if (args.includes('--push')) {
  const base = process.env['SEED_BASE_URL'] ?? 'http://localhost:8787';
  const mem = new MemoryStore();
  await seedStore(mem);
  const envs = await mem.pullSince('1970-01-01T00:00:00Z');
  const res = await fetch(`${base}/sync/push`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-user-id': 'u-owner', 'x-role': 'owner', 'x-device-id': 'seed' },
    body: JSON.stringify(envs),
  });
  console.log(`pushed ${envs.length} envelopes -> ${res.status}`);
}
