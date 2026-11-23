// Smidgen — Lane 3 Capture
// apps/ios/Features/Ingest/OCRScanView.swift
//
// Vision OCR scan: cookbook photo → recognized text → title/ingredients/steps
// editable preview → save. Uses Vision when available; otherwise OCRStub so
// the flow works in simulator / without the SDK.

import SwiftUI
import SwiftData
import PhotosUI

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
            // The CGImage drops the UIImage orientation, so pass it
            // explicitly — otherwise portrait pages can OCR rotated/empty.
            let handler = VNImageRequestHandler(
                cgImage: cg,
                orientation: CGImagePropertyOrientation(imageOrientation: image.imageOrientation),
                options: [:]
            )
            do { try handler.perform([req]) } catch { cont.resume(throwing: error) }
        }
    }
}

private extension CGImagePropertyOrientation {
    /// ImageIO uses EXIF numbering, which differs from UIImage.Orientation
    /// raw values — map explicitly instead of casting.
    init(imageOrientation: UIImage.Orientation) {
        switch imageOrientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
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

// MARK: - Progress header (shared IngestStepsHeader; see IngestStepsHeader.swift)

#if os(iOS)
private struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coord { Coord(parent: self) }
    final class Coord: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(parent: CameraPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage,
               let data = img.jpegData(compressionQuality: 0.85) {
                parent.onImage(data)
            }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
#endif

// MARK: - View

public struct OCRScanView: View {
    @Environment(\.modelContext) private var context

    @State private var recognizedText: String = ""
    @State private var title: String = ""
    @State private var ingredientLines: String = ""
    @State private var stepLines: String = ""
    @State private var notice: String?
    @State private var savedMessage: String?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var hasPickedPhoto = false
    @State private var isScanning = false
    @State private var showCamera = false

    @FocusState private var focused: Field?
    private enum Field { case paste, title, ings, steps }

    public init() {}

    private var stepIndex: Int {
        if savedMessage != nil { return 2 }
        if !title.isEmpty || !ingredientLines.isEmpty { return 1 }
        return 0
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    IngestStepsHeader(current: stepIndex)
                        .padding(.top, 8)

                    // Step 1 — Add
                    VStack(alignment: .leading, spacing: 10) {
                        Text("1 · Add a photo")
                            .font(.headline)
                        Text("Take a photo of a cookbook page, or choose one from your library.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            PhotosPicker(selection: $selectedPhoto, matching: .images) {
                                Label(hasPickedPhoto ? "Choose a different photo" : "Choose photo", systemImage: "photo")
                            }
                            .buttonStyle(.bordered)
                            #if os(iOS)
                            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                                Button {
                                    showCamera = true
                                } label: {
                                    Label("Camera", systemImage: "camera")
                                }
                                .buttonStyle(.bordered)
                            }
                            #endif
                        }
                        if isScanning {
                            ProgressView("Reading text…")
                                .font(.caption)
                        }
                        Divider()
                        Text("Or paste or edit text")
                            .font(.subheadline.bold())
                        TextEditor(text: $recognizedText)
                            .frame(minHeight: 90, maxHeight: 140)
                            .padding(6)
                            .background(Color(.tertiarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .focused($focused, equals: .paste)
                            .accessibilityIdentifier("ocr-text")
                            .accessibilityLabel("Recognized text")
                        Button("Parse text") { parse() }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("ocr-parse")
                    }
                    .padding(14)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    // Step 2 — Review
                    VStack(alignment: .leading, spacing: 10) {
                        Text("2 · Review and save")
                            .font(.headline)
                        Text("Check the details below — the first line becomes the title.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField("Title", text: $title)
                            .textFieldStyle(.roundedBorder)
                            .focused($focused, equals: .title)
                        Text("Ingredients")
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $ingredientLines)
                            .frame(minHeight: 80, maxHeight: 130)
                            .padding(6)
                            .background(Color(.tertiarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .focused($focused, equals: .ings)
                            .accessibilityLabel("Ingredients")
                        Text("Steps")
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $stepLines)
                            .frame(minHeight: 80, maxHeight: 130)
                            .padding(6)
                            .background(Color(.tertiarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .focused($focused, equals: .steps)
                            .accessibilityLabel("Steps")
                    }
                    .padding(14)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    // Step 3 — Save
                    VStack(alignment: .leading, spacing: 10) {
                        Text("3 · Save")
                            .font(.headline)
                        if let notice {
                            Text(notice)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Checked on this device.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button("Save recipe") { save() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canSave || savedMessage != nil)
                            .accessibilityIdentifier("ocr-save")
                        if !canSave {
                            Text("Add a title to save.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let savedMessage {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                Text(savedMessage)
                                    .foregroundStyle(.green)
                            }
                            .accessibilityIdentifier("ocr-saved")
                        }
                    }
                    .padding(14)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Scan a cookbook page")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = nil }
                }
            }
            #if os(iOS)
            .sheet(isPresented: $showCamera) {
                CameraPicker { data in
                    Task { await recognize(data: data) }
                }
            }
            #endif
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                hasPickedPhoto = true
                Task {
                    // Reset so re-selecting the same photo fires onChange again.
                    defer { selectedPhoto = nil }
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        await recognize(data: data)
                    } else {
                        notice = "Couldn't read that photo. Try another, or paste the text below."
                    }
                }
            }
        }
    }

    private func parse() {
        let lines = recognizedText.components(separatedBy: .newlines)
        let draft = OCRSplitter.split(lines)
        savedMessage = nil
        title = draft.title
        ingredientLines = draft.ingredientLines.joined(separator: "\n")
        stepLines = draft.stepLines.joined(separator: "\n")
        notice = "Checked on this device."
        focused = nil
    }

    private func recognize(data: Data) async {
        isScanning = true
        savedMessage = nil
        defer { isScanning = false }
        do {
            let res = try await VisionOCR.recognize(data: data)
            if !res.lines.isEmpty {
                recognizedText = res.lines.joined(separator: "\n")
                parse()
            } else {
                notice = "No text found in that photo. Try a closer shot, or paste the text below."
            }
        } catch {
            notice = "Couldn't read that photo. Try again, or paste the text below."
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
        do {
            try context.save()
            notice = nil
            savedMessage = "Saved “\(recipe.title)”"
        } catch {
            // Drop this attempt's pending graph so a retry can't persist duplicates.
            context.rollback()
            print("OCR save failed: \(error)")
            notice = "Couldn't save that recipe. Try again."
        }
        focused = nil
    }
}
