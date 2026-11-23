// Smidgen — Library search tests (pure Foundation — no SwiftData, no UI)
//
// Covers the shared engine behind the Recipes tab list (DemoFlows.swift
// `filtered` delegates here via AdvancedFilter + filterRecipes):
//   1. Free-text query matches across title/ingredients/steps (AND tokens).
//   2. Single-category chip narrows to that category (case-insensitive).
//   3. Query + category combine (the list's exact usage).
//   4. Empty query + no category returns everything, title-sorted.
//
// NOTE: same-target convention as the other suites (see CookTests header).

import XCTest

/// Lightweight stand-in for Recipe (mirrors LibraryRecipe).
final class SearchStubRecipe: LibraryRecipe {
    var recipeId: String
    var title: String
    var recipeDescription: String
    var servings: Double = 4
    var prepMinutes: Int? = nil
    var cookMinutes: Int? = nil
    var rating: Double? = nil
    var source: String = ""
    var categories: [String]
    var ingredientNames: [String]
    var stepTexts: [String]

    init(_ id: String, _ title: String, cats: [String] = [],
         ings: [String] = [], steps: [String] = [], desc: String = "")
    {
        recipeId = id; self.title = title; categories = cats
        ingredientNames = ings; stepTexts = steps; recipeDescription = desc
    }
}

final class LibrarySearchTests: XCTestCase {
    private func recipes() -> [SearchStubRecipe] {
        [
            SearchStubRecipe("r1", "Weeknight Miso Salmon", cats: ["dinner", "fish"],
                             ings: ["salmon", "miso", "rice"], steps: ["Bake 20 minutes."]),
            SearchStubRecipe("r2", "Miso Soup", cats: ["Dinner"],
                             ings: ["miso", "tofu"], steps: ["Simmer gently."]),
            SearchStubRecipe("r3", "Blueberry Pancakes", cats: ["breakfast"],
                             ings: ["flour", "blueberries"], steps: ["Flip once."]),
        ]
    }

    func testQueryMatchesAcrossFields() {
        let out = filterRecipes(recipes(), filter: AdvancedFilter(query: "miso"))
        XCTAssertEqual(out.map { $0.recipeId }.sorted(), ["r1", "r2"])
    }

    func testQueryMatchesStepsOnlyTerm() {
        // "bake" appears only in r1's stepTexts (not title/ingredients).
        let out = filterRecipes(recipes(), filter: AdvancedFilter(query: "bake"))
        XCTAssertEqual(out.map { $0.recipeId }, ["r1"])
    }

    func testQueryTokensAreANDed() {
        let out = filterRecipes(recipes(), filter: AdvancedFilter(query: "miso salmon"))
        XCTAssertEqual(out.map { $0.recipeId }, ["r1"])
    }

    func testSingleCategoryChipNarrowsCaseInsensitively() {
        // Chip titles come from stored categories; matching is case-insensitive.
        let out = filterRecipes(recipes(), filter: AdvancedFilter(categories: ["dinner"]))
        XCTAssertEqual(out.map { $0.recipeId }.sorted(), ["r1", "r2"])
    }

    func testQueryPlusCategoryCombines() {
        // The Recipes tab usage: search text + selected chip.
        let out = filterRecipes(recipes(),
                                filter: AdvancedFilter(query: "miso", categories: ["fish"]))
        XCTAssertEqual(out.map { $0.recipeId }, ["r1"])
    }

    func testEmptyFilterReturnsAllTitleSorted() {
        let out = filterRecipes(recipes(), filter: AdvancedFilter())
        XCTAssertEqual(out.map { $0.title },
                       ["Blueberry Pancakes", "Miso Soup", "Weeknight Miso Salmon"])
    }
}
