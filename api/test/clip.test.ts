import { describe, it, expect } from 'vitest';
import { clipRecipe, parseJsonLd, parseReader, parseCaption } from '../src/clip';
import { clipRequestSchema } from '../src/zod';
import { makeApp, req } from './helpers';

// 12 representative fixtures for CLIP_TEST_REPORT.md.
// fetchStub serves the fixture HTML per URL (no network in tests).
const JSONLD = (name: string, extra = '') => `<!doctype html><html><head><title>${name}</title>
<script type="application/ld+json">{"@context":"https://schema.org","@type":"Recipe","name":"${name}","recipeYield":"4 servings","recipeIngredient":["1 lb salmon","2 tbsp miso"],"recipeInstructions":[{"@type":"HowToStep","text":"Broil 8-10 min."}]}${extra}</script>
</head><body><h1>${name}</h1></body></html>`;

const READER = (title: string) => `<!doctype html><html><head><title>${title}</title></head><body>
<h1>${title}</h1><ul><li>2 cups flour</li><li>1 tsp salt</li><li>3 eggs</li></ul>
<p>Mix everything together.</p><p>Bake at 350F for 30 minutes.</p></body></html>`;

export const CLIP_FIXTURES = [
  { url: 'https://example.com/miso-salmon', html: JSONLD('Weeknight Miso Salmon'), expect: 'jsonld', pass: true },
  { url: 'https://www.allrecipes.com/recipe/12345/best-lasagna', html: JSONLD('Best Lasagna').replace('"@type":"Recipe"', '"@type":["Recipe"]'), expect: 'jsonld', pass: true },
  { url: 'https://www.foodnetwork.com/recipes/weeknight-tacos-1', html: JSONLD('Weeknight Tacos'), expect: 'jsonld', pass: true },
  { url: 'https://www.bbcgoodfood.com/recipes/chicken-curry', html: JSONLD('Chicken Curry'), expect: 'jsonld', pass: true },
  { url: 'https://example.com/no-jsonld-tomato-soup', html: READER('No-Fuss Tomato Soup'), expect: 'reader', pass: true },
  { url: 'https://example.com/grandma-casserole', html: READER('Grandma Casserole'), expect: 'reader', pass: true },
  { url: undefined, caption: 'Gochujang Noodles\n2 packs ramen\n1 tbsp gochujang\nBoil noodles 3 min.\nToss and serve.', expect: 'caption', pass: true },
  { url: undefined, caption: '5-min Pesto Eggs 🍳\n2 eggs\n1 tbsp pesto\nFry eggs, top with pesto.', expect: 'caption', pass: true },
  { url: undefined, caption: 'Meal-prep burrito bowls (from video description)\n1 cup rice\n1 can black beans\nCook rice. Assemble bowls.', expect: 'caption', pass: true },
  { url: undefined, caption: 'OCR from cookbook photo\nCream of Mushroom\n8 oz mushrooms\n2 cups cream\nSimmer 20 minutes.', expect: 'caption', pass: true },
  // Expected failures: JS/login walls with no parseable markup and no caption.
  { url: 'https://www.tiktok.com/@chef/video/7392011111111111111', html: '<html><head></head><body><div id="app"></div></body></html>', expect: 'caption', pass: false },
  { url: 'https://www.instagram.com/p/ABC123xyz/', html: '<html><head><title>Login • Instagram</title></head><body>login wall</body></html>', expect: 'caption', pass: false },
] as const;

function stubFetch(map: Map<string, string>) {
  return async (url: string | URL | Request) => {
    const u = String(url);
    const html = map.get(u) ?? '';
    return new Response(html, { headers: { 'content-type': 'text/html' } });
  };
}

