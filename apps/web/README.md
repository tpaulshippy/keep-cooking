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
`history.replaceState` to the history equivalent. The Worker assets handler
falls back unknown `/app/*` paths to `/app/index.html` so deep links
cold-load correctly (no server rewrite rules needed); the router then
parses `location.pathname` after the `/app` base.

## `API_BASE_URL` config

Resolution order:

1. `localStorage` override `kc.apiBase` (editable in Settings).
2. `http://localhost:8787` when the page is served from `localhost`/`127.0.0.1`.
3. Default `https://keepcooking.app/api`.

## How `/app` + `/api` + `/` coexist

Same Worker family: `/` serves the marketing/landing surface, `/api/*`
serves the Hono API, and `/app/*` serves this static SPA bundle. All route
paths are real history URLs (`/app/recipes/:id`), so every deep link
resolves to the same `index.html` via the Worker `/app/*` fallback, and the
router parses `location.pathname` client-side.

## Offline model

All collections (recipes, plans, menus, lists, pantry) persist in
`localStorage` (`kc.*` keys). Mutations write a `SyncEnvelope`
`{id, updatedAt, deviceId, deleted?, entity, payload}` to the collection and
append it to the `kc.outbox` queue. Merge is last-writer-wins on
`updatedAt`, ties keep the stored record (replay-safe), tombstones
(`deleted: true`) filter from views but still merge — the same semantics as
the native `SyncEngine`. First paint is useful offline: the store ships with
3 seeded demo recipes. Push drains the outbox against the API; pull applies
remote envelopes via LWW without re-queueing.

## Budget note

Static assets only — no new Worker, D1, or R2 resources. Sync reuses the
existing API and device-key auth; reads stay open, writes carry the
`x-device-*` Ed25519 signature over the canonical string from
`api/src/auth.ts`.

## Scripts

- `npm run dev` — Vite dev server on :5174
- `npm run build` — typecheck + static build to `dist/`
- `npm run typecheck` / `npm test -- --run` / `npm run smoke`
