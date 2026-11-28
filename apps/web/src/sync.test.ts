import { describe, expect, it, beforeEach } from 'vitest';
import { Store } from './store';
import { pushOutbox, toRecordInput, type PushTransport, type ServerRecord } from './sync';

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

describe('pushOutbox', () => {
  beforeEach(() => localStorage.clear());

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
});
