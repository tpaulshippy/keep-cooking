// Keep Cooking — Lane 3 Capture
// apps/ios/Features/Ingest/IngredientParser.swift
//
// Single-line ingredient parser shared by Clip preview, caption import,
// and OCR scan. Pure value types — fully unit-tested (IngredientParserTests).
//
// Handles: unicode fractions (½ ¼ ¾ ⅓ ⅔ ⅛ ⅜ ⅝ ⅞), ASCII fractions (1/2),
// mixed numbers (1 1/2), ranges (2-3 cloves), decimals, and units:
// tbsp/tsp/cup/g/ml/oz (+ aliases: cups, tablespoon, teaspoon, grams, etc.)

import Foundation

public struct ParsedIngredient: Sendable, Equatable {
    public var quantity: Double?
    public var quantityText: String? // original e.g. "2-3" for ranges
    public var unit: String
    public var name: String
    public var display: String // fraction-rounded display string

    public init(quantity: Double?, quantityText: String? = nil, unit: String, name: String, display: String) {
        self.quantity = quantity; self.quantityText = quantityText
        self.unit = unit; self.name = name; self.display = display
    }
}

public enum IngredientParser {
    // MARK: Unicode fractions

    static let unicodeFractions: [Character: Double] = [
        "½": 0.5, "⅓": 1.0/3.0, "⅔": 2.0/3.0, "¼": 0.25, "¾": 0.75,
        "⅛": 0.125, "⅜": 0.375, "⅝": 0.625, "⅞": 0.875,
        "⅕": 0.2, "⅖": 0.4, "⅗": 0.6, "⅘": 0.8, "⅙": 1.0/6.0, "⅚": 5.0/6.0,
    ]

    /// Canonical unit map: alias (lowercased, punctuation stripped) → canonical.
    static let unitAliases: [String: String] = [
        "tbsp": "tbsp", "tbs": "tbsp", "tablespoon": "tbsp", "tablespoons": "tbsp", "tbsp.": "tbsp",
        "tsp": "tsp", "teaspoon": "tsp", "teaspoons": "tsp", "tsp.": "tsp",
        "cup": "cup", "cups": "cup", "c": "cup",
        "g": "g", "gram": "g", "grams": "g", "gramme": "g",
        "kg": "kg", "ml": "ml", "milliliter": "ml", "millilitre": "ml", "l": "l", "liter": "l", "litre": "l",
        "oz": "oz", "ounce": "oz", "ounces": "oz", "oz.": "oz",
        "lb": "lb", "lbs": "lb", "pound": "lb", "pounds": "lb",
        "clove": "clove", "cloves": "clove",
        "can": "can", "cans": "can", "pack": "pack", "packs": "pack",
        "slice": "slice", "slices": "slice", "pinch": "pinch", "dash": "dash",
    ]

    // MARK: Parse

    /// Parse one ingredient line. Never returns nil — unparseable lines
    /// become ParsedIngredient(quantity: nil, unit: "", name: line).
    public static func parse(_ line: String) -> ParsedIngredient {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ParsedIngredient(quantity: nil, unit: "", name: "", display: trimmed)
        }
        var tokens = trimmed.split(separator: " ").map(String.init)
        guard !tokens.isEmpty else {
            return ParsedIngredient(quantity: nil, unit: "", name: trimmed, display: trimmed)
        }

        // 1) Quantity: try mixed number "1 1/2", range "2-3", unicode, fraction, decimal.
        var quantity: Double?
        var quantityText: String?
        var consumed = 0

        // Mixed number: "<int> <frac|unicode>"
        if tokens.count >= 2,
           let whole = Int(tokens[0]),
           let frac = fractionValue(tokens[1])
        {
            quantity = Double(whole) + frac
            quantityText = "\(tokens[0]) \(tokens[1])"
            consumed = 2
        } else if let r = rangeValue(tokens[0]) {
            quantity = r.midpoint
            quantityText = tokens[0] // keep "2-3" for display
            consumed = 1
        } else if let v = fractionValue(tokens[0]) ?? doubleValue(tokens[0]) {
            quantity = v
            quantityText = tokens[0]
            consumed = 1
        }
        // Unicode attached to digit e.g. "1½" or "2½"
        if quantity == nil, let v = attachedUnicodeValue(tokens[0]) {
            quantity = v.value
            quantityText = tokens[0]
            consumed = 1
        }

