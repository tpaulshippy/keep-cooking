// Key-only agent auth tests (#26): happy path + wrong-key rejection +
// blind-server assertion. Uses ONLY published test vectors — no real key
// material. The "client" side re-derives everything from the syncCode with
// WebCrypto (mirroring docs/agents/lib.mjs), so these tests also pin the
// documented KDF against the server.
import { describe, it, expect, beforeAll } from 'vitest';
import { createHash } from 'node:crypto';
import { createApp } from '../src/index';
import { MemoryStore } from '../src/store';
import { D1Store } from '../src/d1store';
import { householdHash, validateE2EPushBatch, E2E_MAX_PUSH_BATCH, type EncryptedEnvelope } from '../src/e2e';
import { AGENT_TOKEN_HEADER } from '../src/agent';
import { deriveAll as deriveAllDocs, encryptEnvelope as docsEncrypt, decryptEnvelope as docsDecrypt, canonicalE2EUpdatedAt } from '../../docs/agents/lib.mjs';
import mcpTools from '../../packages/contracts/mcp-tools.json';

// ---------- fixed test vectors (syncCode is a published dummy, never real) ----------
const SYNC_CODE = 'test-only-vector-sync-code-0001';
const HH = 'hh-agent-test';
const KID = 'PBraLwlg26zP';
const HOUSEHOLD_HASH = 'bb5196d56bbb8b8da4bec5d11c4d17a31f6770bcc16d3d849ee29af48cfa08f4';
// NOTE: no token literal here — GitGuardian flags 43-char base64url as a
// generic secret, and rightly so. The token is re-derived at runtime from
// SYNC_CODE (same HKDF as docs/agents/lib.mjs); the pinned AGENT_VERIFIER
// below still pins the full KDF chain end-to-end.
let AGENT_TOKEN = '';
const AGENT_VERIFIER = '5703eb10eb9f385b81d932418e0b38a7d0c14e3e53d3874387ad44ee5eb88ef1';

// ---------- client-side crypto (mirrors docs/agents/lib.mjs) ----------
const enc = new TextEncoder();
const b64u = (a: Uint8Array | ArrayBuffer) =>
  Buffer.from(a as Uint8Array)
    .toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
const unb64u = (s: string) => new Uint8Array(Buffer.from(s, 'base64'));

async function hkdf(ikmStr: string, salt: string, info: string): Promise<Uint8Array> {
  const ikm = await crypto.subtle.importKey('raw', enc.encode(ikmStr), 'HKDF', false, ['deriveBits']);
  const bits = await crypto.subtle.deriveBits(
    { name: 'HKDF', hash: 'SHA-256', salt: enc.encode(salt), info: enc.encode(info) },
    ikm,
    256,
  );
  return new Uint8Array(bits);
}

async function deriveAll(syncCode: string, householdId: string) {
  const kid = b64u(await crypto.subtle.digest('SHA-256', enc.encode(syncCode))).slice(0, 12);
  const hash = await householdHash(syncCode, householdId);
  const agentRaw = await hkdf(syncCode, 'smidgen-agent-v1', `smidgen-agent-v1/hh:${householdId}/kid:${kid}`);
  const dataRaw = await hkdf(syncCode, 'smidgen-sync-v1', `smidgen-sync-v1/hh:${householdId}/kid:${kid}`);
  return {
    kid,
    householdHash: hash,
    token: b64u(agentRaw),
    verifier: createHash('sha256').update(agentRaw).digest('hex'),
    dataKey: dataRaw,
  };
}

async function encryptEnvelope(
  dataKey: Uint8Array,
  opts: { kid: string; householdHash: string; id: string; entity: 'recipe'; title: string; updatedAt?: string },
): Promise<EncryptedEnvelope> {
  // Native wire format (see docs/agents/lib.mjs + iOS/Android SyncCrypto):
  // ONLY the inner payload is sealed; the plaintext header is bound via
  // e2eHeaderAD as AES-GCM associated data.
  // Mirrors lib.mjs nextAgentUpdatedAt: whole-second AND strictly increasing
  // (module-level), so rapid seals of one entity never tie and both land.
  let ms = Math.floor(Date.parse(opts.updatedAt ?? '2026-11-27T12:00:00.000Z') / 1000) * 1000;
  if (ms <= lastLocalSealMs) ms = lastLocalSealMs + 1000;
  lastLocalSealMs = ms;
  const updatedAt = new Date(ms).toISOString();
  const deviceId = 'agent-test';
  const inner = { id: opts.id, title: opts.title, servings: 2, householdId: HH, ingredients: [], steps: [] };
  const key = await crypto.subtle.importKey('raw', dataKey as unknown as ArrayBuffer, 'AES-GCM', false, ['encrypt']);
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const ad = e2eHeaderAD({ kid: opts.kid, householdHash: opts.householdHash, id: opts.id, updatedAt, deviceId, deleted: false, entity: 'recipe' });
  const ct = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv: nonce as unknown as ArrayBuffer, additionalData: ad as unknown as ArrayBuffer },
    key,
    enc.encode(JSON.stringify(inner)),
  );
  // Wire format is STANDARD base64 with padding (see encryptedEnvelopeSchema).
  const b64 = (a: Uint8Array | ArrayBuffer) => Buffer.from(a as Uint8Array).toString('base64');
  return {
    v: 2,
    alg: 'AES-GCM-256',
    kid: opts.kid,
    householdHash: opts.householdHash,
    id: opts.id,
    entity: 'recipe',
    updatedAt,
    deviceId,
    deleted: false,
    nonce: b64(nonce),
    ciphertext: b64(ct),
  };
}

/** Domain separator for the E2E header AD binding (mirrors lib.mjs). */
const E2E_AD_CONTEXT = 'smidgen-e2e-ad-v1';

// Monotonic seal clock for the local helper (mirrors lib.mjs nextAgentUpdatedAt).
let lastLocalSealMs = 0;

function e2eHeaderAD(h: {
  kid: string; householdHash: string; id: string; updatedAt: string;
  deviceId: string; deleted: boolean; entity: string;
}): Uint8Array {
  const millis = Math.floor(Date.parse(h.updatedAt));
  const parts = [E2E_AD_CONTEXT, '2', 'AES-GCM-256', h.kid, h.householdHash, h.id, String(millis), h.deviceId, h.deleted ? '1' : '0', h.entity];
  return enc.encode(JSON.stringify(parts));
}

async function decryptTitle(dataKey: Uint8Array, env: EncryptedEnvelope): Promise<string> {
  const key = await crypto.subtle.importKey('raw', dataKey as unknown as ArrayBuffer, 'AES-GCM', false, ['decrypt']);
  const ad = e2eHeaderAD({
    kid: env.kid, householdHash: env.householdHash, id: env.id,
    updatedAt: env.updatedAt, deviceId: env.deviceId, deleted: env.deleted, entity: env.entity,
  });
  const pt = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: unb64u(env.nonce) as unknown as ArrayBuffer, additionalData: ad as unknown as ArrayBuffer },
    key,
    unb64u(env.ciphertext),
  );
  const inner = JSON.parse(new TextDecoder().decode(pt)) as { title: string };
  return inner.title;
}

beforeAll(async () => {
  AGENT_TOKEN = (await deriveAll(SYNC_CODE, HH)).token;
});

// ---------- app helpers (key-only: no x-role / x-user-id headers at all) ----------
function agentApp() {
  const store = new MemoryStore();
  const app = createApp(store, { baseUrl: 'https://api.keepcooking.local', secret: 'test-secret' });
  return { app, store };
}

function prodAgentApp() {
  const store = new MemoryStore();
  const app = createApp(store, {
    baseUrl: 'https://keep-cooking-api.pshippy-245.workers.dev',
    secret: 'test-secret',
  });
  return { app, store };
}

