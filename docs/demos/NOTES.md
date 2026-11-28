# PASS 2 — Screen recordings of the real Keep Cooking app

Three MP4s of the REAL running app (no mockups), driven deterministically by
a new XCUITest target while `simctl recordVideo` captures the simulator.
Branch: `xcode-full`. Only `apps/ios/**` + `docs/demos/**` touched.

## Device & OS

- Simulator device for recordings: **KeepCooking26** (created for this pass),
  iPhone 16 Pro, **iOS 26.5** (`D54DE10D-E9FD-4E87-87C5-CCA9AF0BFB67`).
- Build destination (per brief): `platform=iOS Simulator,OS=18.5,name=iPhone 16 Pro`
  — `xcodebuild … -scheme KeepCooking build` → **exit 0**.
- Host: Xcode 27.2 (27B52), xcodegen 2.48.0, macOS 25G342.

### Why not 18.5 for the recording (honest deviation)

The app **builds** for 18.5 but **does not install** on any iOS 18.x simulator:
`installd` rejects the SDK-27-built widget appex —
`com.apple.widgetkit … does not correspond to a known extension point`.
Reproduced on two 18.5 devices (iPhone 16 Pro `A1836DF7…` and iPhone 16 Pro
Max `18946963…`). The full bundle (app + share + widgets extensions) installs
and launches cleanly on iOS 26.5, so all three videos were recorded there.
Genuine project fixes committed along the way (needed on every runtime):

- `Config/Info-Share.plist`: added missing `NSExtension`
  (`com.apple.share-services` + URL/text activation rule) and
  `CFBundleDisplayName` — without these, install fails everywhere.
- `Config/Info-Widgets.plist`: added `NSExtension` (`com.apple.widgetkit`)
  + `CFBundleDisplayName` (same reason).

## Driving decision

**XCUITest, not scripted taps.** New `KeepCookingUITests` target
(`type: bundle.ui-testing`, in `project.yml`, generated via
`xcodegen generate — no hand-edited pbxproj`) with
`apps/ios/UITests/DemoFlowsUITests.swift`: three tests, one per video, with
~1s pauses at key beats so the MP4 is watchable. Accessibility identifiers
added in `apps/ios/App/DemoFlows.swift` (+ 4 `ocr-*` ids in OCRScanView).
To record: start `simctl io recordVideo` in the background, run the single
test, then `kill -INT <simctl-pid>` (SIGINT finalizes the file; plain `kill`
leaves a 0-byte mp4 + `.sb-*` temp).

## Exact commands (all exit 0 unless noted)

```sh
git checkout xcode-full
cd apps/ios && xcodegen generate          # picks up Seed resources + UITests target

# build (OS=18.5 per brief)
xcodebuild -project apps/ios/Smidgen.xcodeproj -scheme KeepCooking \
  -destination 'platform=iOS Simulator,OS=18.5,name=iPhone 16 Pro' build   # exit 0

# recording device (iOS 26.5 — see deviation note above)
xcrun simctl create "KeepCooking26" com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro \
  com.apple.CoreSimulator.SimRuntime.iOS-26-5
xcrun simctl boot D54DE10D-E9FD-4E87-87C5-CCA9AF0BFB67   # exit 0

# video 1 (fresh install first)
xcrun simctl uninstall D54DE10D-… org.smidgen.app        # exit 0
nohup xcrun simctl io D54DE10D-… recordVideo docs/demos/offline-launch.mp4 &
xcodebuild test -project apps/ios/Smidgen.xcodeproj -scheme KeepCookingUITests \
  -destination 'platform=iOS Simulator,name=KeepCooking26' \
  -only-testing:KeepCookingUITests/DemoFlowsUITests/testOfflineLaunch   # passed (18.2s)
kill -INT <recordVideo pid>

# videos 2, 3 — same pattern with testIngestSave / testPlanToList (both passed)
# post-process for compatibility + size:
ffmpeg -i IN.mp4 -c:v libx264 -crf 23 -preset medium -pix_fmt yuv420p \
  -c:a aac -movflags +faststart OUT.mp4
```

Unit suite (touched files it compiles): `xcodebuild test -scheme KeepCookingTests
-destination 'platform=iOS Simulator,name=KeepCooking26'` → **all passed**.

## What each video shows

| File | Dur / size | Beats |
|---|---|---|
| `offline-launch.mp4` | 31.8s / 1.7MB | Fresh install → Recipes lists 15 seeded recipes (Avocado Toast, Banana Bread, …) with zero backend; kill + relaunch → list persists (SwiftData offline-first). |
| `ingest-save.mp4` | 39.3s / 1.9MB | More → Scan cookbook (OCR) → type “Cream of Mushroom / 8 oz mushrooms / 2 cups cream / Simmer 20 minutes.” → **Parse text** → editable preview (`strategy=ocr confidence=0.70`) → **Save recipe** → green “Saved OCR recipe” confirmation. 3 taps, fully local. |
| `plan-to-list.mp4` | 49.2s / 1.5MB | Plan tab week view (Mon/Wed/Fri dinners seeded offline) → **Add week to list** → “Added 1 items to Weekly shop” → Lists tab: Weekly shop aisle-sorted (“salt · 3 tsp · spices”) → check-off → recipe detail → **Cook** → cook-mode step pager + Next. |

