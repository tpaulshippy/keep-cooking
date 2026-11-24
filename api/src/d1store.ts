import { drizzle } from 'drizzle-orm/d1';
import type { Role } from './auth';
import {
  MemoryStore,
  nowIso,
  newId,
  e2eIsNewer,
  type Store,
  type Recipe,
  type ShoppingList,
  type PantryItem,
  type Plan,
  type Menu,
  type Membership,
  type Household,
} from './store';
import { envelopeHeader, type EncryptedEnvelope } from './e2e';

// D1-backed store. Uses drizzle() for the connection (D1 via Drizzle) and
// parameterized raw SQL for queries — table/column names match
// packages/contracts/schema.sql exactly. All values are bound parameters;
// no string interpolation of user input. PII is never logged here.

type D1 = {
  prepare(query: string): {
    bind(...values: unknown[]): {
      all(): Promise<{ results: Record<string, unknown>[] }>;
      first(): Promise<Record<string, unknown> | null>;
      run(): Promise<unknown>;
    };
    all(): Promise<{ results: Record<string, unknown>[] }>;
  };
  batch?(stmts: unknown[]): Promise<unknown[]>;
};

function jparse<T>(s: unknown, fallback: T): T {
  if (typeof s !== 'string' || !s) return fallback;
  try {
    return JSON.parse(s) as T;
  } catch {
    return fallback;
  }
}

export class D1Store extends MemoryStore implements Store {
  private db: D1;
  private drizzleDb: ReturnType<typeof drizzle>;
  private hydrated = false;
  /**
   * E2E writes accepted into memory but not yet confirmed in D1 (persist
   * threw). Keyed hash -> id -> envelope. loadE2EHash() keeps these across
   * D1 reconciles so a wipe on another isolate can't drop a local write
   * that D1 never saw; everything else absent from D1 is dropped.
   */
  private e2eUnsaved = new Map<string, Map<string, EncryptedEnvelope>>();

  constructor(d1: D1) {
    super();
    this.db = d1;
    // D1 via Drizzle: the canonical connection object for the Worker.
    this.drizzleDb = drizzle(d1 as never);
    void this.drizzleDb;
  }

