import type { Context, Next } from 'hono';
import type { Store } from './store';
import { agentVerifierFor, AGENT_TOKEN_HEADER, type AgentIdentity } from './agent';

// Better Auth stub — PASS 2 will verify the real Apple session cookie/JWT here.
// The app works out of the box against the deployed backend: there is no
// beta-token enrollment. E2E household data stays blind (opaque hash buckets);
// the beta gate below is a passthrough kept only to set the `prod` context
// flag for getUser() role handling.
// PII: user ids/emails are NEVER logged (see logger in index.ts).

export type Role = 'owner' | 'member' | 'viewer';

export interface AuthedUser {
  id: string;
  email: string;
  /** Fallback role when no membership row exists (dev convenience). */
  role: Role;
  deviceId: string;
}

const VALID_ROLES: Role[] = ['owner', 'member', 'viewer'];

/**
 * True when baseUrl looks like a deployed host (prod).
 * Dev hosts (`localhost`, `127.0.0.1`, `*.local`, `test`) stay on the stub.
 * Anything else — including `*.workers.dev` and custom domains — is prod.
 * (Pass 2 replaces the stub with Apple auth.)
 */
export function isProdBaseUrl(baseUrl: string | undefined): boolean {
  if (!baseUrl) return false;
  const u = baseUrl.toLowerCase();
  if (u.includes('localhost') || u.includes('127.0.0.1') || u.includes('.local') || u.includes('test')) return false;
  return true; // workers.dev, custom prod domains
}

/** Extract `Bearer <token>` from Authorization (null when missing/malformed). */
export function bearerToken(c: Context): string | null {
  const h = c.req.header('authorization') ?? '';
  const m = h.match(/^Bearer\s+(.+)$/i);
  return m ? m[1]!.trim() || null : null;
}

