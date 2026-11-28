// Keep Cooking — File import (Paprika parity, P0 + P1 best-effort)
// apps/ios/Features/Ingest/PaprikaImport.swift
//
// Offline-first file parser for Paprika native/YAML/HTML exports plus the
// third-party formats Paprika itself imports (P1 best-effort). Foundation
// only — no SwiftData/SwiftUI — so it typechecks with plain `swiftc` and is
// unit-testable without an Xcode target.
//
// Coverage (see /tmp/paprika-spec.md):
//   P0: `.paprikarecipes` (ZIP of gzipped JSON, plain-JSON members accepted),
//       `.paprikarecipe` (bare gzip, bare JSON, multi-member gzip stream),
//       `.yml`/`.yaml` (JSON-as-YAML + a minimal YAML-subset reader),
//       HTML export (JSON-LD Recipe → hRecipe → visible headings).
//   P1 (best-effort, warnings surface gaps): MX2/MXP/MZ2, MealMaster MMF,
//       Living Cookbook FDX/FDXZ, Pepperplate/Copy-Me-That ZIPs, Yum XML,
//       My CookBook MCB, Recipe Manager TXT.
//   P2/P3 opaque blobs (.ysr/.mgourmet/.dvo/.hbox/.sqlite/.rbox/.ckbk/.lcb…)
//       are rejected with a re-export guidance message, never silently dropped.
//
// Photos: `photo_data` (+`photos[].data`) base64 → `photoData` (first photo
// wins). `image_url` is never fetched — it is usually dead.

import Foundation

// MARK: - Parsed model (transport-agnostic)

public struct ImportIngredient: Sendable {
    public var name: String
    public var display: String
    public var position: Int
    public init(name: String, display: String, position: Int) {
        self.name = name; self.display = display; self.position = position
    }
}

public struct ImportStep: Sendable {
    public var position: Int
    public var text: String
    public init(position: Int, text: String) {
        self.position = position; self.text = text
    }
}

public struct ParsedRecipe: Sendable {
    public var paprikaUid: String?
    public var title: String
    public var recipeDescription: String
    public var servings: Double
    public var servingsText: String?
    public var prepMinutes: Int?
    public var cookMinutes: Int?
    public var totalMinutes: Int?
    public var categories: [String]
    public var rating: Double?
    public var difficulty: String?
    public var nutritionText: String?
    public var source: String
    public var sourceUrl: String
    public var notes: String
    public var ingredients: [ImportIngredient]
    public var steps: [ImportStep]
    public var isFavorite: Bool
    public var cookbook: String?
    public var createdAt: Date?
    public var photoData: Data?
    public var photoFilename: String?
    public var warnings: [String]

    public init(title: String) {
        self.title = title
        self.recipeDescription = ""
        self.servings = 4
        self.categories = []
        self.source = ""
        self.sourceUrl = ""
        self.notes = ""
        self.ingredients = []
        self.steps = []
        self.isFavorite = false
        self.warnings = []
    }

    /// Normalized Paprika JSON object (uid upsert key). Kept for lossless
    /// export round-trips; the server import takes raw file bytes instead
    /// (see encodeImportBody), never this object.
    /// Photo bytes ride along as `photo_data` so the server round-trips them.
    public func paprikaJSONObject() -> [String: Any] {
        var obj: [String: Any] = [
            "name": title,
            "description": recipeDescription,
            "ingredients": ingredients.map { $0.display }.joined(separator: "\n"),
            "directions": steps.map { $0.text }.joined(separator: "\n"),
            "notes": notes,
            "categories": categories,
            "servings": servingsText ?? String(servings),
            "source": source,
            "source_url": sourceUrl,
            "on_favorites": isFavorite,
            "rating": rating.map { Int($0) } as Any,
            "nutritional_info": nutritionText as Any,
            "difficulty": difficulty as Any,
            "cookbook": cookbook as Any,
        ]
        if let u = paprikaUid { obj["uid"] = u }
        if let p = prepMinutes { obj["prep_time"] = "\(p) minutes" }
        if let c = cookMinutes { obj["cook_time"] = "\(c) minutes" }
        if let t = totalMinutes { obj["total_time"] = "\(t) minutes" }
        if let ph = photoData {
            obj["photo"] = photoFilename ?? "photo.jpg"
            obj["photo_data"] = ph.base64EncodedString()
        }
        return obj
    }
}

public struct ParsedFile: Sendable {
    public var recipes: [ParsedRecipe]
    public var cookbookHint: String?
    public var warnings: [String]
    public init(recipes: [ParsedRecipe] = [], cookbookHint: String? = nil, warnings: [String] = []) {
        self.recipes = recipes; self.cookbookHint = cookbookHint; self.warnings = warnings
    }
}

// MARK: - Scalar parsers (§1.3 transforms)

public enum PaprikaScalars {
    /// Leading number/fraction/range: "4-6 servings"→4, "1 pie"→1,
    /// "1 1/2 cups"→1.5, "1/2 lb"→0.5. Nil when no leading number.
    public static func servings(_ raw: String?) -> (Double, String?)? {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let text = raw.trimmingCharacters(in: .whitespaces)
        var scanner = text
        // Range "4-6": take the leading value.
        if let dash = scanner.firstIndex(of: "-"),
           String(scanner[..<dash]).trimmingCharacters(in: .whitespaces).range(of: #"^\d+(\.\d+)?$"#, options: .regularExpression) != nil {
            scanner = String(scanner[..<dash])
        }
        // Mixed fraction "1 1/2".
        if let m = scanner.range(of: #"^(\d+)\s+(\d+)\s*/\s*(\d+)"#, options: .regularExpression) {
            let parts = scanner[m].split(whereSeparator: { $0 == " " || $0 == "/" }).compactMap { Double($0) }
            if parts.count == 3, parts[2] != 0 { return (parts[0] + parts[1] / parts[2], raw) }
        }
        if let m = scanner.range(of: #"^(\d+)\s*/\s*(\d+)"#, options: .regularExpression) {
            let parts = scanner[m].split(separator: "/").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2, parts[1] != 0 { return (parts[0] / parts[1], raw) }
        }
        if let m = scanner.range(of: #"^(\d+(\.\d+)?)"#, options: .regularExpression),
           let v = Double(scanner[m]) { return (v, raw) }
        return (4, raw) // Free text ("a pinch", "1 pie" w/o parse) keeps raw.
    }

    /// Free-text + ISO-8601 durations → minutes. "1 hr 15 min"→75, "1:30"→90.
    public static func minutes(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        // ISO-8601 "PT1H30M" / "P1DT2H".
        if text.hasPrefix("p") {
            var total = 0, num = ""
            var inTime = false
            for ch in text.dropFirst() {
                if ch == "t" { inTime = true; continue }
                if ch.isNumber || ch == "." { num.append(ch); continue }
                guard let v = Double(num) else { num = ""; continue }
                switch ch {
                case "d": total += Int(v * 1440)
                case "h": total += Int(v * 60)
                case "m" where inTime: total += Int(v)
                case "s": total += Int((v / 60).rounded())
                default: break
                }
                num = ""
            }
            return total > 0 ? total : nil
        }
        // Clock "1:30".
        if let m = text.range(of: #"^(\d+):(\d{1,2})(?::(\d{1,2}))?$"#, options: .regularExpression) {
            let p = text[m].split(separator: ":").compactMap { Int($0) }
            if p.count == 2 { return p[0] * 60 + p[1] }
            if p.count == 3 { return p[0] * 60 + p[1] }
        }
        // Human text: scan number+unit pairs.
        var total = 0.0, found = false
        let re = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s*(hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)\b"#, options: .caseInsensitive)
        let ns = text as NSString
        re?.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, m.numberOfRanges == 3 else { return }
            let v = Double(ns.substring(with: m.range(at: 1))) ?? 0
            let u = ns.substring(with: m.range(at: 2)).lowercased()
            found = true
            if u.hasPrefix("h") { total += v * 60 }
            else if u.hasPrefix("s") && !u.hasPrefix("sec") { total += v / 60 }
            else if u.hasPrefix("sec") { total += v / 60 }
            else { total += v }
        }
        if found { return max(1, Int(total.rounded())) }
        // Bare number = minutes.
        if let v = Double(text) { return max(1, Int(v.rounded())) }
        return nil
    }

