# Contracts v0.2.0 — source of truth. No lane changes without orchestrator approval.

Ownership: orchestrator only. Lanes consume, never edit.

Contents:
- `openapi.yaml` (+ generated `openapi.json` — run `python3 -c "import yaml,json; json.dump(yaml.safe_load(open('openapi.yaml')),open('openapi.json','w'),indent=2)"`)
- `mcp-tools.json` — versioned MCP tool schemas served verbatim by POST /mcp tools/list (#26)
- `schema.sql` — D1 SQLite. SwiftData models must be 1:1 (Recipe, Ingredient, Step, List, PantryItem, Plan, Menu).
- `examples/Recipe.json`, `ClipReport.json`, `SyncEnvelope.json`
- `PHOTO_VARIANTS.md` — variant rules
- `seed/` — 12 recipes + 3 near-duplicates for dup-finder tests
- `CHANGELOG.md` — versioned

## SyncEnvelope
`{ id: uuid, updatedAt: ISO8601, deviceId: string, deleted?: bool, entity, payload }`.
Last-write-wins on `updatedAt`; `deleted=true` = tombstone, never hard-delete on sync. Outbox queue on device, `GET /sync/pull?since=` + `POST /sync/push`.

## EncryptedEnvelope (E2E v2 — v1 SyncEnvelope untouched)
`examples/EncryptedEnvelope.json` shows the shape (opaque sample bytes, not
real ciphertext): `{ v: 2, alg: "AES-GCM-256", kid, householdHash,
id, entity, updatedAt, deviceId, deleted?, nonce, ciphertext }` — 1:1 with
the `EncryptedEnvelope` schema in `openapi.yaml` / `api/src/e2e.ts` and
`docs/e2e-v1.md`. v1 `SyncEnvelope` (`examples/SyncEnvelope.json`) is
unchanged: v2 wraps it, the server stores routing metadata + opaque bytes
only. `entity` is `recipe | list | pantryItem | plan | menu` (standalone
`ingredient` / `step` → HTTP 422, fold into the parent recipe pre-encrypt).
Zero-knowledge scope is the `/v2/sync/:hash` route only — legacy
`/sync/*` plaintext + R2 photo routes remain outside it.

## ImportReport
`{ imported: Recipe[], updated: number, warnings[], dryRun?, cookbooksCreated? }`.
Mirrors ClipReport conventions (parsed recipes + warnings[]). POST /import accepts
`{ householdId, format, payload (base64) | payloadJson, importCookbooks?, dryRun? }`.
Actually parsed today: Paprika native (paprika-json, paprika-zip incl. paprika-recipe
single-file alias), yaml, html. 415-stubbed with re-export guidance (parsers not
landed): mx2|mxp|mz2|mmf|fdx|fdxz|pepperplate|copymethat|yum. Remaining contract
enum values (pepperplate-zip|pepperplate-db|copymethat-zip|yum-xml|ysr|mgourmet|dvo|
mcb|recipe-manager-txt|hcb|myrecipebook-sqlite|rbox) have no handler yet → 400
unsupported. `paprikaUid` is the upsert key (re-import updates in place);
YAML is create-only (no identity). Optional Paprika extension fields on Recipe/RecipeInput
(all optional, non-breaking): notes, nutritionText, difficulty, servingsText,
prepTimeText/cookTimeText/totalTimeText, paprikaUid, paprikaRaw, cookbooks[], isFavorite, scaleFactor.

## ClipReport
`{ strategy: jsonld|reader|caption|ocr, confidence 0-1, warnings[], sourceUrl, recipe: RecipeInput }`.
Server tries JSON-LD → reader → caption fallback, logs which. All parsing unit-tested client-side too.

## Auth / RBAC
Single device-key auth (open auth, no login). `householdId` on every entity. Roles: owner/member/viewer. Viewer read-only, member CRUD, owner + invites/deletes.

## Endpoints (see openapi.yaml)
POST /clip, POST /import, CRUD /recipes, POST /recipes/:id/scale, CRUD /lists + /pantry, CRUD /plans + /menus, GET /plans/feed.ics, POST /share/cookbook, GET /export/:id.(json|md|html|paprikarecipes|yaml) + GET /export bulk (?format=json|md|html|paprikarecipes|yaml, ?all, ?ids, ?cookbook), GET /sync/pull, POST /sync/push, GET /health, GET /openapi.json (must byte-match openapi.json).
Key-only agent access (#26): POST /agent/enroll, GET /agent/status, POST /mcp (stateless JSON-RPC; schemas in mcp-tools.json). For v1 mutations, `x-agent-token` replaces the device signature (or local dev headers); requests are scoped to the enrolled household.

## Scale rule
`POST /recipes/:id/scale {servings}` → quantities × servings/baseServings, `display` fraction-rounded to ¼ (½, ⅓, ⅛). Range 0.25x–4x enforced in UI.

## Budget (1 Worker + 1 D1 + 1 R2, free tier)
100k req/day, 5GB D1, 10GB R2. See api/README budget doc (Lane 1).
