// MCP server (#26, thin second interface): stateless JSON-RPC 2.0 over
// POST /mcp on the SAME Worker — no Durable Objects, no new hosting, no new
// deps. Every tool delegates to the same Store methods as the REST routes
// above (same validation, same LWW/tombstone semantics). Auth is per-request
// via x-agent-token (see agent.ts); there is no session state, so any
// isolate can serve any call. Tool schemas are versioned in
// packages/contracts/mcp-tools.json, served verbatim by tools/list.

import { newId, type Store } from './store';
import type { AgentIdentity } from './agent';
import {
  parseOrThrow,
  recipeInputSchema,
  shoppingListInputSchema,
  pantryInputSchema,
  planInputSchema,
  menuInputSchema,
  scaleRequestSchema,
  shareRequestSchema,
} from './zod';
import { validateE2EPushBatch, type EncryptedEnvelope } from './e2e';
import { clipRecipe } from './clip';
import { scaleRecipe } from './scale';
import { recipeToHtml, recipeToMarkdown, plansToIcs } from './export';
import { signKey } from './photos';
import mcpTools from '../../packages/contracts/mcp-tools.json';

export const MCP_PROTOCOL_VERSION = '2026-07-28';
export const MCP_SERVER_NAME = 'keep-cooking-agent';
export const MCP_SERVER_VERSION = '0.1.0';

interface JsonRpcRequest {
  jsonrpc?: unknown;
  id?: string | number | null;
  method?: unknown;
  params?: unknown;
}

function rpcOk(id: string | number | null, result: unknown) {
  return { status: 200 as const, body: { jsonrpc: '2.0', id, result } };
}

function rpcErr(id: string | number | null | undefined, code: number, message: string, http: 200 | 401 = 200) {
  return { status: http, body: { jsonrpc: '2.0', id: id ?? null, error: { code, message } } };
}

/** Tool-level failure: MCP tools/call reports isError, not a protocol error. */
function toolError(message: string) {
  return { content: [{ type: 'text', text: message }], isError: true };
}

function toolOk(data: unknown) {
  return { content: [{ type: 'text', text: typeof data === 'string' ? data : JSON.stringify(data) }] };
}

function httpError(status: number, message: string): Error & { status: number } {
  const err = new Error(message) as Error & { status: number };
  err.status = status;
  return err;
}

type McpOpts = { secret: string; baseUrl: string };
type Params = Record<string, unknown>;
type Handler = (store: Store, agent: AgentIdentity, params: Params, opts: McpOpts) => Promise<unknown>;

/** Household for a mutation: explicit param or the enrolled one; never another. */
function scopedHousehold(agent: AgentIdentity, params: Params): string {
  const h = typeof params['householdId'] === 'string' && params['householdId'] ? params['householdId'] : agent.householdId;
  if (h !== agent.householdId) throw httpError(403, `tool is scoped to household '${agent.householdId}'`);
  return h;
}

function strParam(params: Params, name: string, required = true): string {
  const v = params[name];
  if (typeof v !== 'string' || !v) {
    if (!required) return '';
    throw httpError(400, `missing required param '${name}'`);
  }
  return v;
}

/** Single-entity read guard: out-of-scope reads look like 404 (no oracle). */
function scopeOr404<T extends { householdId: string }>(agent: AgentIdentity, row: T | null): T {
  if (!row || row.householdId !== agent.householdId) throw httpError(404, 'not found');
  return row;
}