    /// Directions → steps: blank-line boundaries first, else single newlines.
    /// Strips leading "1. "/"1) "/"1 " numbering (CookTrace parity).
    public static func steps(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        let paras = raw.components(separatedBy: .newlines)
        let hasBlank = paras.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        let chunks: [String]
        if hasBlank {
            var groups: [[String]] = [[]]
            for line in paras {
                if line.trimmingCharacters(in: .whitespaces).isEmpty { groups.append([]) }
                else { groups[groups.count - 1].append(line) }
            }
            chunks = groups.map { $0.joined(separator: " ") }
        } else {
            chunks = paras
        }
        return chunks.map { line in
            var s = line.trimmingCharacters(in: .whitespaces)
            if let m = s.range(of: #"^\d+[.\)\-:]\s+"#, options: .regularExpression) { s = String(s[m.upperBound...]) }
            return s.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }

    public static func rating(_ v: Any?) -> Double? {
        if let i = v as? Int { return i > 0 ? Double(min(i, 5)) : nil }
        if let d = v as? Double { return d > 0 ? min(d, 5) : nil }
        if let n = v as? NSNumber { let i = n.intValue; return i > 0 ? Double(min(i, 5)) : nil }
        return nil
    }

    public static func bool(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.intValue != 0 }
        if let s = v as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return ["1", "yes", "true", "y", "on"].contains(t)
        }
        return false
    }

    public static func categories(_ v: Any?) -> [String] {
        if let a = v as? [String] { return a.filter { !$0.isEmpty } }
        if let a = v as? [Any] { return a.compactMap { $0 as? String }.filter { !$0.isEmpty } }
        if let s = v as? String {
            return s.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return []
    }

    /// "YYYY-MM-DD HH:MM:SS" (+ `dateAdded` alias, ISO-8601 fallback).
    public static func created(_ dict: [String: Any]) -> Date? {
        let raw = (dict["created"] as? String) ?? (dict["dateAdded"] as? String)
        guard let raw else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        for fmt in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ssXXXXX", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: raw) { return d }
        }
        return nil
    }
}

// MARK: - DEFLATE inflater (pure Swift, no Compression dependency)

/// Minimal gzip/ZIP-deflate reader: stored/fixed/dynamic Huffman + LZ77.
/// Needed because Paprika members are gzip, and `Compression` only speaks
/// zlib — this works on every platform with zero dependencies.
enum PaprikaInflate {
    struct BitReader {
        var bytes: [UInt8]
        var bytePos = 0
        var bitPos = 0
        init(_ data: Data) { bytes = Array(data) }
        mutating func bits(_ n: Int) -> Int? {
            var out = 0, shift = 0, need = n
            while need > 0 {
                guard bytePos < bytes.count else { return nil }
                let avail = 8 - bitPos
                let take = min(avail, need)
                out |= Int((bytes[bytePos] >> bitPos) & UInt8((1 << take) - 1)) << shift
                bitPos += take
                if bitPos == 8 { bytePos += 1; bitPos = 0 }
                shift += take; need -= take
            }
            return out
        }
        mutating func align() { if bitPos != 0 { bytePos += 1; bitPos = 0 } }
    }

    struct HuffTree {
        var codes: [Int: (bits: Int, sym: Int)] = [:] // keyed lookup per length
        var byLen: [Int: [Int: Int]] = [:] // len -> code -> sym
        static func build(lengths: [Int]) -> HuffTree? {
            var t = HuffTree()
            let maxBits = lengths.max() ?? 0
            guard maxBits <= 15 else { return nil }
            var blCount = [Int](repeating: 0, count: 16)
            for l in lengths where l > 0 { blCount[l] += 1 }
            var code = 0
            var nextCode = [Int](repeating: 0, count: 16)
            for b in 1..<16 { code = (code + blCount[b - 1]) << 1; nextCode[b] = code }
            for (sym, len) in lengths.enumerated() where len > 0 {
                let c = nextCode[len]; nextCode[len] += 1
                // Reverse `len` bits (DEFLATE packs codes LSB-first).
                var rev = 0
                for i in 0..<len { rev |= ((c >> i) & 1) << (len - 1 - i) }
                t.byLen[len, default: [:]][rev] = sym
            }
            return t
        }
        func decode(_ r: inout BitReader) -> Int? {
            var code = 0
            for len in 1...15 {
                guard let b = r.bits(1) else { return nil }
                code |= b << (len - 1)
                // `code` is the raw LSB-first value straight off the wire,
                // which is exactly how build(lengths:) keyed the table.
                if let sym = byLen[len]?[code] { return sym }
            }
            return nil
        }
    }

