// Smidgen — Lane 3 Capture
// apps/ios/Features/Ingest/IngestHumanPolishTests.swift
//
// Regression tests for the ingest human-polish pass (PR #5 review):
// server-error copy mapping, warning copy, and warnings decoding.
// Add this file to the iOS unit-test target alongside
// IngredientParserTests.swift. No network, no SwiftData.

import XCTest

// NOTE: when these files live in the same test target, no import is needed.
// If your app target is named Smidgen, use `@testable import Smidgen` instead.

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
        let text = clipWarningText(for: "jsonld-missing")
        XCTAssertFalse(text.contains("jsonld-missing"))
        XCTAssertFalse(text.isEmpty)
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
}
