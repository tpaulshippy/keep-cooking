import { Hono } from 'hono';
import { MemoryStore, newId, type Store, type SyncEnvelopeWire } from './store';
import { D1Store } from './d1store';
import { authAttach, agentAttach, createBetaGate, getAgent, getUser, isProdBaseUrl, requireAgentScope, requireOwnerRole, requireWriteRole } from './auth';
import { clipRecipe } from './clip';
import { scaleRecipe } from './scale';
import { signKey, variantKeys, DEFAULT_SIGNED_URL_TTL_SECONDS } from './photos';
import { recipeToHtml, recipeToMarkdown, plansToIcs } from './export';
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
import { agentEnrollSchema, agentShortHash, AGENT_TOKEN_HEADER } from './agent';
import { handleMcp } from './mcp';
import openApiJson from '../../packages/contracts/openapi.json';

export interface Env {
  DB?: unknown;
  PHOTOS?: unknown;
  APP_VERSION?: string;
  PUBLIC_BASE_URL?: string;
  BETTER_AUTH_SECRET?: string; // reserved for pass 2 (real Apple auth); unused by the beta gate
  INTERNAL_BETA_TOKEN?: string; // required in prod: `wrangler secret put INTERNAL_BETA_TOKEN`
}

const VERSION = '0.1.0';