const agentHeaders = (token: string) => ({ [AGENT_TOKEN_HEADER]: token, 'content-type': 'application/json' });

async function enroll(app: ReturnType<typeof createApp>, householdHashHex: string, householdId: string, verifier: string) {
  return app.request('/api/agent/enroll', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ householdHash: householdHashHex, householdId, verifier }),
  });
}

async function randomToken(): Promise<string> {
  return b64u(crypto.getRandomValues(new Uint8Array(32)));
}

describe('agent KDF vectors (docs/agents parity)', () => {
  it('re-derives the published test vectors from the syncCode alone', async () => {
    const d = await deriveAll(SYNC_CODE, HH);
    const doc = await deriveAllDocs(SYNC_CODE, HH); // independent implementation
    expect(d.kid).toBe(KID);
    expect(d.householdHash).toBe(HOUSEHOLD_HASH);
    expect(d.verifier).toBe(AGENT_VERIFIER);
    expect(d.token).toBe(doc.token); // cross-implementation parity, no token literal
    expect(d.token).toMatch(/^[A-Za-z0-9_-]{43}$/);
  });

  it('wrong key derives a different token, verifier, and bucket', async () => {
    const d = await deriveAll('test-only-vector-sync-code-9999', HH);
    expect(d.token).not.toBe(AGENT_TOKEN);
    expect(d.verifier).not.toBe(AGENT_VERIFIER);
    expect(d.householdHash).not.toBe(HOUSEHOLD_HASH);
  });

  it('push batches are capped (413 above E2E_MAX_PUSH_BATCH)', async () => {
    const d = await deriveAll(SYNC_CODE, HH);
    const one = await encryptEnvelope(d.dataKey, {
      kid: d.kid,
      householdHash: d.householdHash,
      id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      entity: 'recipe',
      title: 'Batch Cap Broth',
    });
    const atCap = Array(E2E_MAX_PUSH_BATCH).fill(one);
    expect(validateE2EPushBatch(d.householdHash, atCap)).toHaveLength(E2E_MAX_PUSH_BATCH);
    const overCap = [...atCap, one];
    try {
      validateE2EPushBatch(d.householdHash, overCap);
      expect.unreachable('over-cap batch must throw');
    } catch (e) {
      expect((e as { status?: number }).status).toBe(413);
    }
    // HTTP surface: 413, nothing persisted.
    const { app } = agentApp();
    const res = await app.request(`/api/v2/sync/${d.householdHash}`, {
      method: 'PUT',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(overCap),
    });
    expect(res.status).toBe(413);
    expect(await (await app.request(`/api/v2/sync/${d.householdHash}`)).json()).toEqual([]);
  });

  it('lib.mjs and the test helpers interoperate (AD-bound payload-only format)', async () => {
    const d = await deriveAll(SYNC_CODE, HH);
    const doc = await deriveAllDocs(SYNC_CODE, HH);
    const inner = { id: 'x', title: 'Interop Stew', servings: 2, householdId: HH, ingredients: [], steps: [] };
    const params = {
      kid: d.kid,
      householdHash: d.householdHash,
      id: '11111111-1111-4111-8111-111111111111',
      entity: 'recipe',
      updatedAt: '2026-11-27T12:00:00.000Z',
      deviceId: 'agent-test',
      payload: inner,
    };
    // Sealed by lib.mjs, opened by the local helper (and vice versa).
    const viaDocs = await docsEncrypt(doc.dataKey, params);
    expect(await decryptTitle(d.dataKey, viaDocs as unknown as EncryptedEnvelope)).toBe('Interop Stew');
    const viaLocal = await encryptEnvelope(d.dataKey, {
      kid: params.kid, householdHash: params.householdHash, id: params.id, entity: 'recipe', title: 'Interop Stew',
    });
    expect((await docsDecrypt(doc.dataKey, viaLocal)).payload.title).toBe('Interop Stew');
  });

  it('agent envelopes bind whole-second timestamps both apps reproduce', async () => {
    // Agent rule (docs/agents/lib.mjs header): iOS binds whole MILLISECONDS
    // while Android floors to whole SECONDS, so a nonzero-ms envelope fails
    // AD auth on one side. Agent sealing floors to seconds up front, making
    // both formulas agree — pin that here with a nonzero-ms input.
    expect(canonicalE2EUpdatedAt('2026-11-27T12:00:00.456Z')).toBe('2026-11-27T12:00:00.000Z');
    expect(canonicalE2EUpdatedAt('2026-11-27T12:00:00.000Z')).toBe('2026-11-27T12:00:00.000Z');
    const d = await deriveAll(SYNC_CODE, HH);
    const doc = await deriveAllDocs(SYNC_CODE, HH);
    const env = await docsEncrypt(doc.dataKey, {
      kid: d.kid,
      householdHash: d.householdHash,
      id: '11111111-1111-4111-8111-111111111112',
      entity: 'recipe',
      updatedAt: '2026-11-27T12:00:00.456Z', // nonzero millis in…
      deviceId: 'agent-test',
      payload: { id: 'x', title: 'Whole Second Stew', servings: 2, householdId: HH, ingredients: [], steps: [] },
    });
    expect(env.updatedAt.endsWith('.000Z')).toBe(true); // …whole seconds out (monotonic bump may advance it past the input second)
    expect(Date.parse(env.updatedAt)).toBeGreaterThanOrEqual(Date.parse('2026-11-27T12:00:00.000Z'));
    // iOS formula (floor ms) and Android formula (floor to seconds) agree on
    // agent envelopes — the envelope opens on both implementations.
    const iosMillis = Math.floor(Date.parse(env.updatedAt));
    const androidMillis = Math.floor(Date.parse(env.updatedAt) / 1000) * 1000;
    expect(iosMillis).toBe(androidMillis);
    // …and the sealed box still opens (AD over the canonicalized header).
    expect((await docsDecrypt(doc.dataKey, env)).payload.title).toBe('Whole Second Stew');
    expect(await decryptTitle(d.dataKey, env as unknown as EncryptedEnvelope)).toBe('Whole Second Stew');
  });

  it('rapid agent seals are strictly increasing whole seconds (no same-entity ties)', async () => {
    const { nextAgentUpdatedAt } = await import('../../docs/agents/lib.mjs');
    const d = await deriveAll(SYNC_CODE, HH);
    const doc = await deriveAllDocs(SYNC_CODE, HH);
    const base = {
      kid: d.kid,
      householdHash: d.householdHash,
      id: '22222222-2222-4222-8222-222222222222',
      entity: 'recipe' as const,
      deviceId: 'agent-test',
      payload: { id: 'x', title: 'Rapid Ragu', servings: 2, householdId: HH, ingredients: [], steps: [] },
    };
    // Same input timestamp twice (far from other tests' seals, so the
    // module-level clock starts here deterministically).
    const e1 = await docsEncrypt(doc.dataKey, { ...base, updatedAt: '2026-11-27T12:05:00.000Z' });
    const e2 = await docsEncrypt(doc.dataKey, { ...base, updatedAt: '2026-11-27T12:05:00.000Z' });
    expect(e1.updatedAt).toBe('2026-11-27T12:05:00.000Z');
    expect(e2.updatedAt).toBe('2026-11-27T12:05:01.000Z');
    expect(Date.parse(e2.updatedAt)).toBeGreaterThan(Date.parse(e1.updatedAt));
    for (const e of [e1, e2]) {
      // Whole seconds: the iOS (floor ms) and Android (floor to seconds)
      // AD formulas agree, so the envelope opens on both implementations.
      expect(Math.floor(Date.parse(e.updatedAt))).toBe(Math.floor(Date.parse(e.updatedAt) / 1000) * 1000);
      expect((await docsDecrypt(doc.dataKey, e)).payload.title).toBe('Rapid Ragu');
      expect(await decryptTitle(d.dataKey, e as unknown as EncryptedEnvelope)).toBe('Rapid Ragu');
    }
    // The exported stepper is monotonic across calls on its own.
    const t1 = nextAgentUpdatedAt('2026-11-27T12:06:00.000Z');
    expect(nextAgentUpdatedAt('2026-11-27T12:06:00.000Z')).not.toBe(t1);
    expect(Date.parse(nextAgentUpdatedAt('2026-11-27T12:06:00.000Z'))).toBeGreaterThan(Date.parse(t1));
  });
});