const handlers: Record<string, Handler> = {
  // ---------- recipes ----------
  recipe_list: async (store, agent) => store.listRecipes(agent.householdId),
  recipe_get: async (store, agent, p) => scopeOr404(agent, await store.getRecipe(strParam(p, 'id'))),
  recipe_create: async (store, agent, p, _o) => {
    const { id: _drop, ...rest } = p;
    void _drop;
    const body = parseOrThrow(recipeInputSchema, { ...rest, householdId: scopedHousehold(agent, p) });
    return store.createRecipe(body, { deviceId: agent.deviceId });
  },
  recipe_update: async (store, agent, p) => {
    const id = strParam(p, 'id');
    const cur = scopeOr404(agent, await store.getRecipe(id));
    const { id: _drop, ...rest } = p;
    void _drop;
    void cur;
    const body = parseOrThrow(recipeInputSchema, { ...rest, householdId: scopedHousehold(agent, p) });
    const r = await store.updateRecipe(id, body, { deviceId: agent.deviceId });
    if (!r) throw httpError(404, 'not found');
    return r;
  },
  recipe_delete: async (store, agent, p) => {
    const id = strParam(p, 'id');
    scopeOr404(agent, await store.getRecipe(id));
    await store.deleteRecipe(id, agent.deviceId);
    return { deleted: id };
  },
  // ---------- lists ----------
  list_list: async (store, agent) => (await store.listLists()).filter((l) => l.householdId === agent.householdId),
  list_get: async (store, agent, p) => scopeOr404(agent, await store.getList(strParam(p, 'id'))),
  list_create: async (store, agent, p) => {
    const { id: _drop, ...rest } = p;
    void _drop;
    const body = parseOrThrow(shoppingListInputSchema, { ...rest, householdId: scopedHousehold(agent, p) });
    return store.createList(body, { deviceId: agent.deviceId });
  },
  list_update: async (store, agent, p) => {
    const id = strParam(p, 'id');
    scopeOr404(agent, await store.getList(id));
    const { id: _drop, ...rest } = p;
    void _drop;
    const body = parseOrThrow(shoppingListInputSchema, { ...rest, householdId: scopedHousehold(agent, p) });
    const l = await store.updateList(id, body, { deviceId: agent.deviceId });
    if (!l) throw httpError(404, 'not found');
    return l;
  },
  list_delete: async (store, agent, p) => {
    const id = strParam(p, 'id');
    scopeOr404(agent, await store.getList(id));
    await store.deleteList(id, agent.deviceId);
    return { deleted: id };
  },
  // ---------- pantry ----------
  pantry_list: async (store, agent) => (await store.listPantry()).filter((x) => x.householdId === agent.householdId),
  pantry_create: async (store, agent, p) => {
    const { id: _drop, ...rest } = p;
    void _drop;
    const body = parseOrThrow(pantryInputSchema, { ...rest, householdId: scopedHousehold(agent, p) });
    return store.createPantry(body, { deviceId: agent.deviceId });
  },
  pantry_update: async (store, agent, p) => {
    const id = strParam(p, 'id');
    scopeOr404(agent, await store.getPantry(id));
    const { id: _drop, ...rest } = p;
    void _drop;
    const body = parseOrThrow(pantryInputSchema, { ...rest, householdId: scopedHousehold(agent, p) });
    const r = await store.updatePantry(id, body, { deviceId: agent.deviceId });
    if (!r) throw httpError(404, 'not found');
    return r;
  },
  pantry_delete: async (store, agent, p) => {
    const id = strParam(p, 'id');
    scopeOr404(agent, await store.getPantry(id));
    await store.deletePantry(id, agent.deviceId);
    return { deleted: id };
  },
  // ---------- plans ----------
  plan_list: async (store, agent) => (await store.listPlans()).filter((x) => x.householdId === agent.householdId),
  plan_get: async (store, agent, p) => scopeOr404(agent, await store.getPlan(strParam(p, 'id'))),
  plan_create: async (store, agent, p) => {
    const { id: _drop, ...rest } = p;
    void _drop;
    const body = parseOrThrow(planInputSchema, { ...rest, householdId: scopedHousehold(agent, p) });
    return store.createPlan(body, { deviceId: agent.deviceId });
  },
  plan_update: async (store, agent, p) => {
    const id = strParam(p, 'id');
    scopeOr404(agent, await store.getPlan(id));
    const { id: _drop, ...rest } = p;
    void _drop;
    const body = parseOrThrow(planInputSchema, { ...rest, householdId: scopedHousehold(agent, p) });
    const r = await store.updatePlan(id, body, { deviceId: agent.deviceId });
    if (!r) throw httpError(404, 'not found');
    return r;
  },
  plan_delete: async (store, agent, p) => {
    const id = strParam(p, 'id');
    scopeOr404(agent, await store.getPlan(id));
    await store.deletePlan(id, agent.deviceId);
    return { deleted: id };
  },
  plan_feed: async (store, agent) => {
    const plans = (await store.listPlans()).filter((x) => x.householdId === agent.householdId);
    const byId = new Map((await store.listRecipes(agent.householdId)).map((r) => [r.id, r.title] as const));
    return { format: 'text/calendar', content: plansToIcs(plans, (rid) => byId.get(rid ?? '') ?? null) };
  },
  // ---------- menus ----------
  menu_list: async (store, agent) => (await store.listMenus()).filter((x) => x.householdId === agent.householdId),
  menu_get: async (store, agent, p) => scopeOr404(agent, await store.getMenu(strParam(p, 'id'))),
  menu_create: async (store, agent, p) => {
    const { id: _drop, ...rest } = p;
    void _drop;
    const body = parseOrThrow(menuInputSchema, { ...rest, householdId: scopedHousehold(agent, p) });
    return store.createMenu(body, { deviceId: agent.deviceId });
  },
  menu_update: async (store, agent, p) => {
    const id = strParam(p, 'id');
    scopeOr404(agent, await store.getMenu(id));
    const { id: _drop, ...rest } = p;
    void _drop;
    const body = parseOrThrow(menuInputSchema, { ...rest, householdId: scopedHousehold(agent, p) });
    const r = await store.updateMenu(id, body, { deviceId: agent.deviceId });
    if (!r) throw httpError(404, 'not found');
    return r;
  },
  menu_delete: async (store, agent, p) => {
    const id = strParam(p, 'id');
    scopeOr404(agent, await store.getMenu(id));
    await store.deleteMenu(id, agent.deviceId);
    return { deleted: id };
  },
  // ---------- clip / ingest ----------
  clip: async (_store, _agent, p) => {
    const url = typeof p['url'] === 'string' ? p['url'] : undefined;
    const caption = typeof p['caption'] === 'string' ? p['caption'] : undefined;
    const { log: _log, ...report } = await clipRecipe({ url, caption });
    void _log;
    return report;
  },
  scale_recipe: async (store, agent, p) => {
    const r = scopeOr404(agent, await store.getRecipe(strParam(p, 'id')));
    const { servings } = parseOrThrow(scaleRequestSchema, { servings: Number(p['servings']) });
    const { ingredients } = scaleRecipe(r.ingredients, r.servings, servings);
    return { ...r, servings, ingredients };
  },
  // ---------- share / export ----------
  share_cookbook: async (store, agent, p, opts) => {
    // Same bounds as REST POST /share/cookbook: expiresInDays is an int in
    // [1, 365] (default 30), recipeIds is 1..500 non-empty ids — and every
    // id must belong to the enrolled household (out-of-scope reads 404).
    const parsed = parseOrThrow(shareRequestSchema, { ...p, householdId: scopedHousehold(agent, p) });
    for (const rid of parsed.recipeIds) scopeOr404(agent, await store.getRecipe(rid));
    const id = newId();
    const expiresAt = new Date(Date.now() + (parsed.expiresInDays ?? 30) * 86400_000).toISOString();
    const s = await store.createShare({ id, householdId: parsed.householdId, recipeIds: parsed.recipeIds, url: `${opts.baseUrl}/s/${id}`, expiresAt });
    return { id: s.id, url: s.url, expiresAt: s.expiresAt };
  },
  export_recipe: async (store, agent, p) => {
    const r = scopeOr404(agent, await store.getRecipe(strParam(p, 'id')));
    const format = p['format'] === 'md' || p['format'] === 'html' ? p['format'] : 'json';
    if (format === 'md') return { format, content: recipeToMarkdown(r) };
    if (format === 'html') return { format, content: recipeToHtml(r) };
    return r;
  },
  // ---------- sync (blind v2 pull/push) ----------
  sync_pull: async (store, agent, p) => {
    const since = typeof p['since'] === 'string' && p['since'] ? p['since'] : '1970-01-01T00:00:00.000Z';
    const parsed = new Date(since);
    if (Number.isNaN(parsed.getTime())) throw httpError(400, 'invalid since');
    return store.e2eList(agent.householdHash, parsed.toISOString());
  },
  sync_push: async (store, agent, p) => {
    // Surface field-level schema issues to the agent: parseOrThrow attaches
    // them as `details`, but the tool envelope only carries a message.
    let batch: EncryptedEnvelope[];
    try {
      batch = validateE2EPushBatch(agent.householdHash, p['envelopes']);
    } catch (e) {
      if (e instanceof Error) {
        const details = (e as Error & { details?: unknown }).details;
        if (details !== undefined) e.message = `${e.message}: ${JSON.stringify(details)}`;
      }
      throw e;
    }
    const stored: string[] = [];
    for (const env of batch) {
      if (await store.e2ePut(agent.householdHash, env)) stored.push(env.id);
    }
    return { stored };
  },
  // ---------- photos ----------
  photos_sign: async (store, agent, p, opts) => {
    const key = strParam(p, 'key');
    const m = key.match(/^photos\/([^/]+)\/(original|1024|thumb)\.jpg$/);
    if (m) {
      const r = await store.getRecipe(m[1]!);
      if (r && r.householdId !== agent.householdId) throw httpError(403, 'photo is outside the enrolled household');
    }
    // Contract (mcp-tools.json) promises integer ttl in [1, 899] (photos.ts
    // MAX_SIGNED_URL_TTL_SECONDS - 1): enforce it here so ttl 0 / negative
    // (already-expired URL) or fractional values never reach signKey.
    const ttl = typeof p['ttl'] === 'number' ? p['ttl'] : undefined;
    if (ttl !== undefined && (!Number.isInteger(ttl) || ttl < 1 || ttl > 899)) {
      throw httpError(400, "ttl must be an integer in [1, 899]");
    }
    return signKey(key, { secret: opts.secret, baseUrl: opts.baseUrl, ...(ttl !== undefined ? { ttlSeconds: ttl } : {}) });
  },
};

