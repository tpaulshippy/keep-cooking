# Lighthouse report — marketing site (issue #29)

Date: 2026-11-27. Target: `sites/marketing/dist/` served locally
(`python3 -m http.server`), audited with Lighthouse + Playwright Chromium.

## Scores (all ≥ 90 ✅)

| Profile  | Performance | Accessibility | Best practices | SEO |
|----------|-------------|---------------|----------------|-----|
| Desktop  | 100         | 100           | 100            | 100 |
| Mobile   | 100         | 100           | 100            | 100 |

## Fix during validation

First run: desktop a11y 95 / mobile a11y 96 — `color-contrast` failure on
the `.eyebrow` kicker (`#c96f2e` on `#faf7ef`, 3.38:1). Fixed by darkening
the eyebrow to `#8f4d15` (≈6:1). Re-ran both profiles → 100s.

## Spot-checks

- Desktop (1440×900) + mobile (390×844) screenshots rendered correctly —
  hero, proof band, tour grid (3→1 col), FAQ `<details>`, footer.
- Keyboard: first Tab lands on the “Skip to content” link; visible
  `:focus-visible` outline; mobile nav toggles `aria-expanded`.
- Copy verified against `README.md`: no invented features/pricing
  (only factual Paprika 4 Premium $14.99/yr comparison from README),
  free/MIT positioning matches, GitHub + `/app` links present, store
  links clearly marked placeholders.

## Reproduce

```sh
npm run build --prefix sites/marketing
cd sites/marketing/dist && python3 -m http.server 8471
npx lighthouse http://localhost:8471/ --preset=desktop \
  --chrome-flags="--headless --no-sandbox"
```