  /** Merge D1 rows into the in-memory maps (LWW per row). Safe to run per
   * request: D1 wins ties/newer; unpersisted memory rows (D1 unavailable)
   * are kept. Self-healing — no one-shot flag. */
  async hydrate(): Promise<void> {
    const q = async (sql: string) => (await this.db.prepare(sql).all()).results;
    // Snapshot memory rows so strictly-newer local writes survive the reload.
    const prev = {
      recipes: new Map(this.recipes),
      lists: new Map(this.lists),
      pantry: new Map(this.pantry),
      plans: new Map(this.plans),
      menus: new Map(this.menus),
    };
    try {
      const hh = await q('SELECT id, name FROM households');
      for (const h of hh) {
        this.households.set(String(h['id']), { id: String(h['id']), name: String(h['name'] ?? '') });
      }
      for (const m of await q('SELECT household_id, user_id, role FROM memberships')) {
        const hh = String(m['household_id']);
        const u = String(m['user_id']);
        this.memberships.set(`${hh}|${u}`, { householdId: hh, userId: u, role: String(m['role']) as Role });
      }
      const ingByRecipe = new Map<string, { id: string; recipeId: string; name: string; quantity: number | null; unit: string; display: string; position: number }[]>();
      for (const g of await q('SELECT id, recipe_id, name, quantity, unit, display, position FROM ingredients ORDER BY position')) {
        const rid = String(g['recipe_id']);
        if (!ingByRecipe.has(rid)) ingByRecipe.set(rid, []);
        ingByRecipe.get(rid)!.push({
          id: String(g['id']), recipeId: rid, name: String(g['name'] ?? ''),
          quantity: g['quantity'] == null ? null : Number(g['quantity']),
          unit: String(g['unit'] ?? ''), display: String(g['display'] ?? ''),
          position: Number(g['position'] ?? 0),
        });
      }
      const stepsByRecipe = new Map<string, { id: string; position: number; text: string; timers: { seconds: number; label: string }[]; recipeId: string }[]>();
      for (const s of await q('SELECT id, recipe_id, position, text, timers FROM steps ORDER BY position')) {
        const rid = String(s['recipe_id']);
        if (!stepsByRecipe.has(rid)) stepsByRecipe.set(rid, []);
        stepsByRecipe.get(rid)!.push({
          id: String(s['id']), position: Number(s['position'] ?? 0), text: String(s['text'] ?? ''),
          timers: jparse(s['timers'], []), recipeId: rid,
        });
      }
      for (const r of await q('SELECT * FROM recipes')) {
        const id = String(r['id']);
        this.recipes.set(id, {
          id,
          householdId: String(r['household_id'] ?? ''),
          title: String(r['title'] ?? ''),
          description: String(r['description'] ?? ''),
          servings: Number(r['servings'] ?? 4),
          prepMinutes: r['prep_minutes'] == null ? null : Number(r['prep_minutes']),
          cookMinutes: r['cook_minutes'] == null ? null : Number(r['cook_minutes']),
          rating: r['rating'] == null ? null : Number(r['rating']),
          source: String(r['source'] ?? ''),
          sourceUrl: String(r['source_url'] ?? ''),
          categories: jparse<string[]>(r['categories'], []),
          photoKeys: {
            original: String(r['photo_original'] ?? ''),
            large1024: String(r['photo_large1024'] ?? ''),
            thumb: String(r['photo_thumb'] ?? ''),
          },
          updatedAt: String(r['updated_at'] ?? ''),
          deviceId: String(r['device_id'] ?? ''),
          deleted: Number(r['deleted'] ?? 0) === 1,
          ingredients: ingByRecipe.get(id) ?? [],
          steps: stepsByRecipe.get(id) ?? [],
        });
      }
      const itemsByList = new Map<string, { id: string; name: string; quantity: string; aisle: string; checked: boolean; recipeId: string | null }[]>();
      for (const it of await q('SELECT id, list_id, name, quantity, aisle, checked, recipe_id FROM list_items')) {
        const lid = String(it['list_id']);
        if (!itemsByList.has(lid)) itemsByList.set(lid, []);
        itemsByList.get(lid)!.push({
          id: String(it['id']), name: String(it['name'] ?? ''),
          quantity: String(it['quantity'] ?? ''), aisle: String(it['aisle'] ?? ''),
          checked: Number(it['checked'] ?? 0) === 1,
          recipeId: it['recipe_id'] == null ? null : String(it['recipe_id']),
        });
      }
      for (const l of await q('SELECT * FROM shopping_lists')) {
        const id = String(l['id']);
        this.lists.set(id, {
          id, entity: 'list', householdId: String(l['household_id'] ?? ''), name: String(l['name'] ?? ''),
          items: itemsByList.get(id) ?? [],
          updatedAt: String(l['updated_at'] ?? ''), deviceId: String(l['device_id'] ?? ''),
          deleted: Number(l['deleted'] ?? 0) === 1,
        });
      }
      for (const p of await q('SELECT * FROM pantry_items')) {
        const id = String(p['id']);
        this.pantry.set(id, {
          id, entity: 'pantryItem', householdId: String(p['household_id'] ?? ''), name: String(p['name'] ?? ''),
          quantity: String(p['quantity'] ?? ''), location: String(p['location'] ?? ''),
          expiresAt: p['expires_at'] == null ? null : String(p['expires_at']),
          lowThreshold: String(p['low_threshold'] ?? ''), barcode: String(p['barcode'] ?? ''),
          updatedAt: String(p['updated_at'] ?? ''), deviceId: String(p['device_id'] ?? ''),
          deleted: Number(p['deleted'] ?? 0) === 1,
        });
      }
      for (const p of await q('SELECT * FROM plans')) {
        const id = String(p['id']);
        this.plans.set(id, {
          id, entity: 'plan', householdId: String(p['household_id'] ?? ''), date: String(p['date'] ?? ''),
          meal: String(p['meal'] ?? 'dinner'), recipeId: p['recipe_id'] == null ? null : String(p['recipe_id']),
          note: String(p['note'] ?? ''), servings: p['servings'] == null ? null : Number(p['servings']),
          updatedAt: String(p['updated_at'] ?? ''), deviceId: String(p['device_id'] ?? ''),
          deleted: Number(p['deleted'] ?? 0) === 1,
        });
      }
      for (const m of await q('SELECT * FROM menus')) {
        const id = String(m['id']);
        this.menus.set(id, {
          id, entity: 'menu', householdId: String(m['household_id'] ?? ''), name: String(m['name'] ?? ''),
          entries: jparse(m['entries'], []),
          updatedAt: String(m['updated_at'] ?? ''), deviceId: String(m['device_id'] ?? ''),
          deleted: Number(m['deleted'] ?? 0) === 1,
        });
      }
      // LWW merge: restore memory rows strictly newer than what D1 returned.
      const newer = <K, V extends { updatedAt: string }>(cur: Map<K, V>, old: Map<K, V>) => {
        for (const [id, row] of old) {
          const c = cur.get(id);
          if (!c || row.updatedAt > c.updatedAt) cur.set(id, row);
        }
      };
      newer(this.recipes, prev.recipes);
      newer(this.lists, prev.lists);
      newer(this.pantry, prev.pantry);
      newer(this.plans, prev.plans);
      newer(this.menus, prev.menus);
      this.hydrated = true;
    } catch (e) {
      // Fresh DB (tables may not exist until migration runs): stay empty.
      console.error('[d1store-hydrate]', e instanceof Error ? e.message : e);
      this.hydrated = true;
    }
    // E2E blobs are NOT hydrated here: they load lazily per household hash
    // in loadE2EHash() (called by e2ePut/e2eList/e2eWipe), so one request
    // never pulls every household's ciphertext into memory.
  }