    static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    static let distBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577]
    static let distExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    /// Inflate a raw DEFLATE stream.
    static func inflateRaw(_ data: Data) -> Data? {
        var r = BitReader(data)
        var out = [UInt8]()
        out.reserveCapacity(max(1024, data.count * 2))
        var isFinal = false
        while !isFinal {
            guard let bfinal = r.bits(1), let btype = r.bits(2) else { return nil }
            isFinal = bfinal == 1
            switch btype {
            case 0:
                r.align()
                guard let len = r.bits(16), let nlen = r.bits(16), len ^ 0xFFFF == nlen else { return nil }
                for _ in 0..<len {
                    guard r.bytePos < r.bytes.count else { return nil }
                    out.append(r.bytes[r.bytePos]); r.bytePos += 1
                }
            case 1, 2:
                let litTree: HuffTree?
                let distTree: HuffTree?
                if btype == 1 {
                    var lit = [Int](repeating: 0, count: 288)
                    for i in 0..<144 { lit[i] = 8 }
                    for i in 144..<256 { lit[i] = 9 }
                    for i in 256..<280 { lit[i] = 7 }
                    for i in 280..<288 { lit[i] = 8 }
                    litTree = HuffTree.build(lengths: lit)
                    distTree = HuffTree.build(lengths: [Int](repeating: 5, count: 32))
                } else {
                    guard let hlit = r.bits(5), let hdist = r.bits(5), let hclen = r.bits(4) else { return nil }
                    let order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
                    var clLens = [Int](repeating: 0, count: 19)
                    for i in 0..<(hclen + 4) {
                        guard let v = r.bits(3) else { return nil }
                        clLens[order[i]] = v
                    }
                    guard let clTree = HuffTree.build(lengths: clLens) else { return nil }
                    let total = (hlit + 257) + (hdist + 1)
                    var lens: [Int] = []
                    while lens.count < total {
                        guard let sym = clTree.decode(&r) else { return nil }
                        if sym <= 15 { lens.append(sym) }
                        else if sym == 16 {
                            guard let rep = r.bits(2), let last = lens.last else { return nil }
                            lens += [Int](repeating: last, count: rep + 3)
                        } else if sym == 17 {
                            guard let rep = r.bits(3) else { return nil }
                            lens += [Int](repeating: 0, count: rep + 3)
                        } else if sym == 18 {
                            guard let rep = r.bits(7) else { return nil }
                            lens += [Int](repeating: 0, count: rep + 11)
                        } else { return nil }
                    }
                    litTree = HuffTree.build(lengths: Array(lens.prefix(hlit + 257)))
                    distTree = HuffTree.build(lengths: Array(lens.dropFirst(hlit + 257)))
                }
                guard let lt = litTree, let dt = distTree else { return nil }
                var done = false
                while !done {
                    guard let sym = lt.decode(&r) else { return nil }
                    if sym < 256 { out.append(UInt8(sym)) }
                    else if sym == 256 { done = true }
                    else {
                        let li = sym - 257
                        guard li < lengthBase.count else { return nil }
                        guard let ex = r.bits(lengthExtra[li]) else { return nil }
                        let len = lengthBase[li] + ex
                        guard let dsym = dt.decode(&r), dsym < distBase.count else { return nil }
                        guard let dex = r.bits(distExtra[dsym]) else { return nil }
                        let dist = distBase[dsym] + dex
                        guard dist <= out.count else { return nil }
                        for _ in 0..<len { out.append(out[out.count - dist]) }
                    }
                }
            default:
                return nil
            }
        }
        return Data(out)
    }

    /// Split a possibly-concatenated gzip stream into members. `1F 8B` can
    /// occur inside compressed data, so candidates are validated by
    /// ISIZE-verified inflation (shortest valid slice wins) instead of
    /// blindly slicing on the magic (FreeMyRecipes multi-member parity).
    static func splitGzipMembers(_ data: Data) -> [Data] {
        let b = Array(data)
        var starts: [Int] = []
        var i = 0
        while i + 1 < b.count {
            if b[i] == 0x1F, b[i + 1] == 0x8B { starts.append(i); i += 2 } else { i += 1 }
        }
        guard !starts.isEmpty else { return [] }
        // Fast path: the whole thing is one valid member.
        if starts.count == 1, starts[0] == 0, gunzipVerified(data) != nil { return [data] }
        var out: [Data] = []
        var idx = 0
        while idx < starts.count {
            let s = starts[idx]
            // Candidate ends: next few magic offsets, then EOF (bounded so a
            // pathological file can't go quadratic).
            var ends = Array(starts[(idx + 1)...].prefix(8))
            ends.append(b.count)
            var advanced = false
            for e in ends where e > s + 18 {
                if gunzipVerified(Data(b[s..<e])) != nil {
                    out.append(Data(b[s..<e]))
                    // Consume every start offset inside the accepted slice.
                    while idx < starts.count, starts[idx] < e { idx += 1 }
                    advanced = true
                    break
                }
            }
            if !advanced { idx += 1 }
        }
        return out
    }

    /// Gunzip one member (header flags FEXTRA/FNAME/FCOMMENT/FHCRC honored).
    /// Lenient: trailer CRC/ISIZE are not checked (some exporters write
    /// all-zero trailers). Use `gunzipVerified` when slicing streams.
    static func gunzip(_ data: Data) -> Data? {
        guard let (raw, _) = gunzipParts(data) else { return nil }
        return inflateGzipBody(raw)
    }

    /// Gunzip with ISIZE trailer verification (uncompressed size mod 2³²).
    /// Used to validate candidate slices when splitting concatenated streams.
    static func gunzipVerified(_ data: Data) -> Data? {
        guard let (raw, isize) = gunzipParts(data),
              let out = inflateGzipBody(raw),
              UInt32(truncatingIfNeeded: out.count) == isize
        else { return nil }
        return out
    }

    static func gunzipParts(_ data: Data) -> (body: Data, isize: UInt32)? {
        let b = Array(data)
        guard b.count >= 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 0x08 else { return nil }
        let flags = b[3]
        var pos = 10
        func skip(_ n: Int) -> Bool { guard pos + n <= b.count else { return false }; pos += n; return true }
        if flags & 0x04 != 0 {
            guard pos + 2 <= b.count else { return nil }
            let xlen = Int(b[pos]) | (Int(b[pos + 1]) << 8)
            guard skip(2 + xlen) else { return nil }
        }
        if flags & 0x08 != 0 { while pos < b.count, b[pos] != 0 { pos += 1 }; guard skip(1) else { return nil } }
        if flags & 0x10 != 0 { while pos < b.count, b[pos] != 0 { pos += 1 }; guard skip(1) else { return nil } }
        if flags & 0x02 != 0 { guard skip(2) else { return nil } }
        guard b.count >= pos + 8 else { return nil }
        let t = b.count - 8
        let isize = UInt32(b[t + 4]) | (UInt32(b[t + 5]) << 8) | (UInt32(b[t + 6]) << 16) | (UInt32(b[t + 7]) << 24)
        return (Data(b[pos..<t]), isize)
    }

    /// Inflate a gzip body liberally: raw DEFLATE first, else a zlib-wrapped
    /// body (some encoders wrap). Keeps export/import agreeing on every OS.
    static func inflateGzipBody(_ raw: Data) -> Data? {
        if let out = inflateRaw(raw) { return out }
        if raw.count > 6, raw[raw.startIndex] == 0x78,
           let out = inflateRaw(raw.dropFirst(2).dropLast(4)) { return out }
        return nil
    }
}

// MARK: - ZIP reader (stored + deflated, central-directory driven)

struct PaprikaZipEntry {
    var name: String
    var data: Data
}

enum PaprikaZip {
    static func u16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | (Int(b[o + 1]) << 8) }
    static func u32(_ b: [UInt8], _ o: Int) -> Int {
        Int(b[o]) | (Int(b[o + 1]) << 8) | (Int(b[o + 2]) << 16) | (Int(b[o + 3]) << 24)
    }

    /// Central-directory parse; each entry inflated (method 8) or stored (0).
    /// Entries with data-descriptors (streaming flag) are skipped — Paprika
    /// never emits them, and skipping beats mis-slicing.
    static func unzip(_ data: Data) -> [PaprikaZipEntry]? {
        let b = Array(data)
        guard b.count >= 22 else { return nil }
        // Locate EOCD scanning back from the tail (comment ≤ 64k).
        var eocd = -1
        let lo = max(0, b.count - (65557 + 22))
        var i = b.count - 22
        while i >= lo {
            if b[i] == 0x50, b[i + 1] == 0x4B, b[i + 2] == 0x05, b[i + 3] == 0x06 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return nil }
        let count = u16(b, eocd + 10)
        let centralOff = u32(b, eocd + 16)
        guard count > 0, centralOff < b.count else { return nil }
        var out: [PaprikaZipEntry] = []
        var pos = centralOff
        for _ in 0..<count {
            guard pos + 46 <= b.count,
                  b[pos] == 0x50, b[pos + 1] == 0x4B, b[pos + 2] == 0x01, b[pos + 3] == 0x02
            else { break }
            let method = u16(b, pos + 10)
            let flags = u16(b, pos + 8)
            let compSize = u32(b, pos + 24)
            let nameLen = u16(b, pos + 28)
            let extraLen = u16(b, pos + 30)
            let commentLen = u16(b, pos + 32)
            let localOff = u32(b, pos + 42)
            guard pos + 46 + nameLen <= b.count else { break }
            let nameData = Data(b[(pos + 46)..<(pos + 46 + nameLen)])
            let name = String(data: nameData, encoding: .utf8)
                ?? nameData.map { String(format: "%c", $0) }.joined()
            pos += 46 + nameLen + extraLen + commentLen
            if flags & 0x08 != 0 { continue } // streaming sizes — skip safely
            guard localOff + 30 <= b.count,
                  b[localOff] == 0x50, b[localOff + 1] == 0x4B,
                  b[localOff + 2] == 0x03, b[localOff + 3] == 0x04
            else { continue }
            let ln = u16(b, localOff + 26), le = u16(b, localOff + 28)
            let dataStart = localOff + 30 + ln + le
            guard dataStart + compSize <= b.count else { continue }
            let payload = Data(b[dataStart..<(dataStart + compSize)])
            if method == 0 { out.append(PaprikaZipEntry(name: name, data: payload)) }
            else if method == 8, let inflated = PaprikaInflate.inflateRaw(payload) {
                out.append(PaprikaZipEntry(name: name, data: inflated))
            }
        }
        return out
    }
}

// MARK: - Paprika JSON → ParsedRecipe (§1.2–1.3)

public enum PaprikaImportParser {
    // MARK: Entry point

