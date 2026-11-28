import { describe, expect, it, beforeEach } from 'vitest';
import { Store } from './store';
import type { EntityKind } from './store';
import { pushOutbox, toRecordInput, contentSignature, type PushTransport, type ServerRecord } from './sync';

if (typeof localStorage === 'undefined') {
  const mem = new Map<string, string>();
  (globalThis as Record<string, unknown>).localStorage = {
    getItem: (k: string) => (mem.has(k) ? mem.get(k)! : null),
    setItem: (k: string, v: string) => void mem.set(k, String(v)),
    removeItem: (k: string) => void mem.delete(k),
    clear: () => mem.clear(),
  };
}

const notFound = (what: string) => new Error(`PUT ${what} failed: 404`);
const offline = () => new Error('PUT /x failed: 500');

function scripted(impl: Partial<PushTransport>): PushTransport {
  return {
    update: () => { throw offline(); },
    create: () => { throw offline(); },
    remove: async () => {},
    list: async () => [],
    ...impl,
  };
}

describe('toRecordInput', () => {
  it('strips envelope metadata pulled payloads carry', () => {
    expect(toRecordInput({ id: 'a', updatedAt: 't', deviceId: 'd', deleted: false, entity: 'recipe', title: 'T' }))
      .toEqual({ title: 'T' });
    expect(toRecordInput(null)).toEqual({});
  });
});

describe('contentSignature', () => {
  it('scopes every entity to householdId: same content in another household must not match', () => {
    const cases: [EntityKind, Record<string, unknown>][] = [
      ['recipe', { title: 'T', servings: 4, ingredients: [{ name: 'Egg' }], steps: ['stir'] }],
      ['list', { name: 'N', items: [{ name: 'Milk' }] }],
      ['pantryItem', { name: 'Flour', quantity: '1', location: 'Shelf' }],
      ['plan', { date: '2026-01-01', meal: 'dinner', recipeId: 'r' }],
      ['menu', { name: 'M', entries: [{ dayOffset: 0, meal: 'dinner', recipeId: 'r' }] }],
    ];
    for (const [entity, input] of cases) {
      const a = contentSignature(entity, { ...input, householdId: 'hh-personal' });
      const b = contentSignature(entity, { ...input, householdId: 'hh-shared' });
      expect(a, entity).not.toBe(b);
      expect(contentSignature(entity, { ...input, householdId: 'hh-personal' }), entity).toBe(a);
    }
  });

  it('covers full schema metadata: differing description/timings/source/positions must not match', () => {
    const base = {
      title: 'Soup', servings: 4, householdId: 'hh-demo',
      ingredients: [{ name: 'Salt', quantity: 1, unit: 'tsp', display: '1 tsp Salt', position: 0 }],
      steps: [{ position: 0, text: 'Stir.' }],
    };
    const sig = contentSignature('recipe', base);
    const variants: Record<string, unknown>[] = [
      { ...base, description: 'weeknight' },
      { ...base, prepMinutes: 10 },
      { ...base, cookMinutes: 20 },
      { ...base, rating: 5 },
      { ...base, source: 'book' },
      { ...base, sourceUrl: 'https://x.test/r' },
      { ...base, categories: ['Dinner'] },
      { ...base, photoKeys: { thumb: 'photos/x/thumb.jpg' } },
      { ...base, ingredients: [{ name: 'Salt', quantity: 1, unit: 'tsp', display: '1 tsp Salt', position: 1 }] },
      { ...base, steps: [{ position: 1, text: 'Stir.' }] },
    ];
    for (const v of variants) expect(contentSignature('recipe', v)).not.toBe(sig);
    expect(contentSignature('recipe', { ...base })).toBe(sig);
    // List checked/recipeId + pantry expiry metadata are covered too.
    expect(contentSignature('list', { name: 'N', householdId: 'h', items: [{ name: 'M', checked: true }] }))
      .not.toBe(contentSignature('list', { name: 'N', householdId: 'h', items: [{ name: 'M' }] }));
    expect(contentSignature('pantryItem', { name: 'F', householdId: 'h', expiresAt: '2026-02-01' }))
      .not.toBe(contentSignature('pantryItem', { name: 'F', householdId: 'h' }));
  });
});