describe('clip pipeline (12 fixtures)', () => {
  const htmlMap = new Map(CLIP_FIXTURES.filter((f) => f.url && 'html' in f).map((f) => [f.url as string, (f as { html: string }).html]));
  for (const [i, f] of CLIP_FIXTURES.entries()) {
    it(`fixture ${i + 1}: ${f.url ?? 'caption-only'}`, async () => {
      const r = await clipRecipe({
        url: f.url,
        caption: 'caption' in f ? (f as { caption: string }).caption : undefined,
        fetchFn: stubFetch(htmlMap) as typeof fetch,
      });
      if (f.pass) {
        expect(r.strategy).toBe(f.expect);
        expect(r.recipe.title.length).toBeGreaterThan(0);
        if (f.expect !== 'caption' || true) {
          expect(r.recipe.ingredients.length + r.recipe.steps.length).toBeGreaterThan(0);
        }
        if (f.expect === 'jsonld') expect(r.confidence).toBeGreaterThanOrEqual(0.9);
      } else {
        // Graceful degradation: caption fallback with warnings, low confidence.
        expect(r.strategy).toBe('caption');
        expect(r.confidence).toBeLessThanOrEqual(0.45);
        expect(r.warnings.length).toBeGreaterThan(0);
      }
    });
  }

  it('unit: parseJsonLd handles @graph', () => {
    const html = `<html><head><script type="application/ld+json">{"@graph":[{"@type":"WebSite","name":"x"},{"@type":"Recipe","name":"Graph Pie","recipeIngredient":["1 crust"],"recipeInstructions":["Bake."]}]}</script></head></html>`;
    const r = parseJsonLd(html, 'https://example.com/pie');
    expect(r?.strategy).toBe('jsonld');
    expect(r?.recipe.title).toBe('Graph Pie');
  });

  it('unit: parseReader returns null without title', () => {
    expect(parseReader('<html><body>no headings</body></html>')).toBeNull();
  });

  it('unit: parseCaption empty -> warnings', () => {
    const r = parseCaption('');
    expect(r.warnings.length).toBeGreaterThan(0);
    expect(r.confidence).toBeLessThanOrEqual(0.45);
  });

  it('POST /clip with caption (no network)', async () => {
    const { app } = await makeApp();
    const res = await req(app, 'POST', '/api/clip', {
      body: { caption: 'Gochujang Noodles\n2 packs ramen\nBoil 3 min.' },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { strategy: string; recipe: { title: string } };
    expect(body.strategy).toBe('caption');
    expect(body.recipe.title).toBe('Gochujang Noodles');
  });

  it('POST /clip requires url or caption', async () => {
    const { app } = await makeApp();
    const res = await req(app, 'POST', '/api/clip', { body: {} });
    expect(res.status).toBe(400);
  });

  it('POST /clip caption-only with source:text -> 200 + strategy caption', async () => {
    const { app } = await makeApp();
    const res = await req(app, 'POST', '/api/clip', {
      body: { caption: 'Pasted Weeknight Pasta\n2 cups pasta\n1 cup sauce\nBoil pasta. Add sauce.', source: 'text' },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { strategy: string; recipe: { title: string } };
    expect(body.strategy).toBe('caption');
    expect(body.recipe.title).toBe('Pasted Weeknight Pasta');
  });

  it('POST /clip caption-only with source:photo -> 200 + strategy caption', async () => {
    const { app } = await makeApp();
    const res = await req(app, 'POST', '/api/clip', {
      body: { caption: 'Photo transcript soup\n8 oz mushrooms\n2 cups cream\nSimmer 20 minutes.', source: 'photo' },
    });
    expect(res.status).toBe(200);
    const body = (await res.json()) as { strategy: string; recipe: { title: string } };
    expect(body.strategy).toBe('caption');
    expect(body.recipe.title).toBe('Photo transcript soup');
  });

  it('clipRequestSchema accepts source text/photo, still requires url or caption', async () => {
    expect(clipRequestSchema.safeParse({ caption: 'a\nb', source: 'text' }).success).toBe(true);
    expect(clipRequestSchema.safeParse({ caption: 'a\nb', source: 'photo' }).success).toBe(true);
    expect(
      clipRequestSchema.safeParse({ url: 'https://example.com/x', caption: 'a\nb', source: 'text' }).success,
    ).toBe(true);
    expect(clipRequestSchema.safeParse({ source: 'text' }).success).toBe(false);
    expect(clipRequestSchema.safeParse({ source: 'bogus', caption: 'a' }).success).toBe(false);
  });

  it('url+caption still works (url wins via stubbed fetch)', async () => {
    const htmlMap = new Map([[CLIP_FIXTURES[0]!.url as string, JSONLD('Weeknight Miso Salmon')]]);
    const r = await clipRecipe({
      url: CLIP_FIXTURES[0]!.url as string,
      caption: 'Fallback caption\n2 eggs\nFry.',
      fetchFn: stubFetch(htmlMap) as typeof fetch,
    });
    expect(r.strategy).toBe('jsonld');
    expect(r.recipe.title).toBe('Weeknight Miso Salmon');
  });
});
