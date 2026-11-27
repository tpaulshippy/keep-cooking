import { describe, it, expect } from 'vitest';
import { createHash, generateKeyPairSync, sign, type KeyObject } from 'node:crypto';
import { createApp } from '../src/index';
import { MemoryStore } from '../src/store';

// Device-signature gate (prod):
// - reads (GET/HEAD/OPTIONS) + /health + /openapi.json: open, no sig.
// - POST /v2/devices: public enrollment (201 / 200 / 409 / 400 per oracle).
// - all other POST/PUT/DELETE: valid Ed25519 sig required (401 otherwise).
//   v2 writes are sig-only; v1 writes add household RBAC with
//   user.id = verified deviceId. Legacy bearer tokens are ignored.
// Dev (local baseUrl) keeps the x-role header stub: unsigned writes pass.

const PROD_URL = 'https://keep-cooking-api.pshippy-245.workers.dev';
const HASH = 'a'.repeat(64);

function makeDevice() {
  const id = crypto.randomUUID();
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const spki: Buffer = publicKey.export({ format: 'der', type: 'spki' });
  // SPKI DER = 12-byte prefix + 32-byte raw key (verified against node output).
  const raw = new Uint8Array(spki.subarray(spki.length - 32));
  return { id, publicKey: raw, publicKeyB64: Buffer.from(raw).toString('base64'), privateKey };
}

async function prodApp() {
  const store = new MemoryStore();
  const dev = makeDevice();
  await store.enrollDevice({ deviceId: dev.id, publicKeyB64: dev.publicKeyB64 });
  const app = createApp(store, { baseUrl: PROD_URL, secret: 'test-secret' });
  return { app, store, dev };
}

async function enrollDevice(store: MemoryStore) {
  const d = makeDevice();
  await store.enrollDevice({ deviceId: d.id, publicKeyB64: d.publicKeyB64 });
  return d;
}

function devApp() {
  const store = new MemoryStore();
  const app = createApp(store, { baseUrl: 'https://api.keepcooking.local', secret: 'test-secret' });
  return { app, store };
}

const recipeBody = JSON.stringify({ title: 'x', servings: 1, householdId: 'hh-demo' });

function signedHeaders(o: {
  deviceId: string;
  privateKey: KeyObject;
  method: string;
  path: string;
  body: string;
  ts?: string;
}) {
  const bodyBytes = new TextEncoder().encode(o.body);
  const ts = o.ts ?? Date.now().toString();
  const canonical = `${o.method}\n${o.path}\n${ts}\n${sha256Hex(bodyBytes)}`;
  const sig = sign(null, new TextEncoder().encode(canonical), o.privateKey);
  return {
    'content-type': 'application/json',
    'x-device-id': o.deviceId,
    'x-device-ts': ts,
    'x-device-sig': sig.toString('base64'),
  };
}

function sha256Hex(bytes: Uint8Array): string {
  return createHash('sha256').update(bytes).digest('hex');
}

function encEnv(id: string, deviceId: string) {
  return {
    v: 2,
    alg: 'AES-GCM-256',
    kid: 'k1',
    householdHash: HASH,
    id,
    entity: 'recipe',
    updatedAt: new Date().toISOString(),
    deviceId,
    deleted: false,
    nonce: Buffer.from('123456789012').toString('base64'),
    ciphertext: Buffer.from('0123456789abcdef0123456789abcdef').toString('base64'),
  };
}

