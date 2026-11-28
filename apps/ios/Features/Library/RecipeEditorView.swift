// Keep Cooking — Recipe editor (iOS lane, recipe-editor feature)
// apps/ios/Features/Library/RecipeEditorView.swift
//
// Dark-modal "Edit Recipe" sheet matching the Paprika-style reference:
// top-left red X (discard draft), top-right blue checkmark (save),
// collapsible DisclosureGroup sections (Info expanded by default), card
// rows bound to a draft copy. Save writes back through the same store/sync
// path the detail view uses (mutate + updatedAt bump + context.save());
// Cancel discards the draft. Difficulty, notes, and nutritionText live on
// the synced Recipe model (envelope keys, LWW) — never local-only.
// Cookbook is display-only (membership read from Cookbook models).
// Times map to prepMinutes/cookMinutes; Total is stored when edited,
// otherwise preserved/derived.

import SwiftUI
import SwiftData

/// Difficulty options. The selection is stored on the synced Recipe model
/// (`difficulty`, nil = unspecified) — never local-only.
public enum RecipeDifficulty: String, CaseIterable, Hashable {
    case unspecified = "Unspecified"
    case easy = "Easy"
    case medium = "Medium"
    case hard = "Hard"

    /// Stored model value → picker selection (unknown strings are unspecified).
    static func fromStored(_ raw: String?) -> RecipeDifficulty {
        RecipeDifficulty(rawValue: raw ?? "") ?? .unspecified
    }
}

