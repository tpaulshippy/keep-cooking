// Keep Cooking — recipe-editor screenshot driver (iOS lane)
// apps/ios/UITests/RecipeEditorScreenshotTests.swift
//
// Opens a known seeded recipe ("Weeknight Miso Salmon", seed recipe-01),
// presents the Edit Recipe sheet, and writes a host-side screenshot to
// /tmp/recipe-editor-ios.png. The target is a fixed seed title — not the
// first sorted row — so the shot is deterministic regardless of other
// data or sort order. Run with:
//   xcodebuild test -project Smidgen.xcodeproj -scheme <TestScheme> \
//     -destination 'platform=iOS Simulator,id=<UDID>' \
//     -only-testing:KeepCookingUITests/RecipeEditorScreenshotTests/testEditRecipeSheet
// Set dark mode first: `xcrun simctl ui <UDID> appearance dark`.

import XCTest

final class RecipeEditorScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        // NOTE: for a guaranteed-fresh seed set, uninstall the app first:
        //   xcrun simctl uninstall <UDID> org.smidgen.app
        // (Foundation.Process is unavailable in the iOS-simulator test
        //  bundle, so the reset must happen host-side before this run.)
        // Targeting below is a fixed seed title + search filter, so the
        // shot stays deterministic even with leftover user data around it.
    }

    private func id(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func testEditRecipeSheet() throws {
        let app = XCUIApplication()
        app.launch()

        let list = id(app, "recipe-list")
        XCTAssertTrue(list.waitForExistence(timeout: 30), "seeded recipe list missing")

        // Open the known seeded recipe (deterministic target: seed
        // recipe-01). Prefer the library search filter; fall back to
        // scrolling the list if the search field is absent.
        let seedTitle = "Weeknight Miso Salmon"
        let searchField = id(app, "library-search-field")
        if searchField.waitForExistence(timeout: 10) {
            searchField.tap()
            searchField.typeText("Miso")
            if app.keyboards.buttons["Search"].waitForExistence(timeout: 5) {
                app.keyboards.buttons["Search"].tap()
            }
        } else {
            print("TEST-DIAG: search field absent; hierarchy:\n\(app.debugDescription)")
        }
        var seedCell = app.cells.containing(.staticText, identifier: seedTitle).firstMatch
        if !seedCell.waitForExistence(timeout: 10) {
            let list = id(app, "recipe-list")
            for _ in 0..<12 where !seedCell.isHittable {
                list.swipeUp()
                seedCell = app.cells.containing(.staticText, identifier: seedTitle).firstMatch
            }
        }
        XCTAssertTrue(seedCell.waitForExistence(timeout: 10), "seeded recipe '\(seedTitle)' missing")
        seedCell.tap()

        let detail = id(app, "recipe-detail-title")
        XCTAssertTrue(detail.waitForExistence(timeout: 30), "recipe detail missing")

        let edit = id(app, "edit-recipe-button")
        XCTAssertTrue(edit.waitForExistence(timeout: 10), "Edit button missing")
        edit.tap()

        let editor = id(app, "recipe-editor")
        XCTAssertTrue(editor.waitForExistence(timeout: 30), "recipe editor sheet missing")
        sleep(2)

        let shot = app.screenshot()
        let data = shot.pngRepresentation
        let url = URL(fileURLWithPath: "/tmp/recipe-editor-ios.png")
        try data.write(to: url)
    }
}
