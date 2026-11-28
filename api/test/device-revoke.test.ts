import { describe, it, expect } from 'vitest';
import { createHash, generateKeyPairSync, sign, type KeyObject } from 'node:crypto';
import { createApp } from '../src/index';
import { MemoryStore } from '../src/store';
import { D1Store } from '../src/d1store';

// POST /v2/devices/:id/revoke (self-revoke only):
// - 200 { deviceId, revokedAt } on valid self-signed revoke; the revoked
//   device then fails all writes with 401 via authenticateDevice.
// - 404 for unknown :id (checked before auth), 401 for missing/bad sig,
//   403 for cross-device revoke (signer != :id). No admin override, no UI.

const PROD_URL = 'https://keepcooking.app/api';

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

  it('revokedAt is stable: a concurrent revoke keeps the first timestamp', async () => {
    const { app, store, dev } = await prodApp();
    const path = `/v2/devices/${dev.id}/revoke`;
    const first = await app.request(path, {
      method: 'POST',
      headers: signedHeaders({ deviceId: dev.id, privateKey: dev.privateKey, method: 'POST', path, body: '' }),
    });
    expect(first.status).toBe(200);
    const ts1 = (await store.getDevice(dev.id))?.revokedAt;
    expect(typeof ts1).toBe('string');
    // A direct second revoke (bypassing the revoked-signer 401) is idempotent.
    const again = await store.revokeDevice(dev.id);
    expect(again).toEqual({ deviceId: dev.id, revokedAt: ts1 });
  });
});

// Minimal in-memory D1 fake: only the device_keys statements used by
// D1Store.getDevice/enrollDevice/revokeDevice are implemented.
function fakeD1(state: {
  winnerB64: string | null;
  winnerCreatedAt?: string;
  winnerRevokedAt?: string | null;
  failReads?: boolean;
  failWrites?: boolean;
  seenSql?: string[];
}) {
  const run = async (sql: string, params: unknown[]) => {
    state.seenSql?.push(sql);
    if (state.failWrites) throw new Error('D1 write failed');
    return {};
  };
  return {
    prepare(sql: string) {
      return {
        bind(...params: unknown[]) {
          return {
            first: async () => {
              if (state.failReads) throw new Error('D1 read failed');
              if (sql.startsWith('SELECT device_id, public_key, created_at FROM device_keys')) {
                if (!state.winnerB64) return null;
                return {
                  device_id: 'd1-test-device',
                  public_key: state.winnerB64,
                  created_at: state.winnerCreatedAt ?? '2026-01-01T00:00:00.000Z',
                };
              }
              if (sql.startsWith('SELECT device_id, public_key, display_name, created_at, revoked_at')) {
                if (!state.winnerB64) return null;
                return {
                  device_id: 'd1-test-device',
                  public_key: state.winnerB64,
                  display_name: null,
                  created_at: state.winnerCreatedAt ?? '2026-01-01T00:00:00.000Z',
                  revoked_at: state.winnerRevokedAt ?? null,
                };
              }
              if (sql.startsWith('SELECT public_key FROM device_keys')) {
                if (!state.winnerB64) return null;
                return { public_key: state.winnerB64 };
              }
              if (sql.startsWith('SELECT COUNT(*)')) return { n: 0 };
              return null;
            },
            run: () => run(sql, params),
            all: async () => ({ results: [] }),
          };
        },
        all: async () => ({ results: [] }),
      };
    },
  };
}

describe('D1 device-key durability', () => {
  it('lost-race 409 clears the rejected key: later D1 reads see the winner', async () => {
    const loser = makeDevice();
    const winner = makeDevice();
    // Pre-check sees no winner, our key is cached by super.enrollDevice, then
    // the post-insert re-read finds a concurrent winner with another key.
    let phase = 0;
    const phased = {
      prepare(sql: string) {
        return {
          bind(...params: unknown[]) {
            return {
              first: async () => {
                if (sql.startsWith('SELECT device_id, public_key, created_at FROM device_keys')) {
                  return phase === 0 ? null : { device_id: 'd1-test-device', public_key: winner.publicKeyB64, created_at: '2026-01-01T00:00:00.000Z' };
                }
                if (sql.startsWith('SELECT public_key FROM device_keys')) {
                  return { public_key: winner.publicKeyB64 };
                }
                if (sql.startsWith('SELECT device_id, public_key, display_name, created_at, revoked_at')) {
                  return {
                    device_id: 'd1-test-device',
                    public_key: winner.publicKeyB64,
                    display_name: null,
                    created_at: '2026-01-01T00:00:00.000Z',
                    revoked_at: null,
                  };
                }
                return null;
              },
              run: async () => {
                phase = 1; // insert landed; a concurrent winner beats us after this
                return {};
              },
              all: async () => ({ results: [] }),
            };
          },
          all: async () => ({ results: [] }),
        };
      },
    };
    const phasedStore = new D1Store(phased as never);
    await expect(
      phasedStore.enrollDevice({ deviceId: 'd1-test-device', publicKeyB64: loser.publicKeyB64 }),
    ).rejects.toMatchObject({ status: 409 });
    // D1 is now unreachable: the fallback must serve the D1 winner, never
    // the rejected loser key.
    (phasedStore as unknown as { db: unknown }).db = fakeD1({ winnerB64: winner.publicKeyB64, failReads: true }) as never;
    const got = await phasedStore.getDevice('d1-test-device');
    expect(got).not.toBeNull();
    expect(Buffer.from(got!.publicKey).toString('base64')).toBe(winner.publicKeyB64);
  });

  it('revoke is first-write-wins (COALESCE) and reports the D1 timestamp', async () => {
    const seenSql: string[] = [];
    const store = new D1Store(
      fakeD1({ winnerB64: makeDevice().publicKeyB64, winnerRevokedAt: '2026-05-01T00:00:00.000Z', seenSql }) as never,
    );
    const res = await store.revokeDevice('d1-test-device');
    expect(res).toEqual({ deviceId: 'd1-test-device', revokedAt: '2026-05-01T00:00:00.000Z' });
    expect(seenSql.some((s) => s.includes('COALESCE(revoked_at'))).toBe(true);
  });

  it('revoke fails (no 200) when D1 cannot persist', async () => {
    const key = makeDevice();
    const store = new D1Store(fakeD1({ winnerB64: key.publicKeyB64, failWrites: true }) as never);
    await expect(store.revokeDevice('d1-test-device')).rejects.toThrow('D1 write failed');
  });
});
