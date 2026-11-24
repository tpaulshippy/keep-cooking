# Ingest demo notes — Lane 3 Capture (working outline, not perfection)

6-input walkthrough. Each: input → expected strategy → taps → log line.

## 1. AllRecipes URL (jsonld)
- Input: `https://www.allrecipes.com/recipe/12345/best-lasagna`
- View: ClipView → paste → **Clip recipe** (tap 1) → preview (tap 2 review) → **Save** (tap 3)
- Expects: `POST /clip {url}` → `ClipReport{strategy: jsonld, confidence ≥ 0.9}`
- Log: `clip strategy=jsonld host=www.allrecipes.com confidence=0.9x`
- Save: Recipe + Ingredient(display fraction-rounded) + Step via SwiftData

## 2. NYT Cooking URL (jsonld/reader)
- Input: `https://cooking.nytimes.com/recipes/weeknight-miso-salmon`
- Same 3-tap flow. NYT usually ships JSON-LD; if paywalled markup is thin,
  server falls back to `reader` with `warnings: ["jsonld-missing"]`.
- Log: `clip strategy=jsonld|reader host=cooking.nytimes.com confidence=…`

## 3. TikTok link + caption (caption)
- Input: link `https://www.tiktok.com/@chef/video/7392011111111111111` + caption paste:
  `Gochujang Noodles / 2 packs ramen / 1 tbsp gochujang / Boil noodles 3 min. / Toss and serve.`
- View: CaptionsImportView (platform=TikTok) → **Import caption** → editable preview → **Save**
- Expects: `POST /clip {url, caption, source: tiktok}` → `strategy: caption`
- Log: `clip strategy=caption host=www.tiktok.com confidence=0.4x`
- Note: TikTok HTML alone is a JS wall (expected failure without caption) —
  caption is what makes it parse.

## 4. IG link + caption (caption)
- Input: link `https://www.instagram.com/p/ABC123xyz/` + caption:
  `5-min Pesto Eggs / 2 eggs / 1 tbsp pesto / Fry eggs, top with pesto.`
- Same CaptionsImportView flow, platform=Instagram, `source: instagram`.
- Log: `clip strategy=caption host=www.instagram.com confidence=0.4x`
- Note: IG login wall alone fails gracefully (warnings + low confidence);
  caption rescues it.

## 5. YouTube link + description (caption)
- Input: link `https://www.youtube.com/watch?v=xyz` + description paste:
  `Meal-prep burrito bowls / 1 cup rice / 1 can black beans / Cook rice. Assemble bowls.`
- Same flow, platform=YouTube, `source: youtube`.
- Fraction check: `1/2`, `½`, `2-3 cloves` all parse via IngredientParser
  (see IngredientParserTests).

## 6. Cookbook photo (ocr)
- Input: photo of "Cream of Mushroom" page (8 oz mushrooms, 2 cups cream, "Simmer 20 minutes.")
- View: OCRScanView → paste/simulate recognized text → **Parse text** →
  editable title/ingredients/steps → **Save**
- On device with Vision: `VisionOCR.recognize(data:)` → `OCRSplitter.split`
  (first line = title, quantity-led lines = ingredients, rest = steps).
- Without Vision (simulator/CI): stub returns empty + manual paste; same preview/save path.
- Log: `strategy=ocr confidence=0.70 (local heuristic)` until server ocr lands.
- `POST /clip` with `source: ocr` is supported when sending OCR text as caption.

## Clipboard + Share sheet (both feed ClipView)
- Clipboard: copy any URL → foreground app → ClipboardBanner "Clip this link?
  [Clip] [Dismiss]" → Clip prefills URL (consent-gated, dismissable).
- Share sheet: Safari/IG/TikTok → Share → Keep Cooking Share → ShareViewController writes
  URL to App Group `group.com.smidgen.share` → host drains via
  `ShareStore.drain()` on foreground into ClipView.

## Files
- Features/Ingest: ClipModels.swift, IngredientParser.swift, ClipView.swift,
  CaptionsImportView.swift, OCRScanView.swift, ClipboardBanner.swift,
  IngredientParserTests.swift
- ShareExtension: ShareStore.swift, ShareViewController.swift
- No new persistence — all saves go through Lane 2 `Recipe/Ingredient/Step`.
- No UI outside owned dirs. No changes to api/, contracts/, Core/, Sync/, App/.
