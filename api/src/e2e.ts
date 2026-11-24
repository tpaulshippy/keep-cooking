import { z } from 'zod';

// E2E V1 thin blind blob pipe.
// The server NEVER decrypts: envelopes carry an opaque `ciphertext` plus a
// plaintext routing header (v/alg/kid/householdHash/id/entity/updatedAt/...).
// Photos stay inline in the ciphertext for pass 1 — no dedicated photo route.
// Standalone ingredient/step envelopes are rejected (fold into the parent
// recipe envelope pre-encrypt); per-id delete travels as deleted=true tombstone.

/** Domain separator prefix for household-hash derivation (utf8 concat). */
export const HOUSEHOLD_HASH_PREFIX = 'smidgen-hh-v1';

/** Path-param guard: lowercase 64-hex SHA-256 digest. */
export const E2E_HASH_RE = /^[0-9a-f]{64}$/;

/** Number of hash hex chars safe to surface in logs (prefix only). */
export const HASH_LOG_PREFIX_LEN = 8;

export function hashLogPrefix(hash: string): string {
  return hash.slice(0, HASH_LOG_PREFIX_LEN);
}

/**
 * householdHash = hex(SHA256("smidgen-hh-v1" || syncCode || householdId)).
 * Uses WebCrypto when available (workers + modern node); falls back to
 * node:crypto via dynamic import so the workers bundle stays clean.
 */
export async function householdHash(syncCode: string, householdId: string): Promise<string> {
  const input = `${HOUSEHOLD_HASH_PREFIX}${syncCode}${householdId}`;
  const g = globalThis as unknown as { crypto?: { subtle?: SubtleCrypto } };
  if (g.crypto?.subtle) {
    const digest = await g.crypto.subtle.digest('SHA-256', new TextEncoder().encode(input));
    return Array.from(new Uint8Array(digest))
      .map((b) => b.toString(16).padStart(2, '0'))
      .join('');
  }
  const { createHash } = await import('node:crypto');
  return createHash('sha256').update(input, 'utf8').digest('hex');
}

/** E2E entities: whole-object only. ingredient/step must fold into recipe. */
export const e2eEntitySchema = z.enum(['recipe', 'list', 'pantryItem', 'plan', 'menu']);

export const encryptedEnvelopeSchema = z.object({
  v: z.literal(2),
  alg: z.literal('AES-GCM-256'),
  kid: z.string().min(1).max(120),
  householdHash: z.string().regex(/^[0-9a-f]{64}$/),
  id: z.string().uuid(),
  entity: e2eEntitySchema,
  updatedAt: z.string().datetime(),
  deviceId: z.string().min(1).max(200),
  deleted: z.boolean().default(false),
  nonce: z.string().min(1).max(512),
  ciphertext: z.string().min(1),
});

export type EncryptedEnvelope = z.infer<typeof encryptedEnvelopeSchema>;

/** Split an envelope into D1 columns: header JSON (routing only) + ciphertext. */
export function envelopeHeader(env: EncryptedEnvelope): Record<string, unknown> {
  const { ciphertext: _ct, ...header } = env;
  void _ct;
  return header;
}