        tokens.removeFirst(min(consumed, tokens.count))

        // 2) Unit: next token if it matches a known alias.
        var unit = ""
        if let first = tokens.first, let canon = canonicalUnit(first) {
            unit = canon
            tokens.removeFirst()
        }

        // 3) Rest is the name.
        var name = tokens.joined(separator: " ")
        if quantity == nil && unit.isEmpty {
            name = trimmed // nothing parsed — keep whole line as name
        }
        name = name.trimmingCharacters(in: .whitespaces)

        let display = buildDisplay(quantity: quantity, quantityText: quantityText, unit: unit, name: name, fallback: trimmed)
        return ParsedIngredient(quantity: quantity, quantityText: quantityText, unit: unit, name: name, display: display)
    }

    /// Parse many lines (caption / OCR block), skipping blanks.
    public static func parseLines(_ text: String) -> [ParsedIngredient] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { parse($0) }
    }

    // MARK: - Helpers (internal for tests)

    static func fractionValue(_ token: String) -> Double? {
        let t = token.trimmingCharacters(in: .whitespaces)
        if t.count == 1, let v = unicodeFractions[Character(t)] { return v }
        if t.count == 1, let scalar = t.unicodeScalars.first {
            // vulgar fractions U+00BC–U+00BE
            switch scalar.value {
            case 0x00BC: return 0.25
            case 0x00BD: return 0.5
            case 0x00BE: return 0.75
            default: break
            }
        }
        // ASCII a/b
        if t.contains("/") {
            let parts = t.split(separator: "/")
            if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d != 0 {
                return n / d
            }
        }
        return nil
    }

    static func doubleValue(_ token: String) -> Double? {
        Double(token.replacingOccurrences(of: ",", with: "."))
    }

    /// Range "2-3" or "2–3" (en dash) → midpoint. Returns nil otherwise.
    static func rangeValue(_ token: String) -> (low: Double, high: Double, midpoint: Double)? {
        let norm = token.replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
        let parts = norm.split(separator: "-")
        guard parts.count == 2,
              let lo = Double(parts[0]), let hi = Double(parts[1])
        else { return nil }
        return (lo, hi, (lo + hi) / 2.0)
    }

    /// Digit(s) with attached unicode fraction, e.g. "1½" → 1.5.
    static func attachedUnicodeValue(_ token: String) -> (value: Double, whole: Int)? {
        guard let last = token.last,
              let frac = unicodeFractions[last] ?? fractionValue(String(last))
        else { return nil }
        let head = String(token.dropLast())
        if head.isEmpty { return (frac, 0) }
        if let whole = Int(head) { return (Double(whole) + frac, whole) }
        if let whole = Double(head) { return (whole + frac, Int(whole)) }
        return nil
    }

    static func canonicalUnit(_ token: String) -> String? {
        let key = token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
        return unitAliases[key]
    }

    static func buildDisplay(quantity: Double?, quantityText: String?, unit: String, name: String, fallback: String) -> String {
        guard !name.isEmpty else { return fallback }
        var parts: [String] = []
        if let qt = quantityText, !qt.isEmpty {
            parts.append(qt)
        } else if let q = quantity {
            parts.append(fractionString(q))
        }
        if !unit.isEmpty { parts.append(unit) }
        parts.append(name)
        if parts.count == 1 && quantity == nil && unit.isEmpty { return fallback }
        return parts.joined(separator: " ")
    }

    /// Format a Double as a fraction-rounded string (1.5 → "1 1/2").
    static func fractionString(_ value: Double) -> String {
        let denominators = [2, 3, 4, 8]
        let whole = Int(value)
        let frac = value - Double(whole)
        if frac < 0.03 { return "\(whole)" }
        var best = (n: 0, d: 1, err: Double.greatestFiniteMagnitude)
        for d in denominators {
            let n = Int((frac * Double(d)).rounded())
            let err = abs(Double(n) / Double(d) - frac)
            if err < best.err { best = (n, d, err) }
        }
        if best.n == 0 { return "\(whole)" }
        if best.n == best.d { return "\(whole + 1)" }
        let f = "\(best.n)/\(best.d)"
        return whole == 0 ? f : "\(whole) \(f)"
    }
}