describe('agent enroll + key-only REST', () => {
  it('enroll then status with only the key-derived token', async () => {
    const { app } = agentApp();
    const res = await enroll(app, HOUSEHOLD_HASH, HH, AGENT_VERIFIER);
    expect(res.status).toBe(201);
    expect(await res.json()).toEqual({ ok: true, householdId: HH, householdHash: HOUSEHOLD_HASH, hashPrefix8: HOUSEHOLD_HASH.slice(0, 8) });
    const st = await app.request('/api/agent/status', { headers: agentHeaders(AGENT_TOKEN) });
    expect(st.status).toBe(200);
    const body = (await st.json()) as { householdId: string; hashPrefix8: string };
    expect(body.householdId).toBe(HH);
    expect(body.hashPrefix8).toBe(HOUSEHOLD_HASH.slice(0, 8));
  });

  it('rejects bad enroll bodies (400)', async () => {
    const { app } = agentApp();
    for (const bad of [
      { householdHash: 'not-hex', householdId: HH, verifier: AGENT_VERIFIER },
      { householdHash: HOUSEHOLD_HASH, householdId: '', verifier: AGENT_VERIFIER },
      { householdHash: HOUSEHOLD_HASH, householdId: HH, verifier: 'short' },
      {},
    ]) {
      const res = await app.request('/api/agent/enroll', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify(bad),
      });
      expect(res.status).toBe(400);
    }
  });

  it('full CRUD with ONLY the device key (no x-role headers)', async () => {
    const { app } = agentApp();
    await enroll(app, HOUSEHOLD_HASH, HH, AGENT_VERIFIER);
    const h = agentHeaders(AGENT_TOKEN);
    // create recipe
    const created = await app.request('/api/recipes', {
      method: 'POST',
      headers: h,
      body: JSON.stringify({ title: 'Agent Gumbo', servings: 4, householdId: HH }),
    });
    expect(created.status).toBe(201);
    const recipe = (await created.json()) as { id: string };
    // list is scoped to the enrolled household
    const list = (await (await app.request('/api/recipes', { headers: h })).json()) as { id: string }[];
    expect(list.map((r) => r.id)).toEqual([recipe.id]);
    // plan a week entry
    const plan = await app.request('/api/plans', {
      method: 'POST',
      headers: h,
      body: JSON.stringify({ date: '2026-12-01', meal: 'dinner', recipeId: recipe.id, householdId: HH }),
    });
    expect(plan.status).toBe(201);
    // grocery list from the recipe
    const gl = await app.request('/api/lists', {
      method: 'POST',
      headers: h,
      body: JSON.stringify({ name: 'Week groceries', householdId: HH, items: [{ name: 'okra' }] }),
    });
    expect(gl.status).toBe(201);
    // update + delete
    const upd = await app.request(`/api/recipes/${recipe.id}`, {
      method: 'PUT',
      headers: h,
      body: JSON.stringify({ title: 'Agent Gumbo v2', servings: 4, householdId: HH }),
    });
    expect(upd.status).toBe(200);
    const del = await app.request(`/api/recipes/${recipe.id}`, { method: 'DELETE', headers: h });
    expect(del.status).toBe(204);
  });

  it('agent works in prod (no header-role escalation path needed)', async () => {
    const { app } = prodAgentApp();
    await enroll(app, HOUSEHOLD_HASH, HH, AGENT_VERIFIER);
    const res = await app.request('/api/recipes', {
      method: 'POST',
      headers: agentHeaders(AGENT_TOKEN),
      body: JSON.stringify({ title: 'Prod Agent Soup', servings: 2, householdId: HH }),
    });
    expect(res.status).toBe(201);
  });

  it('unknown or malformed token is 401 (fail closed)', async () => {
    const { app } = agentApp();
    await enroll(app, HOUSEHOLD_HASH, HH, AGENT_VERIFIER);
    const unknown = await app.request('/api/recipes', {
      method: 'POST',
      headers: agentHeaders(await randomToken()),
      body: JSON.stringify({ title: 'x', householdId: HH }),
    });
    expect(unknown.status).toBe(401);
    for (const bad of ['short', 'Bearer abc', 'x'.repeat(43)]) {
      const res = await app.request('/api/recipes', {
        method: 'POST',
        headers: agentHeaders(bad),
        body: JSON.stringify({ title: 'x', householdId: HH }),
      });
      expect(res.status).toBe(401);
    }
    // /health stays open even with a bad token (liveness probe).
    expect((await app.request('/api/health', { headers: agentHeaders('short') })).status).toBe(200);
  });

  it('an empty x-agent-token is 401, not anonymous (fail closed)', async () => {
    const { app } = agentApp();
    await enroll(app, HOUSEHOLD_HASH, HH, AGENT_VERIFIER);
    const res = await app.request('/api/recipes', {
      method: 'POST',
      headers: { [AGENT_TOKEN_HEADER]: '', 'content-type': 'application/json' },
      body: JSON.stringify({ title: 'x', householdId: HH }),
    });
    expect(res.status).toBe(401);
    // …while a missing header still takes the anonymous dev path.
    expect((await app.request('/api/recipes')).status).toBe(200);
  });

  it('cross-household access is rejected (403 writes, 404 reads)', async () => {
    const { app } = agentApp();
    await enroll(app, HOUSEHOLD_HASH, HH, AGENT_VERIFIER);
    const h = agentHeaders(AGENT_TOKEN);
    // write naming another household
    const bad = await app.request('/api/recipes', {
      method: 'POST',
      headers: h,
      body: JSON.stringify({ title: 'sneaky', householdId: 'hh-other' }),
    });
    expect(bad.status).toBe(403);
    // seed a foreign-household recipe via the dev stub, then try to read it
    const seeded = await app.request('/api/recipes', {
      method: 'POST',
      headers: { 'x-role': 'owner', 'content-type': 'application/json' },
      body: JSON.stringify({ title: 'Foreign Stew', householdId: 'hh-other' }),
    });
    const fid = ((await seeded.json()) as { id: string }).id;
    expect((await app.request(`/api/recipes/${fid}`, { headers: h })).status).toBe(404);
    // read-only transforms of foreign recipes are hidden too (no oracle)
    const scale = await app.request(`/api/recipes/${fid}/scale`, {
      method: 'POST',
      headers: h,
      body: JSON.stringify({ servings: 8 }),
    });
    expect(scale.status).toBe(404);
    const exp = await app.request(`/api/export/${fid}.md`, { headers: h });
    expect(exp.status).toBe(404);
    // collections hide the foreign household
    const lists = await app.request('/api/lists', {
      method: 'POST',
      headers: { 'x-role': 'owner', 'content-type': 'application/json' },
      body: JSON.stringify({ name: 'foreign', householdId: 'hh-other' }),
    });
    expect(lists.status).toBe(201);
    expect(await (await app.request('/api/lists', { headers: h })).json()).toEqual([]);
  });

  it('a label-squatter without the syncCode gets 409; bootstrap stays open', async () => {
    const { app } = agentApp();
    // Bootstrap: a label with no existing binding enrolls openly.
    expect((await enroll(app, HOUSEHOLD_HASH, HH, AGENT_VERIFIER)).status).toBe(201);
    // Squatter: same label, different hash, no token proof → 409.
    const squat = await enroll(app, 'a'.repeat(64), HH, 'b'.repeat(64));
    expect(squat.status).toBe(409);
    // Victim binding untouched: the real token still verifies.
    expect((await app.request('/api/agent/status', { headers: agentHeaders(AGENT_TOKEN) })).status).toBe(200);
  });

  it('re-binding a bound label with the existing token succeeds (rotation with proof)', async () => {
    const { app } = agentApp();
    await enroll(app, HOUSEHOLD_HASH, HH, AGENT_VERIFIER);
    const newHash = 'c'.repeat(64);
    const token2 = await randomToken();
    const verifier2 = createHash('sha256').update(Buffer.from(token2, 'base64url')).digest('hex');
    // Same label, different hash, but the existing token is presented → 201.
    const rebind = await app.request('/api/agent/enroll', {
      method: 'POST',
      headers: { ...agentHeaders(AGENT_TOKEN), 'content-type': 'application/json' },
      body: JSON.stringify({ householdHash: newHash, householdId: HH, verifier: verifier2 }),
    });
    expect(rebind.status).toBe(201);
    expect((await app.request('/api/agent/status', { headers: agentHeaders(token2) })).status).toBe(200);
  });

  it('rotating the verifier revokes the old token', async () => {
    const { app } = agentApp();
    await enroll(app, HOUSEHOLD_HASH, HH, AGENT_VERIFIER);
    expect((await app.request('/api/agent/status', { headers: agentHeaders(AGENT_TOKEN) })).status).toBe(200);
    const token2 = await randomToken();
    const verifier2 = createHash('sha256').update(Buffer.from(token2, 'base64url')).digest('hex');
    const re = await enroll(app, HOUSEHOLD_HASH, HH, verifier2);
    expect(re.status).toBe(201);
    expect((await app.request('/api/agent/status', { headers: agentHeaders(AGENT_TOKEN) })).status).toBe(401);
    expect((await app.request('/api/agent/status', { headers: agentHeaders(token2) })).status).toBe(200);
  });

  it('re-binding a label to a new hash revokes the old token', async () => {
    const { app, store } = agentApp();
    await enroll(app, HOUSEHOLD_HASH, HH, AGENT_VERIFIER);
    const newHash = 'd'.repeat(64);
    const token2 = await randomToken();
    const verifier2 = createHash('sha256').update(Buffer.from(token2, 'base64url')).digest('hex');
    // Proven re-bind (existing token presented) succeeds and moves the label.
    const rebind = await app.request('/api/agent/enroll', {
      method: 'POST',
      headers: { ...agentHeaders(AGENT_TOKEN), 'content-type': 'application/json' },
      body: JSON.stringify({ householdHash: newHash, householdId: HH, verifier: verifier2 }),
    });
    expect(rebind.status).toBe(201);
    // Old token no longer authenticates; new one does.
    expect((await app.request('/api/agent/status', { headers: agentHeaders(AGENT_TOKEN) })).status).toBe(401);
    expect((await app.request('/api/agent/status', { headers: agentHeaders(token2) })).status).toBe(200);
    // No trace of the old binding: verifier, hash, and label indexes moved.
    expect(await store.agentGetByVerifier(AGENT_VERIFIER)).toBeNull();
    expect(await store.agentGetByLabel(HH)).toMatchObject({ householdHash: newHash, verifier: verifier2 });
  });

  it('agentRevokeByHash deletes the D1 row and clears memory indexes', async () => {
    const deleted: string[] = [];
    const fakeDb = {
      prepare(sql: string) {
        return {
          bind: (...args: unknown[]) => ({
            run: async () => {
              if (/DELETE FROM agent_enrollments/.test(sql)) deleted.push(String(args[0]));
              return { meta: { changes: 1 } };
            },
            all: async () => ({ results: [] as unknown[] }),
            first: async () => null,
          }),
        };
      },
    };
    const store = new D1Store(fakeDb as never);
    await store.agentEnroll({ householdHash: HOUSEHOLD_HASH, householdId: HH, verifier: AGENT_VERIFIER, updatedAt: new Date().toISOString() });
    expect(await store.agentGetByVerifier(AGENT_VERIFIER)).toMatchObject({ householdId: HH });
    expect(await store.agentRevokeByHash(HOUSEHOLD_HASH)).toBe(true);
    expect(deleted).toEqual([HOUSEHOLD_HASH]);
    expect(await store.agentGetByVerifier(AGENT_VERIFIER)).toBeNull();
    expect(await store.agentGetByLabel(HH)).toBeNull();
    expect(await store.agentRevokeByHash(HOUSEHOLD_HASH)).toBe(false);
  });

  it('legacy v1 sync pull/push honor the enrolled household', async () => {
    const { app } = agentApp();
    await enroll(app, HOUSEHOLD_HASH, HH, AGENT_VERIFIER);
    const h = agentHeaders(AGENT_TOKEN);
    // push without a household label is rejected (explicit scope required)
    const noHh = await app.request('/api/sync/push', {
      method: 'POST',
      headers: h,
      body: JSON.stringify([{ id: '12345678-1234-4234-8234-000000000001', updatedAt: '2026-11-27T12:00:00.000Z', deviceId: 'a', entity: 'recipe', payload: { title: 'x' } }]),
    });
    expect(noHh.status).toBe(403);
    // push for another household is rejected
    const other = await app.request('/api/sync/push', {
      method: 'POST',
      headers: h,
      body: JSON.stringify([{ id: '12345678-1234-4234-8234-000000000002', updatedAt: '2026-11-27T12:00:00.000Z', deviceId: 'a', entity: 'recipe', payload: { title: 'x', householdId: 'hh-other' } }]),
    });
    expect(other.status).toBe(403);
    // matching push works and pulls back scoped
    const ok = await app.request('/api/sync/push', {
      method: 'POST',
      headers: h,
      body: JSON.stringify([{ id: '12345678-1234-4234-8234-000000000003', updatedAt: '2026-11-27T12:00:00.000Z', deviceId: 'a', entity: 'recipe', payload: { title: 'Scoped', householdId: HH, ingredients: [], steps: [] } }]),
    });
    expect(ok.status).toBe(200);
    const pull = (await (await app.request('/api/sync/pull?since=1970-01-01T00:00:00.000Z', { headers: h })).json()) as { payload: { householdId: string } }[];
    expect(pull.length).toBeGreaterThan(0);
    for (const e of pull) expect(e.payload.householdId).toBe(HH);
  });

  it('agent cannot overwrite another household row by reusing its id (403)', async () => {
    const { app } = agentApp();
    await enroll(app, HOUSEHOLD_HASH, HH, AGENT_VERIFIER);
    const id = '22222222-2222-4222-8222-222222222222';
    const foreign = {
      id, updatedAt: '2026-11-27T12:00:00.000Z', deviceId: 'dev', entity: 'recipe',
      payload: { title: 'Foreign', householdId: 'hh-other', ingredients: [], steps: [] },
    };
    // Seed the foreign row via the anonymous dev path (no agent header).
    const seed = await app.request('/api/sync/push', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify([foreign]),
    });
    expect(seed.status).toBe(200);
    // Same id with the agent's own label → 403, row untouched.
    const overwrite = await app.request('/api/sync/push', {
      method: 'POST',
      headers: agentHeaders(AGENT_TOKEN),
      body: JSON.stringify([{ ...foreign, updatedAt: '2026-11-28T12:00:00.000Z', payload: { ...foreign.payload, householdId: HH } }]),
    });
    expect(overwrite.status).toBe(403);
    // Same id with a matching label still merges (no false positive).
    const own = await app.request('/api/sync/push', {
      method: 'POST',
      headers: agentHeaders(AGENT_TOKEN),
      body: JSON.stringify([{ ...foreign, id: '33333333-3333-4333-8333-333333333333', payload: { ...foreign.payload, householdId: HH } }]),
    });
    expect(own.status).toBe(200);
  });

  it('enrollments survive a D1 hydrate (and work pre-migration)', async () => {
    // Pre-migration fake: every SQL op throws; memory fallback must hold.
    const throwing = { prepare() { throw new Error('no such table: agent_enrollments'); } };
    const store = new D1Store(throwing as never);
    await store.agentEnroll({ householdHash: HOUSEHOLD_HASH, householdId: HH, verifier: AGENT_VERIFIER, updatedAt: new Date().toISOString() });
    expect(await store.agentGetByVerifier(AGENT_VERIFIER)).toMatchObject({ householdId: HH });
    expect(await store.agentGetByVerifier('0'.repeat(64))).toBeNull();
    // Hydrate round-trip: seed the enrollments table in a fake D1 and assert
    // the rows (and the label index) load.
    const row = {
      household_hash: HOUSEHOLD_HASH, household_id: HH,
      verifier: AGENT_VERIFIER, updated_at: '2026-11-27T12:00:00.000Z',
    };
    const seeded = {
      prepare(sql: string) {
        return { all: async () => ({ results: /FROM\s+agent_enrollments/.test(sql) ? [row] : [] }) };
      },
    };
    const store2 = new D1Store(seeded as never);
    await store2.hydrate();
    expect(await store2.agentGetByVerifier(AGENT_VERIFIER)).toMatchObject({ householdId: HH, householdHash: HOUSEHOLD_HASH });
    expect(await store2.agentGetByLabel(HH)).toMatchObject({ householdHash: HOUSEHOLD_HASH });
  });

  it('agent v2 bucket scope: cross-bucket reads 404, writes 403, own bucket works', async () => {
    const { app, store } = agentApp();
    await enroll(app, HOUSEHOLD_HASH, HH, AGENT_VERIFIER);
    const h = agentHeaders(AGENT_TOKEN);
    const other = 'e'.repeat(64); // well-formed but not the enrolled bucket
    // Cross-bucket read → 404 (no existence oracle).
    expect((await app.request(`/api/v2/sync/${other}`, { headers: h })).status).toBe(404);
    // Cross-bucket PUT → 403, nothing stored anywhere.
    const d = await deriveAll(SYNC_CODE, HH);
    const env = await encryptEnvelope(d.dataKey, {
      kid: d.kid,
      householdHash: d.householdHash,
      id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaa01',
      entity: 'recipe',
      title: 'Cross Bucket Broth',
    });
    expect(
      (await app.request(`/api/v2/sync/${other}`, { method: 'PUT', headers: h, body: JSON.stringify([env]) })).status,
    ).toBe(403);
    expect(await store.e2eList(other, new Date(0).toISOString())).toEqual([]);
    expect(await store.e2eList(HOUSEHOLD_HASH, new Date(0).toISOString())).toEqual([]);
    // Seed the OWN bucket, then cross-bucket DELETE → 403, own bucket intact.
    expect(
      (await app.request(`/api/v2/sync/${HOUSEHOLD_HASH}`, { method: 'PUT', headers: h, body: JSON.stringify([env]) })).status,
    ).toBe(200);
    expect((await app.request(`/api/v2/sync/${other}`, { method: 'DELETE', headers: h })).status).toBe(403);
    expect(await store.e2eList(HOUSEHOLD_HASH, new Date(0).toISOString())).toHaveLength(1);
    // Own bucket still works with the token: read 200, wipe 200.
    expect((await app.request(`/api/v2/sync/${HOUSEHOLD_HASH}`, { headers: h })).status).toBe(200);
    expect((await app.request(`/api/v2/sync/${HOUSEHOLD_HASH}`, { method: 'DELETE', headers: h })).status).toBe(200);
    expect(await store.e2eList(HOUSEHOLD_HASH, new Date(0).toISOString())).toEqual([]);
  });

  it('POST /share/cookbook rejects foreign recipeIds for agents (404)', async () => {
    const { app, store } = agentApp();
    await enroll(app, HOUSEHOLD_HASH, HH, AGENT_VERIFIER);
    const h = agentHeaders(AGENT_TOKEN);
    const own = (await (
      await app.request('/api/recipes', {
        method: 'POST',
        headers: h,
        body: JSON.stringify({ title: 'Own Shareable', householdId: HH }),
      })
    ).json()) as { id: string };
    const seeded = await app.request('/api/recipes', {
      method: 'POST',
      headers: { 'x-role': 'owner', 'content-type': 'application/json' },
      body: JSON.stringify({ title: 'Foreign', householdId: 'hh-other' }),
    });
    expect(seeded.status).toBe(201);
    const foreignId = ((await seeded.json()) as { id: string }).id;
    // Foreign recipe in an agent share → 404, nothing created.
    const bad = await app.request('/api/share/cookbook', {
      method: 'POST',
      headers: h,
      body: JSON.stringify({ householdId: HH, recipeIds: [foreignId] }),
    });
    expect(bad.status).toBe(404);
    // Own recipe shares fine.
    const ok = await app.request('/api/share/cookbook', {
      method: 'POST',
      headers: h,
      body: JSON.stringify({ householdId: HH, recipeIds: [own.id] }),
    });
    expect(ok.status).toBe(201);
    void store;
  });
});

