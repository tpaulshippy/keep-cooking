# Watch — Preview / Screenshot Notes

`WatchViews.swift` (watchOS): `WatchRootView` tabs — Steps, Timers, Lists.
Data comes only from the shared App Group: `TodaySnapshot` (lists) and
`NowCookingPayload` (`smidgen.nowcooking.v1`, written by the phone when Cook
mode starts a recipe). No SwiftData, no network on-watch.

## What to capture (Apple Watch 45mm + 49mm)

1. **Steps**: seed a payload and screenshot mid-cook —
   `WatchStore.writeNowCooking(NowCookingPayload(recipeId: "demo",
   title: "Weeknight Miso Salmon",
   steps: [.init(position: 0, text: "Heat oven to 220C."),
            .init(position: 1, text: "Glaze salmon with miso.")],
   timers: [.init(label: "Roast", seconds: 600)]))`.
   First step checked off (shows strikethrough + filled checkmark).
2. **Timers**: `Roast 10:00` row with Start/Stop; screenshot mid-countdown.
3. **Lists**: `Weekly shop 7 of 12 done` with progress bar (from
   `TodaySnapshot.preview`).

## How (once the watch target exists)

```swift
#Preview { WatchStepsView() }   // + write the demo payload in a preview task
#Preview { WatchTimersView() }
#Preview { WatchListView() }
```

Capture from the canvas on 45mm + 49mm; save to
`apps/ios/watch/screenshots/` (git-ignored until the watch target lands —
the directory is intentionally absent from this commit).

Empty states (all reachable offline): "No recipe — Start cooking on iPhone
to see steps here.", "No timers", "No lists". Countdown uses
`Task.sleep` + MainActor ticks; stopping cancels via the `running` set —
no runaway background work.