public struct RecipeEditorView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var cookbooks: [Cookbook]

    private let recipe: Recipe

    @State private var infoExpanded = true
    @State private var timesExpanded = true
    @State private var descriptionExpanded = true
    @State private var ingredientsExpanded = true
    @State private var directionsExpanded = true
    @State private var notesExpanded = false
    @State private var nutritionExpanded = false

    @State private var title: String
    @State private var rating: Double?
    @State private var servingsText: String
    @State private var servingsValue: Double
    @State private var sourceUrl: String
    @State private var difficulty: RecipeDifficulty
    @State private var categoriesText: String
    @State private var photoUrlText: String

    @State private var prepText: String
    @State private var cookText: String
    @State private var descriptionText: String
    @State private var ingredientsText: String
    @State private var directionsText: String
    @State private var notesText: String
    @State private var nutritionText: String
    @State private var nutritionShowsTable = false

    /// Original prep/cook: a foreign explicit total is preserved until the
    /// user edits times, at which point the stored total is recomputed.
    private let originalPrepMinutes: Int?
    private let originalCookMinutes: Int?

    /// Original serialized lines, used to match edited lines back to their
    /// model objects so untouched rows round-trip with zero data loss.
    private let originalIngredientLines: [String]
    private let originalStepTexts: [String]

    public init(recipe: Recipe) {
        self.recipe = recipe
        _title = State(initialValue: recipe.title)
        _rating = State(initialValue: recipe.rating)
        _servingsValue = State(initialValue: recipe.servings)
        _servingsText = State(initialValue: Self.servingsString(recipe.servings))
        _sourceUrl = State(initialValue: recipe.sourceUrl)
        _difficulty = State(initialValue: RecipeDifficulty.fromStored(recipe.difficulty))
        _categoriesText = State(initialValue: recipe.categories.joined(separator: ", "))
        _photoUrlText = State(initialValue: recipe.photoThumb ?? recipe.photoOriginal ?? "")
        _prepText = State(initialValue: recipe.prepMinutes.map(String.init) ?? "")
        _cookText = State(initialValue: recipe.cookMinutes.map(String.init) ?? "")
        _descriptionText = State(initialValue: recipe.recipeDescription)
        let ings = recipe.ingredients.sorted { $0.position < $1.position }
        let ingLines = ings.map(Self.ingredientLine(for:))
        _ingredientsText = State(initialValue: ingLines.joined(separator: "\n"))
        let steps = recipe.steps.sorted { $0.position < $1.position }.map { $0.text }
        _directionsText = State(initialValue: steps.joined(separator: "\n\n"))
        _notesText = State(initialValue: recipe.notes ?? "")
        _nutritionText = State(initialValue: recipe.nutritionText ?? "")
        self.originalPrepMinutes = recipe.prepMinutes
        self.originalCookMinutes = recipe.cookMinutes
        self.originalIngredientLines = ingLines
        self.originalStepTexts = steps
    }

    // MARK: - Line serialization (lossless for untouched rows)

    /// One line per ingredient. Prefers the stored display string, but seeds
    /// carry quantity-only displays ("3 tbsp") alongside the food name
    /// ("white miso") — combine those so the name survives the round-trip.
    /// Header-style rows (e.g. "Pumpkin Filling:") pass through verbatim.
    static func ingredientLine(for ing: Ingredient) -> String {
        let display = ing.display.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = ing.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if display.isEmpty { return name }
        if name.isEmpty { return display }
        if display.localizedCaseInsensitiveContains(name)
            || name.localizedCaseInsensitiveContains(display) { return display }
        return "\(display) \(name)"
    }

    private static func servingsString(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(v)) : String(v)
    }

    static func formatMinutes(_ m: Int?) -> String {
        guard let m, m > 0 else { return "" }
        if m < 60 { return "\(m) min" }
        let h = m / 60, r = m % 60
        return r == 0 ? "\(h) hr" : "\(h) hr \(r) min"
    }

    // MARK: - Derived display values

    /// Renderable photos only: absolute http(s) URLs (relative R2 keys
    /// have no public-URL resolver yet and render as placeholders).
    /// Matches the detail view's photoURL(forKey:) behavior.
    private var photoCount: Int {
        Array(Set(
            [photoUrlText, recipe.photoThumb ?? "", recipe.photoOriginal ?? ""]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter {
                    guard !$0.isEmpty, let u = URL(string: $0),
                          let s = u.scheme?.lowercased()
                    else { return false }
                    return s == "http" || s == "https"
                }
        )).count
    }

    private var sourceDomain: String {
        let raw = sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return recipe.source.isEmpty ? "Source" : recipe.source }
        if let url = URL(string: raw), let host = url.host, !host.isEmpty { return host }
        if let url = URL(string: "https://\(raw)"), let host = url.host, !host.isEmpty { return host }
        return recipe.source.isEmpty ? "Source" : recipe.source
    }

    private var prepMinutes: Int? {
        Int(prepText.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
    }

    private var cookMinutes: Int? {
        Int(cookText.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
    }

    private var derivedTotalMinutes: Int? {
        let p = prepMinutes ?? 0, c = cookMinutes ?? 0
        let total = p + c
        return total > 0 ? total : nil
    }

    /// True once the user edits prep/cook. A stored foreign total is shown
    /// until then; afterwards the stored total is recomputed from the edits.
    private var timesEdited: Bool {
        prepMinutes != originalPrepMinutes || cookMinutes != originalCookMinutes
    }

    private var shownTotalMinutes: Int? {
        timesEdited ? derivedTotalMinutes : (recipe.totalMinutes ?? derivedTotalMinutes)
    }

    /// Display-only: first live cookbook containing this recipe, else
    /// placeholder. Tombstoned cookbooks never surface here.
    private var cookbookName: String {
        cookbooks.first { !$0.tombstoned && $0.recipeIds.contains(recipe.id) }?.name ?? "My Cookbook"
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Body

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    section(icon: nil, title: "Info", isExpanded: $infoExpanded, id: "info") {
                        infoCard
                    }
                    section(icon: "timer", title: "Times", isExpanded: $timesExpanded, id: "times") {
                        timesCard
                    }
                    section(icon: "text.quote", title: "Description", isExpanded: $descriptionExpanded, id: "description") {
                        textCard(text: $descriptionText, id: "recipe-editor-description", minHeight: 140)
                    }
                    section(icon: "list.bullet", title: "Ingredients", isExpanded: $ingredientsExpanded, id: "ingredients") {
                        textCard(text: $ingredientsText, id: "recipe-editor-ingredients-text", minHeight: 220, font: .body)
                    }
                    section(icon: "list.number", title: "Directions", isExpanded: $directionsExpanded, id: "directions") {
                        textCard(text: $directionsText, id: "recipe-editor-directions-text", minHeight: 220)
                    }
                    section(icon: "note.text", title: "Notes", isExpanded: $notesExpanded, id: "notes") {
                        textCard(text: $notesText, id: "recipe-editor-notes-text", minHeight: 120)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        DisclosureGroup(isExpanded: $nutritionExpanded) {
                            nutritionCard
                        } label: {
                            sectionLabel(icon: "chart.pie", title: "Nutrition")
                                .accessibilityIdentifier("recipe-editor-section-nutrition")
                        }
                        .tint(.secondary)
                    }
                    .padding(.horizontal)
                }
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Color(.systemBackground))
            .navigationTitle("Edit Recipe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.red)
                            .frame(width: 40, height: 40)
                            .background(Color.red.opacity(0.12))
                            .clipShape(Circle())
                    }
                    .accessibilityIdentifier("recipe-editor-cancel")
                    .accessibilityLabel("Discard changes")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        save()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.blue)
                            .clipShape(Circle())
                    }
                    .disabled(!canSave)
                    .accessibilityIdentifier("recipe-editor-save")
                    .accessibilityLabel("Save changes")
                }
            }
        }
        .accessibilityIdentifier("recipe-editor")
    }

    // MARK: - Section scaffolding (dark card style)

    private func section<Content: View>(
        icon: String?, title: String, isExpanded: Binding<Bool>, id: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(isExpanded: isExpanded) {
                content()
            } label: {
                sectionLabel(icon: icon, title: title)
                    .accessibilityIdentifier("recipe-editor-section-\(id)")
            }
            .tint(.secondary)
        }
        .padding(.horizontal)
    }

    private func sectionLabel(icon: String?, title: String) -> some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
            }
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minHeight: 44, alignment: .leading)
        }
    }

    private var cardStyle: some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(Color(.secondarySystemBackground))
    }

    private func textCard(text: Binding<String>, id: String, minHeight: CGFloat, font: Font = .body) -> some View {
        TextEditor(text: text)
            .font(font)
            .scrollContentBackground(.hidden)
            .frame(minHeight: minHeight)
            .padding(12)
            .background(cardStyle)
            .accessibilityIdentifier(id)
    }

    // MARK: - Info card

    private var infoCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextField("Recipe title", text: $title)
                .font(.title3.weight(.semibold))
                .padding(.vertical, 14)
                .accessibilityIdentifier("recipe-editor-title")
            Divider()
            photosRow
            Divider()
            ratingRow
            Divider()
            servingsRow
            Divider()
            sourceRow
            Divider()
            difficultyRow
            Divider()
            categoriesRow
            Divider()
            cookbookRow
        }
        .padding(.horizontal, 16)
        .background(cardStyle)
    }

    private var photosRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Photos")
                        .font(.body)
                    Text(photoCount == 1 ? "1 photo" : "\(photoCount) photos")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("recipe-editor-photo-count")
                }
                Spacer()
                photoThumb
            }
            .padding(.vertical, 12)
            TextField("Photo URL (optional)", text: $photoUrlText)
                .font(.caption)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
