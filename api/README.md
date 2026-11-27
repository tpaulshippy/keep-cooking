# Keep Cooking API — Lane 1

One Hono Worker on Cloudflare: D1 (via Drizzle schema + parameterized SQL) + R2 photos.
Single device-key auth (open auth, header stub in dev; device encryption key is the credential).
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

- Auth: single device encryption key (open auth, no login); `src/auth.ts`
  `getUser()` trusts `x-user-id` /
  `x-user-email` / `x-role` headers as a dev stub — the device key is the
  credential, there is no password or interactive login; set
  `PHOTOS_SIGNING_SECRET` via `wrangler secret put` for photo URL signing.
- Internal TestFlight gate (pass 1): when `PUBLIC_BASE_URL` is a deployed host
  (`*.workers.dev` or any non-local domain), every route except `GET /health`
  requires `Authorization: Bearer <INTERNAL_BETA_TOKEN>` (else `401
  {error:"unauthorized"}`). `x-role` is **ignored in prod** — header fallback
  is forced to `viewer`, so header-role escalation is impossible; stored
  `memberships` rows (keyed off `user.id`) can still grant member/owner.
  Dev (`localhost` / `*.local` / vitest) keeps the header stub with no bearer.
- Roles: `viewer` read-only (all mutations → 403), `member` full CRUD,
  `owner` everything + `POST /share/cookbook` + membership management.
- Stored `memberships` rows win over the header fallback role (tested).

### Beta-gate env (set once, applied on every prod deploy)

```bash
# Generate + store the token as a repo secret (never commit the value):
openssl rand -hex 32 | gh secret set INTERNAL_BETA_TOKEN --repo tpaulshippy/keep-cooking
```

`.github/workflows/deploy.yml` pushes that secret to the Worker
(`wrangler secret put`) and ensures the `hh-demo` / `beta-user` owner
membership exists, so the iOS app's sync (x-user-id `beta-user`) can write.
Manual alternative: `npx wrangler secret put INTERNAL_BETA_TOKEN`.

# Reserved for photo URL signing, unused by auth:
# npx wrangler secret put PHOTOS_SIGNING_SECRET

# D1: wrangler.toml still has `database_id = "local-keepcooking-placeholder"` —
# replace it with the real id from `npx wrangler d1 create keep-cooking` before deploy.
```

### Curl

```bash
BASE=https://keep-cooking-api.pshippy-245.workers.dev
TOKEN=$(cat ~/.keepcooking-beta-token)   # value stored via `wrangler secret put INTERNAL_BETA_TOKEN`

curl -s $BASE/health                                        # 200, no auth
curl -s $BASE/recipes                                      # 401 {error:"unauthorized"}
curl -s -H "Authorization: Bearer $TOKEN" $BASE/recipes    # 200
curl -s -X POST $BASE/recipes \
  -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' \
  -H 'x-role: owner' -d '{"title":"probe","servings":2}'   # 403 — x-role ignored in prod
```

## Endpoints (exactly packages/contracts/openapi.yaml, plus 2 photo helpers)

`GET /health`, `GET /openapi.json` (deep-equals contracts file),
`POST /clip`, CRUD `/recipes` + `POST /recipes/:id/scale`,
CRUD `/lists`, CRUD `/pantry`, CRUD `/plans` + `/menus`,
`GET /plans/feed.ics`, `POST /share/cookbook`, `GET /export/:id.(json|md|html)`,
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
