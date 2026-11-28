// Web E2E V1 parity tests: locked crypto vectors + invite + sync orchestration.
// Vectors derived from the spec (docs/e2e-v1.md) via node:crypto; any change
// here must match iOS (SyncCrypto.swift) and Android (SyncCrypto.kt).

import { describe, expect, it, beforeEach } from 'vitest';
import {
  b64encode,
  b64decode,
  e2eDecrypt,
  e2eEncrypt,
  hashPrefix8,
  headerAD,
  householdHash,
  inviteBundleJson,
  kidOf,
  parseInviteBundle,
  acceptInvite,
  ensureE2EIdentity,
  loadActive,
  loadMetadata,
  type EncryptedEnvelope,
  type InviteBundle,
} from './e2e';
import { Store, type SyncEnvelope } from './store';
import { syncE2E, type E2ETransport } from './sync';

function stubLocalStorage(): void {
  const map = new Map<string, string>();
  const ls = {
    getItem: (k: string) => (map.has(k) ? map.get(k)! : null),
    setItem: (k: string, v: string) => void map.set(k, String(v)),
    removeItem: (k: string) => void map.delete(k),
    clear: () => map.clear(),
  };
  Object.defineProperty(globalThis, 'localStorage', { value: ls, configurable: true, writable: true });
}

const CODE = 'correct horse battery staple';
const HH = 'hh1';
// node:crypto reference: hex(sha256("smidgen-hh-v1" + CODE + HH))
const HASH = '8bf8111bffef7ec689deef9b62b86072f5a78266d2b0728ddaf27978edea421f';
// base64url(sha256(CODE))[:12]
const KID = 'xLvLH77JnWW_';

function env(id: string, updatedAt: string, title = 'Soup', deviceId = 'dev-a'): SyncEnvelope {
  return { id, updatedAt, deviceId, entity: 'recipe', payload: { title } };
}

describe('locked E2E vectors', () => {
  it('householdHash matches the spec derivation', async () => {
    await expect(householdHash(CODE, HH)).resolves.toBe(HASH);
  });

  it('kidOf matches base64url(sha256)[:12]', async () => {
    await expect(kidOf(CODE)).resolves.toBe(KID);
  });

  it('hashPrefix8 is the first 8 hex chars', () => {
    expect(hashPrefix8(HASH)).toBe('8bf8111b');
  });

  it('base64 round-trips', () => {
    const bytes = new Uint8Array([0, 1, 2, 250, 255]);
    expect(b64decode(b64encode(bytes))).toEqual(bytes);
  });

  it('headerAD is deterministic JSON with millis binding', () => {
    const ad = (id: string) =>
      headerAD({ kid: KID, householdHash: HASH, id, updatedAtMillis: 1700000000123, deviceId: 'd"1', deleted: false, entity: 'recipe' });
    expect(ad('r1')).toEqual(ad('r1'));
    const parts = JSON.parse(new TextDecoder().decode(ad('r1'))) as string[];
    expect(parts).toHaveLength(10);
    expect(parts[0]).toBe('smidgen-e2e-ad-v1');
    expect(parts[6]).toBe('1700000000123');
    expect(parts[7]).toBe('d"1');
  });
});

describe('seal / open', () => {
  const identity = { householdId: HH, kid: KID, hash: HASH };

  it('round-trips a payload', async () => {
    const enc = await e2eEncrypt(env('r1', '2026-01-02T03:04:05.123Z'), identity, CODE);
    expect(enc.v).toBe(2);
    expect(enc.alg).toBe('AES-GCM-256');
    expect(enc.nonce.length).toBeGreaterThan(0);
    const back = await e2eDecrypt(enc, identity, CODE);
    expect(back.id).toBe('r1');
    expect(back.payload).toEqual({ title: 'Soup' });
    expect(back.updatedAt).toBe('2026-01-02T03:04:05.123Z');
  });

  it('fails closed on a tampered header', async () => {
    const enc = await e2eEncrypt(env('r1', '2026-01-02T03:04:05.123Z'), identity, CODE);
    await expect(e2eDecrypt({ ...enc, deviceId: 'mallory' }, identity, CODE)).rejects.toThrow('decrypt failed');
  });

  it('fails closed on a wrong code', async () => {
    const enc = await e2eEncrypt(env('r1', '2026-01-02T03:04:05.123Z'), identity, CODE);
    await expect(e2eDecrypt(enc, identity, 'wrong code')).rejects.toThrow();
  });

  it('rejects unknown versions', async () => {
    const enc = await e2eEncrypt(env('r1', '2026-01-02T03:04:05.123Z'), identity, CODE);
    await expect(e2eDecrypt({ ...enc, v: 1 } as unknown as EncryptedEnvelope, identity, CODE)).rejects.toThrow('unsupported envelope version');
  });
});

