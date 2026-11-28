// Keep Cooking — Lane 3 Capture
// apps/ios/Features/Ingest/PasteImportView.swift
//
// Generic free-text import: paste any recipe text (not tied to a social
// platform) → Preview (local IngredientParser) or Import (POST /clip
// {caption, source: text}) → editable preview → save. Server failure falls
// back to the local parse so the flow still works offline.

import SwiftUI
import SwiftData

public struct PasteImportView: View {
    @Environment(\.modelContext) private var context

    @State private var pastedText: String = ""
    @State private var report: ClipReport?
    @State private var isLoading = false
    @State private var error: String?
    @State private var saveError: String?
    /// True when the visible preview predates a failed refresh — Save stays
    /// disabled so a stale recipe can't be persisted as if it were fresh.
    @State private var reportStale = false

    @State private var title: String = ""
    @State private var ingredientLines: String = ""
    @State private var stepLines: String = ""
    @State private var savedMessage: String?

    @FocusState private var focused: Field?
    private enum Field { case paste, title, ings, steps }

    var baseURL: URL

    private static func defaultBaseURL() -> URL {
        if let s = Bundle.main.object(forInfoDictionaryKey: "SMIDGEN_API_BASE_URL") as? String,
           !s.isEmpty, let url = URL(string: s) {
            return url
        }
        return URL(string: SyncConfig.prodBaseURL)!
    }

    public init(baseURL: URL? = nil) {
        self.baseURL = baseURL ?? Self.defaultBaseURL()
    }

    private var stepIndex: Int {
        if savedMessage != nil { return 2 }
        if report != nil || !title.isEmpty || !ingredientLines.isEmpty { return 1 }
        return 0
    }

