# Keep Cooking — Android

Native Android app with full parity to `apps/ios/`. Package `com.keepcooking.app`,
single-activity + Compose Navigation, Material3, offline-first Room store.

## Structure

```
apps/android/
├── settings.gradle.kts / build.gradle.kts / gradle.properties
├── app/build.gradle.kts            # minSdk 26, targetSdk 34, Compose BOM, Material3,
│                                   # Navigation-Compose, Room, DataStore, Retrofit/OkHttp,
│                                   # Coil, JUnit4 + Compose UI test
└── app/src/main/
    ├── AndroidManifest.xml
    ├── assets/seed/                # 15 seed recipes copied from apps/ios/Seed/
    └── java/com/keepcooking/app/
        ├── MainActivity.kt         # single-activity shell (cf. AdaptiveShell)
        ├── KeepCookingApp.kt       # Application (cf. KeepCookingApp.swift)
        ├── AppContainer.kt         # Room + DataStore + SyncEngine wiring (cf. SyncCoordinator)
        ├── navigation/NavGraph.kt  # 5 tabs: Library / Ingest / Cook / Plan / Shop
        ├── data/Models.kt          # Room entities ported from Core/Models.swift
        ├── data/Daos.kt            # Room DAOs
        ├── data/AppDatabase.kt     # Room database (cf. SwiftData container)
        ├── data/SeedLoader.kt      # one-shot assets/seed load (cf. iOS SeedLoader)
        ├── network/ApiService.kt   # Retrofit transport (cf. APISyncTransport)
        ├── sync/SyncEngine.kt      # outbox LWW + tombstones (cf. SyncEngine.swift)
        ├── export/RecipeExporter.kt# Markdown export (cf. apps/ios/Export/)
        └── ui/theme/ + ui/screens/ # Material3 theme + 5 tab placeholders
```

## Build

Requires Android Studio Hedgehog+ (AGP 8.3, JDK 17) and an Android SDK with
`platforms;android-34` + build-tools.

```bash
cd apps/android
./gradlew :app:assembleDebug        # pinned wrapper → Gradle 8.7, no system Gradle needed
./gradlew :app:testDebugUnitTest   # JUnit4 unit tests (sync LWW contract)
./gradlew :app:connectedDebugAndroidTest  # Compose UI tests (needs emulator/device)
```

CLI builds must run on JDK 17 (`JAVA_HOME` → a 17 install); newer JDKs break
the Kotlin 1.9 / KSP 1.x daemon. Covered in CI by `android-check.yml`.

No `local.properties` is checked in — set `sdk.dir` / `ANDROID_HOME` locally.

## Sync contract

Same as iOS: `id · updatedAt (ISO8601) · deviceId · deleted` tombstone on every
top-level entity, last-write-wins on `updatedAt`, ties break toward remote.
Local Room is the source of truth; `SyncEngine.sync()` pulls + LWW-applies
remote winners (a pending outbox edit shadows stale remotes), advances the
pull cursor by ENVELOPE time, then pushes what remains. Server-won conflict
envelopes apply via LWW and leave the outbox. Settings from DataStore: base
URL (defaults to the production Workers URL unless overridden in Settings → Advanced), user id.

## E2E (v1, blind-server /v2/sync/:hash)

Sealed envelopes (AES-GCM-256, HKDF-SHA256 key from the invite syncCode)
sync through `SyncEngine.syncE2E`; see `sync/SyncCrypto.kt` for the locked
interfaces (key derivation, header AD binding, kid, household hash).

> **Production gate — plaintext secret store.** The syncCode currently lives
> in a dedicated plaintext Preferences DataStore file
> (`keepcooking_e2e_secret`), split from the non-secret metadata. Before E2E
> is enabled for real households, the syncCode MUST move to `EncryptedFile`
> (Tink/Keystore-backed) or the Android Keystore — no Keystore dependency is
> added in this pass on purpose. Tracked by `TODO(security)` on `E2EKeyStore`
> in `sync/SyncCrypto.kt`; do not ship E2E onboarding until it is resolved.
