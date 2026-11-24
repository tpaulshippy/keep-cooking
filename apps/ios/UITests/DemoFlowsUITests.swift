// Keep Cooking — PASS 2 demo drivers
// apps/ios/UITests/DemoFlowsUITests.swift
//
// Deterministic drivers for the three screen recordings (run while
// `xcrun simctl io booted recordVideo` captures). Each test pauses ~1s at
// key beats so the MP4 is watchable. No backend: everything is local.

import XCTest

final class DemoFlowsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Helpers

    /// Any element carrying the given accessibility identifier.
    private func id(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func wait(_ element: XCUIElement, _ message: String, timeout: TimeInterval = 30) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), message)
    }

    // MARK: 1 — offline-launch: fresh install lists seeded recipes; persists.

    func testOfflineLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        wait(app.tabBars.buttons["Recipes"], "Recipes tab missing")
        // Seeded recipes appear with zero backend configured.
        wait(id(app, "recipe-list"), "seeded recipe list missing")
        XCTAssertGreaterThan(app.cells.count + app.buttons.count, 3,
            "expected seeded recipes")
        sleep(2)

        // Kill + relaunch: the list persists (SwiftData, offline-first).
        app.terminate()
        sleep(1)
        app.launch()
        wait(app.tabBars.buttons["Recipes"], "Recipes tab missing after relaunch")
        wait(id(app, "recipe-list"), "recipe list missing after relaunch")
        sleep(2)
    }

    // MARK: 2 — ingest-save: paste → Parse → Save (OCR, fully local, ≤3 taps).

    func testIngestSave() throws {
        let app = XCUIApplication()
        app.launch()

        wait(app.tabBars.buttons["More"], "More tab missing")
        app.tabBars.buttons["More"].tap()
        wait(id(app, "more-ocr"), "OCR entry missing")
        id(app, "more-ocr").tap()

        // Tap 1: paste/type recognized text.
        let editor = app.textViews["ocr-text"]
        wait(editor, "OCR text editor missing")
        editor.tap()
        editor.typeText("Cream of Mushroom\n8 oz mushrooms\n2 cups cream\nSimmer 20 minutes.")
        sleep(1)

        // Dismiss the keyboard (also scrolls the form) so lower rows exist.
        // Targets the review heading by identifier (stable across copy edits).
        wait(id(app, "ocr-review-heading"), "review heading missing")
        id(app, "ocr-review-heading").tap()
        sleep(1)

        // Tap 2: parse into editable preview.
        let parse = app.buttons["ocr-parse"]
        wait(parse, "Parse button missing")
        parse.tap()
        sleep(2)

        // Tap 3: save into the library (swipe up to reveal the Save row).
        app.swipeUp()
        sleep(1)
        let save = app.buttons["ocr-save"]
        wait(save, "Save button missing (title empty?)")
        save.tap()
        wait(id(app, "ocr-saved"), "saved confirmation missing")
        sleep(2)
    }

    // MARK: 3 — plan-to-list: week → aggregate → aisle-sorted check-off (+cook).

    func testPlanToList() throws {
        let app = XCUIApplication()
        app.launch()

        // Week plan with demo entries (Mon/Wed/Fri dinners, seeded offline).
        wait(app.tabBars.buttons["Plan"], "Plan tab missing")
        app.tabBars.buttons["Plan"].tap()
        wait(app.buttons["Add week to list"], "Add-week button missing")
        sleep(1)
        app.buttons["Add week to list"].tap()
        wait(id(app, "week-to-list-confirm"), "week-to-list confirmation missing")
        sleep(2)

        // Aggregated, aisle-sorted list → check off the first item.
        app.tabBars.buttons["Lists"].tap()
        let weeklyHeader = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'Weekly shop'")).firstMatch
        wait(weeklyHeader, "Weekly shop list missing")
        let listsView = id(app, "lists-view")
        wait(listsView, "lists view missing")
        let firstItem = listsView.descendants(matching: .button).firstMatch
        wait(firstItem, "no shoppable item")
        firstItem.tap()
        sleep(2)

        // Cook mode reachable from a recipe: scaler + step pager.
        app.tabBars.buttons["Recipes"].tap()
        wait(id(app, "recipe-list"), "recipe list missing")
        let firstRecipe = id(app, "recipe-list").descendants(matching: .button).firstMatch
        wait(firstRecipe, "no recipe row")
        firstRecipe.tap()
        let cook = app.buttons["cook-button"]
        wait(cook, "Cook button missing")
        cook.tap()
        wait(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Step 1 of'")).firstMatch,
            "cook step pager missing")
        sleep(1)
        let next = app.buttons["Next"]
        if next.waitForExistence(timeout: 5) { next.tap() }
        sleep(2)
    }
}