## Gaps / stubs (nothing faked)

- **URL/clipboard ingest is a stub without a backend.** `ClipView` /
  `CaptionsImportView` POST to `/clip`, which isn't configured, so they fail
  gracefully offline. The recorded ingest uses the OCR path, which is 100%
  local (paste → `OCR blockadeSplitter` → save into SwiftData). Wired into the
  app via More tab; both dead-end views remain reachable for when the backend
  exists.
- **Seeds are minimal stubs.** Every `packages/contracts/seed/recipe-*.json`
  carries a single `salt 1 tsp` ingredient, so the week aggregation correctly
  merges 3 plans into one “salt · 3 tsp” line (summed quantities + aisle guess
  `spices` prove the real `aggregateWeekToList` ran). Richer seeds will make
  this video prettier; the pipeline is honest.
- **Cook timers not exercised.** Seeds contain no timed steps, so the Timers
  section shows “No timers found”; the video reaches cook mode, pages steps,
  and the scaler UI is present. Pantry/barcode and webcal subscribe are not
  recorded (stub sheets / no Calendar in sim).
- iOS 18.5 recording was impossible (installd/widgetkit, above); 18.5 build
  verified green. The stray `KeepCooking26` simulator is intentional test infra.

## Menus demo (issue 25, no recording yet — simulator steps)

No `menus.mp4` recorded (no macOS host in CI). Manual simulator path covers
the same flow on iOS + Android against Room/SwiftData offline-first:

1. iOS: drawer → **Menus** (also via More → Menus). Android: Plan tab →
   **Reusable menus**. **Create** "Week 1 — High protein" → **Edit** →
   day-count stepper to 7, rename a slot if desired (slot renames update
   that slot's entries) → per-cell recipe picker assigns a recipe +
   servings (iOS shows photo + name, Android shows name) → Save.
   Only entry-backed days/slots persist and sync — trailing empty days
   from the stepper are editor-local until filled.
2. Rename to "Week 1 — HP", **Duplicate** ("Week 1 — HP copy"), delete copy.
3. **Apply to week** with week-start date → skip-filled ON leaves occupied
   day+meal plans intact (reports skipped count); toggle OFF overwrites
   (conflicts tombstoned first, LWW via `updatedAt`).
4. Plan tab day/week/month shows applied entries; **Add week to list**
   aggregates menu-applied recipes into the aisle-sorted grocery list.
5. Offline edit (airplane mode) → reconnect → converges via `SyncEnvelope`
   `entity: "menu"` outbox/LWW path like plans/lists (see
   `MenuPlanningTests` iOS / `MenuPlanningTest` Android for helper-unit
   coverage of day-count, slots, meal mapping, expand, and skip-filled
   filtering; API `menus` CRUD smoke in `api/test/recipes.test.ts`).
6. No contract changes: menu length/slots derive from `entries`
   (`dayOffset`/`meal`), persisted in existing `entriesJSON`/`entriesJson`.
   Custom slot labels are kept on the menu but mapped to a supported plan
   meal (breakfast/lunch/dinner/snack, else dinner) at apply time, since
   plans only allow those four; entries with an empty meal or
   `dayOffset` outside 0–27 are ignored by Apply and reported.

## Backend origin (issue 28)

- Canonical API origin is now `https://keepcooking.app/api` (custom domain
  in front of the same single Worker + D1 + R2 — no new infra). One-time
  prerequisite: a Cloudflare Worker Route `keepcooking.app/api/*` → the
  `keep-cooking-api` Worker (plus DNS for `keepcooking.app`) must exist
  before this base URL works — until then keep using the workers.dev origin
  with the same `/api` prefix (`https://keep-cooking-api.<account>.workers.dev/api`,
  not the bare origin: this Worker serves `/api/…` only, so root paths 404).
- The Worker serves `/api/…` only (no root-path fallback). Old
  `https://keep-cooking-api.<account>.workers.dev` root-path clients 404 —
  expected: pre-launch, single tester, just update the base URL.
- Any demo command that used the workers.dev origin can swap the base URL
  to `https://keepcooking.app/api` with no other change (auth is
  header-signature over the full path, not cookies) — EXCEPT manually
  signed curl commands: the signature canonical string covers the full
  path as sent, so re-derive it from the serialized request URL
  (`METHOD + "\n" + /api/...path+query + "\n" + ts + "\n" + hex(SHA256(body))`).
  Swapping only the host while signing the old root path yields 401.
