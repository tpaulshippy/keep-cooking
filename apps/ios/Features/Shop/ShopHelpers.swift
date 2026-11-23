// Smidgen — Lane 4 Shop: aisle sorting + pantry helpers (pure)
//   - aisleSortKey: canonical grocery order so lists group by aisle.
//   - Pantry expiry/low-stock helpers for locations + expiry + low-stock UI.

import Foundation

// MARK: - Aisle sort

/// Canonical aisle order. Unknown aisles sort after known ones, alphabetically.
private let canonicalAisles = [
    "produce", "bakery", "deli", "meat", "seafood",
    "dairy", "frozen", "canned", "dry goods", "pasta",
    "baking", "spices", "snacks", "beverages", "household",
]

/// Sort key: (known-aisle rank, aisle name, item name), all lowercased.
public func aisleSortKey(aisle: String, name: String) -> (Int, String, String) {
    let a = aisle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if a.isEmpty { return (Int.max - 1, "", name.lowercased()) } // unfiled: last-ish
    if let rank = canonicalAisles.firstIndex(of: a) { return (rank, a, name.lowercased()) }
    return (canonicalAisles.count, a, name.lowercased())
}

/// Normalized aisle key: trimmed + lowercased, so values that differ only
/// by case or surrounding whitespace group into one section.
public func normalizedAisleKey(_ aisle: String) -> String {
    aisle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

public func aisleGroupedNames<T>(items: [T], aisleOf: (T) -> String, nameOf: (T) -> String) -> [String] {
    // Dedupe on the normalized key; keep the first-seen raw value as the
    // section representative so identical inputs render byte-identically.
    var seen: [String: String] = [:]
    for item in items {
        let raw = aisleOf(item)
        let key = normalizedAisleKey(raw)
        if seen[key] == nil { seen[key] = raw }
    }
    return seen.values.sorted { l, r in
        let kl = aisleSortKey(aisle: l, name: "")
        let kr = aisleSortKey(aisle: r, name: "")
        if kl.0 != kr.0 { return kl.0 < kr.0 }
        return kl.1 < kr.1
    }
}

// MARK: - Pantry helpers

public enum ExpiryStatus: String, Sendable, Equatable {
    case expired
    case expiringSoon // within 7 days
    case fresh
    case noDate
}

/// Classifies an expiry date relative to `now` (default: today).
public func expiryStatus(expiresAt: Date?, now: Date = Date()) -> ExpiryStatus {
    guard let expiresAt else { return .noDate }
    if expiresAt < now { return .expired }
    let weekOut = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now
    if expiresAt <= weekOut { return .expiringSoon }
    return .fresh
}

/// True when `quantity` is at/below the low-stock threshold.
/// Both are free-text ("2", "500g"); compares numeric prefixes when possible,
/// otherwise falls back to non-empty equality (any stock beats empty).
public func isLowStock(quantity: String, threshold: String) -> Bool {
    let q = quantity.trimmingCharacters(in: .whitespacesAndNewlines)
    let t = threshold.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty { return false } // no threshold set
    if q.isEmpty { return true } // nothing left
    if let qn = Double(q.prefix(while: { $0.isNumber || $0 == "." })),
       let tn = Double(t.prefix(while: { $0.isNumber || $0 == "." })),
       qn > 0 || tn > 0
    {
        return qn <= tn
    }
    return false
}
