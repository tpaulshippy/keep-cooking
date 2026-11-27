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
import { householdHash, type EncryptedEnvelope } from '../src/e2e';
import { AGENT_TOKEN_HEADER } from '../src/agent';
import { deriveAll as deriveAllDocs } from '../../docs/agents/lib.mjs';
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
  opts: { kid: string; householdHash: string; id: string; entity: 'recipe'; title: string },
): Promise<EncryptedEnvelope> {
  const payload = {
    id: opts.id,
    updatedAt: '2026-11-27T12:00:00.000Z',
    deviceId: 'agent-test',
    deleted: false,
    entity: 'recipe' as const,
    payload: { id: opts.id, title: opts.title, servings: 2, householdId: HH, ingredients: [], steps: [] },
  };
  const key = await crypto.subtle.importKey('raw', dataKey as unknown as ArrayBuffer, 'AES-GCM', false, ['encrypt']);
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const ct = await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce as unknown as ArrayBuffer }, key, enc.encode(JSON.stringify(payload)));
  // Wire format is STANDARD base64 with padding (see encryptedEnvelopeSchema).
  const b64 = (a: Uint8Array | ArrayBuffer) => Buffer.from(a as Uint8Array).toString('base64');
  return {
    v: 2,
    alg: 'AES-GCM-256',
    kid: opts.kid,
    householdHash: opts.householdHash,
    id: opts.id,
    entity: 'recipe',
    updatedAt: '2026-11-27T12:00:00.000Z',
    deviceId: 'agent-test',
    deleted: false,
    nonce: b64(nonce),
    ciphertext: b64(ct),
  };
}

async function decryptTitle(dataKey: Uint8Array, env: EncryptedEnvelope): Promise<string> {
  const key = await crypto.subtle.importKey('raw', dataKey as unknown as ArrayBuffer, 'AES-GCM', false, ['decrypt']);
  const pt = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: unb64u(env.nonce) as unknown as ArrayBuffer },
    key,
    unb64u(env.ciphertext),
  );
  const wire = JSON.parse(new TextDecoder().decode(pt)) as { payload: { title: string } };
  return wire.payload.title;
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
  return app.request('/agent/enroll', {
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
});

