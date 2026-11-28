import { Hono } from 'hono';
import { MemoryStore, newId, type Store, type SyncEnvelopeWire } from './store';
import { D1Store } from './d1store';
import { authAttach, agentAttach, authenticateDevice, getAgent, getUser, isProdBaseUrl, requireAgentScope, requireOwnerRole, requireWriteRole } from './auth';
import { devicesEnroll, devicesRevoke } from './devices';
import { clipRecipe } from './clip';
import { scaleRecipe } from './scale';
import { signKey, variantKeys, verifySignature, DEFAULT_SIGNED_URL_TTL_SECONDS } from './photos';
import { recipeToHtml, recipeToMarkdown, plansToIcs } from './export';
import { exportPaprika, exportSinglePaprikaRecipe, exportYaml, b64ToBytes } from './paprika';
import { runImport } from './import';
import {
  parseOrThrow,
  clipRequestSchema,
  recipeInputSchema,
  shoppingListInputSchema,
  pantryInputSchema,
  planInputSchema,
  menuInputSchema,
  scaleRequestSchema,
  shareRequestSchema,
  syncEnvelopeSchema,
  entitySchema,
} from './zod';
import { E2E_HASH_RE, HASH_LOG_PREFIX_LEN, validateE2EPushBatch, type EncryptedEnvelope } from './e2e';
import { agentEnrollSchema, agentShortHash, agentVerifierFor, AGENT_TOKEN_HEADER } from './agent';
import { handleMcp } from './mcp';
import openApiJson from '../../packages/contracts/openapi.json';

export interface Env {
  DB?: unknown;
  PHOTOS?: unknown;
  APP_VERSION?: string;
  PUBLIC_BASE_URL?: string;
  PHOTOS_SIGNING_SECRET?: string; // HMAC for photo signed URLs only; not auth
}

/**
 * R2 byte source for GET /photos/dl. Returns the object's bytes (or null
 * when the key does not exist). Wired from the PHOTOS binding in the worker
 * entrypoint; tests pass a fake. Absent in dev without R2 (route 404s).
 */
export type PhotoFetcher = (key: string) => Promise<{ body: Uint8Array | ReadableStream | string | null; contentType?: string } | null>;

const VERSION = '0.1.0';

