# Intents — Notes

`SmidgenIntents.swift`: 3 Shortcuts via AppIntents (`SmidgenShortcutsProvider`).

| Intent | Phrase examples | Behavior (all offline-first) |
|---|---|---|
| Add Recipe | "Add miso salmon to Smidgen" | Creates recipe; each non-empty line of `ingredientsText` becomes an `Ingredient` row. Empty title throws a spoken message (no silent no-op). |
| Start Timer | "Start 10-minute pasta timer" | Validates 1–720 min; logs a `StepTimer` on a "Shortcut Timers" recipe step (visible in Cook mode) and returns the countdown dialog. |
| Add to List | "Add milk to my shopping list" | Appends to the most-recently-updated list; creates "Shopping" if none exists. Empty item throws a spoken message. |

All writes go through SwiftData directly; sync convergence happens via the
normal outbox on next sync — intents never touch `SyncEngine` or the network.
`IntentStore.container()` builds its own `ModelContainer`; if the app's
schema adds `Cookbook`/`SavedSearch` registration, this container picks them
up automatically (they are listed in the container call).
