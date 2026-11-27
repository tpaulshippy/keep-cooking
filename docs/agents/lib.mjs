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
 */
export function e2eHeaderAD({ v = 2, alg = 'AES-GCM-256', kid, householdHash, id, updatedAt, deviceId, deleted = false, entity }) {
  const millis = Math.floor(Date.parse(updatedAt));
  const parts = [E2E_AD_CONTEXT, String(v), alg, kid, householdHash, id, String(millis), deviceId, deleted ? '1' : '0', entity];
  return enc.encode(JSON.stringify(parts));
}

/** AES-GCM-256 encrypt a v1 SyncEnvelope payload into an EncryptedEnvelope.
 * Wire format mirrors the apps exactly: ONLY `payload` is sealed; the header
 * stays plaintext and is bound via `e2eHeaderAD` as AES-GCM associated data,
 * so iOS/Android open agent-sealed envelopes (and vice versa). */
export async function encryptEnvelope(dataKey, { kid, householdHash, id, entity, updatedAt, deviceId, deleted = false, payload }) {
  const key = await crypto.subtle.importKey('raw', dataKey, 'AES-GCM', false, ['encrypt']);
  const ad = e2eHeaderAD({ kid, householdHash, id, updatedAt, deviceId, deleted, entity });
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const ct = await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce, additionalData: ad }, key, enc.encode(JSON.stringify(payload)));
  return {
    v: 2,
    alg: 'AES-GCM-256',
    kid,
    householdHash,
    id,
    entity,
    updatedAt,
    deviceId,
    deleted,
    nonce: bytesToB64(nonce),
    ciphertext: bytesToB64(ct),
  };
}

/** Decrypt an EncryptedEnvelope back to the v1 SyncEnvelope wire object
 * ({id, updatedAt, deviceId, deleted, entity, payload}): rebuilds the header
 * AD from the envelope and passes it as associated data, so boxes sealed
 * without it (or under a tampered header) fail authentication. */
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

export async function enroll(base, { householdHash, householdId, verifier }) {
  const res = await fetch(`${base}/agent/enroll`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
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
