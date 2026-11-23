# Lane 5 — Organize + Share + System (iOS)

Owner: Lane 5. Scope: `apps/ios/Features/Library/**`, `apps/ios/Widgets/**`,
`apps/ios/watch/**`, `apps/ios/Intents/**`, `apps/ios/Export/**` ONLY.
Never touched: `api/`, `packages/contracts`, `Core/`, `Sync/`, other Features,
`App/`. Integration steps that land outside this scope are listed under
**Needed from other lanes** — they are explicit asks, not silent edits.

## What shipped

### Library (`Features/Library/`)

| File | Contents |
|---|---|
| `LibrarySearch.swift` | Foundation-only full-text + advanced filter (`AdvancedFilter`: query, include/exclude terms, max total minutes, min rating, source substring, categories). `filterRecipes` + `matchesFilter` are pure; `Recipe` conforms via extension in `LibraryModels`. |
| `DuplicateFinder.swift` | Foundation-only fuzzy duplicate detection + merge planning. |
| `LibraryModels.swift` | `@Model Cookbook` (id-synced recipe-id list), `@Model SavedSearch` (local-only JSON filter), `HouseholdInvite` + `CookbookShareLink` DTOs, `ShareAPIClient` for Lane 1 `POST /share/cookbook`. |
| `LibraryViews.swift` | `LibraryHomeView` (categories w/ counts, cookbooks, saved searches, duplicate badge), `LibrarySearchView` + `AdvancedFilterForm`, `CookbookEditView`/`CookbookDetailView`, `DuplicateReviewView` (merge + keep-both dismissal persisted to UserDefaults). |
| `ShareViews.swift` | `HouseholdInvitesView` (create/copy/share/revoke, expiry-tracked), `CookbookShareView` (creates Lane 1 share link, ShareLink + copy). |
| `DuplicateFinderTests.swift` | XCTest: all 3 seeded dupes caught, no false positives, merge semantics, normalization. |

### Duplicate finder — why 4 signals

The frozen seeds prove titles alone are insufficient (all 15 seeds also share
byte-identical stub content: `1 tsp salt` + `Cook and serve.`):

- **(a) Title token Jaccard ≥ 0.5** — catches `14 "Miso Salmon Weeknight"` ↔ `01 "Weeknight Miso Salmon"`.
- **(b) Edit similarity ≥ 0.8** — close spellings/word order.
- **(c) Copy markers** — `strippedCopyTitle`: `Copy of X`→`X`, `X (1)`→`X`.
- **(d) Explicit reference** — `referenceFragment`: `dup of 09` names the seed whose id ends `…000009`. Required for seed 13, which shares no title tokens and no *distinctive* content with 09.
- **(e) Content Jaccard ≥ 0.8 with ≥ 6 content tokens/side** — real dupes with real ingredient lists. The ≥ 6-token floor is load-bearing: without it every seed would cluster with every other seed on the shared stub content.

Merge (`planMerge`): survivor = most ingredients → has photo → highest rating → lowest id. Absorbs **best photo** (longest non-empty photo key = highest-resolution R2 variant), **union ingredients** (case-insensitive dedup, sorted), union categories, best rating. `DuplicateReviewView.applyMerge` tombstones losers (sync-safe) and appends missing ingredients as real `Ingredient` rows.

### Share

- Cookbook shares call Lane 1 `POST /share/cookbook` and render the returned `{id, url, expiresAt}`. Base URL persists in UserDefaults (`smidgen.apiBaseURL`, default `http://localhost:8787`).
- Household invites are **out-of-band** (ShareLink → Messages/Mail) with code, expiry, max-uses, and `smidgen://invite/<code>` deep-link shape. No server route exists yet (see Not Yet).

### Export (`Export/`)

- `RecipeExporter.swift` (Foundation-only): `exportJSON` / `exportMarkdown` / `exportHTML`, mirroring `api/src/export.ts` (Markdown line style, `PT<n>M` durations, JSON-LD `Recipe` block). HTML escapes `<` inside JSON-LD so `</script>` can never break out.
- `ExportView.swift`: recipe picker + format picker + preview + ShareLink temp-file export (offline-capable).
- `EXPORT_SAMPLES/recipe.{json,md,html}`: generated **from the real Swift exporter** (`swiftc` compile of `RecipeExporter.swift` + a seed-01-based main), validated: JSON parses with 4 ingredients/3 steps; Markdown spot-checked; HTML contains exactly one `application/ld+json` block whose `@type` is `Recipe` with `prepTime PT10M`/`cookTime PT20M`, 4 `recipeIngredient`, 3 `HowToStep`.