// E2E blindness: the access log must never carry a full household hash
// (prefix only) and envelope bodies (ciphertext/nonce) are never logged
// anywhere — handlers below log nothing per-envelope.
// All routes are served under /api only (no backward-compat root mount).
export function redactE2EPath(path: string): string {
  const m = path.match(/^(\/api\/v2\/sync\/)([0-9a-fA-F]{16,})(.*)$/);
  if (m) return `${m[1]}${m[2]!.slice(0, HASH_LOG_PREFIX_LEN)}…`;
  // Device ids are user ids in prod (see auth.ts) — never log them.
  const d = path.match(/^(\/api\/v2\/devices\/)[^/?#]+(.*)$/);
  if (d) return `${d[1]}…${d[2]}`;
  return path;
}

// Singleton memory store for `wrangler dev` without a D1 binding.
let devMemory: MemoryStore | null = null;
// Reuse D1Store per binding object so hydrate() runs once.
const d1Stores = new WeakMap<object, D1Store>();

export function resolveStore(env: Env): Store {
  if (env.DB) {
    let s = d1Stores.get(env.DB as object);
    if (!s) {
      s = new D1Store(env.DB as never);
      d1Stores.set(env.DB as object, s);
    }
    void s.hydrate();
    return s;
  }
  if (!devMemory) devMemory = new MemoryStore();
  return devMemory;
}

export function createApp(
  store: Store,
  opts: { version?: string; baseUrl?: string; secret?: string; prod?: boolean; photosFetcher?: PhotoFetcher } = {},
) {
  const app = new Hono<{ Variables: { store: Store } }>();
  const version = opts.version ?? VERSION;
  const baseUrl = (opts.baseUrl ?? 'https://api.keepcooking.local').replace(/\/$/, '');
  const secret = opts.secret ?? 'dev-only-change-me';
  const photosFetcher = opts.photosFetcher;
  // Prod detection: explicit override wins, else derived from baseUrl
  // (workers.dev / any non-local host => prod). Dev keeps the header stub.
  const prod = opts.prod ?? isProdBaseUrl(baseUrl);

  // PII-safe access log: method + pathname + status + ms only.
  // Never log headers (Authorization, x-user-*, cookies) or bodies.
  // E2E rule: household hashes are prefix-redacted (see redactE2EPath).
  app.use('*', async (c, next) => {
    const t0 = Date.now();
    await next();
    const path = redactE2EPath(new URL(c.req.url).pathname);
    console.log(JSON.stringify({ m: c.req.method, p: path, s: c.res.status, ms: Date.now() - t0 }));
  });
  // Key-only agent auth (#26): no x-agent-token header → passthrough
  // (existing behavior byte-identical); header present → must verify (401).
  // Runs BEFORE the device gate so a valid agent token is an alternative
  // credential to the Ed25519 device signature (agents hold only the
  // syncCode, never a device signing key).
  app.use('*', agentAttach(store));
  // Device-signature gate.
  // All routes live under /api (single-serve; old root-path clients 404).
  // Open (no sig): GET/HEAD/OPTIONS on any route, plus /api/health,
  // /api/openapi.json, and POST /api/v2/devices (enrollment — how devices join).
  // POST /api/v2/devices/:id/revoke is also exempt here so devicesRevoke can
  // return 404 for unknown targets before auth (it re-verifies the
  // signature itself, keeping dev/prod consistent).
  // Agent-token requests (agentAttach above) skip the device signature:
  // the token already proves syncCode possession for that household.
  // Everything else: dev (!prod) passes through to the getUser() header
  // stub; prod requires a valid Ed25519 device signature (401 otherwise).
  // v2 writes are sig-only; v1 writes additionally enforce household RBAC
  // with user.id = the verified device id (see getUser in auth.ts).
  app.use('*', async (c, next) => {
    c.set('prod' as never, prod as never);
    const pathname = new URL(c.req.url).pathname;
    const m = c.req.method;
    if (m === 'GET' || m === 'HEAD' || m === 'OPTIONS') return next();
    if (pathname === '/api/health' || pathname === '/api/openapi.json') return next();
    if (pathname === '/api/v2/devices' && m === 'POST') return next();
    if (m === 'POST' && /^\/api\/v2\/devices\/[^/]+\/revoke$/.test(pathname)) return next();
    // Key-only agent surface (#26), served under /api like everything else:
    // open enrollment (how agents join — same trust as the unguessable /v2
    // bucket) and the MCP endpoint, whose per-method auth lives in handleMcp
    // (agent calls carry x-agent-token; initialize/notifications stay usable
    // for handshake).
    if (pathname === '/api/agent/enroll' && m === 'POST') return next();
    if (pathname === '/api/mcp' && m === 'POST') return next();
    if (!prod) return next(); // dev header stub
    if (getAgent(c)) return next(); // agent token already verified (#26)
    await authenticateDevice(c, store); // throws 401
    return next();
  });
  app.use('*', authAttach);
  app.use('*', async (c, next) => {
    c.set('store' as never, store as never);
    await next();
  });

  app.onError((err, c) => {
    const status = (err as { status?: number }).status ?? 500;
    const details = (err as { details?: unknown }).details;
    // Never echo request bodies (may contain PII) — only validation summary.
    return c.json({ error: err.message || 'internal error', ...(details ? { details } : {}) }, status as 400);
  });

  const getStore = (): Store => store;

  // All routes live on this sub-app, mounted once at /api below.
  const api = new Hono<{ Variables: { store: Store } }>();

  // ---------- device enrollment (public; no sig — this is how devices join) ----------
  // devicesEnroll is owned by the enroll-store lane (api/src/devices.ts):
  // POST { deviceId: UUIDv4, publicKey: base64(32B), displayName? } ->
  // 201 first enroll / 200 idempotent re-enroll / 409 key conflict.
  api.post('/v2/devices', async (c) => devicesEnroll(c, getStore()));

  // ---------- device self-revoke (sig verified by the handler, not the
  // gate: the '/v2/devices/:id/revoke' exemption above lets devicesRevoke
  // check existence first — 404 unknown :id -> 401 missing/bad/stale sig
  // -> 403 signer != :id -> 200 { deviceId, revokedAt }). Revoked devices
  // fail all later writes with 401 via authenticateDevice.
  api.post('/v2/devices/:id/revoke', async (c) => devicesRevoke(c, getStore()));

  // ---------- health / openapi ----------
  api.get('/health', (c) => c.json({ ok: true, version }));
  api.get('/openapi.json', (c) => c.json(openApiJson));

  // ---------- key-only agent auth (#26) ----------
  // POST /agent/enroll binds {householdHash, householdId, verifier}. Open for
  // a label with NO existing binding (bootstrap must work with the hash
  // alone). But a householdId label that already maps to a DIFFERENT hash is
  // bound: re-binding it requires proving syncCode knowledge by presenting
  // the existing token in x-agent-token (anyone holding the syncCode
  // re-derives the deterministic token, so legit clients and rotation are
  // unaffected; label-squatters without the syncCode get 409). Same-hash
  // re-enroll rotates the token verifier without rotating the data key.
  // A proven re-bind to a different hash additionally revokes the old
  // hash's enrollment, so the previous token stops authenticating.
  // Never receives key material — only hashes/labels.
  api.post('/agent/enroll', async (c) => {
    const body = parseOrThrow(agentEnrollSchema, await c.req.json().catch(() => ({})));
    const bound = await getStore().agentGetByLabel(body.householdId);
    // Re-binding a label to a DIFFERENT hash revokes the old hash's
    // enrollment (D1 row + memory indexes): the previous token must stop
    // authenticating, or it would keep full plaintext access to the same
    // householdId. Same-hash re-enroll skips this (plain verifier rotation).
    const rebinds = !!bound && bound.householdHash !== body.householdHash;
    if (rebinds) {
      const presented = c.req.header(AGENT_TOKEN_HEADER);
      const verifier = presented ? await agentVerifierFor(presented) : null;
      if (!verifier || verifier !== bound.verifier) {
        const err = new Error(
          'householdId label is already bound — present the existing agent token in x-agent-token to re-bind it',
        ) as Error & { status?: number };
        err.status = 409;
        throw err;
      }
      await getStore().agentRevokeByHash(bound.householdHash);
    }
    await getStore().ensureHousehold(body.householdId, body.householdId);
    const e = await getStore().agentEnroll({ ...body, updatedAt: new Date().toISOString() });
    return c.json(
      { ok: true, householdId: e.householdId, householdHash: e.householdHash, hashPrefix8: agentShortHash(e.householdHash) },
      201,
    );
  });
  api.get('/agent/status', async (c) => {
    const a = getAgent(c);
    if (!a) {
      const err = new Error(`missing or unknown ${AGENT_TOKEN_HEADER} (enroll with POST /agent/enroll)`) as Error & { status?: number };
      err.status = 401;
      throw err;
    }
    return c.json({ householdId: a.householdId, hashPrefix8: agentShortHash(a.householdHash), deviceId: a.deviceId });
  });

  // ---------- MCP (stateless JSON-RPC on this Worker; x-agent-token required) ----------
  api.post('/mcp', async (c) => {
    const body = await c.req.json().catch(() => null);
    const { status, body: out } = await handleMcp(getStore(), { secret, baseUrl }, body, getAgent(c));
    // Notifications (202) carry no body per Streamable HTTP.
    return out === null || out === undefined ? c.body(null, status) : c.json(out, status);
  });
  api.get('/mcp', (c) => c.json({ error: 'use POST /mcp with a JSON-RPC 2.0 body' }, 405));

  // ---------- clip ----------
  api.post('/clip', async (c) => {
    const body = parseOrThrow(clipRequestSchema, await c.req.json().catch(() => ({})));
    const result = await clipRecipe({ url: body.url, caption: body.caption, source: body.source });
    const { log: _log, ...report } = result;
    void _log;
    return c.json(report);
  });

  // ---------- recipes ----------
  api.get('/recipes', async (c) => {
    const householdId = c.req.query('householdId');
    const a = getAgent(c);
    if (a) {
      if (householdId && householdId !== a.householdId) {
        const err = new Error(`agent token is scoped to household '${a.householdId}'`) as Error & { status?: number };
        err.status = 403;
        throw err;
      }
      return c.json(await getStore().listRecipes(a.householdId));
    }
    return c.json(await getStore().listRecipes(householdId));
  });
  api.post('/recipes', async (c) => {
    const body = parseOrThrow(recipeInputSchema, await c.req.json().catch(() => ({})));
    requireAgentScope(c, body.householdId);
    await requireWriteRole(c, getStore(), body.householdId);
    const user = getUser(c);
    const r = await getStore().createRecipe(body, { deviceId: user.deviceId });
    return c.json(r, 201);
  });
  api.get('/recipes/:id', async (c) => {
    const r = await getStore().getRecipe(c.req.param('id'));
    if (!r) return c.json({ error: 'not found' }, 404);
    const a = getAgent(c);
    if (a && r.householdId !== a.householdId) return c.json({ error: 'not found' }, 404);
    return c.json(r);
  });
  api.put('/recipes/:id', async (c) => {
    const id = c.req.param('id');
    const cur = await getStore().getRecipe(id);
    if (!cur) return c.json({ error: 'not found' }, 404);
    const a = getAgent(c);
    if (a && cur.householdId !== a.householdId) return c.json({ error: 'not found' }, 404);
    const body = parseOrThrow(recipeInputSchema, await c.req.json().catch(() => ({})));
    requireAgentScope(c, body.householdId ?? cur.householdId);
    await requireWriteRole(c, getStore(), body.householdId ?? cur.householdId);
    const user = getUser(c);
    const r = await getStore().updateRecipe(id, body, { deviceId: user.deviceId });
    return c.json(r);
  });
  api.delete('/recipes/:id', async (c) => {
    const id = c.req.param('id');
    const cur = await getStore().getRecipe(id);
    if (!cur) return c.json({ error: 'not found' }, 404);
    const a = getAgent(c);
    if (a && cur.householdId !== a.householdId) return c.json({ error: 'not found' }, 404);
    requireAgentScope(c, cur.householdId);
    await requireWriteRole(c, getStore(), cur.householdId);
    const user = getUser(c);
    await getStore().deleteRecipe(id, user.deviceId);
    return c.body(null, 204);
  });
  api.post('/recipes/:id/scale', async (c) => {
    const id = c.req.param('id');
    const r = await getStore().getRecipe(id);
    if (!r) return c.json({ error: 'not found' }, 404);
    const a = getAgent(c);
    if (a && r.householdId !== a.householdId) return c.json({ error: 'not found' }, 404);
    const body = parseOrThrow(scaleRequestSchema, await c.req.json().catch(() => ({})));
    const { ingredients } = scaleRecipe(r.ingredients, r.servings, body.servings);
    return c.json({ ...r, servings: body.servings, ingredients });
  });

  // ---------- lists ----------
  api.get('/lists', async (c) => {
    const all = await getStore().listLists();
    const a = getAgent(c);
    return c.json(a ? all.filter((l) => l.householdId === a.householdId) : all);
  });
  api.post('/lists', async (c) => {
    const body = parseOrThrow(shoppingListInputSchema, await c.req.json().catch(() => ({})));
    requireAgentScope(c, body.householdId);
    await requireWriteRole(c, getStore(), body.householdId);
    const user = getUser(c);
    return c.json(await getStore().createList(body, { deviceId: user.deviceId }), 201);
  });
  api.get('/lists/:id', async (c) => {
    const l = await getStore().getList(c.req.param('id'));
    if (!l) return c.json({ error: 'not found' }, 404);
    const a = getAgent(c);
    if (a && l.householdId !== a.householdId) return c.json({ error: 'not found' }, 404);
    return c.json(l);
  });
  api.put('/lists/:id', async (c) => {
    const id = c.req.param('id');
    const cur = await getStore().getList(id);
    if (!cur) return c.json({ error: 'not found' }, 404);
    const a = getAgent(c);
    if (a && cur.householdId !== a.householdId) return c.json({ error: 'not found' }, 404);
    const body = parseOrThrow(shoppingListInputSchema, await c.req.json().catch(() => ({})));
    requireAgentScope(c, body.householdId ?? cur.householdId);
    await requireWriteRole(c, getStore(), body.householdId ?? cur.householdId);
    const user = getUser(c);
    return c.json(await getStore().updateList(id, body, { deviceId: user.deviceId }));
  });
  api.delete('/lists/:id', async (c) => {
    const id = c.req.param('id');
    const cur = await getStore().getList(id);
    if (!cur) return c.json({ error: 'not found' }, 404);
    const a = getAgent(c);
    if (a && cur.householdId !== a.householdId) return c.json({ error: 'not found' }, 404);
    requireAgentScope(c, cur.householdId);
    await requireWriteRole(c, getStore(), cur.householdId);
    const user = getUser(c);
    await getStore().deleteList(id, user.deviceId);
    return c.body(null, 204);
  });

  // ---------- pantry ----------
  api.get('/pantry', async (c) => {
    const all = await getStore().listPantry();
    const a = getAgent(c);
    return c.json(a ? all.filter((p) => p.householdId === a.householdId) : all);
  });
  api.post('/pantry', async (c) => {
    const body = parseOrThrow(pantryInputSchema, await c.req.json().catch(() => ({})));
    requireAgentScope(c, body.householdId);
    await requireWriteRole(c, getStore(), body.householdId);
    const user = getUser(c);
    return c.json(await getStore().createPantry(body, { deviceId: user.deviceId }), 201);
  });
  api.put('/pantry/:id', async (c) => {
    const id = c.req.param('id');
    const cur = await getStore().getPantry(id);
    if (!cur) return c.json({ error: 'not found' }, 404);
    const a = getAgent(c);
    if (a && cur.householdId !== a.householdId) return c.json({ error: 'not found' }, 404);
    const body = parseOrThrow(pantryInputSchema, await c.req.json().catch(() => ({})));
    requireAgentScope(c, body.householdId ?? cur.householdId);
    await requireWriteRole(c, getStore(), body.householdId ?? cur.householdId);
    const user = getUser(c);
    return c.json(await getStore().updatePantry(id, body, { deviceId: user.deviceId }));
  });
  api.delete('/pantry/:id', async (c) => {
    const id = c.req.param('id');
    const cur = await getStore().getPantry(id);
    if (!cur) return c.json({ error: 'not found' }, 404);
    const a = getAgent(c);
    if (a && cur.householdId !== a.householdId) return c.json({ error: 'not found' }, 404);
    requireAgentScope(c, cur.householdId);
    await requireWriteRole(c, getStore(), cur.householdId);
    const user = getUser(c);
    await getStore().deletePantry(id, user.deviceId);
    return c.body(null, 204);
  });

  // ---------- plans feed (before :id) ----------
  api.get('/plans/feed.ics', async (c) => {
    const allPlans = await getStore().listPlans();
    const a = getAgent(c);
    const plans = a ? allPlans.filter((p) => p.householdId === a.householdId) : allPlans;
    const byId = new Map((await getStore().listRecipes()).map((r) => [r.id, r.title] as const));
    const ics = plansToIcs(plans, (rid) => byId.get(rid ?? '') ?? null);
    return new Response(ics, { headers: { 'content-type': 'text/calendar; charset=utf-8' } });
  });

  // ---------- plans ----------
  api.get('/plans', async (c) => {
    const all = await getStore().listPlans();
    const a = getAgent(c);
    return c.json(a ? all.filter((p) => p.householdId === a.householdId) : all);
  });
  api.post('/plans', async (c) => {
    const body = parseOrThrow(planInputSchema, await c.req.json().catch(() => ({})));
    requireAgentScope(c, body.householdId);
    await requireWriteRole(c, getStore(), body.householdId);
    const user = getUser(c);
    return c.json(await getStore().createPlan(body, { deviceId: user.deviceId }), 201);
  });
  api.get('/plans/:id', async (c) => {
    const p = await getStore().getPlan(c.req.param('id'));
    if (!p) return c.json({ error: 'not found' }, 404);
    const a = getAgent(c);
    if (a && p.householdId !== a.householdId) return c.json({ error: 'not found' }, 404);
    return c.json(p);
  });
  api.put('/plans/:id', async (c) => {
    const id = c.req.param('id');
    const cur = await getStore().getPlan(id);
    if (!cur) return c.json({ error: 'not found' }, 404);
    const a = getAgent(c);
    if (a && cur.householdId !== a.householdId) return c.json({ error: 'not found' }, 404);
    const body = parseOrThrow(planInputSchema, await c.req.json().catch(() => ({})));
    requireAgentScope(c, body.householdId ?? cur.householdId);
    await requireWriteRole(c, getStore(), body.householdId ?? cur.householdId);
    const user = getUser(c);
    return c.json(await getStore().updatePlan(id, body, { deviceId: user.deviceId }));
  });
  api.delete('/plans/:id', async (c) => {
    const id = c.req.param('id');
    const cur = await getStore().getPlan(id);
    if (!cur) return c.json({ error: 'not found' }, 404);
    const a = getAgent(c);
    if (a && cur.householdId !== a.householdId) return c.json({ error: 'not found' }, 404);
    requireAgentScope(c, cur.householdId);
    await requireWriteRole(c, getStore(), cur.householdId);
    const user = getUser(c);
    await getStore().deletePlan(id, user.deviceId);
    return c.body(null, 204);
  });

  // ---------- menus ----------
  api.get('/menus', async (c) => {
    const all = await getStore().listMenus();
    const a = getAgent(c);
    return c.json(a ? all.filter((m) => m.householdId === a.householdId) : all);
  });
  api.post('/menus', async (c) => {
    const body = parseOrThrow(menuInputSchema, await c.req.json().catch(() => ({})));
    requireAgentScope(c, body.householdId);
    await requireWriteRole(c, getStore(), body.householdId);
    const user = getUser(c);
    return c.json(await getStore().createMenu(body, { deviceId: user.deviceId }), 201);
  });
  api.get('/menus/:id', async (c) => {
    const m = await getStore().getMenu(c.req.param('id'));
    if (!m) return c.json({ error: 'not found' }, 404);
    const a = getAgent(c);
    if (a && m.householdId !== a.householdId) return c.json({ error: 'not found' }, 404);
    return c.json(m);
  });
  api.put('/menus/:id', async (c) => {
    const id = c.req.param('id');
    const cur = await getStore().getMenu(id);
    if (!cur) return c.json({ error: 'not found' }, 404);
    const a = getAgent(c);
    if (a && cur.householdId !== a.householdId) return c.json({ error: 'not found' }, 404);
    const body = parseOrThrow(menuInputSchema, await c.req.json().catch(() => ({})));
    requireAgentScope(c, body.householdId ?? cur.householdId);
    await requireWriteRole(c, getStore(), body.householdId ?? cur.householdId);
    const user = getUser(c);
    return c.json(await getStore().updateMenu(id, body, { deviceId: user.deviceId }));
  });
  api.delete('/menus/:id', async (c) => {
    const id = c.req.param('id');
    const cur = await getStore().getMenu(id);
    if (!cur) return c.json({ error: 'not found' }, 404);
    const a = getAgent(c);
    if (a && cur.householdId !== a.householdId) return c.json({ error: 'not found' }, 404);
    requireAgentScope(c, cur.householdId);
    await requireWriteRole(c, getStore(), cur.householdId);
    const user = getUser(c);
    await getStore().deleteMenu(id, user.deviceId);
    return c.body(null, 204);
  });

  // ---------- share ----------
  api.post('/share/cookbook', async (c) => {
    const body = parseOrThrow(shareRequestSchema, await c.req.json().catch(() => ({})));
    requireAgentScope(c, body.householdId);
    await requireOwnerRole(c, getStore(), body.householdId);
    // Agent recipe scope (#26, mirrors the MCP share_cookbook tool): every
    // shared recipe must belong to the enrolled household — out-of-scope ids
    // 404 without confirming existence.
    const a = getAgent(c);
    if (a) {
      for (const rid of body.recipeIds) {
        const r = await getStore().getRecipe(rid);
        if (!r || r.householdId !== a.householdId) return c.json({ error: 'not found' }, 404);
      }
    }
    const id = newId();
    const expiresAt = new Date(Date.now() + (body.expiresInDays ?? 30) * 86400_000).toISOString();
    const url = `${baseUrl}/s/${id}`;
    const s = await getStore().createShare({ id, householdId: body.householdId, recipeIds: body.recipeIds, url, expiresAt });
    return c.json({ id: s.id, url: s.url, expiresAt: s.expiresAt }, 201);
  });

  // ---------- export ----------
  // Note: hono does not reliably match `:id.json`-style suffix patterns, so a
  // single `:file` param is split into id + extension here. Behavior matches
  // openapi.yaml /export/{id}.(json|md|html) exactly, plus Paprika parity:
  // .paprikarecipes (single recipe as one-member ZIP), .paprikarecipe
  // (single gzip JSON), .yaml/.yml (JSON-as-YAML). The basename `all`
  // exports the whole visible cookbook in .paprikarecipes/.yaml.
  api.get('/export/:file', async (c) => {
    const file = c.req.param('file') ?? '';
    const m = file.match(/^(.+)\.(json|md|html|paprikarecipes|paprikarecipe|yaml|yml)$/);
    if (!m) return c.json({ error: 'not found' }, 404);
    const a = getAgent(c);
    const scopeHousehold = a?.householdId;
    const ext = m[2]!;
    if (m[1] === 'all') {
      if (ext !== 'paprikarecipes' && ext !== 'yaml' && ext !== 'yml') return c.json({ error: 'not found' }, 404);
      const qHousehold = c.req.query('householdId');
      if (scopeHousehold && qHousehold && qHousehold !== scopeHousehold) return c.json({ error: 'not found' }, 404);
      const all = await getStore().listRecipes(qHousehold ?? scopeHousehold);
      if (ext === 'paprikarecipes') {
        const zip = await exportPaprika(all);
        return new Response(zip, {
          headers: {
            'content-type': 'application/zip',
            'content-disposition': 'attachment; filename="cookbook.paprikarecipes"',
          },
        });
      }
      return new Response(exportYaml(all), {
        headers: {
          'content-type': 'text/yaml; charset=utf-8',
          'content-disposition': 'attachment; filename="cookbook.yaml"',
        },
      });
    }
    const r = await getStore().getRecipe(m[1]!);
    if (!r) return c.json({ error: 'not found' }, 404);
    if (a && r.householdId !== a.householdId) return c.json({ error: 'not found' }, 404);
    if (ext === 'json') return c.json(r);
    if (ext === 'md') return new Response(recipeToMarkdown(r), { headers: { 'content-type': 'text/markdown; charset=utf-8' } });
    if (ext === 'html')
      return new Response(recipeToHtml(r), { headers: { 'content-type': 'text/html; charset=utf-8' } });
    if (ext === 'paprikarecipes') {
      const zip = await exportPaprika([r]);
      return new Response(zip, {
        headers: {
          'content-type': 'application/zip',
          'content-disposition': `attachment; filename="${r.id}.paprikarecipes"`,
        },
      });
    }
    if (ext === 'paprikarecipe') {
      const gz = await exportSinglePaprikaRecipe(r);
      return new Response(gz, {
        headers: {
          'content-type': 'application/gzip',
          'content-disposition': `attachment; filename="${r.id}.paprikarecipe"`,
        },
      });
    }
    return new Response(exportYaml([r]), {
      headers: {
        'content-type': 'text/yaml; charset=utf-8',
        'content-disposition': `attachment; filename="${r.id}.yaml"`,
      },
    });
  });

  // ---------- import (Paprika parity) ----------
  // POST /api/import accepts either JSON
  // {format?, filename?, payload(base64)?, text?, householdId?} or
  // multipart form data (file + optional format/householdId fields).
  // Persists via createRecipe (uid upsert) and returns {imported, ids,
  // warnings, updated, dryRun, cookbooksCreated}; dryRun=true parses fully
  // and reports without persisting anything.
  api.post('/import', async (c) => {
    const contentType = c.req.header('content-type') ?? '';
    let format: string | undefined;
    let filename: string | undefined;
    let bytes: Uint8Array | undefined;
    let text: string | undefined;
    let householdId = 'hh-demo';
    let dryRun = false;
    if (contentType.includes('multipart/form-data')) {
      const body = await c.req.parseBody();
      const file = body['file'];
      if (file instanceof File) {
        filename = file.name || undefined;
        bytes = new Uint8Array(await file.arrayBuffer());
      }
      if (typeof body['format'] === 'string') format = body['format'];
      if (typeof body['filename'] === 'string') filename ??= body['filename'];
      if (typeof body['householdId'] === 'string' && body['householdId']) householdId = body['householdId'];
      if (typeof body['text'] === 'string') text = body['text'];
      if (typeof body['dryRun'] === 'string') dryRun = body['dryRun'].toLowerCase() === 'true' || body['dryRun'] === '1';
    } else {
      const body = (await c.req.json().catch(() => ({}))) as Record<string, unknown>;
      if (typeof body['format'] === 'string') format = body['format'];
      if (typeof body['filename'] === 'string') filename = body['filename'];
      if (typeof body['householdId'] === 'string' && body['householdId']) householdId = body['householdId'];
      if (body['dryRun'] === true || body['dryRun'] === 'true' || body['dryRun'] === 1) dryRun = true;
      if (typeof body['payload'] === 'string' && body['payload'].trim() !== '') {
        try {
          bytes = b64ToBytes(body['payload'].trim());
        } catch {
          const err = new Error('payload is not valid base64') as Error & { status?: number };
          err.status = 400;
          throw err;
        }
      }
      if (typeof body['text'] === 'string') text = body['text'];
    }
    requireAgentScope(c, householdId);
    await requireWriteRole(c, getStore(), householdId);
    const user = getUser(c);
    const result = await runImport(getStore(), { format, filename, bytes, text, householdId, dryRun }, { deviceId: user.deviceId, householdId });
    return c.json(result);
  });

  // ---------- photos (signed URLs; variants per PHOTO_VARIANTS.md) ----------
  api.get('/photos/variants', (c) => {
    const recipeId = c.req.query('recipeId') ?? 'unknown';
    return c.json(variantKeys(recipeId));
  });
  api.get('/photos/sign', async (c) => {
    const key = c.req.query('key') ?? '';
    if (!key) return c.json({ error: 'key is required' }, 400);
    // Agent scope (best-effort): a key naming a recipe of another household
    // is rejected; unparseable keys carry no household signal, so they pass.
    const a = getAgent(c);
    if (a) {
      const km = key.match(/^photos\/([^/]+)\/(original|1024|thumb)\.jpg$/);
      if (km) {
        const r = await getStore().getRecipe(km[1]!);
        if (r && r.householdId !== a.householdId) return c.json({ error: 'photo is outside the enrolled household' }, 403);
      }
    }
    const ttl = Number(c.req.query('ttl') ?? DEFAULT_SIGNED_URL_TTL_SECONDS);
    const signed = await signKey(key, { secret, baseUrl, ttlSeconds: Number.isFinite(ttl) ? ttl : DEFAULT_SIGNED_URL_TTL_SECONDS });
    return c.json(signed);
  });
  // GET /photos/dl serves R2 bytes for a signed URL (GET /photos/sign only
  // mints). The HMAC exp/sig is verified first — 400 on missing params, 403
  // on bad/expired — then the object streams with its stored contentType
  // (image/jpeg for recipe photos). 404 when no
  // fetcher is wired (dev without R2) or the key does not exist.
  api.get('/photos/dl', async (c) => {
    const key = c.req.query('key') ?? '';
    const expRaw = c.req.query('exp') ?? '';
    const sig = c.req.query('sig') ?? '';
    const exp = Number(expRaw);
    if (!key || !expRaw || !sig || !Number.isFinite(exp)) return c.json({ error: 'key, exp, and sig are required' }, 400);
    if (!(await verifySignature(key, exp, sig, secret))) return c.json({ error: 'invalid or expired signature' }, 403);
    if (!photosFetcher) return c.json({ error: 'photo serving is not configured' }, 404);
    const obj = await photosFetcher(key);
    if (!obj || !obj.body) return c.json({ error: 'not found' }, 404);
    return new Response(obj.body, { headers: { 'content-type': obj.contentType ?? 'image/jpeg' } });
  });

  // ---------- sync ----------
  api.get('/sync/pull', async (c) => {
    const since = c.req.query('since') ?? '1970-01-01T00:00:00Z';
    const all = await getStore().pullSince(since);
    const a = getAgent(c);
    if (!a) return c.json(all);
    // Legacy plaintext pipe: scope to the enrolled household. Envelopes
    // without a household label are dropped for agents (no scope signal).
    return c.json(
      all.filter((e) => (e.payload as { householdId?: unknown } | undefined)?.householdId === a.householdId),
    );
  });
  api.post('/sync/push', async (c) => {
    const raw = await c.req.json().catch(() => null);
    if (!Array.isArray(raw)) return c.json({ error: 'expected an array of SyncEnvelopes' }, 400);
    const conflicts: SyncEnvelopeWire[] = [];
    const a = getAgent(c);
    for (const item of raw) {
      const env = parseOrThrow(syncEnvelopeSchema, item) as SyncEnvelopeWire;
      if (a) {
        // Agent plaintext-push scope: every envelope must name the enrolled
        // household. Child rows resolve through the parent recipe; unknown
        // parents are dropped (client will re-pull), as for app callers.
        if (env.entity === 'ingredient' || env.entity === 'step') {
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          const payload = (env.payload ?? {}) as Record<string, any>;
          const parent = await getStore().getRecipeRow(String(payload.recipeId ?? env.id));
          if (!parent) continue;
          if (parent.householdId !== a.householdId) {
            const err = new Error(`agent token is scoped to household '${a.householdId}'`) as Error & { status?: number };
            err.status = 403;
            throw err;
          }
        } else {
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          const hh = ((env.payload ?? {}) as Record<string, any>).householdId;
          requireAgentScope(c, typeof hh === 'string' ? hh : undefined);
        }
      }
      if (!entitySchema.safeParse(env.entity).success) {
        const err = new Error(`unknown entity: ${env.entity}`) as Error & { status?: number };
        err.status = 400;
        throw err;
      }
      if (env.entity === 'ingredient' || env.entity === 'step') {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        const payload = (env.payload ?? {}) as Record<string, any>;
        const recipeId = String(payload.recipeId ?? env.id);
        const parent = await getStore().getRecipeRow(recipeId);
        if (!parent) continue; // unknown parent: drop (client will re-pull)
        if (env.updatedAt > parent.updatedAt) {
          if (env.entity === 'ingredient') {
            if (env.deleted) await getStore().softDeleteIngredient(env.id);
            else {
              await getStore().upsertIngredient(recipeId, {
                id: env.id,
                name: String(payload.name ?? ''),
                quantity: payload.quantity ?? null,
                unit: String(payload.unit ?? ''),
                display: String(payload.display ?? ''),
                position: Number(payload.position ?? 0),
                recipeId,
              } as never);
            }
          } else {
            if (env.deleted) await getStore().softDeleteStep(env.id);
            else {
              await getStore().upsertStep(recipeId, {
                id: env.id,
                position: Number(payload.position ?? 0),
                text: String(payload.text ?? ''),
                timers: payload.timers ?? [],
                recipeId,
              } as never);
            }
          }
          await getStore().bumpRecipe(recipeId, env.deviceId, env.updatedAt);
        } else {
          const cur = await getStore().getEnvelopeEntity(env.entity, env.id);
          if (cur) conflicts.push(cur);
          else {
            const full = await getStore().getRecipe(recipeId);
            if (full) {
              conflicts.push({
                id: full.id, updatedAt: full.updatedAt, deviceId: full.deviceId,
                deleted: full.deleted, entity: 'recipe',
                payload: { ...full },
              });
            }
          }
        }
        continue;
      }
      const stored = await getStore().getEnvelopeEntity(env.entity, env.id);
      if (a && stored) {
        // An agent must not overwrite another household's row by reusing its
        // entity id with its own label (same comparison as the
        // ingredient/step branch above, but against the stored envelope).
        const storedHh = (stored.payload as { householdId?: unknown } | undefined)?.householdId;
        if (storedHh !== a.householdId) {
          const err = new Error(`agent token is scoped to household '${a.householdId}'`) as Error & { status?: number };
          err.status = 403;
          throw err;
        }
      }
      if (!stored || env.updatedAt > stored.updatedAt) {
        await requireWriteRole(c, getStore(), (env.payload as { householdId?: string } | undefined)?.householdId);
        await getStore().applyEnvelopeFull(env);
      } else if (env.updatedAt < stored.updatedAt) {
        conflicts.push(stored); // server-won
      }
      // equal timestamps: idempotent, no conflict
    }
    return c.json(conflicts);
  });

  // ---------- e2e v1 blind sync (opaque blobs; server never decrypts) ----------
  // PUT/GET /v2/sync/:hash — :hash is the hex householdHash deriving bucket
  // identity. Plaintext v1 envelopes fail schema validation (400). Photos
  // stay inline in ciphertext for pass 1 — no dedicated photo route.
  // Agent bucket scope (#26): a token authenticates exactly one bucket.
  // Cross-bucket reads 404 (no existence oracle); cross-bucket writes 403.
  api.get('/v2/sync/:hash', async (c) => {
    const hash = c.req.param('hash') ?? '';
    if (!E2E_HASH_RE.test(hash)) return c.json({ error: 'invalid household hash' }, 400);
    const raw = c.req.query('since') ?? '1970-01-01T00:00:00.000Z';
    const parsed = new Date(raw);
    if (Number.isNaN(parsed.getTime())) return c.json({ error: 'invalid since' }, 400);
    const a = getAgent(c);
    if (a && hash !== a.householdHash) return c.json({ error: 'not found' }, 404);
    return c.json(await getStore().e2eList(hash, parsed.toISOString()));
  });
  api.put('/v2/sync/:hash', async (c) => {
    const hash = c.req.param('hash') ?? '';
    if (!E2E_HASH_RE.test(hash)) return c.json({ error: 'invalid household hash' }, 400);
    const a = getAgent(c);
    if (a && hash !== a.householdHash) {
      return c.json({ error: `agent token is scoped to household '${a.householdId}'` }, 403);
    }
    const raw = await c.req.json().catch(() => null);
    // Validate-first (shared with the MCP sync_push tool): a bad batch never
    // partially lands. The 422 shape keeps its `entity` field for clients.
    let batch: EncryptedEnvelope[];
    try {
      batch = validateE2EPushBatch(hash, raw);
    } catch (e) {
      const err = e as Error & { status?: number; entity?: string };
      if (err.status === 422) return c.json({ error: err.message, entity: err.entity }, 422);
      throw e;
    }
    const stored: string[] = [];
    for (const env of batch) {
      if (await getStore().e2ePut(hash, env)) stored.push(env.id);
    }
    return c.json({ stored });
  });
  api.delete('/v2/sync/:hash', async (c) => {
    const hash = c.req.param('hash') ?? '';
    if (!E2E_HASH_RE.test(hash)) return c.json({ error: 'invalid household hash' }, 400);
    const a = getAgent(c);
    if (a && hash !== a.householdHash) {
      return c.json({ error: `agent token is scoped to household '${a.householdId}'` }, 403);
    }
    // Whole-bucket wipe. No household membership lookup is possible from an
    // opaque hash, so no role check applies in either env. Per-id delete
    // travels as a deleted=true tombstone envelope via PUT.
    const wiped = await getStore().e2eWipe(hash);
    return c.json({ wiped });
  });

  // #28: keepcooking.app/api origin. All routes are mounted once, at /api.
  // Old root-path clients (workers.dev installs) 404 — acceptable: pre-launch,
  // single tester. Clients sign exactly what they send (full /api path+query).
  // Still 1 Worker + 1 D1 + 1 R2, no new infra.
  app.route('/api', api);

  return app;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const store = resolveStore(env);
    if (store instanceof D1Store) await store.hydrate();
    const photos = env.PHOTOS as
      | { get: (key: string) => Promise<{ body: ReadableStream | null; httpMetadata?: { contentType?: string } } | null> }
      | undefined;
    const app = createApp(store, {
      version: env.APP_VERSION ?? VERSION,
      baseUrl: env.PUBLIC_BASE_URL ?? 'https://api.keepcooking.local',
      secret: env.PHOTOS_SIGNING_SECRET ?? 'dev-only-change-me',
      // prod derived from PUBLIC_BASE_URL via isProdBaseUrl (workers.dev => prod)
      photosFetcher: photos
        ? async (key: string) => {
            const obj = await photos.get(key);
            return obj ? { body: obj.body, contentType: obj.httpMetadata?.contentType } : null;
          }
        : undefined,
    });
    return app.fetch(request);
  },
};
