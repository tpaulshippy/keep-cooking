# Keep Cooking — App Store Connect metadata (en-US, v1.0 draft)
# Store metadata skeleton ported from verseloop's appstore/metadata.md structure.
# Every keepcooking-unknown is marked TODO — fill before first submission.
# Bundle prefix: org.smidgen.app (see apps/ios/project.yml) · iOS 17.0+
# NOTE: Apple bundle IDs / App Group stay on the original App Store app's values
# (org.smidgen.app) intentionally to avoid re-provisioning; only the display
# name ("Keep Cooking", binary + on-device) and the store name
# ("Keep Cooking Recipes" — ASC uses the longer name because "Keep Cooking"
# was taken) change.

## URLs
- Privacy Policy URL: TODO — Keep Cooking privacy URL unknown (verseloop used a Worker-hosted /privacy page; expect a keepcooking.app-hosted page).
- Support URL: TODO — Keep Cooking support URL unknown (expect keepcooking.app or github.com/tpaulshippy/keep-cooking).
- Marketing URL (optional): TODO (verseloop used its GitHub repo URL — ours: github.com/tpaulshippy/keep-cooking).
- Data deletion info: TODO — Keep Cooking deletion story unknown (in-app location + whether server data is deleted/rotated).
- In-app privacy link: TODO — confirm Settings (or equivalent) links the privacy URL with no login required.

## App Information
- Name (30 chars max): "Keep Cooking Recipes" (20 chars, fits the 30-char limit). NOTE: ASC uses the longer store name because "Keep Cooking" was taken; the binary/display name stays "Keep Cooking".
- Subtitle (30 chars max): TODO — e.g. cookbook/recipe-scan positioning.
- Primary Category: TODO (verseloop: Education).
- Secondary Category: TODO (verseloop: Reference).
- Content Rights: TODO — cookbook-page scanning may involve third-party content (photographed/scanned text); confirm rights position and attribution, if any.

## Pricing & Availability
- Price: TODO (verseloop: Free).
- Availability: TODO — territories, if restricted. No in-app purchases: TODO (confirm).

## Version 1.0 — App Store Listing (en-US)

### Promotional Text (170 chars, editable without review)
TODO — Keep Cooking listing copy unknown.

### Description (4000 chars)
TODO — Keep Cooking listing copy unknown. Cover: what the app does (cookbook-page
scan → recipes?), offline behavior, account/sync story, data/export story.

### Keywords (100 chars, comma-separated, no spaces needed)
TODO — Keep Cooking keywords unknown (e.g. recipes,cookbook,scan,... — confirm within 100-char limit).

### Screenshots (6.9" + iPad spec)
- Required set: iPhone 6.9" class — 1290×2796 portrait PNG (accepted: 1320×2868 / 1290×2796 / 1260×2736). Apple auto-scales to smaller iPhone classes.
- iPad: TODO — confirm whether Keep Cooking is iPhone-only (no iPad screenshots, like verseloop) or Universal (then iPad 13" screenshots required). Check TARGETED_DEVICE_FAMILY / UIDeviceFamily before submission.
- Files: TODO — place final framed shots under apps/ios/screenshots/ (dir exists; confirm exact filenames + 6-frame shot list once UI is frozen).
  1. TODO
  2. TODO
  3. TODO
  4. TODO
  5. TODO
  6. TODO
- App Preview video: TODO — optional, skipped for v1.0 unless decided otherwise.

### Age Rating (TODO — confirm rating)
- Questionnaire answers TODO. Inputs to verify: camera/photo-library use (cookbook scan),
  user-generated content position (see below), messaging/sharing, web views, gambling, contests.
- TODO — run Apple's age-rating questionnaire in App Store Connect and record answers here.

### App Privacy (Nutrition Label) — TODO
- Data Collection: TODO — confirm (camera images? scanned text? sync payloads? analytics? crash reports?).
- Tracking: TODO — confirm (IDFA/ATT usage; NSPrivacyTracking value).
- Privacy manifest: TODO — confirm apps/ios privacy manifest filename + NSPrivacyCollectedDataTypes / accessed-API reasons (verseloop shipped a PrivacyInfo.xcprivacy with UserDefaults CA92.1 only).
- Required-reason APIs used: TODO — enumerate (camera? photo library? UserDefaults? file timestamps?).

### Export Compliance
- ITSAppUsesNonExemptEncryption=false (apps/ios/Config/Info-App.plist already sets
  ITSAppUsesNonExemptEncryption to false). TODO — confirm this stays accurate: app must
  use only iOS-standard exempt encryption (HTTPS + Apple CryptoKit, if any). No proprietary
  crypto, no CCATS required — re-verify if any custom crypto is added.

## App Review Notes (for reviewer)
- No login needed: TODO — confirm app opens without login; describe first-run state (verseloop opened to demo verses).
- Device-key gate (was: beta-token gate — removed, no token enrollment):
  TODO — Keep Cooking review build behavior behind the device-key gate unknown.
  Document the gate for the reviewer: there is no shared-secret bearer gate —
  reads plus `POST /v2/devices` (enrollment) stay open, every other write must
  carry `x-device-id` / `x-device-ts` / `x-device-sig` from an enrolled Ed25519
  key (see api/README.md Auth). Record which enrolled device/key the review
  build uses, how to re-enroll, and which features are gated vs open. Client
  Beta UI (in-app enroll / revoke) is deferred — enrollment is API-side for now.
- UGC position: TODO — Keep Cooking handles user-supplied content (scanned cookbook pages, recipes,
  photos?). State the position: is content private to the device/user, is there any sharing/
  public display, moderation/reporting/blocking mechanisms if user content is shared between users.
- Camera/photo flows: TODO — describe scan flow (NSCameraUsageDescription: "Take a photo of a
  cookbook page to scan its text."; NSPhotoLibraryUsageDescription covers picker) so the
  reviewer knows what to exercise.
- Sync/backend: TODO — document SMIDGEN_API_BASE_URL used by the review build (default in
  apps/ios/project.yml is https://keep-cooking-api.pshippy-245.workers.dev;
  confirm reviewer-reachable backend, demo account if needed).
- Privacy Policy in-app location: TODO (must be reachable with no login).
- Contact: TODO — support/issues URL for reviewer follow-ups.

## Version / Build
- Marketing version: TODO — confirm CFBundleShortVersionString (apps/ios/Config/Info-App.plist currently 1.0).
- Build: TODO — confirm numbering scheme (verseloop stamped CURRENT_PROJECT_VERSION from
  CI_BUILD_NUMBER via ci_pre_xcodebuild.sh; the app has no apps/ios/ci_scripts yet — decide
  scheme before first cloud upload; Apple rejects re-uploaded build numbers).
- Deployment target: iOS 17.0 (per apps/ios/project.yml; watchOS 10.0 target also exists — TODO confirm watch/Widgets ship in v1.0 or are excluded).

## Release
- Release type: Manual release (hold for developer release after approval).
- Phased release: off for v1.0 (no phased release).
