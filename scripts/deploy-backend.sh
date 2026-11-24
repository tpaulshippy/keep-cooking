#!/usr/bin/env bash
# Smidgen — fresh BYO backend deploy (Worker + D1 + R2).
# Prints the Worker URL to paste into the app: Settings → Server (BYO backend).
#
# Usage:
#   ./scripts/deploy-backend.sh
#
# Prerequisites: `wrangler login`, node >= 20. Run from the repo root.
# The script is idempotent-ish: D1/R2 creates are skipped when they exist,
# secrets are only (re)set when provided via env.

set -euo pipefail

cd "$(dirname "$0")/.."

API_DIR="api"
TOKEN="${INTERNAL_BETA_TOKEN:-}"
BASE_URL="${PUBLIC_BASE_URL:-}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

need wrangler
need node

if [ ! -d "$API_DIR" ]; then
  echo "run from the repo root (expected ./$API_DIR)" >&2
  exit 1
fi

echo "==> 1/5 D1 database (smidgen)"
if wrangler d1 list 2>/dev/null | grep -q "smidgen"; then
  echo "    D1 'smidgen' already exists — keeping it."
else
  wrangler d1 create smidgen
  echo "    NOTE: copy the printed database_id into $API_DIR/wrangler.toml"
fi

echo "==> 2/5 R2 bucket (smidgen-photos)"
if wrangler r2 bucket list 2>/dev/null | grep -q "smidgen-photos"; then
  echo "    R2 'smidgen-photos' already exists — keeping it."
else
  wrangler r2 bucket create smidgen-photos
fi

echo "==> 3/5 secrets / vars"
if [ -n "$TOKEN" ]; then
  printf '%s' "$TOKEN" | wrangler secret put INTERNAL_BETA_TOKEN
else
  echo "    INTERNAL_BETA_TOKEN not provided; checking existing secret…"
  if wrangler secret list 2>/dev/null | grep -q "INTERNAL_BETA_TOKEN"; then
    echo "    secret already set — keeping it."
  else
    echo "    WARNING: no INTERNAL_BETA_TOKEN. Prod gates writes behind it." >&2
    echo "    Re-run with: INTERNAL_BETA_TOKEN=\$(openssl rand -base64 32) ./scripts/deploy-backend.sh" >&2
  fi
fi
if [ -n "$BASE_URL" ]; then
  echo "    PUBLIC_BASE_URL=$BASE_URL (set in $API_DIR/wrangler.toml [vars])"
fi

echo "==> 4/5 deploy worker"
(cd "$API_DIR" && wrangler deploy)

echo "==> 5/5 health check"
WORKER_URL="$(cd "$API_DIR" && wrangler deploy --dry-run 2>/dev/null | grep -oE 'https://[a-zA-Z0-9.-]+\.workers\.dev' | head -n 1 || true)"
if [ -z "$WORKER_URL" ]; then
  # Fall back to the configured public URL.
  WORKER_URL="$(grep -E '^PUBLIC_BASE_URL' "$API_DIR/wrangler.toml" | cut -d'"' -f2)"
fi
echo "    GET $WORKER_URL/health"
curl -fsS "$WORKER_URL/health" || {
  echo "    health check failed — verify the Worker URL and bindings" >&2
  exit 1
}

echo ""
echo "================================================================"
echo "  Backend is live: $WORKER_URL"
echo "  Paste it into the app: Settings → Server (BYO backend) → Test"
echo "================================================================"
