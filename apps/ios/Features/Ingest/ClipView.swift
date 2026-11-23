// Smidgen — Lane 3 Capture
// apps/ios/Features/Ingest/ClipView.swift
//
// Paprika-parity ingest: URL → preview → save in <3 taps.
// Tap 1: paste URL + "Clip". Tap 2: review editable preview. Tap 3: "Save".
// POST /clip (ClipClient); saves into Lane 2 SwiftData models (Recipe + Ingredient + Step).

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

    @FocusState private var focused: Field?
    private enum Field { case url, title, ings, steps }

    var baseURL: URL

    public init(baseURL: URL = URL(string: "https://api.smidgen.local")!) {
        self.baseURL = baseURL
    }

    private var stepIndex: Int {
        if savedMessage != nil { return 2 }
        if report != nil { return 1 }
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

                    VStack(alignment: .leading, spacing: 10) {
                        Text("1 · Add a link")
                            .font(.headline)
                        Text("Paste a recipe link below and we'll pull in the details.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextField("Recipe link", text: $urlText)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focused, equals: .url)
                            #if os(iOS)
                            .keyboardType(.URL)
                            #endif
                        Button(isLoading ? "Clipping…" : "Clip recipe") {
                            Task { await runClip() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isLoading || urlText.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(14)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    if let error {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle")
                            Text(error)
                        }
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }

                    if report != nil {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("2 · Review and save")
                                .font(.headline)
                            Text("Check the details — edit anything before saving.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text("Ready to review.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let warnings = report?.warnings, !warnings.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(warnings, id: \.self) { warning in
                                        HStack(spacing: 6) {
                                            Image(systemName: "exclamationmark.triangle")
                                            Text(clipWarningText(for: warning))
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                    }
                                }
                            }
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
                            Text("Steps")
                                .font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $stepLines)
                                .frame(minHeight: 80, maxHeight: 130)
                                .padding(6)
                                .background(Color(.tertiarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .focused($focused, equals: .steps)
                        }
                        .padding(14)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14))

                        VStack(alignment: .leading, spacing: 10) {
                            Text("3 · Save")
                                .font(.headline)
                            Button("Save recipe") { save() }
                                .buttonStyle(.borderedProminent)
                                .disabled(!canSave || savedMessage != nil)
                            if !canSave {
                                Text("Add a title to save.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(14)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }

                    if let savedMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(savedMessage)
                                .foregroundStyle(.green)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Save a recipe link")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = nil }
                }
            }
        }
    }

    // MARK: - Actions

    private func runClip() async {
        isLoading = true; error = nil; savedMessage = nil
        defer { isLoading = false }
        focused = nil
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
            print("Clip failed: \(error)")
            self.error = clipServerErrorMessage(for: error)
                ?? "Couldn't clip that link. Check the address and try again."
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
        do {
            try context.save()
            savedMessage = "Saved “\(recipe.title)” (\(parsed.count) ingredients, \(steps.count) steps)"
        } catch {
            print("Clip save failed: \(error)")
            self.error = "Couldn't save that recipe. Try again."
        }
        focused = nil
    }

    private func currentDeviceId() -> String {
        #if os(iOS)
        return UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        #else
        return UUID().uuidString
        #endif
    }
}
