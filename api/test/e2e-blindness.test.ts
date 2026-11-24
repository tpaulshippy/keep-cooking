import { describe, it, expect, beforeAll } from 'vitest';
import { createHash } from 'node:crypto';
import { createApp } from '../src/index';
import { MemoryStore } from '../src/store';
import { householdHash, type EncryptedEnvelope } from '../src/e2e';
import { makeApp, req } from './helpers';

const BETA = 'e2e-beta-token';

let HASH = '';
let OTHER_HASH = '';
beforeAll(async () => {
  HASH = await householdHash('test-sync-code-1', 'hh-e2e');
  OTHER_HASH = await householdHash('different-code', 'hh-e2e');
});

function env(over: Partial<EncryptedEnvelope> = {}): EncryptedEnvelope {
  return {
    v: 2,
    alg: 'AES-GCM-256',
    kid: 'kid-test-1',
    householdHash: HASH,
    id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    entity: 'recipe',
    updatedAt: '2026-11-20T12:00:00.000Z',
    deviceId: 'dev-a',
    deleted: false,
    nonce: 'NONCE-base',
    ciphertext: 'CIPHERTEXT-base',
    ...over,
  };
}

const uid = (n: number) => `12345678-1234-4234-8234-${String(n).padStart(12, '0')}`;

