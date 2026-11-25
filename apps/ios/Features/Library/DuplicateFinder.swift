// Keep Cooking — Lane 5 Organize
// apps/ios/Features/Library/DuplicateFinder.swift
//
// Fuzzy duplicate detection + merge. Foundation only (no SwiftData/SwiftUI)
// so it compiles standalone (`swiftc`) and is unit-tested directly.
//
// Why four signals? The frozen seeds prove titles alone are not enough:
//   recipe-14 "Miso Salmon Weeknight"  ~= recipe-01 "Weeknight Miso Salmon"
//       -> token-order-insensitive title match (Jaccard).
//   recipe-15 "Choc Chip Cookies"      ~= recipe-09 "Chocolate Chip Cookies"
//       -> abbreviation-insensitive match ("choc" -> "chocolate").
//   recipe-13 "dup of 09"              ~= recipe-09 (shares NO title tokens and
//       NO distinctive content — all 15 seeds share one stub ingredient/step).
//       -> explicit import reference ("dup of <id-fragment>").
// So a pair is a duplicate when ANY of these hold:
//   (a) title token Jaccard >= 0.5 after normalization, or
//   (b) normalized-title Levenshtein similarity >= 0.8, or
//   (c) stripped copy-markers agree ("Copy of X", "X (1)"), or
//   (d) explicit reference ("dup of 09" names the other record), or
//   (e) content signature (ingredients + steps) Jaccard >= 0.8 with >= 6
//       content tokens per side (degenerate stubs never merge on content).
// All three seeded dupes are caught (see DuplicateFinderTests).

import Foundation

// MARK: - Input protocol

/// Minimal surface the finder needs. `Recipe` conforms in LibraryModels.swift.
public protocol DuplicableRecipe: AnyObject {
    // NOTE: @Model classes are main-actor confined and explicitly non-Sendable
    // (see Core/Models.swift) — like Lane 2's Syncable, this stays AnyObject.
    var recipeId: String { get }
    var title: String { get }
    var rating: Double? { get }
    var categories: [String] { get }
    /// Lowercased ingredient display/name strings are fine.
    var ingredientNames: [String] { get }
    var stepTexts: [String] { get }
    /// Photo key quality proxy: nil/empty = no photo.
    var photoOriginal: String? { get }
    var photoThumb: String? { get }
}

// MARK: - Normalization

/// Abbreviation expansions applied before tokenizing titles.
private let abbreviationExpansions: [String: String] = [
    "choc": "chocolate",
    "veg": "vegetable",
    "veggie": "vegetable",
    "parm": "parmesan",
    "mozz": "mozzarella",
]

/// Lowercases, strips punctuation, expands common abbreviations, and splits
/// on whitespace. "Choc-Chip Cookies!" -> ["chocolate", "chip", "cookies"].
public func titleTokens(_ title: String) -> [String] {
    let lowered = title.lowercased()
    let cleaned = String(lowered.map { $0.isLetter || $0.isNumber ? $0 : " " })
    return cleaned.split(separator: " ").map { word in
        let w = String(word)
        return abbreviationExpansions[w] ?? w
    }
}

/// Normalized title string used for edit-distance comparison.
public func normalizedTitle(_ title: String) -> String {
    titleTokens(title).joined(separator: " ")
}

// MARK: - Similarity primitives

/// Jaccard similarity over token multisets, 0...1.
public func jaccard(_ a: [String], _ b: [String]) -> Double {
    guard !a.isEmpty || !b.isEmpty else { return 1 }
    var countsA: [String: Int] = [:]
    var countsB: [String: Int] = [:]
    for t in a { countsA[t, default: 0] += 1 }
    for t in b { countsB[t, default: 0] += 1 }
    var intersection = 0
    var union = 0
    for key in Set(countsA.keys).union(countsB.keys) {
        intersection += min(countsA[key] ?? 0, countsB[key] ?? 0)
        union += max(countsA[key] ?? 0, countsB[key] ?? 0)
    }
    guard union > 0 else { return 1 }
    return Double(intersection) / Double(union)
}

/// Levenshtein distance over characters.
public func levenshtein(_ a: String, _ b: String) -> Int {
    let s = Array(a), t = Array(b)
    if s.isEmpty { return t.count }
    if t.isEmpty { return s.count }
    var prev = Array(0 ... t.count)
    for i in 1 ... s.count {
        var cur = [i] + Array(repeating: 0, count: t.count)
        for j in 1 ... t.count {
            cur[j] = s[i - 1] == t[j - 1]
                ? prev[j - 1]
                : 1 + min(prev[j - 1], prev[j], cur[j - 1])
        }
        prev = cur
    }
    return prev[t.count]
}

/// 1 - (distance / maxLength), so identical strings score 1.
public func levenshteinSimilarity(_ a: String, _ b: String) -> Double {
    let longest = max(a.count, b.count)
    guard longest > 0 else { return 1 }
    return 1 - Double(levenshtein(a, b)) / Double(longest)
}