describe('blind server: real AES-GCM round-trip, server learns nothing', () => {
  it('PUT opaque envelope, pull, decrypt client-side; store+logs hold no plaintext', async () => {
    const { app, store } = agentApp();
    const d = await deriveAll(SYNC_CODE, HH);
    const MARKER = 'SUPER-SEKRIT-PLAINTEXT-MARKER-9f8e7d6c5b4a';
    const env = await encryptEnvelope(d.dataKey, {
      kid: d.kid,
      householdHash: d.householdHash,
      id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      entity: 'recipe',
      title: `Agent ${MARKER} Soup`,
    });

    const lines: string[] = [];
    const orig = console.log;
    console.log = (...args: unknown[]) => { lines.push(args.map((a) => String(a)).join(' ')); };
    try {
      const put = await app.request(`/api/v2/sync/${HOUSEHOLD_HASH}`, {
        method: 'PUT',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify([env]),
      });
      expect(put.status).toBe(200);
      expect(await put.json()).toEqual({ stored: [env.id] });
      const pull = (await (await app.request(`/api/v2/sync/${HOUSEHOLD_HASH}`)).json()) as EncryptedEnvelope[];
      expect(pull).toHaveLength(1);
      expect(await decryptTitle(d.dataKey, pull[0]!)).toBe(`Agent ${MARKER} Soup`);
      const wipe = await app.request(`/api/v2/sync/${HOUSEHOLD_HASH}`, { method: 'DELETE' });
      expect(wipe.status).toBe(200);
    } finally {
      console.log = orig;
    }

    // Server-side memory holds only opaque bytes for this bucket.
    const blobs: EncryptedEnvelope[] = [];
    for (const bucket of store.e2eBlobs.values()) blobs.push(...bucket.values());
    const dumped = JSON.stringify(blobs);
    expect(dumped).not.toContain(MARKER);
    expect(dumped).not.toContain('Soup');
    // Logs: full hash never, prefix only; no marker, no ciphertext field.
    const all = lines.join('\n');
    expect(lines.length).toBeGreaterThan(0);
    expect(all).not.toContain(MARKER);
    expect(all).not.toContain(HOUSEHOLD_HASH);
    expect(all).toContain(HOUSEHOLD_HASH.slice(0, 8));
    expect(all).not.toContain('ciphertext');
  });

  it('a wrong key addresses an empty bucket and cannot enroll the victim verifier', async () => {
    const { app } = agentApp();
    await enroll(app, HOUSEHOLD_HASH, HH, AGENT_VERIFIER);
    const wrong = await deriveAll('test-only-vector-sync-code-9999', HH);
    // Different key → different bucket → empty pull (no oracle for victims).
    const pull = await app.request(`/api/v2/sync/${wrong.householdHash}`);
    expect(pull.status).toBe(200);
    expect(await pull.json()).toEqual([]);
    // The wrong key cannot enroll the victim's label either: its hash differs
    // from the bound one and it holds no valid token → 409 with no header…
    const squat = await enroll(app, wrong.householdHash, HH, wrong.verifier);
    expect(squat.status).toBe(409);
    // …and 401 carrying its own (unknown) token, rejected before the handler.
    const squatAuth = await app.request('/api/agent/enroll', {
      method: 'POST',
      headers: agentHeaders(wrong.token),
      body: JSON.stringify({ householdHash: wrong.householdHash, householdId: HH, verifier: wrong.verifier }),
    });
    expect(squatAuth.status).toBe(401);
    // The wrong-key token is unknown to the server → 401 on every v1 route.
    for (const [m, p] of [['GET', '/api/recipes'], ['POST', '/api/recipes'], ['GET', '/api/agent/status']] as const) {
      const res = await app.request(p, {
        method: m,
        headers: agentHeaders(wrong.token),
        ...(m === 'POST' ? { body: JSON.stringify({ title: 'x', householdId: HH }) } : {}),
      });
      expect(res.status).toBe(401);
    }
  });
});

