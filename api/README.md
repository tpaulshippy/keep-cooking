# Keep Cooking API — Lane 1

One Hono Worker on Cloudflare: D1 (via Drizzle schema + parameterized SQL) + R2 photos.
Single device-key auth (open auth, header stub in dev; device signing key is the credential).
Households + RBAC (owner/member/viewer). Zod-validated inputs. **PII is never logged**
(access log records method + pathname + status + ms only).

## 3-command deploy

```bash
npx wrangler d1 create keep-cooking        # 1. create D1 (paste id into wrangler.toml)
npx wrangler r2 bucket create keep-cooking-photos   # 2. create R2 bucket
npm run deploy                        # 3. apply migrations/seed, then deploy
```

Full first-time sequence (after `d1 create`):

```bash
npx wrangler d1 execute keep-cooking --remote --file=./drizzle/0001_init.sql
npx wrangler d1 execute keep-cooking --remote --file=./drizzle/seed.sql   # optional demo seeds
npm run deploy
```

Local dev:

```bash
npm install
npm run db:apply:local     # migrations to local D1 (needs wrangler)
npm run db:seed:local      # optional: 15 contract seeds
npm run dev                # wrangler dev (no D1 binding -> in-memory store)
npm test                   # vitest
```

`wrangler dev` boots with or without D1/R2 bindings: if `DB` is missing it uses
an in-memory store (dev only). `GET /health` proves boot.

## Budget (1 Worker + 1 D1 + 1 R2, Cloudflare free tier)

| Resource | Free-tier quota | Keep Cooking usage | Headroom |
|---|---|---|---|
| Workers requests | 100k req/day | ~2k req/day (beta households) | 50x |
| D1 rows read | 5M/day | ~50k/day | 100x |
| D1 storage | 5 GB | ~50 MB (15 seeds ≈ 30 KB; 10k recipes ≈ 20 MB) | 100x |
| R2 storage | 10 GB | ~1 GB (10k photos, 1024px q80 ≈ 100 KB avg) | 10x |
| R2 Class A/B ops | 1M / 10M / month | ~100k uploads + ~1M signed GETs | 10x |

Stay-free rules: signed photo URLs (<15 min TTL) instead of proxied bytes,
`GET /sync/pull?since=` deltas instead of full dumps, ICS feed cached client-side.

## Auth / RBAC

- Auth: per-device Ed25519 signing keys — the device signing key is the
  credential, there is no password or login (`api/src/auth.ts`). Enroll the
  device once, then sign every write. The household E2E key (see
  `docs/e2e-v1.md`) is a different secret: it encrypts recipe content and
  never leaves the device — it is never sent to, or verified by, the server.
- Enroll (open — the only unsigned write):
  `POST /v2/devices { deviceId: UUIDv4, publicKey: base64(32B Ed25519),
  displayName? }` → `201 { deviceId, enrolledAt }` on first enroll,
  `200` on idempotent re-enroll with the same key, `410` when the id was
  revoked (gone — enroll a fresh `deviceId` instead), `409` when the id is
  already enrolled with a different key.
- Signed writes carry `x-device-id` / `x-device-ts` (millis since epoch) /
  `x-device-sig` (base64 Ed25519 over the canonical string
  `METHOD + "\n" + path+query + "\n" + ts + "\n" + hex(SHA256(bodyBytes))`;
  the empty body hashes as `hex(SHA256(""))`). Reads (`GET`/`HEAD`/`OPTIONS`)
  plus `GET /health`, `GET /openapi.json`, and `POST /v2/devices`
  (enrollment) stay open; every other `POST`/`PUT`/`DELETE` requires a valid
  signature (`401` otherwise). Replay window `|now - ts| <= 5 min` is a
  documented limitation, not a nonce ledger: two identical writes inside the
  window both verify (handlers are idempotent, so this is safe). This has
  nothing to do with the E2E envelope `nonce` (`api/src/e2e.ts`), which is a
  per-envelope AES-GCM IV for content encryption, not auth replay protection.
- Roles: `viewer` read-only (all mutations → 403), `member` full CRUD,
  `owner` everything + `POST /share/cookbook` + membership management.
  In prod `x-role` is **ignored** — the header fallback is forced to
  `viewer`, so header-role escalation is impossible; stored `memberships`
  rows (keyed off the verified device id) can still grant member/owner.
  First-claim bootstrap: on an empty household the first verified writer
  becomes `owner`; further devices stay `viewer` (role-checked writes → 403)
  until an owner grants them a role. No membership seed is applied at deploy.
  Dev (`localhost` / `*.local` / vitest) keeps the header stub with no
  signature checks.
