// Smidgen — Lane 4 Cook: session state + background stub (no persistence layer)
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
    /// Schedules a local notification per timer. Returns the scheduled ids.
    @discardableResult
    public static func schedule(timers: [ParsedTimer]) -> [String] {
        let center = UNUserNotificationCenter.current()
        // One UUID per schedule call: per-timer starts each pass a
        // one-element array (index always 0), so index+seconds alone would
        // collide and equal-duration timers would replace each other.
        let batch = UUID().uuidString
        var ids: [String] = []
        for (i, timer) in timers.enumerated() {
            let id = "cook-timer-\(batch)-\(i)-\(timer.seconds)"
            let content = UNMutableNotificationContent()
            content.title = "Smidgen timer"
            content.body = "\(timer.label) — done!"
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, TimeInterval(timer.seconds)), repeats: false)
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            ids.append(id)
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
