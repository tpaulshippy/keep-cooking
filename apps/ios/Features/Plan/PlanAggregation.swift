// Smidgen — Lane 4 Plan: week aggregation + webcal feed (pure)
//   - aggregateWeekToList: plans for a week -> merged shopping-list lines,
//     quantities scaled (plan.servings vs recipe.servings) and summed by
//     (lowercased name + unit). Display strings use RecipeScaler fractions.
//   - planFeedURL: https://.../plans/feed.ics -> webcal:// subscribe URL.

import Foundation

/// One recipe's contribution to a shopping list.
public struct PlanGroceryInput: Sendable, Hashable {
    public var name: String
    public var quantity: Double?
    public var unit: String
    /// Servings the recipe as written makes.
    public var baseServings: Double
    /// Servings the plan entry calls for (nil = as written).
    public var targetServings: Double?
    public var recipeId: String?

    public init(name: String, quantity: Double?, unit: String,
                baseServings: Double, targetServings: Double? = nil, recipeId: String? = nil) {
        self.name = name; self.quantity = quantity; self.unit = unit
        self.baseServings = baseServings; self.targetServings = targetServings
        self.recipeId = recipeId
    }
}

/// One merged shopping-list line.
public struct AggregatedItem: Sendable, Hashable, Equatable {
    public var name: String // display-cased from first occurrence
    public var unit: String
    public var totalQuantity: Double? // nil when all inputs unmeasured
    public var recipeIds: [String]
    public init(name: String, unit: String, totalQuantity: Double?, recipeIds: [String] = []) {
        self.name = name; self.unit = unit
        self.totalQuantity = totalQuantity; self.recipeIds = recipeIds
    }

    /// "1½ cups flour" / "Salt" when unmeasured.
    public var display: String {
        guard let q = totalQuantity else { return name }
        return scaledDisplay(name: name, quantity: q, unit: unit, factor: 1)
    }
}

/// Aggregates a week's grocery inputs into merged list lines.
/// Same (name.lowercased(), unit.lowercased()) merge; unmeasured inputs
/// contribute a nil-quantity line that never absorbs measured ones.
public func aggregateWeekToList(_ inputs: [PlanGroceryInput]) -> [AggregatedItem] {
    var measured: [String: AggregatedItem] = [:]
    var measuredOrder: [String] = []
    var unmeasured: [AggregatedItem] = []

    for input in inputs {
        let target = input.targetServings ?? input.baseServings
        let factor = scaleFactor(baseServings: input.baseServings, targetServings: target)
        let key = "\(input.name.lowercased())\u{1F}\(input.unit.lowercased())"
        guard let q = scaledQuantity(input.quantity, factor: factor) else {
            if !unmeasured.contains(where: { $0.name.lowercased() == input.name.lowercased() }) {
                unmeasured.append(AggregatedItem(name: input.name, unit: input.unit,
                                                 totalQuantity: nil,
                                                 recipeIds: input.recipeId.map { [$0] } ?? []))
            }
            continue
        }
        if var existing = measured[key] {
            existing.totalQuantity = (existing.totalQuantity ?? 0) + q
            if let rid = input.recipeId, !existing.recipeIds.contains(rid) {
                existing.recipeIds.append(rid)
            }
            measured[key] = existing
        } else {
            measured[key] = AggregatedItem(name: input.name, unit: input.unit, totalQuantity: q,
                                           recipeIds: input.recipeId.map { [$0] } ?? [])
            measuredOrder.append(key)
        }
    }
    return measuredOrder.compactMap { measured[$0] } + unmeasured
}

// MARK: - webcal feed

/// Builds the subscribe URL for Lane 1 GET /plans/feed.ics.
/// `https://api.example.com/plans/feed.ics?...` -> `webcal://...` so iOS
/// opens Calendar's subscribe sheet.
public func planFeedSubscribeURL(baseURL: URL, householdId: String) -> URL? {
    var comps = URLComponents(url: baseURL.appendingPathComponent("/plans/feed.ics"),
                              resolvingAgainstBaseURL: false)
    comps?.queryItems = [URLQueryItem(name: "householdId", value: householdId)]
    guard let httpsURL = comps?.url else { return nil }
    var webcal = URLComponents(url: httpsURL, resolvingAgainstBaseURL: false)
    if webcal?.scheme == "https" { webcal?.scheme = "webcal" }
    else if webcal?.scheme == "http" { webcal?.scheme = "webcal" }
    return webcal?.url
}
