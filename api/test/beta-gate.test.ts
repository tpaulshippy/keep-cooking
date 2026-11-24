import { describe, it, expect } from 'vitest';
import { createApp } from '../src/index';
import { MemoryStore } from '../src/store';

const BETA = 'beta-secret-123';

function prodApp() {
  const store = new MemoryStore();
  const app = createApp(store, {
    baseUrl: 'https://keep-cooking-api.pshippy-245.workers.dev', // prod host => gate on
    secret: 'test-secret',
    betaToken: BETA,
  });
  return { app, store };
}

function devApp() {
  const store = new MemoryStore();
  const app = createApp(store, { baseUrl: 'https://api.keepcooking.local', secret: 'test-secret' });
  return { app, store };
}

describe('prod beta gate (internal TestFlight)', () => {
  it('/health stays unauthenticated in prod', async () => {
    const { app } = prodApp();
    const res = await app.request('/health', { method: 'GET' });
    expect(res.status).toBe(200);
  });

  it('prod rejects non-health routes without beta token (401)', async () => {
    const { app } = prodApp();
    for (const [m, p] of [
      ['GET', '/recipes'],
      ['POST', '/recipes'],
      ['GET', '/sync/pull?since=1970-01-01T00:00:00Z'],
      ['GET', '/openapi.json'],
    ] as const) {
      const res = await app.request(p, {
        method: m,
        headers: { 'x-user-id': 'u1', 'x-role': 'owner' },
        body: m === 'POST' ? JSON.stringify({ title: 'x', servings: 1 }) : undefined,
      });
      expect(res.status).toBe(401);
    }
  });

  it('prod rejects wrong beta token (401)', async () => {
    const { app } = prodApp();
    const res = await app.request('/recipes', {
      headers: { Authorization: 'Bearer wrong-token', 'x-role': 'owner' },
    });
    expect(res.status).toBe(401);
  });

  it('prod never allows header-role escalation: bearer + x-role owner still viewer (writes 403, reads 200)', async () => {
    const { app, store } = prodApp();
    await store.setMembership('hh-demo', 'beta-user', 'viewer');
    const auth = { Authorization: `Bearer ${BETA}`, 'x-user-id': 'beta-user', 'x-role': 'owner' };
    const write = await app.request('/recipes', {
      method: 'POST',
      headers: { ...auth, 'content-type': 'application/json' },
      body: JSON.stringify({ title: 'Escalation Attempt', servings: 2, householdId: 'hh-demo' }),
    });
    expect(write.status).toBe(403); // forced viewer, not owner
    const read = await app.request('/recipes?householdId=hh-demo', { headers: auth });
    expect(read.status).toBe(200);
  });

  it('prod RBAC stays keyed off user.id: stored owner membership can still write with beta token', async () => {
    const { app, store } = prodApp();
    await store.setMembership('hh-demo', 'beta-owner', 'owner');
    const auth = { Authorization: `Bearer ${BETA}`, 'x-user-id': 'beta-owner', 'x-role': 'viewer' };
    const res = await app.request('/recipes', {
      method: 'POST',
      headers: { ...auth, 'content-type': 'application/json' },
      body: JSON.stringify({ title: 'Membership Wins', servings: 2, householdId: 'hh-demo' }),
    });
    expect(res.status).toBe(201);
  });

  it('prod with no beta token configured fails closed (401 even with bearer)', async () => {
    const store = new MemoryStore();
    const app = createApp(store, {
      baseUrl: 'https://keep-cooking-api.pshippy-245.workers.dev',
      secret: 'test-secret',
      // no betaToken
    });
    const res = await app.request('/recipes', {
      headers: { Authorization: `Bearer ${BETA}` },
    });
    expect(res.status).toBe(401);
    const health = await app.request('/health');
    expect(health.status).toBe(200);
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