    /// Parses one staged file. Dispatches on extension + magic bytes, never
    /// on the presenting URL (Files/Mail staging renames freely).
    public static func parseFile(named fileName: String, data: Data) -> ParsedFile {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let bytes = Array(data.prefix(4))
        let isZip = bytes.count >= 2 && bytes[0] == 0x50 && bytes[1] == 0x4B
        let isGzip = bytes.count >= 2 && bytes[0] == 0x1F && bytes[1] == 0x8B

        // Opaque proprietary formats: reject with re-export guidance (P2/P3).
        if ["ysr", "mgourmet", "mgourmet3", "mgourmet4", "dvo", "hcb", "sqlite", "rbox", "ckbk", "lcb", "mc2", "mcx", "mcf", "mrf"].contains(ext) {
            return ParsedFile(warnings: [unsupportedMessage(for: ext)])
        }

        if isZip || ["paprikarecipes", "zip", "mcb", "mz2"].contains(ext) {
            return parseZipContainer(named: fileName, data: data, ext: ext)
        }
        if isGzip || ["paprikarecipe", "fdxz"].contains(ext) {
            return parseGzipPayload(data: data, ext: ext)
        }
        if ext == "fdx" || looksLikeXML(data) {
            return parseXMLPayload(data: data, ext: ext, fileName: fileName)
        }
        if ["html", "htm"].contains(ext) || looksLikeHTML(data) {
            return parseHTML(data: data)
        }
        // Plain text family: try JSON first (JSON-as-YAML is valid YAML),
        // then the minimal YAML reader, then labeled-section text.
        if let obj = tryJSON(data) {
            return parseJSONObjectOrArray(obj)
        }
        if ["yml", "yaml"].contains(ext) || maybeYAML(data) {
            let parsed = parseYAMLText(String(data: data, encoding: .utf8) ?? "")
            if !parsed.recipes.isEmpty { return parsed }
        }
        return parseLabeledText(String(data: data, encoding: .utf8) ?? "", fileName: fileName)
    }

    public static func unsupportedMessage(for ext: String) -> String {
        switch ext {
        case "ckbk": return "The Recipe Manager exports come in two flavors — this `.ckbk` file is its private database and can't be read. Re-export as Text and import that instead."
        case "lcb": return "Living Cookbook's native `.lcb` database isn't readable. In Living Cookbook use File → Export → `.fdx` and import that."
        case "mc2", "mcx", "mcf", "mrf": return "That MasterCook database file can't be read directly. In MasterCook use File → Export and Mail → MC 5+ (`.mx2`) or `.mz2`."
        case "dvo": return "Cook'n `.dvo` files have no readable format. Re-export from Cook'n as MasterCook `.mx2` and import that."
        default: return "`. \(ext)` is a proprietary export this importer can't read yet. If the app offers MasterCook `.mx2`, MealMaster text, or Paprika `.paprikarecipes` export, use that instead."
        }
    }

    // MARK: Containers

    static func parseZipContainer(named fileName: String, data: Data, ext: String) -> ParsedFile {
        guard let entries = PaprikaZip.unzip(data) else {
            // Not actually a ZIP (or unreadable): fall through to raw attempts.
            if let obj = tryJSON(data) { return parseJSONObjectOrArray(obj) }
            return ParsedFile(warnings: ["Couldn't read `\(fileName)` as a ZIP archive."])
        }
        var recipes: [ParsedRecipe] = []
        var warnings: [String] = []
        var skippedTrash = 0
        for entry in entries {
            let lower = entry.name.lowercased()
            // My CookBook inner XML / Copy-Me-That HTML / Pepperplate TXT.
            if lower.hasSuffix(".xml") || lower.hasSuffix(".fdx") {
                let sub = parseXMLPayload(data: entry.data, ext: "xml", fileName: entry.name)
                recipes += sub.recipes; warnings += sub.warnings
                continue
            }
            if lower.hasSuffix(".html") || lower.hasSuffix(".htm") {
                let sub = parseHTML(data: entry.data)
                recipes += sub.recipes; warnings += sub.warnings
                continue
            }
            if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png")
                || lower.hasPrefix("__macosx") || lower.hasSuffix(".ds_store") { continue }
            // Recipe members: gunzip, else raw JSON (CookTrace parity).
            let payload = gunzipAllowingRaw(entry.data)
            if let obj = tryJSON(payload) {
                let sub = parseJSONObjectOrArray(obj)
                for r in sub.recipes {
                    if isTrash(r) { skippedTrash += 1; continue }
                    recipes.append(r)
                }
                warnings += sub.warnings
            } else if !entry.data.isEmpty {
                let sub = parseLabeledText(String(data: entry.data, encoding: .utf8) ?? "", fileName: entry.name)
                recipes += sub.recipes; warnings += sub.warnings
            }
        }
        if skippedTrash > 0 { warnings.append("Skipped \(skippedTrash) trashed recipe\(skippedTrash == 1 ? "" : "s").") }
        if recipes.isEmpty, warnings.isEmpty {
            warnings.append("No recipes found in `\(fileName)` (\(entries.count) file\(entries.count == 1 ? "" : "s") checked).")
        }
        return ParsedFile(recipes: recipes, warnings: warnings)
    }

    static func parseGzipPayload(data: Data, ext: String) -> ParsedFile {
        // Multi-member stream first (1F 8B 08 split), then single.
        let members = PaprikaInflate.splitGzipMembers(data)
        if members.count > 1 {
            var recipes: [ParsedRecipe] = []
            var warnings: [String] = []
            for m in members {
                if let json = PaprikaInflate.gunzip(m), let obj = tryJSON(json) {
                    let sub = parseJSONObjectOrArray(obj)
                    recipes += sub.recipes; warnings += sub.warnings
                }
            }
            if !recipes.isEmpty { return ParsedFile(recipes: recipes, warnings: warnings) }
        }
        if let json = PaprikaInflate.gunzip(data), let obj = tryJSON(json) {
            return parseJSONObjectOrArray(obj)
        }
        if ext == "fdxz" { return ParsedFile(warnings: ["Couldn't decompress that `.fdxz` file."]) }
        // Bare JSON saved with a Paprika name (defensive).
        if let obj = tryJSON(data) { return parseJSONObjectOrArray(obj) }
        return ParsedFile(warnings: ["Couldn't read that `.paprikarecipe` file — it isn't gzip or JSON."])
    }

    static func gunzipAllowingRaw(_ data: Data) -> Data {
        if data.prefix(2).elementsEqual([0x1F, 0x8B]) {
            return PaprikaInflate.gunzip(data) ?? data
        }
        return data
    }

    // MARK: JSON objects

