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

// MARK: - Paprika export (P0 — native format, §1.4 of paprika spec)

/// Sanitizes a title for use as a `.paprikarecipe` ZIP member name:
/// filesystem-hostile chars become `-`, matching the ExportView temp-file rule.
public func paprikaSanitizedFilename(_ title: String) -> String {
    let safe = title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
    let collapsed = String(safe).replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
    let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return trimmed.isEmpty ? "recipe" : String(trimmed.prefix(60))
}

/// `created` stamp in Paprika's `"YYYY-MM-DD HH:MM:SS"` shape (UTC).
public func paprikaCreatedString(_ date: Date = Date()) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(secondsFromGMT: 0)
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f.string(from: date)
}

/// Human duration Paprika expects (`"20 minutes"`, `"1 hr 15 min"`).
/// Returns nil when minutes is nil so callers can emit JSON null.
public func paprikaHumanMinutes(_ m: Int?) -> String? {
    guard let m else { return nil }
    if m < 60 { return "\(m) minutes" }
    let h = m / 60, r = m % 60
    return r == 0 ? "\(h) hr" : "\(h) hr \(r) min"
}

/// Full-fidelity Paprika JSON object for one recipe (§1.4).
/// - `uid`: stable identity (reused `paprikaUid` on round-trip). Uppercase UUID.
/// - `servingsText`: raw servings string when known (e.g. `"4-6 servings"`),
///   else the numeric servings stringified.
/// - `created`: Paprika `created` stamp; defaults to now.
public func exportPaprikaJSON<R: ExportableRecipe>(
    _ r: R,
    uid: String? = nil,
    servingsText: String? = nil,
    created: String? = nil
) -> String {
    let id = (uid ?? UUID().uuidString).uppercased()
    let ings = r.exportIngredients.map { $0.text }.joined(separator: "\n")
    let dirs = r.exportSteps.sorted { $0.position < $1.position }.map { $0.text }.joined(separator: "\n")
    let servings = servingsText ?? (r.servings.truncatingRemainder(dividingBy: 1) == 0
        ? String(Int(r.servings)) : String(r.servings))
    // NOTE: ExportableRecipe carries no photo bytes, so `photo`/`photo_data`
    // are null here. A pipeline WITH photo bytes must set `photo` to
    // `${UID}.jpg` whenever `photo_data` is present — a `photo_data` with a
    // null/absent `photo` crashes Paprika mid-import (measured).
    let obj: [String: Any] = [
        "uid": id,
        "hash": "",
        "name": r.title,
        "description": r.recipeDescription,
        "ingredients": ings,
        "directions": dirs,
        "notes": "",
        "categories": r.categories,
        "servings": servings,
        "prep_time": paprikaHumanMinutes(r.prepMinutes) as Any,
        "cook_time": paprikaHumanMinutes(r.cookMinutes) as Any,
        "total_time": NSNull(),
        "difficulty": NSNull(),
        "rating": Int(r.rating ?? 0),
        "nutritional_info": "",
        "source": r.source,
        "source_url": r.sourceUrl,
        "image_url": NSNull(),
        "photo": NSNull(),
        "photo_large": NSNull(),
        "photo_hash": "",
        "photo_data": NSNull(),
        "photos": [],
        "on_favorites": false,
        "scale": NSNull(),
        "cookbook": "",
        "created": created ?? paprikaCreatedString(),
        "on_grocery_list": false,
        "in_trash": false,
        "is_pinned": false,
        "deleted": false,
    ]
    let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    return String(data: data, encoding: .utf8) ?? "{}"
}

// MARK: - Paprika gzip + ZIP container (§1.1)

#if canImport(Compression)
import Compression
#endif

/// CRC-32 (IEEE) over Data — gzip trailer + ZIP headers. Pure Swift so the
/// exporter stays dependency-free (no ZIPFoundation/SSZipArchive in-tree).
func paprikaCRC32(_ data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
        }
    }
    return crc ^ 0xFFFF_FFFF
}

