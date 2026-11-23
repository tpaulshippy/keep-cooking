# Widgets — Preview / Screenshot Notes

`SmidgenWidgets.swift` (TimelineProvider + two widgets) reads only the shared
`WidgetSnapshot.swift` payload — no SwiftData, no network.

## What to capture (2 widgets × 2 sizes)

1. **Today's Plan** (`.systemSmall`, `.systemMedium`) with preview data:
   breakfast `Blueberry Pancakes`, dinner `Weeknight Miso Salmon` (see
   `TodaySnapshot.preview`).
2. **List Progress** (`.systemSmall`, `.systemMedium`) with `Weekly shop 7/12`.

## How (once the widget extension target exists)

```swift
#Preview(as: .systemSmall) { TodayPlanWidget() } timeline: {
    SnapshotEntry(date: .now, snapshot: .preview)
}
#Preview(as: .systemMedium) { ListProgressWidget() } timeline: {
    SnapshotEntry(date: .now, snapshot: .preview)
}
```

Capture from the canvas (Snapshot) on iPhone 17 + iPad 13" simulators; save
to `apps/ios/Widgets/screenshots/` (git-ignored until the extension target
lands — the directory is intentionally absent from this commit).

Expected rendering: small = title + up to 3 meal rows / first list with
progress bar; medium = same plus second list. Empty states read
"No meals planned" / "No active lists" (never blank, never spinner).
A snapshot older than the last plan/list edit cannot occur — the app calls
`SnapshotWriter.refresh(context:)` after every plan/list mutation.

## Target membership reminder

Widget extension: `WidgetSnapshot.swift` + `SmidgenWidgets.swift` only.
Main app (for the writer): `WidgetSnapshot.swift` + the `SnapshotWriter`
section of `SmidgenWidgets.swift` (it is `#if canImport(SwiftData)`-gated).
App Group `group.com.smidgen.shared` required on both.
