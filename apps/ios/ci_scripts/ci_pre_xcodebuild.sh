#!/bin/sh
# Xcode Cloud pre-build: stamp a unique build number so every TestFlight
# upload is accepted (Apple rejects re-uploaded build numbers).
# Locally this is a no-op (CI_BUILD_NUMBER only exists in Xcode Cloud).
#
# KeepCooking upload set: app + widgets + share ONLY
# (org.smidgen.app, org.smidgen.app.widgets, org.smidgen.app.share).
# KeepCookingWatch (org.smidgen.app.watch) is a standalone watchOS app that
# stays in-tree but is NOT uploaded (pair at distribution time), so it is
# deliberately left out of the plist fallback below. The pbxproj sed is
# global and covers all 6 targets, which is harmless for watch/tests.
set -e

if [ -z "${CI_BUILD_NUMBER:-}" ]; then
  echo "No CI_BUILD_NUMBER (local build) — leaving build number alone."
  exit 0
fi

echo "Stamping build number ${CI_BUILD_NUMBER}"

# Primary mechanism: project-level CURRENT_PROJECT_VERSION (project.yml
# `settings:`) lands in the pbxproj after `xcodegen generate`. One global
# sed covers all 6 targets (app/widgets/share/tests/watch/uitests).
ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/../.." && pwd)}"
PBX=""
for candidate in "$ROOT/apps/ios/Smidgen.xcodeproj/project.pbxproj" \
                 "$ROOT/apps/ios/KeepCooking.xcodeproj/project.pbxproj" \
                 "$ROOT/Smidgen.xcodeproj/project.pbxproj" \
                 "$ROOT/KeepCooking.xcodeproj/project.pbxproj"; do
  if [ -f "$candidate" ]; then
    PBX="$candidate"
    break
  fi
done

STAMPED=0
if [ -n "$PBX" ]; then
  # shellcheck disable=SC2016
  if grep -q 'CURRENT_PROJECT_VERSION = [0-9]*;' "$PBX"; then
    sed -i '' 's/CURRENT_PROJECT_VERSION = [0-9]*;/CURRENT_PROJECT_VERSION = '"${CI_BUILD_NUMBER}"';/g' "$PBX"
    STAMPED=1
    echo "Stamped CURRENT_PROJECT_VERSION=${CI_BUILD_NUMBER} in $PBX"
  else
    echo "WARNING: no CURRENT_PROJECT_VERSION in $PBX (regen pending?) — using plist fallback."
  fi
else
  echo "WARNING: project.pbxproj not found under $ROOT — using plist fallback."
fi

# Fallback (pre-regen layouts where the build setting has not landed in the
# pbxproj yet): stamp CFBundleVersion directly in the 3 UPLOAD targets'
# Info plists. Watch/tests plists are intentionally untouched.
if [ "$STAMPED" -eq 0 ]; then
  for plist in "$ROOT/apps/ios/Config/Info-App.plist" \
               "$ROOT/apps/ios/Config/Info-Widgets.plist" \
               "$ROOT/apps/ios/Config/Info-Share.plist"; do
    if [ -f "$plist" ]; then
      /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${CI_BUILD_NUMBER}" "$plist" \
        || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string ${CI_BUILD_NUMBER}" "$plist"
      echo "Stamped CFBundleVersion=${CI_BUILD_NUMBER} in $plist"
    else
      echo "WARNING: plist not found: $plist"
    fi
  done
fi
