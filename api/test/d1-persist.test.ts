import { describe, it, expect } from 'vitest';
import { D1Store } from '../src/d1store';

// D1-less: fake binding records SQL so the ON CONFLICT clauses and child
// pruning can be asserted without a D1 database.
function makeFakeD1() {
  const stmts: { sql: string; params: unknown[] }[] = [];
  const terminal = {
    all: async () => ({ results: [] as Record<string, unknown>[] }),
    first: async () => null,
    run: async () => {
      stmts.push(last);
      return {};
    },
  };
  let last = { sql: '', params: [] as unknown[] };
  const db = {
    prepare(sql: string) {
      return {
        bind(...params: unknown[]) {
          last = { sql, params };
          return terminal;
        },
        all: async () => ({ results: [] as Record<string, unknown>[] }),
      };
    },
  };
  return { db, stmts };
}

describe('D1Store SQL generation (fake binding)', () => {
  it('recipe upsert persists meta fields and prunes omitted children', async () => {
    const { db, stmts } = makeFakeD1();
    const store = new D1Store(db as never);
    const r = await store.createRecipe(
      {
        title: 'R', householdId: 'hh-demo', prepMinutes: 5, cookMinutes: 6, rating: 3,
        source: 'S', sourceUrl: 'https://x.example/', categories: ['c'],
        ingredients: [{ name: 'A' }], steps: [{ text: 'T' }],
      },
      { deviceId: 'd1' },
    );
    const upsert = stmts.find((s) => s.sql.startsWith('INSERT INTO recipes'));
    expect(upsert).toBeDefined();
    for (const col of ['prep_minutes', 'cook_minutes', 'rating', 'is_favorite', 'source', 'source_url', 'categories', 'photo_original']) {
      expect(upsert!.sql).toContain(`${col}=excluded.${col}`);
    }
    // Update omitting all children: DELETEs must cover both child tables.
    stmts.length = 0;
    await store.updateRecipe(r.id, { title: 'R2', householdId: 'hh-demo', ingredients: [], steps: [] }, { deviceId: 'd1' });
    const dels = stmts.filter((s) => s.sql.startsWith('DELETE FROM'));
    expect(dels.some((s) => s.sql === 'DELETE FROM ingredients WHERE recipe_id = ?')).toBe(true);
    expect(dels.some((s) => s.sql === 'DELETE FROM steps WHERE recipe_id = ?')).toBe(true);
  });

  it('recipe update keeps present children via NOT IN prune', async () => {
    const { db, stmts } = makeFakeD1();
    const store = new D1Store(db as never);
    const r = await store.createRecipe(
      { title: 'R', householdId: 'hh-demo', ingredients: [{ id: 'k1', name: 'A' }, { id: 'k2', name: 'B' }], steps: [] },
      { deviceId: 'd1' },
    );
    stmts.length = 0;
    await store.updateRecipe(
      r.id,
      { title: 'R', householdId: 'hh-demo', ingredients: [{ id: 'k1', name: 'A2' }], steps: [] },
      { deviceId: 'd1' },
    );
    const prune = stmts.find((s) => s.sql.startsWith('DELETE FROM ingredients'));
    expect(prune?.sql).toContain('NOT IN (?)');
    expect(prune?.params).toEqual([r.id, 'k1']);
  });

  it('pantry upsert persists all fields; list update prunes omitted items', async () => {
    const { db, stmts } = makeFakeD1();
    const store = new D1Store(db as never);
    await store.createPantry(
      { name: 'M', householdId: 'hh-demo', location: 'L', expiresAt: '2026-01-01', lowThreshold: 't', barcode: 'b' },
      { deviceId: 'd1' },
    );
    const upsert = stmts.find((s) => s.sql.startsWith('INSERT INTO pantry_items'));
    expect(upsert).toBeDefined();
    for (const col of ['location', 'expires_at', 'low_threshold', 'barcode']) {
      expect(upsert!.sql).toContain(`${col}=excluded.${col}`);
    }
    const l = await store.createList(
      { name: 'S', householdId: 'hh-demo', items: [{ id: 'a', name: 'A' }, { id: 'b', name: 'B' }] },
      { deviceId: 'd1' },
    );
    stmts.length = 0;
    await store.updateList(l.id, { name: 'S', householdId: 'hh-demo', items: [{ id: 'a', name: 'A' }] }, { deviceId: 'd1' });
    const prune = stmts.find((s) => s.sql.startsWith('DELETE FROM list_items'));
    expect(prune?.sql).toContain('NOT IN (?)');
    expect(prune?.params).toEqual([l.id, 'a']);
  });
});
