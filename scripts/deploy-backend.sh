#!/usr/bin/env bash
# Keep Cooking — fresh BYO backend deploy (Worker + D1 + R2).
# Prints the Worker URL to paste into the app: Settings → Server (BYO backend).
#
# Usage:
#   INTERNAL_BETA_TOKEN=$(openssl rand -base64 32) ./scripts/deploy-backend.sh
#   PUBLIC_BASE_URL=https://api.example.com INTERNAL_BETA_TOKEN=… ./scripts/deploy-backend.sh
#   BYO_NO_TOKEN=1 ./scripts/deploy-backend.sh   # explicit local/no-token setup only
#
# Prerequisites: `wrangler login`, node >= 20, curl. Run from the repo root.
# The script is idempotent-ish: D1/R2 creates are skipped when they exist,
# secrets are only (re)set when provided via env.

set -euo pipefail

cd "$(dirname "$0")/.."

API_DIR="api"
TOKEN="${INTERNAL_BETA_TOKEN:-}"
BASE_URL="${PUBLIC_BASE_URL:-}"
# Explicit opt-out for a local/no-token backend (writes ungated — never expose).
ALLOW_NO_TOKEN="${BYO_NO_TOKEN:-}"

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

need wrangler
need node
need curl

if [ ! -d "$API_DIR" ]; then
  echo "run from the repo root (expected ./$API_DIR)" >&2
  exit 1
fi

# Exact-name match on captured command output (no SIGPIPE: never pipe the
# live listing straight into grep -q). Matches JSON `"name": "<want>"` or a
# table row where <want> stands alone (not a prefix/suffix of another name:
# "keep-cooking" must not match "keep-cooking2"/"my-keep-cooking"; "keep-cooking-photos" must not
# match "keep-cooking-photos2").
exact_name_present() {
  local want="$1" text="$2"
  printf '%s\n' "$text" | grep -qF "\"name\": \"$want\"" && return 0
  printf '%s\n' "$text" | grep -qF "\"name\":\"$want\"" && return 0
  printf '%s\n' "$text" | grep -qE "(^|[^A-Za-z0-9_.-])${want}([^A-Za-z0-9_.-]|\$)" && return 0
  return 1
}

echo "==> 1/6 D1 database (keep-cooking)"
D1_LIST="$(wrangler d1 list 2>/dev/null || true)"
if exact_name_present "keep-cooking" "$D1_LIST"; then
  echo "    D1 'keep-cooking' already exists — keeping it."
else
  D1_CREATE="$(wrangler d1 create keep-cooking 2>&1)"
  printf '%s\n' "$D1_CREATE"
  # Resolve the new database_id and write it into api/wrangler.toml before
  # deploy so the Worker binds the database we just created (not the
  # local-keepcooking-placeholder).
  NEW_DB_ID="$(printf '%s\n' "$D1_CREATE" | grep -oE '"database_id"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n 1 | cut -d'"' -f4 || true)"
  if [ -z "${NEW_DB_ID:-}" ]; then
    NEW_DB_ID="$(printf '%s\n' "$D1_CREATE" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -n 1 || true)"
  fi
  if [ -n "${NEW_DB_ID:-}" ]; then
    if grep -qE '^[[:space:]]*database_id[[:space:]]*=' "$API_DIR/wrangler.toml"; then
      # Portable in-place update (macOS + GNU sed).
      sed -i.bak -E "s|^[[:space:]]*database_id[[:space:]]*=.*|database_id = \"$NEW_DB_ID\"|" "$API_DIR/wrangler.toml"
      rm -f "$API_DIR/wrangler.toml.bak"
    else
      printf 'database_id = "%s"\n' "$NEW_DB_ID" >> "$API_DIR/wrangler.toml"
    fi
    echo "    wrote database_id $NEW_DB_ID into $API_DIR/wrangler.toml"
  else
    echo "    ERROR: could not parse database_id from create output — aborting" >&2
    echo "    rather than deploying against the placeholder/wrong D1." >&2
    echo "    Copy it by hand into $API_DIR/wrangler.toml, then re-run." >&2
    exit 1
  fi
fi

echo "==> 2/6 R2 bucket (keep-cooking-photos)"
R2_LIST="$(wrangler r2 bucket list 2>/dev/null || true)"
if exact_name_present "keep-cooking-photos" "$R2_LIST"; then
  echo "    R2 'keep-cooking-photos' already exists — keeping it."
else
  wrangler r2 bucket create keep-cooking-photos
fi

echo "==> 3/6 D1 schema (remote)"
for migration in "$API_DIR/drizzle/0001_init.sql" "$API_DIR/drizzle/0002_e2e_blobs.sql" "$API_DIR/drizzle/0003_agent_enrollments.sql"; do
  if [ -f "$migration" ]; then
    echo "    applying $migration --remote"
    wrangler d1 execute keep-cooking --remote --file="$migration"
  else
    echo "    skipping $migration (not found)"
  fi
