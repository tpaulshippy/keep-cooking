// Keep Cooking — Lane 5 Organize
// apps/ios/Export/RecipeExporter.swift
//
// Client-side export mirroring Lane 1 `api/src/export.ts` exactly:
//   JSON (full recipe object) · Markdown · self-contained Schema.org HTML.
// Foundation only — no SwiftData/SwiftUI — so samples can be generated and
// the HTML JSON-LD can be asserted in tests.
//
// Duration format matches the API: `PT<n>M` (prepTime/cookTime).

import Foundation

// MARK: - Input protocol

public protocol ExportableRecipe: AnyObject {
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
    var sourceUrl: String { get }
    var categories: [String] { get }
    var exportIngredients: [ExportableIngredient] { get }
    var exportSteps: [ExportableStep] { get }
}

public struct ExportableIngredient: Sendable {
    public var name: String
    public var display: String
    public init(name: String, display: String) { self.name = name; self.display = display }
    public var text: String { display.isEmpty ? name : display }
}

public struct ExportableStep: Sendable {
    public var position: Int
    public var text: String
    public init(position: Int, text: String) { self.position = position; self.text = text }
}

// MARK: - JSON

/// Full-fidelity JSON export (matches `GET /export/{id}.json` shape).
public func exportJSON<R: ExportableRecipe>(_ r: R) -> String {
    // Build with JSONSerialization to keep key order readable and stable.
    let ings: [[String: Any]] = r.exportIngredients.map { ["name": $0.name, "display": $0.text] }
    let steps: [[String: Any]] = r.exportSteps.sorted { $0.position < $1.position }
        .map { ["position": $0.position, "text": $0.text] }
    var out: [String: Any] = [
        "id": r.recipeId,
        "title": r.title,
        "description": r.recipeDescription,
        "servings": r.servings,
        "categories": r.categories,
        "source": r.source,
        "sourceUrl": r.sourceUrl,
        "ingredients": ings,
        "steps": steps,
    ]
    if let p = r.prepMinutes { out["prepMinutes"] = p }
    if let c = r.cookMinutes { out["cookMinutes"] = c }
    if let rating = r.rating { out["rating"] = rating }
    let data = (try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    return String(data: data, encoding: .utf8) ?? "{}"
}

// MARK: - Markdown

/// Markdown export (matches Lane 1 `recipeToMarkdown` line-for-line style).
public func exportMarkdown<R: ExportableRecipe>(_ r: R) -> String {
    var lines: [String] = ["# \(r.title)", ""]
    if !r.recipeDescription.isEmpty { lines += [r.recipeDescription, ""] }
    lines.append("Servings: \(formatServings(r.servings))")
    if r.prepMinutes != nil || r.cookMinutes != nil {
        lines.append("Time: prep \(r.prepMinutes.map(String.init) ?? "?") min · cook \(r.cookMinutes.map(String.init) ?? "?") min")
    }
    lines += ["", "## Ingredients", ""]
    for ing in r.exportIngredients { lines.append("- \(ing.text)") }
    lines += ["", "## Steps", ""]
    let steps = r.exportSteps.sorted { $0.position < $1.position }
    for (i, s) in steps.enumerated() { lines.append("\(i + 1). \(s.text)") }
    lines.append("")
    return lines.joined(separator: "\n")
}

private func formatServings(_ s: Double) -> String {
    s.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(s)) : String(s)
}

// MARK: - HTML (self-contained Schema.org)

private func escHtml(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

private func escJSON(_ s: String) -> String {
    // JSON-LD lives in a <script> tag: escape `<` so `</script>` can never
    // appear inside a recipe string and break out of the element.
    s.replacingOccurrences(of: "<", with: "\\u003c")
}

/// Self-contained Schema.org HTML export (matches Lane 1 `recipeToHtml`).
/// Offline-safe: no external CSS/JS — only an inline <style> block plus the
/// JSON-LD script. Validates by containing exactly one
/// `application/ld+json` block whose `@type` is `Recipe`.
public func exportHTML<R: ExportableRecipe>(_ r: R) -> String {
    let steps = r.exportSteps.sorted { $0.position < $1.position }
    var jsonLd: [String: Any] = [
        "@context": "https://schema.org",
        "@type": "Recipe",
        "name": r.title,
        "recipeYield": r.servings,
        "recipeIngredient": r.exportIngredients.map { $0.text },
        "recipeInstructions": steps.map { ["@type": "HowToStep", "text": $0.text] },
    ]
    if !r.recipeDescription.isEmpty { jsonLd["description"] = r.recipeDescription }
    if let p = r.prepMinutes { jsonLd["prepTime"] = "PT\(p)M" }
    if let c = r.cookMinutes { jsonLd["cookTime"] = "PT\(c)M" }
    let rawJson = (try? JSONSerialization.data(withJSONObject: jsonLd, options: [.sortedKeys])) ?? Data()
    let jsonString = escJSON(String(data: rawJson, encoding: .utf8) ?? "{}")
    let ings = r.exportIngredients.map { "<li>\(escHtml($0.text))</li>" }.joined()
    let stepsHtml = steps.map { "<li>\(escHtml($0.text))</li>" }.joined()
    let desc = r.recipeDescription.isEmpty ? "" : "<p>\(escHtml(r.recipeDescription))</p>"
    return """
    <!doctype html><html lang="en"><head><meta charset="utf-8">\
    <meta name="viewport" content="width=device-width,initial-scale=1">\
    <title>\(escHtml(r.title))</title>\
    <script type="application/ld+json">\(jsonString)</script>\
    <style>body{font-family:system-ui,sans-serif;max-width:40rem;margin:2rem auto;padding:0 1rem}</style>\
    </head><body><h1>\(escHtml(r.title))</h1>\(desc)\
    <p>Servings: \(escHtml(formatServings(r.servings)))</p>\
    <h2>Ingredients</h2><ul>\(ings)</ul><h2>Steps</h2><ol>\(stepsHtml)</ol></body></html>
    """
}
