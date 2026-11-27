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

/// Maps a menu meal to a valid plan meal slot.
/// The plans CHECK constraint + openapi Plan.meal allow only
/// breakfast/lunch/dinner/snack, so custom menu labels (e.g. "brunch")
/// collapse to "dinner" at apply time instead of being written verbatim
/// to Plan.mealRaw — a contract violation that sync would then propagate
/// to every device. Input is normalized first, so raw labels are accepted.
public func planMealForMenuSlot(_ raw: String) -> String {
    switch normalizeMeal(raw) {
    case "breakfast", "lunch", "dinner", "snack": return normalizeMeal(raw)
    default: return "dinner"
    }
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
/// (dayOffset 0 = weekStart). Meals are normalized; entries are dropped when:
///   - the normalized meal is empty (an empty mealRaw would violate the
///     plans contract, and Apply must never write one),
///   - dayOffset is outside 0...27 (the editor scope is 1–28 days while the
///     API allows offsets 0–365, so out-of-range entries can arrive via
///     sync — they stay on the menu but Apply ignores them),
///   - the offset can't resolve to a date (Calendar.current).
/// Callers surface the drop count as `entries.count - expanded.count`.
public func expandMenuEntries(entries: [MenuEntry],
                              weekStart: Date,
                              householdId: String,
                              deviceId: String,
                              makeID: () -> String = { UUID().uuidString }) -> [ExpandedMenuEntry] {
    let calendar = Calendar.current
    return entries.compactMap { entry in
        let meal = normalizeMeal(entry.meal)
        guard meal.isEmpty == false else { return nil }
        guard entry.dayOffset >= 0, entry.dayOffset <= menuMaxDayCount - 1 else { return nil }
        guard let day = calendar.date(byAdding: .day, value: entry.dayOffset, to: weekStart) else {
            return nil
        }
        return (dayOffset: entry.dayOffset,
                date: day,
                meal: meal,
                recipeId: entry.recipeId,
                servings: entry.servings)
    }
}

/// Renames one entry-derived meal slot: rewrites every entry whose
/// normalized meal equals `oldMeal` to the normalized `newMeal`, then
/// dedupes fully identical entries (same dayOffset/meal/recipeId/servings),
/// keeping the first occurrence — a rename can collide with entries that
/// already carry the target label. No-op when either side normalizes to
/// empty or both sides are equal. Pure so the slot editor stays testable;
/// the caller persists the result with an updatedAt bump.
public func renameMenuSlot(entries: [MenuEntry], from oldMeal: String, to newMeal: String) -> [MenuEntry] {
    let source = normalizeMeal(oldMeal)
    let target = normalizeMeal(newMeal)
    guard source.isEmpty == false, target.isEmpty == false, source != target else {
        return entries
    }
    var seen = Set<MenuEntry>()
    var out: [MenuEntry] = []
    out.reserveCapacity(entries.count)
    for entry in entries {
        let candidate: MenuEntry
        if normalizeMeal(entry.meal) == source {
            candidate = MenuEntry(dayOffset: entry.dayOffset, meal: target,
                                  recipeId: entry.recipeId, servings: entry.servings)
        } else {
            candidate = entry
        }
        if seen.insert(candidate).inserted {
            out.append(candidate)
        }
    }
    return out
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