describe('invite bundles', () => {
  const bundle: InviteBundle = { householdId: HH, syncCode: CODE, kid: KID, hash: HASH };

  it('encodes v2 JSON the native apps accept', () => {
    const parsed = JSON.parse(inviteBundleJson(bundle)) as Record<string, string>;
    expect(parsed.v).toBe('2');
    expect(parsed.householdId).toBe(HH);
    expect(parsed.syncCode).toBe(CODE);
    expect(parsed.kid).toBe(KID);
    expect(parsed.hash).toBe(HASH);
  });

  it('parses its own bundle', async () => {
    await expect(parseInviteBundle(inviteBundleJson(bundle))).resolves.toMatchObject({ householdId: HH, kid: KID, hash: HASH });
  });

  it('rejects non-invites', async () => {
    await expect(parseInviteBundle('hello')).rejects.toThrow('not a Keep Cooking invite code');
    await expect(parseInviteBundle(JSON.stringify({ v: '1', householdId: HH, syncCode: CODE, kid: KID, hash: HASH }))).rejects.toThrow(
      'not a Keep Cooking invite code',
    );
  });

  it('rejects tampered hashes and kids', async () => {
    await expect(parseInviteBundle(inviteBundleJson({ ...bundle, hash: '0'.repeat(64) }))).rejects.toThrow('mistyped or tampered');
    await expect(parseInviteBundle(inviteBundleJson({ ...bundle, kid: 'AAAAAAAAAAAA' }))).rejects.toThrow('Key ID mismatch');
  });
});

describe('identity storage', () => {
  beforeEach(() => stubLocalStorage());

  it('acceptInvite then loadActive round-trips', async () => {
    expect(loadMetadata()).toBeNull();
    expect(await acceptInvite({ householdId: HH, syncCode: CODE, kid: KID, hash: HASH })).toBe(true);
    expect(loadMetadata()).toMatchObject({ householdId: HH, kid: KID, hash: HASH });
    const active = await loadActive();
    expect(active?.syncCode).toBe(CODE);
  });

  it('acceptInvite refuses tampered bundles and stores nothing', async () => {
    expect(await acceptInvite({ householdId: HH, syncCode: CODE, kid: KID, hash: '0'.repeat(64) })).toBe(false);
    expect(loadMetadata()).toBeNull();
  });

  it('ensureE2EIdentity is stable (no rotation side effect)', async () => {
    const first = await ensureE2EIdentity(HH);
    const second = await ensureE2EIdentity('other-household');
    expect(first?.syncCode).toBe(second?.syncCode);
    expect(second?.metadata.householdId).toBe(HH);
  });
});

