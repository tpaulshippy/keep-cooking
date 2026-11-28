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

function env(id: string, updatedAt: string, title: string, deleted = false, deviceId = 'test'): SyncEnvelope {
  return { id, updatedAt, deviceId, entity: 'recipe', deleted, payload: { title } };
}

describe('lwwMerge', () => {
  it('newer wins', () => {
    const a = env('x', '2026-01-01T00:00:00.000Z', 'old');
    const b = env('x', '2026-01-02T00:00:00.000Z', 'new');
    expect(lwwMerge(a, b).payload).toEqual({ title: 'new' });
    expect(lwwMerge(b, a).payload).toEqual({ title: 'new' });
  });

  it('tie takes incoming (remote-wins, matches native SyncEngine)', () => {
    const stored = env('x', '2026-01-01T00:00:00.000Z', 'stored', false, 'device-a');
    const remote = env('x', '2026-01-01T00:00:00.000Z', 'remote', false, 'device-b');
    expect(lwwMerge(stored, remote).payload).toEqual({ title: 'remote' });
  });

  it('identical same-device replay is a no-op', () => {
    const a = env('x', '2026-01-01T00:00:00.000Z', 'same', false, 'device-a');
    const b = env('x', '2026-01-01T00:00:00.000Z', 'same-changed', false, 'device-a');
    expect(lwwMerge(a, b)).toBe(a);
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
    // Push succeeds later; outbox drains by identity; replay is a no-op.
    store.drainOutbox([{ id: local.id, updatedAt: local.updatedAt }]);
    expect(store.state.outbox).toHaveLength(0);
    store.applyRemote({ ...local });
    expect(store.state.recipes.find((e) => e.id === 'r1')?.payload).toEqual({ title: 'Local edit' });
  });

  it('tie converges to remote (airplane-mode both edited)', () => {
    const store = new Store();
    store.clearAll();
    const t = '2026-03-01T12:00:00.000Z';
    store.state.recipes = [env('r1', t, 'Local title', false, 'device-local')];
    store.applyRemote(env('r1', t, 'Server title', false, 'device-server'));
    const got = store.state.recipes.find((e) => e.id === 'r1')?.payload as { title: string };
    expect(got.title).toBe('Server title');
  });
});

describe('drainOutbox identity', () => {
  beforeEach(() => localStorage.clear());

  it('acks by (id, updatedAt): a newer unsent edit survives', () => {
    const store = new Store();
    store.clearAll();
    store.upsert('recipe', 'r1', { title: 'v1' });
    store.upsert('recipe', 'r1', { title: 'v2' });
    // Force distinct timestamps for determinism (same-ms upserts are legal).
    store.state.outbox[0] = { ...store.state.outbox[0], updatedAt: '2026-01-01T00:00:00.000Z' };
    store.state.outbox[1] = { ...store.state.outbox[1], updatedAt: '2026-01-02T00:00:00.000Z' };
    const drained = store.drainOutbox([{ id: 'r1', updatedAt: '2026-01-01T00:00:00.000Z' }]);
    expect(drained).toHaveLength(1);
    expect(store.state.outbox.map((e) => e.updatedAt)).toEqual(['2026-01-02T00:00:00.000Z']);
    expect(store.state.outbox[0].payload).toEqual({ title: 'v2' });
  });
});

describe('reconcileLocalId', () => {
  beforeEach(() => localStorage.clear());

  it('replaces the local id with the server record, rewrites pending outbox ids', () => {
    const store = new Store();
    store.clearAll();
    const local = store.upsert('recipe', 'local-id', { title: 'Draft' });
    const later = store.upsert('recipe', 'local-id', { title: 'Draft v2' });
    void later;
    store.reconcileLocalId('local-id', {
      id: 'server-id',
      updatedAt: '2026-04-01T00:00:00.000Z',
      deviceId: 'web',
      entity: 'recipe',
      payload: { title: 'Draft v2' },
    });
    expect(store.state.recipes.map((e) => e.id)).toEqual(['server-id']);
    expect(store.state.outbox.every((e) => e.id === 'server-id')).toBe(true);
    expect(local.id).toBe('local-id'); // original envelope untouched
  });
});
