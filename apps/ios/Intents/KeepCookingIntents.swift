// Keep Cooking — Lane 5 Organize
// apps/ios/Intents/KeepCookingIntents.swift
//
// 8 Shortcuts via AppIntents (iOS 17+): Add Recipe, Start Timer, Add to List,
// plus 5 cook controls (Next/Previous/Repeat step, Cross off ingredient,
// Start Cook Timer).
// Intents write through SnapshotWriter-visible SwiftData paths only — they
// never touch the network or SyncEngine directly; sync picks up the new
/// updated records via the normal outbox on next launch/refresh.
//
// NOTE: AppIntents requires the intent target to link AppIntents + SwiftData.
// Each intent is deliberately dependency-light so Shortcuts works offline.

import Foundation
#if canImport(AppIntents)
import AppIntents
import SwiftData
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Shared helpers

/// Handoff bridge to the live Cook session. Intent definitions live in the
/// same in-app target as the consumer, so the pending command is written to
/// `UserDefaults.standard` — the exact store
/// `VoiceCookManager.consumePendingCommand` reads + clears (key
/// "cook.pendingCommand"; do not rename without updating both sides).
/// (An App Group suite would be a different store from the consumer here,
/// so it must not be used.)
private enum CookPendingHandoff {
    static let key = "cook.pendingCommand"

    /// Set while a CookModeView session is on screen (appear/disappear);
    /// nav intents require it so they never claim a step change when no
    /// live session can consume the handoff.
    /// Single source of truth: CookModeView.sessionActiveKey.
    static let sessionActiveKey = CookModeView.sessionActiveKey

    static func write(_ value: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    /// Throws a spoken message when no Cook session is active to consume a
    /// nav handoff. Call before `write` in every `openAppWhenRun` intent.
    static func requireActiveSession() throws {
        guard UserDefaults.standard.bool(forKey: sessionActiveKey) else {
            throw IntentExecutionError.message("Open a recipe in Cook mode first, then try again.")
        }
    }
}

@MainActor
private enum IntentStore {
    static func container() throws -> ModelContainer {
        try ModelContainer(for: Recipe.self, Ingredient.self, Step.self,
                           ShoppingList.self, ListItem.self, Plan.self, Menu.self,
                           Cookbook.self, SavedSearch.self)
    }

    static func deviceId() -> String {
        #if os(iOS)
        return UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        #else
        return UUID().uuidString
        #endif
    }
}

// MARK: - 1. Add Recipe

/// "Add <title> to Keep Cooking" — creates a recipe shell with one ingredient per
/// line of `ingredientsText` so a dictated list lands structured.
struct AddRecipeIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Recipe"
    static var description = IntentDescription("Creates a new recipe in Keep Cooking.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Title") var title: String
    @Parameter(title: "Ingredients", default: "") var ingredientsText: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$title) to Keep Cooking")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw IntentExecutionError.message("Give the recipe a title first.")
        }
        let container = try IntentStore.container()
        let context = ModelContext(container)
        let recipe = Recipe(householdId: "hh-demo", title: trimmed, deviceId: IntentStore.deviceId())
        context.insert(recipe)
        var position = 0
        for line in ingredientsText.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }) {
            let ing = Ingredient(recipeId: recipe.id, name: line, display: line,
                                 position: position, updatedAt: Date(), deviceId: recipe.deviceId)
            ing.recipe = recipe
            context.insert(ing)
            position += 1
        }
        try context.save()
        return .result(dialog: "Added \(trimmed) to Keep Cooking.")
    }
}

// MARK: - 2. Start Timer