    static func tryJSON(_ data: Data) -> Any? {
        guard !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    static func parseJSONObjectOrArray(_ obj: Any) -> ParsedFile {
        if let dict = obj as? [String: Any] {
            // Single Paprika object vs YAML-style single (name key, no uid needed).
            if isPaprikaObject(dict) || dict["name"] != nil {
                return ParsedFile(recipes: [parsePaprikaObject(dict)].compactMap { $0 })
            }
            return ParsedFile(warnings: ["That JSON file doesn't look like a recipe (no `name`)."])
        }
        if let arr = obj as? [[String: Any]] {
            return ParsedFile(recipes: arr.compactMap(parsePaprikaObject))
        }
        if let arr = obj as? [Any] {
            let dicts = arr.compactMap { $0 as? [String: Any] }
            if !dicts.isEmpty { return ParsedFile(recipes: dicts.compactMap(parsePaprikaObject)) }
        }
        return ParsedFile(warnings: ["That JSON file doesn't contain recipes."])
    }

    static func isPaprikaObject(_ d: [String: Any]) -> Bool {
        d["uid"] != nil || d["ingredients"] is String || d["directions"] is String
            || d["prep_time"] != nil || d["cook_time"] != nil
    }

    static func isTrash(_ r: ParsedRecipe) -> Bool {
        r.warnings.contains("__intrash__")
    }

    /// Core §1.3 mapping. Returns nil only when there is no usable title AND
    /// no content (avoids importing blank members as "Untitled").
    public static func parsePaprikaObject(_ d: [String: Any]) -> ParsedRecipe? {
        let name = (d["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let ingsRaw = d["ingredients"] as? String ?? ""
        let dirsRaw = d["directions"] as? String ?? ""
        guard !name.isEmpty || !ingsRaw.isEmpty || !dirsRaw.isEmpty else { return nil }
        var r = ParsedRecipe(title: name.isEmpty ? "Untitled" : name)
        r.paprikaUid = (d["uid"] as? String)?.uppercased()
        r.recipeDescription = (d["description"] as? String) ?? ""
        r.notes = (d["notes"] as? String) ?? ""
        if let s = PaprikaScalars.servings(d["servings"] as? String) {
            r.servings = s.0; r.servingsText = s.1
        }
        r.prepMinutes = PaprikaScalars.minutes(d["prep_time"] as? String)
        r.cookMinutes = PaprikaScalars.minutes(d["cook_time"] as? String)
        r.totalMinutes = PaprikaScalars.minutes(d["total_time"] as? String)
        r.categories = PaprikaScalars.categories(d["categories"])
        r.rating = PaprikaScalars.rating(d["rating"])
        r.difficulty = d["difficulty"] as? String
        r.nutritionText = d["nutritional_info"] as? String
        r.source = (d["source"] as? String) ?? ""
        // Legacy alias: old exports put the URL in `source`.
        let srcUrl = (d["source_url"] as? String) ?? ""
        if srcUrl.isEmpty, r.source.lowercased().hasPrefix("http") {
            r.sourceUrl = r.source; r.source = ""
        } else {
            r.sourceUrl = srcUrl
        }
        r.isFavorite = PaprikaScalars.bool(d["on_favorites"])
        r.cookbook = d["cookbook"] as? String
        r.createdAt = PaprikaScalars.created(d)
        // Trash / sync flags → marker warning (container skips on import).
        if PaprikaScalars.bool(d["in_trash"]) || PaprikaScalars.bool(d["deleted"]) {
            r.warnings.append("__intrash__")
        }
        // Ingredients: one line each, display ALWAYS the original line.
        let ingLines = ingsRaw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        r.ingredients = ingLines.enumerated().map {
            ImportIngredient(name: $1, display: $1, position: $0)
        }
        // Directions → steps.
        r.steps = PaprikaScalars.steps(dirsRaw).enumerated().map {
            ImportStep(position: $0, text: $1)
        }
        // Photos: embedded base64 wins; `\/` unescaped; image_url never fetched.
        var photoB64 = (d["photo_data"] as? String)?.replacingOccurrences(of: "\\/", with: "/")
        if (photoB64 ?? "").isEmpty {
            if let photos = d["photos"] as? [[String: Any]] {
                photoB64 = (photos.first?["data"] as? String)?.replacingOccurrences(of: "\\/", with: "/")
            }
        }
        if (photoB64 ?? "").isEmpty, let yamlPhoto = d["photo"] as? String, !yamlPhoto.isEmpty {
            photoB64 = yamlPhoto // YAML `photo` ≈ JSON `photo_data` (base64).
        }
        if let b64 = photoB64, !b64.isEmpty {
            let clean = b64.components(separatedBy: .whitespacesAndNewlines).joined()
            if let bytes = Data(base64Encoded: clean, options: .ignoreUnknownCharacters) {
                r.photoData = bytes
                let fname = d["photo"] as? String
                r.photoFilename = (fname?.isEmpty == false ? fname : nil)
                    ?? (r.paprikaUid.map { "\($0).jpg" })
            } else {
                r.warnings.append("Photo data couldn't be decoded — imported without the photo.")
            }
        }
        if r.ingredients.isEmpty, r.steps.isEmpty {
            r.warnings.append("No ingredients or steps found — check the file parsed correctly.")
        }
        return r
    }

    // MARK: Minimal YAML reader (§2)

    static func maybeYAML(_ data: Data) -> Bool {
        guard let s = String(data: data, encoding: .utf8) else { return false }
        let head = s.prefix(400)
        return head.contains("name:") && (head.contains("ingredients:") || head.contains("directions:"))
    }

    /// Handles what Paprika actually emits: JSON-as-YAML (tried first by the
    /// caller) plus hand-written `key: value` / `key: |` literal blocks /
    /// `key: [a, b]` flow lists, single recipe or `- ` list items.
    public static func parseYAMLText(_ text: String) -> ParsedFile {
        let docs = splitYAMLDocs(text)
        var recipes: [ParsedRecipe] = []
        var warnings: [String] = []
        for doc in docs {
            if let r = parseYAMLDoc(doc) { recipes.append(r) }
        }
        if recipes.isEmpty {
            warnings.append("Couldn't parse that YAML file — strict indentation is required, or export as JSON-as-YAML.")
        }
        return ParsedFile(recipes: recipes, warnings: warnings)
    }

    static func splitYAMLDocs(_ text: String) -> [String] {
        // Multi-recipe `---` docs or `- name:` list items at indent 0.
        let lines = text.components(separatedBy: .newlines)
        var docs: [[String]] = [[]]
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "---" || t == "..." { docs.append([]); continue }
            if (line.hasPrefix("- ") || line == "-"), !line.hasPrefix(" ") {
                if !(docs.last?.isEmpty ?? true) { docs.append([]) }
                docs[docs.count - 1].append(String(line.dropFirst(2)))
                continue
            }
            docs[docs.count - 1].append(line)
        }
        return docs.map { $0.joined(separator: "\n") }.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func parseYAMLDoc(_ doc: String) -> ParsedRecipe? {
        var fields: [String: String] = [:]
        let lines = doc.components(separatedBy: .newlines)
        var i = 0
        while i < lines.count {
            let line = lines[i]
            guard let colon = line.firstIndex(of: ":") else { i += 1; continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.hasPrefix(" "), !key.hasPrefix("-") else { i += 1; continue }
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value == "|" || value == ">" {
                // Literal block: consume deeper-indented lines.
                var block: [String] = []
                i += 1
                while i < lines.count,
                      (lines[i].hasPrefix(" ") || lines[i].hasPrefix("\t")
                        || lines[i].trimmingCharacters(in: .whitespaces).isEmpty) {
                    block.append(lines[i].trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                // Drop padding-only empties but keep paragraph breaks.
                while block.first?.isEmpty == true { block.removeFirst() }
                while block.last?.isEmpty == true { block.removeLast() }
                fields[key] = block.joined(separator: "\n")
                continue
            }
            // Strip quotes / trailing comments.
            if (value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2)
                || (value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2) {
                value = String(value.dropFirst().dropLast())
            }
            fields[key] = value
            i += 1
        }
        guard fields["name"] != nil || fields["ingredients"] != nil || fields["directions"] != nil else { return nil }
        var dict: [String: Any] = [:]
        for (k, v) in fields {
            if k == "categories" {
                if v.hasPrefix("["), v.hasSuffix("]") {
                    dict[k] = v.dropFirst().dropLast().split(separator: ",").map {
                        $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    }
                } else { dict[k] = v }
            } else if k == "rating" {
                dict[k] = Int(v) ?? 0
            } else if k == "on_favorites" {
                dict[k] = ["yes", "true", "1"].contains(v.lowercased())
            } else {
                dict[k] = v
            }
        }
        return parsePaprikaObject(dict)
    }

    // MARK: Labeled-section text (.txt / .mxp / .mmf-ish / Pepperplate)

    static func parseLabeledText(_ text: String, fileName: String) -> ParsedFile {
        let lines = text.components(separatedBy: .newlines)
        var title = ""
        var servings: String?
        var categories: [String] = []
        var source = ""
        var prep: String?, cook: String?
        var notes: [String] = []
        var ings: [String] = []
        var steps: [String] = []
        enum Section { case none, ings, steps, notes }
        var section = Section.none
        let headerRe = try? NSRegularExpression(pattern: #"^([A-Za-z][A-Za-z ]{2,}):\s*(.*)$"#)

        func classify(_ header: String) -> Section? {
            let h = header.lowercased()
            if h.contains("ingredient") { return .ings }
            if h.contains("instruction") || h.contains("direction") || h.contains("procedure")
                || h.contains("preparation") || h == "method" || h.contains("steps") { return .steps }
            if h.contains("note") { return .notes }
            return nil
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // MealMaster decorations: `-----`, `MMMMM` trailers.
            if line.hasPrefix("-----") || line.hasPrefix("MMMMM") {
                let inner = line.trimmingCharacters(in: CharacterSet(charactersIn: "-= M"))
                if !inner.isEmpty, classify(inner) == nil, section == .none {
                    section = .none
                }
                continue
            }
            let ns = line as NSString
            if let m = headerRe?.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
               m.numberOfRanges == 3 {
                let key = ns.substring(with: m.range(at: 1))
                let val = ns.substring(with: m.range(at: 2))
                let kl = key.lowercased()
                if kl == "title" || kl == "name" || kl == "recipe" { title = val; section = .none; continue }
                if kl == "servings" || kl == "yield" || kl == "quantity" { servings = val; continue }
                if kl == "categories" || kl == "category" || kl == "tags" {
                    categories = val.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    continue
                }
                if kl == "source" || kl == "author" { source = val; continue }
                if kl.contains("prep") { prep = val; continue }
                if kl.contains("cook") { cook = val; continue }
                if let s = classify(key) { section = s; if !val.isEmpty {
                    switch s { case .ings: ings.append(val); case .steps: steps.append(val); case .notes: notes.append(val); case .none: break }
                }; continue }
                // Unknown header with content → notes-ish, stay in section.
                if section == .notes || section == .none { notes.append(line) }
                continue
            }
            switch section {
            case .ings:
                // MealMaster continuation `-…` lines append to the previous row.
                if line.hasPrefix("-"), !ings.isEmpty { ings[ings.count - 1] += " " + line.dropFirst().trimmingCharacters(in: .whitespaces) }
                else { ings.append(line) }
            case .steps: steps.append(line)
            case .notes: notes.append(line)
            case .none:
                // No section yet: first non-empty line is the title.
                if title.isEmpty { title = line } else { notes.append(line) }
            }
        }
        if title.isEmpty { title = ((fileName as NSString).deletingPathExtension as NSString).lastPathComponent }
        if ings.isEmpty, steps.isEmpty {
            return ParsedFile(warnings: ["No labeled Ingredients/Directions sections found in `\(fileName)`."])
        }
        var dict: [String: Any] = [
            "name": title,
            "ingredients": ings.joined(separator: "\n"),
            "directions": steps.joined(separator: "\n"),
            "notes": notes.joined(separator: "\n"),
            "categories": categories,
            "source": source,
        ]
        if let s = servings { dict["servings"] = s }
        if let p = prep { dict["prep_time"] = p }
        if let c = cook { dict["cook_time"] = c }
        guard let r = parsePaprikaObject(dict) else {
            return ParsedFile(warnings: ["Couldn't parse `\(fileName)` as recipe text."])
        }
        return ParsedFile(recipes: [r])
    }

    // MARK: XML (.xml / .fdx / .mx2 / .mcb inner)

    static func looksLikeXML(_ data: Data) -> Bool {
        let head = String(data: Data(data.prefix(600)), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return head.hasPrefix("<")
    }

    static func parseXMLPayload(data: Data, ext: String, fileName: String) -> ParsedFile {
        // MasterCook MX2 charset repair: Latin-1/Win-1252 → UTF-8, bare `&`,
        // `standalone`-before-`encoding` decl order.
        var text = String(data: data, encoding: .utf8)
        if text == nil {
            text = String(data: data, encoding: .windowsCP1252)
                ?? String(data: data, encoding: .isoLatin1)
        }
        guard var xml = text else {
            return ParsedFile(warnings: ["Couldn't decode `\(fileName)` as text."])
        }
        if ext == "mx2" {
            xml = xml.replacingOccurrences(of: "standalone=\"yes\" encoding=", with: "encoding=")
            xml = xml.replacingOccurrences(of: #"&(?!amp;|lt;|gt;|quot;|apos;|#)"#,
                                           with: "&amp;", options: .regularExpression)
        }
        guard let xmlData = xml.data(using: .utf8) else {
            return ParsedFile(warnings: ["Couldn't read `\(fileName)`."])
        }
        let walker = GenericRecipeXML()
        let parser = XMLParser(data: xmlData)
        parser.delegate = walker
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        if walker.recipes.isEmpty {
            return ParsedFile(warnings: ["No recipes found in `\(fileName)` (checked \(walker.elementCount) XML elements)."])
        }
        let recipes = walker.recipes.compactMap(parsePaprikaObject)
        return ParsedFile(recipes: recipes)
    }

    /// Lenient walker: maps common tag aliases (FDX / Yum-XML / Cookmate /
    /// MX2-repaired) onto Paprika keys. Unknown tags inside an ingredient or
    /// step container still contribute their text.
    class GenericRecipeXML: NSObject, XMLParserDelegate {
        var recipes: [[String: Any]] = []
        var current: [String: Any] = [:]
        var ingBuf: [String] = []
        var stepBuf: [String] = []
        var catBuf: [String] = []
        var text = ""
        var stack: [String] = []
        var elementCount = 0
        var inRecipe = false

        static let recipeTags: Set<String> = ["recipe", "rcpe", "rcp", "r"]
        static let titleTags: Set<String> = ["title", "name", "recipename", "label"]
        static let ingContainer: Set<String> = ["ingredients", "ingredientlist", "ings"]
        static let ingTags: Set<String> = ["ingredient", "ing", "item", "li", "i"]
        static let stepContainer: Set<String> = ["instructions", "directions", "procedure", "procedures", "steps", "method", "recipetext"]
        static let stepTags: Set<String> = ["step", "direction", "instruction", "procedure", "recipestep", "p", "li"]
        static let catTags: Set<String> = ["category", "cat", "tag", "cuisine"]
        static let servingsTags: Set<String> = ["servings", "yield", "quantity", "serves"]
        static let descTags: Set<String> = ["description", "desc", "summary", "headnote"]
        static let notesTags: Set<String> = ["notes", "note", "comments", "comment"]
        static let sourceTags: Set<String> = ["source", "author", "authorname", "from"]
        static let urlTags: Set<String> = ["url", "sourceurl", "link", "web"]
        static let prepTags: Set<String> = ["preptime", "prep_time", "prep"]
        static let cookTags: Set<String> = ["cooktime", "cook_time", "cook"]
        static let totalTags: Set<String> = ["totaltime", "total_time", "total"]

        func parser(_ parser: XMLParser, didStartElement el: String,
                    namespaceURI: String?, qualifiedName: String?, attributes attrs: [String: String] = [:]) {
            elementCount += 1
            let tag = el.lowercased()
            stack.append(tag)
            text = ""
            if Self.recipeTags.contains(tag) {
                if inRecipe { flush() }
                inRecipe = true
                current = [:]; ingBuf = []; stepBuf = []; catBuf = []
            }
            // Attribute-carried values (FDX qty/unit/item).
            if inRecipe, Self.ingTags.contains(tag) {
                let bits = [attrs["qty"], attrs["quantity"], attrs["amount"],
                            attrs["unit"], attrs["item"], attrs["name"], attrs["food"]]
                    .compactMap { $0 }.filter { !$0.isEmpty }
                if !bits.isEmpty { ingBuf.append(bits.joined(separator: " ")) }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters s: String) { text += s }

        func parser(_ parser: XMLParser, didEndElement el: String,
                    namespaceURI: String?, qualifiedName: String?) {
            let tag = el.lowercased()
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = ""
            _ = stack.popLast()
            guard inRecipe else { return }
            if Self.recipeTags.contains(tag) { flush(); return }
            guard !value.isEmpty else { return }
            if Self.titleTags.contains(tag), current["name"] == nil { current["name"] = value }
            else if Self.ingTags.contains(tag) { ingBuf.append(value) }
            else if Self.stepTags.contains(tag), !Self.ingContainer.contains(stack.last ?? "") { stepBuf.append(value) }
            else if Self.catTags.contains(tag) { catBuf.append(value) }
            else if Self.servingsTags.contains(tag) { current["servings"] = value }
            else if Self.descTags.contains(tag) { current["description"] = value }
            else if Self.notesTags.contains(tag) {
                current["notes"] = ((current["notes"] as? String) ?? "") + value + "\n"
            }
            else if Self.sourceTags.contains(tag) { current["source"] = value }
            else if Self.urlTags.contains(tag) { current["source_url"] = value }
            else if Self.prepTags.contains(tag) { current["prep_time"] = value }
            else if Self.cookTags.contains(tag) { current["cook_time"] = value }
            else if Self.totalTags.contains(tag) { current["total_time"] = value }
        }

        func flush() {
            if !ingBuf.isEmpty { current["ingredients"] = ingBuf.joined(separator: "\n") }
            if !stepBuf.isEmpty { current["directions"] = stepBuf.joined(separator: "\n") }
            if !catBuf.isEmpty { current["categories"] = catBuf }
            if current["name"] != nil || current["ingredients"] != nil || current["directions"] != nil {
                recipes.append(current)
            }
            current = [:]; ingBuf = []; stepBuf = []; catBuf = []
            inRecipe = false
        }
    }

    // MARK: HTML (JSON-LD → hRecipe → headings, §3)

    static func looksLikeHTML(_ data: Data) -> Bool {
        guard let head = String(data: Data(data.prefix(800)), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return head.hasPrefix("<!doctype html") || head.hasPrefix("<html")
    }

    public static func parseHTML(data: Data) -> ParsedFile {
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return ParsedFile(warnings: ["Couldn't decode that HTML file as text."])
        }
        // 1) JSON-LD Recipe blocks (Paprika 4+ / schema.org). Accumulate
        // EVERY block so a multi-recipe HTML export round-trips all of its
        // recipes instead of just the first.
        let ldRecipes = extractJsonLd(html).flatMap { paprikaRecipesFromJsonLd($0) }
        if !ldRecipes.isEmpty { return ParsedFile(recipes: ldRecipes) }
        // 2) hRecipe microformat (Paprika ≤3).
        if let recipe = paprikaFromHRecipe(html) { return ParsedFile(recipes: [recipe]) }
        // 3) Visible headings fallback.
        if let recipe = paprikaFromHeadings(html) { return ParsedFile(recipes: [recipe]) }
        return ParsedFile(warnings: ["No recipe data found in that HTML (checked JSON-LD, hRecipe, and headings)."])
    }

    static func extractJsonLd(_ html: String) -> [[String: Any]] {
        var out: [[String: Any]] = []
        let pattern = #"<script[^>]*type=["']application/ld\+json["'][^>]*>(.*?)</script>"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return out }
        let ns = html as NSString
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let raw = ns.substring(with: m.range(at: 1))
            guard let d = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) else { continue }
            if let dict = obj as? [String: Any] { out.append(dict) }
            else if let arr = obj as? [[String: Any]] { out.append(contentsOf: arr) }
        }
        return out
    }

    static func jsonLdRecipes(_ obj: [String: Any]) -> [[String: Any]] {
        // Unwrap @graph / arrays; match @type Recipe (string or array).
        if let graph = obj["@graph"] as? [[String: Any]] { return graph.flatMap { jsonLdRecipes($0) } }
        let type = obj["@type"]
        let isRecipe = (type as? String)?.lowercased() == "recipe"
            || (type as? [String])?.contains { $0.lowercased() == "recipe" } == true
        return isRecipe ? [obj] : []
    }

    /// All recipes in one JSON-LD block (unwraps @graph; usually one).
    static func paprikaRecipesFromJsonLd(_ obj: [String: Any]) -> [ParsedRecipe] {
        jsonLdRecipes(obj).compactMap { r -> ParsedRecipe? in
            var dict: [String: Any] = [:]
            dict["name"] = r["name"]
            dict["description"] = r["description"]
            if let ings = r["recipeIngredient"] as? [String] { dict["ingredients"] = ings.joined(separator: "\n") }
            else if let s = r["recipeIngredient"] as? String { dict["ingredients"] = s }
            if let instr = r["recipeInstructions"] {
                dict["directions"] = howToStepsToText(instr)
            }
            dict["servings"] = [r["recipeYield"]].compactMap { $0 }.map { "\($0)" }.first
            dict["prep_time"] = r["prepTime"] as? String
            dict["cook_time"] = r["cookTime"] as? String
            dict["total_time"] = r["totalTime"] as? String
            if let cats = r["recipeCategory"] {
                dict["categories"] = (cats as? [String]) ?? ((cats as? String).map { [$0] } ?? [])
            }
            if let author = r["author"] as? [String: Any] { dict["source"] = author["name"] }
            else if let author = r["author"] as? String { dict["source"] = author }
            return parsePaprikaObject(dict)
        }
    }

    static func paprikaFromJsonLd(_ obj: [String: Any]) -> ParsedRecipe? {
        paprikaRecipesFromJsonLd(obj).first
    }

    static func howToStepsToText(_ instr: Any) -> String {
        if let s = instr as? String { return s }
        if let arr = instr as? [Any] {
            return arr.map { item -> String in
                if let s = item as? String { return s }
                if let d = item as? [String: Any] { return (d["text"] as? String) ?? "" }
                return ""
            }.filter { !$0.isEmpty }.joined(separator: "\n")
        }
        return ""
    }

    static func stripTags(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "<[^>]+>", options: .caseInsensitive) else { return s }
        let decoded = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
        return decoded
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }

    static func paprikaFromHRecipe(_ html: String) -> ParsedRecipe? {
        guard html.lowercased().contains("hrecipe") else { return nil }
        func firstClass(_ names: [String]) -> String? {
            for n in names {
                let pattern = #"class=["'][^"']*\b"# + n + #"\b[^"']*["'][^>]*>(.*?)<"#
                if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
                   let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) {
                    return stripTags((html as NSString).substring(with: m.range(at: 1))).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            return nil
        }
        func allClass(_ names: [String]) -> [String] {
            var found: [String] = []
            for n in names {
                let pattern = #"<li[^>]*class=["'][^"']*\b"# + n + #"\b[^"']*["'][^>]*>(.*?)</li>"#
                guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { continue }
                for m in re.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
                    let t = stripTags((html as NSString).substring(with: m.range(at: 1))).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { found.append(t) }
                }
            }
            return found
        }
        guard let title = firstClass(["fn"]) else { return nil }
        var dict: [String: Any] = ["name": title]
        let ings = allClass(["ingredient"])
        if !ings.isEmpty { dict["ingredients"] = ings.joined(separator: "\n") }
        let steps = allClass(["instructions"])
        if !steps.isEmpty { dict["directions"] = steps.joined(separator: "\n") }
        if let y = firstClass(["yield"]) { dict["servings"] = y }
        if let s = firstClass(["summary"]) { dict["description"] = s }
        if let a = firstClass(["author"]) { dict["source"] = a }
        return parsePaprikaObject(dict)
    }

    static func paprikaFromHeadings(_ html: String) -> ParsedRecipe? {
        // Visible-section fallback: split body text on Ingredients/Directions/Notes headings.
        let body: String
        if let re = try? NSRegularExpression(pattern: "<body[^>]*>(.*?)</body>", options: [.caseInsensitive, .dotMatchesLineSeparators]),
           let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) {
            body = (html as NSString).substring(with: m.range(at: 1))
        } else { body = html }
        let title: String
        if let re = try? NSRegularExpression(pattern: "<h1[^>]*>(.*?)</h1>", options: [.caseInsensitive, .dotMatchesLineSeparators]),
           let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)) {
            title = stripTags((html as NSString).substring(with: m.range(at: 1))).trimmingCharacters(in: .whitespacesAndNewlines)
        } else { title = "Imported recipe" }
        let text = stripTags(body)
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var ings: [String] = [], steps: [String] = [], notes: [String] = []
        enum S { case none, ings, steps, notes }
        var s = S.none
        for line in lines where !line.isEmpty {
            let l = line.lowercased()
            if ["ingredients", "ingredient list"].contains(l) { s = .ings; continue }
            if ["directions", "instructions", "method", "steps", "preparation"].contains(l) { s = .steps; continue }
            if ["notes", "note"].contains(l) { s = .notes; continue }
            switch s { case .ings: ings.append(line); case .steps: steps.append(line); case .notes: notes.append(line); case .none: break }
        }
        guard !ings.isEmpty || !steps.isEmpty else { return nil }
        return parsePaprikaObject([
            "name": title,
            "ingredients": ings.joined(separator: "\n"),
            "directions": steps.joined(separator: "\n"),
            "notes": notes.joined(separator: "\n"),
        ])
    }
}

// MARK: - Import request body + server client (POST /api/import)

/// File extension → server `format` (mirrors detectImportFormat in
/// api/src/import.ts). Binary bundles and text formats alike travel as
/// base64 `payload`; unknown text-ish extensions return nil and let the
/// server content-sniff.
public enum ImportFormatHint {
    public static func format(forFileName fileName: String) -> String? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "paprikarecipes", "paprikarecipe", "zip":
            return "paprika-zip"
        case "json":
            return "paprika-json"
        case "yml", "yaml":
            return "yaml"
        case "html", "htm":
            return "html"
        case "mx2", "mxp", "mz2", "mmf", "fdx", "fdxz":
            return ext // accepted by the detector; server 415s with re-export guidance until parsers land
        default:
            return nil
        }
    }
}

/// Encodes the server import envelope (ImportRequest): the ORIGINAL file
/// bytes as base64 `payload` plus `filename`/`format` for detection, with
/// decoded `text` alongside for text formats. The server owns parsing and
/// uid upsert; the client never sends parsed recipes (the API consumes
/// `format`/`filename`/`payload`/`text`, not a `recipes` array).
public func encodeImportBody(fileName: String, data: Data, format: String? = nil,
                             householdId: String? = nil,
                             importCookbooks: Bool = true,
                             dryRun: Bool = false) -> Data? {
    let resolved = format ?? ImportFormatHint.format(forFileName: fileName)
    var body: [String: Any] = [
        "filename": fileName,
        "importCookbooks": importCookbooks,
        "dryRun": dryRun,
    ]
    if let resolved { body["format"] = resolved }
    if let householdId, !householdId.isEmpty { body["householdId"] = householdId }
    if let resolved, ["yaml", "html", "paprika-json"].contains(resolved),
       let text = String(data: data, encoding: .utf8) {
        body["text"] = text
    }
    body["payload"] = data.base64EncodedString()
    return try? JSONSerialization.data(withJSONObject: body)
}

/// Decoded import report. Tolerant of both wire shapes: the live server's
/// `{"imported": Int, "ids": [String], "warnings": [...]}` (api/src/import.ts
/// ImportResult) and the contract ImportReport
/// `{"imported": [Recipe], "updated": Int, "warnings"?, "dryRun"?, "cookbooksCreated"?}`.
public struct ImportServerResult: Sendable, Codable {
    public var imported: Int
    public var updated: Int
    public var ids: [String]
    public var warnings: [String]?
    public var dryRun: Bool?
    public var cookbooksCreated: [String]?

