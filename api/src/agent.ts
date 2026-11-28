// Key-only agent auth (issue #26).
//
// The device encryption key (syncCode) ALONE authenticates the agent — no
// password, no login, no Apple ID. Two domain-separated HKDF-SHA256
// derivations come from the same syncCode, for different jobs:
//
//   data key   HKDF(syncCode, salt "smidgen-sync-v1",
//                   info "smidgen-sync-v1/hh:<householdId>/kid:<kid>")  [client only]
//   agent token HKDF(syncCode, salt "smidgen-agent-v1",
//                   info "smidgen-agent-v1/hh:<householdId>/kid:<kid>")  [bearer]
//
// The data key NEVER leaves the agent's machine (it decrypts /v2 envelopes
// locally). The agent token is presented as the `x-agent-token` header and
// the server stores only its verifier, hex(SHA256(raw token bytes)) — a D1
// dump yields no usable credential (256-bit preimage).
//
// Enrollment (`POST /agent/enroll {householdHash, householdId, verifier}`)
// is open: knowledge of the unguessable householdHash IS the capability
// (same trust as the /v2 bucket itself). Re-enroll with a new verifier to
// rotate the token without rotating the data key.
//
// What the server ever sees in plaintext: the enrollment triple
// (householdHash, householdId label, verifier) plus whatever the agent sends
// through the legacy PLAINTEXT v1 routes (documented out-of-scope for
// zero-knowledge in docs/e2e-v1.md). /v2 blobs stay opaque: the server
// never holds syncCode, data key, or agent token preimage.

import { z } from 'zod';
import { E2E_HASH_RE } from './e2e';

/** Dedicated header — never `Authorization` (the beta gate ignores any
 * Bearer there by contract, see test/beta-gate.test.ts). */
export const AGENT_TOKEN_HEADER = 'x-agent-token';

/** base64url of exactly 32 raw bytes (43 chars, no padding). */
export const AGENT_TOKEN_RE = /^[A-Za-z0-9_-]{43}$/;

/** hex(SHA-256) verifier. */
export const AGENT_VERIFIER_RE = /^[0-9a-f]{64}$/;

export const agentEnrollSchema = z.object({
  householdHash: z.string().regex(E2E_HASH_RE),
  householdId: z.string().min(1).max(120),
  verifier: z.string().regex(AGENT_VERIFIER_RE),
});

export type AgentEnrollInput = z.infer<typeof agentEnrollSchema>;

export interface AgentEnrollment {
  householdHash: string;
  householdId: string;
  /** hex(SHA256(raw agent-token bytes)). Never the token itself. */
  verifier: string;
  updatedAt: string;
}

export interface AgentIdentity {
  householdId: string;
  householdHash: string;
  deviceId: string;
}

function b64urlToBytes(s: string): Uint8Array | null {
  try {
    let b = s.replace(/-/g, '+').replace(/_/g, '/');
    while (b.length % 4 !== 0) b += '=';
    const bin = atob(b);
    const out = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  } catch {
    return null;
  }
}

/** hex(SHA-256) over bytes. WebCrypto when available, node:crypto fallback. */
export async function sha256HexBytes(data: Uint8Array): Promise<string> {
  const g = globalThis as unknown as { crypto?: { subtle?: SubtleCrypto } };
  if (g.crypto?.subtle) {
    const digest = await g.crypto.subtle.digest(
      'SHA-256',
      data as unknown as ArrayBuffer,
    );
    return Array.from(new Uint8Array(digest))
      .map((b) => b.toString(16).padStart(2, '0'))
      .join('');
  }
  const { createHash } = await import('node:crypto');
  return createHash('sha256').update(data).digest('hex');
}

/**
 * Verifier for a presented `x-agent-token` value, or null when malformed
 * (wrong shape or not 32 bytes). Pure function of the token — needs no key.
 */
export async function agentVerifierFor(token: string): Promise<string | null> {
  if (!AGENT_TOKEN_RE.test(token)) return null;
  const bytes = b64urlToBytes(token);
  if (!bytes || bytes.length !== 32) return null;
  return sha256HexBytes(bytes);
}

/** Short non-secret handle for logs/ids (`hashPrefix8` style). */
export function agentShortHash(householdHash: string): string {
  return householdHash.slice(0, 8);
}
