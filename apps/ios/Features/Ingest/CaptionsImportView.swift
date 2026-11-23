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

private struct CaptionStepsHeader: View {
    var current: Int
    private let steps = ["Add", "Review", "Save"]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(steps.indices, id: \.self) { i in
                VStack(spacing: 4) {
                    Circle()
                        .fill(i <= current ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: 22, height: 22)
                        .overlay(
                            Text("\(i + 1)")
                                .font(.caption2.bold())
                                .foregroundStyle(i <= current ? .white : .secondary)
                        )
                    Text(steps[i])
                        .font(.caption2)
                        .foregroundStyle(i == current ? .primary : .secondary)
                }
                if i < steps.count - 1 {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(height: 1)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 16)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(current + 1) of 3: \(steps[current])")
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

    @FocusState private var focused: Field?
    private enum Field { case link, caption, title, ings, steps }

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
                    CaptionStepsHeader(current: stepIndex)
                        .padding(.top, 8)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("1 · Add a video")
                            .font(.headline)
                        Text("Pick where the video is from, then paste its caption.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Picker("Platform", selection: $platform) {
                            ForEach(SocialPlatform.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        TextField("Video link (optional)", text: $linkText)
                            .textFieldStyle(.roundedBorder)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focused, equals: .link)
                        Text("Paste or edit text")
                            .font(.subheadline.bold())
                        TextEditor(text: $captionText)
                            .frame(minHeight: 90, maxHeight: 140)
                            .padding(6)
                            .background(Color(.tertiarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .focused($focused, equals: .caption)
                        Button(isLoading ? "Importing…" : "Import caption") {
                            Task { await runImport() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isLoading || captionText.trimmingCharacters(in: .whitespaces).isEmpty)
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
                            Text("Checked on this device.")
                                .font(.caption)
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
                                .disabled(!canSave)
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
            .navigationTitle("Save from video")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = nil }
                }
            }
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
        focused = nil
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
            self.error = "Couldn't import that caption. Check the text and try again."
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
        focused = nil
    }
}