    public init(imported: Int = 0, updated: Int = 0, ids: [String] = [],
                warnings: [String]? = nil, dryRun: Bool? = nil,
                cookbooksCreated: [String]? = nil) {
        self.imported = imported; self.updated = updated; self.ids = ids
        self.warnings = warnings; self.dryRun = dryRun
        self.cookbooksCreated = cookbooksCreated
    }

    enum CodingKeys: String, CodingKey {
        case imported, updated, ids, warnings, dryRun, cookbooksCreated
    }

    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        var count = 0
        var idsFromImported: [String] = []
        if let n = try? box.decode(Int.self, forKey: .imported) {
            count = n
        } else if var list = try? box.nestedUnkeyedContainer(forKey: .imported) {
            while !list.isAtEnd {
                if let recipe = try? list.decode(ImportedRecipeRef.self) {
                    count += 1
                    if let id = recipe.id { idsFromImported.append(id) }
                } else if (try? list.decode(JSONSkipped.self)) != nil {
                    count += 1
                } else {
                    break // unconsumable element: stop rather than loop forever
                }
            }
        }
        imported = count
        updated = (try? box.decode(Int.self, forKey: .updated)) ?? 0
        let ids = (try? box.decode([String].self, forKey: .ids)) ?? []
        self.ids = ids.isEmpty ? idsFromImported : ids
        warnings = try? box.decode([String].self, forKey: .warnings)
        dryRun = try? box.decode(Bool.self, forKey: .dryRun)
        cookbooksCreated = try? box.decode([String].self, forKey: .cookbooksCreated)
    }

