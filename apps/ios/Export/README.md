# Export — Notes

`RecipeExporter.swift` (Foundation-only) mirrors Lane 1 `api/src/export.ts`
so on-device exports are byte-comparable with `GET /export/{id}.(json|md|html)`:
Markdown line style, `PT<n>M` durations, JSON-LD `Recipe` block with inline
`<style>` and no external resources.

`ExportView.swift` (`RecipeExportView`): picker + format + preview + ShareLink
temp-file export. Works offline; the share row only appears when a file was
actually written.

## Formats (JSON/Markdown/HTML/Paprika/YAML)

`ExportFormat`: `json` (`public.json`), `md` (`net.daringfireball.markdown`),
`html` (`public.html`), `paprikarecipes` (`com.paprika.recipes`,
archive UTI conforming to `public.zip` — not the single-recipe
`com.paprika.recipe`),
`yaml` (`public.yaml`, written `.yml`).

- `exportPaprikaJSON(_:uid:servingsText:created:)` (`RecipeExporter.swift`):
  full Paprika object per spec §1.4 — `uid` (stable, uppercase, reused
  `paprikaUid` on round-trip), `\n`-joined ingredients/directions, human
  durations (`20 minutes`), categories, rating int, cookbook, `created`
  stamp. `photo`/`photo_data` are null here: `ExportableRecipe` carries no
  photo bytes, and emitting `photo_data` without a `photo` filename
  crashes Paprika mid-import — a photo-carrying pipeline must synthesize
  `${UID}.jpg` (see `ParsedRecipe.paprikaJSONObject()`).
- `exportPaprikaArchive(_:)` → real `.paprikarecipes` ZIP bytes (stored
  entries, one gzip member per recipe named
  `<sanitized title>.paprikarecipe`). Manual writer + CRC-32, no third-party
  ZIP dependency; gzip via `Compression` when available, raw-JSON member
  fallback otherwise (the parser accepts plain-JSON members per §1.1).
  `RecipeExportView` writes these bytes (not text) for the Paprika format, so
  the shared file imports into Paprika as-is.
- `exportYaml(_:)` / `exportYamlArray(_:)`: Paprika YAML §2 emitted as JSON
  (YAML is a superset of JSON — zero indentation risk), written `.yml`.

## Import (Features/Ingest/)

`PaprikaImport.swift` (Foundation-only, `swiftc`-checkable): offline parser
for `.paprikarecipes` (ZIP → gunzip-per-member, plain-JSON fallback,
trash-skip), `.paprikarecipe` (bare gzip / multi-member stream / bare JSON),
`.yml`/`.yaml` (JSON-as-YAML + minimal `key:`/`key: |` reader, single or
`- ` list), HTML export (JSON-LD `Recipe` → hRecipe → headings), plus
best-effort P1: MX2/MXP/MZ2, MealMaster text, FDX/FDXZ, Pepperplate/Copy-Me-That
ZIPs, Yum XML, My CookBook `.mcb`, Recipe Manager TXT. Its DEFLATE inflater
and ZIP reader are pure Swift (no `Compression`/ZIP dependency). P2/P3 opaque
blobs (`.ysr`/`.mgourmet`/`.dvo`/`.hcb`/`.sqlite`/`.rbox`/`.ckbk`/`.lcb`) are
rejected with a re-export guidance message, never silently dropped.
`POST /import` lives in `ImportAPIClient` (same auth as `ClipClient`); the
server owns uid upsert.

`ImportView.swift`: file picker (`fileImporter`, all import extensions) →
offline parse preview (counts + warnings, no network touched) → cookbook
picker + **Import cookbooks from file** toggle (Paprika parity) → progress +
result (`imported / updated / warnings`, server vs on-device source noted).
Flow is parse-offline-first, then `POST /import` when reachable, else
on-device SwiftData save (title-match updates — Recipe has no paprikaUid
column; Core is frozen).

### Wiring an app to receive `.paprikarecipes` taps (Files/Mail)

1. Info.plist — declare the types so the system routes the files here:

```xml
<key>UTExportedTypeDeclarations</key>
<array>
  <dict>
    <key>UTTypeIdentifier</key><string>com.paprika.recipes</string>
    <key>UTTypeConformsTo</key><array><string>public.zip</string></array>
    <key>UTTypeTagSpecification</key>
    <dict><key>public.filename-extension</key><array><string>paprikarecipes</string></array></dict>
  </dict>
  <dict>
    <key>UTTypeIdentifier</key><string>com.paprika.recipe</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string></array>
    <key>UTTypeTagSpecification</key>
    <dict><key>public.filename-extension</key><array><string>paprikarecipe</string></array></dict>
  </dict>
</array>
<key>CFBundleDocumentTypes</key>
<array>
  <dict>
    <key>CFBundleTypeName</key><string>Paprika recipes</string>
    <key>LSItemContentTypes</key>
    <array><string>com.paprika.recipes</string><string>com.paprika.recipe</string></array>
    <key>LSHandlerRank</key><string>Alternate</string>
  </dict>
</array>
```

2. App root — stage the file, then show the import UI:

```swift
@State private var showImport = false
// ...
.modifier(ImportURLHandler(onFile: { url in
    if ImportPendingStore.stage(url) { showImport = true }
}))
.sheet(isPresented: $showImport) { ImportView() }
```

`ImportView` also consumes a staged file on appear, so presenting it after
any `ImportPendingStore.stage(_:)` (share sheet, drag-and-drop) works.

## EXPORT_SAMPLES provenance

`EXPORT_SAMPLES/recipe.{json,md,html}` were generated from the **real
shipped exporter** (not hand-written):

```
swiftc -o /tmp/gen_samples apps/ios/Export/RecipeExporter.swift <main.swift>
/tmp/gen_samples   # writes the 3 files; main mirrors seed recipe-01
                   # (Weeknight Miso Salmon) with full ingredients/steps
```

Validation performed at generation time: JSON parses (`id`, 4 ingredients,
3 steps); Markdown spot-checked; HTML contains exactly one
`application/ld+json` block, `@type == Recipe`, `prepTime == PT10M`,
`cookTime == PT20M`, 4 `recipeIngredient`, 3 `HowToStep`, no `</script>`
inside the JSON-LD. Re-run the same command after any exporter change and
diff the samples — they are the regression test until an Xcode target exists.
