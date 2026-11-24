// Keep Cooking — Lane 4 CookTests (XCTest)
// Covers the Lane 4 pure core — no SwiftData, no network, no UI:
//   1. Scaling 4 -> 6 servings (factor + fraction display).
//   2. Timer parser (ranges use upper bound, multi-timer, hr/min/sec).
//   3. Week aggregation (scaled merge + unmeasured passthrough).
//   4. Aisle sort + pantry helpers (expiry, low-stock).
//
// Run: these live in the KeepCookingTests target alongside SyncEngineTests
// (apps/ios/Sync/SyncEngineTests.swift). The pure-logic sources under test
// (RecipeScaler.swift, StepTimerParser.swift, CookSession.swift,
// ../Plan/PlanAggregation.swift, ../Shop/ShopHelpers.swift) compile into
// the same test target (see project.yml + KeepCooking.xcodeproj) — no import
// needed, no @testable import (standalone bundle, no app host).

import XCTest

// Same-target convention (see header): no import needed.

final class CookTests: XCTestCase {
    // MARK: - Scaling 4 -> 6 servings

    func testScaleFactor4to6() {
        XCTAssertEqual(scaleFactor(baseServings: 4, targetServings: 6), 1.5)
    }

    func testScaleFactorClamped() {
        XCTAssertEqual(scaleFactor(baseServings: 4, targetServings: 40), 4) // 10x -> 4x
        XCTAssertEqual(scaleFactor(baseServings: 4, targetServings: 0.1), 0.25) // tiny -> 0.25x
        XCTAssertEqual(scaleFactor(baseServings: 0, targetServings: 6), 1) // degenerate
    }

    func testFractionDisplay() {
        XCTAssertEqual(fractionDisplayString(for: 1.5), "1½")
        XCTAssertEqual(fractionDisplayString(for: 6), "6") // 4 cups @1.5x
        XCTAssertEqual(fractionDisplayString(for: 0.5), "½")
        XCTAssertEqual(fractionDisplayString(for: 0.25), "¼")
        // Servings labels must never use %.1g (2.5 -> "2", 12.5 -> "1e+01").
        XCTAssertEqual(fractionDisplayString(for: 2.5), "2½")
        XCTAssertEqual(fractionDisplayString(for: 12.5), "12½")
        XCTAssertEqual(fractionDisplayString(for: 4), "4")
    }

    func testScaledDisplay4to6() {
        // 4 cups flour, base 4 servings -> 6 servings = 6 cups.
        XCTAssertEqual(
            scaledDisplay(name: "flour", quantity: 4, unit: "cups", factor: 1.5),
            "6 cups flour")
        // 1 cup sugar -> 1½ cups.
        XCTAssertEqual(
            scaledDisplay(name: "sugar", quantity: 1, unit: "cup", factor: 1.5),
            "1½ cup sugar")
        // Unmeasured stays bare.
        XCTAssertEqual(
            scaledDisplay(name: "Salt to taste", quantity: nil, unit: "", factor: 1.5),
            "Salt to taste")
    }

    // MARK: - Timer parser

    func testTimerParserRangeUsesUpperBound() {
        let timers = parseTimers(from: "bake 12-15 min")
        XCTAssertEqual(timers.count, 1)
        XCTAssertEqual(timers[0].seconds, 15 * 60)
    }

    func testTimerParserMultiTimer() {
        let timers = parseTimers(from: "bake 12-15 min, rest 1 hr")
        XCTAssertEqual(timers.count, 2)
        XCTAssertEqual(timers[0].seconds, 15 * 60)
        XCTAssertEqual(timers[1].seconds, 3600)
    }

    func testTimerParserSeconds() {
        let timers = parseTimers(from: "sear 30 seconds per side")
        XCTAssertEqual(timers.count, 1)
        XCTAssertEqual(timers[0].seconds, 30)
    }

    func testTimerParserNoTimers() {
        XCTAssertTrue(parseTimers(from: "chop the onions finely").isEmpty)
    }

    // MARK: - Aggregation (plan -> list, scaled)