// MARK: - Pair scoring

public struct DuplicateThresholds: Sendable {
    public var titleJaccard: Double
    public var titleEditSimilarity: Double
    public var contentJaccard: Double
    public init(titleJaccard: Double = 0.5, titleEditSimilarity: Double = 0.8, contentJaccard: Double = 0.8) {
        self.titleJaccard = titleJaccard
        self.titleEditSimilarity = titleEditSimilarity
        self.contentJaccard = contentJaccard
    }
}

/// Content signature: normalized ingredient + step tokens.
func contentTokens<R: DuplicableRecipe>(_ r: R) -> [String] {
    let ings = r.ingredientNames.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
    let steps = r.stepTexts.flatMap { $0.lowercased().split(whereSeparator: \.isWhitespace).map(String.init) }
    return ings + steps
}

/// True when the pair counts as duplicates under any signal.
public func isDuplicatePair<R: DuplicableRecipe>(
    _ a: R, _ b: R, thresholds: DuplicateThresholds = DuplicateThresholds()
) -> Bool {
    if a.recipeId == b.recipeId { return false }
    let ta = titleTokens(a.title), tb = titleTokens(b.title)
    if jaccard(ta, tb) >= thresholds.titleJaccard { return true }
    if levenshteinSimilarity(normalizedTitle(a.title), normalizedTitle(b.title)) >= thresholds.titleEditSimilarity {
        return true
    }
    // Explicit import-style references: "dup of 09", "copy of X", "X (1)".
    // Stripped titles that agree, or a fragment that identifies the other
    // record (id suffix / title mention), count as duplicates.
    if strippedCopyTitle(a.title) == strippedCopyTitle(b.title),
       !strippedCopyTitle(a.title).isEmpty { return true }
    if referencesOther(title: a.title, other: b) || referencesOther(title: b.title, other: a) { return true }
    // Content signal needs non-trivial content on both sides so degenerate
    // stubs (one shared ingredient + one shared step, as in the frozen
    // seeds) never merge on content alone.
    let ca = contentTokens(a), cb = contentTokens(b)
    if ca.count >= 6, cb.count >= 6, jaccard(ca, cb) >= thresholds.contentJaccard { return true }
    return false
}

