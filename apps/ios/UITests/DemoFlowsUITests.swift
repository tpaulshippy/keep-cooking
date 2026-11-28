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

    /// Waits until the element no longer exists (DisclosureGroup collapse, sheet dismiss).
    private func waitGone(_ element: XCUIElement, _ message: String, timeout: TimeInterval = 5) {
        let exp = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: element)
        let result = XCTWaiter().wait(for: [exp], timeout: timeout)
        XCTAssertEqual(result, .completed, message)
    }

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
        // Single + lives in the shell top bar (quick-add): Clip / Scan / Caption.
        let add = id(app, "quick-add-button")
        wait(add, "quick-add button missing")
        add.tap()
        let scan = app.buttons["Scan cookbook"]
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
        // Drawer-only nav: sections switch through the drawer (no bottom bar).
        goDrawer(app, "drawer-plan")
        wait(app.buttons["Add week to list"], "Add-week button missing")
        sleep(1)
        app.buttons["Add week to list"].tap()
        wait(id(app, "week-to-list-confirm"), "week-to-list confirmation missing")
        sleep(2)

        // Aggregated, aisle-sorted list → check off the first item.
        // (Lists lives in the drawer; Shopping/Lists switch via drawer rows.)
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
        goDrawer(app, "drawer-recipes")
        wait(id(app, "recipe-list"), "recipe list missing")
        let firstRecipe = id(app, "recipe-list").descendants(matching: .button).firstMatch
        wait(firstRecipe, "no recipe row")
        firstRecipe.tap()
        // Detail opens on the Ingredients pane; the cook entry point
        // (Start Cooking) lives in the Directions pane (detail revamp).
        let directionsToggle = app.buttons["Directions"]
        wait(directionsToggle, "Directions toggle missing")
        directionsToggle.tap()
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

    // MARK: 4 — nutrition-panel: edit nutrition text, save, collapse/expand.

    func testNutritionPanel() throws {
        let app = XCUIApplication()
        app.launch()

        wait(id(app, "recipe-list"), "seeded recipe list missing")
        let firstRecipe = id(app, "recipe-list").descendants(matching: .button).firstMatch
        wait(firstRecipe, "no recipe row")
        firstRecipe.tap()

        // Open the editor and fill the Nutrition TextEditor.
        let edit = id(app, "edit-recipe-button")
        wait(edit, "Edit button missing")
        edit.tap()
        let editor = id(app, "recipe-editor")
        wait(editor, "recipe editor sheet missing")

        // The editor's Nutrition section starts collapsed: expand it.
        let nutritionSection = id(app, "recipe-editor-section-nutrition")
        let nutritionField = app.textViews["recipe-editor-nutrition-text"]
        if !nutritionField.waitForExistence(timeout: 5) {
            wait(nutritionSection, "editor nutrition section missing")
            nutritionSection.tap()
        }
        for _ in 0..<6 where !nutritionField.isHittable {
            app.swipeUp()
            sleep(1)
        }
        wait(nutritionField, "editor nutrition TextEditor missing")
        nutritionField.tap()
        // Replace any seeded text so reruns stay deterministic.
        if let current = nutritionField.value as? String, !current.isEmpty {
            nutritionField.press(forDuration: 1.1)
            let selectAll = app.menuItems["Select All"]
            if selectAll.waitForExistence(timeout: 3) {
                selectAll.tap()
            }
        }
        nutritionField.typeText("220 kcal test nutrition")
        sleep(1)

        // Dismiss the keyboard (nav-bar tap, ocr-test pattern) so Save is tappable.
        if app.keyboards.count > 0 {
            app.navigationBars.staticTexts["Edit Recipe"].tap()
            sleep(1)
        }
        let save = app.buttons["recipe-editor-save"]
        wait(save, "editor Save button missing")
        save.tap()

        // Editor dismisses back to detail; the panel shows the saved text.
        let panel = id(app, "nutrition-panel")
        wait(panel, "nutrition panel missing after editor dismiss")
        for _ in 0..<6
            where !app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS '220 kcal test nutrition'")).firstMatch.isHittable {
            app.swipeUp()
            sleep(1)
        }
        let nutritionText = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS '220 kcal test nutrition'")).firstMatch
        wait(nutritionText, "saved nutrition text missing from panel")

        // Collapse the DisclosureGroup: the text disappears.
        let headerButton = panel.descendants(matching: .button).firstMatch
        let header: XCUIElement =
            headerButton.waitForExistence(timeout: 5) ? headerButton : app.staticTexts["Nutrition"]
        wait(header, "Nutrition DisclosureGroup header missing")
        if !header.isHittable { app.swipeUp(); sleep(1) }
        header.tap()
        waitGone(
            app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS '220 kcal test nutrition'")).firstMatch,
            "nutrition text still visible after collapse")

        // Expand again: the text reappears.
        let headerAgain = panel.descendants(matching: .button).firstMatch
        let header2: XCUIElement =
            headerAgain.waitForExistence(timeout: 5) ? headerAgain : app.staticTexts["Nutrition"]
        wait(header2, "Nutrition DisclosureGroup header missing on re-expand")
        header2.tap()
        let nutritionTextAgain = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS '220 kcal test nutrition'")).firstMatch
        wait(nutritionTextAgain, "nutrition text missing after re-expand")

        app.swipeUp()
        sleep(1)
        app.swipeUp()
        sleep(1)
        let shot = app.screenshot()
        let url = URL(fileURLWithPath: "/tmp/kc-nutrition-ios.png")
        try? shot.pngRepresentation.write(to: url)
        add(XCTAttachment(screenshot: shot))
    }
}
