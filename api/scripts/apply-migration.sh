#!/usr/bin/env bash
# Apply one wrangler D1 migration file, tolerating ONLY the benign
# duplicate-column rerun. One-time ALTER TABLE migrations (SQLite has no
# ADD COLUMN IF NOT EXISTS) fail with "duplicate column ..." when replayed
# after a successful apply — that single case is safe to ignore. Every
# other failure (transient network, syntax, missing table/column, auth)
# aborts loudly so a deploy never proceeds against a missing schema.
#
# Usage: apply-migration.sh --local|--remote <migration-file>
# Exit: 0 on applied-or-already-applied, wrangler's status otherwise.
set -uo pipefail

target="$1" # --local or --remote
file="$2"

out="$(npx wrangler d1 execute keep-cooking "$target" --file="$file" 2>&1)"
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
