// Keep Cooking — File import UI (Paprika parity)
// apps/ios/Features/Ingest/ImportView.swift
//
// ImportView: pick a file (Files/Mail share / `.paprikarecipes` tap) →
// offline parse → cookbook choice → POST /import when online, on-device
// SwiftData save when offline. Paprika parity: "Import cookbooks from file"
// toggle recreates the file's cookbook; otherwise recipes fold into the
// picked cookbook (or the library).
//
// Wiring (see Features/Library/README + Export/README):
//   1. Info.plist `UTExportedTypeDeclarations` for `com.paprika.recipe(s)`
//      so Files/Mail route taps to the app (snippet in Export/README).
//   2. App-level `.onOpenURL` → `ImportPendingStore.stage(_:)`; ImportView
//      consumes the staged file on appear. Attaching `ImportURLHandler` to
//      any visible view also works for in-app routing.

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - File types

public extension UTType {
    /// `.paprikarecipes` — a ZIP, so it conforms to `.zip`.
    static var paprikaRecipes: UTType {
        UTType(exportedAs: "com.paprika.recipes", conformingTo: .zip)
    }
    /// `.paprikarecipe` — a single gzip member.
    static var paprikaRecipeFile: UTType {
        UTType(exportedAs: "com.paprika.recipe", conformingTo: .data)
    }
}

public enum ImportFileTypes {
    /// System-known types by extension; unknown ones fall through to the
    /// custom exported types (which need the Info.plist declarations).
    public static var readable: [UTType] {
        var types: [UTType] = [.paprikaRecipes, .paprikaRecipeFile, .zip, .html, .xml, .plainText]
        for ext in ["yml", "yaml", "mx2", "mxp", "mz2", "mmf", "fdx", "fdxz", "mcb"] {
            if let t = UTType(filenameExtension: ext), !types.contains(t) {
                types.append(t)
            }
        }
        return types
    }

    /// Extension allow-list for `onOpenURL` gating (Files/Mail staging
    /// renames freely, so check the extension, never the full name).
    public static let allowedExtensions: Set<String> = [
        "paprikarecipes", "paprikarecipe", "yml", "yaml", "html", "htm",
        "zip", "xml", "mx2", "mxp", "mz2", "mmf", "mm", "txt",
        "fdx", "fdxz", "mcb",
    ]

    public static func isImportable(_ url: URL) -> Bool {
        allowedExtensions.contains(url.pathExtension.lowercased())
    }
}

// MARK: - Pending-file store (onOpenURL → ImportView)

/// Stages an opened file URL where ImportView can consume it. Files/Mail
/// hand us a security-scoped inbox URL that can vanish — stage copies the
/// bytes into tmp immediately.
public enum ImportPendingStore {
    static let defaultsKey = "smidgen.pendingImportPath"

    @discardableResult
    public static func stage(_ url: URL) -> Bool {
        guard ImportFileTypes.isImportable(url) else { return false }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return false }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("import-\(UUID().uuidString)-\(url.lastPathComponent)")
        guard (try? data.write(to: dest, options: .atomic)) != nil else { return false }
        UserDefaults.standard.set(dest.path, forKey: defaultsKey)
        return true
    }

    public struct StagedFile: Sendable {
        public var fileName: String
        public var data: Data
    }

    public static func consume() -> StagedFile? {
        guard let path = UserDefaults.standard.string(forKey: defaultsKey) else { return nil }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return StagedFile(fileName: url.lastPathComponent, data: data)
    }
}

/// View modifier: route opened import files into a callback. Attach near the
/// app root (or any always-visible view) alongside ImportView.
/// Usage: `.modifier(ImportURLHandler(onFile: { ImportPendingStore.stage($0) }))`
/// then present ImportView, which consumes the staged file on appear.
public struct ImportURLHandler: ViewModifier {
    public var onFile: (URL) -> Void
    public init(onFile: @escaping (URL) -> Void) { self.onFile = onFile }
    public func body(content: Content) -> some View {
        content.onOpenURL { url in
            if ImportFileTypes.isImportable(url) { onFile(url) }
        }
    }
}

