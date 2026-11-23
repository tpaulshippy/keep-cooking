# Smidgen

A permissive open-source Paprika replacement — native iOS, backed by Cloudflare free tier.

No subscriptions. No self-hosted Docker. Own your recipes.

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

## What Smidgen is not

- Not AGPL like Mealie / Tandoor / KitchenOwl / RecipeSage
- Not source-available like Tandoor (+ Commons Clause) or dual-licensed like RecipeSage
- Not Apple-only paid like Mela ($6.99) or sub-locked like Paprika 4 Premium ($14.99/yr)
- Not a web app skinned as iOS

## Stack (planned)

- App: SwiftUI (iOS 17+), SwiftData + CloudKit mirror for offline
- API: Hono on Cloudflare Workers, OpenAPI at `/openapi.json`
- DB: D1 (SQLite) via Drizzle, R2 for photos
- Auth: Better Auth on D1 (email + Sign in with Apple)
- Format: plain JSON + Markdown export, Paprika / Mela importers
