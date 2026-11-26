// Keep Cooking — Lane 5 Organize
// apps/ios/Export/ExportView.swift
//
// Export UI: pick a recipe, preview JSON/Markdown/HTML, share or save to
// Files. Recipe conforms to ExportableRecipe here (Lane 5 extension only).

import SwiftUI
import SwiftData

extension Recipe: ExportableRecipe {
    public var exportIngredients: [ExportableIngredient] {
        ingredients.sorted { $0.position < $1.position }
            .map { ExportableIngredient(name: $0.name, display: $0.display.isEmpty ? $0.name : $0.display) }
    }
    public var exportSteps: [ExportableStep] {
        steps.sorted { $0.position < $1.position }
            .map { ExportableStep(position: $0.position, text: $0.text) }
    }
}

public enum ExportFormat: String, CaseIterable, Identifiable {
    case json, md, html
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .json: return "JSON"
        case .md: return "Markdown"
        case .html: return "HTML (Schema.org)"
        }
    }
    public var fileExtension: String { self == .md ? "md" : rawValue }
    public var utType: String {
        switch self {
        case .json: return "public.json"
        case .md: return "net.daringfireball.markdown"
        case .html: return "public.html"
        }
    }
}

/// Recipe picker + format segmented control + live preview + ShareLink.
/// Export is computed on-device from SwiftData (works offline); the ShareLink
/// writes a temp file so Messages/Mail/Files all receive a real document.
public struct RecipeExportView: View {
    @Query(filter: #Predicate<Recipe> { !$0.tombstoned },
           sort: [SortDescriptor(\Recipe.title)])
    private var recipes: [Recipe]

    @State private var selectedId: String?
    @State private var format: ExportFormat = .md
    @State private var savedURL: URL?

    public init() {}

    private var selected: Recipe? {
        recipes.first(where: { $0.id == selectedId }) ?? recipes.first
    }

    private var exportedText: String {
        guard let r = selected else { return "" }
        switch format {
        case .json: return exportJSON(r)
        case .md: return exportMarkdown(r)
        case .html: return exportHTML(r)
        }
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Recipe") {
                    if recipes.isEmpty {
                        Text("No recipes to export.").foregroundStyle(.secondary)
                    } else {
                        Picker("Recipe", selection: Binding(
                            get: { selected?.id ?? "" },
                            set: { selectedId = $0 }
                        )) {
                            ForEach(recipes, id: \.id) { r in
                                Text(r.title).tag(r.id)
                            }
                        }
                    }
                }
                Section("Format") {
                    Picker("Format", selection: $format) {
                        ForEach(ExportFormat.allCases) { f in Text(f.title).tag(f) }
                    }
                    .pickerStyle(.segmented)
                }
                if selected != nil {
                    Section("Preview") {
                        Text(String(exportedText.prefix(1200)))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    Section {
                        if let url = writeTempFile() {
                            ShareLink(item: url) {
                                Label("Share \(format.title) file", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Export")
        }
    }

    /// Writes the current export to a temp file for ShareLink. Returns nil
    /// (hiding the row) only when there is nothing to export.
    private func writeTempFile() -> URL? {
        guard let r = selected else { return nil }
        let safe = r.title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let name = "keep-cooking-\(String(safe).prefix(40)).\(format.fileExtension)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(String(name))
        try? exportedText.write(to: url, atomically: true, encoding: .utf8)
        return (try? url.checkResourceIsReachable()) == true ? url : nil
    }
}
