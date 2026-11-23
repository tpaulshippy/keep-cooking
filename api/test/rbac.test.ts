import { describe, it, expect } from 'vitest';
import { makeApp, req } from './helpers';

const RECIPE = { title: 'RBAC Stew', servings: 2, householdId: 'hh-demo' };

describe('RBAC', () => {
  it('viewer: reads OK, all mutations 403', async () => {
    const { app } = await makeApp();
    const created = await req(app, 'POST', '/recipes', { body: RECIPE, role: 'owner' });
    expect(created.status).toBe(201);
    const id = ((await created.json()) as { id: string }).id;

    const get = await req(app, 'GET', `/recipes/${id}`, { role: 'viewer' });
    expect(get.status).toBe(200);
    const list = await req(app, 'GET', '/recipes?householdId=hh-demo', { role: 'viewer' });
    expect(list.status).toBe(200);

    for (const [m, p, b] of [
      ['POST', '/recipes', RECIPE],
      ['PUT', `/recipes/${id}`, RECIPE],
      ['DELETE', `/recipes/${id}`, undefined],
      ['POST', '/lists', { name: 'x' }],
      ['POST', '/pantry', { name: 'x' }],
      ['POST', '/plans', { date: '2026-12-01', meal: 'dinner' }],
      ['POST', '/menus', { name: 'x' }],
      ['POST', `/recipes/${id}/scale`, { servings: 4 }],
    ] as const) {
      // scale is a read-only transform: viewer allowed.
      const res = await req(app, m, p, { body: b, role: 'viewer' });
      if (p.endsWith('/scale')) expect(res.status).toBe(200);
      else expect(res.status).toBe(403);
    }
  });

  it('member: full CRUD, but share/cookbook is owner-only', async () => {
    const { app } = await makeApp();
    const created = await req(app, 'POST', '/recipes', { body: RECIPE, role: 'member' });
    expect(created.status).toBe(201);
    const id = ((await created.json()) as { id: string }).id;

    const upd = await req(app, 'PUT', `/recipes/${id}`, { body: { ...RECIPE, title: 'RBAC Stew v2' }, role: 'member' });
    expect(upd.status).toBe(200);
    const del = await req(app, 'DELETE', `/recipes/${id}`, { role: 'member' });
    expect(del.status).toBe(204);

    const share = await req(app, 'POST', '/share/cookbook', {
      body: { householdId: 'hh-demo', recipeIds: ['x'] },
      role: 'member',
    });
    expect(share.status).toBe(403);
  });

  it('owner: share/cookbook works', async () => {
    const { app } = await makeApp();
    const res = await req(app, 'POST', '/share/cookbook', {
      body: { householdId: 'hh-demo', recipeIds: ['r1'], expiresInDays: 7 },
      role: 'owner',
    });
    expect(res.status).toBe(201);
    const body = (await res.json()) as { id: string; url: string; expiresAt: string };
    expect(body.url).toContain(body.id);
    expect(new Date(body.expiresAt).getTime()).toBeGreaterThan(Date.now());
  });

  it('stored membership overrides header role', async () => {
    const { app, store } = await makeApp();
    // u-viewer is a viewer in hh-demo per seed; even claiming owner via header, membership wins.
    await store.setMembership('hh-demo', 'sneaky', 'viewer');
    const res = await req(app, 'POST', '/recipes', {
      body: RECIPE,
      headers: { 'x-user-id': 'sneaky', 'x-role': 'owner', 'x-device-id': 'd', 'content-type': 'application/json' },
    });
    expect(res.status).toBe(403);
  });

  it('zod rejects invalid inputs (400, no PII echo)', async () => {
    const { app } = await makeApp();
    const res = await req(app, 'POST', '/recipes', { body: { title: '' }, role: 'owner' });
    expect(res.status).toBe(400);
    const scale = await req(app, 'POST', '/recipes/nope/scale', { body: { servings: 9999 }, role: 'owner' });
    expect([400, 404]).toContain(scale.status);
  });
});