### System — Widgets, Intents, Watch

- `Widgets/WidgetSnapshot.swift` (Foundation-only, shared by app/widget/watch/tests): `TodaySnapshot` over App Group `group.com.smidgen.shared`, key `smidgen.snapshot.v1`. Reads never throw — corrupt/missing data yields `.empty`.
- `Widgets/SmidgenWidgets.swift`: **Today Plan** widget (today's meals, meal-ordered) + **List Progress** widget (checked/total + ProgressView), hourly timeline + `WidgetCenter.reloadAllTimelines()` via `SnapshotWriter.refresh(context:)` (main-app target).
- `Intents/SmidgenIntents.swift`: 3 Shortcuts via AppIntents — **Add Recipe** (title + one-ingredient-per-line), **Start Timer** (logs a `StepTimer` onto a "Shortcut Timers" recipe AND returns the countdown dialog), **Add to List** (appends to most-recent list, creates "Shopping" if none). All offline-first SwiftData writes; sync picks them up via outbox. Phrases in `SmidgenShortcutsProvider`.
- `watch/WatchViews.swift`: `WatchRootView` tabs — **Steps** (check off from `smidgen.nowcooking.v1`), **Timers** (start/stop countdowns), **Lists** (progress from the shared snapshot). The phone writes `NowCookingPayload` when Cook mode starts a recipe.

## Validation (this machine, no Xcode project in repo)

- `swiftc -parse` on all 11 files: clean.
- `swiftc -typecheck` (macOS SDK): all library/export/widget/watch/intents sources typecheck with **zero errors** (one fix applied along the way: removed iOS-only `textInputAutocapitalization`; `AnyObject`-protocol alignment with Lane 2's `Syncable` precedent).
- `DuplicateFinderTests.swift`: `swiftc -parse` clean. Full `xctest` execution is **not possible with raw `swiftc` in this environment** (even a trivial `import XCTest` file fails the same way — the toolchain needs the xcodebuild test-bundle pipeline). Instead, **every assertion in the XCTest file is mirrored in a standalone harness** compiled against the real shipped sources (`LibrarySearch` + `DuplicateFinder` + `RecipeExporter` + `WidgetSnapshot`): **18/18 PASS** — all 3 seeded dupes caught, no false positives on distinct seeds, merge keeps best photo + unions ingredients, all filter dimensions, HTML escaping + single JSON-LD block, snapshot roundtrip + corrupt-tolerance.
- Export samples validated with Python `json` + string checks (see above).
- No auth/sync/Core changes: `git status` shows only Lane 5 paths (plus this README).

## Needed from other lanes (not done here — out of scope)

1. **App shell**: register `Cookbook.self` + `SavedSearch.self` in `SmidgenApp.modelTypes`; add a Library tab pointing at `LibraryHomeView`; route `smidgen://invite/<code>` in `onOpenURL`.
2. **Targets/entitlements**: widget extension target (includes `WidgetSnapshot.swift` + `SmidgenWidgets.swift`), watch target (includes `WidgetSnapshot.swift` + `WatchViews.swift`), App Group `group.com.smidgen.shared` on all three + main app.
3. **Cook mode (Lane 4)**: write `NowCookingPayload` via `WatchStore.writeNowCooking` when a recipe starts; call `SnapshotWriter.refresh(context:)` after plan/list edits.

## Not Yet (unfinished = removed, nothing dead shipped)

- Server-side household membership/invite redemption (`POST /households/:id/invites` + `POST /invites/redeem`) — invites are local + out-of-band only. Every button in `HouseholdInvitesView` works against that local model.
- Better Auth token on `ShareAPIClient` (Lane 1 dev store accepts owner role without it; documented in code, not hidden).
- Actual widget/watch screenshots — no `.xcodeproj` exists in the repo so nothing can be screenshotted here; see `Widgets/PREVIEW_NOTES.md` and `watch/PREVIEW_NOTES.md` for the exact preview configuration to capture them from.
- Cookbook cover art, drag-reorder of cookbook members, full-text stemming/stop-words (substring matching only).
- Export to Paprika/Mela formats (JSON/Markdown/Schema.org HTML only, per contract).
