import type { Context, Next } from 'hono';
import type { DeviceKey, Store } from './store';
import { agentVerifierFor, AGENT_TOKEN_HEADER, type AgentIdentity } from './agent';

// Auth: Ed25519 device signatures (no bearer tokens, no login).
// Every mutating request (POST/PUT/DELETE/PATCH) carries:
//   x-device-id  - enrolled device id (matches Store.getDevice)
//   x-device-ts  - millis since epoch, digits only, |now - ts| <= 5min
//   x-device-sig - base64 Ed25519 signature over the canonical string:
//     METHOD + "\n" + path+query + "\n" + ts + "\n" + hex(SHA256(bodyBytes))
//   (empty body hashes as hex(SHA256(""))).
// Reads (GET/HEAD/OPTIONS), /health, /openapi.json, and POST /v2/devices
// (enrollment) stay open. Dev hosts (see isProdBaseUrl) keep the x-role
// header stub and skip signature checks.
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

/** A device key as returned by Store.getDevice (see store.ts). */
export type { DeviceKey };

export const DEVICE_ID_HEADER = 'x-device-id';
export const DEVICE_TS_HEADER = 'x-device-ts';
export const DEVICE_SIG_HEADER = 'x-device-sig';

/** Max clock skew for x-device-ts (5 minutes either direction).
 * Known limitation (no nonce/replay cache by design): a captured signed
 * request still verifies until its timestamp ages out of this window.
 * Accepted because sync/e2e writes are LWW-idempotent (stored wins ties),
 * so a replayed write cannot reorder state — it re-applies the same
 * envelope. A durable nonce cache would be the fix if non-idempotent
 * endpoints ever require signatures; an in-memory cache is NOT one
 * (isolates don't share it), so none is shipped. */
export const DEVICE_TS_SKEW_MS = 5 * 60 * 1000;

/** DER prefix wrapping a 32-byte raw Ed25519 key as SPKI (for node:crypto). */
const ED25519_SPKI_DER_PREFIX_HEX = '302a300506032b6570032100';

/** Strict standard-base64 decode (null on any malformation). Both branches
 * re-encode to confirm strictness: unpadded or whitespace-containing input
 * is rejected on Workers (atob) exactly as on Node (Buffer). */
function base64ToBytes(s: string): Uint8Array | null {
  try {
    if (typeof Buffer !== 'undefined') {
      const b = Buffer.from(s, 'base64');
      // Buffer is lenient (skips bad chars): re-encode to confirm strictness.
      if (b.toString('base64') !== s) return null;
      return new Uint8Array(b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength));
    }
    const bin = atob(s);
    const g = globalThis as unknown as { btoa?: (s: string) => string };
    if (typeof g.btoa === 'function') {
      // Re-encode check matching the Buffer branch above.
      if (g.btoa(bin) !== s) return null;
    } else if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{4}|[A-Za-z0-9+/]{3}=|[A-Za-z0-9+/]{2}==)$/.test(s)) {
      return null;
    }
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}

