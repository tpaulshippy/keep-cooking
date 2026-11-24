// Keep Cooking — Lane 4 Cook: session state + background stub (no persistence layer)
// Consumes Core/Models.swift + SyncEngine; adds no new persistence.
//   - CookSession: @Observable step pager state (index, crossed-off steps,
//     per-ingredient cross-off, active timers). Pure Swift, testable.
//   - KeepAwake: keep-screen-on helper (UIApplication.isIdleTimerDisabled)
//     — call `KeepAwake.enable()` on appear, `.disable()` on disappear.
//   - CookActivityStub: Live Activity + local-notification seam. Today this
//     schedules real UNUserNotificationCenter alerts for timers (works in
//     background); the Live Activity half is a logged no-op stub awaiting
//     an ActivityKit widget target (Lane 5+).

import Foundation
import UserNotifications

#if os(iOS)
import UIKit
#endif

// MARK: - Session state

@Observable
@MainActor
public final class CookSession {
    public var stepIndex: Int = 0
    public var stepCount: Int = 1
    public var crossedOffSteps: Set<String> = [] // Step.id
    public var crossedOffIngredients: Set<String> = [] // Ingredient.id
    public var scale: Double = 1 // 0.25x–4x, clamped by UI stepper
    public var timers: [ParsedTimer] = []

    public init(stepCount: Int = 1) {
        self.stepCount = max(1, stepCount)
    }

    public func go(to index: Int) {
        stepIndex = min(max(0, index), stepCount - 1)
    }

    public func next() { go(to: stepIndex + 1) }
    public func previous() { go(to: stepIndex - 1) }

    public func toggleStep(id: String) {
        if crossedOffSteps.contains(id) { crossedOffSteps.remove(id) }
        else { crossedOffSteps.insert(id) }
    }

    /// Idempotent "done": repeat calls never unmark. The Finish button uses
    /// this; the step card's toggle remains the explicit unmark action.
    public func markStepDone(id: String) { crossedOffSteps.insert(id) }

    public func toggleIngredient(id: String) {
        if crossedOffIngredients.contains(id) { crossedOffIngredients.remove(id) }
        else { crossedOffIngredients.insert(id) }
    }

    public func loadTimers(from stepTexts: [String]) {
        timers = stepTexts.flatMap { parseTimers(from: $0) }
    }
}

// MARK: - Voice scale + ingredient-match helpers (Option A, Lane 10)

/// Voice scale commands ("double / halve / reset the recipe").
public enum ScaleVoiceCommand: Sendable {
    case double
    case halve
    case reset
}

public extension ScaleVoiceCommand {
    init?(_ voice: VoiceCommand) {
        switch voice {
        case .doubleScale: self = .double
        case .halveScale: self = .halve
        case .resetScale: self = .reset
        default: return nil
        }
    }
}

/// Applies a voice scale command to a servings pair. Double/halve are
/// relative to the base servings; reset returns to base. Pure (no state).
public func applyScaleCommand(_ command: ScaleVoiceCommand,
                              baseServings: Double,
                              targetServings: inout Double) {
    switch command {
    case .double: targetServings = baseServings * 2
    case .halve: targetServings = baseServings / 2
    case .reset: targetServings = baseServings
    }
}

/// Fuzzy ingredient-id lookup using the same normalization as the voice
/// parser (`fuzzyVoiceMatch`). Pure (no state).
///
/// Ambiguity rule (cubic finding): when multiple ingredients share the same
/// normalized label, returns nil instead of the first match so the caller
/// can reply with a disambiguation prompt. Existing optional signature kept.
public func ingredientId(matching name: String,
                         in ingredients: [(id: String, name: String)]) -> String? {
    let matched = fuzzyVoiceMatch(name, candidates: ingredients.map { $0.name })
    guard let matched else { return nil }
    let norm = voiceNormalizedName(matched)
    let dupes = ingredients.filter { voiceNormalizedName($0.name) == norm }
    guard dupes.count == 1 else { return nil }
    return dupes.first?.id
}

/// Validates a 1-based voice step request against the step count.
/// Returns the step number when it lies in 1...stepCount, else nil so the
/// caller can reply "There are only N steps." Pure (no state).
public func validatedStep(_ n: Int, stepCount: Int) -> Int? {
    guard stepCount > 0, (1...stepCount).contains(n) else { return nil }
    return n
}

// MARK: - Keep screen on

public enum KeepAwake {
    public static func enable() {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true
        #endif
    }

    public static func disable() {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
    }
}

// MARK: - Live Activity + local notification stub

/// Background timer alerts. Local notifications fire even when the app is
/// backgrounded; the Live Activity half is a stub (no ActivityKit target yet).
public enum CookActivityStub {
    /// Pure ID builder (no system calls) behind `schedule`: one UUID batch
    /// per call so per-timer starts passing one-element arrays never collide.
    /// Unit tests exercise this directly — `UNUserNotificationCenter` is
    /// unavailable in the host-less KeepCookingTests bundle.
    public static func makeIDs(for timers: [ParsedTimer]) -> [String] {
        let batch = UUID().uuidString
        return timers.enumerated().map { "cook-timer-\(batch)-\($0.offset)-\($0.element.seconds)" }
    }

    /// Schedules a local notification per timer. Returns the scheduled ids.
    @discardableResult
    public static func schedule(timers: [ParsedTimer]) -> [String] {
        let center = UNUserNotificationCenter.current()
        let ids = makeIDs(for: timers)
        for (id, timer) in zip(ids, timers) {
            let content = UNMutableNotificationContent()
            content.title = "Keep Cooking timer"
            content.body = "\(timer.label) — done!"
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, TimeInterval(timer.seconds)), repeats: false)
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
        }
        startLiveActivityStub(timerCount: timers.count)
        return ids
    }

    public static func cancel(ids: [String]) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
        endLiveActivityStub()
    }

    // MARK: Live Activity seam (stub — logged no-op)

    public static func startLiveActivityStub(timerCount: Int) {
        // Intentional no-op: count only, no PII. Real ActivityKit
        // implementation lands with the widget target (Lane 5+).
        _ = timerCount
    }

    public static func endLiveActivityStub() {}
}
