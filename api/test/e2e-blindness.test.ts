import { describe, it, expect, beforeAll } from 'vitest';
import { createHash } from 'node:crypto';
import { createApp } from '../src/index';
import { MemoryStore } from '../src/store';
import { D1Store, type D1 } from '../src/d1store';
import { householdHash, type EncryptedEnvelope } from '../src/e2e';
import { makeApp, req } from './helpers';

let HASH = '';
let OTHER_HASH = '';
beforeAll(async () => {
  HASH = await householdHash('test-sync-code-1', 'hh-e2e');
  OTHER_HASH = await householdHash('different-code', 'hh-e2e');
});

// Schema-enforced crypto shapes: nonce = base64(12 bytes), ciphertext =
// base64(>=16 bytes, at least the GCM auth tag).
const b64 = (raw: string) => Buffer.from(raw, 'utf8').toString('base64');
const ct = (raw: string) => b64(raw.length >= 16 ? raw : raw.padEnd(16, '.'));
const NONCE = b64('NONCE-base12'); // exactly 12 bytes

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
    nonce: NONCE,
    ciphertext: ct('CIPHERTEXT-base'),
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

  it('rejects bad nonce/ciphertext shapes (400)', async () => {
    const { app } = await makeApp({ seed: false });
    const cases: Partial<EncryptedEnvelope>[] = [
      { nonce: 'AAAA' }, // 3 bytes, not 12
      { nonce: 'not valid base64!!!' },
      { nonce: b64('eleven-byte') }, // 11 bytes
      { nonce: b64('thirteen-byte') }, // 13 bytes
      { ciphertext: 'AAAA' }, // 3 bytes, needs >= 16
      { ciphertext: '%%%' },
      { ciphertext: b64('fifteen-bytes!!') }, // 15 bytes
    ];
    for (const [i, c] of cases.entries()) {
      const res = await req(app, 'PUT', `/v2/sync/${HASH}`, { body: [env({ id: uid(200 + i), ...c })] });
      expect(res.status).toBe(400);
    }
    // Boundary shapes pass: 12-byte nonce + exactly-16-byte ciphertext.
    const ok = await req(app, 'PUT', `/v2/sync/${HASH}`, {
      body: [env({ id: uid(210), nonce: b64('0123456789ab'), ciphertext: b64('0123456789abcdef') })],
    });
    expect(ok.status).toBe(200);
    expect(await ok.json()).toEqual({ stored: [uid(210)] });
    expect(await (await req(app, 'GET', `/v2/sync/${HASH}`)).json()).toHaveLength(1);
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

  it('validates the entire batch before writing any (no partial batches)', async () => {
    const { app } = await makeApp({ seed: false });
    const good = env({ id: uid(55) });
    // Second envelope has a householdHash mismatch: whole batch rejected.
    const mismatch = await req(app, 'PUT', `/v2/sync/${HASH}`, {
      body: [good, env({ id: uid(56), householdHash: OTHER_HASH })],
    });
    expect(mismatch.status).toBe(400);
    expect(await (await req(app, 'GET', `/v2/sync/${HASH}`)).json()).toEqual([]);
    // Second envelope is a forbidden entity: 422, still nothing written.
    const forbidden = await req(app, 'PUT', `/v2/sync/${HASH}`, {
      body: [good, { ...env({ id: uid(57) }), entity: 'ingredient' }],
    });
    expect(forbidden.status).toBe(422);
    expect(await (await req(app, 'GET', `/v2/sync/${HASH}`)).json()).toEqual([]);
    // Second envelope fails schema: 400, still nothing written.
    const broken = await req(app, 'PUT', `/v2/sync/${HASH}`, {
      body: [good, { ...env({ id: uid(58) }), nonce: 'short' }],
    });
    expect(broken.status).toBe(400);
    expect(await (await req(app, 'GET', `/v2/sync/${HASH}`)).json()).toEqual([]);
  });

  it('upserts LWW by updatedAt (stale loses, ties idempotent)', async () => {
    const { app } = await makeApp({ seed: false });
    const id = uid(21);
    const newer = env({ id, updatedAt: '2026-11-22T12:00:00.000Z', ciphertext: ct('CIPHERTEXT-NEW') });
    const older = env({ id, updatedAt: '2026-11-20T12:00:00.000Z', ciphertext: ct('CIPHERTEXT-OLD') });
    expect((await (await req(app, 'PUT', `/v2/sync/${HASH}`, { body: [newer] })).json())).toEqual({ stored: [id] });
    const stale = await req(app, 'PUT', `/v2/sync/${HASH}`, { body: [older] });
    expect(stale.status).toBe(200);
    expect(await stale.json()).toEqual({ stored: [] });
    // Equal timestamps: idempotent, still a single winner.
    const again = await req(app, 'PUT', `/v2/sync/${HASH}`, { body: [newer] });
    expect(await again.json()).toEqual({ stored: [] });
    const list = (await (await req(app, 'GET', `/v2/sync/${HASH}`)).json()) as EncryptedEnvelope[];
    expect(list).toHaveLength(1);
    expect(list[0]!.ciphertext).toBe(ct('CIPHERTEXT-NEW'));
  });

  it('LWW compares parsed timestamps and handles invalid dates safely', async () => {
    const s = new MemoryStore();
    const good = env({ id: uid(91), updatedAt: '2026-11-20T12:00:00.000Z' });
    expect(await s.e2ePut(HASH, good)).toBe(true);
    // Invalid incoming timestamps never win.
    expect(await s.e2ePut(HASH, { ...good, updatedAt: 'not-a-date' })).toBe(false);
    expect((await s.e2eList(HASH, '1970-01-01T00:00:00.000Z'))[0]!.ciphertext).toBe(good.ciphertext);
    // Mixed ISO shapes order by instant, not lexically: 13:00+02:00 is
    // 11:00Z — older than the stored 12:00Z despite sorting later as text.
    expect(
      await s.e2ePut(HASH, env({ id: uid(91), updatedAt: '2026-11-20T13:00:00+02:00' })),
    ).toBe(false);
    // An invalid stored timestamp loses to any valid incoming one.
    const weird = env({ id: uid(92), updatedAt: 'garbage' });
    expect(await s.e2ePut(HASH, weird)).toBe(true);
    expect(await s.e2ePut(HASH, env({ id: uid(92), updatedAt: '2026-11-21T12:00:00.000Z' }))).toBe(true);
  });

  it('propagates deleted=true tombstones on pull', async () => {
    const { app } = await makeApp({ seed: false });
    const id = uid(31);
    await req(app, 'PUT', `/v2/sync/${HASH}`, {
      body: [env({ id, updatedAt: '2026-11-20T12:00:00.000Z', ciphertext: ct('CIPHERTEXT-LIVE') })],
    });
    await req(app, 'PUT', `/v2/sync/${HASH}`, {
      body: [env({ id, updatedAt: '2026-11-21T12:00:00.000Z', deleted: true, ciphertext: ct('CIPHERTEXT-TOMB') })],
    });
    const list = (await (await req(app, 'GET', `/v2/sync/${HASH}?since=2026-11-20T13:00:00.000Z`)).json()) as EncryptedEnvelope[];
    expect(list).toHaveLength(1);
    expect(list[0]!.deleted).toBe(true);
    expect(list[0]!.ciphertext).toBe(ct('CIPHERTEXT-TOMB'));
  });

  it('filters by ?since on header updatedAt (pullSince semantics)', async () => {
    const { app } = await makeApp({ seed: false });
    await req(app, 'PUT', `/v2/sync/${HASH}`, {
      body: [
        env({ id: uid(41), updatedAt: '2026-11-20T12:00:00.000Z', entity: 'plan', ciphertext: ct('C1') }),
        env({ id: uid(42), updatedAt: '2026-11-25T12:00:00.000Z', entity: 'plan', ciphertext: ct('C2') }),
      ],
    });
    const pull = (await (
      await req(app, 'GET', `/v2/sync/${HASH}?since=2026-11-22T00:00:00.000Z`)
    ).json()) as EncryptedEnvelope[];
    expect(pull.map((e) => e.id)).toEqual([uid(42)]);
    // Non-canonical but valid dates are normalized, not rejected.
    const offset = await req(app, 'GET', `/v2/sync/${HASH}?since=2026-11-22T00:00:00%2B00:00`);
    expect(offset.status).toBe(200);
    expect(((await offset.json()) as EncryptedEnvelope[]).map((e) => e.id)).toEqual([uid(42)]);
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
        env({ id: uid(61), updatedAt: '2026-11-20T12:00:00.000Z', ciphertext: ct('C1') }),
        env({ id: uid(62), updatedAt: '2026-11-21T12:00:00.000Z', entity: 'list', ciphertext: ct('C2') }),
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

  it('/v2 is open without any token (no enrollment)', async () => {
    const store = new MemoryStore();
    const app = createApp(store, {
      baseUrl: 'https://keep-cooking-api.pshippy-245.workers.dev',
      secret: 'test-secret',
    });
    const anon = { 'content-type': 'application/json' };
    expect((await app.request(`/v2/sync/${HASH}`, { headers: anon })).status).toBe(200);
    expect(
      (await app.request(`/v2/sync/${HASH}`, { method: 'PUT', headers: anon, body: JSON.stringify([]) })).status,
    ).toBe(200);
    expect((await app.request(`/v2/sync/${HASH}`, { method: 'DELETE', headers: anon })).status).toBe(200);
  });

  it('logs never include ciphertext-adjacent plaintext (hash prefix only)', async () => {
    const { app } = await makeApp({ seed: false });
    const lines: string[] = [];
    const orig = console.log;
    console.log = (...args: unknown[]) => {
      lines.push(args.map((a) => String(a)).join(' '));
    };
    try {
      const ctRaw = 'SECRET-CIPHERTEXT-9f8e7d6c5b4a';
      const nonceRaw = 'SECRET-NONCE'; // exactly 12 bytes
      await req(app, 'PUT', `/v2/sync/${HASH}`, {
        body: [env({ id: uid(71), ciphertext: b64(ctRaw), nonce: b64(nonceRaw) })],
      });
      await req(app, 'GET', `/v2/sync/${HASH}`);
      await req(app, 'DELETE', `/v2/sync/${HASH}`);
    } finally {
      console.log = orig;
    }
    const all = lines.join('\n');
    expect(lines.length).toBeGreaterThan(0);
    expect(all).not.toContain('SECRET-CIPHERTEXT-9f8e7d6c5b4a');
    expect(all).not.toContain('SECRET-NONCE');
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

// Faithful fake-D1: implements just enough of the D1 binding for the SQL
// D1Store emits — per-hash blob SELECT, the LWW-guarded blob UPSERT
// (honoring the WHERE excluded.updated_at predicate), blob DELETE, and
// empty results for every legacy-table hydrate query. Legacy persists are
// no-ops. `failRun` makes the next run() throw (D1 outage simulation).
type FakeRow = Record<string, unknown>;
type FakeBlob = { household_hash: string; id: string; header: string; ciphertext: string; updated_at: string };

class FakeD1 {
  blobs = new Map<string, FakeBlob>();
  seenSql: string[] = [];
  failRun: Error | null = null;

  private selectBlobs(hash: string): FakeBlob[] {
    return [...this.blobs.values()].filter((r) => r.household_hash === hash);
  }

  prepare(sql: string) {
    this.seenSql.push(sql);
    const self = this;
    return {
      bind(...values: unknown[]) {
        return {
          async all(): Promise<{ results: FakeRow[] }> {
            if (/FROM\s+sync_blobs_v2/i.test(sql)) {
              return { results: self.selectBlobs(String(values[0] ?? '')) };
            }
            return { results: [] };
          },
          async first(): Promise<FakeRow | null> {
            if (/FROM\s+sync_blobs_v2/i.test(sql)) {
              return self.selectBlobs(String(values[0] ?? ''))[0] ?? null;
            }
            return null;
          },
          async run(): Promise<unknown> {
            if (self.failRun) {
              const e = self.failRun;
              self.failRun = null;
              throw e;
            }
            if (/INSERT\s+INTO\s+sync_blobs_v2/i.test(sql)) {
              const [hh, id, header, ciphertext, updatedAt] = values as string[];
              const key = `${hh}|${id}`;
              const cur = self.blobs.get(key);
              const next: FakeBlob = { household_hash: hh, id, header, ciphertext, updated_at: updatedAt };
              if (!cur) {
                self.blobs.set(key, next);
              } else if (/WHERE\s+excluded\.updated_at\s*>/i.test(sql)) {
                // Faithful UPSERT predicate: stale writes can't clobber.
                const nu = Date.parse(updatedAt);
                const cu = Date.parse(cur.updated_at);
                if (!Number.isNaN(nu) && (Number.isNaN(cu) || nu > cu)) self.blobs.set(key, next);
              } else if (updatedAt >= cur.updated_at) {
                self.blobs.set(key, next);
              }
              return {};
            }
            if (/DELETE\s+FROM\s+sync_blobs_v2/i.test(sql)) {
              const hash = String(values[0] ?? '');
              for (const k of [...self.blobs.keys()]) {
                if (k.startsWith(`${hash}|`)) self.blobs.delete(k);
              }
              return {};
            }
            return {};
          },
        };
      },
      async all(): Promise<{ results: FakeRow[] }> {
        return { results: [] };
      },
    };
  }
}

describe('e2e v1 D1-backed pipe (faithful FakeD1)', () => {
  const makeD1App = async (fake: FakeD1) => {
    const store = new D1Store(fake as unknown as D1);
    await store.hydrate();
    const app = createApp(store, { baseUrl: 'https://api.keepcooking.local', secret: 'test-secret' });
    return { app, store, fake };
  };

  it('PUT/LWW/pull/wipe round-trip through D1 (header-only routing + opaque ciphertext)', async () => {
    const { app, fake } = await makeD1App(new FakeD1());
    const id = uid(301);
    const put = await req(app, 'PUT', `/v2/sync/${HASH}`, {
      body: [env({ id, updatedAt: '2026-11-20T12:00:00.000Z', ciphertext: ct('D1-CIPHERTEXT-1!') })],
    });
    expect(put.status).toBe(200);
    expect(await put.json()).toEqual({ stored: [id] });
    // D1 row carries the routing header + opaque ciphertext columns.
    const row = fake.blobs.get(`${HASH}|${id}`);
    expect(row).toBeDefined();
    expect(row!.updated_at).toBe('2026-11-20T12:00:00.000Z');
    expect(row!.ciphertext).toBe(ct('D1-CIPHERTEXT-1!'));
    const header = JSON.parse(row!.header) as Record<string, unknown>;
    expect(header['id']).toBe(id);
    expect(header['nonce']).toBe(NONCE);
    expect(header).not.toHaveProperty('ciphertext');
    // Stale loses; pull returns the winner.
    const stale = await req(app, 'PUT', `/v2/sync/${HASH}`, {
      body: [env({ id, updatedAt: '2026-11-19T12:00:00.000Z', ciphertext: ct('D1-CIPHERTEXT-0!') })],
    });
    expect(await stale.json()).toEqual({ stored: [] });
    expect(fake.blobs.get(`${HASH}|${id}`)!.ciphertext).toBe(ct('D1-CIPHERTEXT-1!'));
    const pull = (await (await req(app, 'GET', `/v2/sync/${HASH}`)).json()) as EncryptedEnvelope[];
    expect(pull).toHaveLength(1);
    expect(pull[0]!.ciphertext).toBe(ct('D1-CIPHERTEXT-1!'));
    // Wipe clears D1 and reports the reconciled count.
    const wipe = await req(app, 'DELETE', `/v2/sync/${HASH}`);
    expect(await wipe.json()).toEqual({ wiped: 1 });
    expect(fake.blobs.size).toBe(0);
    expect(await (await req(app, 'GET', `/v2/sync/${HASH}`)).json()).toEqual([]);
  });

  it('LWW holds across isolates and the upsert carries the conflict predicate', async () => {
    const fake = new FakeD1();
    const a = await makeD1App(fake);
    const b = await makeD1App(fake);
    const id = uid(302);
    // B's cache is empty and hydrate() never bulk-loads blobs; its write
    // path lazy-loads the hash from D1.
    await req(a.app, 'PUT', `/v2/sync/${HASH}`, {
      body: [env({ id, updatedAt: '2026-11-22T12:00:00.000Z', ciphertext: ct('D1-CIPHERTEXT-NEW') })],
    });
    expect(await b.store.e2ePut(HASH, env({ id, updatedAt: '2026-11-20T12:00:00.000Z', ciphertext: ct('D1-STALE!!!!!!') }))).toBe(false);
    expect(fake.blobs.get(`${HASH}|${id}`)!.ciphertext).toBe(ct('D1-CIPHERTEXT-NEW'));
    // …while a newer write from the other isolate wins everywhere.
    expect(await b.store.e2ePut(HASH, env({ id, updatedAt: '2026-11-23T12:00:00.000Z', ciphertext: ct('D1-NEWER!!!!!!') }))).toBe(true);
    const pullA = await a.store.e2eList(HASH, '1970-01-01T00:00:00.000Z');
    expect(pullA.map((e) => e.ciphertext)).toEqual([ct('D1-NEWER!!!!!!')]);
    // The emitted upsert targets the composite key with an LWW predicate so
    // a stale write racing the load can't overwrite a newer D1 winner.
    const upsert = fake.seenSql.find((s) => /INSERT\s+INTO\s+sync_blobs_v2/i.test(s));
    expect(upsert).toBeDefined();
    expect(upsert).toMatch(/ON CONFLICT\s*\(\s*household_hash\s*,\s*id\s*\)/i);
    expect(upsert).toMatch(/WHERE\s+excluded\.updated_at\s*>\s*sync_blobs_v2\.updated_at/i);
  });

  it('a stale write racing the snapshot cannot clobber the D1 winner', async () => {
    const fake = new FakeD1();
    const { store } = await makeD1App(fake);
    const id = uid(303);
    // First persist wins and records the store's upsert SQL.
    expect(await store.e2ePut(HASH, env({ id, updatedAt: '2026-11-20T12:00:00.000Z', ciphertext: ct('D1-V1-VALID!!!!') }))).toBe(true);
    const captured = fake.seenSql.find((s) => /INSERT\s+INTO\s+sync_blobs_v2/i.test(s));
    expect(captured).toBeDefined();
    // A newer row lands in D1 behind the snapshot; replaying the captured
    // upsert with a stale version must not clobber it (predicate guards).
    fake.blobs.set(`${HASH}|${id}`, {
      household_hash: HASH,
      id,
      header: JSON.stringify({ v: 2, id }),
      ciphertext: ct('D1-V2-WINNER!!!!'),
      updated_at: '2026-11-22T12:00:00.000Z',
    });
    await fake
      .prepare(captured!)
      .bind(HASH, id, JSON.stringify({ v: 2, id }), ct('D1-STALE!!!!!!!'), '2026-11-19T12:00:00.000Z')
      .run();
    expect(fake.blobs.get(`${HASH}|${id}`)!.ciphertext).toBe(ct('D1-V2-WINNER!!!!'));
  });

  it('a wipe on one isolate does not resurrect on another', async () => {
    const fake = new FakeD1();
    const a = await makeD1App(fake);
    const b = await makeD1App(fake);
    await req(a.app, 'PUT', `/v2/sync/${HASH}`, {
      body: [
        env({ id: uid(304), updatedAt: '2026-11-20T12:00:00.000Z', ciphertext: ct('WIPE-ME-1!!!!!!') }),
        env({ id: uid(305), updatedAt: '2026-11-21T12:00:00.000Z', ciphertext: ct('WIPE-ME-2!!!!!!') }),
      ],
    });
    expect(await (await req(a.app, 'GET', `/v2/sync/${HASH}`)).json()).toHaveLength(2);
    expect(await (await req(b.app, 'DELETE', `/v2/sync/${HASH}`)).json()).toEqual({ wiped: 2 });
    expect(fake.blobs.size).toBe(0);
    // A's cache still holds the rows, but its next read reconciles against
    // D1 and drops them instead of resurrecting.
    expect(await (await req(a.app, 'GET', `/v2/sync/${HASH}`)).json()).toEqual([]);
  });

  it('propagates D1 persistence failures instead of acking memory-only', async () => {
    const fake = new FakeD1();
    const { app } = await makeD1App(fake);
    fake.failRun = new Error('D1 unavailable');
    const res = await req(app, 'PUT', `/v2/sync/${HASH}`, { body: [env({ id: uid(306) })] });
    expect(res.status).toBe(500);
  });

  it('keeps unconfirmed local writes across reconciles until D1 confirms', async () => {
    const fake = new FakeD1();
    const { store } = await makeD1App(fake);
    fake.failRun = new Error('boom');
    await expect(store.e2ePut(HASH, env({ id: uid(307) }))).rejects.toThrow('boom');
    // D1 has nothing, but the unconfirmed write survives reconciliation…
    expect((await store.e2eList(HASH, '1970-01-01T00:00:00.000Z')).map((e) => e.id)).toEqual([uid(307)]);
    // …and a retry once D1 recovers confirms it (idempotent tie for the
    // winner, but D1 now holds the row).
    expect(await store.e2ePut(HASH, env({ id: uid(307) }))).toBe(false);
    expect(fake.blobs.get(`${HASH}|${uid(307)}`)!.ciphertext).toBe(ct('CIPHERTEXT-base'));
  });

  it('wipe failures propagate (no silent success)', async () => {
    const fake = new FakeD1();
    const { store } = await makeD1App(fake);
    expect(await store.e2ePut(HASH, env({ id: uid(308) }))).toBe(true);
    fake.failRun = new Error('D1 unavailable');
    await expect(store.e2eWipe(HASH)).rejects.toThrow('D1 unavailable');
  });
});