function hexOf(bytes: Uint8Array): string {
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

/**
 * hex(SHA-256(data)). SubtleCrypto first (workers + modern node), node:crypto
 * fallback — same branching pattern as householdHash in e2e.ts.
 */
async function sha256Hex(data: Uint8Array): Promise<string> {
  const g = globalThis as unknown as { crypto?: { subtle?: SubtleCrypto } };
  if (g.crypto?.subtle) {
    const digest = await g.crypto.subtle.digest('SHA-256', Uint8Array.from(data));
    return hexOf(new Uint8Array(digest));
  }
  const { createHash } = await import('node:crypto');
  return createHash('sha256').update(data).digest('hex');
}

/**
 * Ed25519 verify. SubtleCrypto first (Cloudflare Workers and Node >= 22
 * both support { name: 'Ed25519' } importKey/verify — verified at runtime),
 * node:crypto fallback for older runtimes (raw 32-byte key wrapped in SPKI
 * DER). No vendored curve code is needed while both paths exist; if a target
 * runtime ever lacks both, vendor a minimal ed25519 verify here.
 */
async function ed25519Verify(
  publicKey: Uint8Array,
  message: Uint8Array,
  signature: Uint8Array,
): Promise<boolean> {
  const g = globalThis as unknown as { crypto?: { subtle?: SubtleCrypto } };
  if (g.crypto?.subtle) {
    try {
      const key = await g.crypto.subtle.importKey('raw', Uint8Array.from(publicKey), { name: 'Ed25519' }, false, [
        'verify',
      ]);
      return await g.crypto.subtle.verify(
        { name: 'Ed25519' },
        key,
        Uint8Array.from(signature),
        Uint8Array.from(message),
      );
    } catch {
      // Runtime lacks Ed25519 in SubtleCrypto — fall through to node:crypto.
    }
  }
  const { verify, createPublicKey } = await import('node:crypto');
  const prefix = Buffer.from(ED25519_SPKI_DER_PREFIX_HEX, 'hex');
  const spki = Buffer.concat([prefix, Buffer.from(publicKey)]);
  const keyObj = createPublicKey({ key: spki, format: 'der', type: 'spki' });
  return verify(null, Buffer.from(message), keyObj, Buffer.from(signature));
}

/** Canonical signed string (see header comment). Exported for tests/clients. */
export async function deviceCanonicalString(
  method: string,
  pathAndQuery: string,
  ts: string,
  bodyBytes: Uint8Array,
): Promise<string> {
  return `${method}\n${pathAndQuery}\n${ts}\n${await sha256Hex(bodyBytes)}`;
}

function prodFlag(c: Context): boolean {
  try {
    return (c.get('prod' as never) as boolean) === true;
  } catch {
    return false;
  }
}

function verifiedDeviceId(c: Context): string | null {
  try {
    return (c.get('verifiedDeviceId' as never) as string | undefined) ?? null;
  } catch {
    return null;
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
    // After authenticateDevice, user.id is the verified device id.
    const verified = verifiedDeviceId(c);
    return {
      id: verified ?? h('x-user-id') ?? 'beta-user',
      email: h('x-user-email') ?? '',
      role: 'viewer',
      deviceId: verified ?? h('x-device-id') ?? 'server',
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

/**
 * Verify device signature headers against the enrolled device key.
 * Returns the DeviceKey and records the verified id on the context (so
 * getUser() keys v1 RBAC off it). Throws 401 on missing/unknown/bad
 * sig, stale timestamp, or revoked device.
 */
export async function authenticateDevice(c: Context, store: Store): Promise<DeviceKey> {
  const fail = (msg: string): Error & { status?: number } => {
    const err = new Error(msg) as Error & { status?: number };
    err.status = 401;
    return err;
  };
  const deviceId = c.req.header(DEVICE_ID_HEADER) ?? '';
  const ts = c.req.header(DEVICE_TS_HEADER) ?? '';
  const sigB64 = c.req.header(DEVICE_SIG_HEADER) ?? '';
  if (!deviceId || !ts || !sigB64) throw fail('device signature required');
  if (!/^\d{1,20}$/.test(ts)) throw fail('invalid device timestamp');
  const tsNum = Number(ts);
  if (!Number.isSafeInteger(tsNum)) throw fail('invalid device timestamp');
  if (Math.abs(Date.now() - tsNum) > DEVICE_TS_SKEW_MS) throw fail('stale device timestamp');
  const sig = base64ToBytes(sigB64);
  if (!sig || sig.length !== 64) throw fail('invalid device signature');
  // Device lookup via Store.getDevice (enroll-store lane). Unknown ids fail
  // closed with 401 (never 500 — existence of a device is an auth question).
  const device = await store.getDevice(deviceId);
  if (!device) throw fail('unknown device');
  if (device.revokedAt) throw fail('device revoked');
  if (device.publicKey.length !== 32) throw fail('unknown device');
  const url = new URL(c.req.url);
  const pathAndQuery = `${url.pathname}${url.search}`;
  // Hono caches the request body, so handlers can still call c.req.json().
  const bodyBytes = new Uint8Array(await c.req.arrayBuffer());
  const canonical = await deviceCanonicalString(c.req.method, pathAndQuery, ts, bodyBytes);
  let ok = false;
  try {
    ok = await ed25519Verify(device.publicKey, new TextEncoder().encode(canonical), sig);
  } catch {
    ok = false;
  }
  if (!ok) throw fail('bad device signature');
  c.set('verifiedDeviceId' as never, device.deviceId as never);
  return device;
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

/** Block viewers from all mutations. Members and owners may CRUD.
 * First-claim bootstrap (fresh-deploy P1): a household with zero
 * memberships has no owner yet, so the first writer that would otherwise
 * fall back to viewer claims the owner seat (persisted, then allowed).
 * Later devices still need a grant (403 until then). In prod the gate
 * guarantees the claimant holds a valid device signature. */
export async function requireWriteRole(
  c: Context,
  store: Store,
  householdId: string | undefined,
): Promise<Role> {
  const role = await resolveRole(c, store, householdId);
  if (role !== 'viewer') return role;
  if (await maybeFirstClaim(c, store, householdId)) return 'owner';
  const err = new Error('viewer role is read-only') as Error & { status?: number };
  err.status = 403;
  throw err;
}

/** Owner-only actions: share links / invites / household deletes.
 * Same first-claim bootstrap as requireWriteRole: an empty household's
 * first writer becomes owner. */
export async function requireOwnerRole(
  c: Context,
  store: Store,
  householdId: string | undefined,
): Promise<void> {
  const role = await resolveRole(c, store, householdId);
  if (role === 'owner') return;
  if (await maybeFirstClaim(c, store, householdId)) return;
  const err = new Error('owner role required') as Error & { status?: number };
  err.status = 403;
  throw err;
}

/**
 * First-claim: when a household has no memberships at all, persist the
 * caller as owner and report true. Returns false when there is nothing to
 * claim (household unknown/undefined, already populated, or the count
 * lookup failed) — callers then enforce the resolved role as usual.
 */
async function maybeFirstClaim(c: Context, store: Store, householdId: string | undefined): Promise<boolean> {
  if (!householdId) return false;
  let n: number;
  try {
    n = await store.countMemberships(householdId);
  } catch {
    return false;
  }
  if (n !== 0) return false;
  const user = getUser(c);
  await store.setMembership(householdId, user.id, 'owner');
  return true;
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
    // Missing header → non-agent path. A PRESENT header (even empty) must
    // verify or 401 — an empty value is not "no header" (fail closed).
    if (tok === undefined) return next();
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