- Stored `memberships` rows win over the header fallback role (tested).
- Revocation: `POST /v2/devices/{id}/revoke` (signed; self-only).
  A revoked device gets `401 device revoked` on its next write —
  self-revoke is logout. There is no shared token to rotate; enroll a fresh
  key instead.
- `PHOTOS_SIGNING_SECRET` is HMAC-only: it signs photo URLs
  (`wrangler secret put PHOTOS_SIGNING_SECRET`), it is not auth and never
  substitutes for a device signature.

### Curl

```bash
BASE=https://keepcooking.app/api
DEVICE_ID=$(uuidgen)   # persist one per device; the private half never leaves it

# 1. enroll (open — the only unsigned write):
curl -s -X POST $BASE/v2/devices \
  -H 'content-type: application/json' \
  -d "{\"deviceId\":\"$DEVICE_ID\",\"publicKey\":\"<base64-of-32B-Ed25519-pubkey>\"}"
# → 201 {"deviceId":"...","enrolledAt":"..."} (200 = same key re-enrolled, 410 = revoked id, 409 = id taken)

# 2. reads are open — no headers:
curl -s $BASE/health     # 200, proves boot
curl -s $BASE/recipes    # 200, no signature

# 3. writes are signed (TS = millis, SIG = Ed25519 over the canonical string;
#    construction below is schematic — see deviceCanonicalString in api/src/auth.ts).
#    Canonical path is the FULL path as sent, including the /api prefix:
BODY='{"title":"probe","servings":2}'
TS=$(date +%s000)
CANONICAL=$(printf 'POST\n/api/recipes\n%s\n%s' "$TS" "$(printf '%s' "$BODY" | sha256sum | cut -d' ' -f1)")
SIG=$(sign_ed25519 "$CANONICAL" device-private-key)   # Ed25519, base64 output
curl -s -X POST $BASE/recipes \
  -H 'content-type: application/json' \
  -H "x-device-id: $DEVICE_ID" -H "x-device-ts: $TS" -H "x-device-sig: $SIG" \
  -d "$BODY"   # 201 as first-claim owner on an empty household, else 201 as
               # granted owner/member, 403 as viewer (needs a grant)
```

## Cutover / rollback (issue #28: keepcooking.app/api origin)

- The Worker dual-serves every route at both `/…` and `/api/…`
  (see `api/src/index.ts` — native Hono `.route()` mount, smallest diff).
  Backward-compat window: old `*.workers.dev` clients keep working on the
  root paths; new clients use `https://keepcooking.app/api`.
- Auth is header-signature (`x-device-id` / `x-device-ts` / `x-device-sig`
  over the full path+query), not cookies — so no CORS/cookie code change
  was needed beyond the base URL. CORS allows the custom domain; device-key
  enrollment, signed writes, and signed photo URLs work through it unchanged.
- Pre-deploy check from `api/`: `npx wrangler deploy --dry-run`.
- Rollback is a single deploy: `git revert` the `PUBLIC_BASE_URL` bump (or
  re-deploy the previous commit) — one Worker, one deploy, no migration.
  The old origin never stops serving during the window, so clients pinned
  to either base URL stay green.

## Endpoints (exactly packages/contracts/openapi.yaml, plus 2 photo helpers)

`GET /health`, `GET /openapi.json` (deep-equals contracts file),
`POST /clip`, CRUD `/recipes` + `POST /recipes/:id/scale`,
CRUD `/lists`, CRUD `/pantry`, CRUD `/plans` + `/menus`,
`GET /plans/feed.ics`, `POST /share/cookbook`, `GET /export/:id.(json|md|html)`,
`POST /v2/devices` (enroll) + `POST /v2/devices/{id}/revoke` (self-revoke = logout),
`GET /sync/pull?since=`, `POST /sync/push`,
plus `GET /photos/variants?recipeId=` and `GET /photos/sign?key=` (<15 min TTL).

## Sync

Envelopes `{id, updatedAt, deviceId, deleted, entity, payload}`.
Last-write-wins on `updatedAt`; `deleted=true` is a tombstone (DELETE routes
tombstone, never hard-delete). `POST /sync/push` returns server-won conflicts.

## Clip

`POST /clip {url?, caption?}` tries JSON-LD → reader → caption, logs only
`{strategy, host, confidence}`. See CLIP_TEST_REPORT.md (10/12 auto-pass).

## Photos

Variants `photos/{recipeId}/{original,1024,thumb}.jpg` (see contracts
PHOTO_VARIANTS.md), SHA-256 dedup by key reuse, signed GET URLs with
10-min default TTL (hard cap <15 min), HMAC-SHA256 verified by the Worker.