describe('device-signature gate (prod)', () => {
  it('/health stays unauthenticated', async () => {
    const { app } = await prodApp();
    const res = await app.request('/health', { method: 'GET' });
    expect(res.status).toBe(200);
  });

  it('reads stay open without any signature', async () => {
    const { app } = await prodApp();
    for (const [m, p] of [
      ['GET', '/recipes'],
      ['GET', '/sync/pull?since=1970-01-01T00:00:00Z'],
      ['GET', '/openapi.json'],
      ['GET', `/v2/sync/${HASH}`],
    ] as const) {
      const res = await app.request(p, { method: m });
      expect(res.status).toBe(200);
    }
  });

  it('prod writes without a signature -> 401 (v1 + v2 sync)', async () => {
    const { app, store } = await prodApp();
    await store.setMembership('hh-demo', 'u1', 'owner');
    const anon = { 'content-type': 'application/json', 'x-user-id': 'u1', 'x-role': 'owner' };
    const r1 = await app.request('/recipes', { method: 'POST', headers: anon, body: recipeBody });
    expect(r1.status).toBe(401);
    const r2 = await app.request(`/v2/sync/${HASH}`, {
      method: 'PUT',
      headers: anon,
      body: JSON.stringify([]),
    });
    expect(r2.status).toBe(401);
    const r3 = await app.request(`/v2/sync/${HASH}`, { method: 'DELETE', headers: anon });
    expect(r3.status).toBe(401);
  });

  it('a legacy bearer token is ignored: writes without a sig still 401', async () => {
    const { app } = await prodApp();
    const res = await app.request('/recipes', {
      method: 'POST',
      headers: {
        Authorization: 'Bearer legacy-secret',
        'content-type': 'application/json',
        'x-user-id': 'u1',
        'x-role': 'owner',
      },
      body: recipeBody,
    });
    expect(res.status).toBe(401);
  });

  it('stale timestamps, bad signatures, and unknown devices -> 401', async () => {
    const { app, dev } = await prodApp();
    const base = { deviceId: dev.id, privateKey: dev.privateKey, method: 'POST', path: '/recipes', body: recipeBody };
    const stale = await app.request('/recipes', {
      method: 'POST',
      headers: signedHeaders({ ...base, ts: (Date.now() - 10 * 60_000).toString() }),
      body: recipeBody,
    });
    expect(stale.status).toBe(401);
    const tampered = await app.request('/recipes', {
      method: 'POST',
      headers: signedHeaders(base),
      body: JSON.stringify({ title: 'tampered', servings: 1, householdId: 'hh-demo' }),
    });
    expect(tampered.status).toBe(401);
    const unknown = await app.request('/recipes', {
      method: 'POST',
      headers: signedHeaders({ ...base, deviceId: crypto.randomUUID() }),
      body: recipeBody,
    });
    expect(unknown.status).toBe(401);
  });

  it('valid signature -> v1 write 201 and v2 sync write 200', async () => {
    const { app, store, dev } = await prodApp();
    await store.setMembership('hh-demo', dev.id, 'owner');
    const write = await app.request('/recipes', {
      method: 'POST',
      headers: signedHeaders({ deviceId: dev.id, privateKey: dev.privateKey, method: 'POST', path: '/recipes', body: recipeBody }),
      body: recipeBody,
    });
    expect(write.status).toBe(201);
    const envBody = JSON.stringify([encEnv(crypto.randomUUID(), dev.id)]);
    const put = await app.request(`/v2/sync/${HASH}`, {
      method: 'PUT',
      headers: signedHeaders({
        deviceId: dev.id,
        privateKey: dev.privateKey,
        method: 'PUT',
        path: `/v2/sync/${HASH}`,
        body: envBody,
      }),
      body: envBody,
    });
    expect(put.status).toBe(200);
    expect(await put.json()).toEqual({ stored: expect.any(Array) });
  });

  it('v1 RBAC is keyed off the verified device id (sig + role, not headers)', async () => {
    const { app, store, dev } = await prodApp();
    // Owner device writes even when x-user-id/x-role headers say otherwise.
    await store.setMembership('hh-demo', dev.id, 'owner');
    const headers = {
      ...signedHeaders({ deviceId: dev.id, privateKey: dev.privateKey, method: 'POST', path: '/recipes', body: recipeBody }),
      'x-user-id': 'someone-else',
      'x-role': 'viewer',
    };
    const res = await app.request('/recipes', { method: 'POST', headers, body: recipeBody });
    expect(res.status).toBe(201);
    // Viewer device with a valid sig still gets 403 on writes.
    const viewer = await enrollDevice(store);
    await store.setMembership('hh-demo', viewer.id, 'viewer');
    const denied = await app.request('/recipes', {
      method: 'POST',
      headers: signedHeaders({
        deviceId: viewer.id,
        privateKey: viewer.privateKey,
        method: 'POST',
        path: '/recipes',
        body: recipeBody,
      }),
      body: recipeBody,
    });
    expect(denied.status).toBe(403);
  });

  it('POST /v2/devices is public: 201 enroll, 200 re-enroll, 409 conflict, 400 invalid', async () => {
    const { app } = await prodApp();
    const fresh = makeDevice();
    const enrollBody = JSON.stringify({ deviceId: fresh.id, publicKey: fresh.publicKeyB64 });
    const first = await app.request('/v2/devices', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: enrollBody,
    });
    expect(first.status).toBe(201);
    expect(await first.json()).toEqual({ deviceId: fresh.id, enrolledAt: expect.any(String) });
    const again = await app.request('/v2/devices', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: enrollBody,
    });
    expect(again.status).toBe(200);
    const other = makeDevice();
    const conflict = await app.request('/v2/devices', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ deviceId: fresh.id, publicKey: other.publicKeyB64 }),
    });
    expect(conflict.status).toBe(409);
    const invalid = await app.request('/v2/devices', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ deviceId: 'not-a-uuid', publicKey: 'AA==' }),
    });
    expect(invalid.status).toBe(400);
  });

  it('dev stub unchanged: unsigned writes work with x-role owner', async () => {
    const { app } = devApp();
    const res = await app.request('/recipes', {
      method: 'POST',
      headers: { 'x-user-id': 'dev-user', 'x-role': 'owner', 'content-type': 'application/json' },
      body: JSON.stringify({ title: 'Dev Stew', servings: 2 }),
    });
    expect(res.status).toBe(201);
  });

  it('enroll with JSON null body -> 400 (not a 500 TypeError)', async () => {
    const { app } = await prodApp();
    const res = await app.request('/v2/devices', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: 'null',
    });
    expect(res.status).toBe(400);
  });

  it('re-enrolling a revoked device -> 410 (same or different key)', async () => {
    const { app, store, dev } = await prodApp();
    await store.setMembership('hh-demo', dev.id, 'owner');
    const path = `/v2/devices/${dev.id}/revoke`;
    const revoked = await app.request(path, {
      method: 'POST',
      headers: signedHeaders({ deviceId: dev.id, privateKey: dev.privateKey, method: 'POST', path, body: '' }),
    });
    expect(revoked.status).toBe(200);

    const sameKey = await app.request('/v2/devices', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ deviceId: dev.id, publicKey: dev.publicKeyB64 }),
    });
    expect(sameKey.status).toBe(410);
    expect(await sameKey.json()).toEqual({ error: expect.stringContaining('fresh deviceId') });

    const other = makeDevice();
    const diffKey = await app.request('/v2/devices', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ deviceId: dev.id, publicKey: other.publicKeyB64 }),
    });
    expect(diffKey.status).toBe(410);
  });

  it('first-claim bootstrap: empty household -> first writer 201 as owner, second device 403', async () => {
    const { app, store, dev } = await prodApp();
    const hh = `hh-first-claim-${crypto.randomUUID()}`;
    const body = JSON.stringify({ title: 'First Stew', servings: 2, householdId: hh });

    const first = await app.request('/recipes', {
      method: 'POST',
      headers: signedHeaders({ deviceId: dev.id, privateKey: dev.privateKey, method: 'POST', path: '/recipes', body }),
      body,
    });
    expect(first.status).toBe(201);
    expect(await store.getMembership(hh, dev.id)).toEqual({ householdId: hh, userId: dev.id, role: 'owner' });

    const second = await enrollDevice(store);
    const body2 = JSON.stringify({ title: 'Second Stew', servings: 2, householdId: hh });
    const denied = await app.request('/recipes', {
      method: 'POST',
      headers: signedHeaders({
        deviceId: second.id,
        privateKey: second.privateKey,
        method: 'POST',
        path: '/recipes',
        body: body2,
      }),
      body: body2,
    });
    expect(denied.status).toBe(403);
  });

  it('gate scoping: non-POST /v2/devices still needs a signature', async () => {
    const { app } = await prodApp();
    const res = await app.request('/v2/devices', {
      method: 'PUT',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({}),
    });
    expect(res.status).toBe(401);
  });

  it('revoke exemption: unknown target -> 404 even with missing/bad signature', async () => {
    const { app, dev } = await prodApp();
    const target = crypto.randomUUID();
    const path = `/v2/devices/${target}/revoke`;
    const missing = await app.request(path, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
    });
    expect(missing.status).toBe(404);
    const badSig = await app.request(path, {
      method: 'POST',
      headers: signedHeaders({ deviceId: dev.id, privateKey: dev.privateKey, method: 'POST', path, body: '{"tampered":true}' }),
    });
    expect(badSig.status).toBe(404);
  });
});