describe('syncE2E orchestration', () => {
  beforeEach(() => stubLocalStorage());

  function memoryTransport(bucket: EncryptedEnvelope[], accepted: Set<string> = new Set()): E2ETransport & { bucket: EncryptedEnvelope[] } {
    return {
      bucket,
      pull: async () => [...bucket],
      push: async (_hash, envs) => {
        const stored: string[] = [];
        for (const e of envs) {
          if (accepted.has(e.id)) continue; // simulate server-won LWW race
          bucket.push(e);
          stored.push(e.id);
        }
        return stored;
      },
    };
  }

  const identity = { householdId: HH, kid: KID, hash: HASH };

  it('pushes the outbox sealed and pulls remote winners via LWW', async () => {
    const store = new Store();
    store.clearAll();
    store.upsert('recipe', 'local-1', { title: 'Local' });
    const t = memoryTransport([]);
    const res = await syncE2E(store, identity, CODE, t);
    expect(res).toEqual({ pulled: 0, pushed: 1, conflicts: 0 });
    expect(store.state.outbox).toHaveLength(0);
    expect(t.bucket).toHaveLength(1);
    expect(t.bucket[0].id).toBe('local-1');

    // A newer remote wins; an older remote loses to the local edit.
    const remoteNew = await e2eEncrypt(env('local-1', '2999-01-01T00:00:00.000Z', 'Remote', 'dev-b'), identity, CODE);
    const res2 = await syncE2E(store, identity, CODE, memoryTransport([remoteNew]));
    expect(res2.pulled).toBe(1);
    expect((store.state.recipes.find((e) => e.id === 'local-1')?.payload as { title: string }).title).toBe('Remote');
  });

  it('keeps a newer local edit and counts server-won conflicts', async () => {
    const store = new Store();
    store.clearAll();
    store.upsert('recipe', 'r1', { title: 'Local edit' });
    // Race: the incremental pull misses the server version, the push loses
    // the server-side LWW, and the forced full pull reconciles the winner.
    const winner = await e2eEncrypt(env('r1', '2999-01-01T00:00:00.000Z', 'Winner', 'dev-b'), identity, CODE);
    let pulls = 0;
    const t: E2ETransport = {
      pull: async () => (++pulls === 1 ? [] : [winner]),
      push: async () => [],
    };
    const res = await syncE2E(store, identity, CODE, t);
    expect(pulls).toBe(2);
    expect(res.conflicts).toBe(1);
    expect((store.state.recipes.find((e) => e.id === 'r1')?.payload as { title: string }).title).toBe('Winner');
  });

  it('chunks pushes at the 500-envelope cap', async () => {
    const store = new Store();
    store.clearAll();
    for (let i = 0; i < 501; i++) store.upsert('recipe', `r${i}`, { title: `R${i}` });
    let batches = 0;
    const t: E2ETransport = {
      pull: async () => [],
      push: async (_hash, envs) => {
        batches++;
        expect(envs.length).toBeLessThanOrEqual(500);
        return envs.map((e) => e.id);
      },
    };
    const res = await syncE2E(store, identity, CODE, t);
    expect(batches).toBe(2);
    expect(res.pushed).toBe(501);
  });
});

describe('invite edge cases', () => {
  it('rejects JSON null with the controlled error', async () => {
    await expect(parseInviteBundle('null')).rejects.toThrow('not a Keep Cooking invite code');
    await expect(parseInviteBundle('[]')).rejects.toThrow('not a Keep Cooking invite code');
    await expect(parseInviteBundle('{"v":"2"}')).rejects.toThrow('not a Keep Cooking invite code');
  });
});

