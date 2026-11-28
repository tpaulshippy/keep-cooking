#!/usr/bin/env bash
# Apply one wrangler D1 migration file, tolerating ONLY the benign
# duplicate-column rerun. One-time ALTER TABLE migrations (SQLite has no
# ADD COLUMN IF NOT EXISTS) fail with "duplicate column ..." when replayed
# after a successful apply — that single case is safe to ignore. Every
# other failure (transient network, syntax, missing table/column, auth)
# aborts loudly so a deploy never proceeds against a missing schema.
#
# Usage: [WRANGLER_BIN=/path/to/wrangler] apply-migration.sh --local|--remote <migration-file>
# The deploy script preflights `wrangler` and exports its exact path via
# WRANGLER_BIN so both use the same executable (npx could resolve a
# different copy). Direct runs fall back to resolving `wrangler` from PATH
# the same way the deploy preflight does; a missing binary is a loud 127.
# Exit: 0 on applied-or-already-applied, wrangler's status otherwise.
set -uo pipefail

target="$1" # --local or --remote
file="$2"

WRANGLER_BIN="${WRANGLER_BIN:-$(command -v wrangler || true)}"
if [ -z "$WRANGLER_BIN" ]; then
  echo "ERROR: wrangler not found (set WRANGLER_BIN or put wrangler on PATH)" >&2
  exit 127
fi

out="$("$WRANGLER_BIN" d1 execute keep-cooking "$target" --file="$file" 2>&1)"
status=$?
printf '%s\n' "$out"
if [ "$status" -ne 0 ]; then
  if printf '%s\n' "$out" | grep -qi "duplicate column"; then
    echo "($(basename "$file" .sql) already applied — duplicate column tolerated)"
    exit 0
  fi
  echo "ERROR applying $file (exit $status) — aborting, not masking the failure" >&2
  exit "$status"
fi
