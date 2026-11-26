import { describe, it, expect } from 'vitest';
import { createApp } from '../src/index';
import { MemoryStore } from '../src/store';

// The app works out of the box: no token enrollment on any route.
// E2E household buckets stay blind via unguessable hashes; v1 routes still
// enforce household RBAC (viewer read-only, member/owner write).

function prodApp() {
  const store = new MemoryStore();
  const app = createApp(store, {
    baseUrl: 'https://keep-cooking-api.pshippy-245.workers.dev',
    secret: 'test-secret',
  });
  return { app, store };
}

function devApp() {
  const store = new MemoryStore();
  const app = createApp(store, { baseUrl: 'https://api.keepcooking.local', secret: 'test-secret' });
  return { app, store };
}

describe('open access (no token enrollment)', () => {
  it('/health stays unauthenticated', async () => {
    const { app } = prodApp();
    const res = await app.request('/health', { method: 'GET' });
    expect(res.status).toBe(200);
  });

  it('prod allows non-health routes without any bearer token', async () => {
    const { app, store } = prodApp();
    for (const [m, p] of [
      ['GET', '/recipes'],
      ['GET', '/sync/pull?since=1970-01-01T00:00:00Z'],
      ['GET', '/openapi.json'],
    ] as const) {
      const res = await app.request(p, {
        method: m,
        headers: { 'x-user-id': 'u1', 'x-role': 'owner' },
      });
      expect(res.status).toBe(200);
    }
    // Writes still enforce household RBAC: seed an owner membership, then
    // write with no bearer at all (the app's out-of-box path).
    await store.setMembership('hh-demo', 'u1', 'owner');
    const write = await app.request('/recipes', {
      method: 'POST',
      headers: { 'x-user-id': 'u1', 'x-role': 'owner', 'content-type': 'application/json' },
      body: JSON.stringify({ title: 'x', servings: 1 }),
    });
    expect(write.status).toBe(201);
  });

  it('a bearer token is accepted but ignored (no 401 either way)', async () => {
    const { app } = prodApp();
    const withBearer = await app.request('/recipes', {
      headers: { Authorization: 'Bearer anything-at-all', 'x-role': 'owner' },
    });
    expect(withBearer.status).toBe(200);
    const withoutBearer = await app.request('/recipes', {
      headers: { 'x-role': 'owner' },
    });
    expect(withoutBearer.status).toBe(200);
  });

  it('prod never allows header-role escalation: x-role owner still viewer (writes 403, reads 200)', async () => {
    const { app, store } = prodApp();
    await store.setMembership('hh-demo', 'beta-user', 'viewer');
    const auth = { 'x-user-id': 'beta-user', 'x-role': 'owner' };
    const write = await app.request('/recipes', {
      method: 'POST',
      headers: { ...auth, 'content-type': 'application/json' },
      body: JSON.stringify({ title: 'Escalation Attempt', servings: 2, householdId: 'hh-demo' }),
    });
    expect(write.status).toBe(403); // forced viewer, not owner
    const read = await app.request('/recipes?householdId=hh-demo', { headers: auth });
    expect(read.status).toBe(200);
  });

  it('prod RBAC stays keyed off user.id: stored owner membership can still write', async () => {
    const { app, store } = prodApp();
    await store.setMembership('hh-demo', 'beta-owner', 'owner');
    const auth = { 'x-user-id': 'beta-owner', 'x-role': 'viewer' };
    const res = await app.request('/recipes', {
      method: 'POST',
      headers: { ...auth, 'content-type': 'application/json' },
      body: JSON.stringify({ title: 'Membership Wins', servings: 2, householdId: 'hh-demo' }),
    });
    expect(res.status).toBe(201);
  });

  it('dev stub unchanged: x-role owner works with no bearer', async () => {
    const { app } = devApp();
    const res = await app.request('/recipes', {
      method: 'POST',
      headers: { 'x-user-id': 'dev-user', 'x-role': 'owner', 'content-type': 'application/json' },
      body: JSON.stringify({ title: 'Dev Stew', servings: 2 }),
    });
    expect(res.status).toBe(201);
  });
});
