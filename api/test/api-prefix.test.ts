import { describe, it, expect } from 'vitest';
import { createHash, generateKeyPairSync, sign, type KeyObject } from 'node:crypto';
import { createApp } from '../src/index';
import { MemoryStore } from '../src/store';

// Issue #28: keepcooking.app/api origin. Every route is mounted twice — at
// `/` (backward compat: old workers.dev clients keep working) and at `/api`
// (custom-domain origin) — via native Hono .route(). Signatures cover the
// FULL path+query, so /api writes sign the /api path and root writes sign
// the root path; no auth change was needed.

const PROD_URL = 'https://keepcooking.app/api';
const HASH = 'b'.repeat(64);

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
}) {
  const bodyBytes = new TextEncoder().encode(o.body);
  const ts = Date.now().toString();
  const canonical = `${o.method}\n${o.path}\n${ts}\n${sha256Hex(bodyBytes)}`;
  const sig = sign(null, new TextEncoder().encode(canonical), o.privateKey);
  return {
    'content-type': 'application/json',
    'x-device-id': o.deviceId,
    'x-device-ts': ts,
    'x-device-sig': sig.toString('base64'),
  };
}

describe('dual-serve: /api/* and root paths', () => {
  it('/api/health and /health both 200', async () => {
    const { app } = await prodApp();
    for (const p of ['/health', '/api/health']) {
      const res = await app.request(p, { method: 'GET' });
      expect(res.status).toBe(200);
      expect(await res.json()).toEqual({ ok: true, version: expect.any(String) });
    }
  });

  it('/api/openapi.json and /openapi.json both 200', async () => {
    const { app } = await prodApp();
    for (const p of ['/openapi.json', '/api/openapi.json']) {
      const res = await app.request(p, { method: 'GET' });
      expect(res.status).toBe(200);
    }
  });

  it('open reads work on both mounts; unsigned writes 401 on both', async () => {
    const { app } = await prodApp();
    for (const p of ['/recipes', '/api/recipes']) {
      expect((await app.request(p, { method: 'GET' })).status).toBe(200);
    }
    const anon = { 'content-type': 'application/json' };
    const body = JSON.stringify({ title: 'x', servings: 1, householdId: 'hh-demo' });
    for (const p of ['/recipes', '/api/recipes']) {
      expect((await app.request(p, { method: 'POST', headers: anon, body })).status).toBe(401);
    }
  });

  it('signed write works via /api (full /api path in canonical string)', async () => {
    const { app, dev } = await prodApp();
    const hh = `hh-api-${crypto.randomUUID()}`;
    const body = JSON.stringify({ title: 'API Stew', servings: 2, householdId: hh });
    const res = await app.request('/api/recipes', {
      method: 'POST',
      headers: signedHeaders({ deviceId: dev.id, privateKey: dev.privateKey, method: 'POST', path: '/api/recipes', body }),
      body,
    });
    expect(res.status).toBe(201);
  });

  it('signed write still works on root paths (backward compat)', async () => {
    const { app, dev } = await prodApp();
    const hh = `hh-root-${crypto.randomUUID()}`;
    const body = JSON.stringify({ title: 'Root Stew', servings: 2, householdId: hh });
    const res = await app.request('/recipes', {
      method: 'POST',
      headers: signedHeaders({ deviceId: dev.id, privateKey: dev.privateKey, method: 'POST', path: '/recipes', body }),
      body,
    });
    expect(res.status).toBe(201);
  });

  it('a root-signed signature does NOT verify on the /api path (and vice versa)', async () => {
    const { app, dev } = await prodApp();
    const hh = `hh-x-${crypto.randomUUID()}`;
    const body = JSON.stringify({ title: 'X Stew', servings: 2, householdId: hh });
    // Signed for /recipes but sent to /api/recipes -> 401 (canonical mismatch).
    const crossed = await app.request('/api/recipes', {
      method: 'POST',
      headers: signedHeaders({ deviceId: dev.id, privateKey: dev.privateKey, method: 'POST', path: '/recipes', body }),
      body,
    });
    expect(crossed.status).toBe(401);
  });

  it('open enrollment works on both mounts; e2e sync write works via /api', async () => {
    const { app, dev } = await prodApp();
    const fresh = makeDevice();
    const enrollBody = JSON.stringify({ deviceId: fresh.id, publicKey: fresh.publicKeyB64 });
    for (const p of ['/v2/devices', '/api/v2/devices']) {
      const res = await app.request(p, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: enrollBody,
      });
      expect([200, 201]).toContain(res.status);
    }
    const envBody = JSON.stringify([
      {
        v: 2,
        alg: 'AES-GCM-256',
        kid: 'k1',
        householdHash: HASH,
        id: crypto.randomUUID(),
        entity: 'recipe',
        updatedAt: new Date().toISOString(),
        deviceId: dev.id,
        deleted: false,
        nonce: Buffer.from('123456789012').toString('base64'),
        ciphertext: Buffer.from('0123456789abcdef0123456789abcdef').toString('base64'),
      },
    ]);
    const putPath = `/api/v2/sync/${HASH}`;
    const put = await app.request(putPath, {
      method: 'PUT',
      headers: signedHeaders({ deviceId: dev.id, privateKey: dev.privateKey, method: 'PUT', path: putPath, body: envBody }),
      body: envBody,
    });
    expect(put.status).toBe(200);
    // Same blind bucket readable from the root mount.
    const pull = await app.request(`/v2/sync/${HASH}`, { method: 'GET' });
    expect(pull.status).toBe(200);
    expect(await pull.json()).toEqual(JSON.parse(envBody));
  });
});