/// Removes importer copy markers: "copy of X" -> "X", "X (1)" -> "X",
/// "X - copy" -> "X". A bare "dup of 09" strips to "" (handled by
/// referenceFragment instead) — never force-unwrap, never crash on odd input.
public func strippedCopyTitle(_ title: String) -> String {
    // Strip "(N)" copy-numbers BEFORE normalization: normalizedTitle drops
    // all punctuation, so a post-normalization `\(\d+\)` regex could never
    // match ("Salsa (1)" normalizes to "salsa 1", parens already gone).
    let deNumbered = title.replacingOccurrences(of: #"\s*\(\d+\)\s*$"#, with: "", options: .regularExpression)
    var s = normalizedTitle(deNumbered)
    for prefix in ["copy of ", "copy ", "duplicate of ", "duplicate "] {
        if s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)); break }
    }
    s = s.replacingOccurrences(of: #"\s*\(\d+\)\s*$"#, with: "", options: .regularExpression)
    s = s.replacingOccurrences(of: #"\s+-\s+copy\s*$"#, with: "", options: .regularExpression)
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Parses "dup of <ref>" / "duplicate of <ref>" / "copy of <ref>" titles.
/// Returns the raw reference fragment ("09" for "dup of 09"), else nil.
public func referenceFragment(_ title: String) -> String? {
    let s = normalizedTitle(title).trimmingCharacters(in: .whitespacesAndNewlines)
    let pattern = #"^(?:dup(?:licate)?|copy)(?:\s+of)?\s+(.+)$"#
    guard let range = s.range(of: pattern, options: .regularExpression) else { return nil }
    let ref = String(s[range]).replacingOccurrences(of: pattern, with: "$1", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return ref.isEmpty ? nil : ref
}

/// True when `title` explicitly references `other` ("dup of 09" -> the seed
/// whose id ends in 000009). Fragment must be >= 2 chars; it matches an id
/// suffix, a title-token hit, or a title substring (len >= 3).
func referencesOther<R: DuplicableRecipe>(title: String, other: R) -> Bool {
    guard let ref = referenceFragment(title), ref.count >= 2 else { return false }
    let lowerRef = ref.lowercased()
    if other.recipeId.lowercased().hasSuffix(lowerRef) { return true }
    if lowerRef.count >= 3, normalizedTitle(other.title).contains(lowerRef) { return true }
    if titleTokens(other.title).contains(lowerRef) { return true }
    return false
}

// MARK: - Grouping (union-find over pairs)

/// Groups recipes into duplicate clusters (each group has >= 2 members).
/// Deterministic: groups and members are sorted by id.
public func findDuplicateGroups<R: DuplicableRecipe>(
    _ recipes: [R], thresholds: DuplicateThresholds = DuplicateThresholds()
) -> [[R]] {
    let sorted = recipes.sorted { $0.recipeId < $1.recipeId }
    var parent: [String: String] = [:]
    for r in sorted { parent[r.recipeId] = r.recipeId }
    func find(_ x: String) -> String {
        var root = x
        while parent[root] != root { root = parent[root] ?? root }
        return root
    }
    func union(_ x: String, _ y: String) {
        let rx = find(x), ry = find(y)
        if rx != ry { parent[max(rx, ry)] = min(rx, ry) }
    }
    for i in sorted.indices {
        for j in sorted.indices where j > i {
            if isDuplicatePair(sorted[i], sorted[j], thresholds: thresholds) {
                union(sorted[i].recipeId, sorted[j].recipeId)
            }
        }
    }
    var clusters: [String: [R]] = [:]
    for r in sorted { clusters[find(r.recipeId), default: []].append(r) }
    return clusters.values.filter { $0.count >= 2 }
        .sorted { ($0.first?.recipeId ?? "") < ($1.first?.recipeId ?? "") }
}

// MARK: - Merge

/// Merge instruction produced for a duplicate group: which record survives
/// and what it absorbs. Callers apply it to SwiftData (delete losers, update
/// survivor) — see LibraryViews DuplicateReviewView.
public struct DuplicateMergePlan: Sendable {
    /// Survivor id.
    public var survivorId: String
    /// Ids to tombstone/delete after merging.
    public var absorbedIds: [String]
    /// Union of categories across the group (sorted, deduped, lowercased).
    public var mergedCategories: [String]
    /// Union of ingredient names (case-insensitive dedup, sorted).
    public var mergedIngredientNames: [String]
    /// Best (longest non-empty) photo key in the group, if any.
    public var bestPhotoOriginal: String?
    public var bestPhotoThumb: String?
    /// Highest rating in the group, if any.
    public var bestRating: Double?

    /// Title of the survivor (longest original title — most descriptive).
    public var survivorTitle: String
}

/// Canonical ingredient identity for merge/search: the real `name`.
/// `display` is quantity-only by design ("3 tbsp") and must never stand in
/// for the name — using it as identity unions quantity strings, and writing
/// those back as names permanently loses ingredient names.
public func ingredientIdentity(name: String, display: String) -> String {
    name.isEmpty ? display : name
}

/// Picks the survivor (most ingredients, then best photo, then highest rating,
/// then lowest id for determinism) and unions ingredients + categories.
/// Best photo = longest non-empty photo key (highest-resolution R2 key);
/// union ingredients dedup case-insensitively.
public func planMerge<R: DuplicableRecipe>(group: [R]) -> DuplicateMergePlan? {
    guard group.count >= 2 else { return nil }
    let ranked = group.sorted {
        if $0.ingredientNames.count != $1.ingredientNames.count {
            return $0.ingredientNames.count > $1.ingredientNames.count
        }
        let pa = $0.photoOriginal?.isEmpty == false ? 1 : 0
        let pb = $1.photoOriginal?.isEmpty == false ? 1 : 0
        if pa != pb { return pa > pb }
        if ($0.rating ?? -1) != ($1.rating ?? -1) { return ($0.rating ?? -1) > ($1.rating ?? -1) }
        return $0.recipeId < $1.recipeId
    }
    guard let survivor = ranked.first else { return nil }
    var seenIngs = Set<String>()
    var mergedIngs: [String] = []
    for r in ranked {
        for name in r.ingredientNames {
            let key = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, seenIngs.insert(key).inserted {
                mergedIngs.append(name.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }
    mergedIngs.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    let mergedCats = Array(Set(ranked.flatMap { $0.categories.map { $0.lowercased() } })).sorted()
    let photoCandidates = ranked.compactMap { $0.photoOriginal }.filter { !$0.isEmpty }
    let bestPhoto = photoCandidates.max(by: { $0.count < $1.count })
    let thumbCandidates = ranked.compactMap { $0.photoThumb }.filter { !$0.isEmpty }
    let bestThumb = thumbCandidates.max(by: { $0.count < $1.count })
    let bestRating = ranked.compactMap { $0.rating }.max()
    let survivorTitle = ranked.map { $0.title }.max(by: { $0.count < $1.count }) ?? survivor.title
    return DuplicateMergePlan(
        survivorId: survivor.recipeId,
        absorbedIds: ranked.dropFirst().map { $0.recipeId }.sorted(),
        mergedCategories: mergedCats,
        mergedIngredientNames: mergedIngs,
        bestPhotoOriginal: bestPhoto,
        bestPhotoThumb: bestThumb,
        bestRating: bestRating,
        survivorTitle: survivorTitle
    )
}
