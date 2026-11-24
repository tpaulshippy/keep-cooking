-- Smidgen E2E V1 blind blob pipe (see api/src/e2e.ts).
-- Server-blind: header JSON holds the plaintext routing header only
-- (v/alg/kid/householdHash/id/entity/updatedAt/deviceId/deleted/nonce);
-- ciphertext stays opaque. LWW on updated_at; per-id delete via
-- deleted=true tombstone envelope; whole-bucket wipe = DELETE rows by hash.
-- Photos stay inline in ciphertext for pass 1 (no photo blob table).

CREATE TABLE IF NOT EXISTS sync_blobs_v2 (
  household_hash TEXT NOT NULL,
  id TEXT NOT NULL,
  header TEXT NOT NULL,
  ciphertext TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  PRIMARY KEY (household_hash, id)
);
CREATE INDEX IF NOT EXISTS idx_sync_blobs_v2_hash_updated ON sync_blobs_v2(household_hash, updated_at);