func paprikaAppendLE(_ data: inout Data, _ v: UInt16) {
    data.append(UInt8(v & 0xFF)); data.append(UInt8((v >> 8) & 0xFF))
}

func paprikaAppendLE(_ data: inout Data, _ v: UInt32) {
    data.append(UInt8(v & 0xFF)); data.append(UInt8((v >> 8) & 0xFF))
    data.append(UInt8((v >> 16) & 0xFF)); data.append(UInt8((v >> 24) & 0xFF))
}

#if canImport(Compression)
/// Raw-deflate `data` with the Compression framework, returned exactly as
/// the encoder produced it. (The buffer API's framing is used verbatim —
/// empirically raw deflate on current OSes — and the in-repo gunzip accepts
/// both raw and zlib-wrapped bodies, so export/import agree everywhere.)
/// Nil when compression fails — callers fall back to storing raw JSON (the
/// Paprika parser accepts plain-JSON members).
func paprikaRawDeflate(_ data: Data) -> Data? {
    guard !data.isEmpty else { return Data() }
    return data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
        guard let srcPtr = src.baseAddress else { return nil }
        let dstCap = max(64, data.count + 64)
        let dstPtr = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCap)
        defer { dstPtr.deallocate() }
        let n = compression_encode_buffer(
            dstPtr, dstCap,
            srcPtr.assumingMemoryBound(to: UInt8.self), data.count,
            nil, COMPRESSION_ZLIB)
        guard n > 0 else { return nil }
        return Data(bytes: dstPtr, count: n)
    }
}
#endif

/// Wraps raw (or already-deflated) bytes in a gzip member. When the
/// Compression framework is available the JSON is deflated first; otherwise
/// the member is stored raw — still importable per §1.1 (plain-JSON fallback).
public func paprikaGzipMember(jsonData: Data) -> Data {
    #if canImport(Compression)
    let body = paprikaRawDeflate(jsonData) ?? jsonData
    #else
    let body = jsonData
    #endif
    var out = Data([0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03])
    out.append(body)
    var crc = paprikaCRC32(jsonData), size = UInt32(jsonData.count)
    withUnsafeBytes(of: &crc) { out.append(contentsOf: $0) }
    withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
    return out
}

/// Builds a `.paprikarecipes` ZIP (stored entries, one gzip member per
/// recipe named `<sanitized title>.paprikarecipe`). Manual writer — no
/// third-party ZIP dependency in the project.
public func exportPaprikaArchive(_ recipes: [any ExportableRecipe]) -> Data {
    var zip = Data()
    var central = Data()
    for r in recipes {
        let memberName = paprikaSanitizedFilename(r.title) + ".paprikarecipe"
        let nameBytes = Array(memberName.utf8)
        let jsonData = Data(exportPaprikaJSON(r).utf8)
        let member = paprikaGzipMember(jsonData: jsonData)
        let crc = paprikaCRC32(member)
        let localOffset = UInt32(zip.count)
        // Local file header (method 0 = stored; the member itself is gzipped).
        paprikaAppendLE(&zip, UInt32(0x0403_4B50))
        paprikaAppendLE(&zip, UInt16(20))
        paprikaAppendLE(&zip, UInt16(0))
        paprikaAppendLE(&zip, UInt16(0))
        paprikaAppendLE(&zip, UInt16(0))
        paprikaAppendLE(&zip, UInt16(0))
        paprikaAppendLE(&zip, crc)
        paprikaAppendLE(&zip, UInt32(member.count))
        paprikaAppendLE(&zip, UInt32(member.count))
        paprikaAppendLE(&zip, UInt16(nameBytes.count))
        paprikaAppendLE(&zip, UInt16(0))
        zip.append(contentsOf: nameBytes)
        zip.append(member)
        // Central directory entry.
        paprikaAppendLE(&central, UInt32(0x0201_4B50))
        paprikaAppendLE(&central, UInt16(20))
        paprikaAppendLE(&central, UInt16(20))
        paprikaAppendLE(&central, UInt16(0))
        paprikaAppendLE(&central, UInt16(0))
        paprikaAppendLE(&central, UInt16(0))
        paprikaAppendLE(&central, UInt16(0))
        paprikaAppendLE(&central, crc)
        paprikaAppendLE(&central, UInt32(member.count))
        paprikaAppendLE(&central, UInt32(member.count))
        paprikaAppendLE(&central, UInt16(nameBytes.count))
        paprikaAppendLE(&central, UInt16(0))
        paprikaAppendLE(&central, UInt16(0))
        paprikaAppendLE(&central, UInt16(0))
        paprikaAppendLE(&central, UInt16(0))
        paprikaAppendLE(&central, UInt32(0))
        paprikaAppendLE(&central, localOffset)
        central.append(contentsOf: nameBytes)
    }
    let centralOffset = UInt32(zip.count)
    zip.append(central)
    let centralSize = UInt32(central.count)
    // End of central directory.
    paprikaAppendLE(&zip, UInt32(0x0605_4B50))
    paprikaAppendLE(&zip, UInt16(0))
    paprikaAppendLE(&zip, UInt16(0))
    paprikaAppendLE(&zip, UInt16(recipes.count))
    paprikaAppendLE(&zip, UInt16(recipes.count))
    paprikaAppendLE(&zip, centralSize)
    paprikaAppendLE(&zip, centralOffset)
    paprikaAppendLE(&zip, UInt16(0))
    return zip
}

