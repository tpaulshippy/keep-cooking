// Smidgen — Lane 3 Capture
// apps/ios/Features/Ingest/ClipView.swift
//
// Paprika-parity ingest: URL → preview → save in <3 taps.
// Tap 1: paste URL + "Clip". Tap 2: review editable preview. Tap 3: "Save".
// POST /clip (ClipClient); strategies jsonld/reader/caption logged PII-safe.
// Saves into Lane 2 SwiftData models (Recipe + Ingredient + Step).

import SwiftUI
import SwiftData

public struct ClipView: View {
    @Environment(\.modelContext) private var context

    @State private var urlText: String = ""
    @State private var report: ClipReport?
    @State private var isLoading = false
    @State private var error: String?
    @State private var savedMessage: String?

    // Editable preview state
    @State private var title: String = ""
    @State private var ingredientLines: String = ""
    @State private var stepLines: String = ""

    var baseURL: URL

    public init(baseURL: URL = URL(string: "https://api.smidgen.local")!) {
        self.baseURL = baseURL
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Recipe URL") {
                    TextField("https://…", text: $urlText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.URL)
                        #endif
                    Button(isLoading ? "Clipping…" : "Clip recipe") {
                        Task { await runClip() }
                    }
                    .disabled(isLoading || urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }

                if let report {
                    Section("Preview · \(report.strategy.rawValue) · confidence \(confidenceText(report))") {
                        TextField("Title", text: $title)
                        Text("Ingredients (one per line)").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $ingredientLines).frame(minHeight: 120)
                        Text("Steps (one per line)").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $stepLines).frame(minHeight: 120)
                        if let warnings = report.warnings, !warnings.isEmpty {
                            ForEach(warnings, id: \.self) { Text("⚠︎ \($0)").font(.caption) }
                        }
                    }
                    Section {
                        Button("Save recipe") { save() }
                    }
                }

                if let savedMessage {
                    Section { Text(savedMessage).foregroundStyle(.green) }
                }
            }
            .navigationTitle("Clip URL")
        }
    }

    // MARK: - Actions

    private func runClip() async {
        isLoading = true; error = nil; savedMessage = nil
        defer { isLoading = false }
        let req = ClipRequest(url: urlText.trimmingCharacters(in: .whitespaces), source: .url)
        do {
            let client = ClipClient(baseURL: baseURL)
            let rep = try await client.clip(req)
            // PII-safe log: strategy + host + confidence only.
            print(client.logEvent(for: rep, requestURL: req.url).description)
            report = rep
            title = rep.recipe.title
            ingredientLines = (rep.recipe.ingredients ?? []).map {
                $0.display ?? "\($0.name)"
            }.joined(separator: "\n")
            stepLines = (rep.recipe.steps ?? []).map { $0.text }.joined(separator: "\n")
        } catch {
            self.error = "Clip failed: \(error.localizedDescription)"
        }
    }

    private func save() {
        let deviceId = currentDeviceId()
        let recipe = Recipe(
            householdId: "hh-demo",
            title: title.isEmpty ? (report?.recipe.title ?? "Untitled") : title,
            recipeDescription: report?.recipe.description ?? "",
            servings: report?.recipe.servings ?? 4,
            prepMinutes: report?.recipe.prepMinutes,
            cookMinutes: report?.recipe.cookMinutes,
            source: report?.recipe.source ?? "clip",
            sourceUrl: report?.recipe.sourceUrl ?? urlText,
            deviceId: deviceId
        )
        context.insert(recipe)
        let parsed = IngredientParser.parseLines(ingredientLines)
        for (i, p) in parsed.enumerated() {
            let m = Ingredient(
                recipeId: recipe.id, name: p.name.isEmpty ? p.display : p.name,
                quantity: p.quantity, unit: p.unit, display: p.display,
                position: i, updatedAt: Date(), deviceId: deviceId
            )
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
        savedMessage = "Saved “\(recipe.title)” (\(parsed.count) ingredients, \(steps.count) steps)"
    }

    private func confidenceText(_ r: ClipReport) -> String {
        String(format: "%.2f", r.confidence ?? 0)
    }

    private func currentDeviceId() -> String {
        #if os(iOS)
        return UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        #else
        return UUID().uuidString
        #endif
    }
}
