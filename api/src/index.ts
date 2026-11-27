import { Hono } from 'hono';
import { MemoryStore, newId, type Store, type SyncEnvelopeWire } from './store';
import { D1Store } from './d1store';
import { authAttach, authenticateDevice, getUser, isProdBaseUrl, requireOwnerRole, requireWriteRole } from './auth';
import { devicesEnroll } from './devices';
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
import { E2E_HASH_RE, HASH_LOG_PREFIX_LEN, encryptedEnvelopeSchema, type EncryptedEnvelope } from './e2e';
import openApiJson from '../../packages/contracts/openapi.json';

export interface Env {
  DB?: unknown;
  PHOTOS?: unknown;
  APP_VERSION?: string;
  PUBLIC_BASE_URL?: string;
  PHOTOS_SIGNING_SECRET?: string; // HMAC for photo signed URLs only; not auth
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
  opts: { version?: string; baseUrl?: string; secret?: string; prod?: boolean } = {},
) {
  const app = new Hono<{ Variables: { store: Store } }>();
  const version = opts.version ?? VERSION;
  const baseUrl = (opts.baseUrl ?? 'https://api.keepcooking.local').replace(/\/$/, '');
  const secret = opts.secret ?? 'dev-only-change-me';
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
  // Device-signature gate.
  // Open (no sig): GET/HEAD/OPTIONS on any route, plus /health,
  // /openapi.json, and POST /v2/devices (enrollment — how devices join).
  // Everything else: dev (!prod) passes through to the getUser() header
  // stub; prod requires a valid Ed25519 device signature (401 otherwise).
  // v2 writes are sig-only; v1 writes additionally enforce household RBAC
  // with user.id = the verified device id (see getUser in auth.ts).
  app.use('*', async (c, next) => {
    c.set('prod' as never, prod as never);
    const pathname = new URL(c.req.url).pathname;
    const m = c.req.method;
    if (m === 'GET' || m === 'HEAD' || m === 'OPTIONS') return next();
    if (pathname === '/health' || pathname === '/openapi.json') return next();
    if (pathname === '/v2/devices') return next();
    if (!prod) return next(); // dev header stub
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

  // ---------- device enrollment (public; no sig — this is how devices join) ----------
  // devicesEnroll is owned by the enroll-store lane (api/src/devices.ts):
  // POST { deviceId: UUIDv4, publicKey: base64(32B), displayName? } ->
  // 201 first enroll / 200 idempotent re-enroll / 409 key conflict.
  app.post('/v2/devices', async (c) => devicesEnroll(c, getStore()));

  // ---------- health / openapi ----------
  app.get('/health', (c) => c.json({ ok: true, version }));
  app.get('/openapi.json', (c) => c.json(openApiJson));

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
    return c.json(await getStore().listRecipes(householdId));
  });
  app.post('/recipes', async (c) => {
    const body = parseOrThrow(recipeInputSchema, await c.req.json().catch(() => ({})));
    await requireWriteRole(c, getStore(), body.householdId);
    const user = getUser(c);
    const r = await getStore().createRecipe(body, { deviceId: user.deviceId });
    return c.json(r, 201);
  });
  app.get('/recipes/:id', async (c) => {
    const r = await getStore().getRecipe(c.req.param('id'));
    if (!r) return c.json({ error: 'not found' }, 404);
    return c.json(r);
  });
  app.put('/recipes/:id', async (c) => {
    const id = c.req.param('id');
    const cur = await getStore().getRecipe(id);
    if (!cur) return c.json({ error: 'not found' }, 404);
    const body = parseOrThrow(recipeInputSchema, await c.req.json().catch(() => ({})));
    await requireWriteRole(c, getStore(), body.householdId ?? cur.householdId);
    const user = getUser(c);
    const r = await getStore().updateRecipe(id, body, { deviceId: user.deviceId });
    return c.json(r);
  });
  app.delete('/recipes/:id', async (c) => {
    const id = c.req.param('id');
    const cur = await getStore().getRecipe(id);
    if (!cur) return c.json({ error: 'not found' }, 404);
    await requireWriteRole(c, getStore(), cur.householdId);
    const user = getUser(c);
    await getStore().deleteRecipe(id, user.deviceId);
    return c.body(null, 204);
  });
  app.post('/recipes/:id/scale', async (c) => {
    const id = c.req.param('id');
    const r = await getStore().getRecipe(id);
    if (!r) return c.json({ error: 'not found' }, 404);
    const body = parseOrThrow(scaleRequestSchema, await c.req.json().catch(() => ({})));
    const { ingredients } = scaleRecipe(r.ingredients, r.servings, body.servings);
    return c.json({ ...r, servings: body.servings, ingredients });
  });

  // ---------- lists ----------
  app.get('/lists', async (c) => c.json(await getStore().listLists()));
  app.post('/lists', async (c) => {
    const body = parseOrThrow(shoppingListInputSchema, await c.req.json().catch(() => ({})));
    await requireWriteRole(c, getStore(), body.householdId);
    const user = getUser(c);
    return c.json(await getStore().createList(body, { deviceId: user.deviceId }), 201);
  });
  app.get('/lists/:id', async (c) => {
    const l = await getStore().getList(c.req.param('id'));
    if (!l) return c.json({ error: 'not found' }, 404);
    return c.json(l);
  });
  app.put('/lists/:id', async (c) => {
    const id = c.req.param('id');
    const cur = await getStore().getList(id);
    if (!cur) return c.json({ error: 'not found' }, 404);
    const body = parseOrThrow(shoppingListInputSchema, await c.req.json().catch(() => ({})));
    await requireWriteRole(c, getStore(), body.householdId ?? cur.householdId);
    const user = getUser(c);
    return c.json(await getStore().updateList(id, body, { deviceId: user.deviceId }));
  });
  app.delete('/lists/:id', async (c) => {
    const id = c.req.param('id');
    const cur = await getStore().getList(id);
    if (!cur) return c.json({ error: 'not found' }, 404);
    await requireWriteRole(c, getStore(), cur.householdId);
    const user = getUser(c);
    await getStore().deleteList(id, user.deviceId);
    return c.body(null, 204);
  });

  // ---------- pantry ----------
  app.get('/pantry', async (c) => c.json(await getStore().listPantry()));
  app.post('/pantry', async (c) => {
    const body = parseOrThrow(pantryInputSchema, await c.req.json().catch(() => ({})));
    await requireWriteRole(c, getStore(), body.householdId);
    const user = getUser(c);
    return c.json(await getStore().createPantry(body, { deviceId: user.deviceId }), 201);
  });
  app.put('/pantry/:id', async (c) => {
    const id = c.req.param('id');
    const cur = await getStore().getPantry(id);
    if (!cur) return c.json({ error: 'not found' }, 404);
    const body = parseOrThrow(pantryInputSchema, await c.req.json().catch(() => ({})));
    await requireWriteRole(c, getStore(), body.householdId ?? cur.householdId);
    const user = getUser(c);
    return c.json(await getStore().updatePantry(id, body, { deviceId: user.deviceId }));
  });
  app.delete('/pantry/:id', async (c) => {
    const id = c.req.param('id');
    const cur = await getStore().getPantry(id);
    if (!cur) return c.json({ error: 'not found' }, 404);
    await requireWriteRole(c, getStore(), cur.householdId);
    const user = getUser(c);
    await getStore().deletePantry(id, user.deviceId);
    return c.body(null, 204);
  });

  // ---------- plans feed (before :id) ----------
  app.get('/plans/feed.ics', async (c) => {
    const plans = await getStore().listPlans();
    const byId = new Map((await getStore().listRecipes()).map((r) => [r.id, r.title] as const));
    const ics = plansToIcs(plans, (rid) => byId.get(rid ?? '') ?? null);
    return new Response(ics, { headers: { 'content-type': 'text/calendar; charset=utf-8' } });
  });

  // ---------- plans ----------
  app.get('/plans', async (c) => c.json(await getStore().listPlans()));
  app.post('/plans', async (c) => {
    const body = parseOrThrow(planInputSchema, await c.req.json().catch(() => ({})));
    await requireWriteRole(c, getStore(), body.householdId);
    const user = getUser(c);
    return c.json(await getStore().createPlan(body, { deviceId: user.deviceId }), 201);
  });
  app.get('/plans/:id', async (c) => {
    const p = await getStore().getPlan(c.req.param('id'));
    if (!p) return c.json({ error: 'not found' }, 404);
    return c.json(p);
  });
  app.put('/plans/:id', async (c) => {
    const id = c.req.param('id');
    const cur = await getStore().getPlan(id);
    if (!cur) return c.json({ error: 'not found' }, 404);
    const body = parseOrThrow(planInputSchema, await c.req.json().catch(() => ({})));
    await requireWriteRole(c, getStore(), body.householdId ?? cur.householdId);
    const user = getUser(c);
    return c.json(await getStore().updatePlan(id, body, { deviceId: user.deviceId }));
  });
  app.delete('/plans/:id', async (c) => {
    const id = c.req.param('id');
    const cur = await getStore().getPlan(id);
    if (!cur) return c.json({ error: 'not found' }, 404);
    await requireWriteRole(c, getStore(), cur.householdId);
    const user = getUser(c);
    await getStore().deletePlan(id, user.deviceId);
    return c.body(null, 204);
  });

  // ---------- menus ----------
  app.get('/menus', async (c) => c.json(await getStore().listMenus()));
  app.post('/menus', async (c) => {
    const body = parseOrThrow(menuInputSchema, await c.req.json().catch(() => ({})));
    await requireWriteRole(c, getStore(), body.householdId);
    const user = getUser(c);
    return c.json(await getStore().createMenu(body, { deviceId: user.deviceId }), 201);
  });
  app.get('/menus/:id', async (c) => {
    const m = await getStore().getMenu(c.req.param('id'));
    if (!m) return c.json({ error: 'not found' }, 404);
    return c.json(m);
  });
  app.put('/menus/:id', async (c) => {
    const id = c.req.param('id');
    const cur = await getStore().getMenu(id);
    if (!cur) return c.json({ error: 'not found' }, 404);
    const body = parseOrThrow(menuInputSchema, await c.req.json().catch(() => ({})));
    await requireWriteRole(c, getStore(), body.householdId ?? cur.householdId);
    const user = getUser(c);
    return c.json(await getStore().updateMenu(id, body, { deviceId: user.deviceId }));
  });
  app.delete('/menus/:id', async (c) => {
    const id = c.req.param('id');
    const cur = await getStore().getMenu(id);
    if (!cur) return c.json({ error: 'not found' }, 404);
    await requireWriteRole(c, getStore(), cur.householdId);
    const user = getUser(c);
    await getStore().deleteMenu(id, user.deviceId);
    return c.body(null, 204);
  });

  // ---------- share ----------
  app.post('/share/cookbook', async (c) => {
    const body = parseOrThrow(shareRequestSchema, await c.req.json().catch(() => ({})));
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
    const ttl = Number(c.req.query('ttl') ?? DEFAULT_SIGNED_URL_TTL_SECONDS);
    const signed = await signKey(key, { secret, baseUrl, ttlSeconds: Number.isFinite(ttl) ? ttl : DEFAULT_SIGNED_URL_TTL_SECONDS });
    return c.json(signed);
  });

  // ---------- sync ----------
  app.get('/sync/pull', async (c) => {
    const since = c.req.query('since') ?? '1970-01-01T00:00:00Z';
    return c.json(await getStore().pullSince(since));
  });
  app.post('/sync/push', async (c) => {
    const raw = await c.req.json().catch(() => null);
    if (!Array.isArray(raw)) return c.json({ error: 'expected an array of SyncEnvelopes' }, 400);
    const conflicts: SyncEnvelopeWire[] = [];
    for (const item of raw) {
      const env = parseOrThrow(syncEnvelopeSchema, item) as SyncEnvelopeWire;
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
    if (!Array.isArray(raw)) return c.json({ error: 'expected an array of encrypted envelopes' }, 400);
    // Validate-first: parse every envelope (schema + householdHash match +
    // entity set) before writing any, so a bad batch never partially lands.
    const batch: EncryptedEnvelope[] = [];
    for (const item of raw) {
      const entity = (item as { entity?: unknown } | null | undefined)?.entity;
      if (entity === 'ingredient' || entity === 'step') {
        return c.json(
          {
            error: 'standalone ingredient/step envelopes are not accepted; fold children into the parent recipe envelope before encrypting',
            entity,
          },
          422,
        );
      }
      const parsed = parseOrThrow(encryptedEnvelopeSchema, item);
      const env: EncryptedEnvelope = { ...parsed, deleted: parsed.deleted ?? false };
      if (env.householdHash !== hash) return c.json({ error: 'householdHash mismatch' }, 400);
      batch.push(env);
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
      secret: env.PHOTOS_SIGNING_SECRET ?? 'dev-only-change-me',
      // prod derived from PUBLIC_BASE_URL via isProdBaseUrl (workers.dev => prod)
    });
    return app.fetch(request);
  },
};