/** Constant-time string compare so beta-token probing leaks no timing signal. */
export function timingSafeEqual(a: string, b: string): boolean {
  if (!a || !b || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export function isBetaAuthorized(c: Context, betaToken: string | undefined): boolean {
  if (!betaToken) return false; // fail closed: prod without a token rejects everything
  const provided = bearerToken(c);
  if (!provided) return false;
  return timingSafeEqual(provided, betaToken);
}

/**
 * Prod gate middleware factory.
 * - Open access: every route (including prod) passes through — the app works
 *   out of the box with no token enrollment. E2E household buckets stay
 *   blind via unguessable hashes; v1 RBAC below still applies per household.
 * - `/health` stays unauthenticated; all other routes proceed to authAttach.
 * - Sets the `prod` context flag so getUser() de-escalates x-role.
 * - `betaToken` is accepted but ignored (kept for call-site compat).
 */
export function createBetaGate(opts: { betaToken?: string; prod: boolean }) {
  const { prod } = opts;
  void opts.betaToken; // ignored: open access, no token enrollment
  return async function betaGate(c: Context, next: Next) {
    c.set('prod' as never, prod as never);
    return next();
  };
}

function prodFlag(c: Context): boolean {
  try {
    return (c.get('prod' as never) as boolean) === true;
  } catch {
    return false;
  }
}

export function getUser(c: Context): AuthedUser {
  // Key-only agent identity (#26): a valid x-agent-token beats every header
  // stub in every env — the key holder can already decrypt the whole
  // household, so they are its owner. Scope is enforced per-route by
  // requireAgentScope(), not by role.
  const agent = getAgent(c);
  if (agent) {
    return { id: `agent-${agent.householdHash.slice(0, 8)}`, email: '', role: 'owner', deviceId: agent.deviceId };
  }
  const h = c.req.header.bind(c.req);
  const prod = prodFlag(c);
  if (prod) {
    // PROD: never trust x-role (no header-role escalation). Stored
    // memberships can still upgrade via resolveRole(); header fallback is viewer.
    return {
      id: h('x-user-id') ?? 'beta-user',
      email: h('x-user-email') ?? '',
      role: 'viewer',
      deviceId: h('x-device-id') ?? 'server',
    };
  }
  const roleRaw = (h('x-role') ?? 'owner').toLowerCase();
  const role: Role = (VALID_ROLES as string[]).includes(roleRaw) ? (roleRaw as Role) : 'owner';
  return {
    id: h('x-user-id') ?? 'dev-user',
    email: h('x-user-email') ?? '',
    role,
    deviceId: h('x-device-id') ?? 'server',
  };
}

/** Resolve effective role: stored membership wins, otherwise header fallback. */
export async function resolveRole(
  c: Context,
  store: Store,
  householdId: string | undefined,
): Promise<Role> {
  // Agent requests already proved key possession: owner, scope-checked
  // separately by requireAgentScope().
  if (getAgent(c)) return 'owner';
  const user = getUser(c);
  if (!householdId) return user.role;
  try {
    const m = await store.getMembership(householdId, user.id);
    if (m) return m.role;
  } catch {
    // fall through to header role
  }
  return user.role;
}

/** Block viewers from all mutations. Members and owners may CRUD. */
export async function requireWriteRole(
  c: Context,
  store: Store,
  householdId: string | undefined,
): Promise<Role> {
  const role = await resolveRole(c, store, householdId);
  if (role === 'viewer') {
    const err = new Error('viewer role is read-only') as Error & { status?: number };
    err.status = 403;
    throw err;
  }
  return role;
}

/** Owner-only actions: share links / invites / household deletes. */
export async function requireOwnerRole(
  c: Context,
  store: Store,
  householdId: string | undefined,
): Promise<void> {
  const role = await resolveRole(c, store, householdId);
  if (role !== 'owner') {
    const err = new Error('owner role required') as Error & { status?: number };
    err.status = 403;
    throw err;
  }
}

/** Hono middleware: attach authed user to context. Never logs identity. */
export async function authAttach(c: Context, next: Next) {
  c.set('user' as never, getUser(c) as never);
  await next();
}

/**
 * Key-only agent attach (#26). No header → non-agent path, byte-identical
 * behavior to before. Header present → must verify, else 401 (fail closed).
 * `/health` stays open for liveness probes even with a bad token.
 */
export function agentAttach(store: Store) {
  return async function agentAttachMw(c: Context, next: Next) {
    const tok = c.req.header(AGENT_TOKEN_HEADER);
    if (!tok) return next();
    if (new URL(c.req.url).pathname === '/health') return next();
    const verifier = await agentVerifierFor(tok);
    const enr = verifier ? await store.agentGetByVerifier(verifier) : null;
    if (!enr) {
      const err = new Error('unknown agent token (enroll with POST /agent/enroll)') as Error & { status?: number };
      err.status = 401;
      throw err;
    }
    const id: AgentIdentity = {
      householdId: enr.householdId,
      householdHash: enr.householdHash,
      deviceId: `agent-${enr.householdHash.slice(0, 8)}`,
    };
    c.set('agent' as never, id as never);
    await next();
  };
}

/** Agent identity for this request, or null for human/app callers. */
export function getAgent(c: Context): AgentIdentity | null {
  try {
    return (c.get('agent' as never) as AgentIdentity | null) ?? null;
  } catch {
    return null;
  }
}

/**
 * Scope guard for agent requests: the target household must be the enrolled
 * one (explicit — no silent 'hh-demo' default). No-op for non-agent
 * requests. Throws 403 on mismatch.
 */
export function requireAgentScope(c: Context, householdId: string | undefined): void {
  const a = getAgent(c);
  if (!a) return;
  if (!householdId || householdId !== a.householdId) {
    const err = new Error(
      `agent token is scoped to household '${a.householdId}' — pass that householdId`,
    ) as Error & { status?: number };
    err.status = 403;
    throw err;
  }
}
