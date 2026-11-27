// Types for the dependency-free docs client (docs/agents/lib.mjs), used by
// agent.test.ts to pin cross-implementation KDF + envelope parity without literals.
declare module '*docs/agents/lib.mjs' {
  export function deriveAll(
    syncCode: string,
    householdId: string,
  ): Promise<{
    kid: string;
    householdHash: string;
    hashPrefix8: string;
    token: string;
    verifier: string;
    dataKey: Uint8Array;
  }>;
  export interface DocsEnvelopeHeader {
    v?: number;
    alg?: string;
    kid: string;
    householdHash: string;
    id: string;
    entity: string;
    updatedAt: string;
    deviceId: string;
    deleted?: boolean;
    payload?: unknown;
  }
  export interface DocsEncryptedEnvelope {
    v: 2;
    alg: 'AES-GCM-256';
    kid: string;
    householdHash: string;
    id: string;
    entity: string;
    updatedAt: string;
    deviceId: string;
    deleted: boolean;
    nonce: string;
    ciphertext: string;
  }
  export function e2eHeaderAD(h: DocsEnvelopeHeader): Uint8Array;
  export function canonicalE2EUpdatedAt(updatedAt: string): string;
  export function encryptEnvelope(dataKey: Uint8Array, params: DocsEnvelopeHeader & { payload: unknown }): Promise<DocsEncryptedEnvelope>;
  export function decryptEnvelope(
    dataKey: Uint8Array,
    env: DocsEncryptedEnvelope,
  ): Promise<{ id: string; updatedAt: string; deviceId: string; deleted: boolean; entity: string; payload: { title: string } }>;
}
