import { describe, expect, it, beforeEach } from 'vitest';
import { lwwMerge, mergeInto, visible, Store, type SyncEnvelope } from './store';

// Minimal localStorage stub for the node test env (app runs in browsers).
if (typeof localStorage === 'undefined') {
  const mem = new Map<string, string>();
  (globalThis as Record<string, unknown>).localStorage = {
    getItem: (k: string) => (mem.has(k) ? mem.get(k)! : null),
    setItem: (k: string, v: string) => void mem.set(k, String(v)),
    removeItem: (k: string) => void mem.delete(k),
    clear: () => mem.clear(),
  };
}

function env(id: string, updatedAt: string, title: string, deleted = false): SyncEnvelope {
  return { id, updatedAt, deviceId: 'test', entity: 'recipe', deleted, payload: { title } };
}

describe('lwwMerge', () => {
  it('newer wins', () => {
    const a = env('x', '2026-01-01T00:00:00.000Z', 'old');
    const b = env('x', '2026-01-02T00:00:00.000Z', 'new');
    expect(lwwMerge(a, b).payload).toEqual({ title: 'new' });
    expect(lwwMerge(b, a).payload).toEqual({ title: 'new' });
  });

  it('ties keep stored (idempotent replay)', () => {
    const a = env('x', '2026-01-01T00:00:00.000Z', 'stored');
    const b = env('x', '2026-01-01T00:00:00.000Z', 'replay');
    expect(lwwMerge(a, b).payload).toEqual({ title: 'stored' });
  });

  it('tombstones merge like any envelope', () => {
    const live = env('x', '2026-01-01T00:00:00.000Z', 'live');
    const tomb = env('x', '2026-01-02T00:00:00.000Z', 'live', true);
    const merged = mergeInto([live], tomb);
    expect(merged[0].deleted).toBe(true);
    expect(visible(merged)).toHaveLength(0);
  });
});

describe('outbox converge (airplane-mode edit)', () => {
  beforeEach(() => localStorage.clear());

  it('queues offline edits and converges on replay', () => {
    const store = new Store();
    store.clearAll();
    // Airplane mode: edit while offline.
    const local = store.upsert('recipe', 'r1', { title: 'Local edit' });
    expect(store.state.outbox).toHaveLength(1);
    // Server had a stale copy; remote applies LWW.
    store.applyRemote(env('r1', '2020-01-01T00:00:00.000Z', 'Stale server'));
    const found = store.state.recipes.find((e) => e.id === 'r1');
    expect((found?.payload as { title: string }).title).toBe('Local edit');
    // Push succeeds later; outbox drains; replay of same envelope is a no-op.
    store.drainOutbox([local.id]);
    expect(store.state.outbox).toHaveLength(0);
    store.applyRemote({ ...local });
    expect(store.state.recipes.find((e) => e.id === 'r1')?.payload).toEqual({ title: 'Local edit' });
  });
});
