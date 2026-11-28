// Keep Cooking — recipe-editor screenshot driver (iOS lane)
// apps/ios/UITests/RecipeEditorScreenshotTests.swift
//
// Opens the first seeded recipe, presents the Edit Recipe sheet, and writes
// a host-side screenshot to /tmp/recipe-editor-ios.png. Run with:
//   xcodebuild test -project Smidgen.xcodeproj -scheme <TestScheme> \
//     -destination 'platform=iOS Simulator,id=<UDID>' \
//     -only-testing:KeepCookingUITests/RecipeEditorScreenshotTests/testEditRecipeSheet
// Set dark mode first: `xcrun simctl ui <UDID> appearance dark`.

import XCTest

final class RecipeEditorScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func id(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func testEditRecipeSheet() throws {
        let app = XCUIApplication()
        app.launch()

        let list = id(app, "recipe-list")
        XCTAssertTrue(list.waitForExistence(timeout: 30), "seeded recipe list missing")

        // Open the first recipe row (NavigationLink rows expose as cells/links).
        let firstCell = app.cells.firstMatch
        if firstCell.waitForExistence(timeout: 10) {
            firstCell.tap()
        } else {
            app.links.firstMatch.tap()
        }

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
