# Intents — Notes

`KeepCookingIntents.swift`: 8 Shortcuts via AppIntents (`KeepCookingShortcuts`).

| Intent | Phrase examples | Behavior (all offline-first) |
|---|---|---|
| Add Recipe | "Add miso salmon to Keep Cooking" | Creates recipe; each non-empty line of `ingredientsText` becomes an `Ingredient` row. Empty title throws a spoken message (no silent no-op). |
| Start Timer | "Start 10-minute pasta timer" | Validates 1–720 min; logs a `StepTimer` on a "Shortcut Timers" recipe step (visible in Cook mode) and returns the countdown dialog. |
| Add to List | "Add milk to my shopping list" | Appends to the most-recently-updated list; creates "Shopping" if none exists. Empty item throws a spoken message. |
| Next Step | "Next step with Keep Cooking" | Writes `cook.pendingCommand="next"` to the shared App Group (`group.com.smidgen.share`) and opens the app, where the live session consumes + clears it. Honest dialog: "Opening Keep Cooking to go to the next step." Limitation: requires the app frontmost for the live session; Siri path is not continuous listening. |
| Previous Step | "Previous step with Keep Cooking" | Writes `cook.pendingCommand="previous"` and opens the app; the live session moves back in-app. Honest dialog: "Opening Keep Cooking to go back a step." Limitation: requires the app frontmost for the live session; Siri path is not continuous listening. |
| Repeat Step | "Repeat step with Keep Cooking" / "Read current step" | Writes `cook.pendingCommand="repeat"` and opens the app; the live session re-reads the current step in-app. Honest dialog: "Opening Keep Cooking to repeat this step." Limitation: requires the app frontmost for the live session; Siri path is not continuous listening. |
| Cross Off Ingredient | "Cross off basil with Keep Cooking" | Fuzzy-matches `ingredient` against non-deleted ingredients in the most-recent recipes via the shared `ingredientId(matching:in:)` / `fuzzyVoiceMatch` resolution; on a hit writes `cook.pendingCommand="crossoff:<normalized-name>"` and opens the app where in-app voice completes the toggle (dialog: "Opening Keep Cooking to cross off <name>."). Unknown names throw "I don't see <name> in your recent recipes." — never reports success without action. Limitation: requires the app frontmost for the live session; Siri path is not continuous listening. |
| Start Cook Timer | "Start cook timer with Keep Cooking" | Same "Shortcut Timers" `StepTimer` logging as Start Timer (1–720 min, offline, `openAppWhenRun=false`) AND schedules a real local notification (`UNTimeIntervalNotificationTrigger`, mirroring `CookActivityStub.schedule`); dialog "Timer set for N minutes: <label>." is now truthful. Does not drive the live CookSession. Limitation: Siri path is not continuous listening. |

All writes go through SwiftData directly; sync convergence happens via the
normal outbox on next sync — intents never touch `SyncEngine` or the network.
`IntentStore.container()` builds its own `ModelContainer`; if the app's
schema adds `Cookbook`/`SavedSearch` registration, this container picks them
up automatically (they are listed in the container call).
