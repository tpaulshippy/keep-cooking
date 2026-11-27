// Types for the dependency-free docs client (docs/agents/lib.mjs), used by
// agent.test.ts to pin cross-implementation KDF parity without literals.
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
}
