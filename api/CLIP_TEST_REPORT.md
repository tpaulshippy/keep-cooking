# CLIP_TEST_REPORT — 10/12 URLs auto-pass

Pipeline: **JSON-LD → reader → caption fallback**, PII-free logging
(`{strategy, host, confidence}` only). Fixtures live in
`api/test/clip.test.ts` (`CLIP_FIXTURES`, no network — stubbed fetch);
`POST /clip` with a URL hits the network in production.

| # | URL / source | Strategy | Conf. | Pass | Notes |
|---|---|---|---|---|---|
| 1 | https://example.com/miso-salmon | jsonld | 0.95 | ✅ | title/servings/ingredients/steps |
| 2 | https://www.allrecipes.com/recipe/12345/best-lasagna | jsonld | 0.95 | ✅ | `@type:["Recipe"]` array form |
| 3 | https://www.foodnetwork.com/recipes/weeknight-tacos-1 | jsonld | 0.95 | ✅ | |
| 4 | https://www.bbcgoodfood.com/recipes/chicken-curry | jsonld | 0.95 | ✅ | |
| 5 | https://example.com/no-jsonld-tomato-soup | reader | 0.60 | ✅ | h1 + `<li>` split ingredients/steps, warning-free |
| 6 | https://example.com/grandma-casserole | reader | 0.60 | ✅ | paragraphs → steps |
| 7 | tiktok caption paste | caption | 0.45 | ✅ | qty-regex → ingredients |
| 8 | instagram caption paste | caption | 0.45 | ✅ | emoji-tolerant |
| 9 | youtube description paste | caption | 0.45 | ✅ | |
| 10 | cookbook OCR paste | caption | 0.45 | ✅ | |
| 11 | https://www.tiktok.com/@chef/video/7392011111111111111 | caption (degraded) | 0.20 | ❌ | JS-rendered oEmbed wall, no markup → `warnings:["empty caption"]`; needs manual caption or rendered-fetch |
| 12 | https://www.instagram.com/p/ABC123xyz/ | caption (degraded) | 0.20 | ❌ | login wall, no markup → warnings; needs manual caption or oEmbed token |

**Result: 10/12 auto-extract pass; 2 fail gracefully** (HTTP 200 with
`strategy: "caption"`, `confidence ≤ 0.45`, non-empty `warnings` — never a
crash, never a hallucinated recipe). Production fix path for #11/#12: TikTok
oEmbed + Instagram Graph token before reader fallback (Lane 1 follow-up).
