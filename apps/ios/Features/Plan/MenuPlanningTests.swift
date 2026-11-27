// Keep Cooking — Lane 4 MenuPlanningTests (XCTest)
// Covers the Lane 4 pure menu-planning core — no SwiftData, no network, no UI:
//   1. Day counts (max dayOffset + 1, min 1).
//   2. Meal slots (default order, custom extras alphabetical, snacks->snack).
//   3. Week expansion (date offsets, meal normalization).
//   4. Skip-filled filtering + occupied keys.
//   5. normalizeMeal + validateDayCount clamping.
//
// Run: these live in the KeepCookingTests target alongside CookTests
// (apps/ios/Features/Cook/CookTests.swift) and SyncEngineTests — the
// pure-logic sources under test (MenuPlanning.swift, PlanAggregation.swift)
// compile into the same test target — no import needed, no @testable import
// (standalone bundle, no app host).

import XCTest

// Same-target convention (see header): no import needed.

final class MenuPlanningTests: XCTestCase {
    private func entry(dayOffset: Int, meal: String,
                       recipeId: String = "r1", servings: Double = 2) -> MenuEntry {
        MenuEntry(dayOffset: dayOffset, meal: meal, recipeId: recipeId, servings: servings)
    }

    // MARK: - Day counts

    func testMenuDayCountEmptyIsOne() {
        XCTAssertEqual(menuDayCount(entries: []), 1)
    }

    func testMenuDayCountUsesMaxOffsetPlusOne() {
        let entries = [entry(dayOffset: 0, meal: "dinner"),
                       entry(dayOffset: 2, meal: "lunch"),
                       entry(dayOffset: 6, meal: "breakfast")]
        XCTAssertEqual(menuDayCount(entries: entries), 7)
    }

    func testMenuDayCountIgnoresNegativeOffsets() {
        XCTAssertEqual(menuDayCount(entries: [entry(dayOffset: -3, meal: "dinner")]), 1)
    }

    // MARK: - Meal slots

    func testMenuMealSlotsDefaultOrder() {
        // Entries arrive out of order with a "Snacks" variant; output follows
        // the canonical default order with snacks normalized.
        let entries = [entry(dayOffset: 0, meal: "dinner"),
                       entry(dayOffset: 0, meal: "Snacks"),
                       entry(dayOffset: 1, meal: "breakfast"),
                       entry(dayOffset: 1, meal: "lunch"),
                       entry(dayOffset: 2, meal: "DINNER")]
        XCTAssertEqual(menuMealSlots(entries: entries),
                       ["breakfast", "lunch", "dinner", "snack"])
    }

    func testMenuMealSlotsCustomExtrasAlphabetical() {
        let entries = [entry(dayOffset: 0, meal: "brunch"),
                       entry(dayOffset: 0, meal: "dinner"),
                       entry(dayOffset: 1, meal: "appetizer"),
                       entry(dayOffset: 1, meal: "lunch")]
        XCTAssertEqual(menuMealSlots(entries: entries),
                       ["lunch", "dinner", "appetizer", "brunch"])
    }

    func testMenuMealSlotsEmptyEntriesReturnsDefaults() {
        XCTAssertEqual(menuMealSlots(entries: []), ["breakfast", "lunch", "dinner", "snack"])
    }

    // MARK: - Week expansion

    func testExpandMenuEntriesDatesAndMeals() {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let entries = [entry(dayOffset: 0, meal: "Dinner", recipeId: "r1", servings: 4),
                       entry(dayOffset: 2, meal: "Snacks", recipeId: "r2", servings: 1)]
        let expanded = expandMenuEntries(entries: entries, weekStart: start,
                                         householdId: "hh", deviceId: "d1")
        XCTAssertEqual(expanded.count, 2)
        XCTAssertEqual(expanded[0].dayOffset, 0)
        XCTAssertEqual(expanded[1].dayOffset, 2)
        XCTAssertTrue(calendar.isDate(expanded[0].date, inSameDayAs: start))
        XCTAssertTrue(calendar.isDate(expanded[1].date,
                                      inSameDayAs: calendar.date(byAdding: .day, value: 2, to: start) ?? start))
        XCTAssertEqual(expanded[0].meal, "dinner")
        XCTAssertEqual(expanded[1].meal, "snack")
        XCTAssertEqual(expanded[0].recipeId, "r1")
        XCTAssertEqual(expanded[1].servings, 1)
    }

    // MARK: - Skip-filled filtering + occupied keys

    func testOccupiedKeysNormalizeDayAndMeal() {
        let calendar = Calendar.current
        let day = Date()
        let laterSameDay = calendar.date(byAdding: .hour, value: 5, to: day) ?? day
        let keys = occupiedKeys(plans: [(date: day, meal: "dinner"),
                                        (date: laterSameDay, meal: "SNACKS")])
        // Same-day different times collapse; "SNACKS" normalizes to "snack".
        XCTAssertEqual(keys, [OccupiedMealKey(day: day, meal: "dinner"),
                              OccupiedMealKey(day: day, meal: "snack")])
        XCTAssertEqual(keys.count, 2)
    }

    func testFilterSkippedSkipFilled() {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let d0 = start
        let d1 = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        let expanded: [ExpandedMenuEntry] = [
            (dayOffset: 0, date: d0, meal: "dinner", recipeId: "r1", servings: 2),
            (dayOffset: 1, date: d1, meal: "lunch", recipeId: "r2", servings: 2),
        ]
        let occupied: Set<OccupiedMealKey> = [OccupiedMealKey(day: d0, meal: "DINNER")]
        let result = filterSkipped(expanded: expanded, occupied: occupied, skipFilled: true)
        XCTAssertEqual(result.toInsert.count, 1)
        XCTAssertEqual(result.toInsert.first?.recipeId, "r2")
        XCTAssertEqual(result.skippedCount, 1)
    }

    func testFilterSkippedOverwriteInsertsAll() {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let expanded: [ExpandedMenuEntry] = [
            (dayOffset: 0, date: start, meal: "dinner", recipeId: "r1", servings: 2),
        ]
        let occupied: Set<OccupiedMealKey> = [OccupiedMealKey(day: start, meal: "dinner")]
        let result = filterSkipped(expanded: expanded, occupied: occupied, skipFilled: false)
        XCTAssertEqual(result.toInsert.count, 1)
        XCTAssertEqual(result.skippedCount, 0)
    }

    // MARK: - normalizeMeal + validateDayCount

    func testNormalizeMeal() {
        XCTAssertEqual(normalizeMeal("Dinner"), "dinner")
        XCTAssertEqual(normalizeMeal("  Snacks "), "snack")
        XCTAssertEqual(normalizeMeal("SNACK"), "snack")
        XCTAssertEqual(normalizeMeal("  brunch  "), "brunch")
        XCTAssertEqual(normalizeMeal(""), "")
    }

    func testValidateDayCountClamps() {
        XCTAssertEqual(validateDayCount(0), 1)
        XCTAssertEqual(validateDayCount(-5), 1)
        XCTAssertEqual(validateDayCount(1), 1)
        XCTAssertEqual(validateDayCount(7), 7)
        XCTAssertEqual(validateDayCount(28), 28)
        XCTAssertEqual(validateDayCount(29), 28)
        XCTAssertEqual(validateDayCount(500), 28)
    }
}