// E2E blindness: the access log must never carry a full household hash
// (prefix only) and envelope bodies (ciphertext/nonce) are never logged
// anywhere — handlers below log nothing per-envelope.
export function redactE2EPath(path: string): string {
  const m = path.match(/^(\/v2\/sync\/)([0-9a-fA-F]{16,})(.*)$/);
  if (m) return `${m[1]}${m[2]!.slice(0, HASH_LOG_PREFIX_LEN)}…`;
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
  opts: { version?: string; baseUrl?: string; secret?: string; betaToken?: string; prod?: boolean } = {},
) {
  const app = new Hono<{ Variables: { store: Store } }>();
  const version = opts.version ?? VERSION;
  const baseUrl = (opts.baseUrl ?? 'https://api.keepcooking.local').replace(/\/$/, '');
  const secret = opts.secret ?? 'dev-only-change-me';
  // Prod detection: explicit override wins, else derived from baseUrl
  // (workers.dev / any non-local host => prod). Dev keeps the header stub.
  const prod = opts.prod ?? isProdBaseUrl(baseUrl);
  const betaToken = opts.betaToken;

  // PII-safe access log: method + pathname + status + ms only.
  // Never log headers (Authorization, x-user-*, cookies) or bodies.
  // E2E rule: household hashes are prefix-redacted (see redactE2EPath).
  app.use('*', async (c, next) => {
    const t0 = Date.now();
    await next();
    const path = redactE2EPath(new URL(c.req.url).pathname);
    console.log(JSON.stringify({ m: c.req.method, p: path, s: c.res.status, ms: Date.now() - t0 }));
  });
  // Prod beta gate (passthrough): /health stays open and everything else
  // proceeds to authAttach with no token enrollment. E2E buckets stay blind;
  // v1 routes still enforce household RBAC below.
  app.use('*', createBetaGate({ betaToken, prod }));
  app.use('*', authAttach);
  // Key-only agent auth (#26): no x-agent-token header → passthrough
  // (existing behavior byte-identical); header present → must verify (401).
  app.use('*', agentAttach(store));
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

  // ---------- health / openapi ----------
  app.get('/health', (c) => c.json({ ok: true, version }));
  app.get('/openapi.json', (c) => c.json(openApiJson));

  // ---------- key-only agent auth (#26) ----------
  // POST /agent/enroll binds {householdHash, householdId, verifier}. Open:
  // knowledge of the unguessable householdHash IS the capability (same trust
  // as the /v2 bucket itself). Re-enroll rotates the token verifier without
  // rotating the data key. Never receives key material — only hashes/labels.
  app.post('/agent/enroll', async (c) => {
    const body = parseOrThrow(agentEnrollSchema, await c.req.json().catch(() => ({})));
    await getStore().ensureHousehold(body.householdId, body.householdId);
    const e = await getStore().agentEnroll({ ...body, updatedAt: new Date().toISOString() });
    return c.json(
      { ok: true, householdId: e.householdId, householdHash: e.householdHash, hashPrefix8: agentShortHash(e.householdHash) },
      201,
    );
  });
  app.get('/agent/status', async (c) => {
    const a = getAgent(c);
    if (!a) {
      const err = new Error(`missing or unknown ${AGENT_TOKEN_HEADER} (enroll with POST /agent/enroll)`) as Error & { status?: number };
      err.status = 401;
      throw err;
    }
    return c.json({ householdId: a.householdId, hashPrefix8: agentShortHash(a.householdHash), deviceId: a.deviceId });
  });

  // ---------- MCP (stateless JSON-RPC on this Worker; x-agent-token required) ----------
  app.post('/mcp', async (c) => {
    const body = await c.req.json().catch(() => null);
    const { status, body: out } = await handleMcp(getStore(), { secret, baseUrl }, body, getAgent(c));
    return c.json(out, status);
  });
  app.get('/mcp', (c) => c.json({ error: 'use POST /mcp with a JSON-RPC 2.0 body' }, 405));

  // ---------- clip ----------
  app.post('/clip', async (c) => {
    const body = parseOrThrow(clipRequestSchema, await c.req.json().catch(() => ({})));
    const result = await clipRecipe({ url: body.url, caption: body.caption, source: body.source });
    const { log: _log, ...report } = result;
    void _log;
    return c.json(report);
  });

  // ---------- recipes ----------
  app.get('/recipes', async (c) => {
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
  app.post('/recipes', async (c) => {
    const body = parseOrThrow(recipeInputSchema, await c.req.json().catch(() => ({})));
    requireAgentScope(c, body.householdId);
    await requireWriteRole(c, getStore(), body.householdId);
    const user = getUser(c);
    const r = await getStore().createRecipe(body, { deviceId: user.deviceId });
    return c.json(r, 201);
  });
  app.get('/recipes/:id', async (c) => {
    const r = await getStore().getRecipe(c.req.param('id'));
    if (!r) return c.json({ error: 'not found' }, 404);
    const a = getAgent(c);
    if (a && r.householdId !== a.householdId) return c.json({ error: 'not found' }, 404);
    return c.json(r);
  });
  app.put('/recipes/:id', async (c) => {
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
  app.delete('/recipes/:id', async (c) => {
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
  app.post('/recipes/:id/scale', async (c) => {
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
  app.get('/lists', async (c) => {
    const all = await getStore().listLists();
    const a = getAgent(c);
    return c.json(a ? all.filter((l) => l.householdId === a.householdId) : all);
  });
  app.post('/lists', async (c) => {
    const body = parseOrThrow(shoppingListInputSchema, await c.req.json().catch(() => ({})));
    requireAgentScope(c, body.householdId);
    await requireWriteRole(c, getStore(), body.householdId);
    const user = getUser(c);
    return c.json(await getStore().createList(body, { deviceId: user.deviceId }), 201);
  });
  app.get('/lists/:id', async (c) => {
    const l = await getStore().getList(c.req.param('id'));
    if (!l) return c.json({ error: 'not found' }, 404);
    const a = getAgent(c);
    if (a && l.householdId !== a.householdId) return c.json({ error: 'not found' }, 404);
    return c.json(l);
  });
  app.put('/lists/:id', async (c) => {
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
  app.delete('/lists/:id', async (c) => {
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
  app.get('/pantry', async (c) => {
    const all = await getStore().listPantry();
    const a = getAgent(c);
    return c.json(a ? all.filter((p) => p.householdId === a.householdId) : all);
  });
  app.post('/pantry', async (c) => {
    const body = parseOrThrow(pantryInputSchema, await c.req.json().catch(() => ({})));
    requireAgentScope(c, body.householdId);
    await requireWriteRole(c, getStore(), body.householdId);
    const user = getUser(c);
    return c.json(await getStore().createPantry(body, { deviceId: user.deviceId }), 201);
  });
  app.put('/pantry/:id', async (c) => {
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
  app.delete('/pantry/:id', async (c) => {
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
  app.get('/plans/feed.ics', async (c) => {
    const allPlans = await getStore().listPlans();
    const a = getAgent(c);
    const plans = a ? allPlans.filter((p) => p.householdId === a.householdId) : allPlans;
    const byId = new Map((await getStore().listRecipes()).map((r) => [r.id, r.title] as const));
    const ics = plansToIcs(plans, (rid) => byId.get(rid ?? '') ?? null);
    return new Response(ics, { headers: { 'content-type': 'text/calendar; charset=utf-8' } });
  });

  // ---------- plans ----------
  app.get('/plans', async (c) => {
    const all = await getStore().listPlans();
    const a = getAgent(c);
    return c.json(a ? all.filter((p) => p.householdId === a.householdId) : all);
  });
  app.post('/plans', async (c) => {
    const body = parseOrThrow(planInputSchema, await c.req.json().catch(() => ({})));
    requireAgentScope(c, body.householdId);
    await requireWriteRole(c, getStore(), body.householdId);
    const user = getUser(c);
    return c.json(await getStore().createPlan(body, { deviceId: user.deviceId }), 201);
  });
  app.get('/plans/:id', async (c) => {
    const p = await getStore().getPlan(c.req.param('id'));
    if (!p) return c.json({ error: 'not found' }, 404);
    const a = getAgent(c);
    if (a && p.householdId !== a.householdId) return c.json({ error: 'not found' }, 404);
    return c.json(p);
  });
  app.put('/plans/:id', async (c) => {
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
  app.delete('/plans/:id', async (c) => {
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
  app.get('/menus', async (c) => {
    const all = await getStore().listMenus();
    const a = getAgent(c);
    return c.json(a ? all.filter((m) => m.householdId === a.householdId) : all);
  });
  app.post('/menus', async (c) => {
    const body = parseOrThrow(menuInputSchema, await c.req.json().catch(() => ({})));
    requireAgentScope(c, body.householdId);
    await requireWriteRole(c, getStore(), body.householdId);
    const user = getUser(c);
    return c.json(await getStore().createMenu(body, { deviceId: user.deviceId }), 201);
  });
  app.get('/menus/:id', async (c) => {
    const m = await getStore().getMenu(c.req.param('id'));
    if (!m) return c.json({ error: 'not found' }, 404);
    const a = getAgent(c);
    if (a && m.householdId !== a.householdId) return c.json({ error: 'not found' }, 404);
    return c.json(m);
  });
  app.put('/menus/:id', async (c) => {
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
  app.delete('/menus/:id', async (c) => {
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
  app.post('/share/cookbook', async (c) => {
    const body = parseOrThrow(shareRequestSchema, await c.req.json().catch(() => ({})));
    requireAgentScope(c, body.householdId);
    await requireOwnerRole(c, getStore(), body.householdId);
    const id = newId();
    const expiresAt = new Date(Date.now() + (body.expiresInDays ?? 30) * 86400_000).toISOString();
    const url = `${baseUrl}/s/${id}`;
    const s = await getStore().createShare({ id, householdId: body.householdId, recipeIds: body.recipeIds, url, expiresAt });
    return c.json({ id: s.id, url: s.url, expiresAt: s.expiresAt }, 201);
  });

  // ---------- export ----------
  // Note: hono does not reliably match `:id.json`-style suffix patterns, so a
  // single `:file` param is split into id + extension here. Behavior matches
  // openapi.yaml /export/{id}.(json|md|html) exactly.
  app.get('/export/:file', async (c) => {
    const file = c.req.param('file') ?? '';
    const m = file.match(/^(.+)\.(json|md|html)$/);
    if (!m) return c.json({ error: 'not found' }, 404);
    const r = await getStore().getRecipe(m[1]!);
    if (!r) return c.json({ error: 'not found' }, 404);
    const a = getAgent(c);
    if (a && r.householdId !== a.householdId) return c.json({ error: 'not found' }, 404);
    const ext = m[2]!;
    if (ext === 'json') return c.json(r);
    if (ext === 'md') return new Response(recipeToMarkdown(r), { headers: { 'content-type': 'text/markdown; charset=utf-8' } });
    return new Response(recipeToHtml(r), { headers: { 'content-type': 'text/html; charset=utf-8' } });
  });

  // ---------- photos (signed URLs; variants per PHOTO_VARIANTS.md) ----------
  app.get('/photos/variants', (c) => {
    const recipeId = c.req.query('recipeId') ?? 'unknown';
    return c.json(variantKeys(recipeId));
  });
  app.get('/photos/sign', async (c) => {
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

  // ---------- sync ----------
  app.get('/sync/pull', async (c) => {
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
  app.post('/sync/push', async (c) => {
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
  app.get('/v2/sync/:hash', async (c) => {
    const hash = c.req.param('hash') ?? '';
    if (!E2E_HASH_RE.test(hash)) return c.json({ error: 'invalid household hash' }, 400);
    const raw = c.req.query('since') ?? '1970-01-01T00:00:00.000Z';
    const parsed = new Date(raw);
    if (Number.isNaN(parsed.getTime())) return c.json({ error: 'invalid since' }, 400);
    return c.json(await getStore().e2eList(hash, parsed.toISOString()));
  });
  app.put('/v2/sync/:hash', async (c) => {
    const hash = c.req.param('hash') ?? '';
    if (!E2E_HASH_RE.test(hash)) return c.json({ error: 'invalid household hash' }, 400);
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
  app.delete('/v2/sync/:hash', async (c) => {
    const hash = c.req.param('hash') ?? '';
    if (!E2E_HASH_RE.test(hash)) return c.json({ error: 'invalid household hash' }, 400);
    // Whole-bucket wipe. No household membership lookup is possible from an
    // opaque hash, so no role check applies in either env. Per-id delete
    // travels as a deleted=true tombstone envelope via PUT.
    const wiped = await getStore().e2eWipe(hash);
    return c.json({ wiped });
  });

  return app;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const store = resolveStore(env);
    if (store instanceof D1Store) await store.hydrate();
    const app = createApp(store, {
      version: env.APP_VERSION ?? VERSION,
      baseUrl: env.PUBLIC_BASE_URL ?? 'https://api.keepcooking.local',
      secret: env.BETTER_AUTH_SECRET ?? 'dev-only-change-me',
      betaToken: env.INTERNAL_BETA_TOKEN,
      // prod derived from PUBLIC_BASE_URL via isProdBaseUrl (workers.dev => prod)
    });
    return app.fetch(request);
  },
};
