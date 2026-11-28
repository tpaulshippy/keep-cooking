// Keep Cooking key-only agent client — dependency-free (WebCrypto only).
// Works in Node 18+, browsers, and Workers. No npm packages, no secrets on
// disk: the syncCode is passed in by the caller (env var, Keychain, prompt)
// and never logged or persisted by this module.
//
// KDF (locked, must match api/src/*.ts + api/test/agent.test.ts vectors):
//   kid           = base64url(SHA256(syncCode UTF-8))[:12]
//   householdHash = hex(SHA256("smidgen-hh-v1" || syncCode || householdId))
//   dataKey       = HKDF-SHA256(IKM: syncCode, salt: "smidgen-sync-v1",
//                   info: "smidgen-sync-v1/hh:<householdId>/kid:<kid>", L: 32)
//   agentToken    = base64url(HKDF-SHA256(IKM: syncCode, salt: "smidgen-agent-v1",
//                   info: "smidgen-agent-v1/hh:<householdId>/kid:<kid>", L: 32))
//   verifier      = hex(SHA256(raw agent-token bytes))
//
// Wire encodings: envelope nonce/ciphertext are STANDARD base64 with padding
// (server schema requires it); kid/token are base64url without padding.
//
// AGENT TIMESTAMP RULE (app interop): agent-sealed envelopes MUST use a
// whole-SECOND updatedAt (ms=000, wire `...T..:..:.000Z`). The two apps
// disagree on nonzero-millis envelopes — iOS `e2eHeaderAD` binds whole
// MILLISECONDS (SyncCrypto.swift) while Android `canonicalE2EMillis` floors
// to whole SECONDS (SyncCrypto.kt), so a nonzero-ms envelope sealed by one
// side fails AD authentication on the other (and Android's pull has no
// per-envelope error handling, so one bad envelope blocks the household).
// Flooring to whole seconds in the agent makes both formulas agree
// (floor(ms) == ms when ms=000), so agent envelopes open on BOTH current
// implementations. Do NOT touch apps/ to "fix" this here — the app-side gap
// is out of scope; the agent just never emits fractional seconds.
//
// SAME-SECOND TIES: the server keeps the earlier envelope when two seals of
// one entity share a timestamp (LWW on strictly-greater updatedAt), so two
// rapid seals inside one second would silently drop the second. To prevent
// that, encryptEnvelope bumps a floored value that is not ahead of the
// previous seal forward to the next whole second (module-level lastMillis) —
// rapid seals are whole-second AND strictly increasing, so both land.

const enc = new TextEncoder();
const dec = new TextDecoder();

export function bytesToB64(bytes) {
  let s = '';
  const arr = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  for (let i = 0; i < arr.length; i += 0x8000) {
    s += String.fromCharCode.apply(null, arr.subarray(i, i + 0x8000));
  }
  return btoa(s);
}

