// Keep Cooking — Lane 5 Organize
// apps/ios/Export/ExportView.swift
//
// Export UI: multi-select recipes, pick a format, share a temp file.
// Recipe conforms to ExportableRecipe here (Lane 5 extension only).

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
    case json, md, html, paprikarecipes, yaml
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .json: return "JSON"
        case .md: return "Markdown"
        case .html: return "HTML (Schema.org)"
        case .paprikarecipes: return "Paprika"
        case .yaml: return "YAML"
        }
    }
    public var fileExtension: String {
        switch self {
        case .md: return "md"
        case .paprikarecipes: return "paprikarecipes"
        case .yaml: return "yml"
        default: return rawValue
        }
    }
    public var utType: String {
        switch self {
        case .json: return "public.json"
        case .md: return "net.daringfireball.markdown"
        case .html: return "public.html"
        case .paprikarecipes: return "com.paprika.recipes"
        case .yaml: return "public.yaml"
        }
    }
}

/// Multi-select recipe picker + format segmented control + ShareLink.
/// Export is computed on-device from SwiftData (works offline); the ShareLink
/// writes a temp file so Messages/Mail/Files all receive a real document.
public struct RecipeExportView: View {
    @Query(filter: #Predicate<Recipe> { !$0.tombstoned },
           sort: [SortDescriptor(\Recipe.title)])
    private var recipes: [Recipe]

    @State private var selectedIds: Set<String> = []
    @State private var didInitSelection = false
    @State private var format: ExportFormat = .md

    public init() {}

    private var selected: [Recipe] {
        // Preserve the library order (stable file/ZIP member order no matter
        // the toggle sequence) and drop IDs the live query no longer has.
        let valid = Set(recipes.map(\.id))
        return recipes.filter { selectedIds.contains($0.id) && valid.contains($0.id) }
    }

    private var allSelected: Bool {
        !recipes.isEmpty && selected.count == recipes.count
    }

    private var exportedText: String {
        let sel = selected
        guard !sel.isEmpty else { return "" }
        switch format {
        case .json:
            if sel.count == 1 { return exportJSON(sel[0]) }
            return "[" + sel.map { exportJSON($0) }.joined(separator: ",") + "]"
        case .md:
            return sel.map { exportMarkdown($0) }.joined(separator: "\n\n---\n\n")
        case .html:
            if sel.count == 1 { return exportHTML(sel[0]) }
            return exportHTMLPage(sel)
        case .paprikarecipes:
            return exportPaprikaJSON(sel[0])
        case .yaml:
            if sel.count == 1 { return exportYaml(sel[0]) }
            return exportYamlArray(sel)
        }
    }

    /// Binary payload for formats that are not plain text. Paprika export
    /// is a real `.paprikarecipes` ZIP (one gzip member per recipe), so
    /// Files/Mail receive an importable document — not a JSON dump.
    private var exportedData: Data? {
        guard !selected.isEmpty, format == .paprikarecipes else { return nil }
        return exportPaprikaArchive(selected)
    }

    public var body: some View {
        Form {
            Section {
                if recipes.isEmpty {
                    Text("No recipes to export.").foregroundStyle(.secondary)
                } else {
                    Button(allSelected ? "Deselect All" : "Select All") {
                        if allSelected {
                            selectedIds.removeAll()
                        } else {
                            selectedIds = Set(recipes.map(\.id))
                        }
                    }
                    ForEach(recipes, id: \.id) { r in
                        Toggle(r.title, isOn: Binding(
                            get: { selectedIds.contains(r.id) },
                            set: { on in
                                if on { selectedIds.insert(r.id) }
                                else { selectedIds.remove(r.id) }
                            }
                        ))
                    }
                }
            } header: {
                Text("Recipes")
            } footer: {
                if !recipes.isEmpty {
                    Text("\(selected.count) of \(recipes.count) selected")
                }
            }
            Section("Format") {
                Picker("Format", selection: $format) {
                    ForEach(ExportFormat.allCases) { f in Text(f.title).tag(f) }
                }
                .pickerStyle(.segmented)
            }
            Section {
                if selected.isEmpty {
                    Text("Select at least one recipe.").foregroundStyle(.secondary)
                } else if let url = writeTempFile() {
                    ShareLink(item: url) {
                        Label("Share \(format.title) file (\(selected.count) recipe\(selected.count == 1 ? "" : "s"))", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .onAppear {
            if !didInitSelection {
                didInitSelection = true
                selectedIds = Set(recipes.map(\.id))
            }
        }
        // Prune IDs the live query dropped (deleted recipes) so Select All,
        // the count, and the footer never disagree about what is visible.
        .onChange(of: recipes.map(\.id)) { _, ids in
            selectedIds = selectedIds.intersection(ids)
        }
    }

    /// Writes the current export to a temp file for ShareLink. Returns nil
    /// (hiding the row) only when there is nothing to export. Binary formats
    /// (Paprika ZIP) write bytes; text formats write UTF-8.
    private func writeTempFile() -> URL? {
        let sel = selected
        guard !sel.isEmpty else { return nil }
        let name: String
        if sel.count == 1, let r = sel.first {
            let safe = r.title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
            name = "keep-cooking-\(String(safe).prefix(40)).\(format.fileExtension)"
        } else {
            name = "keep-cooking-export-\(sel.count)-recipes.\(format.fileExtension)"
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        if let data = exportedData {
            try? data.write(to: url, options: .atomic)
        } else {
            try? exportedText.write(to: url, atomically: true, encoding: .utf8)
        }
        return (try? url.checkResourceIsReachable()) == true ? url : nil
    }
}
