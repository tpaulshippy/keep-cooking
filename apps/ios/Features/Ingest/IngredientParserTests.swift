// Smidgen — Lane 3 Capture
// apps/ios/Features/Ingest/IngredientParserTests.swift
//
// XCTest suite for IngredientParser + ClipboardDetector + OCRSplitter.
// Add this file + IngredientParser.swift + ClipboardBanner.swift +
// OCRScanView.swift to the iOS unit-test target. No network, no SwiftData.
//
// Covers: unicode ½, ASCII 1/2, range 2-3 cloves, units
// tbsp/tsp/cup/g/ml/oz, plus detector + OCR splitter.

import XCTest

// NOTE: when these files live in the same test target, no import is needed.
// If your app target is named Smidgen, use `@testable import Smidgen` instead.

final class IngredientParserTests: XCTestCase {
    func testUnicodeHalf() {
        let p = IngredientParser.parse("½ cup sugar")
        XCTAssertEqual(p.quantity ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(p.unit, "cup")
        XCTAssertEqual(p.name, "sugar")
    }

    func testAsciiFraction() {
        let p = IngredientParser.parse("1/2 tsp salt")
        XCTAssertEqual(p.quantity ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(p.unit, "tsp")
        XCTAssertEqual(p.name, "salt")
    }

    func testMixedNumber() {
        let p = IngredientParser.parse("1 1/2 cups flour")
        XCTAssertEqual(p.quantity ?? -1, 1.5, accuracy: 0.001)
        XCTAssertEqual(p.unit, "cup")
        XCTAssertEqual(p.name, "flour")
    }

    func testAttachedUnicode() {
        let p = IngredientParser.parse("1½ cups flour")
        XCTAssertEqual(p.quantity ?? -1, 1.5, accuracy: 0.001)
        XCTAssertEqual(p.unit, "cup")
    }

    func testRangeCloves() {
        let p = IngredientParser.parse("2-3 cloves garlic")
        XCTAssertEqual(p.quantity ?? -1, 2.5, accuracy: 0.001)
        XCTAssertEqual(p.unit, "clove")
        XCTAssertEqual(p.name, "garlic")
        XCTAssertEqual(p.quantityText, "2-3")
    }

    func testTablespoonVariants() {
        for line in ["2 tbsp miso", "2 tablespoon miso", "2 tablespoons miso"] {
            let p = IngredientParser.parse(line)
            XCTAssertEqual(p.unit, "tbsp", line)
            XCTAssertEqual(p.name, "miso", line)
        }
    }

    func testMetricUnits() {
        XCTAssertEqual(IngredientParser.parse("200 g salmon").unit, "g")
        XCTAssertEqual(IngredientParser.parse("250 ml cream").unit, "ml")
        XCTAssertEqual(IngredientParser.parse("8 oz mushrooms").unit, "oz")
        XCTAssertEqual(IngredientParser.parse("2 cups rice").unit, "cup")
        XCTAssertEqual(IngredientParser.parse("1 tsp salt").unit, "tsp")
    }

    func testBareName() {
        let p = IngredientParser.parse("salt to taste")
        XCTAssertNil(p.quantity)
        XCTAssertEqual(p.name, "salt to taste")
        XCTAssertEqual(p.display, "salt to taste")
    }

    func testEmptyLine() {
        let p = IngredientParser.parse("   ")
        XCTAssertNil(p.quantity)
        XCTAssertEqual(p.name, "")
    }

    func testParseLinesSkipsBlanks() {
        let out = IngredientParser.parseLines("1 cup rice\n\n1 tsp salt\n")
        XCTAssertEqual(out.count, 2)
    }

    func testFractionString() {
        XCTAssertEqual(IngredientParser.fractionString(1.5), "1 1/2")
        XCTAssertEqual(IngredientParser.fractionString(0.5), "1/2")
        XCTAssertEqual(IngredientParser.fractionString(2.0), "2")
    }

    // MARK: - ClipboardDetector

    func testDetectorFindsURL() {
        XCTAssertNotNil(ClipboardDetector.firstURL(in: "check https://www.allrecipes.com/recipe/123 yum"))
        XCTAssertNil(ClipboardDetector.firstURL(in: "no link here"))
    }

    func testDetectorLooksLikeRecipe() {
        XCTAssertTrue(ClipboardDetector.looksLikeRecipe("https://example.com/soup"))
        XCTAssertTrue(ClipboardDetector.looksLikeRecipe("1 cup rice\n2 eggs\n"))
        XCTAssertFalse(ClipboardDetector.looksLikeRecipe("hello world"))
    }

    // MARK: - OCRSplitter

    func testOCRSplitter() {
        let draft = OCRSplitter.split([
            "Cream of Mushroom",
            "8 oz mushrooms",
            "2 cups cream",
            "Simmer 20 minutes.",
        ])
        XCTAssertEqual(draft.title, "Cream of Mushroom")
        XCTAssertEqual(draft.ingredientLines.count, 2)
        XCTAssertEqual(draft.stepLines, ["Simmer 20 minutes."])
    }

    // MARK: - Clip host helper

    func testClipHost() {
        XCTAssertEqual(clipHost(from: "https://www.allrecipes.com/recipe/123"), "www.allrecipes.com")
        XCTAssertEqual(clipHost(from: nil), "caption-only")
    }
}
