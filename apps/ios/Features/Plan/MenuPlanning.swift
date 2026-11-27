// Keep Cooking — Lane 4 Plan: menu planning helpers (pure)
// apps/ios/Features/Plan/MenuPlanning.swift
//
// Paprika-style reusable menus: day counts, meal slots, week expansion,
// and skip-filled filtering. Foundation only — no SwiftData import so the
// logic stays unit-testable (see MenuPlanningTests.swift). `MenuEntry` is
// referenced as a same-module type; no model mutation happens here
// (@MainActor persistence lives in DemoFlows.MenusTabView).

import Foundation

/// Default meal slots, in canonical display order. Matches
/// `planMealOrder` (PlanViews) and the `MealSlot` raw values.
public let menuDefaultSlots: [String] = ["breakfast", "lunch", "dinner", "snack"]

/// Maximum menu length in days (editor stepper range is 1...28).
public let menuMaxDayCount = 28

/// Normalizes a meal label: trims whitespace, lowercases, and maps
/// "snacks" to "snack" (mirrors PlanView's snack/snacks handling).
/// Empty input stays empty — callers decide the fallback.
public func normalizeMeal(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if trimmed == "snacks" { return "snack" }
    return trimmed
}

/// Clamps a menu length to the editor range 1...menuMaxDayCount.
public func validateDayCount(_ raw: Int) -> Int {
    min(max(raw, 1), menuMaxDayCount)
}

/// Number of days a menu spans: max dayOffset + 1, minimum 1.
/// Upper-clamped to menuMaxDayCount so oversized offsets can't break the grid.
public func menuDayCount(entries: [MenuEntry]) -> Int {
    let maxOffset = entries.map(\.dayOffset).max() ?? -1
    return validateDayCount(maxOffset + 1)
}

/// Ordered distinct meal slots used by a menu's entries.
/// Meals present in `defaultSlots` come first in default order; any custom
/// labels are preserved and appended alphabetically. Empty menus (or menus
/// whose entries all normalize to empty) return the defaults so the editor
/// grid always has columns.
public func menuMealSlots(entries: [MenuEntry],
                          defaultSlots: [String] = menuDefaultSlots) -> [String] {
    let defaults = defaultSlots.map(normalizeMeal).filter { $0.isEmpty == false }
    let present = Set(entries.map { normalizeMeal($0.meal) }.filter { $0.isEmpty == false })
    guard present.isEmpty == false else { return defaults.isEmpty ? menuDefaultSlots : defaults }
    let inOrder = defaults.filter { present.contains($0) }
    let extras = present.subtracting(defaults).sorted()
    return inOrder + extras
}

/// One menu entry expanded onto a concrete calendar date.
/// Identity (plan id / household / device) is stamped by the caller at
/// insert time, so the tuple carries only schedule fields; `householdId`,
/// `deviceId`, and `makeID` are accepted to keep a single expansion seam
/// for the apply-to-week call site (see MenusTabView.apply).
public typealias ExpandedMenuEntry = (
    dayOffset: Int, date: Date, meal: String, recipeId: String, servings: Double
)

/// Expands menu entries onto the week starting at `weekStart`
/// (dayOffset 0 = weekStart). Meals are normalized; entries whose offset
/// can't resolve to a date are dropped (Calendar.current).
public func expandMenuEntries(entries: [MenuEntry],
                              weekStart: Date,
                              householdId: String,
                              deviceId: String,
                              makeID: () -> String = { UUID().uuidString }) -> [ExpandedMenuEntry] {
    let calendar = Calendar.current
    return entries.compactMap { entry in
        guard let day = calendar.date(byAdding: .day, value: entry.dayOffset, to: weekStart) else {
            return nil
        }
        return (dayOffset: entry.dayOffset,
                date: day,
                meal: normalizeMeal(entry.meal),
                recipeId: entry.recipeId,
                servings: entry.servings)
    }
}

/// A calendar-day + normalized-meal slot that already has a plan.
/// Day is start-of-day normalized so plans at different times compare equal.
public struct OccupiedMealKey: Sendable, Hashable {
    public var day: Date
    public var meal: String
    public init(day: Date, meal: String) {
        self.day = Calendar.current.startOfDay(for: day)
        self.meal = normalizeMeal(meal)
    }
}

/// Builds the occupied-slot set from lightweight (date, meal) pairs.
/// Call sites map their plans (e.g. `(plan.date, plan.mealRaw)`) so this
/// helper never touches SwiftData types.
public func occupiedKeys(plans: [(date: Date, meal: String)]) -> Set<OccupiedMealKey> {
    Set(plans.map { OccupiedMealKey(day: $0.date, meal: $0.meal) })
}

/// Splits expanded entries into insertable vs skipped.
/// skipFilled=true drops entries whose slot is occupied and reports how many
/// were skipped; false inserts everything (the caller tombstones conflicts
/// first for the overwrite path) with skippedCount 0.
public func filterSkipped(expanded: [ExpandedMenuEntry],
                          occupied: Set<OccupiedMealKey>,
                          skipFilled: Bool) -> (toInsert: [ExpandedMenuEntry], skippedCount: Int) {
    guard skipFilled else { return (expanded, 0) }
    var kept: [ExpandedMenuEntry] = []
    var skipped = 0
    for entry in expanded {
        if occupied.contains(OccupiedMealKey(day: entry.date, meal: entry.meal)) {
            skipped += 1
        } else {
            kept.append(entry)
        }
    }
    return (kept, skipped)
}