// MARK: - YAML export (P0 — JSON-compatible YAML, §2)

/// Paprika YAML export. YAML is a superset of JSON, so the object is
/// serialized as JSON with a `.yml` extension — zero indentation risk
/// (emission strategy per spec §2). `on_favorites` round-trips as bool but
/// is a measured no-op on Paprika iOS import.
public func exportYaml<R: ExportableRecipe>(_ r: R) -> String {
    let obj: [String: Any] = [
        "name": r.title,
        "servings": r.servings.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(r.servings)) : String(r.servings),
        "source": r.source,
        "source_url": r.sourceUrl,
        "prep_time": paprikaHumanMinutes(r.prepMinutes) as Any,
        "cook_time": paprikaHumanMinutes(r.cookMinutes) as Any,
        "on_favorites": false,
        "categories": r.categories,
        "nutritional_info": "",
        "difficulty": NSNull(),
        "rating": Int(r.rating ?? 0),
        "notes": "",
        "photo": NSNull(),
        "ingredients": r.exportIngredients.map { $0.text }.joined(separator: "\n"),
        "directions": r.exportSteps.sorted { $0.position < $1.position }.map { $0.text }.joined(separator: "\n"),
    ]
    let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    return String(data: data, encoding: .utf8) ?? "{}"
}

/// Multi-recipe YAML file (YAML list = JSON array of the per-recipe objects).
public func exportYamlArray(_ recipes: [any ExportableRecipe]) -> String {
    let arr: [[String: Any]] = recipes.map { r in [
        "name": r.title,
        "servings": r.servings.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(r.servings)) : String(r.servings),
        "source": r.source,
        "source_url": r.sourceUrl,
        "prep_time": paprikaHumanMinutes(r.prepMinutes) as Any,
        "cook_time": paprikaHumanMinutes(r.cookMinutes) as Any,
        "on_favorites": false,
        "categories": r.categories,
        "nutritional_info": "",
        "difficulty": NSNull(),
        "rating": Int(r.rating ?? 0),
        "notes": "",
        "photo": NSNull(),
        "ingredients": r.exportIngredients.map { $0.text }.joined(separator: "\n"),
        "directions": r.exportSteps.sorted { $0.position < $1.position }.map { $0.text }.joined(separator: "\n"),
    ] }
    let data = (try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    return String(data: data, encoding: .utf8) ?? "[]"
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