    public func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(imported, forKey: .imported)
        try box.encode(updated, forKey: .updated)
        try box.encode(ids, forKey: .ids)
        try box.encodeIfPresent(warnings, forKey: .warnings)
        try box.encodeIfPresent(dryRun, forKey: .dryRun)
        try box.encodeIfPresent(cookbooksCreated, forKey: .cookbooksCreated)
    }
}

/// Minimal `id` view over an ImportReport `imported[]` recipe element
/// (unknown keys ignored).
private struct ImportedRecipeRef: Decodable {
    var id: String?
}

/// Value skipper so a tolerant `imported[]` walk never stalls on an
/// unexpected element shape.
private struct JSONSkipped: Decodable {
    init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        if box.decodeNil() { return }
        if (try? box.decode(Bool.self)) != nil { return }
        if (try? box.decode(Double.self)) != nil { return }
        if (try? box.decode(String.self)) != nil { return }
        if (try? box.decode([JSONSkipped].self)) != nil { return }
        _ = try box.decode([String: JSONSkipped].self)
    }
}

public enum ImportClientError: Error, Sendable {
    case badURL
    case httpStatus(Int)
    case decode(Error)
}

/// Minimal client for `POST /import`. Mirrors ClipClient auth (identity
/// headers + Ed25519 signer); callers fall back to on-device save on any
/// transport error (offline-first).
public struct ImportAPIClient: Sendable {
    public var baseURL: URL
    public var session: URLSession
    public var betaToken: String?
    public var userId: String
    public var deviceId: String
    public var signer: AnySendableSigner?