// MARK: - Import result

public struct FileImportResult: Sendable {
    public var fileName: String
    public var imported: Int
    public var updated: Int
    public var viaServer: Bool
    public var cookbookName: String?
    public var warnings: [String]
}

// MARK: - ImportView

/// File import: picker → offline parse preview → cookbook choice → import.
/// Parses fully offline first (parse errors never touch the network); then
/// POSTs `/import` when reachable, else saves to SwiftData on-device.
public struct ImportView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Cookbook> { !$0.tombstoned },
           sort: [SortDescriptor(\Cookbook.name)])
    private var cookbooks: [Cookbook]

    var baseURL: URL

    @State private var showPicker = false
    @State private var staged: ImportPendingStore.StagedFile?
    @State private var parsed: ParsedFile?
    @State private var isParsing = false
    @State private var isImporting = false
    @State private var progress: Double = 0
    @State private var result: FileImportResult?
    @State private var error: String?
    @State private var selectedCookbookId: String?
    @State private var importCookbooks = true

    public init(baseURL: URL? = nil) {
        self.baseURL = baseURL ?? Self.defaultBaseURL()
    }

    private static func defaultBaseURL() -> URL {
        if let s = Bundle.main.object(forInfoDictionaryKey: "SMIDGEN_API_BASE_URL") as? String,
           !s.isEmpty, let url = URL(string: s) { return url }
        if let o = UserDefaults.standard.string(forKey: "smidgen.apiBaseURL"),
           !o.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let url = URL(string: o.trimmingCharacters(in: .whitespacesAndNewlines)) { return url }
        return URL(string: "https://keepcooking.app/api")!
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    stepChoose
                    if isParsing {
                        ProgressView("Reading file…")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let parsed { stepReview(parsed) }
                    if let result { stepResult(result) }
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
            }
            .navigationTitle("Import from file")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showPicker,
                          allowedContentTypes: ImportFileTypes.readable,
                          allowsMultipleSelection: true) { res in
                switch res {
                case .success(let urls): stagePicked(urls)
                case .failure: error = "Couldn't open that file. Try again."
                }
            }
            .onAppear { consumePending() }
        }
    }

    // MARK: 1 · Choose

    private var stepChoose: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("1 · Choose a file")
                .font(.headline)
            Text("Paprika `.paprikarecipes` / `.paprikarecipe`, YAML, HTML export, or any format Paprika imports (`.mx2`, `.mmf`, `.fdx`, Pepperplate `.zip`, Yum `.xml`…). Parsed on this device first — nothing uploads until you tap Import.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                result = nil; error = nil; showPicker = true
            } label: {
                Label(staged == nil ? "Choose file" : "Choose a different file", systemImage: "doc.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            if let staged {
                HStack(spacing: 6) {
                    Image(systemName: "doc.fill").foregroundStyle(.secondary)
                    Text(staged.fileName).font(.caption).lineLimit(1)
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: 2 · Review

    private func stepReview(_ file: ParsedFile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("2 · Review")
                .font(.headline)
            Text("\(file.recipes.count) recipe\(file.recipes.count == 1 ? "" : "s") found\(file.recipes.count <= 5 ? ":" : " (first 5 shown):")")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ForEach(Array(file.recipes.prefix(5).enumerated()), id: \.offset) { _, r in
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.title).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text("\(r.ingredients.count) ingredients · \(r.steps.count) steps\(r.paprikaUid == nil ? " · no Paprika id (always creates new)" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
            if !file.warnings.isEmpty {
                ForEach(file.warnings, id: \.self) { w in
                    Label(w, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            // Paprika parity: cookbook handling.
            Toggle("Import cookbooks from file", isOn: $importCookbooks)
                .font(.subheadline)
            if importCookbooks, let hint = file.cookbookHint ?? file.recipes.first?.cookbook {
                Text("Creates cookbook “\(hint)” (or adds to it if it exists).")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Add to cookbook", selection: $selectedCookbookId) {
                    Text("Library (no cookbook)").tag(nil as String?)
                    ForEach(cookbooks, id: \.id) { c in
                        Text(c.name).tag(c.id as String?)
                    }
                }
                .font(.subheadline)
            }
            Text("3 · Import")
                .font(.headline)
                .padding(.top, 4)
            if isImporting {
                ProgressView(value: progress) {
                    Text("Importing…").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Button("Import \(file.recipes.count) recipe\(file.recipes.count == 1 ? "" : "s")") {
                    Task { await runImport() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(file.recipes.isEmpty)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: 3 · Result

    private func stepResult(_ r: FileImportResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Imported \(r.imported) · updated \(r.updated)")
                    .font(.headline)
            }
            Text(r.viaServer
                 ? "Saved via the server (re-imports update in place by Paprika id)."
                 : "Saved on this device (offline) — re-imports match by title until the next sync.")
                .font(.caption).foregroundStyle(.secondary)
            if let c = r.cookbookName {
                Text("Cookbook: \(c)").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(r.warnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Actions

    private func consumePending() {
        guard staged == nil, parsed == nil else { return }
        if let pending = ImportPendingStore.consume() {
            staged = pending
            parse(pending)
        }
    }

    private func stagePicked(_ urls: [URL]) {
        error = nil; result = nil; parsed = nil; staged = nil
        guard let url = urls.first else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard ImportFileTypes.isImportable(url),
              let data = try? Data(contentsOf: url)
        else {
            error = "That file type can't be imported. Try `.paprikarecipes`, `.yml`, or `.zip`."
            return
        }
        let file = ImportPendingStore.StagedFile(fileName: url.lastPathComponent, data: data)
        staged = file
        parse(file)
    }

    private func parse(_ file: ImportPendingStore.StagedFile) {
        isParsing = true
        defer { isParsing = false }
        var pf = PaprikaImportParser.parseFile(named: file.fileName, data: file.data)
        // Surface the file's cookbook for the picker toggle.
        if pf.cookbookHint == nil { pf.cookbookHint = pf.recipes.first?.cookbook }
        parsed = pf
        if pf.recipes.isEmpty, pf.warnings.isEmpty {
            error = "No recipes found in `\(file.fileName)`."
        }
    }

    private func runImport() async {
        guard let file = parsed, let staged else { return }
        isImporting = true; progress = 0; error = nil; result = nil
        defer { isImporting = false }
        let cookbookName = importCookbooks
            ? (file.cookbookHint ?? file.recipes.first?.cookbook)
            : cookbooks.first(where: { $0.id == selectedCookbookId })?.name
        // 1) Try the server (uid upsert) — any failure falls back to device.
        if let body = encodeImportBody(recipes: file.recipes, cookbook: importCookbooks ? cookbookName : nil,
                                       importCookbooks: importCookbooks) {
            do {
                let client = makeClient()
                let res = try await client.postImport(body)
                await MainActor.run {
                    self.progress = 1
                    self.result = FileImportResult(
                        fileName: staged.fileName,
                        imported: res.imported, updated: res.updated,
                        viaServer: true, cookbookName: cookbookName,
                        warnings: (res.warnings ?? []) + file.warnings)
                }
                return
            } catch {
                print("Import POST failed (\(error)) — saving on-device instead.")
            }
        }
        // 2) Offline: save into SwiftData directly (create; title-match updates).
        await MainActor.run {
            let outcome = saveLocally(file.recipes, cookbookName: importCookbooks ? nil : cookbookName,
                                      createCookbookNamed: importCookbooks ? cookbookName : nil)
            self.progress = 1
            self.result = FileImportResult(
                fileName: staged.fileName,
                imported: outcome.imported, updated: outcome.updated,
                viaServer: false, cookbookName: cookbookName,
                warnings: ["Server unreachable — saved on this device."] + file.warnings)
        }
    }

    private func makeClient() -> ImportAPIClient {
        let did = DeviceAuth.currentDeviceId()
        let signer = DeviceAuth.requestSigner(deviceId: did).map { s in
            AnySendableSigner { s.signedRequest($0) }
        }
        return ImportAPIClient(baseURL: baseURL, userId: SyncConfig.userId, deviceId: did, signer: signer)
    }

    /// On-device save. No paprikaUid column exists on Recipe (Core is
    /// frozen), so dedupe is by case-insensitive title: matches are updated
    /// in place (ingredients/steps replaced), everything else is created.
    private func saveLocally(_ recipes: [ParsedRecipe],
                             cookbookName: String?,
                             createCookbookNamed: String?) -> (imported: Int, updated: Int) {
        let deviceId = DeviceAuth.currentDeviceId()
        var imported = 0, updated = 0
        var cookbook: Cookbook?
        if let name = createCookbookNamed ?? cookbookName {
            if let existing = cookbooks.first(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                cookbook = existing
            } else if createCookbookNamed != nil {
                let c = Cookbook(householdId: "hh-demo", name: name, deviceId: deviceId)
                context.insert(c)
                cookbook = c
            } else {
                cookbook = cookbooks.first(where: { $0.name == name })
            }
        }
        let total = max(recipes.count, 1)
        for (i, pr) in recipes.enumerated() {
            let match = (try? context.fetch(FetchDescriptor<Recipe>()))?.first {
                !$0.tombstoned && $0.title.localizedCaseInsensitiveCompare(pr.title) == .orderedSame
            }
            let recipe: Recipe
            if let match {
                recipe = match
                for old in match.ingredients { context.delete(old) }
                match.ingredients.removeAll()
                for old in match.steps { context.delete(old) }
                match.steps.removeAll()
                match.recipeDescription = pr.recipeDescription
                match.servings = pr.servings
                match.prepMinutes = pr.prepMinutes
                match.cookMinutes = pr.cookMinutes
                match.rating = pr.rating
                match.isFavorite = pr.isFavorite
                match.source = pr.source
                match.sourceUrl = pr.sourceUrl
                match.categories = pr.categories
                match.updatedAt = Date()
                match.deviceId = deviceId
                updated += 1
            } else {
                recipe = Recipe(householdId: "hh-demo", title: pr.title,
                    recipeDescription: pr.recipeDescription, servings: pr.servings,
                    prepMinutes: pr.prepMinutes, cookMinutes: pr.cookMinutes,
                    rating: pr.rating, isFavorite: pr.isFavorite,
                    source: pr.source.isEmpty ? "import" : pr.source, sourceUrl: pr.sourceUrl,
                    categories: pr.categories, updatedAt: Date(), deviceId: deviceId)
                context.insert(recipe)
                imported += 1
            }
            for (j, ing) in pr.ingredients.enumerated() {
                let m = Ingredient(recipeId: recipe.id, name: ing.name, display: ing.display,
                    position: ing.position >= 0 ? ing.position : j,
                    updatedAt: Date(), deviceId: deviceId)
                m.recipe = recipe
                context.insert(m)
            }
            for (j, st) in pr.steps.enumerated() {
                let m = Step(recipeId: recipe.id, position: st.position >= 0 ? st.position : j,
                    text: st.text, updatedAt: Date(), deviceId: deviceId)
                m.recipe = recipe
                context.insert(m)
            }
            if let c = cookbook, !c.recipeIds.contains(recipe.id) {
                c.recipeIds = c.recipeIds + [recipe.id]
                c.updatedAt = Date()
            }
            progress = Double(i + 1) / Double(total) * 0.9
        }
        do {
            try context.save()
        } catch {
            print("Import local save failed: \(error)")
            self.error = "Couldn't save those recipes on this device. Try again."
            return (0, 0)
        }
        progress = 1
        return (imported, updated)
    }
}
