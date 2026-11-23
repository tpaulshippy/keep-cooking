# Export — Notes

`RecipeExporter.swift` (Foundation-only) mirrors Lane 1 `api/src/export.ts`
so on-device exports are byte-comparable with `GET /export/{id}.(json|md|html)`:
Markdown line style, `PT<n>M` durations, JSON-LD `Recipe` block with inline
`<style>` and no external resources.

`ExportView.swift` (`RecipeExportView`): picker + format + preview + ShareLink
temp-file export. Works offline; the share row only appears when a file was
actually written.

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
