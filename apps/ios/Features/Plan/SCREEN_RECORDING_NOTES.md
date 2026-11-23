# Lane 4 — Screen-recording notes (plan → list → check-off)

Record on iPhone (portrait) + iPad (landscape split) simulators, iOS 17+.
Goal: show the full offline-first loop in under 2 minutes, no narration gaps.

## Script (iPhone)

1. **Plan (0:00–0:35)** — Open Plan tab → span = Week.
   - Show a week with 2–3 entries (dinner Mon/Wed/Fri with servings).
   - Tap "Apply to week" on a reusable menu; week fills in.
   - Tap "Add week to list" → toast/sheet confirms "5 items added to Weekly shop".
2. **Shop (0:35–1:15)** — Open Lists tab → "Weekly shop".
   - Show items grouped/sorted by aisle (Produce → Dairy → …).
   - Check off 2 items (unchecked-first ordering keeps them visible at bottom).
   - Open Pantry → point out "Low" / "Expiring soon" flags; tap Scan → stub sheet → manual code entry.
3. **Cook (1:15–1:50)** — Open recipe → "Cook" → CookModeView.
   - Drag servings stepper 4 → 6; quantities flip to fractions (1½ cup).
   - Page through steps; mark step done; toggle an ingredient cross-off.
   - Timers section: show parsed timers ("bake 12-15 min" → 15 min) → "Start all timers".

## iPad pass (landscape, NavigationSplitView)

- Sidebar → Plan; content column shows week grid full-width.
- Detail column: CookModeView two-column layout (ingredients | steps).
- Show keep-screen-on: Control Center / note "screen stays awake in Cook mode".

## Webcal (optional overlay, no recording needed if Calendar unavailable in sim)

- Plan → "Subscribe in Calendar (webcal)" → Calendar subscribe sheet with
  `webcal://…/plans/feed.ics?householdId=…` prefilled. Screenshot suffices.

## Editing

- Captions for each beat; blur any personal household ids in URLs.
- Export 1080p; attach link to the Lane 4 PR.
