import { describe, it, expect } from 'vitest';
import { createHash, generateKeyPairSync, sign, type KeyObject } from 'node:crypto';
import { createApp } from '../src/index';
import { MemoryStore } from '../src/store';

// POST /v2/devices/:id/revoke (self-revoke only):
// - 200 { deviceId, revokedAt } on valid self-signed revoke; the revoked
//   device then fails all writes with 401 via authenticateDevice.
// - 404 for unknown :id (checked before auth), 401 for missing/bad sig,
//   403 for cross-device revoke (signer != :id). No admin override, no UI.

const PROD_URL = 'https://keep-cooking-api.pshippy-245.workers.dev';

function makeDevice() {
  const id = crypto.randomUUID();
  const { publicKey, privateKey } = generateKeyPairSync('ed25519');
  const spki: Buffer = publicKey.export({ format: 'der', type: 'spki' });
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

function sha256Hex(bytes: Uint8Array): string {
  return createHash('sha256').update(bytes).digest('hex');
}

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

const recipeBody = JSON.stringify({ title: 'x', servings: 1, householdId: 'hh-demo' });

describe('device self-revoke', () => {
  it('self-revoke -> 200, then revoked device fails writes with 401', async () => {
    const { app, store, dev } = await prodApp();
    await store.setMembership('hh-demo', dev.id, 'owner');
    const path = `/v2/devices/${dev.id}/revoke`;
    const res = await app.request(path, {
      method: 'POST',
      headers: signedHeaders({ deviceId: dev.id, privateKey: dev.privateKey, method: 'POST', path, body: '' }),
    });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ deviceId: dev.id, revokedAt: expect.any(String) });

    const write = await app.request('/recipes', {
      method: 'POST',
      headers: signedHeaders({ deviceId: dev.id, privateKey: dev.privateKey, method: 'POST', path: '/recipes', body: recipeBody }),
      body: recipeBody,
    });
    expect(write.status).toBe(401);
  });

  it('unknown device id -> 404', async () => {
    const { app, dev } = await prodApp();
    const target = crypto.randomUUID();
    const path = `/v2/devices/${target}/revoke`;
    const res = await app.request(path, {
      method: 'POST',
      headers: signedHeaders({ deviceId: dev.id, privateKey: dev.privateKey, method: 'POST', path, body: '' }),
    });
    expect(res.status).toBe(404);
  });

  it('missing signature -> 401', async () => {
    const { app, dev } = await prodApp();
    const res = await app.request(`/v2/devices/${dev.id}/revoke`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
    });
    expect(res.status).toBe(401);
  });

  it('cross-device revoke -> 403 and victim stays usable', async () => {
    const { app, store, dev } = await prodApp();
    const other = makeDevice();
    await store.enrollDevice({ deviceId: other.id, publicKeyB64: other.publicKeyB64 });
    await store.setMembership('hh-demo', other.id, 'owner');
    const path = `/v2/devices/${other.id}/revoke`;
    const res = await app.request(path, {
      method: 'POST',
      headers: signedHeaders({ deviceId: dev.id, privateKey: dev.privateKey, method: 'POST', path, body: '' }),
    });
    expect(res.status).toBe(403);

    const write = await app.request('/recipes', {
      method: 'POST',
      headers: signedHeaders({
        deviceId: other.id,
        privateKey: other.privateKey,
        method: 'POST',
        path: '/recipes',
        body: recipeBody,
      }),
      body: recipeBody,
    });
    expect(write.status).toBe(201);
  });

  it('second self-revoke after revocation -> 401 (revoked signer)', async () => {
    const { app, dev } = await prodApp();
    const path = `/v2/devices/${dev.id}/revoke`;
    const first = await app.request(path, {
      method: 'POST',
      headers: signedHeaders({ deviceId: dev.id, privateKey: dev.privateKey, method: 'POST', path, body: '' }),
    });
    expect(first.status).toBe(200);
    const second = await app.request(path, {
      method: 'POST',
      headers: signedHeaders({ deviceId: dev.id, privateKey: dev.privateKey, method: 'POST', path, body: '' }),
    });
    expect(second.status).toBe(401);
  });
});
