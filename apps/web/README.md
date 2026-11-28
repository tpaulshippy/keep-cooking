# keep-cooking-web

Offline-first single-page app served at `/app`.

Framework choice: no framework — plain TypeScript + Vite. The app is form-and-list CRUD over a local store with tiny view functions; React/Vue would add bundle weight and build complexity for no behavioral gain, and vanilla keeps the free-tier static bundle minimal while still supporting deep links, keyboard nav and focus states.

## Routes (History API under `/app`)

| History path | View |
|---|---|
| `/app/` | Home + recent recipes |
| `/app/recipes` | Library list + search |
| `/app/recipes/:id` | Recipe detail + delete |
| `/app/cook/:id` | Cook mode: steps + serving scaler + timers + cross-off |
| `/app/plan` | Plan day/week + aggregate week to list |
| `/app/lists` | Shop lists (aisle-sorted) + pantry |
| `/app/menus` | Menus list + apply to week + add week to list |
| `/app/ingest` | Clip URL / caption / clipboard (online API, offline draft fallback) |
| `/app/settings` | API base, enroll, push/pull, share link, export JSON + Markdown |

Legacy hash URLs (`/app/#/recipes/:id`) are upgraded once on load via
`history.replaceState` to the history equivalent. The router parses
`location.pathname` after the `/app` base.

## Deploy prerequisite: `/app/*` fallback (manual step, not yet wired)

Deep links (`/app/recipes/:id`) cold-load correctly **only if** the host
serving `/app/*` returns `/app/index.html` for unknown `/app/*` paths. The
API Worker in this repo does **not** serve `/app` — `api/wrangler.toml` has
no `[assets]` binding, and `apps/web/dist` is build output (gitignored), so
there is nothing for the API Worker to fall back to. Until hosted separately:

- Prerequisite: deploy the built `apps/web/dist` to a **separate static
  host** (e.g. Cloudflare Pages, or a dedicated Worker with
  `not_found_handling = "single-page-application"`), then route
  `keepcooking.app/app/*` to that host (or an equivalent rewrite of
  `/app/*` → `/app/index.html`).
- Without it: `/app/` loads and all in-app navigation works, but a cold load,
  refresh, or shared link to any deeper path (e.g. `/app/recipes/:id`)
  returns 404 instead of the app.

## `API_BASE_URL` config

Resolution order:

1. `localStorage` override `kc.apiBase` (editable in Settings).
2. `http://localhost:8787/api` when the page is served from `localhost`/`127.0.0.1`.
3. Default `https://keepcooking.app/api`.

## How `/app` + `/api` + `/` coexist

Three separate surfaces on one domain: `/` is the marketing/landing surface,
`/api/*` is served by the Hono API Worker in `api/`, and `/app/*` is served
by a separate static host (see the deploy prerequisite above — not the API
Worker). All `/app` route paths are real history URLs
(`/app/recipes/:id`); they resolve to the same `index.html` **once that
static host's SPA fallback is wired**, and the router parses
`location.pathname` client-side.

## Offline model

All collections (recipes, plans, menus, lists, pantry) persist in
`localStorage` (`kc.*` keys). Mutations write a `SyncEnvelope`
`{id, updatedAt, deviceId, deleted?, entity, payload}` to the collection and
append it to the `kc.outbox` queue. Merge is last-writer-wins on
`updatedAt`; ties take the incoming (remote) envelope for deterministic
convergence, identical same-device replays are no-ops, and tombstones
(`deleted: true`) filter from views but still merge — the same semantics as
the native `SyncEngine` (`mergeOutcome` in `apps/ios/Sync/SyncEngine.swift`).
First paint is useful offline: the store ships with the 15 frozen contract seeds (packages/contracts/seed/recipe-*.json — the same files iOS and Android load).
Push (`src/sync.ts`) attempts each queued envelope and acks only envelopes
whose mutation actually succeeded, by `(id, updatedAt)` identity — failures
stop the run and stay queued; update-404 falls back to create + reconcile
with the server record (an exact-single uncertain match is adopted, so
routine offline drafts avoid duplicating on pull — ambiguous or unmatched
drafts still create, and may duplicate); pull
applies remote envelopes via LWW without re-queueing.

## Budget note

Static assets only — no new Worker, D1, or R2 resources. Sync reuses the
existing API and device-key auth; reads stay open, writes carry the
`x-device-*` Ed25519 signature over the canonical string from
`api/src/auth.ts`.

## Scripts

- `npm run dev` — Vite dev server on :5174
- `npm run build` — typecheck + static build to `dist/`
- `npm run typecheck` / `npm test -- --run` / `npm run smoke`