describe('agent enroll + key-only REST', () => {
  it('enroll then status with only the key-derived token', async () => {
    const { app } = agentApp();
    const res = await enroll(app, HOUSEHOLD_HASH, HH, AGENT_VERIFIER);
    expect(res.status).toBe(201);
    expect(await res.json()).toEqual({ ok: true, householdId: HH, householdHash: HOUSEHOLD_HASH, hashPrefix8: HOUSEHOLD_HASH.slice(0, 8) });
    const st = await app.request('/agent/status', { headers: agentHeaders(AGENT_TOKEN) });
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
      const res = await app.request('/agent/enroll', {
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
    const created = await app.request('/recipes', {
      method: 'POST',
      headers: h,
      body: JSON.stringify({ title: 'Agent Gumbo', servings: 4, householdId: HH }),
    });
    expect(created.status).toBe(201);
    const recipe = (await created.json()) as { id: string };
    // list is scoped to the enrolled household
    const list = (await (await app.request('/recipes', { headers: h })).json()) as { id: string }[];
    expect(list.map((r) => r.id)).toEqual([recipe.id]);
    // plan a week entry
    const plan = await app.request('/plans', {
      method: 'POST',
      headers: h,
      body: JSON.stringify({ date: '2026-12-01', meal: 'dinner', recipeId: recipe.id, householdId: HH }),
    });
    expect(plan.status).toBe(201);
    // grocery list from the recipe
    const gl = await app.request('/lists', {
      method: 'POST',
      headers: h,
      body: JSON.stringify({ name: 'Week groceries', householdId: HH, items: [{ name: 'okra' }] }),
    });
    expect(gl.status).toBe(201);
    // update + delete
    const upd = await app.request(`/recipes/${recipe.id}`, {
      method: 'PUT',
      headers: h,
      body: JSON.stringify({ title: 'Agent Gumbo v2', servings: 4, householdId: HH }),
    });
    expect(upd.status).toBe(200);
    const del = await app.request(`/recipes/${recipe.id}`, { method: 'DELETE', headers: h });
    expect(del.status).toBe(204);
  });

  it('agent works in prod (no header-role escalation path needed)', async () => {
    const { app } = prodAgentApp();
    await enroll(app, HOUSEHOLD_HASH, HH, AGENT_VERIFIER);
    const res = await app.request('/recipes', {
      method: 'POST',
      headers: agentHeaders(AGENT_TOKEN),
      body: JSON.stringify({ title: 'Prod Agent Soup', servings: 2, householdId: HH }),
    });
    expect(res.status).toBe(201);
  });

  it('unknown or malformed token is 401 (fail closed)', async () => {
    const { app } = agentApp();
    await enroll(app, HOUSEHOLD_HASH, HH, AGENT_VERIFIER);
    const unknown = await app.request('/recipes', {
      method: 'POST',
      headers: agentHeaders(await randomToken()),
      body: JSON.stringify({ title: 'x', householdId: HH }),
    });
    expect(unknown.status).toBe(401);
    for (const bad of ['short', 'Bearer abc', 'x'.repeat(43)]) {
      const res = await app.request('/recipes', {
        method: 'POST',
        headers: agentHeaders(bad),
        body: JSON.stringify({ title: 'x', householdId: HH }),
      });
      expect(res.status).toBe(401);
    }
    // /health stays open even with a bad token (liveness probe).
    expect((await app.request('/health', { headers: agentHeaders('short') })).status).toBe(200);
  });

  it('cross-household access is rejected (403 writes, 404 reads)', async () => {
    const { app } = agentApp();
    await enroll(app, HOUSEHOLD_HASH, HH, AGENT_VERIFIER);
    const h = agentHeaders(AGENT_TOKEN);
    // write naming another household
    const bad = await app.request('/recipes', {
      method: 'POST',
      headers: h,
      body: JSON.stringify({ title: 'sneaky', householdId: 'hh-other' }),
    });
    expect(bad.status).toBe(403);
    // seed a foreign-household recipe via the dev stub, then try to read it
    const seeded = await app.request('/recipes', {
      method: 'POST',
      headers: { 'x-role': 'owner', 'content-type': 'application/json' },
      body: JSON.stringify({ title: 'Foreign Stew', householdId: 'hh-other' }),
    });
    const fid = ((await seeded.json()) as { id: string }).id;
    expect((await app.request(`/recipes/${fid}`, { headers: h })).status).toBe(404);
    // read-only transforms of foreign recipes are hidden too (no oracle)
    const scale = await app.request(`/recipes/${fid}/scale`, {
      method: 'POST',
      headers: h,
      body: JSON.stringify({ servings: 8 }),
    });
    expect(scale.status).toBe(404);
    const exp = await app.request(`/export/${fid}.md`, { headers: h });
    expect(exp.status).toBe(404);
    // collections hide the foreign household
    const lists = await app.request('/lists', {
      method: 'POST',
      headers: { 'x-role': 'owner', 'content-type': 'application/json' },
      body: JSON.stringify({ name: 'foreign', householdId: 'hh-other' }),
    });
    expect(lists.status).toBe(201);
    expect(await (await app.request('/lists', { headers: h })).json()).toEqual([]);
  });

  it('rotating the verifier revokes the old token', async () => {
    const { app } = agentApp();
    await enroll(app, HOUSEHOLD_HASH, HH, AGENT_VERIFIER);
    expect((await app.request('/agent/status', { headers: agentHeaders(AGENT_TOKEN) })).status).toBe(200);
    const token2 = await randomToken();
    const verifier2 = createHash('sha256').update(Buffer.from(token2, 'base64url')).digest('hex');
    const re = await enroll(app, HOUSEHOLD_HASH, HH, verifier2);
    expect(re.status).toBe(201);
    expect((await app.request('/agent/status', { headers: agentHeaders(AGENT_TOKEN) })).status).toBe(401);
    expect((await app.request('/agent/status', { headers: agentHeaders(token2) })).status).toBe(200);
  });

  it('legacy v1 sync pull/push honor the enrolled household', async () => {
    const { app } = agentApp();
    await enroll(app, HOUSEHOLD_HASH, HH, AGENT_VERIFIER);
    const h = agentHeaders(AGENT_TOKEN);
    // push without a household label is rejected (explicit scope required)
    const noHh = await app.request('/sync/push', {
      method: 'POST',
      headers: h,
      body: JSON.stringify([{ id: '12345678-1234-4234-8234-000000000001', updatedAt: '2026-11-27T12:00:00.000Z', deviceId: 'a', entity: 'recipe', payload: { title: 'x' } }]),
    });
    expect(noHh.status).toBe(403);
    // push for another household is rejected
    const other = await app.request('/sync/push', {
      method: 'POST',
      headers: h,
      body: JSON.stringify([{ id: '12345678-1234-4234-8234-000000000002', updatedAt: '2026-11-27T12:00:00.000Z', deviceId: 'a', entity: 'recipe', payload: { title: 'x', householdId: 'hh-other' } }]),
    });
    expect(other.status).toBe(403);
    // matching push works and pulls back scoped
    const ok = await app.request('/sync/push', {
      method: 'POST',
      headers: h,
      body: JSON.stringify([{ id: '12345678-1234-4234-8234-000000000003', updatedAt: '2026-11-27T12:00:00.000Z', deviceId: 'a', entity: 'recipe', payload: { title: 'Scoped', householdId: HH, ingredients: [], steps: [] } }]),
    });
    expect(ok.status).toBe(200);
    const pull = (await (await app.request('/sync/pull?since=1970-01-01T00:00:00.000Z', { headers: h })).json()) as { payload: { householdId: string } }[];
    expect(pull.length).toBeGreaterThan(0);
    for (const e of pull) expect(e.payload.householdId).toBe(HH);
  });

  it('enrollments survive a D1 hydrate (and work pre-migration)', async () => {
    // Pre-migration fake: every SQL op throws; memory fallback must hold.
    const throwing = { prepare() { throw new Error('no such table: agent_enrollments'); } };
    const store = new D1Store(throwing as never);
    await store.agentEnroll({ householdHash: HOUSEHOLD_HASH, householdId: HH, verifier: AGENT_VERIFIER, updatedAt: new Date().toISOString() });
    expect(await store.agentGetByVerifier(AGENT_VERIFIER)).toMatchObject({ householdId: HH });
    expect(await store.agentGetByVerifier('0'.repeat(64))).toBeNull();
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
      const put = await app.request(`/v2/sync/${HOUSEHOLD_HASH}`, {
        method: 'PUT',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify([env]),
      });
      expect(put.status).toBe(200);
      expect(await put.json()).toEqual({ stored: [env.id] });
      const pull = (await (await app.request(`/v2/sync/${HOUSEHOLD_HASH}`)).json()) as EncryptedEnvelope[];
      expect(pull).toHaveLength(1);
      expect(await decryptTitle(d.dataKey, pull[0]!)).toBe(`Agent ${MARKER} Soup`);
      const wipe = await app.request(`/v2/sync/${HOUSEHOLD_HASH}`, { method: 'DELETE' });
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
    const pull = await app.request(`/v2/sync/${wrong.householdHash}`);
    expect(pull.status).toBe(200);
    expect(await pull.json()).toEqual([]);
    // The wrong-key token is unknown to the server → 401 on every v1 route.
    for (const [m, p] of [['GET', '/recipes'], ['POST', '/recipes'], ['GET', '/agent/status']] as const) {
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
    return app.request('/mcp', {
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

  it('GET /mcp is 405', async () => {
    const { app } = agentApp();
    expect((await app.request('/mcp')).status).toBe(405);
  });
});