    private var canSave: Bool {
        isSavableTitle(title)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    IngestStepsHeader(current: stepIndex)
                        .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("1 · Paste recipe text")
                            .font(.headline)
                        Text("Paste any recipe — from a site, an email, or your own notes.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $pastedText)
                            .frame(minHeight: 120, maxHeight: 180)
                            .padding(6)
                            .background(Color(.tertiarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .focused($focused, equals: .paste)
                            .accessibilityLabel("Recipe text")
                            .accessibilityIdentifier("paste-text")
                            .disabled(isLoading)
                        HStack(spacing: 10) {
                            Button("Preview") { previewLocally() }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("paste-preview")
                                .disabled(isLoading || pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button(isLoading ? "Importing…" : "Import") {
                                Task { await runImport() }
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("paste-import")
                            .disabled(isLoading || pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        Text("Preview works offline. Import uses the recipe service when online.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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

                    if report != nil || !title.isEmpty || !ingredientLines.isEmpty {
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
                                .accessibilityIdentifier("paste-title")
                            Text("Ingredients")
                                .font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $ingredientLines)
                                .frame(minHeight: 80, maxHeight: 130)
                                .padding(6)
                                .background(Color(.tertiarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .focused($focused, equals: .ings)
                                .accessibilityLabel("Ingredients")
                                .accessibilityIdentifier("paste-ingredients")
                            Text("Steps")
                                .font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $stepLines)
                                .frame(minHeight: 80, maxHeight: 130)
                                .padding(6)
                                .background(Color(.tertiarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .focused($focused, equals: .steps)
                                .accessibilityLabel("Steps")
                                .accessibilityIdentifier("paste-steps")
                        }
                        .padding(14)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14))

                        VStack(alignment: .leading, spacing: 10) {
                            Text("3 · Save")
                                .font(.headline)
                            if let saveError {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.circle")
                                    Text(saveError)
                                }
                                .font(.caption)
                                .foregroundStyle(.red)
                            }
                            Button("Save recipe") { save() }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("paste-save")
                                .disabled(!canSave || savedMessage != nil || isLoading || reportStale)
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
                        .accessibilityIdentifier("paste-saved")
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Paste recipe text")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = nil }
                }
            }
        }
        .onChange(of: pastedText) { _, _ in
            // Live local parse preview before any server round-trip.
            if report == nil && savedMessage == nil {
                let parsed = IngredientParser.parseLines(pastedText)
                if !parsed.isEmpty {
                    ingredientLines = parsed.map { $0.display }.joined(separator: "\n")
                }
            }
        }
    }

    /// Offline-first local preview: first non-empty line = title,
    /// quantity-led lines = ingredients (via IngredientParser), rest = steps.
    private func previewLocally() {
        let lines = pastedText.components(separatedBy: .newlines)
        let draft = OCRSplitter.split(lines)
        savedMessage = nil
        reportStale = false
        error = nil
        // Keep a server title if one already exists and the local split
        // found nothing better — otherwise adopt the local draft.
        if !draft.title.isEmpty { title = draft.title }
        ingredientLines = draft.ingredientLines.joined(separator: "\n")
        stepLines = draft.stepLines.joined(separator: "\n")
        focused = nil
    }

    private func runImport() async {
        isLoading = true; error = nil; saveError = nil; savedMessage = nil; reportStale = false
        defer { isLoading = false }
        focused = nil
        let req = ClipRequest(caption: pastedText, source: .text)
        do {
            #if os(iOS)
            // Enroll before the first signed POST (fresh installs would get
            // 401 in prod). Re-read afterwards — 409 recovery rotates the id.
            await DeviceAuth.enrollIfNeeded(baseURL: baseURL, deviceId: DeviceAuth.currentDeviceId())
            let clipDeviceId = DeviceAuth.currentDeviceId()
            #else
            let clipDeviceId = UUID().uuidString
            #endif
            let client = ClipClient(baseURL: baseURL,
                betaToken: nil,
                userId: SyncConfig.userId, deviceId: clipDeviceId,
                signer: DeviceAuth.requestSigner(deviceId: clipDeviceId))
            let rep = try await client.clip(req)
            print(client.logEvent(for: rep, requestURL: req.url).description)
            report = rep
            title = rep.recipe.title
            // Prefer server parse; fall back to local IngredientParser.
            let ings = rep.recipe.ingredients ?? []
            ingredientLines = ings.isEmpty
                ? IngredientParser.parseLines(pastedText).map { $0.display }.joined(separator: "\n")
                : ings.map { $0.display ?? $0.name }.joined(separator: "\n")
            stepLines = (rep.recipe.steps ?? []).map { $0.text }.joined(separator: "\n")
        } catch {
            print("Paste import failed: \(error)")
            // Offline fallback: keep a usable local draft so the user can
            // still review + save. Only mark stale when a prior server
            // preview exists (a retry must succeed first in that case).
            reportStale = report != nil
            previewLocally()
            self.error = clipServerErrorMessage(for: error)
                ?? "Couldn't reach the recipe service — showing an offline preview instead."
        }
    }

    private func save() {
        let deviceId = DeviceAuth.currentDeviceId()
        let trimmed = cleanTitle(title)
        let recipe = Recipe(
            householdId: "hh-demo",
            title: trimmed.isEmpty ? (report?.recipe.title ?? trimmed) : trimmed,
            source: "text",
            sourceUrl: "",
            deviceId: deviceId
        )
        context.insert(recipe)
        // Track this attempt's inserts so a failed save can delete exactly
        // these objects — rollback() would also discard other views'
        // unsaved changes in the shared context.
        var inserted: [any PersistentModel] = [recipe]
        let parsed = IngredientParser.parseLines(ingredientLines)
        for (i, p) in parsed.enumerated() {
            let m = Ingredient(recipeId: recipe.id, name: p.name.isEmpty ? p.display : p.name,
                               quantity: p.quantity, unit: p.unit, display: p.display,
                               position: i, updatedAt: Date(), deviceId: deviceId)
            m.recipe = recipe
            context.insert(m)
            inserted.append(m)
        }
        let steps = stepLines.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for (i, text) in steps.enumerated() {
            let m = Step(recipeId: recipe.id, position: i, text: text,
                         updatedAt: Date(), deviceId: deviceId)
            m.recipe = recipe
            context.insert(m)
            inserted.append(m)
        }
        do {
            try context.save()
            saveError = nil
            savedMessage = "Saved “\(recipe.title)” from pasted text"
        } catch {
            inserted.forEach { context.delete($0) }
            print("Paste save failed: \(error)")
            saveError = "Couldn't save that recipe. Try again."
        }
        focused = nil
    }
}
