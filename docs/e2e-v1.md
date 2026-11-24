# Smidgen E2E v1 — zero-knowledge recipe sync

> **Zero-knowledge statement (scope: /v2 E2E envelopes only).** Recipe
> content inside `PUT/GET /v2/sync/:hash` envelopes is encrypted on-device
> before it ever reaches the backend. The Worker, D1 `sync_blobs_v2`, logs,
> and backups hold only opaque blobs plus routing metadata (household hash,
> key id, timestamps) for that route. Smidgen cannot see or recover those
> recipes. Lose code+devices = permanent loss.
>
> Out of scope: the legacy plaintext pipes `GET /sync/pull` and
> `POST /sync/push` are NOT zero-knowledge, and R2 photo routes (signed
> URLs, variant fetches) carry operator-visible bytes. Do not route private
> content through them and expect E2E protection.

## Envelope v2 shape

v1 `SyncEnvelope` (`packages/contracts`) stays untouched. v2 wraps it —
1:1 with `encryptedEnvelopeSchema` in `api/src/e2e.ts`:

```json
{
  "v": 2,
  "alg": "AES-GCM-256",
  "kid": "opaque key id (per-household, feeds the HKDF info string)",
  "householdHash": "hex(SHA256(\"smidgen-hh-v1\" || syncCode || householdId))",
  "id": "uuid of the wrapped v1 envelope",
  "entity": "recipe | list | pantryItem | plan | menu",
  "updatedAt": "ISO-8601 datetime (header LWW cursor)",
  "deviceId": "writer device id",
  "deleted": false,
  "nonce": "base64, 12 random bytes, fresh per envelope (AES-GCM)",
  "ciphertext": "base64, AES-GCM-256(raw-ciphertext ‖ 16-byte tag) over the canonical JSON of the v1 envelope payload"
}
```

Routing columns stored server-side (`household_hash`, `id`, `header`,
`ciphertext`, `updated_at` — D1 `sync_blobs_v2`, PK
`(household_hash, id)`). None of these is recipe content. Standalone
`ingredient` / `step` envelopes are rejected (HTTP 422): clients fold
children into the parent recipe envelope pre-encrypt. Per-id delete
travels as a `deleted: true` tombstone via PUT; whole-bucket wipe is
`DELETE /v2/sync/:hash`. Photos stay inline in the ciphertext for pass 1 —
no dedicated photo route.

## Key derivation (locked)

- `householdHash = hex(SHA256("smidgen-hh-v1" || syncCode || householdId))`
  (UTF-8 concat). Names the server bucket (`PUT/GET/DELETE
  /v2/sync/:hash`) without revealing the code.
- Data key: `HKDF-SHA256(IKM: syncCode UTF-8, salt: "smidgen-sync-v1",
  info: "smidgen-sync-v1/hh:<householdId>/kid:<kid>", L: 32)`.
- Cipher: AES-GCM-256, 12-byte random nonce per envelope, never reused
  (`ciphertext` = raw-ciphertext ‖ 16-byte tag, base-64 encoded).
- Key id: `kid = base64url(SHA256(syncCode UTF-8))[:12]` (opaque routing
  header + HKDF info input).
- Fingerprint: `hashPrefix8 = householdHash[:8]` (eyeball-match in
  Settings; the only hash fraction that may appear in logs).
- Key storage: the `syncCode` lives ONLY in the Keychain under account
  `smidgen.e2ee.<hashPrefix8>`. UserDefaults holds non-secret metadata
  only (`kid` / `householdHash` / `householdId` / endpoint hint) — never
  the code.

One key per household. All devices in a household share the same `syncCode`.

## Routes (unchanged wire, opaque payloads)

| Route | Change |
|---|---|
| `GET /health` | None — plaintext liveness probe. Used by Settings → Test. |
| `GET /sync/pull?since=` | v1 plaintext pipe, unchanged (legacy). |
| `POST /sync/push` | v1 plaintext pipe, unchanged (legacy). |
| `GET /v2/sync/:hash` | Encrypted envelopes (`v:2`, `alg:AES-GCM-256`) for one household bucket; `?since=` filters on header `updatedAt`. |
| `PUT /v2/sync/:hash` | Upsert batch; LWW per `id` on header `updatedAt`; standalone `ingredient`/`step` → 422; `householdHash` mismatch → 400. |
| `DELETE /v2/sync/:hash` | Whole-bucket wipe (per-id delete travels as `deleted:true` tombstones via PUT). | |

The server validates shape (`EncryptedEnvelope` schema in `openapi.yaml` /
`openapi.json`) and LWW metadata only. It has no key material and cannot
produce or verify plaintext.

## Invite flow (second device)

1. Device A (already joined): Settings → End-to-end encryption → Show invite
   bundle. The bundle is JSON:
   `{"v":"2","householdId","syncCode","kid","hash","endpointHint"}`.