export function b64ToBytes(s) {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

export function bytesToB64Url(bytes) {
  return bytesToB64(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export function bytesToHex(bytes) {
  return [...new Uint8Array(bytes)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

async function hkdf(ikmStr, salt, info) {
  const ikm = await crypto.subtle.importKey('raw', enc.encode(ikmStr), 'HKDF', false, ['deriveBits']);
  const bits = await crypto.subtle.deriveBits(
    { name: 'HKDF', hash: 'SHA-256', salt: enc.encode(salt), info: enc.encode(info) },
    ikm,
    256,
  );
  return new Uint8Array(bits);
}

/** Derive every client value from the device encryption key alone. */
export async function deriveAll(syncCode, householdId) {
  const kid = bytesToB64Url(await crypto.subtle.digest('SHA-256', enc.encode(syncCode))).slice(0, 12);
  const householdHash = bytesToHex(
    await crypto.subtle.digest('SHA-256', enc.encode(`smidgen-hh-v1${syncCode}${householdId}`)),
  );
  const agentRaw = await hkdf(syncCode, 'smidgen-agent-v1', `smidgen-agent-v1/hh:${householdId}/kid:${kid}`);
  const dataKey = await hkdf(syncCode, 'smidgen-sync-v1', `smidgen-sync-v1/hh:${householdId}/kid:${kid}`);
  return {
    kid,
    householdHash,
    hashPrefix8: householdHash.slice(0, 8),
    token: bytesToB64Url(agentRaw),
    verifier: bytesToHex(await crypto.subtle.digest('SHA-256', agentRaw)),
    dataKey,
  };
}

/** Domain separator for the E2E header associated-data binding. Must match
 * `e2eADContext` (iOS SyncCrypto.swift) / `E2E_AD_CONTEXT` (Android
 * SyncCrypto.kt): AES-GCM authenticates (but does not encrypt) these bytes,
 * so a blind-server header swap fails open instead of decrypting under a
 * forged header. Encoded as a JSON string array — deterministic. */
export const E2E_AD_CONTEXT = 'smidgen-e2e-ad-v1';

/**
 * Canonical associated data binding the sealed payload to its plaintext
 * routing header. Parts (all strings): [context, v, alg, kid,
 * householdHash, id, updatedAtMillis, deviceId, deletedFlag, entity].
 * `updatedAt` binds whole MILLISECONDS parsed from the exact wire string —
 * the same value both sides recompute after the JSON round-trip.
 *
 * AGENT RULE: callers MUST pass a whole-second wire string here (see
 * `canonicalE2EUpdatedAt`). Whole-second input makes the iOS millisecond
 * formula and the Android floor-to-seconds formula produce the SAME value,
 * so the envelope authenticates on both current app implementations.
 */
export function e2eHeaderAD({ v = 2, alg = 'AES-GCM-256', kid, householdHash, id, updatedAt, deviceId, deleted = false, entity }) {
  const millis = Math.floor(Date.parse(updatedAt));
  const parts = [E2E_AD_CONTEXT, String(v), alg, kid, householdHash, id, String(millis), deviceId, deleted ? '1' : '0', entity];
  return enc.encode(JSON.stringify(parts));
}

/** Floor any timestamp to a whole-second ISO-8601 wire string (`...000Z`).
 * Agent envelopes MUST be sealed with this form (see the header rule above):
 * nonzero millis would bind an AD value Android's floor-to-seconds
 * `canonicalE2EMillis` can never reproduce. */
export function canonicalE2EUpdatedAt(updatedAt) {
  return new Date(Math.floor(Date.parse(updatedAt) / 1000) * 1000).toISOString();
}

// Monotonic whole-second sealer: floored values that do not advance past the
// previous seal move forward to the next whole second, so rapid seals of one
// entity never tie (the server keeps the earlier envelope on equal
// timestamps). Module-level: all seals from this import share the clock.
let lastSealedMillis = 0;

/** Whole-second ISO string strictly after every previous seal from this module. */
export function nextAgentUpdatedAt(updatedAt) {
  let ms = Math.floor(Date.parse(updatedAt) / 1000) * 1000;
  if (ms <= lastSealedMillis) ms = lastSealedMillis + 1000;
  lastSealedMillis = ms;
  return new Date(ms).toISOString();
}

/** AES-GCM-256 encrypt a v1 SyncEnvelope payload into an EncryptedEnvelope.
 * Wire format mirrors the apps exactly: ONLY `payload` is sealed; the header
 * stays plaintext and is bound via `e2eHeaderAD` as AES-GCM associated data,
 * so iOS/Android open agent-sealed envelopes (and vice versa).
 * `updatedAt` is canonicalized to a strictly increasing whole-second value
 * before sealing (see the header rule above), so the wire header and the
 * bound AD always carry a `.000Z` value both app implementations reproduce
 * — and rapid seals never tie. */
export async function encryptEnvelope(dataKey, { kid, householdHash, id, entity, updatedAt, deviceId, deleted = false, payload }) {
  const wireUpdatedAt = nextAgentUpdatedAt(updatedAt);
  const key = await crypto.subtle.importKey('raw', dataKey, 'AES-GCM', false, ['encrypt']);
  const ad = e2eHeaderAD({ kid, householdHash, id, updatedAt: wireUpdatedAt, deviceId, deleted, entity });
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const ct = await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce, additionalData: ad }, key, enc.encode(JSON.stringify(payload)));
  return {
    v: 2,
    alg: 'AES-GCM-256',
    kid,
    householdHash,
    id,
    entity,
    updatedAt: wireUpdatedAt,
    deviceId,
    deleted,
    nonce: bytesToB64(nonce),
    ciphertext: bytesToB64(ct),
  };
}

/** Decrypt an EncryptedEnvelope back to the v1 SyncEnvelope wire object
 * ({id, updatedAt, deviceId, deleted, entity, payload}): rebuilds the header
 * AD from the envelope and passes it as associated data, so boxes sealed
 * without it (or under a tampered header) fail authentication.
 * Decryption logic is unchanged by the agent whole-second rule — it binds
 * whatever wire string the envelope carries. Agent envelopes always carry
 * `.000Z` (see `encryptEnvelope`), which is what makes them open on both
 * the iOS millisecond and Android floor-to-seconds AD formulas. */
export async function decryptEnvelope(dataKey, env) {
  const key = await crypto.subtle.importKey('raw', dataKey, 'AES-GCM', false, ['decrypt']);
  const ad = e2eHeaderAD({
    v: env.v,
    alg: env.alg,
    kid: env.kid,
    householdHash: env.householdHash,
    id: env.id,
    updatedAt: env.updatedAt,
    deviceId: env.deviceId,
    deleted: env.deleted,
    entity: env.entity,
  });
  const pt = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: b64ToBytes(env.nonce), additionalData: ad }, key, b64ToBytes(env.ciphertext));
  return {
    id: env.id,
    updatedAt: env.updatedAt,
    deviceId: env.deviceId,
    deleted: env.deleted ?? false,
    entity: env.entity,
    payload: JSON.parse(dec.decode(pt)),
  };
}

export async function enroll(base, { householdHash, householdId, verifier }, token) {
  const res = await fetch(`${base}/agent/enroll`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...(token ? { 'x-agent-token': token } : {}) },
    body: JSON.stringify({ householdHash, householdId, verifier }),
  });
  if (res.status !== 201) throw new Error(`enroll failed: ${res.status} ${await res.text()}`);
  return res.json();
}

/** Minimal REST helper carrying only the key-derived token (no login). */
export function agentFetch(base, token) {
  return async (method, path, body) => {
    const res = await fetch(`${base}${path}`, {
      method,
      headers: { 'x-agent-token': token, 'content-type': 'application/json' },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await res.text();
    let json = null;
    try {
      json = text ? JSON.parse(text) : null;
    } catch {
      json = { _raw: text };
    }
    return { status: res.status, json, text };
  };
}
