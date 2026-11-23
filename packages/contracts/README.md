# Contracts v0.1.0 — source of truth. No lane changes without orchestrator approval.

Ownership: orchestrator only. Lanes consume, never edit.

Contents:
- `openapi.yaml` (+ generated `openapi.json` — run `python3 -c "import yaml,json; json.dump(yaml.safe_load(open('openapi.yaml')),open('openapi.json','w'),indent=2)"`)
- `schema.sql` — D1 SQLite. SwiftData models must be 1:1 (Recipe, Ingredient, Step, List, PantryItem, Plan, Menu).
- `examples/Recipe.json`, `ClipReport.json`, `SyncEnvelope.json`
- `PHOTO_VARIANTS.md` — variant rules
- `seed/` — 12 recipes + 3 near-duplicates for dup-finder tests
- `CHANGELOG.md` — versioned

## SyncEnvelope
`{ id: uuid, updatedAt: ISO8601, deviceId: string, deleted?: bool, entity, payload }`.
Last-write-wins on `updatedAt`; `deleted=true` = tombstone, never hard-delete on sync. Outbox queue on device, `GET /sync/pull?since=` + `POST /sync/push`.

## ClipReport
`{ strategy: jsonld|reader|caption|ocr, confidence 0-1, warnings[], sourceUrl, recipe: RecipeInput }`.
Server tries JSON-LD → reader → caption fallback, logs which. All parsing unit-tested client-side too.

## Auth / RBAC
Better Auth (email + Apple). `householdId` on every entity. Roles: owner/member/viewer. Viewer read-only, member CRUD, owner + invites/deletes.

## Endpoints (see openapi.yaml)
POST /clip, CRUD /recipes, POST /recipes/:id/scale, CRUD /lists + /pantry, CRUD /plans + /menus, GET /plans/feed.ics, POST /share/cookbook, GET /export/:id.(json|md|html), GET /sync/pull, POST /sync/push, GET /health, GET /openapi.json (must byte-match openapi.json).

## Scale rule
`POST /recipes/:id/scale {servings}` → quantities × servings/baseServings, `display` fraction-rounded to ¼ (½, ⅓, ⅛). Range 0.25x–4x enforced in UI.

## Budget (1 Worker + 1 D1 + 1 R2, free tier)
100k req/day, 5GB D1, 10GB R2. See api/README budget doc (Lane 1).
