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

    /// Open the drawer and choose a section row
    /// (identifiers: drawer-recipes, drawer-plan, drawer-lists, …).
    private func goDrawer(_ app: XCUIApplication, _ row: String) {
        let hamburger = app.buttons["drawer-hamburger"]
        wait(hamburger, "drawer hamburger missing")
        hamburger.tap()
        let dest = id(app, row)
        wait(dest, "\(row) drawer row missing")
        dest.tap()
    }

    // MARK: 1 — offline-launch: fresh install lists seeded recipes; persists.

    func testOfflineLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        // Drawer shell launches into Recipes: seeded list, no tab bar.
        XCTAssertEqual(app.tabBars.count, 0, "drawer shell must not show a tab bar")
        wait(id(app, "recipe-list"), "seeded recipe list missing")
        XCTAssertGreaterThan(app.cells.count + app.buttons.count, 3,
            "expected seeded recipes")
        // Drawer opens over content and lists sections.
        let hamburger = app.buttons["drawer-hamburger"]
        wait(hamburger, "drawer hamburger missing")
        hamburger.tap()
        wait(id(app, "drawer-recipes"), "drawer recipes row missing")
        app.buttons["Dismiss navigation menu"].tap()
        sleep(2)

        // Kill + relaunch: the list persists (SwiftData, offline-first).
        app.terminate()
        sleep(1)
        app.launch()
        wait(id(app, "recipe-list"), "recipe list missing after relaunch")
        sleep(2)
    }

    // MARK: 2 — ingest-save: paste → Parse → Save (OCR, fully local, ≤3 taps).

    func testIngestSave() throws {
        let app = XCUIApplication()
        app.launch()

        wait(id(app, "recipe-list"), "seeded recipe list missing")
        let add = id(app, "add-recipe-button")
        wait(add, "add-recipe button missing")
        add.tap()
        let scan = app.buttons["Scan cookbook (OCR)"]
        wait(scan, "Scan cookbook entry missing")
        scan.tap()

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
        let planTab = app.buttons["Plan tab"]
        wait(planTab, "Plan tab missing")
        planTab.tap()
        wait(app.buttons["Add week to list"], "Add-week button missing")
        sleep(1)
        app.buttons["Add week to list"].tap()
        wait(id(app, "week-to-list-confirm"), "week-to-list confirmation missing")
        sleep(2)

        // Aggregated, aisle-sorted list → check off the first item.
        // (Lists lives in the drawer; the bottom-bar shortcut is "Shopping".)
        goDrawer(app, "drawer-lists")
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
        let recipesTab = app.buttons["Recipes tab"]
        wait(recipesTab, "Recipes tab missing")
        recipesTab.tap()
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