describe('MCP on the same Worker', () => {
  const rpc = (method: string, params?: unknown, id: number | string = 1) => ({
    jsonrpc: '2.0',
    id,
    method,
    ...(params !== undefined ? { params } : {}),
  });
  async function call(app: ReturnType<typeof createApp>, body: unknown, token?: string) {
    return app.request('/api/mcp', {
      method: 'POST',
      headers: { 'content-type': 'application/json', ...(token ? { [AGENT_TOKEN_HEADER]: token } : {}) },
      body: JSON.stringify(body),
    });
  }

  it('initialize + tools/list serve the versioned contracts', async () => {
    const { app } = agentApp();
    await enroll(app, HOUSEHOLD_HASH, HH, AGENT_VERIFIER);
    const init = await call(app, rpc('initialize'), AGENT_TOKEN);
    expect(init.status).toBe(200);
    const ij = (await init.json()) as { result: { protocolVersion: string; serverInfo: { name: string } } };
    expect(ij.result.protocolVersion).toMatch(/^\d{4}-\d{2}-\d{2}$/);
    expect(ij.result.serverInfo.name).toBe('keep-cooking-agent');
    const list = (await (await call(app, rpc('tools/list'), AGENT_TOKEN)).json()) as {
      result: { tools: { name: string; inputSchema: unknown }[] };
    };
    expect(list.result.tools.map((t) => t.name)).toEqual(mcpTools.tools.map((t) => t.name));
    for (const t of list.result.tools) expect(t.inputSchema).toBeDefined();
  });

  it('server/discover advertises the MCP subset + cache hints; tools/list carries them too', async () => {
    const { app } = agentApp();
    await enroll(app, HOUSEHOLD_HASH, HH, AGENT_VERIFIER);
    const disc = (await (await call(app, rpc('server/discover'), AGENT_TOKEN)).json()) as {
      result: {
        resultType: string;
        supportedVersions: string[];
        capabilities: { tools: object };
        _meta: { 'io.modelcontextprotocol/serverInfo': { name: string; version: string } };
        instructions: string;
        ttlMs: number;
        cacheScope: string;
      };
    };
    expect(disc.result.resultType).toBe('complete');
    expect(disc.result.supportedVersions).toEqual(['2026-07-28']);
    expect(disc.result.capabilities).toEqual({ tools: {} });
    expect(disc.result._meta['io.modelcontextprotocol/serverInfo']).toMatchObject({
      name: 'keep-cooking-agent',
      version: '0.1.0',
    });
    expect(typeof disc.result.instructions).toBe('string');
    expect(disc.result.instructions.length).toBeGreaterThan(0);
    expect(disc.result.ttlMs).toBe(3600000);
    expect(disc.result.cacheScope).toBe('private');
    // Handshake stays public like initialize.
    const anon = (await (await call(app, rpc('server/discover'))).json()) as { result: { resultType: string } };
    expect(anon.result.resultType).toBe('complete');
    // Legacy initialize is unchanged (2025-client compat).
    const init = (await (await call(app, rpc('initialize'), AGENT_TOKEN)).json()) as {
      result: { protocolVersion: string };
    };
    expect(init.result.protocolVersion).toBe('2026-07-28');
    // tools/list carries the same cache fields alongside the tools array.
    const list = (await (await call(app, rpc('tools/list'), AGENT_TOKEN)).json()) as {
      result: { resultType: string; tools: unknown[]; ttlMs: number; cacheScope: string };
    };
    expect(Array.isArray(list.result.tools)).toBe(true);
    expect(list.result.resultType).toBe('complete');
    expect(list.result.ttlMs).toBe(3600000);
    expect(list.result.cacheScope).toBe('private');
  });

  it('id-less non-notification requests get 202 with no body (not id:null)', async () => {
    const { app } = agentApp();
    await enroll(app, HOUSEHOLD_HASH, HH, AGENT_VERIFIER);
    const res = await call(app, { jsonrpc: '2.0', method: 'tools/list' }, AGENT_TOKEN);
    expect(res.status).toBe(202);
    expect(await res.text()).toBe('');
  });

  it('tools/call recipe_create → get → list without any header stub', async () => {
    const { app } = agentApp();
    await enroll(app, HOUSEHOLD_HASH, HH, AGENT_VERIFIER);
    const created = (await (
      await call(app, rpc('tools/call', { name: 'recipe_create', arguments: { title: 'MCP Risotto', servings: 2 } }), AGENT_TOKEN)
    ).json()) as { result: { content: { text: string }[] } };
    const recipe = JSON.parse(created.result.content[0]!.text) as { id: string; title: string };
    expect(recipe.title).toBe('MCP Risotto');
    const got = (await (
      await call(app, rpc('tools/call', { name: 'recipe_get', arguments: { id: recipe.id } }), AGENT_TOKEN)
    ).json()) as { result: { content: { text: string }[] } };
    expect(JSON.parse(got.result.content[0]!.text)).toMatchObject({ id: recipe.id });
    const listed = (await (
      await call(app, rpc('tools/call', { name: 'recipe_list', arguments: {} }), AGENT_TOKEN)
    ).json()) as { result: { content: { text: string }[] } };
    expect((JSON.parse(listed.result.content[0]!.text) as { id: string }[]).map((r) => r.id)).toEqual([recipe.id]);
  });

  it('auth failures are 401; unknown tool/method are protocol errors; tool errors are isError', async () => {
    const { app } = agentApp();
    await enroll(app, HOUSEHOLD_HASH, HH, AGENT_VERIFIER);
    const noAuth = await call(app, rpc('tools/list'));
    expect(noAuth.status).toBe(401);
    const badTool = (await (await call(app, rpc('tools/call', { name: 'nope', arguments: {} }), AGENT_TOKEN)).json()) as {
      error: { code: number };
    };
    expect(badTool.error.code).toBe(-32601);
    const badMethod = (await (await call(app, rpc('frobnicator'), AGENT_TOKEN)).json()) as { error: { code: number } };
    expect(badMethod.error.code).toBe(-32601);
    const missing = (await (
      await call(app, rpc('tools/call', { name: 'recipe_get', arguments: { id: '00000000-0000-4000-8000-000000000000' } }), AGENT_TOKEN)
    ).json()) as { result: { isError: boolean; content: { text: string }[] } };
    expect(missing.result.isError).toBe(true);
  });

  it('MCP writes are household-scoped and sync_push stays blind', async () => {
    const { app, store } = agentApp();
    await enroll(app, HOUSEHOLD_HASH, HH, AGENT_VERIFIER);
    // cross-household write via MCP → isError, nothing stored
    const bad = (await (
      await call(app, rpc('tools/call', { name: 'recipe_create', arguments: { title: 'sneaky', householdId: 'hh-other' } }), AGENT_TOKEN)
    ).json()) as { result: { isError: boolean } };
    expect(bad.result.isError).toBe(true);
    expect(await store.listRecipes('hh-other')).toEqual([]);
    // blind sync_push via MCP with a real envelope
    const d = await deriveAll(SYNC_CODE, HH);
    const env = await encryptEnvelope(d.dataKey, {
      kid: d.kid,
      householdHash: d.householdHash,
      id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      entity: 'recipe',
      title: 'MCP Blind Curry',
    });
    const pushed = (await (
      await call(app, rpc('tools/call', { name: 'sync_push', arguments: { envelopes: [env] } }), AGENT_TOKEN)
    ).json()) as { result: { content: { text: string }[] } };
    expect(JSON.parse(pushed.result.content[0]!.text)).toEqual({ stored: [env.id] });
    const pulled = (await (
      await call(app, rpc('tools/call', { name: 'sync_pull', arguments: {} }), AGENT_TOKEN)
    ).json()) as { result: { content: { text: string }[] } };
    const envs = JSON.parse(pulled.result.content[0]!.text) as EncryptedEnvelope[];
    expect(envs).toHaveLength(1);
    expect(await decryptTitle(d.dataKey, envs[0]!)).toBe('MCP Blind Curry');
  });

  it('inherited handler names do not resolve (prototype pollution guard)', async () => {
    const { app } = agentApp();
    await enroll(app, HOUSEHOLD_HASH, HH, AGENT_VERIFIER);
    for (const name of ['constructor', 'toString', 'hasOwnProperty']) {
      const res = (await (
        await call(app, rpc('tools/call', { name, arguments: {} }), AGENT_TOKEN)
      ).json()) as { error: { code: number } };
      expect(res.error.code).toBe(-32601);
    }
  });

  it('missing jsonrpc is an invalid request; notifications are 202 with no body', async () => {
    const { app } = agentApp();
    await enroll(app, HOUSEHOLD_HASH, HH, AGENT_VERIFIER);
    const bad = (await (
      await call(app, { method: 'tools/list', id: 1 }, AGENT_TOKEN)
    ).json()) as { error: { code: number } };
    expect(bad.error.code).toBe(-32600);
    const note = await call(app, { jsonrpc: '2.0', method: 'notifications/initialized' }, AGENT_TOKEN);
    expect(note.status).toBe(202);
    expect(await note.text()).toBe('');
  });

  it('notifications carrying an id are acknowledged, not dropped', async () => {
    const { app } = agentApp();
    await enroll(app, HOUSEHOLD_HASH, HH, AGENT_VERIFIER);
    // Real clients send id-bearing notifications: ack with an empty result
    // (200) so nobody hangs waiting for a reply.
    const note = await call(app, { jsonrpc: '2.0', id: 7, method: 'notifications/initialized' }, AGENT_TOKEN);
    expect(note.status).toBe(200);
    expect(await note.json()).toEqual({ jsonrpc: '2.0', id: 7, result: {} });
  });

  it('photos_sign enforces the integer ttl contract [1, 899]', async () => {
    const { app } = agentApp();
    await enroll(app, HOUSEHOLD_HASH, HH, AGENT_VERIFIER);
    for (const ttl of [0, -5, 1.5, 900, 100000]) {
      const res = (await (
        await call(app, rpc('tools/call', { name: 'photos_sign', arguments: { key: 'photos/x/thumb.jpg', ttl } }), AGENT_TOKEN)
      ).json()) as { result: { isError: boolean; content: { text: string }[] } };
      expect(res.result.isError).toBe(true);
      expect(res.result.content[0]!.text).toContain('ttl');
    }
    // In-range ttl signs fine.
    const ok = (await (
      await call(app, rpc('tools/call', { name: 'photos_sign', arguments: { key: 'photos/x/thumb.jpg', ttl: 60 } }), AGENT_TOKEN)
    ).json()) as { result: { isError?: boolean; content: { text: string }[] } };
    expect(ok.result.isError ?? false).toBe(false);
    expect(JSON.parse(ok.result.content[0]!.text)).toMatchObject({ key: 'photos/x/thumb.jpg' });
  });

  it('sync_push validation failures carry field details', async () => {
    const { app } = agentApp();
    await enroll(app, HOUSEHOLD_HASH, HH, AGENT_VERIFIER);
    const res = (await (
      await call(app, rpc('tools/call', { name: 'sync_push', arguments: { envelopes: [{ nope: true }] } }), AGENT_TOKEN)
    ).json()) as { result: { isError: boolean; content: { text: string }[] } };
    expect(res.result.isError).toBe(true);
    const text = res.result.content[0]!.text;
    expect(text).toContain('validation failed');
    expect(text).toContain('ciphertext');
  });

  it('share_cookbook enforces bounds and household ownership', async () => {
    const { app } = agentApp();
    await enroll(app, HOUSEHOLD_HASH, HH, AGENT_VERIFIER);
    const created = (await (
      await call(app, rpc('tools/call', { name: 'recipe_create', arguments: { title: 'Shareable', servings: 2 } }), AGENT_TOKEN)
    ).json()) as { result: { content: { text: string }[] } };
    const ownId = (JSON.parse(created.result.content[0]!.text) as { id: string }).id;
    const ok = (await (
      await call(app, rpc('tools/call', { name: 'share_cookbook', arguments: { recipeIds: [ownId] } }), AGENT_TOKEN)
    ).json()) as { result: { isError?: boolean; content: { text: string }[] } };
    expect(ok.result.isError ?? false).toBe(false);
    // expiresInDays 0 / negative / fractional / huge are all rejected.
    for (const expiresInDays of [0, -5, 1.5, 100000]) {
      const bad = (await (
        await call(app, rpc('tools/call', { name: 'share_cookbook', arguments: { recipeIds: [ownId], expiresInDays } }), AGENT_TOKEN)
      ).json()) as { result: { isError: boolean } };
      expect(bad.result.isError).toBe(true);
    }
    // A recipe from another household cannot be shared into this one.
    const seeded = await app.request('/api/recipes', {
      method: 'POST',
      headers: { 'x-role': 'owner', 'content-type': 'application/json' },
      body: JSON.stringify({ title: 'Foreign', householdId: 'hh-other' }),
    });
    const foreignId = ((await seeded.json()) as { id: string }).id;
    const cross = (await (
      await call(app, rpc('tools/call', { name: 'share_cookbook', arguments: { recipeIds: [foreignId] } }), AGENT_TOKEN)
    ).json()) as { result: { isError: boolean } };
    expect(cross.result.isError).toBe(true);
  });

  it('GET /mcp is 405', async () => {
    const { app } = agentApp();
    expect((await app.request('/api/mcp')).status).toBe(405);
  });

  it('D1 unique bindings (label + verifier) surface as 409; rotations still land', async () => {
    // Fake D1 enforcing both unique indexes with D1-style error text, shared
    // by two isolates: the second one starts with empty memory (stale).
    type Row = { household_hash: string; household_id: string; verifier: string; updated_at: string };
    const rows = new Map<string, Row>();
    const fakeDb = {
      prepare(sql: string) {
        return {
          bind: (...args: unknown[]) => ({
            run: async () => {
              if (/INSERT INTO agent_enrollments/.test(sql)) {
                const [hh, label, verifier, ts] = args as string[];
                for (const r of rows.values()) {
                  if (r.household_hash === hh) continue; // self-update never conflicts
                  if (r.verifier === verifier) {
                    throw new Error('D1_ERROR: UNIQUE constraint failed: agent_enrollments.verifier: SQLITE_CONSTRAINT_UNIQUE');
                  }
                  if (r.household_id === label) {
                    throw new Error('D1_ERROR: UNIQUE constraint failed: agent_enrollments.household_id: SQLITE_CONSTRAINT_UNIQUE');
                  }
                }
                rows.set(hh, { household_hash: hh, household_id: label, verifier, updated_at: ts });
                return { meta: { changes: 1 } };
              }
              if (/DELETE FROM agent_enrollments/.test(sql)) {
                rows.delete(String(args[0]));
                return { meta: { changes: 1 } };
              }
              return { meta: { changes: 1 } };
            },
            all: async () => ({ results: [] as unknown[] }),
            first: async () => {
              if (/WHERE household_hash/.test(sql)) {
                const r = rows.get(String(args[0]));
                return r ? { ...r } : null;
              }
              return null;
            },
          }),
        };
      },
    };
    const fresh = new D1Store(fakeDb as never);
    const t0 = '2026-11-27T12:00:00.000Z';
    const t1 = '2026-11-27T12:00:01.000Z';
    const t2 = '2026-11-27T12:00:02.000Z';
    // First binding lands.
    await fresh.agentEnroll({ householdHash: HOUSEHOLD_HASH, householdId: HH, verifier: AGENT_VERIFIER, updatedAt: t0 });
    // Same label + different hash on a STALE isolate (empty memory, same D1)
    // hits the household_id unique index → 409, not 500.
    const stale = new D1Store(fakeDb as never);
    try {
      await stale.agentEnroll({ householdHash: 'f'.repeat(64), householdId: HH, verifier: 'c'.repeat(64), updatedAt: t1 });
      expect.unreachable('duplicate-label-different-hash insert must throw');
    } catch (e) {
      expect((e as { status?: number }).status).toBe(409);
    }
    // Same verifier + different hash on a stale isolate → 409 too.
    const stale2 = new D1Store(fakeDb as never);
    try {
      await stale2.agentEnroll({ householdHash: 'e'.repeat(64), householdId: 'hh-stale', verifier: AGENT_VERIFIER, updatedAt: t1 });
      expect.unreachable('duplicate-verifier-different-hash insert must throw');
    } catch (e) {
      expect((e as { status?: number }).status).toBe(409);
    }
    // Same-hash rotation (new verifier, newer row) still lands on both.
    await fresh.agentEnroll({ householdHash: HOUSEHOLD_HASH, householdId: HH, verifier: 'd'.repeat(64), updatedAt: t2 });
    expect(await fresh.agentGetByVerifier('d'.repeat(64))).toMatchObject({ householdId: HH });
    expect(await fresh.agentGetByVerifier(AGENT_VERIFIER)).toBeNull();
  });

  it('GET /photos/dl verifies the signature and streams R2 bytes', async () => {
    const { signKey } = await import('../src/photos');
    const store = new MemoryStore();
    const jpeg = new TextEncoder().encode('fake-jpeg-bytes');
    const photosFetcher = async (key: string) =>
      key === `photos/r1/thumb.jpg` ? { body: jpeg, contentType: 'image/jpeg' } : null;
    const secret = 'test-secret';
    const app = createApp(store, { baseUrl: 'https://api.keepcooking.local', secret, photosFetcher });
    // Mint via /photos/sign (dev: no token needed), then download.
    const signed = (await (
      await app.request(`/api/photos/sign?key=${encodeURIComponent('photos/r1/thumb.jpg')}`)
    ).json()) as { url: string };
    expect(signed.url).toContain('/api/photos/dl?');
    expect(signed.url).not.toContain('/api/photos/sign?');
    const q = new URL(signed.url).search;
    const good = await app.request(`/api/photos/dl${q}`);
    expect(good.status).toBe(200);
    expect(good.headers.get('content-type')).toContain('image/jpeg');
    expect(await good.text()).toBe('fake-jpeg-bytes');
    // Tampered sig → 403; missing params → 400.
    const tampered = q.replace(/sig=[^&]*/, 'sig=deadbeef');
    expect((await app.request(`/api/photos/dl${tampered}`)).status).toBe(403);
    expect((await app.request('/api/photos/dl?key=x')).status).toBe(400);
    // Signed key with no object → 404.
    const missing = await signKey('photos/nope/thumb.jpg', { secret, baseUrl: 'https://api.keepcooking.local' });
    expect((await app.request(`/api/photos/dl${new URL(missing.url).search}`)).status).toBe(404);
    // Expired signature → 403 (minted in the past).
    const old = await signKey('photos/r1/thumb.jpg', {
      secret,
      baseUrl: 'https://api.keepcooking.local',
      nowMs: Date.now() - 3600_000,
    });
    expect((await app.request(`/api/photos/dl${new URL(old.url).search}`)).status).toBe(403);
    // No fetcher wired (dev without R2) → 404 even with a valid signature.
    const bare = createApp(new MemoryStore(), { baseUrl: 'https://api.keepcooking.local', secret });
    expect((await bare.request(`/api/photos/dl${q}`)).status).toBe(404);
  });

  it('MCP photos_sign targets the /photos/dl byte route', async () => {
    const { app } = agentApp();
    await enroll(app, HOUSEHOLD_HASH, HH, AGENT_VERIFIER);
    const out = (await (
      await call(app, rpc('tools/call', { name: 'photos_sign', arguments: { key: 'photos/x/thumb.jpg' } }), AGENT_TOKEN)
    ).json()) as { result: { content: { text: string }[] } };
    const signed = JSON.parse(out.result.content[0]!.text) as { url: string };
    expect(signed.url).toContain('/api/photos/dl?');
    expect(signed.url).not.toContain('/api/photos/sign?');
  });
});