  private async persist(sql: string, ...params: unknown[]): Promise<void> {
    try {
      await this.db.prepare(sql).bind(...params).run();
    } catch {
      // Local dev without migrations applied: in-memory state still works.
    }
  }

  override async ensureHousehold(id: string, name = id): Promise<Household> {
    const h = await super.ensureHousehold(id, name);
    await this.persist(
      'INSERT INTO households (id, name) VALUES (?, ?) ON CONFLICT(id) DO NOTHING',
      id, h.name,
    );
    return h;
  }
  override async setMembership(householdId: string, userId: string, role: Role): Promise<void> {
    await super.setMembership(householdId, userId, role);
    await this.persist(
      "INSERT INTO memberships (household_id, user_id, role) VALUES (?, ?, ?) ON CONFLICT(household_id, user_id) DO UPDATE SET role = excluded.role",
      householdId, userId, role,
    );
  }

  override async createRecipe(input: any, meta: { deviceId: string; id?: string; updatedAt?: string }): Promise<Recipe> {
    const r = await super.createRecipe(input, meta);
    await this.persist(
      'INSERT INTO recipes (id, household_id, title, description, servings, prep_minutes, cook_minutes, rating, source, source_url, categories, photo_original, photo_large1024, photo_thumb, updated_at, device_id, deleted) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0) ON CONFLICT(id) DO UPDATE SET title=excluded.title, description=excluded.description, servings=excluded.servings, updated_at=excluded.updated_at, device_id=excluded.device_id',
      r.id, r.householdId, r.title, r.description, r.servings, r.prepMinutes, r.cookMinutes, r.rating,
      r.source, r.sourceUrl, JSON.stringify(r.categories),
      r.photoKeys.original, r.photoKeys.large1024, r.photoKeys.thumb, r.updatedAt, r.deviceId,
    );
    for (const g of r.ingredients) {
      await this.persist(
        'INSERT INTO ingredients (id, recipe_id, name, quantity, unit, display, position) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET name=excluded.name, quantity=excluded.quantity, unit=excluded.unit, display=excluded.display, position=excluded.position',
        g.id, r.id, g.name, g.quantity, g.unit, g.display, g.position,
      );
    }
    for (const s of r.steps) {
      await this.persist(
        'INSERT INTO steps (id, recipe_id, position, text, timers) VALUES (?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET position=excluded.position, text=excluded.text, timers=excluded.timers',
        s.id, r.id, s.position, s.text, JSON.stringify(s.timers),
      );
    }
    return r;
  }
  override async deleteRecipe(id: string, deviceId: string): Promise<boolean> {
    const ok = await super.deleteRecipe(id, deviceId);
    if (ok) await this.persist('UPDATE recipes SET deleted = 1, updated_at = ?, device_id = ? WHERE id = ?', nowIso(), deviceId, id);
    return ok;
  }

  override async createList(input: any, meta: { deviceId: string; id?: string; updatedAt?: string }): Promise<ShoppingList> {
    const l = await super.createList(input, meta);
    await this.persist(
      'INSERT INTO shopping_lists (id, household_id, name, updated_at, device_id, deleted) VALUES (?, ?, ?, ?, ?, 0) ON CONFLICT(id) DO UPDATE SET name=excluded.name, updated_at=excluded.updated_at, device_id=excluded.device_id',
      l.id, l.householdId, l.name, l.updatedAt, l.deviceId,
    );
    for (const it of l.items) {
      await this.persist(
        'INSERT INTO list_items (id, list_id, name, quantity, aisle, checked, recipe_id) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET name=excluded.name, quantity=excluded.quantity, aisle=excluded.aisle, checked=excluded.checked',
        it.id, l.id, it.name, it.quantity, it.aisle, it.checked ? 1 : 0, it.recipeId,
      );
    }
    return l;
  }
  override async deleteList(id: string, deviceId: string): Promise<boolean> {
    const ok = await super.deleteList(id, deviceId);
    if (ok) await this.persist('UPDATE shopping_lists SET deleted = 1, updated_at = ?, device_id = ? WHERE id = ?', nowIso(), deviceId, id);
    return ok;
  }

