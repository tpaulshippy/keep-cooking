// Keep Cooking — Lane 5 Organize
// apps/ios/Features/Library/DuplicateFinderTests.swift
//
// XCTest suite for DuplicateFinder (pure Foundation — no SwiftData).
// Covers: all 3 seeded dupes caught, no false-positive cluster across
// distinct seeds, merge keeps best photo + unions ingredients.
//
// Seeded dupes (packages/contracts/seed):
//   recipe-13 "dup of 09"             -> dupe of recipe-09 (explicit reference)
//   recipe-14 "Miso Salmon Weeknight" -> dupe of recipe-01 (title Jaccard)
//   recipe-15 "Choc Chip Cookies"      -> dupe of recipe-09 (abbrev expansion)
//
// NOTE: all 15 frozen seeds share byte-identical stub content (1x salt +
// "Cook and serve."), so the content signal deliberately requires >= 6
// content tokens per side and never fires on the seeds — 13 is caught by
// the reference signal, 14/15 by title signals. Distinct seeds must not cluster.

import XCTest

/// Lightweight stand-in for Recipe (mirrors DuplicableRecipe).
/// A class because the Lane 5 protocols refine AnyObject (like Lane 2's
/// Syncable — @Model types are main-actor confined, never Sendable).
final class StubRecipe: DuplicableRecipe {
    var recipeId: String
    var title: String
    var rating: Double?
    var categories: [String]
    var ingredientNames: [String]
    var stepTexts: [String]
    var photoOriginal: String?
    var photoThumb: String?

    init(_ id: String, _ title: String, ings: [String] = ["1 tsp salt"], steps: [String] = ["Cook and serve."],
         rating: Double? = 4, cats: [String] = ["dinner"], photo: String? = nil)
    {
        recipeId = id; self.title = title; self.rating = rating
        categories = cats; ingredientNames = ings; stepTexts = steps
        photoOriginal = photo; photoThumb = photo.map { _ in "thumb.jpg" }
    }
}

/// The 15 frozen seeds, reduced to finder inputs (ids + titles match
/// packages/contracts/seed/*.json exactly).
func seedStubRecipes() -> [StubRecipe] {
    [
        StubRecipe("..000001", "Weeknight Miso Salmon", cats: ["dinner", "fish"],
                   photo: "photos/..000001/original.jpg"),
        StubRecipe("..000002", "Margherita Pizza"),
        StubRecipe("..000003", "Chicken Tikka Masala"),
        StubRecipe("..000004", "Avocado Toast"),
        StubRecipe("..000005", "Blueberry Pancakes"),
        StubRecipe("..000006", "Caesar Salad"),
        StubRecipe("..000007", "Beef Tacos"),
        StubRecipe("..000008", "Tomato Basil Soup"),
        StubRecipe("..000009", "Chocolate Chip Cookies", cats: ["dessert", "baking"],
                   photo: "photos/..000009/original.jpg"),
        StubRecipe("..000010", "Banana Bread"),
        StubRecipe("..000011", "Garlic Butter Pasta"),
        StubRecipe("..000012", "Greek Grain Bowl"),
        StubRecipe("..000013", "dup of 09", ings: ["1 tsp salt"], steps: ["Cook and serve."]),
        StubRecipe("..000014", "Miso Salmon Weeknight"),
        StubRecipe("..000015", "Choc Chip Cookies"),
    ]
}

final class DuplicateFinderTests: XCTestCase {
    func testCatchesAllThreeSeededDupes() {
        let groups = findDuplicateGroups(seedStubRecipes())
        let clustered = Set(groups.flatMap { $0.map { $0.recipeId } })
        XCTAssertTrue(clustered.contains("..000013"), "seed 13 'dup of 09' must be flagged (reference signal)")
        XCTAssertTrue(clustered.contains("..000014"), "seed 14 'Miso Salmon Weeknight' must cluster with seed 01")
        XCTAssertTrue(clustered.contains("..000015"), "seed 15 'Choc Chip Cookies' must cluster with seed 09")
        // Each dupe must share a group with its original.
        func groupOf(_ id: String) -> Set<String> {
            Set(groups.first(where: { $0.contains(where: { $0.recipeId == id }) })?.map { $0.recipeId } ?? [])
        }
        XCTAssertTrue(groupOf("..000014").contains("..000001"))
        XCTAssertTrue(groupOf("..000015").contains("..000009"))
        XCTAssertTrue(groupOf("..000013").contains("..000009"))
    }