#if os(iOS)
                .keyboardType(.URL)
#endif
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("recipe-editor-photo-url")
        }
    }

    @ViewBuilder
    private var photoThumb: some View {
        let keys: [String] = [photoUrlText, recipe.photoThumb ?? "", recipe.photoOriginal ?? ""]
        let url = keys.lazy.compactMap { key -> URL? in
            let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty, let u = URL(string: k),
                  let s = u.scheme?.lowercased(), s == "http" || s == "https"
            else { return nil }
            return u
        }.first
        if let url {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                default:
                    Image(systemName: "photo")
                        .resizable().scaledToFit().padding(20)
                        .foregroundStyle(.secondary)
                        .background(Color(.tertiarySystemFill))
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        } else {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.tertiarySystemFill))
                .frame(width: 96, height: 96)
                .overlay {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
        }
    }

    private var ratingRow: some View {
        HStack {
            Text("Rating")
                .font(.body)
            Spacer()
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { star in
                    let filled = Double(star) <= (rating ?? 0)
                    Button {
                        if rating == Double(star) { rating = nil }
                        else { rating = Double(star) }
                    } label: {
                        Image(systemName: filled ? "star.fill" : "star")
                            .font(.title3)
                            .foregroundStyle(filled ? .yellow : Color(.tertiaryLabel))
                            .frame(width: 40, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Rate \(star) star\(star == 1 ? "" : "s")")
                }
            }
            .accessibilityIdentifier("recipe-editor-rating")
        }
        .padding(.vertical, 6)
    }

    private var servingsRow: some View {
        HStack {
            Text("Servings")
                .font(.body)
            Spacer()
            TextField("4", text: $servingsText)
                .multilineTextAlignment(.trailing)
                .font(.body)
#if os(iOS)
                .keyboardType(.decimalPad)
#endif
                .frame(width: 64)
                .accessibilityIdentifier("recipe-editor-servings-field")
                .onChange(of: servingsText) {
                    let cleaned = servingsText.trimmingCharacters(in: .whitespaces)
                    // Shared editor range 0.25–100: never alter other values.
                    if let v = Double(cleaned), v >= 0.25, v <= 100 {
                        servingsValue = v
                    }
                }
            Stepper("", value: $servingsValue, in: 0.25...100, step: 1)
                .labelsHidden()
                .accessibilityLabel("Servings")
                .accessibilityIdentifier("recipe-editor-servings-stepper")
                .onChange(of: servingsValue) {
                    servingsText = Self.servingsString(servingsValue)
                }
        }
        .padding(.vertical, 10)
    }

    private var sourceRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(sourceDomain)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let url = URL(string: sourceUrl), url.scheme != nil {
                    Link(destination: url) {
                        Image(systemName: "link")
                            .font(.body)
                            .foregroundStyle(.blue)
                            .frame(width: 40, height: 44)
                    }
                } else {
                    Image(systemName: "link")
                        .font(.body)
                        .foregroundStyle(.secondary.opacity(0.5))
                        .frame(width: 40, height: 44)
                }
            }
            TextField("https://example.com/recipe", text: $sourceUrl)
                .font(.caption)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