    func testAggregationScaledMerge() {
        // Two plans, same flour: 2 cups @4 servings as-written + 2 cups @4
        // servings scaled to 6 (1.5x -> 3 cups) = 5 cups total.
        let inputs = [
            PlanGroceryInput(name: "Flour", quantity: 2, unit: "cups",
                             baseServings: 4, targetServings: 4, recipeId: "r1"),
            PlanGroceryInput(name: "flour", quantity: 2, unit: "cups",
                             baseServings: 4, targetServings: 6, recipeId: "r2"),
        ]
        let out = aggregateWeekToList(inputs)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].totalQuantity ?? -1, 5, accuracy: 0.001)
        XCTAssertEqual(out[0].display, "5 cups Flour")
    }

    func testAggregationUnmeasuredPassthrough() {
        let inputs = [
            PlanGroceryInput(name: "Salt", quantity: nil, unit: "",
                             baseServings: 4, targetServings: 6),
        ]
        let out = aggregateWeekToList(inputs)
        XCTAssertEqual(out.count, 1)
        XCTAssertNil(out[0].totalQuantity)
        XCTAssertEqual(out[0].display, "Salt")
    }

    // MARK: - Shop helpers

    func testAisleSortProduceBeforeDairy() {
        let kp = aisleSortKey(aisle: "produce", name: "x")
        let kd = aisleSortKey(aisle: "dairy", name: "x")
        XCTAssertTrue(kp.0 < kd.0)
        // Unknown aisles sort after known ones.
        let ku = aisleSortKey(aisle: "zebra", name: "x")
        XCTAssertTrue(kd.0 < ku.0)
    }

    func testAisleGroupedNamesNormalizesCaseAndWhitespace() {
        // Values differing only by case/whitespace must collapse to one section.
        struct Item { let aisle: String; let name: String }
        let items = [
            Item(aisle: "Produce", name: "Apples"),
            Item(aisle: "produce ", name: "Carrots"),
            Item(aisle: "PRODUCE", name: "Bananas"),
            Item(aisle: "dairy", name: "Milk"),
            Item(aisle: "", name: "Mystery"),
            Item(aisle: "  ", name: "Other mystery"),
        ]
        let groups = aisleGroupedNames(items: items, aisleOf: { $0.aisle }, nameOf: { $0.name })
        XCTAssertEqual(groups.count, 3) // produce + dairy + unfiled, not 6
        XCTAssertEqual(
            Set(groups.map { normalizedAisleKey($0) }),
            Set(["produce", "dairy", ""]))
    }

    func testNormalizedAisleKey() {
        XCTAssertEqual(normalizedAisleKey(" Produce "), "produce")
        XCTAssertEqual(normalizedAisleKey("DAIRY"), "dairy")
        XCTAssertEqual(normalizedAisleKey(""), "")
    }

    func testExpiryStatus() {
        let now = Date()
        XCTAssertEqual(expiryStatus(expiresAt: now.addingTimeInterval(-10)), .expired)
        XCTAssertEqual(expiryStatus(expiresAt: now.addingTimeInterval(3 * 86400)), .expiringSoon)
        XCTAssertEqual(expiryStatus(expiresAt: now.addingTimeInterval(30 * 86400)), .fresh)
        XCTAssertEqual(expiryStatus(expiresAt: nil), .noDate)
    }

    func testLowStock() {
        XCTAssertTrue(isLowStock(quantity: "1", threshold: "2"))
        XCTAssertFalse(isLowStock(quantity: "3", threshold: "2"))
        XCTAssertFalse(isLowStock(quantity: "anything", threshold: "")) // no threshold
        XCTAssertTrue(isLowStock(quantity: "", threshold: "2")) // nothing left
    }

    // MARK: - Session: Finish is idempotent, card toggle unmarks

    @MainActor
    func testMarkStepDoneIdempotent() {
        let session = CookSession(stepCount: 3)
        session.markStepDone(id: "s-last")
        session.markStepDone(id: "s-last") // repeat Finish tap
        XCTAssertTrue(session.crossedOffSteps.contains("s-last"))
        // Card toggle remains the explicit unmark action.
        session.toggleStep(id: "s-last")
        XCTAssertFalse(session.crossedOffSteps.contains("s-last"))
    }

    // MARK: - Timer scheduling: stable unique identifiers

    func testScheduleIdsUniqueAcrossCalls() {
        // Per-timer starts each pass a one-element array; equal durations
        // must not reuse one notification identifier. Exercises the pure
        // ID builder: UNUserNotificationCenter is unavailable in the
        // host-less test bundle, so `schedule` itself is not called here.
        let timer = ParsedTimer(seconds: 600, label: "bake")
        let first = CookActivityStub.makeIDs(for: [timer])
        let second = CookActivityStub.makeIDs(for: [timer])
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1)
        XCTAssertNotEqual(first[0], second[0])
    }

    func testScheduleIdsUniqueWithinBatch() {
        let timers = [ParsedTimer(seconds: 600, label: "bake"),
                      ParsedTimer(seconds: 600, label: "rest")]
        let ids = CookActivityStub.makeIDs(for: timers)
        XCTAssertEqual(ids.count, 2)
        XCTAssertNotEqual(ids[0], ids[1])
    }
}