describe('e2e v1 blind blob pipe', () => {
  it('derives householdHash as SHA256 hex of "smidgen-hh-v1"||syncCode||householdId', async () => {
    const expected = createHash('sha256').update('smidgen-hh-v1code-xhh-1', 'utf8').digest('hex');
    expect(await householdHash('code-x', 'hh-1')).toBe(expected);
    expect(HASH).toMatch(/^[0-9a-f]{64}$/);
    expect(OTHER_HASH).not.toBe(HASH);
  });

  it('rejects plaintext v1 envelopes on /v2 (400)', async () => {
    const { app } = await makeApp({ seed: false });
    const plain = {
      id: uid(1),
      updatedAt: '2026-11-20T12:00:00.000Z',
      deviceId: 'a',
      deleted: false,
      entity: 'recipe',
      payload: { title: 'Plaintext Soup' },
    };
    const push = await req(app, 'PUT', `/v2/sync/${HASH}`, { body: [plain] });
    expect(push.status).toBe(400);
    // Non-array bodies are rejected too.
    const notArray = await req(app, 'PUT', `/v2/sync/${HASH}`, { body: { id: uid(2) } });
    expect(notArray.status).toBe(400);
    // Nothing persisted.
    const pull = await req(app, 'GET', `/v2/sync/${HASH}`);
    expect(pull.status).toBe(200);
    expect(await pull.json()).toEqual([]);
  });

  it('rejects standalone ingredient/step envelopes with 422', async () => {
    const { app } = await makeApp({ seed: false });
    const ing = await req(app, 'PUT', `/v2/sync/${HASH}`, {
      body: [{ ...env({ id: uid(11) }), entity: 'ingredient' }],
    });
    expect(ing.status).toBe(422);
    const step = await req(app, 'PUT', `/v2/sync/${HASH}`, {
      body: [{ ...env({ id: uid(12) }), entity: 'step' }],
    });
    expect(step.status).toBe(422);
    expect(await (await req(app, 'GET', `/v2/sync/${HASH}`)).json()).toEqual([]);
  });

  it('upserts LWW by updatedAt (stale loses, ties idempotent)', async () => {
    const { app } = await makeApp({ seed: false });
    const id = uid(21);
    const newer = env({ id, updatedAt: '2026-11-22T12:00:00.000Z', ciphertext: 'CIPHERTEXT-NEW' });
    const older = env({ id, updatedAt: '2026-11-20T12:00:00.000Z', ciphertext: 'CIPHERTEXT-OLD' });
    expect((await (await req(app, 'PUT', `/v2/sync/${HASH}`, { body: [newer] })).json())).toEqual({ stored: [id] });
    const stale = await req(app, 'PUT', `/v2/sync/${HASH}`, { body: [older] });
    expect(stale.status).toBe(200);
    expect(await stale.json()).toEqual({ stored: [] });
    // Equal timestamps: idempotent, still a single winner.
    const again = await req(app, 'PUT', `/v2/sync/${HASH}`, { body: [newer] });
    expect(await again.json()).toEqual({ stored: [] });
    const list = (await (await req(app, 'GET', `/v2/sync/${HASH}`)).json()) as EncryptedEnvelope[];
    expect(list).toHaveLength(1);
    expect(list[0]!.ciphertext).toBe('CIPHERTEXT-NEW');
  });

  it('propagates deleted=true tombstones on pull', async () => {
    const { app } = await makeApp({ seed: false });
    const id = uid(31);
    await req(app, 'PUT', `/v2/sync/${HASH}`, {
      body: [env({ id, updatedAt: '2026-11-20T12:00:00.000Z', ciphertext: 'CIPHERTEXT-LIVE' })],
    });
    await req(app, 'PUT', `/v2/sync/${HASH}`, {
      body: [env({ id, updatedAt: '2026-11-21T12:00:00.000Z', deleted: true, ciphertext: 'CIPHERTEXT-TOMB' })],
    });
    const list = (await (await req(app, 'GET', `/v2/sync/${HASH}?since=2026-11-20T13:00:00.000Z`)).json()) as EncryptedEnvelope[];
    expect(list).toHaveLength(1);
    expect(list[0]!.deleted).toBe(true);
    expect(list[0]!.ciphertext).toBe('CIPHERTEXT-TOMB');
  });

  it('filters by ?since on header updatedAt (pullSince semantics)', async () => {
    const { app } = await makeApp({ seed: false });
    await req(app, 'PUT', `/v2/sync/${HASH}`, {
      body: [
        env({ id: uid(41), updatedAt: '2026-11-20T12:00:00.000Z', entity: 'plan', ciphertext: 'C1' }),
        env({ id: uid(42), updatedAt: '2026-11-25T12:00:00.000Z', entity: 'plan', ciphertext: 'C2' }),
      ],
    });
    const pull = (await (
      await req(app, 'GET', `/v2/sync/${HASH}?since=2026-11-22T00:00:00.000Z`)
    ).json()) as EncryptedEnvelope[];
    expect(pull.map((e) => e.id)).toEqual([uid(42)]);
    const badSince = await req(app, 'GET', `/v2/sync/${HASH}?since=not-a-date`);
    expect(badSince.status).toBe(400);
  });

  it('rejects householdHash mismatch (400)', async () => {
    const { app } = await makeApp({ seed: false });
    const res = await req(app, 'PUT', `/v2/sync/${HASH}`, {
      body: [env({ id: uid(51), householdHash: OTHER_HASH })],
    });
    expect(res.status).toBe(400);
  });

  it('DELETE wipes the whole bucket', async () => {
    const { app } = await makeApp({ seed: false });
    await req(app, 'PUT', `/v2/sync/${HASH}`, {
      body: [
        env({ id: uid(61), updatedAt: '2026-11-20T12:00:00.000Z', ciphertext: 'C1' }),
        env({ id: uid(62), updatedAt: '2026-11-21T12:00:00.000Z', entity: 'list', ciphertext: 'C2' }),
      ],
    });
    const wipe = await req(app, 'DELETE', `/v2/sync/${HASH}`);
    expect(wipe.status).toBe(200);
    expect(await wipe.json()).toEqual({ wiped: 2 });
    expect(await (await req(app, 'GET', `/v2/sync/${HASH}`)).json()).toEqual([]);
    // Wiping an empty/unknown bucket is a no-op, not an error.
    const again = await req(app, 'DELETE', `/v2/sync/${HASH}`);
    expect(await again.json()).toEqual({ wiped: 0 });
  });

  it('bad hashes are 400; unknown well-formed hash pulls empty (200)', async () => {
    const { app } = await makeApp({ seed: false });
    for (const bad of ['not-hex', '0'.repeat(63), '0'.repeat(65), 'g'.repeat(64), 'ABCDEF1234']) {
      expect((await req(app, 'GET', `/v2/sync/${bad}`)).status).toBe(400);
      expect((await req(app, 'PUT', `/v2/sync/${bad}`, { body: [] })).status).toBe(400);
      expect((await req(app, 'DELETE', `/v2/sync/${bad}`)).status).toBe(400);
    }
    const unknown = 'f'.repeat(64);
    const pull = await req(app, 'GET', `/v2/sync/${unknown}`);
    expect(pull.status).toBe(200);
    expect(await pull.json()).toEqual([]);
  });

  it('beta gate fronts /v2 in prod (401 without token)', async () => {
    const store = new MemoryStore();
    const app = createApp(store, {
      baseUrl: 'https://smidgen-api.pshippy-245.workers.dev',
      secret: 'test-secret',
      betaToken: BETA,
    });
    const anon = { 'content-type': 'application/json' };
    expect((await app.request(`/v2/sync/${HASH}`, { headers: anon })).status).toBe(401);
    expect(
      (await app.request(`/v2/sync/${HASH}`, { method: 'PUT', headers: anon, body: JSON.stringify([]) })).status,
    ).toBe(401);
    expect((await app.request(`/v2/sync/${HASH}`, { method: 'DELETE', headers: anon })).status).toBe(401);
    const auth = { Authorization: `Bearer ${BETA}`, 'content-type': 'application/json' };
    expect((await app.request(`/v2/sync/${HASH}`, { headers: auth })).status).toBe(200);
    expect(
      (await app.request(`/v2/sync/${HASH}`, { method: 'DELETE', headers: auth })).status,
    ).toBe(200);
  });

  it('logs never include ciphertext-adjacent plaintext (hash prefix only)', async () => {
    const { app } = await makeApp({ seed: false });
    const lines: string[] = [];
    const orig = console.log;
    console.log = (...args: unknown[]) => {
      lines.push(args.map((a) => String(a)).join(' '));
    };
    try {
      const ct = 'SECRET-CIPHERTEXT-9f8e7d6c5b4a';
      const nonce = 'SECRET-NONCE-5a4b3c2d1e';
      await req(app, 'PUT', `/v2/sync/${HASH}`, {
        body: [env({ id: uid(71), ciphertext: ct, nonce })],
      });
      await req(app, 'GET', `/v2/sync/${HASH}`);
      await req(app, 'DELETE', `/v2/sync/${HASH}`);
    } finally {
      console.log = orig;
    }
    const all = lines.join('\n');
    expect(lines.length).toBeGreaterThan(0);
    expect(all).not.toContain('SECRET-CIPHERTEXT-9f8e7d6c5b4a');
    expect(all).not.toContain('SECRET-NONCE-5a4b3c2d1e');
    expect(all).not.toContain(HASH); // full hash never logged…
    expect(all).toContain(HASH.slice(0, 8)); // …prefix only
    expect(all).not.toContain('ciphertext');
  });

  it('legacy /sync/* plaintext pipe is untouched', async () => {
    const { app } = await makeApp({ seed: false });
    const push = await req(app, 'POST', '/sync/push', {
      body: [
        {
          id: uid(81),
          updatedAt: '2026-11-20T12:00:00.000Z',
          deviceId: 'a',
          deleted: false,
          entity: 'recipe',
          payload: { title: 'Legacy Loaf', householdId: 'hh-demo', ingredients: [], steps: [] },
        },
      ],
    });
    expect(push.status).toBe(200);
    expect(await push.json()).toEqual([]);
  });
});
