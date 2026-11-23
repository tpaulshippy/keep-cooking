import { describe, it, expect } from 'vitest';
import { makeApp, req } from './helpers';

describe('sync tombstones + LWW', () => {
  it('push then pull roundtrip', async () => {
    const { app } = await makeApp({ seed: false });
    const env = {
      id: '11111111-1111-4111-8111-111111111111',
      updatedAt: '2026-11-20T12:00:00Z',
      deviceId: 'iphone-17-a',
      deleted: false,
      entity: 'recipe',
      payload: { title: 'Sync Soup', servings: 2, householdId: 'hh-demo', ingredients: [], steps: [] },
    };
    const push = await req(app, 'POST', '/sync/push', { body: [env] });
    expect(push.status).toBe(200);
    expect(await push.json()).toEqual([]);

    const pull = await app.request('/sync/pull?since=1970-01-01T00:00:00Z', { headers: { 'x-role': 'owner' } });
    expect(pull.status).toBe(200);
    const envs = (await pull.json()) as { id: string }[];
    expect(envs.some((e) => e.id === env.id)).toBe(true);
  });

  it('deleted=true tombstone propagates on pull, hides from lists', async () => {
    const { app } = await makeApp({ seed: false });
    const id = '22222222-2222-4222-8222-222222222222';
    await req(app, 'POST', '/sync/push', {
      body: [{ id, updatedAt: '2026-11-20T12:00:00Z', deviceId: 'a', deleted: false, entity: 'recipe', payload: { title: 'Doomed', householdId: 'hh-demo' } }],
    });
    await req(app, 'POST', '/sync/push', {
      body: [{ id, updatedAt: '2026-11-21T12:00:00Z', deviceId: 'a', deleted: true, entity: 'recipe', payload: {} }],
    });
    const list = await req(app, 'GET', '/recipes?householdId=hh-demo');
    const recipes = (await list.json()) as { id: string }[];
    expect(recipes.some((r) => r.id === id)).toBe(false);

    const pull = await app.request('/sync/pull?since=2026-11-20T13:00:00Z', { headers: { 'x-role': 'owner' } });
    const envs = (await pull.json()) as { id: string; deleted: boolean }[];
    const tomb = envs.find((e) => e.id === id);
    expect(tomb?.deleted).toBe(true);
  });

  it('server-won conflict returned when incoming is older', async () => {
    const { app } = await makeApp({ seed: false });
    const id = '33333333-3333-4333-8333-333333333333';
    await req(app, 'POST', '/sync/push', {
      body: [{ id, updatedAt: '2026-11-22T12:00:00Z', deviceId: 'server', deleted: false, entity: 'pantryItem', payload: { name: 'Flour', householdId: 'hh-demo' } }],
    });
    const stale = await req(app, 'POST', '/sync/push', {
      body: [{ id, updatedAt: '2026-11-20T12:00:00Z', deviceId: 'old-phone', deleted: false, entity: 'pantryItem', payload: { name: 'Stale Flour', householdId: 'hh-demo' } }],
    });
    expect(stale.status).toBe(200);
    const conflicts = (await stale.json()) as { payload: { name: string } }[];
    expect(conflicts).toHaveLength(1);
    expect(conflicts[0]!.payload.name).toBe('Flour');
  });

  it('equal timestamps are idempotent (no conflict)', async () => {
    const { app } = await makeApp({ seed: false });
    const env = {
      id: '44444444-4444-4444-8444-444444444444',
      updatedAt: '2026-11-20T12:00:00Z', deviceId: 'a', deleted: false,
      entity: 'list', payload: { name: 'Weekly', householdId: 'hh-demo', items: [] },
    };
    await req(app, 'POST', '/sync/push', { body: [env] });
    const again = await req(app, 'POST', '/sync/push', { body: [env] });
    expect(await again.json()).toEqual([]);
  });

  it('since filter only returns newer envelopes', async () => {
    const { app } = await makeApp({ seed: false });
    await req(app, 'POST', '/sync/push', {
      body: [
        { id: '55555555-5555-4555-8555-555555555555', updatedAt: '2026-11-20T12:00:00Z', deviceId: 'a', deleted: false, entity: 'plan', payload: { date: '2026-12-01', meal: 'dinner', householdId: 'hh-demo' } },
        { id: '66666666-6666-4666-8666-666666666666', updatedAt: '2026-11-25T12:00:00Z', deviceId: 'a', deleted: false, entity: 'plan', payload: { date: '2026-12-02', meal: 'lunch', householdId: 'hh-demo' } },
      ],
    });
    const pull = await app.request('/sync/pull?since=2026-11-22T00:00:00Z', { headers: { 'x-role': 'owner' } });
    const envs = (await pull.json()) as { id: string }[];
    expect(envs.map((e) => e.id)).toEqual(['66666666-6666-4666-8666-666666666666']);
  });
});
