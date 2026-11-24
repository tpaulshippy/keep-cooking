// Keep Cooking — Lane 4 Cook: recipe scaling (pure, no SwiftData, no network)
// Matches Lane 1 POST /recipes/:id/scale { servings: 0.25..100 }.
// Factor is clamped to 0.25x–4x per Lane 4 spec; quantities render as
// fraction-rounded display strings (nearest 1/4, unicode fractions).

import Foundation

/// Scaling factor from base servings to target servings, clamped to 0.25x–4x.
public func scaleFactor(baseServings: Double, targetServings: Double) -> Double {
    guard baseServings > 0, targetServings > 0 else { return 1 }
    let raw = targetServings / baseServings
    return min(4, max(0.25, raw))
}

/// Scaled quantity for one ingredient (nil stays nil — "to taste" etc.).
public func scaledQuantity(_ quantity: Double?, factor: Double) -> Double? {
    guard let quantity else { return nil }
    return quantity * factor
}

/// Rounds a value to the nearest quarter (0.25 steps).
public func roundToQuarter(_ value: Double) -> Double {
    (value * 4).rounded() / 4
}

/// Unicode fraction glyphs for exact quarters/halves/thirds/eighths.
private let fractionGlyphs: [(value: Double, glyph: String)] = [
    (0.125, "⅛"), (0.25, "¼"), (0.333, "⅓"), (0.375, "⅜"),
    (0.5, "½"), (0.625, "⅝"), (0.666, "⅔"), (0.75, "¾"), (0.875, "⅞"),
]

/// Formats a quantity as a fraction-rounded display string, e.g. 1.5 -> "1½".
/// Whole numbers render without fractions; values < 1 render glyph-only.
public func fractionDisplayString(for value: Double) -> String {
    let rounded = roundToQuarter(value)
    let whole = Int(rounded)
    let frac = rounded - Double(whole)
    // Snap the fractional part to the nearest known glyph.
    var best: String?
    var bestDist = Double.greatestFiniteMagnitude
    for entry in fractionGlyphs {
        let d = abs(entry.value - frac)
        if d < bestDist { bestDist = d; best = entry.glyph }
    }
    if frac < 0.06 { return "\(whole)" } // effectively whole
    guard let glyph = best, bestDist < 0.13 else {
        // Fall back to a 2-decimal string rather than a wrong fraction.
        return String(format: "%.2f", rounded)
    }
    if whole == 0 { return glyph }
    return "\(whole)\(glyph)"
}

/// Full scaled display line for one ingredient, e.g. "1½ cups flour".
/// - Parameters:
///   - name: ingredient name; quantity: base quantity (nil = unmeasured);
///   - unit: base unit ("" when none); factor: clamped scale factor.
public func scaledDisplay(name: String, quantity: Double?, unit: String, factor: Double) -> String {
    guard let q = scaledQuantity(quantity, factor: factor) else { return name }
    let qty = fractionDisplayString(for: q)
    if unit.isEmpty { return "\(qty) \(name)" }
    return "\(qty) \(unit) \(name)"
}
