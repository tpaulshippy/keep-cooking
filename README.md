# Keep Cooking

A permissive open-source Paprika replacement — native iOS + Android + web, backed by Cloudflare free tier.

No subscriptions. No self-hosted Docker. Own your recipes.

GitHub: github.com/tpaulshippy/keep-cooking · Domain: KeepCooking.app

## Goals

- **Paprika parity:** one-tap clip from web / TikTok / Instagram / YouTube (caption + link), scan cookbook pages / cards, clipboard import; full Paprika import/export
- **Cook mode:** hands-free steps, scaling, cross-off ingredients, tap-to-start timers, keep-screen-on
- **Organize:** categories, cookbooks, advanced + saved search, duplicate finder, favorites
- **Shop + pantry:** aisle-sorted grocery lists, multiple lists, pantry locations + expiry, barcode scan
- **Plan:** day / week / month meal plan, reusable menus, add-a-week-to-list, calendar feed
- **Sync + share:** iPhone + iPad + Android + web sync, family / household sharing, cookbook sharing, offline-first, export (JSON + Markdown + HTML with Schema.org + Paprika + YAML)
- **Permissive open source:** MIT. No AGPL network-copyleft, no Commons Clause, no personal-use-only rider. Fork it, host it, sell hosting — keep your changes private if you want
- **Native clients:** SwiftUI iPhone + iPad, Kotlin/Compose Android, TS/Vite web SPA. No PWA wrapper, no Electron
- **Cloudflare free backend:** Workers + D1 + R2. One Worker, one D1 DB, one R2 bucket — fits in the free tier (100k req/day, 5GB D1, 10GB R2). No Docker, no Postgres to babysit, no VPS. `wrangler d1 create + r2 bucket create + deploy`

## What Keep Cooking is not

- Not AGPL like Mealie / Tandoor / KitchenOwl / RecipeSage
- Not source-available like Tandoor (+ Commons Clause) or dual-licensed like RecipeSage
- Not Apple-only paid like Mela ($6.99) or sub-locked like Paprika 4 Premium ($14.99/yr)
- Not a web app skinned as iOS

## Stack

- **iOS** (`apps/ios/`): SwiftUI (iOS 17+), Share Sheet importer, widgets, Shortcuts, Apple Watch. XcodeGen: `project.yml` → `Smidgen.xcodeproj`. Recipe view + separate editor, nutrition panel, unified ingest (URL + photo + paste-text), export multi-select, E2E invite codes + Sync now
- **Android** (`apps/android/`): native Kotlin + Compose (`Recipes`, `RecipeEditor`, `Cook`, `Ingest`, `Import`, `Export`, `Plan`, `Shop`, `Library`, `Settings`, `Share` screens). Room offline-first, signed R2 photo URLs, JVM unit tests (sync merge, search, cook logic, edit payload)
- **Web** (`apps/web/`): vanilla TS + Vite SPA (`src/main.ts`, history router at `/app`), served by its own Cloudflare Worker. Offline store, E2E sync parity with mobile (invite codes + Sync now), seed from shared contracts, dark mode follows OS, R2 signed photos with fallback tile
- **API** (`api/`): Hono on Cloudflare Workers, OpenAPI at `/api/openapi.json` (byte-matches contracts). Routes: `/recipes` CRUD + scale, `/lists`, `/pantry`, `/plans` (+ `feed.ics`), `/menus`, `/share/cookbook`, `/export` (json/md/html/paprikarecipes/yaml, bulk + per-file), `/import` (JSON + multipart, Paprika parity, dryRun), `/clip`, `/photos/*` (sign/dl/variants), `/sync/pull|push`, `/v2/sync/:hash` (E2E blind blobs), `/v2/devices`, `/agent/*`, `/mcp`
- **DB:** D1 (SQLite) via Drizzle (`api/drizzle/`: init + E2E blobs + device keys + agent enrollments + `is_favorite` + editor metadata + seed), R2 for photos (`photos/:id/original|1024|thumb.jpg`, HMAC signed URLs <15min)
- **Auth:** Ed25519 device signatures (`x-device-id/ts/sig`, 5-min skew; enforced in prod, stub in dev) + owner/member/viewer RBAC with first-claim bootstrap + key-only agent tokens (`x-agent-token`). Household E2E key never leaves the device
- **Format:** JSON + Markdown + self-contained Schema.org HTML + Paprika + YAML export

## Deploy (free tier: 1 Worker + 1 D1 + 1 R2)

```bash
npx wrangler d1 create keep-cooking
npx wrangler r2 bucket create keep-cooking-photos
npm run deploy --prefix api          # API Worker
# apply migrations as needed:
npm run db:apply:remote --prefix api # 0001_init … 0006_editor_metadata
```

`PUBLIC_BASE_URL=https://keepcooking.app/api` — the API mounts routes only at `/api`
(single-serve; old root-path clients 404). Pushes to `main` touching
`api/contracts/web` auto-deploy API + web via `deploy.yml`.

## Architecture

```
[SwiftUI iOS] --\
[Kotlin Android] ---> [Hono Worker @ /api] --Drizzle--> [D1 SQLite]
[TS/Vite web] --/         device-sig/RBAC/agent auth      R2 photos (signed <15min)
  offline-first stores   E2E blind blobs /v2/sync/:hash   feed.ics / export json|md|html|paprika|yaml
  Share Sheet / Widgets / Watch / Intents                 clip / import / MCP / agent
```

Contracts: `packages/contracts/` (`openapi.yaml` + `openapi.json` byte-synced,
`schema.sql`, `SyncEnvelope`, `ClipReport`, `PHOTO_VARIANTS.md`, `mcp-tools.json`,
15 seeds). `contract-check` runs on PR. No lane may change contracts without
orchestrator approval.

CI (`.github/workflows/`): `contract-check` (specs + examples + seeds),
`unit-tests` (API + web vitest), `android-check` (assemble + JVM tests),
`deploy` (API + web on main), `ios-testflight` (Xcode Cloud on iOS changes).

## Budget (free tier headroom)

| Resource | Quota | Usage (beta) |
|---|---|---|
| Workers req | 100k/day | ~2k/day |
| D1 storage | 5GB | ~50MB |
| R2 storage | 10GB | ~1GB |

## Status

- API: vitest green (`clip`, `recipes`, `d1-persist`, `update-durability`, `agent` suites), `wrangler deploy --dry-run` pass; device auth + RBAC + E2E blobs + Paprika/YAML import-export live
- Sync: E2E blind sync at parity across iOS/Android/web (invite codes + Sync now); 2-device convergence, offline demo (see `apps/ios/SYNC_TEST.md`)
- Ingest: unified URL + photo + paste-text on all three clients, parser tests
- Library: separate recipe editor from view, nutrition panel, `isFavorite` end-to-end, duplicate finder (3 seeded dupes caught), export multi-select + select-all
- Cook/Plan/Shop: scaling + timer + week-plan → aisle-sorted list aggregation tests

Demos (real simulator recordings, iOS 26.5 iPhone 16 Pro): `docs/demos/offline-launch.mp4`
(15 seeds, kill + relaunch persists), `ingest-save.mp4` (OCR scan → parse → save),
`plan-to-list.mp4` (week plan → aggregated aisle-sorted list → check-off → cook mode).
See `docs/demos/NOTES.md` for commands + honest gaps. Full XcodeGen project:
`apps/ios/project.yml` → `Smidgen.xcodeproj` (app + widgets + share + watch + unit/UITests).
