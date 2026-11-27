import type { Context, Next } from 'hono';
import type { Store } from './store';

// Auth: single device encryption key (open auth, no login).
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