#if os(iOS)
                .keyboardType(.URL)
#endif
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("recipe-editor-source-url")
        }
        .padding(.vertical, 10)
    }

    private var difficultyRow: some View {
        HStack {
            Text("Difficulty")
                .font(.body)
            Spacer()
            Picker("Difficulty", selection: $difficulty) {
                ForEach(RecipeDifficulty.allCases, id: \.self) { d in
                    Text(d.rawValue).tag(d)
                }
            }
            .pickerStyle(.menu)
            .tint(.blue)
            .accessibilityIdentifier("recipe-editor-difficulty")
        }
        .padding(.vertical, 10)
    }

    private var categoriesRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "list.bullet.circle")
                .foregroundStyle(.red)
                .font(.body)
            Text("Categories")
                .font(.body)
            Spacer()
            TextField("Uncategorized", text: $categoriesText)
                .multilineTextAlignment(.trailing)
                .font(.body)
                .foregroundStyle(categoriesText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .secondary : .primary)
                .accessibilityIdentifier("recipe-editor-categories")
        }
        .padding(.vertical, 14)
    }

    /// Display-only: no cookbook field exists on the model, so this row
    /// surfaces the containing cookbook's name (or the placeholder).
    private var cookbookRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "book")
                .foregroundStyle(.red)
                .font(.body)
            Text("Cookbook")
                .font(.body)
            Spacer()
            Text(cookbookName)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 14)
        .accessibilityIdentifier("recipe-editor-cookbook")
        .accessibilityLabel("Cookbook: \(cookbookName)")
    }

    // MARK: - Times card

    private var timesCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            timeRow(
                icon: "fork.knife", title: "Prep Time",
                text: $prepText, id: "recipe-editor-prep-time"
            )
            Divider()
            timeRow(
                icon: "flame", title: "Cook Time",
                text: $cookText, id: "recipe-editor-cook-time"
            )
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.red)
                    .font(.body)
                Text("Total Time")
                    .font(.body)
                Spacer()
                Text(Self.formatMinutes(shownTotalMinutes))
                    .font(.body)
                Image(systemName: "clock")
                    .font(.body)
                    .foregroundStyle(.blue)
                    .frame(width: 40, height: 44)
            }
            .padding(.vertical, 10)
            .accessibilityIdentifier("recipe-editor-total-time")
            .accessibilityLabel("Total time: \(Self.formatMinutes(shownTotalMinutes).isEmpty ? "not set" : Self.formatMinutes(shownTotalMinutes))")
        }
        .padding(.horizontal, 16)
        .background(cardStyle)
    }

    private func timeRow(icon: String, title: String, text: Binding<String>, id: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.red)
                .font(.body)
            Text(title)
                .font(.body)
            Spacer()
            TextField("", text: text, prompt: Text("").foregroundStyle(.secondary))
                .multilineTextAlignment(.trailing)
                .font(.body)
#if os(iOS)
                .keyboardType(.numberPad)
