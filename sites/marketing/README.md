# Marketing site — keepcooking.app `/`

Static marketing site for the apex/root. Deploys independently of the API
worker and the `/app` web app.

- Source: `sites/marketing/public/` → build output: `sites/marketing/dist/`
- Build: `npm run build --prefix sites/marketing` (Node only, no deps:
  runs content checks then copies `public/` → `dist/`)

## Why `sites/marketing/`

`apps/` holds runnable software (iOS, Android). The marketing site is a
deployable web property, not an app, so it lives under `sites/` — the same
split Pages/Workers projects use — keeping deploys and ownership separate.

## Deploy (Cloudflare Pages, free tier)

1. New Pages project → upload `sites/marketing/dist/` (or point Pages at
   this repo with build command `npm run build --prefix sites/marketing`
   and output directory `sites/marketing/dist`).
2. Custom domain: `keepcooking.app` (+ `www`).
3. Path safety: `dist/_routes.json` explicitly excludes `/api/*` and
   `/app/*`, which are served by the API Worker (`api/wrangler.toml`) and
   the web-app project (issue #27) — this project owns only `/`.
4. No environment variables, secrets, or bindings. No analytics: the site
   ships zero trackers by choice (see `/privacy.html`).

## Validation

- `npm run build --prefix sites/marketing` — content checks (sections,
  tour coverage, copy accuracy, OG/JSON-LD, path-collision) + dist build.
- Lighthouse: serve `dist/` locally and run desktop + mobile; target ≥90
  perf and a11y (report attached to PR #29).
