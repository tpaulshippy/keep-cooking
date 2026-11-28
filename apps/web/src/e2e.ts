// Web E2E V1 sync — parity with apps/ios/Sync (SyncCrypto.swift /
// SyncEngine.swift) and apps/android sync/E2E (SyncCrypto.kt / SyncEngine.kt),
// against the locked interfaces (see docs/e2e-v1.md):
//   - householdHash = hex SHA-256("smidgen-hh-v1"||syncCode||householdId)
//   - Data key = HKDF-SHA256(IKM syncCode, salt "smidgen-sync-v1",
//     info "smidgen-sync-v1/hh:<householdId>/kid:<kid>"), 32 bytes (WebCrypto)
//   - AES-GCM-256 envelopes (v:2) on PUT/GET /v2/sync/:hash; the header is
//     bound as associated data (AD_CTX below, JSON string-array encoding).
//   - kid = first 12 chars of base64url(SHA-256(syncCode UTF-8)).
//   - Invite bundle {v:"2", householdId, syncCode, kid, hash, endpointHint?};
//     the receiver verifies hash AND kid before storing anything.
// The syncCode lives in localStorage (this browser has no Keychain); anyone
// with this browser profile can read it — same warning as native loss notes.

import { Store, type SyncEnvelope } from './store';

export const HH_DOMAIN = 'smidgen-hh-v1';
export const HKDF_SALT = 'smidgen-sync-v1';
export const AD_CTX = 'smidgen-e2e-ad-v1';
export const E2E_MAX_PUSH_BATCH = 500;

export interface EncryptedEnvelope {
  v: 2;
  alg: 'AES-GCM-256';
  kid: string;
  householdHash: string;
  id: string;
  entity: SyncEnvelope['entity'];
  updatedAt: string; // millis-precision ISO-8601, fixed 3 fractional digits
  deviceId: string;
  deleted: boolean;
  nonce: string; // standard base64 (padded), 12 bytes
  ciphertext: string; // standard base64 (padded), raw-ciphertext || 16-byte tag
}

export interface E2EIdentity {
  householdId: string;
  kid: string;
  hash: string;
}

export interface InviteBundle extends E2EIdentity {
  syncCode: string;
  endpointHint?: string;
}

// ---- base64 (standard alphabet, padded — what the server validates) ----

export function b64encode(bytes: Uint8Array<ArrayBuffer>): string {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}