describe('pushOutbox', () => {
  beforeEach(() => localStorage.clear());

  it('does not adopt a same-content record from a different household', async () => {
    const store = new Store();
    store.clearAll();
    const local = store.upsert('recipe', 'local-draft', { title: 'Shared', servings: 4, householdId: 'hh-personal' });
    let creates = 0;
    const transport = scripted({
      update: async () => { throw notFound('recipes/local-draft'); },
      // Same device, byte-identical content — but it belongs to the shared
      // household, so it must not be adopted for the personal-household draft.
      list: async () => [{
        id: 'srv-shared', updatedAt: '2026-05-02T00:00:00.000Z', deviceId: local.deviceId,
        title: 'Shared', servings: 4, householdId: 'hh-shared',
      }],
      create: async (_e, input): Promise<ServerRecord> => {
        creates++;
        return { id: 'srv-new', updatedAt: '2026-05-03T00:00:00.000Z', ...(input as object) };
      },
    });
    const result = await pushOutbox(store, transport);
    expect(result).toEqual({ pushed: 1, failed: false });
    expect(creates).toBe(1); // an adoption would create nothing
    expect(store.state.recipes.map((e) => e.id)).toEqual(['srv-new']);
    expect(store.state.outbox).toHaveLength(0);
  });

  it('only drains envelopes whose mutation succeeded (mixed outbox)', async () => {
    const store = new Store();
    store.clearAll();
    store.upsert('recipe', 'r-ok', { title: 'Fine' });
    const localList = store.upsert('list', 'local-list', { name: 'Shop' });
    void localList;
    store.upsert('plan', 'p-bad', { date: '2026-01-05', meal: 'dinner' });
    const doomed = store.upsert('recipe', 'r-doomed', { title: 'Never sent' });
    void doomed;

    const transport = scripted({
      update: async (entity, id, input) => {
        if (entity === 'recipe' && id === 'r-ok') {
          return { id, updatedAt: '2026-05-01T00:00:00.000Z', ...(input as object) };
        }
        if (entity === 'plan') throw offline();
        throw notFound(`${entity}/${id}`);
      },
      create: async (entity, input) => {
        if (entity === 'list') {
          return { id: 'server-list', updatedAt: '2026-05-01T00:00:00.000Z', ...(input as object) };
        }
        throw offline();
      },
    });

    const result = await pushOutbox(store, transport);
    expect(result).toEqual({ pushed: 2, failed: true });
    // Recipe updated + list created/reconciled: acked. Plan + doomed: retained.
    expect(store.state.outbox.map((e) => e.id).sort()).toEqual(['p-bad', 'r-doomed']);
    // Reconcile: no local duplicate, pending revisions rewritten to server id.
    expect(store.state.lists.map((e) => e.id)).toEqual(['server-list']);
    expect(store.state.lists[0].payload).toMatchObject({ name: 'Shop' });
  });

  it('delete-404 counts as success; tombstone still merges', async () => {
    const store = new Store();
    store.clearAll();
    store.upsert('menu', 'm-gone', { name: 'Old' });
    store.remove('menu', 'm-gone');
    // Simulate an already-acked create: only the tombstone is queued.
    store.state.outbox = store.state.outbox.filter((e) => e.deleted);
    const seen: string[] = [];
    const transport = scripted({
      remove: async (entity, id) => {
        seen.push(`${entity}/${id}`);
        throw notFound(`${entity}/${id}`);
      },
    });
    const result = await pushOutbox(store, transport);
    expect(result).toEqual({ pushed: 1, failed: false });
    expect(seen).toContain('menu/m-gone');
    expect(store.state.outbox).toHaveLength(0);
    expect(store.state.menus[0].deleted).toBe(true);
  });

  it('update-404 falls back to create and reconciles the server id', async () => {
    const store = new Store();
    store.clearAll();
    store.upsert('recipe', 'local-draft', { title: 'Clipped' });
    const transport = scripted({
      update: async () => { throw notFound('recipes/local-draft'); },
      create: async (_e, input): Promise<ServerRecord> => ({
        id: 'srv-1', updatedAt: '2026-05-02T00:00:00.000Z', ...(input as object),
      }),
    });
    const result = await pushOutbox(store, transport);
    expect(result).toEqual({ pushed: 1, failed: false });
    expect(store.state.recipes.map((e) => e.id)).toEqual(['srv-1']);
    expect(store.state.outbox).toHaveLength(0);
  });

  it('adopts a committed-but-unacked create on retry instead of duplicating', async () => {
    const store = new Store();
    store.clearAll();
    const local = store.upsert('recipe', 'local-draft', { title: 'Clipped', servings: 4 });
    // Server side of the fake: the first create commits, but its response is
    // lost (throw) — the retry must adopt it, not create a second record.
    const committed: ServerRecord[] = [];
    let creates = 0;
    const transport = scripted({
      update: async () => { throw notFound('recipes/local-draft'); },
      create: async (_e, input): Promise<ServerRecord> => {
        creates++;
        if (creates === 1) {
          committed.push({ id: 'srv-1', updatedAt: '2026-05-02T00:00:00.000Z', deviceId: local.deviceId, ...(input as object) });
          throw new Error('socket hang up (response lost after commit)');
        }
        throw new Error('must not create twice');
      },
      list: async () => [...committed],
    });
    expect(await pushOutbox(store, transport)).toEqual({ pushed: 0, failed: true });
    expect(creates).toBe(1);
    expect(await pushOutbox(store, transport)).toEqual({ pushed: 1, failed: false });
    expect(creates).toBe(1); // no second create
    expect(store.state.recipes.map((e) => e.id)).toEqual(['srv-1']);
    expect(store.state.outbox).toHaveLength(0);
  });

  it('refuses to adopt on ambiguous matches (creates instead of wrong-merge)', async () => {
    const store = new Store();
    store.clearAll();
    const local = store.upsert('recipe', 'local-draft', { title: 'Same', servings: 4 });
    const mk = (id: string): ServerRecord => ({ id, updatedAt: '2026-05-02T00:00:00.000Z', deviceId: local.deviceId, title: 'Same', servings: 4 });
    const transport = scripted({
      update: async () => { throw notFound('recipes/local-draft'); },
      list: async () => [mk('srv-a'), mk('srv-b')], // two identical: ambiguous
      create: async (_e, input): Promise<ServerRecord> => ({ id: 'srv-new', ...(input as object) }),
    });
    expect(await pushOutbox(store, transport)).toEqual({ pushed: 1, failed: false });
    expect(store.state.recipes.map((e) => e.id)).toEqual(['srv-new']);
  });

  it('does not collapse two intentional same-content drafts into one', async () => {
    const store = new Store();
    store.clearAll();
    const d1 = store.upsert('recipe', 'draft-1', { title: 'Same', servings: 4 });
    store.upsert('recipe', 'draft-2', { title: 'Same', servings: 4 });
    const transport = scripted({
      update: async () => { throw notFound('x'); },
      // Even though a matching server record exists, two local peers make it
      // ambiguous: both drafts must create their own records.
      list: async () => [{ id: 'srv-1', deviceId: d1.deviceId, title: 'Same', servings: 4 }],
      create: async (_e, input): Promise<ServerRecord> => ({
        id: `srv-${Math.random().toString(36).slice(2)}`, ...(input as object),
      }),
    });
    const result = await pushOutbox(store, transport);
    expect(result.failed).toBe(false);
    expect(store.state.recipes).toHaveLength(2);
    expect(new Set(store.state.recipes.map((e) => e.id)).size).toBe(2);
  });

  it('pushes both revisions of a twice-edited offline record in one run', async () => {
    const store = new Store();
    store.clearAll();
    store.upsert('recipe', 'local-draft', { title: 'v1' });
    store.state.outbox[0] = { ...store.state.outbox[0], updatedAt: '2026-05-01T00:00:00.000Z' };
    store.upsert('recipe', 'local-draft', { title: 'v2' });
    store.state.outbox[1] = { ...store.state.outbox[1], updatedAt: '2026-05-02T00:00:00.000Z' };
    const updates: { id: string; title: unknown }[] = [];
    let creates = 0;
    let clock = 3;
    const stamp = () => `2026-05-0${clock++}T00:00:00.000Z`;
    const transport = scripted({
      update: async (entity, id, input) => {
        if (id === 'local-draft') throw notFound('recipes/local-draft');
        updates.push({ id, title: (input as Record<string, unknown>).title });
        return { id, updatedAt: stamp(), ...(input as object) };
      },
      create: async (_e, input): Promise<ServerRecord> => {
        creates++;
        return { id: 'srv-1', updatedAt: stamp(), ...(input as object) };
      },
    });
    const result = await pushOutbox(store, transport);
    expect(result).toEqual({ pushed: 2, failed: false });
    expect(creates).toBe(1);
    // The rewritten second revision updates the adopted server id in-run.
    expect(updates).toEqual([{ id: 'srv-1', title: 'v2' }]);
    expect(store.state.outbox).toHaveLength(0);
    expect((store.state.recipes[0].payload as { title: string }).title).toBe('v2');
  });

  it('offline-created-then-deleted never resurrects: create skipped, tombstone kept', async () => {
    const store = new Store();
    store.clearAll();
    store.upsert('recipe', 'local-draft', { title: 'Clipped' });
    store.remove('recipe', 'local-draft');
    // Distinct timestamps so both envelopes are processed separately
    // (same-ms create+tombstone would share one identity and drain together).
    store.state.outbox[0] = { ...store.state.outbox[0], updatedAt: '2026-05-01T00:00:00.000Z' };
    store.state.outbox[1] = { ...store.state.outbox[1], updatedAt: '2026-05-02T00:00:00.000Z' };
    const creates: string[] = [];
    const removes: string[] = [];
    const transport = scripted({
      update: async () => { throw notFound('recipes/local-draft'); },
      create: async () => {
        creates.push('create');
        return { id: 'srv-nope' };
      },
      remove: async (entity, id) => {
        removes.push(`${entity}/${id}`);
      },
    });
    const result = await pushOutbox(store, transport);
    expect(result).toEqual({ pushed: 2, failed: false });
    expect(creates).toEqual([]); // create never attempted
    expect(removes).toEqual(['recipe/local-draft']); // tombstone still sent
    expect(store.state.recipes).toHaveLength(1);
    expect(store.state.recipes[0].deleted).toBe(true); // tombstone preserved
    expect(store.state.outbox).toHaveLength(0);
  });

  it('preserves a newer queued revision when an earlier update echo arrives', async () => {
    const store = new Store();
    store.clearAll();
    store.upsert('recipe', 'r1', { title: 'v1' });
    store.upsert('recipe', 'r1', { title: 'v2' });
    store.state.outbox[0] = { ...store.state.outbox[0], updatedAt: '2026-05-01T00:00:00.000Z' };
    store.state.outbox[1] = { ...store.state.outbox[1], updatedAt: '2026-05-02T00:00:00.000Z' };
    store.state.recipes = [{ ...store.state.recipes[0], updatedAt: '2026-05-02T00:00:00.000Z' }];
    const sent: unknown[] = [];
    const transport = scripted({
      update: async (_e, _id, input) => {
        sent.push((input as Record<string, unknown>).title);
        if (sent.length === 1) {
          // Fresh server timestamp: merging this echo via LWW would clobber
          // the still-queued v2 content in the collection.
          return { id: 'r1', updatedAt: '2026-05-03T00:00:00.000Z', ...(input as object) };
        }
        throw offline();
      },
    });
    const result = await pushOutbox(store, transport);
    expect(result).toEqual({ pushed: 1, failed: true });
    expect(sent).toEqual(['v1', 'v2']); // the retry sends v2's content, not the v1 echo
    // v1 acked, v2 retained — and the collection still shows the v2 edit,
    // not the v1 echo.
    expect(store.state.outbox.map((e) => e.updatedAt)).toEqual(['2026-05-02T00:00:00.000Z']);
    expect((store.state.recipes[0].payload as { title: string }).title).toBe('v2');
  });

  it('honors a remote deletion instead of recreating an offline edit', async () => {
    const store = new Store();
    store.clearAll();
    // Record previously pulled from the server, then edited offline.
    store.applyRemote({
      id: 'srv-1', updatedAt: '2026-04-01T00:00:00.000Z', deviceId: 'other-device',
      entity: 'recipe', payload: { title: 'Shared' },
    });
    store.upsert('recipe', 'srv-1', { title: 'My offline edit' });
    let creates = 0;
    const transport = scripted({
      update: async () => { throw notFound('recipes/srv-1'); },
      list: async () => [], // server no longer has it: deleted on another device
      create: async (): Promise<ServerRecord> => {
        creates++;
        return { id: 'srv-resurrected' };
      },
    });
    const result = await pushOutbox(store, transport);
    expect(result).toEqual({ pushed: 1, failed: false });
    expect(creates).toBe(0); // must not resurrect the remote deletion
    expect(store.state.outbox).toHaveLength(0);
    // Tombstone: filtered from views, but the envelope still LWW-merges.
    expect(store.state.recipes).toHaveLength(1);
    expect(store.state.recipes[0].deleted).toBe(true);
  });

  it('joins an in-flight push instead of processing the queue twice', async () => {
    const store = new Store();
    store.clearAll();
    store.upsert('recipe', 'r1', { title: 'Hi' });
    let calls = 0;
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const transport = scripted({
      update: async (_e, id, input) => {
        calls++;
        await gate; // hold the first push open so the second call overlaps it
        return { id, updatedAt: '2026-05-03T00:00:00.000Z', ...(input as object) };
      },
    });
    const first = pushOutbox(store, transport);
    const second = pushOutbox(store, transport);
    release();
    const [r1, r2] = await Promise.all([first, second]);
    expect(calls).toBe(1); // no double-processing, so no duplicate records
    expect(r1).toEqual({ pushed: 1, failed: false });
    expect(r2).toEqual(r1);
    expect(store.state.outbox).toHaveLength(0);
    // Guard released: a later push runs fresh.
    store.upsert('recipe', 'r1', { title: 'Hi again' });
    await expect(pushOutbox(store, transport)).resolves.toEqual({ pushed: 1, failed: false });
    expect(calls).toBe(2);
  });
});
