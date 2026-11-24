# SYNC_TEST.md — Lane 2 iOS Foundation

How offline-first sync is verified. All logic lives in
`apps/ios/Sync/SyncEngine.swift`; tests in `apps/ios/Sync/SyncEngineTests.swift`
run with no SwiftData, no network, no CloudKit (in-memory `FakeServer`
stand-in for Lane 1 `GET /sync/pull` + `POST /sync/push`).

Contract under test (from `schema.sql` + `openapi.yaml`):
- Envelope: `{ id, updatedAt, deviceId, deleted, entity, payload }`
- Last-write-wins on `updatedAt`. Tombstones (`deleted: true`) are ordinary
  writes — a newer tombstone deletes, an older one loses.
- Equal timestamps break **toward remote** so any two devices converge
  deterministically regardless of sync order.

## 1. Collision matrix

| # | Local state | Remote envelope | Expected | Reason |
|---|-------------|-----------------|----------|--------|
| 1 | t0, live | t+5, live | takeRemote | remote newer |
| 2 | t+5, live | t0, live | keepLocal (push) | local newer |
| 3 | t0, live, dev A | t0, live, dev A | identical (no-op) | same write echoed back |
| 4 | t0, live, dev A | t0, live, dev B | takeRemote | tie → remote wins (deterministic) |
| 5 | t0, live | t+5, **deleted** | takeRemote (delete) | newer tombstone deletes |
| 6 | t+5, live | t0, **deleted** | keepLocal (push) | older tombstone loses |
| 7 | t0, **deleted** | t+5, live | takeRemote (resurrect) | live write after tombstone wins |

Covered by `CollisionMatrixTests.testMatrix` (one assertion per row).

## 2. Two-device convergence log (expected)

`TwoDeviceConvergenceTests.testTwoDevicesConvergeAfterOfflineEdits`:

1. Seed `r1@t0` on server. A syncs, B syncs → both at `t0`.
2. Airplane mode. A edits → `r1@t+10/dev-a` (outbox). B edits → `r1@t+20/dev-b` (outbox).
3. A syncs: pull ∅ new, push `t+10` accepted → server `t+10/dev-a`.
4. B syncs: pull `t+10/dev-a` vs local `t+20/dev-b` → `keepLocal`; push `t+20` accepted (server older) → server `t+20/dev-b`, `pushed == 1`.
5. A syncs: pull `t+20/dev-b` vs baseline `t+10/dev-a` → `takeRemote`, `applyRemote` fires once with `deviceId == device-b`.
6. Final: server `t+20/dev-b`; both outboxes empty. **Converged.**

`testDeleteTombstoneBeatsOlderLiveRecord`: local delete at `t+30` pushes cleanly and reads back `deleted == true`.

## 3. Photo dedup log (expected)

- `testIdenticalBytesShareOneKey`: first `photoKey(bytes)` → `photos/<sha256>.jpg`; second call with identical bytes → `nil` (reuse).
- `testDifferentBytesGetDifferentKeys`: distinct bytes → distinct keys.

## 4. How to run

```bash
# Parse-check (no Xcode project yet — Lane 2 ships loose sources):
swiftc -frontend -parse apps/ios/Core/Models.swift       # etc.

# Full typecheck against the iOS SDK (Xcode 16 toolchain, zero errors/warnings):
SDK=$(xcrun --show-sdk-path --sdk iphonesimulator)
swiftc -typecheck -sdk "$SDK" -target arm64-apple-ios17.0-simulator \
  apps/ios/Core/Models.swift apps/ios/Core/SeedLoader.swift \
  apps/ios/Sync/SyncEngine.swift apps/ios/App/KeepCookingApp.swift

# Tests typecheck via xcodebuild once the target exists. CLI note: raw
# swiftc cannot import XCTest's function-like macros (XCTAssertEqual…), so
# the test file was additionally verified with a minimal XCTestCase shim —
# clean. In Xcode no shim is needed.
```

Validated 2026-11-23: all 4 prod files typecheck clean (Swift 5 mode,
no warnings); tests clean under shim.

## 5. Offline demo notes (airplane mode)

1. Fresh install → `SyncCoordinator.seedIfNeeded` loads the 15 frozen
   contract seeds (`packages/contracts/seed/recipe-*.json`) into SwiftData.
2. Enable airplane mode, kill the app, relaunch → Recipes tab still lists
   all seeds (local store is source of truth; no network on main thread —
   views only ever `await SyncCoordinator.shared.sync()`).
3. Pull-to-refresh while offline is a logged no-op (`"offline — no
   transport configured yet"`) until Lane 1 publishes the API base URL;
   then `sync()` pulls/pushes envelopes and the More tab shows counts.

## 6. Gaps / follow-ups (not Lane 2)

- No Xcode project/target yet — tests are written but not yet runnable in CI.
- `APISyncTransport` untested (needs URLProtocol stubbing).
- CloudKit mirror is a stub (`CloudKitMirrorStub.mirror` logs count only).
- Child-row merge (ingredient/step reordering conflicts) defers to parent
  recipe envelope; field-level merge is out of scope.
- Photo upload bytes path (R2 presigned PUT) not wired — only key dedup.
