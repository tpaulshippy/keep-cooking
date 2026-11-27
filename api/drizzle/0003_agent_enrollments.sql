-- Keep Cooking key-only agent auth (#26): enrollment binding.
-- Canonical migration chain: apply drizzle/0001_init.sql, then
-- 0002_e2e_blobs.sql, then this file. All statements are IF NOT EXISTS, so
-- re-applying is safe.
-- Server-blind: rows hold the householdHash (unguessable bucket address), a
-- plaintext householdId LABEL, and a token VERIFIER = hex(SHA256(raw agent
-- token)). The verifier is a one-way hash — a DB dump yields no usable
-- credential. The syncCode, data key, and raw agent token NEVER reach the
-- server. Re-enrolling a hash replaces its verifier (token rotation without
-- data-key rotation).

CREATE TABLE IF NOT EXISTS agent_enrollments (
  household_hash TEXT PRIMARY KEY,
  household_id TEXT NOT NULL REFERENCES households(id),
  verifier TEXT NOT NULL,
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_enrollments_verifier ON agent_enrollments(verifier);
