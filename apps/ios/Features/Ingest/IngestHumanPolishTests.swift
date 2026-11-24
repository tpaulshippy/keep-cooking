// Keep Cooking — Lane 3 Capture
// apps/ios/Features/Ingest/IngestHumanPolishTests.swift
//
// Regression tests for the ingest human-polish pass (PR #5 review):
// server-error copy mapping, warning copy, and warnings decoding.
// Add this file to the iOS unit-test target alongside
// IngredientParserTests.swift. No network, no SwiftData.

import XCTest

// NOTE: when these files live in the same test target, no import is needed.
// If your app target is named KeepCooking, use `@testable import KeepCooking` instead.

final class IngestHumanPolishTests: XCTestCase {
    // MARK: - Server-error copy

    func testHttpStatusMapsToServiceError() {
        XCTAssertEqual(
            clipServerErrorMessage(for: ClipClientError.httpStatus(500)),
            "The recipe service returned an error (500). Try again later."
        )
    }

    func testHttpStatusCodeIsSurfaced() {
        XCTAssertEqual(
            clipServerErrorMessage(for: ClipClientError.httpStatus(429)),
            "The recipe service returned an error (429). Try again later."
        )
    }

    func testNonHttpErrorsKeepGenericCopy() {
        XCTAssertNil(clipServerErrorMessage(for: ClipClientError.badURL))
        XCTAssertNil(
            clipServerErrorMessage(
                for: ClipClientError.decode(NSError(domain: "test", code: 1))
            )
        )
    }

    // MARK: - Warning copy

    func testJsonldMissingWarningIsHumanized() {
        XCTAssertEqual(
            clipWarningText(for: "jsonld-missing"),
            "No recipe card found on the page — details were read from the page text instead."
        )
    }

    func testUnknownWarningPassesThrough() {
        XCTAssertEqual(clipWarningText(for: "low-confidence"), "low-confidence")
    }

    // MARK: - Warnings decoding

    func testClipReportDecodesWarnings() throws {
        let json = """
        {"strategy":"reader","confidence":0.7,"warnings":["jsonld-missing"],\
        "recipe":{"title":"Soup"}}
        """.data(using: .utf8)!
        let report = try JSONDecoder().decode(ClipReport.self, from: json)
        XCTAssertEqual(report.warnings, ["jsonld-missing"])
    }

    func testClipReportWithoutWarningsDecodesNil() throws {
        let json = """
        {"strategy":"jsonld","confidence":0.9,"recipe":{"title":"Soup"}}
        """.data(using: .utf8)!
        let report = try JSONDecoder().decode(ClipReport.self, from: json)
        XCTAssertNil(report.warnings)
    }

    // MARK: - Steps header bounds

    func testStepsHeaderClampsHighIndex() {
        XCTAssertEqual(IngestStepsHeader(current: 99).current, 2)
    }

    func testStepsHeaderClampsNegativeIndex() {
        XCTAssertEqual(IngestStepsHeader(current: -1).current, 0)
    }

    func testStepsHeaderKeepsValidIndex() {
        XCTAssertEqual(IngestStepsHeader(current: 1).current, 1)
    }

    // MARK: - Title gating

    func testNewlineOnlyTitleIsNotSavable() {
        XCTAssertFalse(isSavableTitle("\n  \n"))
        XCTAssertFalse(isSavableTitle("   "))
        XCTAssertTrue(isSavableTitle("Soup"))
    }

    func testCleanTitleTrimsWhitespaceAndNewlines() {
        XCTAssertEqual(cleanTitle("  Soup\n"), "Soup")
    }
}
