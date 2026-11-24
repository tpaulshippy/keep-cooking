# Keep Cooking

A permissive open-source Paprika replacement — native iOS, backed by Cloudflare free tier.

No subscriptions. No self-hosted Docker. Own your recipes.

GitHub: github.com/tpaulshippy/keep-cooking · Domain: KeepCooking.app

## Goals

- **Paprika parity:** one-tap clip from web / TikTok / Instagram / YouTube (caption + link), scan cookbook pages / cards, clipboard import
- **Cook mode:** hands-free steps, scaling, cross-off ingredients, tap-to-start timers, keep-screen-on
- **Organize:** categories, cookbooks, advanced + saved search, duplicate finder
- **Shop + pantry:** aisle-sorted grocery lists, multiple lists, pantry locations + expiry, barcode scan
- **Plan:** day / week / month meal plan, reusable menus, add-a-week-to-list, calendar feed
- **Sync + share:** iPhone + iPad native sync, family / household sharing, cookbook sharing, offline-first, export (JSON + Markdown + HTML with Schema.org)
- **Permissive open source:** MIT. No AGPL network-copyleft, no Commons Clause, no personal-use-only rider. Fork it, host it, sell hosting — keep your changes private if you want
- **Native iOS:** SwiftUI iPhone + iPad, Share Sheet importer, widgets, Shortcuts, Apple Watch. No PWA wrapper, no Electron
- **Cloudflare free backend:** Workers + D1 + R2. One Worker, one D1 DB, one R2 bucket — fits in the free tier (100k req/day, 5GB D1, 10GB R2). No Docker, no Postgres to babysit, no VPS. `wrangler d1 create + r2 bucket create + deploy`

## What Keep Cooking is not

- Not AGPL like Mealie / Tandoor / KitchenOwl / RecipeSage
- Not source-available like Tandoor (+ Commons Clause) or dual-licensed like RecipeSage
- Not Apple-only paid like Mela ($6.99) or sub-locked like Paprika 4 Premium ($14.99/yr)
- Not a web app skinned as iOS

## Stack (v0.1-keepcooking, all lanes merged)

- App: SwiftUI (iOS 17+), SwiftData + CloudKit mirror stub, SyncEngine (outbox, LWW + tombstones)
- API: Hono on Cloudflare Workers, OpenAPI at `/openapi.json` (byte-matches contracts)
- DB: D1 (SQLite) via Drizzle, R2 for photos (thumb/1024/original)
- Auth: Better Auth on D1 (email + Apple; header stub in dev)
- Format: JSON + Markdown + self-contained Schema.org HTML export

## Deploy (free tier: 1 Worker + 1 D1 + 1 R2)

```bash
npx wrangler d1 create keep-cooking
npx wrangler r2 bucket create keep-cooking-photos
npm run deploy --prefix api   # migrations + seed + deploy
```

## Architecture

```
[iPhone/iPad SwiftUI] --HTTPS--> [Hono Worker] --Drizzle--> [D1 SQLite]
   SwiftData offline-first  SyncEnvelope LWW       R2 photos (signed <15min)
   Share Sheet / Widgets / Watch / Intents          feed.ics / export json|md|html
```

Contracts: `packages/contracts/` (`openapi.yaml` + `openapi.json`, `schema.sql`,
`SyncEnvelope`, `ClipReport`, `PHOTO_VARIANTS.md`, 15 seeds). CI `contract-check`
runs on PR. No lane may change contracts without orchestrator approval.

## Budget (free tier headroom)

| Resource | Quota | Usage (beta) |
|---|---|---|
| Workers req | 100k/day | ~2k/day |
| D1 storage | 5GB | ~50MB |
| R2 storage | 10GB | ~1GB |

## Status

- Lane 1 API: 41 vitest green, `wrangler deploy --dry-run` pass
- Lane 2 Sync: typechecks clean, 2-device convergence, offline demo (see `apps/ios/SYNC_TEST.md`)
- Lane 3 Ingest: 6-input demo notes, parser tests
- Lane 4 Cook/Plan/Shop: scaling + timer + aggregation tests
- Lane 5 Library/System: 3 seeded dupes caught, EXPORT_SAMPLES validated

Demos (real simulator recordings, iOS 26.5 iPhone 16 Pro): `docs/demos/offline-launch.mp4`
(15 seeds, kill + relaunch persists), `ingest-save.mp4` (OCR scan → parse → save),
`plan-to-list.mp4` (week plan → aggregated aisle-sorted list → check-off → cook mode).
See `docs/demos/NOTES.md` for commands + honest gaps. Full XcodeGen project:
`apps/ios/project.yml` → `Smidgen.xcodeproj` (app + widgets + share + watch + unit/UITests).