done

echo "==> 4/6 secrets / vars"
if [ -n "$TOKEN" ]; then
  printf '%s' "$TOKEN" | wrangler secret put INTERNAL_BETA_TOKEN
  echo "    INTERNAL_BETA_TOKEN secret set. Enter the same value in the app:"
  echo "    Settings → Server (BYO backend) → Beta token → Save & sync now."
else
  echo "    INTERNAL_BETA_TOKEN not provided; checking existing secret…"
  SECRET_LIST="$(wrangler secret list 2>/dev/null || true)"
  if exact_name_present "INTERNAL_BETA_TOKEN" "$SECRET_LIST"; then
    echo "    secret already set — keeping it."
    echo "    Make sure the same value is entered in the app:"
    echo "    Settings → Server (BYO backend) → Beta token → Save & sync now."
  elif [ "$ALLOW_NO_TOKEN" = "1" ]; then
    # BYO_NO_TOKEN=1 leaves writes ungated, so it is only ever valid
    # against a genuinely local dev target. Refuse remote deploys (the
    # checked-in workers.dev URL included) — gated writes there would 401
    # on every request with no token configured.
    NO_TOKEN_TARGET="${BASE_URL:-}"
    if [ -z "$NO_TOKEN_TARGET" ]; then
      NO_TOKEN_TARGET="$(grep -E '^[[:space:]]*PUBLIC_BASE_URL[[:space:]]*=' "$API_DIR/wrangler.toml" | cut -d'"' -f2 | head -n 1 || true)"
    fi
    case "$NO_TOKEN_TARGET" in
      *localhost*|*127.0.0.1*|*.local*)
        echo "    BYO_NO_TOKEN=1: proceeding WITHOUT a beta token against local target $NO_TOKEN_TARGET." >&2
        echo "    Writes are ungated — never expose this backend." >&2
        ;;
      *)
        echo "    ERROR: BYO_NO_TOKEN=1 is for a local dev target only (localhost / 127.0.0.1 / *.local)." >&2
        echo "    Target '${NO_TOKEN_TARGET:-<unknown>}' is remote and gated writes would 401." >&2
        echo "    Either provide INTERNAL_BETA_TOKEN or point PUBLIC_BASE_URL at a local dev server." >&2
        exit 1
        ;;
    esac
  else
    echo "    ERROR: INTERNAL_BETA_TOKEN is required." >&2
    echo "    Re-run with: INTERNAL_BETA_TOKEN=\$(openssl rand -base64 32) ./scripts/deploy-backend.sh" >&2
    echo "    Then enter the same value in the app: Settings → Server (BYO backend) → Beta token." >&2
    echo "    (Only for an explicit local/no-token setup: BYO_NO_TOKEN=1 ./scripts/deploy-backend.sh)" >&2
    exit 1
  fi
fi
if [ -n "$BASE_URL" ]; then
  if grep -qE '^[[:space:]]*PUBLIC_BASE_URL[[:space:]]*=' "$API_DIR/wrangler.toml"; then
    sed -i.bak -E "s|^[[:space:]]*PUBLIC_BASE_URL[[:space:]]*=.*|PUBLIC_BASE_URL = \"$BASE_URL\"|" "$API_DIR/wrangler.toml"
    rm -f "$API_DIR/wrangler.toml.bak"
  else
    printf '\nPUBLIC_BASE_URL = "%s"\n' "$BASE_URL" >> "$API_DIR/wrangler.toml"
  fi
  echo "    PUBLIC_BASE_URL=$BASE_URL (written to $API_DIR/wrangler.toml [vars])"
fi

echo "==> 5/6 deploy worker"
DEPLOY_LOG="$(mktemp)"
trap 'rm -f "$DEPLOY_LOG"' EXIT
(cd "$API_DIR" && wrangler deploy 2>&1 | tee "$DEPLOY_LOG")

echo "==> 6/6 health check"
# Health-check the actual published URL captured from this deploy's output —
# not a stale dry-run guess.
WORKER_URL="$(grep -oE 'https://[a-zA-Z0-9.-]+\.workers\.dev' "$DEPLOY_LOG" | head -n 1 || true)"
if [ -z "$WORKER_URL" ] && [ -n "$BASE_URL" ]; then
  WORKER_URL="$BASE_URL"
fi
if [ -z "$WORKER_URL" ]; then
  WORKER_URL="$(grep -E '^[[:space:]]*PUBLIC_BASE_URL[[:space:]]*=' "$API_DIR/wrangler.toml" | cut -d'"' -f2 | head -n 1 || true)"
fi
if [ -z "$WORKER_URL" ]; then
  echo "    could not determine the published Worker URL from deploy output" >&2
  exit 1
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
if [ -n "$TOKEN" ]; then
  echo "  + enter your INTERNAL_BETA_TOKEN in the Beta token field → Save & sync now"
fi
echo "================================================================"