export function b64decode(s: string): Uint8Array<ArrayBuffer> {
  const bin = atob(s.trim());
  const out = new Uint8Array(new ArrayBuffer(bin.length));
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function utf8(s: string): Uint8Array<ArrayBuffer> {
  return Uint8Array.from(new TextEncoder().encode(s));
}

function b64urlNoPad(bytes: Uint8Array<ArrayBuffer>): string {
  return b64encode(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

// ---- hashes / ids ----

async function sha256(data: Uint8Array<ArrayBuffer>): Promise<Uint8Array<ArrayBuffer>> {
  const digest = await crypto.subtle.digest('SHA-256', Uint8Array.from(data));
  return new Uint8Array(digest);
}

export async function householdHash(syncCode: string, householdId: string): Promise<string> {
  const digest = await sha256(utf8(HH_DOMAIN + syncCode + householdId));
  return [...digest].map((b) => b.toString(16).padStart(2, '0')).join('');
}

export async function kidOf(syncCode: string): Promise<string> {
  const digest = await sha256(utf8(syncCode));
  return b64urlNoPad(digest).slice(0, 12);
}

export function hashPrefix8(hash: string): string {
  return hash.slice(0, 8);
}

/** Millis-precision wire time: always exactly 3 fractional digits. */
export function e2eWireString(date: Date): string {
  return date.toISOString();
}

/** Canonical AD binding the sealed payload to its plaintext routing header. */
export function headerAD(parts: {
  kid: string; householdHash: string; id: string; updatedAtMillis: number;
  deviceId: string; deleted: boolean; entity: string;
}): Uint8Array<ArrayBuffer> {
  const arr = [
    AD_CTX, '2', 'AES-GCM-256', parts.kid, parts.householdHash, parts.id,
    String(parts.updatedAtMillis), parts.deviceId, parts.deleted ? '1' : '0', parts.entity,
  ];
  return Uint8Array.from(new TextEncoder().encode(JSON.stringify(arr)));
}

async function deriveKey(syncCode: string, householdId: string, kid: string): Promise<CryptoKey> {
  const ikm = await crypto.subtle.importKey(
    'raw', utf8(syncCode), 'HKDF', false, ['deriveKey'],
  );
  return crypto.subtle.deriveKey(
    {
      name: 'HKDF',
      hash: 'SHA-256',
      salt: utf8(HKDF_SALT),
      info: utf8(`smidgen-sync-v1/hh:${householdId}/kid:${kid}`),
    },
    ikm,
    { name: 'AES-GCM', length: 256 },
    false,
    ['encrypt', 'decrypt'],
  );
}

// ---- seal / open ----

export async function e2eEncrypt(env: SyncEnvelope, identity: E2EIdentity, syncCode: string): Promise<EncryptedEnvelope> {
  const sealedAt = new Date(Date.parse(env.updatedAt));
  if (Number.isNaN(sealedAt.getTime())) throw new Error(`bad updatedAt for ${env.id}`);
  const millis = sealedAt.getTime();
  const ad = headerAD({
    kid: identity.kid, householdHash: identity.hash, id: env.id,
    updatedAtMillis: millis, deviceId: env.deviceId, deleted: !!env.deleted, entity: env.entity,
  });
  const key = await deriveKey(syncCode, identity.householdId, identity.kid);
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv: nonce, additionalData: ad },
    key,
    utf8(JSON.stringify(env.payload ?? {})),
  );
  return {
    v: 2,
    alg: 'AES-GCM-256',
    kid: identity.kid,
    householdHash: identity.hash,
    id: env.id,
    entity: env.entity,
    updatedAt: e2eWireString(sealedAt),
    deviceId: env.deviceId,
    deleted: !!env.deleted,
    nonce: b64encode(nonce),
    ciphertext: b64encode(new Uint8Array(ciphertext)),
  };
}

export async function e2eDecrypt(enc: EncryptedEnvelope, identity: E2EIdentity, syncCode: string): Promise<SyncEnvelope> {
  if (enc.v !== 2) throw new Error(`unsupported envelope version ${enc.v}`);
  if (enc.alg !== 'AES-GCM-256') throw new Error(`unsupported alg ${enc.alg}`);
  const millis = Date.parse(enc.updatedAt);
  if (Number.isNaN(millis)) throw new Error(`bad updatedAt for ${enc.id}`);
  const ad = headerAD({
    kid: enc.kid, householdHash: enc.householdHash, id: enc.id,
    updatedAtMillis: millis, deviceId: enc.deviceId, deleted: !!enc.deleted, entity: enc.entity,
  });
  const key = await deriveKey(syncCode, identity.householdId, identity.kid);
  let plain: ArrayBuffer;
  try {
    plain = await crypto.subtle.decrypt(
      { name: 'AES-GCM', iv: b64decode(enc.nonce), additionalData: ad },
      key,
      b64decode(enc.ciphertext),
    );
  } catch {
    throw new Error(`decrypt failed for ${enc.id}`);
  }
  let payload: unknown;
  try {
    payload = JSON.parse(new TextDecoder().decode(plain));
  } catch (e) {
    throw new Error(`payload decode: ${e instanceof Error ? e.message : e}`);
  }
  if (payload === null || typeof payload !== 'object' || Array.isArray(payload)) {
    throw new Error(`payload decode for ${enc.id}`);
  }
  return {
    id: enc.id,
    updatedAt: enc.updatedAt,
    deviceId: enc.deviceId,
    deleted: !!enc.deleted,
    entity: enc.entity,
    payload,
  };
}

// ---- invite bundle JSON (out-of-band transport: copy / share) ----

export function inviteBundleJson(bundle: InviteBundle): string {
  const obj: Record<string, string> = {
    v: '2',
    householdId: bundle.householdId,
    syncCode: bundle.syncCode,
    kid: bundle.kid,
    hash: bundle.hash,
  };
  if (bundle.endpointHint) obj.endpointHint = bundle.endpointHint;
  return JSON.stringify(obj);
}

export async function parseInviteBundle(pasted: string): Promise<InviteBundle> {
  let obj: Record<string, unknown>;
  try {
    obj = JSON.parse(pasted.trim()) as Record<string, unknown>;
  } catch {
    throw new Error('That text is not a Keep Cooking invite code.');
  }
  if (obj === null || typeof obj !== 'object' || Array.isArray(obj)) {
    throw new Error('That text is not a Keep Cooking invite code.');
  }
  const v = obj['v'];
  const householdId = obj['householdId'];
  const syncCode = obj['syncCode'];
  const kid = obj['kid'];
  const hash = obj['hash'];
  const endpointHint = obj['endpointHint'];
  if (
    v !== '2' ||
    typeof householdId !== 'string' || !householdId ||
    typeof syncCode !== 'string' || !syncCode ||
    typeof kid !== 'string' || !kid ||
    typeof hash !== 'string' || !hash
  ) {
    throw new Error('That text is not a Keep Cooking invite code.');
  }
  if ((await householdHash(syncCode, householdId)) !== hash) {
    throw new Error('Code does not match — it was mistyped or tampered with.');
  }
  if ((await kidOf(syncCode)) !== kid) {
    throw new Error('Key ID mismatch — code was created by an incompatible app.');
  }
  const bundle: InviteBundle = { householdId, syncCode, kid, hash };
  if (typeof endpointHint === 'string' && endpointHint) bundle.endpointHint = endpointHint;
  return bundle;
}

// ---- local identity storage (localStorage; no Keychain on web) ----

const LS_META = 'kc.e2e.meta';
const LS_CURSOR = 'kc.e2e.lastPulledAt';

function secretKeyFor(hash: string): string {
  return `kc.e2e.code.${hashPrefix8(hash)}`;
}

export interface E2EMetadata extends E2EIdentity {
  endpointHint?: string;
}

export function loadMetadata(): E2EMetadata | null {
  try {
    const raw = localStorage.getItem(LS_META);
    if (!raw) return null;
    const m = JSON.parse(raw) as E2EMetadata;
    if (!m.householdId || !m.kid || !m.hash) return null;
    return m;
  } catch {
    return null;
  }
}

function loadSecret(hash: string): string | null {
  try {
    return localStorage.getItem(secretKeyFor(hash));
  } catch {
    return null;
  }
}

/** Active credential: metadata + secret, re-verified (hash == derive). */
export async function loadActive(): Promise<{ metadata: E2EMetadata; syncCode: string } | null> {
  const meta = loadMetadata();
  if (!meta) return null;
  const code = loadSecret(meta.hash);
  if (!code) return null;
  if ((await householdHash(code, meta.householdId)) !== meta.hash) return null;
  return { metadata: meta, syncCode: code };
}

/** Verifies the bundle, then stores the secret + metadata. Secret commits first. */
export async function acceptInvite(bundle: InviteBundle): Promise<boolean> {
  if ((await householdHash(bundle.syncCode, bundle.householdId)) !== bundle.hash) return false;
  if ((await kidOf(bundle.syncCode)) !== bundle.kid) return false;
  try {
    localStorage.setItem(secretKeyFor(bundle.hash), bundle.syncCode);
    const meta: E2EMetadata = {
      householdId: bundle.householdId,
      kid: bundle.kid,
      hash: bundle.hash,
    };
    if (bundle.endpointHint) meta.endpointHint = bundle.endpointHint;
    localStorage.setItem(LS_META, JSON.stringify(meta));
  } catch {
    return false;
  }
  return true;
}

/** Fresh household identity (random 32-byte standard-base64 syncCode). */
export async function ensureE2EIdentity(householdId: string): Promise<{ metadata: E2EMetadata; syncCode: string } | null> {
  const active = await loadActive();
  if (active) return active;
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  const syncCode = b64encode(bytes);
  const hh = householdId.trim() || 'hh-demo';
  const kid = await kidOf(syncCode);
  const hash = await householdHash(syncCode, hh);
  const ok = await acceptInvite({ householdId: hh, syncCode, kid, hash });
  if (!ok) return null;
  return loadActive();
}

// ---- pull cursor (envelope time, monotonic; rewound 1s on read) ----

export function loadPullCursor(): Date | null {
  try {
    const raw = localStorage.getItem(LS_CURSOR);
    if (!raw) return null;
    const d = new Date(raw);
    return Number.isNaN(d.getTime()) ? null : d;
  } catch {
    return null;
  }
}

export function pullSince(): string | null {
  const cursor = loadPullCursor();
  if (!cursor) return null;
  return new Date(cursor.getTime() - 1000).toISOString();
}

export function advancePullCursor(remote: { updatedAt: string }[]): void {
  let max = 0;
  for (const env of remote) {
    const t = Date.parse(env.updatedAt);
    if (!Number.isNaN(t) && t > max) max = t;
  }
  if (!max) return;
  try {
    const prev = loadPullCursor()?.getTime() ?? 0;
    if (max > prev) localStorage.setItem(LS_CURSOR, new Date(max).toISOString());
  } catch { /* ignore */ }
}

export function resetPullCursor(): void {
  try {
    localStorage.removeItem(LS_CURSOR);
  } catch { /* ignore */ }
}