2. A shows it as QR; manual copy is the fallback for large bundles.
3. Device B: paste into "Paste invite bundle to join". B rejects unless
   ALL of these hold: `v == "2"`, `kid == kid(syncCode:)` (recomputed via
   the Sync layer hash), and `householdHash = hex(SHA256("smidgen-hh-v1" ||
   syncCode || householdId))` matches `hash` — before storing anything.
4. B stores the `syncCode` in the Keychain (account
   `smidgen.e2ee.<hashPrefix8>`) + non-secret metadata (`kid`,
   `householdHash`, `householdId`) in UserDefaults, then syncs. The
   bundle's `endpointHint` is NEVER auto-applied: B stages it under
   "Suggested server (from invite)" and adopts it only after the user
   taps "Test & use this server" AND `GET <hint>/health` returns 200.
   Both devices show the same `kid` / `hashPrefix8` — compare them
   out-of-band to confirm no tampering.
5. **Second-device nudge:** got a new phone or iPad? Add it now while you
   still have this one — open Settings here on both devices. Without at
   least one joined device (or the saved recovery kit), the new device
   cannot decrypt history.

## Loss & rotation

- **Loss:** the recovery kit IS the `syncCode` (plus `householdId` and the
  backend URL). Anyone with the code reads everything; anyone without it —
  including Smidgen — reads nothing. There is no reset path: losing the
  code AND all joined devices means the ciphertext can never be decrypted
  again. Print it, store it with your passwords, treat it like a house key.
- **Rotation:** Settings (future) → rotate generates a fresh `syncCode`
  (new `kid`). Old devices stop decrypting new writes until they re-join
  with the new bundle. Old ciphertext is NOT re-encrypted — it stays
  readable only with the old code. Keep the old code archived until every
  device has synced past rotation.
- **Leaving:** deleting the app (or resetting the code store) removes the
  key from that device. Server-side blobs are tombstoned by normal sync
  deletes; already-exfiltrated blobs remain decryptable by whoever held
  the code — rotation bounds that exposure going forward.

## BYO steps (fresh backend)

1. `wrangler login` (once per machine).
2. Mint a beta token and deploy from the repo root:
   `INTERNAL_BETA_TOKEN=$(openssl rand -base64 32) ./scripts/deploy-backend.sh`
   - Creates D1 `smidgen` (writes the new `database_id` into
     `api/wrangler.toml` on first run), R2 `smidgen-photos`, applies the D1
     schema remotely (`api/drizzle/0001_init.sql` + `0002_e2e_blobs.sql`),
     sets `INTERNAL_BETA_TOKEN` as a Worker secret, writes
     `PUBLIC_BASE_URL` into `api/wrangler.toml [vars]` when provided, deploys
     the Worker, then curls `/health` on the actual published URL.
   - The token is REQUIRED: without it the script aborts (pass
     `BYO_NO_TOKEN=1` only for an explicit local/no-token setup, where
     writes are ungated and the backend must never be exposed).
3. The script prints the Worker URL, e.g.
   `https://smidgen-api.<account>.workers.dev`.
4. In the app: Settings → Server (BYO backend) → paste URL → **Test**
   (expects `GET /health` → 200). Do NOT tap Save & sync now yet:
   syncing before the household key exists would push recipes through
   the legacy plaintext `POST /sync/push` pipe. Blank resets to the Bundle
   `SMIDGEN_API_BASE_URL` → prod fallback chain.
5. FIRST join or create the household key in Settings → End-to-end
   encryption (paste the invite bundle on a second device, or create a new
   household), and eyeball-match `kid` / `hashPrefix8` across devices.
6. ONLY THEN, back in Settings → Server (BYO backend), enter the same
   `INTERNAL_BETA_TOKEN` in the Beta token field → Save & sync now. From
   this point recipe sync travels as E2E v2 envelopes; the legacy plaintext
   pipes stay unused for recipe content.

## Blindness acceptance (prove the server learns nothing)

Run against a scratch backend with a test household:

1. Create household + push ≥ 1 encrypted recipe envelope.
2. Dump everything the operator can see:
   - `wrangler d1 execute smidgen --command "SELECT * FROM …"` (all tables),
   - `wrangler r2 object list smidgen-photos` + `get` every key,
   - Worker logs (`wrangler tail` capture for the session).
3. Assert over the concatenated dump: **zero bytes** of known recipe
   plaintext — grep for each recipe title, ingredient name, step sentence,
   note, and photo byte-prefix. Expect no matches.
4. Assert structurally: stored sync rows contain only `v/kid/nonce/
   ciphertext/hash` + routing metadata; no `title/text/name` columns carry
   plaintext.
5. Record the dump hashes + grep exit codes (`1` = no match) as the
   acceptance artifact. Any match fails the release.
