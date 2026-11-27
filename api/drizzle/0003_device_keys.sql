-- Device keys for Ed25519 enroll (POST /v2/devices, Pass 1 sketch).
-- public_key is standard base64 of the 32-byte Ed25519 public key.
-- No-clobber: device_id is the PK; re-enroll with the same key is
-- idempotent, a different key for the same device_id is a 409 (enforced
-- in the store layer, not via SQL).
CREATE TABLE IF NOT EXISTS device_keys (
  device_id TEXT PRIMARY KEY,
  public_key TEXT NOT NULL,
  display_name TEXT,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  revoked_at TEXT NULL
);