    public init(baseURL: URL, session: URLSession = .shared,
                betaToken: String? = nil, userId: String = "beta-user", deviceId: String = "app",
                signer: AnySendableSigner? = nil) {
        self.baseURL = baseURL; self.session = session
        self.betaToken = betaToken; self.userId = userId; self.deviceId = deviceId
        self.signer = signer
    }

    public func postImport(_ body: Data) async throws -> ImportServerResult {
        let url = baseURL.appendingPathComponent("/import")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        if let token = betaToken, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        req.setValue(userId, forHTTPHeaderField: "x-user-id")
        req.setValue(deviceId, forHTTPHeaderField: "x-device-id")
        if let signer { req = signer.signedRequest(req) }
        let (data, resp) = try await session.data(for: req)
        guard let status = (resp as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            throw ImportClientError.httpStatus((resp as? HTTPURLResponse)?.statusCode ?? -1)
        }
        do { return try JSONDecoder().decode(ImportServerResult.self, from: data) }
        catch { throw ImportClientError.decode(error) }
    }
}

/// Type-erased Ed25519 signer so this Foundation-only file never imports the
/// Sync target. Call sites wrap `DeviceRequestSigner` in one line.
public struct AnySendableSigner: Sendable {
    private let sign: @Sendable (URLRequest) -> URLRequest
    public init(_ sign: @escaping @Sendable (URLRequest) -> URLRequest) { self.sign = sign }
    public func signedRequest(_ req: URLRequest) -> URLRequest { sign(req) }
}