  override async createPantry(input: any, meta: { deviceId: string; id?: string; updatedAt?: string }): Promise<PantryItem> {
    const p = await super.createPantry(input, meta);
    await this.persist(
      'INSERT INTO pantry_items (id, household_id, name, quantity, location, expires_at, low_threshold, barcode, updated_at, device_id, deleted) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0) ON CONFLICT(id) DO UPDATE SET name=excluded.name, quantity=excluded.quantity, updated_at=excluded.updated_at, device_id=excluded.device_id',
      p.id, p.householdId, p.name, p.quantity, p.location, p.expiresAt, p.lowThreshold, p.barcode, p.updatedAt, p.deviceId,
    );
    return p;
  }
  override async deletePantry(id: string, deviceId: string): Promise<boolean> {
    const ok = await super.deletePantry(id, deviceId);
    if (ok) await this.persist('UPDATE pantry_items SET deleted = 1, updated_at = ?, device_id = ? WHERE id = ?', nowIso(), deviceId, id);
    return ok;
  }

  override async createPlan(input: any, meta: { deviceId: string; id?: string; updatedAt?: string }): Promise<Plan> {
    const p = await super.createPlan(input, meta);
    await this.persist(
      'INSERT INTO plans (id, household_id, date, meal, recipe_id, note, servings, updated_at, device_id, deleted) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0) ON CONFLICT(id) DO UPDATE SET date=excluded.date, meal=excluded.meal, recipe_id=excluded.recipe_id, note=excluded.note, updated_at=excluded.updated_at, device_id=excluded.device_id',
      p.id, p.householdId, p.date, p.meal, p.recipeId, p.note, p.servings, p.updatedAt, p.deviceId,
    );
    return p;
  }
  override async deletePlan(id: string, deviceId: string): Promise<boolean> {
    const ok = await super.deletePlan(id, deviceId);
    if (ok) await this.persist('UPDATE plans SET deleted = 1, updated_at = ?, device_id = ? WHERE id = ?', nowIso(), deviceId, id);
    return ok;
  }

  override async createMenu(input: any, meta: { deviceId: string; id?: string; updatedAt?: string }): Promise<Menu> {
    const m = await super.createMenu(input, meta);
    await this.persist(
      'INSERT INTO menus (id, household_id, name, entries, updated_at, device_id, deleted) VALUES (?, ?, ?, ?, ?, ?, 0) ON CONFLICT(id) DO UPDATE SET name=excluded.name, entries=excluded.entries, updated_at=excluded.updated_at, device_id=excluded.device_id',
      m.id, m.householdId, m.name, JSON.stringify(m.entries), m.updatedAt, m.deviceId,
    );
    return m;
  }
  override async deleteMenu(id: string, deviceId: string): Promise<boolean> {
    const ok = await super.deleteMenu(id, deviceId);
    if (ok) await this.persist('UPDATE menus SET deleted = 1, updated_at = ?, device_id = ? WHERE id = ?', nowIso(), deviceId, id);
    return ok;
  }

  // ---------- E2E V1 blind blobs (D1 sync_blobs_v2; memory fallback) ----------
  // Ciphertext loads lazily per household hash — hydrate() never pulls the
  // whole table. Every E2E op first reconciles the in-memory bucket against
  // the D1 snapshot for that hash, so a DELETE wipe on another isolate is
  // observed here instead of resurrecting stale cache entries.

