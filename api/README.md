# Smidgen API — Lane 1

One Hono Worker on Cloudflare: D1 (via Drizzle schema + parameterized SQL) + R2 photos.
Better Auth (email + Apple stub via headers, production wiring documented below).
Households + RBAC (owner/member/viewer). Zod-validated inputs. **PII is never logged**
(access log records method + pathname + status + ms only).

## 3-command deploy

```bash
npx wrangler d1 create smidgen        # 1. create D1 (paste id into wrangler.toml)
npx wrangler r2 bucket create smidgen-photos   # 2. create R2 bucket
npm run deploy                        # 3. apply migrations/seed, then deploy
```

Full first-time sequence (after `d1 create`):

```bash
npx wrangler d1 execute smidgen --remote --file=./drizzle/0001_init.sql
npx wrangler d1 execute smidgen --remote --file=./drizzle/seed.sql   # optional demo seeds
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

| Resource | Free-tier quota | Smidgen usage | Headroom |
|---|---|---|---|
| Workers requests | 100k req/day | ~2k req/day (beta households) | 50x |
| D1 rows read | 5M/day | ~50k/day | 100x |
| D1 storage | 5 GB | ~50 MB (15 seeds ≈ 30 KB; 10k recipes ≈ 20 MB) | 100x |
| R2 storage | 10 GB | ~1 GB (10k photos, 1024px q80 ≈ 100 KB avg) | 10x |
| R2 Class A/B ops | 1M / 10M / month | ~100k uploads + ~1M signed GETs | 10x |

Stay-free rules: signed photo URLs (<15 min TTL) instead of proxied bytes,
`GET /sync/pull?since=` deltas instead of full dumps, ICS feed cached client-side.

## Auth / RBAC

- Production: Better Auth (email + Apple) verifies the session; `src/auth.ts`
  `getUser()` is the single swap point (currently trusts `x-user-id` /
  `x-user-email` / `x-role` headers as a dev stub — **never enable header auth
  in production**; set `BETTER_AUTH_SECRET` via `wrangler secret put`).
- Roles: `viewer` read-only (all mutations → 403), `member` full CRUD,
  `owner` everything + `POST /share/cookbook` + membership management.
- Stored `memberships` rows win over the header fallback role (tested).

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