describe('0004 migration is wired into every deploy path', () => {
  it('deploy.yml, package.json scripts, and deploy-backend.sh all apply 0004 after 0003', async () => {
    const { readFileSync } = await import('node:fs');
    const { join, dirname } = await import('node:path');
    const { fileURLToPath } = await import('node:url');
    const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
    // CI deploy delegates to the package.json chain (single source).
    const deployYml = readFileSync(join(root, '.github/workflows/deploy.yml'), 'utf8');
    expect(deployYml).toContain('npm run db:apply:remote');
    // Canonical chain 0001 → 0002 → 0003 (devices) → 0004 (agents), in order.
    const pkg = JSON.parse(readFileSync(join(root, 'api/package.json'), 'utf8')) as { scripts: Record<string, string> };
    for (const s of ['db:apply:local', 'db:apply:remote']) {
      const script = pkg.scripts[s];
      const i1 = script.indexOf('0001_init.sql');
      const i2 = script.indexOf('0002_e2e_blobs.sql');
      const i3 = script.indexOf('0003_device_keys.sql');
      const i4 = script.indexOf('0004_agent_enrollments.sql');
      expect(i1).toBeGreaterThanOrEqual(0);
      expect(i2).toBeGreaterThan(i1);
      expect(i3).toBeGreaterThan(i2);
      expect(i4).toBeGreaterThan(i3);
    }
    // Fresh BYO-backend script.
    expect(readFileSync(join(root, 'scripts/deploy-backend.sh'), 'utf8')).toContain('0004_agent_enrollments.sql');
  });
});
