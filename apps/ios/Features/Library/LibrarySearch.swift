// Smidgen — Lane 5 Organize
// apps/ios/Features/Library/LibrarySearch.swift
//
// Pure full-text + advanced recipe filtering. Foundation only (no SwiftData,
// no SwiftUI) so it is unit-testable and compilable standalone with swiftc.
//
// A recipe participates via the `LibraryRecipe` protocol; the SwiftData
// `Recipe` model conforms in LibraryModels.swift. Views pass @Model objects
// straight in — no DTO mapping at call sites.

import Foundation

// MARK: - Input protocol (anything searchable)

/// Minimal surface the search engine needs. `Recipe` conforms in
/// LibraryModels.swift. Tests use a struct stub.
public protocol LibraryRecipe: AnyObject {
    // NOTE: @Model classes are main-actor confined and explicitly non-Sendable
    // (see Core/Models.swift) — like Lane 2's Syncable, this stays AnyObject.
    var recipeId: String { get }
    var title: String { get }
    var recipeDescription: String { get }
    var servings: Double { get }
    var prepMinutes: Int? { get }
    var cookMinutes: Int? { get }
    var rating: Double? { get }
    var source: String { get }
    var categories: [String] { get }
    var ingredientNames: [String] { get }
    var stepTexts: [String] { get }
}

public extension LibraryRecipe {
    /// Total hands-on time when both halves are known, else whichever exists.
    var totalMinutes: Int? {
        switch (prepMinutes, cookMinutes) {
        case let (p?, c?): return p + c
        case let (p?, nil): return p
        case let (nil, c?): return c
        case (nil, nil): return nil
        }
    }

    /// Lowercased haystack for full-text matching: title + description +
    /// ingredients + categories + source.
    var searchHaystack: String {
        ([title, recipeDescription, source] + categories + ingredientNames + stepTexts)
            .joined(separator: " ").lowercased()
    }
}

// MARK: - Filter definition

/// Advanced filter backing Library search + SavedSearch.
/// All fields are optional; nil/empty means "no constraint".
public struct AdvancedFilter: Sendable, Codable, Hashable {
    public var query: String
    /// Every term must appear (AND).
    public var includeTerms: [String]
    /// No term may appear (NOT).
    public var excludeTerms: [String]
    /// Keep recipes whose total time is known and <= this (minutes).
    public var maxTotalMinutes: Int?
    /// Keep recipes rated >= this (0...5). Unrated recipes never match a rating filter.
    public var minRating: Double?
    /// Case-insensitive substring match on `source`.
    public var sourceContains: String?
    /// At least one must match (case-insensitive). Empty = no constraint.
    public var categories: [String]

    public init(
        query: String = "",
        includeTerms: [String] = [],
        excludeTerms: [String] = [],
        maxTotalMinutes: Int? = nil,
        minRating: Double? = nil,
        sourceContains: String? = nil,
        categories: [String] = []
    ) {
        self.query = query
        self.includeTerms = includeTerms
        self.excludeTerms = excludeTerms
        self.maxTotalMinutes = maxTotalMinutes
        self.minRating = minRating
        self.sourceContains = sourceContains
        self.categories = categories
    }

    public var isEmpty: Bool {
        query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && includeTerms.isEmpty && excludeTerms.isEmpty
            && maxTotalMinutes == nil && minRating == nil
            && (sourceContains ?? "").isEmpty && categories.isEmpty
    }
}

// MARK: - Matching

/// True when `recipe` satisfies every constraint in `filter`.
public func matchesFilter<R: LibraryRecipe>(_ recipe: R, filter: AdvancedFilter) -> Bool {
    let haystack = recipe.searchHaystack

    // Free-text query: every whitespace-separated token must appear.
    let queryTokens = filter.query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    for token in queryTokens where !haystack.contains(token) { return false }

    for term in filter.includeTerms {
        let t = term.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty, !haystack.contains(t) { return false }
    }
    for term in filter.excludeTerms {
        let t = term.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty, haystack.contains(t) { return false }
    }

    if let cap = filter.maxTotalMinutes {
        guard let total = recipe.totalMinutes, total <= cap else { return false }
    }
    if let floor = filter.minRating {
        guard let rating = recipe.rating, rating >= floor else { return false }
    }
    if let src = filter.sourceContains?.trimmingCharacters(in: .whitespacesAndNewlines), !src.isEmpty {
        if !recipe.source.lowercased().contains(src.lowercased()) { return false }
    }
    if !filter.categories.isEmpty {
        let have = Set(recipe.categories.map { $0.lowercased() })
        let want = filter.categories.map { $0.lowercased() }
        if !want.contains(where: { have.contains($0) }) { return false }
    }
    return true
}

/// Filters + ranks: matches first, then title-ascending for stability.
public func filterRecipes<R: LibraryRecipe>(_ recipes: [R], filter: AdvancedFilter) -> [R] {
    recipes.filter { matchesFilter($0, filter: filter) }
        .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
}
