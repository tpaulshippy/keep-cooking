// Smidgen — Lane 3 Capture
// apps/ios/Features/Ingest/CaptionsImportView.swift
//
// Social caption import: TikTok / IG / YT link + caption paste
// → ClipRequest{url, caption} → POST /clip → editable preview → save.
// Covers JS/login-wall pages where jsonld/reader fail (caption fallback).

import SwiftUI
import SwiftData

public enum SocialPlatform: String, CaseIterable, Identifiable {
    case tiktok = "TikTok"
    case instagram = "Instagram"
    case youtube = "YouTube"
    public var id: String { rawValue }
    var clipSource: ClipSource {
        switch self {
        case .tiktok: return .tiktok
        case .instagram: return .instagram
        case .youtube: return .youtube
        }
    }
}

public struct CaptionsImportView: View {
    @Environment(\.modelContext) private var context

    @State private var platform: SocialPlatform = .tiktok
    @State private var linkText: String = ""
    @State private var captionText: String = ""
    @State private var report: ClipReport?
    @State private var isLoading = false
    @State private var error: String?

    @State private var title: String = ""
    @State private var ingredientLines: String = ""
    @State private var stepLines: String = ""
    @State private var savedMessage: String?

    var baseURL: URL

    public init(baseURL: URL = URL(string: "https://api.smidgen.local")!) {
        self.baseURL = baseURL
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Source") {
                    Picker("Platform", selection: $platform) {
                        ForEach(SocialPlatform.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    TextField("Video/post link (optional)", text: $linkText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("Caption / description paste").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $captionText).frame(minHeight: 140)
                    Button(isLoading ? "Importing…" : "Import caption") {
                        Task { await runImport() }
                    }
                    .disabled(isLoading || captionText.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }

                if report != nil {
                    Section("Preview (editable)") {
                        TextField("Title", text: $title)
                        Text("Ingredients").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $ingredientLines).frame(minHeight: 120)
                        Text("Steps").font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $stepLines).frame(minHeight: 120)
                    }
                    Section {
                        Button("Save recipe") { save() }
                    }
                }

                if let savedMessage {
                    Section { Text(savedMessage).foregroundStyle(.green) }
                }
            }
            .navigationTitle("Caption import")
        }
        .onChange(of: captionText) { _, _ in
            // Live local parse preview before server round-trip.
            if report == nil {
                let parsed = IngredientParser.parseLines(captionText)
                if !parsed.isEmpty {
                    ingredientLines = parsed.map { $0.display }.joined(separator: "\n")
                }
            }
        }
    }

    private func runImport() async {
        isLoading = true; error = nil; savedMessage = nil
        defer { isLoading = false }
        let url = linkText.trimmingCharacters(in: .whitespaces)
        let req = ClipRequest(
            url: url.isEmpty ? nil : url,
            caption: captionText,
            source: platform.clipSource
        )
        do {
            let client = ClipClient(baseURL: baseURL)
            let rep = try await client.clip(req)
            print(client.logEvent(for: rep, requestURL: req.url).description)
            report = rep
            title = rep.recipe.title
            // Prefer server parse; fall back to local IngredientParser.
            let ings = rep.recipe.ingredients ?? []
            ingredientLines = ings.isEmpty
                ? IngredientParser.parseLines(captionText).map { $0.display }.joined(separator: "\n")
                : ings.map { $0.display ?? $0.name }.joined(separator: "\n")
            stepLines = (rep.recipe.steps ?? []).map { $0.text }.joined(separator: "\n")
        } catch {
            self.error = "Import failed: \(error.localizedDescription)"
        }
    }

    private func save() {
        #if os(iOS)
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        #else
        let deviceId = UUID().uuidString
        #endif
        let recipe = Recipe(
            householdId: "hh-demo",
            title: title.isEmpty ? (report?.recipe.title ?? "Untitled") : title,
            source: "caption:\(platform.rawValue.lowercased())",
            sourceUrl: linkText,
            deviceId: deviceId
        )
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
        savedMessage = "Saved “\(recipe.title)” from \(platform.rawValue)"
    }
}