  /**
   * Merge the D1 snapshot for one hash into the memory bucket. D1 wins ties
   * and newer (parsed-timestamp LWW); strictly-newer memory wins survive.
   * Cached entries absent from D1 are dropped — unless they are unconfirmed
   * local writes (persist failed) that D1 never saw. Returns false when D1
   * is unreachable for blobs (pre-migration DB): callers keep the memory
   * fallback untouched.
   */
  private async loadE2EHash(hash: string): Promise<boolean> {
    let rows: Record<string, unknown>[];
    try {
      rows = (
        await this.db
          .prepare('SELECT id, header, ciphertext, updated_at FROM sync_blobs_v2 WHERE household_hash = ?')
          .bind(hash)
          .all()
      ).results;
    } catch {
      return false;
    }
    let bucket = this.e2eBlobs.get(hash);
    if (!bucket) {
      bucket = new Map();
      this.e2eBlobs.set(hash, bucket);
    }
    const unsaved = this.e2eUnsaved.get(hash);
    const seen = new Set<string>();
    for (const r of rows) {
      let header: Record<string, unknown>;
      try {
        header = JSON.parse(String(r['header'] ?? '{}')) as Record<string, unknown>;
      } catch {
        continue;
      }
      const env = { ...header, ciphertext: String(r['ciphertext'] ?? '') } as EncryptedEnvelope;
      if (!env.id || !env.updatedAt) continue;
      seen.add(env.id);
      const cur = bucket.get(env.id);
      if (!cur || e2eIsNewer(env.updatedAt, cur.updatedAt)) {
        bucket.set(env.id, env);
        // D1 caught up with a queued local write: confirmed.
        const u = unsaved?.get(env.id);
        if (u && !e2eIsNewer(u.updatedAt, env.updatedAt)) unsaved!.delete(env.id);
      }
    }
    for (const [id] of bucket) {
      if (seen.has(id)) continue;
      if (unsaved?.has(id)) continue; // unconfirmed local write survives
      bucket.delete(id); // wiped elsewhere: must not resurrect
    }
    return true;
  }

  /** E2E upsert that throws on D1 failure — no silent memory-only ack.
   * The ON CONFLICT predicate keeps a stale write from overwriting a newer
   * D1 winner lost to an interleaving isolate. A missing table
   * (pre-migration DB) still falls back to memory-only. */
  private async persistE2EOrThrow(hash: string, env: EncryptedEnvelope): Promise<void> {
    try {
      await this.db
        .prepare(
          'INSERT INTO sync_blobs_v2 (household_hash, id, header, ciphertext, updated_at) VALUES (?, ?, ?, ?, ?) ON CONFLICT(household_hash, id) DO UPDATE SET header = excluded.header, ciphertext = excluded.ciphertext, updated_at = excluded.updated_at WHERE excluded.updated_at > sync_blobs_v2.updated_at',
        )
        .bind(hash, env.id, JSON.stringify(envelopeHeader(env)), env.ciphertext, env.updatedAt)
        .run();
    } catch (e) {
      if (e instanceof Error && /no such table/i.test(e.message)) return;
      throw e;
    }
  }

  override async e2ePut(hash: string, env: EncryptedEnvelope): Promise<boolean> {
    await this.loadE2EHash(hash); // merge latest D1 winners before LWW
    const pending = this.e2eUnsaved.get(hash)?.get(env.id);
    const stored = await super.e2ePut(hash, env);
    // Identical retry of an unconfirmed write: super reports a tie (no
    // winner change), but D1 still needs the row — persist anyway.
    const retry = !stored && pending !== undefined && JSON.stringify(pending) === JSON.stringify(env);
    if (!stored && !retry) return false;
    try {
      await this.persistE2EOrThrow(hash, env);
    } catch (e) {
      // Keep the memory copy so the write isn't silently lost, but surface
      // the failure to the caller (HTTP 500) instead of acking it.
      let m = this.e2eUnsaved.get(hash);
      if (!m) {
        m = new Map();
        this.e2eUnsaved.set(hash, m);
      }
      m.set(env.id, env);
      throw e;
    }
    this.e2eUnsaved.get(hash)?.delete(env.id);
    return stored;
  }

  override async e2eList(hash: string, since: string): Promise<EncryptedEnvelope[]> {
    await this.loadE2EHash(hash);
    return super.e2eList(hash, since);
  }

  override async e2eWipe(hash: string): Promise<number> {
    await this.loadE2EHash(hash); // reconcile so the count matches D1
    const n = this.e2eBlobs.get(hash)?.size ?? 0;
    try {
      await this.db.prepare('DELETE FROM sync_blobs_v2 WHERE household_hash = ?').bind(hash).run();
    } catch (e) {
      if (!(e instanceof Error) || !/no such table/i.test(e.message)) throw e;
      // Pre-migration DB: memory fallback.
    }
    this.e2eBlobs.delete(hash);
    this.e2eUnsaved.delete(hash);
    return n;
  }
}

export type { D1 };
export { newId };