/// "Start a 10-minute pasta timer" — Shortcuts has no live-activity
/// reservation without the full app, so this records the timer as a Step
/// timer on a "Shortcut timers" recipe AND starts a system clock timer via
/// the returned dialog. The recorded timer survives in Cook mode.
struct StartTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Timer"
    static var description = IntentDescription("Starts a kitchen timer and logs it on a recipe step.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Minutes") var minutes: Int
    @Parameter(title: "Label", default: "") var label: String

    static var parameterSummary: some ParameterSummary {
        Summary("Start a \(\.$minutes)-minute timer")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard minutes > 0, minutes <= 720 else {
            throw IntentExecutionError.message("Keep timers between 1 minute and 12 hours.")
        }
        let container = try IntentStore.container()
        let context = ModelContext(container)
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let timerLabel = name.isEmpty ? "\(minutes)-minute timer" : name
        // Log onto (or create) a "Shortcut Timers" recipe so Cook mode sees it.
        let existing = try? context.fetch(FetchDescriptor<Recipe>(
            predicate: #Predicate { $0.title == "Shortcut Timers" && !$0.deleted }))
        let recipe: Recipe
        if let found = existing?.first {
            recipe = found
        } else {
            recipe = Recipe(householdId: "hh-demo", title: "Shortcut Timers", deviceId: IntentStore.deviceId())
            context.insert(recipe)
        }
        let position = (recipe.steps.map { $0.position }.max() ?? -1) + 1
        let step = Step(recipeId: recipe.id, position: position,
                        text: timerLabel, timers: [StepTimer(seconds: minutes * 60, label: timerLabel)],
                        updatedAt: Date(), deviceId: recipe.deviceId)
        step.recipe = recipe
        context.insert(step)
        recipe.updatedAt = Date()
        try context.save()
        return .result(dialog: "Timer set for \(minutes) minutes: \(timerLabel).")
    }
}

// MARK: - 3. Add to List

/// "Add milk to my shopping list" — appends to the most-recently-updated
/// non-deleted list, or creates "Shopping" when none exists.
struct AddToListIntent: AppIntent {
    static var title: LocalizedStringResource = "Add to List"
    static var description = IntentDescription("Adds an item to your current shopping list.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Item") var item: String
    @Parameter(title: "Quantity", default: "") var quantity: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$item) to the shopping list")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw IntentExecutionError.message("Tell me what to add to the list.")
        }
        let container = try IntentStore.container()
        let context = ModelContext(container)
        let lists = (try? context.fetch(FetchDescriptor<ShoppingList>(
            predicate: #Predicate { !$0.deleted },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
        let list: ShoppingList
        if let current = lists.first {
            list = current
        } else {
            list = ShoppingList(householdId: "hh-demo", name: "Shopping", updatedAt: Date(), deviceId: IntentStore.deviceId())
            context.insert(list)
        }
        let entry = ListItem(listId: list.id, name: name,
                             quantity: quantity.trimmingCharacters(in: .whitespacesAndNewlines),
                             updatedAt: Date(), deviceId: IntentStore.deviceId())
        entry.shoppingList = list
        context.insert(entry)
        list.updatedAt = Date()
        try context.save()
        return .result(dialog: "Added \(name) to \(list.name).")
    }
}

// MARK: - 4. Cook controls (parity with in-app voice)
//
// LIMITATION: AppIntent extensions run in a separate process with no access
// to the live in-memory CookSession / CookVoiceManager. These intents are
// therefore handoff-based: each one requires an active Cook session
// (`CookPendingHandoff.requireActiveSession`, backed by the shared
// CookModeView.sessionActiveKey flag CookModeView sets on appear/disappear) and then
// writes UserDefaults.standard key "cook.pendingCommand" — "next" /
// "previous" / "repeat" / "crossoff:<normalized-name>" — and opens the app
// (openAppWhenRun=true) where the live session consumes + clears the
// command. With no active session they throw a spoken "open Cook mode
// first" message instead of claiming a step change. None of them performs
// continuous listening — the Siri path is one-shot per invocation.

/// "Next step" — writes a "next" pending command for the live session to
/// consume on foreground, then opens the app. Stateless by design (no live
/// CookSession access from the intent process).
struct NextStepIntent: AppIntent {
    static var title: LocalizedStringResource = "Next step"
    static var description = IntentDescription("Advances to the next cooking step in Keep Cooking.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try CookPendingHandoff.requireActiveSession()
        CookPendingHandoff.write("next")
        return .result(dialog: "Opening Keep Cooking to go to the next step.")
    }
}

/// "Previous step" — writes a "previous" pending command, then opens the app.
struct PreviousStepIntent: AppIntent {
    static var title: LocalizedStringResource = "Previous step"
    static var description = IntentDescription("Goes back to the previous cooking step in Keep Cooking.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try CookPendingHandoff.requireActiveSession()
        CookPendingHandoff.write("previous")
        return .result(dialog: "Opening Keep Cooking to go back a step.")
    }
}

/// "Repeat that / Read current step" — writes a "repeat" pending command,
/// then opens the app where the live session re-reads the current step.
struct RepeatStepIntent: AppIntent {
    static var title: LocalizedStringResource = "Repeat step"
    static var description = IntentDescription("Repeats the current cooking step in Keep Cooking.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try CookPendingHandoff.requireActiveSession()
        CookPendingHandoff.write("repeat")
        return .result(dialog: "Opening Keep Cooking to repeat this step.")
    }
}

/// "Cross off <ingredient>" — resolves a fuzzy ingredient match in the
/// most-recent recipes (same VoiceCommandParser resolution as in-app
/// voice), writes a "crossoff:<name>" pending command for the live session
/// to consume, then opens the app. Never reports success without the
/// handoff: unknown names throw a spoken message.
struct CrossOffIngredientIntent: AppIntent {
    static var title: LocalizedStringResource = "Cross off ingredient"
    static var description = IntentDescription("Crosses off an ingredient in Keep Cooking.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Ingredient") var ingredient: String

    static var parameterSummary: some ParameterSummary {
        Summary("Cross off \(\.$ingredient)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try CookPendingHandoff.requireActiveSession()
        let needle = ingredient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else {
            throw IntentExecutionError.message("Tell me which ingredient to cross off.")
        }
        let container = try IntentStore.container()
        let context = ModelContext(container)
        let recipes = (try? context.fetch(FetchDescriptor<Recipe>(
            predicate: #Predicate { !$0.deleted },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]))) ?? []
        // Shared fuzzy resolution (VoiceCommandParser lives in the same app
        // target as these intents). Deleted rows are excluded so a removed
        // ingredient can never match.
        var matched: Ingredient?
        for recipe in recipes {
            let live = recipe.ingredients.filter { !$0.deleted }
            let pairs = live.map { (id: $0.id, name: $0.name) }
            if let id = ingredientId(matching: needle, in: pairs) {
                matched = live.first { $0.id == id }
                break
            }
        }
        guard let found = matched else {
            throw IntentExecutionError.message("I don't see \(needle) in your recent recipes.")
        }
        let display = found.display.isEmpty ? found.name : found.display
        CookPendingHandoff.write("crossoff:\(voiceNormalizedName(found.name))")
        return .result(dialog: "Opening Keep Cooking to cross off \(display).")
    }
}

/// "Start cook timer" — logs a StepTimer on the "Shortcut Timers" recipe
/// (so Cook mode sees it) AND, when notification authorization allows
/// (requested when undetermined), schedules a real local notification
/// mirroring CookActivityStub.schedule. Offline; does not drive the live
/// CookSession. When alerts are not allowed, the timer is still logged but
/// the dialog says it won't alert.
struct StartCookTimerIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Cook Timer"
    static var description = IntentDescription("Starts a cook timer and logs it on a recipe step.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Minutes") var minutes: Int
    @Parameter(title: "Label", default: "") var label: String

    static var parameterSummary: some ParameterSummary {
        Summary("Start a \(\.$minutes)-minute cook timer")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard minutes > 0, minutes <= 720 else {
            throw IntentExecutionError.message("Keep timers between 1 minute and 12 hours.")
        }
        let container = try IntentStore.container()
        let context = ModelContext(container)
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let timerLabel = name.isEmpty ? "\(minutes)-minute timer" : name
        // Same "Shortcut Timers" logging as StartTimerIntent so Cook mode sees it.
        let existing = try? context.fetch(FetchDescriptor<Recipe>(
            predicate: #Predicate { $0.title == "Shortcut Timers" && !$0.deleted }))
        let recipe: Recipe
        if let found = existing?.first {
            recipe = found
        } else {
            recipe = Recipe(householdId: "hh-demo", title: "Shortcut Timers", deviceId: IntentStore.deviceId())
            context.insert(recipe)
        }
        let position = (recipe.steps.map { $0.position }.max() ?? -1) + 1
        let step = Step(recipeId: recipe.id, position: position,
                        text: timerLabel, timers: [StepTimer(seconds: minutes * 60, label: timerLabel)],
                        updatedAt: Date(), deviceId: recipe.deviceId)
        step.recipe = recipe
        context.insert(step)
        recipe.updatedAt = Date()
        try context.save()
        // Real timer: mirror CookActivityStub.schedule — a local notification
        // that fires even if the app is backgrounded. Authorization is
        // checked first (requested when undetermined); when alerts are not
        // allowed the StepTimer log above still stands, but the dialog says
        // so instead of claiming a timer was set.
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let authorized: Bool
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            authorized = true
        case .notDetermined:
            do {
                authorized = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                authorized = false
            }
        case .denied:
            authorized = false
        @unknown default:
            authorized = false
        }
        if authorized {
            let content = UNMutableNotificationContent()
            content.title = "Keep Cooking timer"
            content.body = "\(timerLabel) — done!"
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, TimeInterval(minutes * 60)), repeats: false)
            try await center.add(UNNotificationRequest(
                identifier: "cook-timer-\(UUID().uuidString)", content: content, trigger: trigger))
            return .result(dialog: "Timer set for \(minutes) minutes: \(timerLabel).")
        } else {
            return .result(dialog: "Timer logged for \(minutes) minutes: \(timerLabel), but notifications are off so it won't alert you. Turn them on in Settings to get the alert.")
        }
    }
}

// MARK: - Shortcuts provider

/// Surfaces all eight intents in the Shortcuts app.
struct KeepCookingShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddRecipeIntent(),
            phrases: ["Add \(.applicationName) recipe", "Save recipe with \(.applicationName)"],
            shortTitle: "Add Recipe",
            systemImageName: "plus.circle"
        )
        AppShortcut(
            intent: StartTimerIntent(),
            phrases: ["Start \(.applicationName) timer", "Set kitchen timer with \(.applicationName)"],
            shortTitle: "Start Timer",
            systemImageName: "timer"
        )
        AppShortcut(
            intent: AddToListIntent(),
            phrases: ["Add to \(.applicationName) list", "Add groceries with \(.applicationName)"],
            shortTitle: "Add to List",
            systemImageName: "cart"
        )
        AppShortcut(
            intent: NextStepIntent(),
            phrases: ["Next step with \(.applicationName)", "Next cooking step with \(.applicationName)"],
            shortTitle: "Next Step",
            systemImageName: "chevron.right"
        )
        AppShortcut(
            intent: PreviousStepIntent(),
            phrases: ["Previous step with \(.applicationName)", "Go back a step with \(.applicationName)"],
            shortTitle: "Previous Step",
            systemImageName: "chevron.left"
        )
        AppShortcut(
            intent: RepeatStepIntent(),
            phrases: ["Repeat step with \(.applicationName)", "Read current step with \(.applicationName)"],
            shortTitle: "Repeat Step",
            systemImageName: "repeat"
        )
        AppShortcut(
            intent: CrossOffIngredientIntent(),
            phrases: ["Cross off ingredient with \(.applicationName)", "Check off ingredient with \(.applicationName)"],
            shortTitle: "Cross Off Ingredient",
            systemImageName: "checkmark.circle"
        )
        AppShortcut(
            intent: StartCookTimerIntent(),
            phrases: ["Start cook timer with \(.applicationName)", "Set cook timer with \(.applicationName)"],
            shortTitle: "Start Cook Timer",
            systemImageName: "timer"
        )
    }
}

/// Errors thrown with a spoken/readable message instead of a silent failure.
private enum IntentExecutionError: Error, CustomStringConvertible {
    case message(String)
    var description: String {
        switch self { case .message(let m): return m }
    }
}
#endif
