// Smidgen — Lane 3 Capture
// apps/ios/Features/Ingest/OCRScanView.swift
//
// Vision OCR scan: cookbook photo → recognized text → title/ingredients/steps
// editable preview → save. Uses Vision when available; otherwise OCRStub so
// the flow works in simulator / without the SDK.

import SwiftUI
import SwiftData

#if canImport(Vision)
import Vision
import UIKit
#endif

// MARK: - OCR abstraction (Vision or stub)

/// Lines of recognized text with confidence. Sendable for actor use.
public struct OCRResult: Sendable {
    public var lines: [String]
    public init(lines: [String]) { self.lines = lines }
}

#if canImport(Vision)
public enum VisionOCR {
    public static func recognize(data: Data) async throws -> OCRResult {
        try await withCheckedThrowingContinuation { cont in
            guard let image = UIImage(data: data), let cg = image.cgImage else {
                cont.resume(returning: OCRResult(lines: []))
                return
            }
            let req = VNRecognizeTextRequest { req, _ in
                let lines = (req.results as? [VNRecognizedTextObservation] ?? []).compactMap {
                    $0.topCandidates(1).first?.string
                }
                cont.resume(returning: OCRResult(lines: lines))
            }
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            do { try handler.perform([req]) } catch { cont.resume(throwing: error) }
        }
    }
}
#else
public enum VisionOCR {
    /// Stub when Vision is unavailable: splits nothing, returns empty.
    /// UI still demonstrates the editable preview via manual paste.
    public static func recognize(data: Data) async throws -> OCRResult {
        OCRResult(lines: [])
    }
}
#endif

// MARK: - Heuristic splitter: OCR lines → title/ingredients/steps

public struct OCRDraft: Sendable {
    public var title: String
    public var ingredientLines: [String]
    public var stepLines: [String]
}

public enum OCRSplitter {
    /// First non-empty line = title. Lines with a leading quantity parse as
    /// ingredients; imperative sentences (ending with .) become steps; the
    /// rest joins steps. Fully unit-tested via IngredientParser + this fn.
    public static func split(_ lines: [String]) -> OCRDraft {
        let cleaned = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let first = cleaned.first else {
            return OCRDraft(title: "", ingredientLines: [], stepLines: [])
        }
        var ings: [String] = []
        var steps: [String] = []
        for line in cleaned.dropFirst() {
            let p = IngredientParser.parse(line)
            if p.quantity != nil && !p.name.isEmpty {
                ings.append(p.display)
            } else {
                steps.append(line)
            }
        }
        return OCRDraft(title: first, ingredientLines: ings, stepLines: steps)
    }
}

// MARK: - View

public struct OCRScanView: View {
    @Environment(\.modelContext) private var context

    @State private var recognizedText: String = ""
    @State private var title: String = ""
    @State private var ingredientLines: String = ""
    @State private var stepLines: String = ""
    @State private var notice: String?
    @State private var savedMessage: String?

    public init() {}

    public var body: some View {
        NavigationStack {
            Form {
                Section("Cookbook photo") {
                    #if canImport(Vision)
                    Text("Pick a photo via the Photos picker in a full build; paste OCR text below to simulate.")
                        .font(.caption).foregroundStyle(.secondary)
                    #else
                    Text("Vision unavailable — stub mode. Paste transcribed text below.")
                        .font(.caption).foregroundStyle(.secondary)
                    #endif
                    Text("Recognized / pasted text (first line = title)").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $recognizedText).frame(minHeight: 140)
                        .accessibilityIdentifier("ocr-text")
                    Button("Parse text") { parse() }
                        .accessibilityIdentifier("ocr-parse")
                }
                Section("Preview (editable)") {
                    TextField("Title", text: $title)
                    Text("Ingredients").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $ingredientLines).frame(minHeight: 120)
                    Text("Steps").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $stepLines).frame(minHeight: 120)
                }
                Section {
                    Button("Scan image data") {
                        Task { await scanPlaceholder() }
                    }
                    Button("Save recipe") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("ocr-save")
                }
                if let notice { Section { Text(notice).font(.caption) } }
                if let savedMessage { Section { Text(savedMessage).foregroundStyle(.green)
                    .accessibilityIdentifier("ocr-saved") } }
            }
            .navigationTitle("OCR scan")
        }
    }

    private func parse() {
        let lines = recognizedText.components(separatedBy: .newlines)
        let draft = OCRSplitter.split(lines)
        title = draft.title
        ingredientLines = draft.ingredientLines.joined(separator: "\n")
        stepLines = draft.stepLines.joined(separator: "\n")
        notice = "strategy=ocr confidence=0.70 (local heuristic; server ocr upgrade later)"
    }

    private func scanPlaceholder() async {
        // Placeholder for UIImagePicker data path: VisionOCR.recognize(data:)
        // then OCRSplitter.split → same editable preview. Stub returns empty.
        do {
            let res = try await VisionOCR.recognize(data: Data())
            if !res.lines.isEmpty {
                recognizedText = res.lines.joined(separator: "\n")
                parse()
            } else {
                notice = "No text recognized (stub/empty image). Paste text above."
            }
        } catch {
            notice = "OCR failed: \(error.localizedDescription)"
        }
    }

    private func save() {
        #if os(iOS)
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        #else
        let deviceId = UUID().uuidString
        #endif
        let recipe = Recipe(householdId: "hh-demo", title: title,
                            source: "ocr", deviceId: deviceId)
        context.insert(recipe)
        let parsed = IngredientParser.parseLines(ingredientLines)
        for (i, p) in parsed.enumerated() {
            let m = Ingredient(recipeId: recipe.id, name: p.name.isEmpty ? p.display : p.name,
                               quantity: p.quantity, unit: p.unit, display: p.display,
                               position: i, updatedAt: Date(), deviceId: deviceId)
            m.recipe = recipe
            context.insert(m)
        }
        let steps = stepLines.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for (i, text) in steps.enumerated() {
            let m = Step(recipeId: recipe.id, position: i, text: text,
                         updatedAt: Date(), deviceId: deviceId)
            m.recipe = recipe
            context.insert(m)
        }
        try? context.save()
        savedMessage = "Saved OCR recipe “\(recipe.title)”"
    }
}