#endif
                .frame(width: 80)
                .accessibilityIdentifier("\(id)-field")
            Text("min")
                .font(.body)
                .foregroundStyle(.secondary)
            Image(systemName: "clock")
                .font(.body)
                .foregroundStyle(.blue)
                .frame(width: 40, height: 44)
        }
        .padding(.vertical, 10)
        .accessibilityIdentifier(id)
    }

    // MARK: - Nutrition card

    private var nutritionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Nutrition view", selection: $nutritionShowsTable) {
                Text("Text").tag(false)
                Text("Table").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("recipe-editor-nutrition-mode")
            if nutritionShowsTable {
                nutritionTable
            } else {
                TextEditor(text: $nutritionText)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 120)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(.tertiarySystemFill)))
                    .accessibilityIdentifier("recipe-editor-nutrition-text")
                Button("Extract to Table") {
                    nutritionShowsTable = true
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("recipe-editor-nutrition-extract")
            }
        }
        .padding(16)
        .background(cardStyle)
    }

    /// Placeholder structured view parsed from the text (source of truth
    /// stays the text, which round-trips verbatim via UserDefaults).
    private var nutritionTable: some View {
        let rows = Self.nutritionRows(from: nutritionText)
        return VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                Text("No structured nutrition yet — add lines like \"Calories 250\" in Text view, then extract here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                    .accessibilityIdentifier("recipe-editor-nutrition-table-empty")
            } else {
                ForEach(rows.indices, id: \.self) { i in
                    HStack {
                        Text(rows[i].label)
                            .font(.body)
                        Spacer()
                        Text(rows[i].value)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                    if i < rows.count - 1 { Divider() }
                }
            }
            Text("Table is a preview — the text is the source of truth.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
        .accessibilityIdentifier("recipe-editor-nutrition-table")
    }

    static func nutritionRows(from text: String) -> [(label: String, value: String)] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { line in
                if let colon = line.firstIndex(of: ":") {
                    let label = line[..<colon].trimmingCharacters(in: .whitespaces)
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    return (label.isEmpty ? line : label, value)
                }
                // Trailing-token split: "Calories 250" → ("Calories", "250").
                let parts = line.split(separator: " ")
                if parts.count >= 2 {
                    return (parts.dropLast().joined(separator: " "), String(parts.last!))
                }
                return (line, "")
            }
    }

    // MARK: - Save (same store/sync path as detail)

    /// Blank-line split for directions: each blank-line-separated paragraph
    /// is one step (internal single newlines preserved), so untouched text
    /// round-trips exactly.
    static func splitDirections(_ text: String) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        // Split on blank lines (whitespace-only lines count as blank).
        let lines = normalized.components(separatedBy: "\n")
        var chunks: [[String]] = [[]]
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                chunks.append([])
            } else {
                chunks[chunks.count - 1].append(line)
            }
        }
        return chunks.map { $0.joined(separator: "\n") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recipe.title = trimmed
        recipe.rating = rating
        // Shared editor range 0.25–100: only clamp values outside it so
        // valid foreign servings (e.g. 0.5, 120→clamped) survive untouched.
        let servings = Double(servingsText.trimmingCharacters(in: .whitespaces)) ?? servingsValue
        recipe.servings = min(max(servings, 0.25), 100)
        let urlRaw = sourceUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        recipe.sourceUrl = urlRaw
        if !urlRaw.isEmpty {
            // Derive the display name from the new URL …
            if let url = URL(string: urlRaw), let host = url.host, !host.isEmpty {
                recipe.source = host
            } else if let url = URL(string: "https://\(urlRaw)"), let host = url.host {
                recipe.source = host
            } else {
                recipe.source = urlRaw
            }
            // … but a blank URL preserves the existing source name: the
            // editor offers no source-name control, so clearing the field
            // must not erase it.
        }
        let cats = categoriesText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        recipe.categories = cats
        // Clearing the photo URL removes the thumbnail (nil, not ignored).
        let photoRaw = photoUrlText.trimmingCharacters(in: .whitespacesAndNewlines)
        recipe.photoThumb = photoRaw.isEmpty ? nil : photoRaw
        // Editor metadata lives on the synced model (envelope keys), so it
        // survives cross-device sync. Verbatim text (even "") is stored so a
        // deliberate clear propagates; nil means never set.
        recipe.difficulty = (difficulty == .unspecified) ? nil : difficulty.rawValue
        recipe.notes = notesText
        recipe.nutritionText = nutritionText

        // Times map straight onto the model. A stored foreign total is kept
        // until prep/cook are edited, then recomputed from the new values.
        recipe.prepMinutes = prepMinutes
        recipe.cookMinutes = cookMinutes
        if timesEdited {
            recipe.totalMinutes = derivedTotalMinutes
        }

        // Description maps straight onto the model.
        recipe.recipeDescription = descriptionText

        // Ingredients: exact-text matches reuse their model objects (zero
        // loss, incl. group headers). Remaining edited lines pair in order
        // with remaining originals — preserving id — and are re-parsed for
        // structured quantity/unit so rows keep scaling after an edit.
        // Truly new lines become fresh rows; removed originals are deleted.
        let newIngLines = ingredientsText.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let existingIngs = recipe.ingredients.sorted { $0.position < $1.position }
        var unmatched: [String: [Ingredient]] = [:]
        for (line, ing) in zip(originalIngredientLines, existingIngs) {
            unmatched[line, default: []].append(ing)
        }
        let consumedIDs = NSMutableSet()
        var orderedIngs: [Ingredient?] = Array(repeating: nil, count: newIngLines.count)
        for (i, line) in newIngLines.enumerated() {
            if var queue = unmatched[line], !queue.isEmpty {
                let ing = queue.removeFirst()
                unmatched[line] = queue
                consumedIDs.add(ing.id)
                orderedIngs[i] = ing
            }
        }
        let leftoverIngs = existingIngs.filter { !consumedIDs.contains($0.id) }
        var li = 0
        for (i, line) in newIngLines.enumerated() where orderedIngs[i] == nil {
            if li < leftoverIngs.count {
                let ing = leftoverIngs[li]
                li += 1
                let parsed = IngredientParser.parse(line)
                ing.name = parsed.name
                ing.quantity = parsed.quantity
                ing.unit = parsed.unit
                ing.display = line
                ing.updatedAt = Date()
                orderedIngs[i] = ing
            } else {
                let parsed = IngredientParser.parse(line)
                let ing = Ingredient(recipeId: recipe.id, name: parsed.name,
                    quantity: parsed.quantity, unit: parsed.unit, display: line,
                    position: 0, updatedAt: Date(), deviceId: recipe.deviceId)
                ing.recipe = recipe
                context.insert(ing)
                orderedIngs[i] = ing
            }
        }
        for ing in leftoverIngs.dropFirst(li) { context.delete(ing) }
        for (i, ing) in orderedIngs.enumerated() { ing?.position = i }

        // Directions: same two-pass strategy. Positional pairing preserves
        // each step's id AND timers when its text is edited; untouched steps
        // reuse their objects verbatim.
        let newStepTexts = Self.splitDirections(directionsText)
        let existingSteps = recipe.steps.sorted { $0.position < $1.position }
        var unmatchedSteps: [String: [Step]] = [:]
        for (text, step) in zip(originalStepTexts, existingSteps) {
            unmatchedSteps[text, default: []].append(step)
        }
        let consumedStepIDs = NSMutableSet()
        var orderedSteps: [Step?] = Array(repeating: nil, count: newStepTexts.count)
        for (i, text) in newStepTexts.enumerated() {
            if var queue = unmatchedSteps[text], !queue.isEmpty {
                let step = queue.removeFirst()
                unmatchedSteps[text] = queue
                consumedStepIDs.add(step.id)
                orderedSteps[i] = step
            }
        }
        let leftoverSteps = existingSteps.filter { !consumedStepIDs.contains($0.id) }
        var si = 0
        for (i, text) in newStepTexts.enumerated() where orderedSteps[i] == nil {
            if si < leftoverSteps.count {
                let step = leftoverSteps[si]
                si += 1
                step.text = text
                step.updatedAt = Date()
                orderedSteps[i] = step
            } else {
                let step = Step(recipeId: recipe.id, position: 0, text: text,
                    updatedAt: Date(), deviceId: recipe.deviceId)
                step.recipe = recipe
                context.insert(step)
                orderedSteps[i] = step
            }
        }
        for step in leftoverSteps.dropFirst(si) { context.delete(step) }
        for (i, step) in orderedSteps.enumerated() { step?.position = i }

        // Last-write-wins sync: bump updatedAt so this edit beats remotes.
        recipe.updatedAt = Date()
        try? context.save()
        dismiss()
    }
}