    func testDistinctSeedsDoNotCluster() {
        // Distinct mains must never land in the same group.
        let mains = seedStubRecipes().filter { ["..000002", "..000003", "..000004", "..000006", "..000007",
                                                "..000008", "..000010", "..000011", "..000012"].contains($0.recipeId) }
        let groups = findDuplicateGroups(mains)
        XCTAssertTrue(groups.isEmpty, "distinct recipes must not cluster, got \(groups)")
    }

    func testSelfNeverMatches() {
        let r = StubRecipe("..000009", "Chocolate Chip Cookies")
        XCTAssertFalse(isDuplicatePair(r, r))
    }

    func testMergeKeepsBestPhotoAndUnionsIngredients() {
        let a = StubRecipe("..000009", "Chocolate Chip Cookies", ings: ["2 cups flour", "1 tsp salt"],
                           cats: ["dessert"], photo: "photos/short.jpg")
        let b = StubRecipe("..000015", "Choc Chip Cookies", ings: ["1 TSP Salt", "1 cup choc chips"],
                           cats: ["baking"], photo: "photos/a-much-longer-higher-resolution-key.jpg")
        guard let plan = planMerge(group: [a, b]) else { return XCTFail("expected a merge plan") }
        // Best photo = longest non-empty key.
        XCTAssertEqual(plan.bestPhotoOriginal, "photos/a-much-longer-higher-resolution-key.jpg")
        // Union ingredients, case-insensitive dedup: salt appears once.
        XCTAssertEqual(plan.mergedIngredientNames.count, 3)
        XCTAssertEqual(plan.mergedIngredientNames.filter { $0.lowercased().contains("salt") }.count, 1)
        // Union categories.
        XCTAssertEqual(Set(plan.mergedCategories), ["baking", "dessert"])
        XCTAssertEqual(plan.absorbedIds.count, 1)
        XCTAssertFalse(plan.absorbedIds.contains(plan.survivorId))
    }

    func testMergeNeedsAPair() {
        XCTAssertNil(planMerge(group: [StubRecipe("..000001", "Solo")]))
    }

    func testIngredientIdentityPrefersName() {
        // Seeds carry BOTH a name ("white miso") and a quantity-only
        // display ("3 tbsp"): identity must be the name, or merges union
        // quantity strings and write them back as names (data loss).
        XCTAssertEqual(ingredientIdentity(name: "white miso", display: "3 tbsp"), "white miso")
        XCTAssertEqual(ingredientIdentity(name: "salt", display: ""), "salt")
        // Legacy display-only rows (empty name) fall back to display.
        XCTAssertEqual(ingredientIdentity(name: "", display: "3 tbsp"), "3 tbsp")
    }

    func testMergeUnionKeepsFullNames() {
        // Union identity is the real name: quantity-only display strings
        // must never become merged "names".
        let a = StubRecipe("..000009", "Chocolate Chip Cookies",
                           ings: ["all-purpose flour", "salt"])
        let b = StubRecipe("..000015", "Choc Chip Cookies",
                           ings: ["Salt", "chocolate chips"])
        guard let plan = planMerge(group: [a, b]) else { return XCTFail("expected a merge plan") }
        XCTAssertEqual(Set(plan.mergedIngredientNames.map { $0.lowercased() }),
                       ["all-purpose flour", "salt", "chocolate chips"])
    }

    func testAbbreviationNormalization() {
        XCTAssertEqual(titleTokens("Choc-Chip Cookies!"), ["chocolate", "chip", "cookies"])
        XCTAssertGreaterThanOrEqual(jaccard(titleTokens("Choc Chip Cookies"), titleTokens("Chocolate Chip Cookies")), 0.5)
    }

    func testReferenceSignal() {
        XCTAssertEqual(referenceFragment("dup of 09"), "09")
        XCTAssertEqual(strippedCopyTitle("Salsa (1)"), "salsa")
        XCTAssertEqual(strippedCopyTitle("Copy of Salsa"), "salsa")
        let target = StubRecipe("..000009", "Chocolate Chip Cookies")
        XCTAssertTrue(isDuplicatePair(StubRecipe("..000013", "dup of 09"), target))
        // Non-matching reference must not fire.
        XCTAssertFalse(isDuplicatePair(StubRecipe("..000099", "dup of 42"), target))
    }
}
