# Intents — Notes

`KeepCookingIntents.swift`: 8 Shortcuts via AppIntents (`KeepCookingShortcuts`).

| Intent | Phrase examples | Behavior (all offline-first) |
|---|---|---|
| Add Recipe | "Add miso salmon to Keep Cooking" | Creates recipe; each non-empty line of `ingredientsText` becomes an `Ingredient` row. Empty title throws a spoken message (no silent no-op). |
| Start Timer | "Start 10-minute pasta timer" | Validates 1–720 min; logs a `StepTimer` on a "Shortcut Timers" recipe step (visible in Cook mode) and returns the countdown dialog. |
| Add to List | "Add milk to my shopping list" | Appends to the most-recently-updated list; creates "Shopping" if none exists. Empty item throws a spoken message. |
| Next Step | "Next step with Keep Cooking" | Stateless: opens the app (`openAppWhenRun=true`), returns "Next step." dialog; the live session advances in-app via the voice manager. Limitation: requires the app frontmost for the live session; Siri path is not continuous listening. |
| Previous Step | "Previous step with Keep Cooking" | Stateless: opens the app, returns "Previous step." dialog; the live session moves back in-app. Limitation: requires the app frontmost for the live session; Siri path is not continuous listening. |
| Repeat Step | "Repeat step with Keep Cooking" / "Read current step" | Stateless: opens the app, returns "Repeating this step." dialog; the live session re-reads the current step in-app. Limitation: requires the app frontmost for the live session; Siri path is not continuous listening. |
| Cross Off Ingredient | "Cross off basil with Keep Cooking" | Fuzzy-matches `ingredient` against the most-recent recipes, returns a confirming dialog, and opens the app where in-app voice completes the toggle (intent does not toggle live session state). Limitation: requires the app frontmost for the live session; Siri path is not continuous listening. |
| Start Cook Timer | "Start cook timer with Keep Cooking" | Same "Shortcut Timers" `StepTimer` logging as Start Timer (1–720 min, offline, `openAppWhenRun=false`); does not drive the live CookSession. Limitation: Siri path is not continuous listening. |

All writes go through SwiftData directly; sync convergence happens via the
normal outbox on next sync — intents never touch `SyncEngine` or the network.
`IntentStore.container()` builds its own `ModelContainer`; if the app's
schema adds `Cookbook`/`SavedSearch` registration, this container picks them
up automatically (they are listed in the container call).