describe('cross-platform vectors (independent node:crypto implementation)', () => {
  // Sealed with node:crypto (fixed nonce) — never with the code under test.
  const CODE2 = 'cross-platform-check';
  const HH2 = 'hh-xplat';
  const KID2 = 'xEKOTzEQxdGk';
  const HASH2 = '0e95f88ee969963dc1853f0d6c0cd1a51c6b482bd0c1dd6655de03e636634a36';
  const identity2 = { householdId: HH2, kid: KID2, hash: HASH2 };
  const NODE_SEALED: EncryptedEnvelope = {
    v: 2,
    alg: 'AES-GCM-256',
    kid: KID2,
    householdHash: HASH2,
    id: 'rec-xplat-1',
    entity: 'recipe',
    updatedAt: '2026-03-04T05:06:07.089Z',
    deviceId: 'dev-node',
    deleted: false,
    nonce: 'AAECAwQFBgcICQoL',
    ciphertext: 'OoROxK4gWVrajnGkwivXvA6if2zCHWki4FabdTG7gSznc3QDROfLYgN9k+sEzRbNYyVxa+Ln+eR9xZzg',
  };

  it('opens a node-sealed envelope (HKDF + AD + AES-GCM interop)', async () => {
    const back = await e2eDecrypt(NODE_SEALED, identity2, CODE2);
    expect(back).toMatchObject({ id: 'rec-xplat-1', deviceId: 'dev-node', entity: 'recipe' });
    expect(back.payload).toEqual({ title: 'Cross-platform soup', servings: 2 });
  });

  it('web-sealed envelopes open under node:crypto with a rebuilt AD', async () => {
    const { createDecipheriv, hkdfSync } = await import('node:crypto');
    const env = await e2eEncrypt(
      { id: 'rec-web-1', updatedAt: '2026-05-06T07:08:09.010Z', deviceId: 'dev-web', entity: 'recipe', payload: { title: 'Web soup' } },
      identity2,
      CODE2,
    );
    const key = Buffer.from(
      hkdfSync('sha256', Buffer.from(CODE2, 'utf8'), Buffer.from('smidgen-sync-v1', 'utf8'), Buffer.from(`smidgen-sync-v1/hh:${HH2}/kid:${KID2}`, 'utf8'), 32),
    );
    const millis = Date.parse(env.updatedAt);
    const ad = JSON.stringify([
      'smidgen-e2e-ad-v1', '2', 'AES-GCM-256', env.kid, env.householdHash, env.id,
      String(millis), env.deviceId, env.deleted ? '1' : '0', env.entity,
    ]);
    const combined = Buffer.from(env.ciphertext, 'base64');
    const decipher = createDecipheriv('aes-256-gcm', key, Buffer.from(env.nonce, 'base64'), { authTagLength: 16 });
    decipher.setAAD(Buffer.from(ad, 'utf8'));
    decipher.setAuthTag(combined.subarray(combined.length - 16));
    const plain = Buffer.concat([decipher.update(combined.subarray(0, combined.length - 16)), decipher.final()]);
    expect(JSON.parse(plain.toString('utf8'))).toEqual({ title: 'Web soup' });
  });
});

describe('syncE2E revision handling', () => {
  const identity = { householdId: HH, kid: KID, hash: HASH };

  it('coalesces duplicate-id revisions to a single push (latest wins)', async () => {
    const store = new Store();
    store.clearAll();
    store.upsert('recipe', 'r1', { title: 'v1' });
    store.upsert('recipe', 'r1', { title: 'v2' });
    expect(store.state.outbox).toHaveLength(2);
    const pushed: EncryptedEnvelope[] = [];
    const t: E2ETransport = {
      pull: async () => [],
      push: async (_hash, envs) => {
        pushed.push(...envs);
        return envs.map((e) => e.id);
      },
    };
    const res = await syncE2E(store, identity, CODE, t);
    expect(pushed).toHaveLength(1);
    expect(res).toEqual({ pulled: 0, pushed: 1, conflicts: 0 });
    expect(store.state.outbox).toHaveLength(0);
    expect(await e2eDecrypt(pushed[0], identity, CODE)).toMatchObject({ id: 'r1' });
    expect((await e2eDecrypt(pushed[0], identity, CODE)).payload).toEqual({ title: 'v2' });
  });

  it('drains an identical replay after a lost PUT response', async () => {
    const store = new Store();
    store.clearAll();
    const local = store.upsert('recipe', 'r1', { title: 'Local' });
    // Server stored it but the response was lost: the retry sees no stored
    // id, then the forced full pull replays our exact revision.
    const winner = await e2eEncrypt({ ...local }, identity, CODE);
    let pulls = 0;
    const t: E2ETransport = {
      pull: async () => (++pulls === 1 ? [] : [winner]),
      push: async () => [],
    };
    const res = await syncE2E(store, identity, CODE, t);
    expect(pulls).toBe(2);
    expect(res.conflicts).toBe(1);
    expect(store.state.outbox).toHaveLength(0);
  });
});