export function mcpToolNames(): string[] {
  return (mcpTools as { tools: { name: string }[] }).tools.map((t) => t.name);
}

/**
 * Stateless JSON-RPC dispatcher. Returns {status, body}; auth failures are
 * HTTP 401 (also JSON-RPC shaped). Unknown handler names are a server
 * registry bug — tools/list is authoritative, so treat as -32601.
 */
export async function handleMcp(
  store: Store,
  opts: McpOpts,
  body: unknown,
  agent: AgentIdentity | null,
): Promise<{ status: 200 | 202 | 401; body: unknown }> {
  const req = (body ?? {}) as JsonRpcRequest;
  if (typeof req !== 'object' || req.method === undefined || req.jsonrpc !== '2.0') {
    return rpcErr(undefined, -32600, 'invalid request', 200);
  }
  const id = req.id === undefined ? null : (req.id as string | number | null);
  const method = String(req.method);

  if (method === 'notifications/initialized' || method.startsWith('notifications/')) {
    // Streamable HTTP: bare notifications get 202 with NO body (null lets the
    // route send an empty response instead of JSON). A notification carrying
    // an `id` is acknowledged with an empty result (200) — real clients send
    // id-bearing notifications and must not hang waiting for a reply.
    if (req.id !== undefined && req.id !== null) return rpcOk(req.id as string | number, {});
    return { status: 202, body: null };
  }
  if (method === 'initialize') {
    return rpcOk(id, {
      protocolVersion: MCP_PROTOCOL_VERSION,
      capabilities: { tools: { listChanged: false } },
      serverInfo: { name: MCP_SERVER_NAME, version: MCP_SERVER_VERSION },
    });
  }
  if (!agent) {
    return rpcErr(id, -32001, 'missing or unknown x-agent-token (enroll with POST /agent/enroll)', 401);
  }
  if (method === 'ping') return rpcOk(id, {});
  if (method === 'tools/list') {
    return rpcOk(id, { tools: (mcpTools as { tools: unknown[] }).tools });
  }
  if (method === 'tools/call') {
    const params = (req.params ?? {}) as { name?: unknown; arguments?: unknown };
    const name = typeof params.name === 'string' ? params.name : '';
    // Own-property lookup: a plain-object index would resolve inherited
    // names like 'constructor'/'toString' to Object.prototype members.
    const handler = Object.prototype.hasOwnProperty.call(handlers, name)
      ? handlers[name]
      : undefined;
    if (!handler) return rpcErr(id, -32601, `unknown tool '${name}'`);
    const args = (params.arguments ?? {}) as Params;
    if (typeof args !== 'object' || args === null || Array.isArray(args)) {
      return rpcOk(id, toolError(`invalid params for tool '${name}': arguments must be an object`));
    }
    try {
      const out = await handler(store, agent, args, opts);
      return rpcOk(id, toolOk(out));
    } catch (e) {
      const msg = e instanceof Error ? e.message : 'tool failed';
      return rpcOk(id, toolError(msg));
    }
  }
  return rpcErr(id, -32601, `unknown method '${method}'`);
}
