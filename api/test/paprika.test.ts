import { describe, it, expect } from 'vitest';
import {
  parsePaprikaJson,
  parsePaprikaYaml,
  parsePaprikaHtml,
  parseServings,
  parseMinutes,
  unpackPaprikaBytes,
  exportPaprika,
  exportYaml,
  gzipBytes,
  zipStore,
} from '../src/paprika';
import { makeApp, req } from './helpers';

const SAMPLE = {
  uid: 'C918EB00-71BE-4AEE-A215-96373518F7A5',
  name: 'Antipasto',
  ingredients: '1/2 limoen\n2 cups flour\nsalt to taste',
  directions: '1. Grill voorverwarmen.\n2. Brood serveren.',
  servings: '4-6 servings',
  rating: 0,
  difficulty: null,
  notes: 'Oma’s recept',
  created: '2012-09-29 18:06:46',
  image_url: null,
  cook_time: '10 min',
  prep_time: '1 hr 15 min',
  source: 'Allerhande 1998',
  source_url: null,
  photo: null,
  photo_data: null,
  categories: ['Voorgerecht'],
  nutritional_info: '145 kcal',
};

describe('paprika json mapping', () => {
  it('maps name/ingredients/directions/servings/times/categories', () => {
    const p = parsePaprikaJson(SAMPLE);
    expect(p.uid).toBe(SAMPLE.uid);
    expect(p.input.title).toBe('Antipasto');
    expect(p.input.ingredients).toHaveLength(3);
    // Best-effort qty/unit, display always lossless.
    expect(p.input.ingredients[0]).toMatchObject({ quantity: 0.5, display: '1/2 limoen' });
    expect(p.input.ingredients[1]).toMatchObject({ quantity: 2, unit: 'cups', name: 'flour', display: '2 cups flour' });
    expect(p.input.ingredients[2]).toMatchObject({ quantity: null, display: 'salt to taste' });
    // Numbering stripped.
    expect(p.input.steps.map((s: { text: string }) => s.text)).toEqual(['Grill voorverwarmen.', 'Brood serveren.']);
    expect(p.input.servings).toBe(4);
    expect(p.input.prepMinutes).toBe(75);
    expect(p.input.cookMinutes).toBe(10);
    expect(p.input.categories).toEqual(['Voorgerecht']);
    // rating 0 = unrated -> null.
    expect(p.input.rating).toBeNull();
    // notes folded into description; difficulty/nutrition in warnings.
    expect(p.input.description).toContain('Oma’s recept');
    expect(p.warnings.join('\n')).toMatch(/difficulty|nutritional_info/);
    expect(p.warnings.join('\n')).not.toMatch(/difficulty "null"|nutritional_info ""/);
  });

  it('splits directions on blank lines', () => {
    const p = parsePaprikaJson({ name: 'X', directions: 'Do this.\n\nDo that.\n\nDo more.' });
    expect(p.input.steps.map((s: { text: string }) => s.text)).toEqual(['Do this.', 'Do that.', 'Do more.']);
  });

  it('synthesizes ${UID}.jpg when photo_data lacks a filename', () => {
    const tiny = btoa('fakejpegdata');
    const p = parsePaprikaJson({ name: 'P', uid: 'ABC-123', photo_data: tiny });
    expect(p.photoFilename).toBe('ABC-123.jpg');
    expect(p.warnings.join('\n')).toMatch(/synthesized "ABC-123.jpg"/);
  });

  it('rejects invalid photo_data with a warning', () => {
    const p = parsePaprikaJson({ name: 'P', photo_data: '!!!not-base64!!!' });
    expect(p.photoFilename).toBeUndefined();
    expect(p.warnings.join('\n')).toMatch(/not valid base64/);
  });
});

describe('servings / times edge cases', () => {
  it.each([
    ['4', 4],
    ['4-6 servings', 4],
    ['1 pie', 1],
    ['1/2', 0.5],
    ['2 1/2 dozen', 2.5],
    ['½', 0.5],
    ['Makes 24 cookies', 24],
  ])('servings "%s" -> %s', (raw, expected) => {
    expect(parseServings(raw).servings).toBeCloseTo(expected);
  });

  it('defaults servings to 4 with a warning when no number', () => {
    const r = parseServings('a few');
    expect(r.servings).toBe(4);
    expect(r.note).toMatch(/no leading number/);
  });

  it.each([
    ['10 min', 10],
    ['1 hr 15 min', 75],
    ['2 hours', 120],
    ['1:30', 90],
    ['90', 90],
  ])('time "%s" -> %s min', (raw, expected) => {
    expect(parseMinutes(raw).minutes).toBe(expected);
  });

  it('leaves unparseable times empty with a warning', () => {
    const r = parseMinutes('until golden');
    expect(r.minutes).toBeNull();
    expect(r.note).toMatch(/unparseable/);
  });
});

describe('paprikarecipes containers', () => {
  it('unzips a ZIP with a plain-JSON (non-gzipped) member', async () => {
    const zip = zipStore([{ name: 'r.paprikarecipe', data: new TextEncoder().encode(JSON.stringify(SAMPLE)) }]);
    const files = await unpackPaprikaBytes(zip);
    expect(files).toHaveLength(1);
    expect(JSON.parse(files[0]!.jsonText).name).toBe('Antipasto');
  });

  it('unzips a ZIP with a gzipped member', async () => {
    const gz = await gzipBytes(new TextEncoder().encode(JSON.stringify(SAMPLE)));
    const zip = zipStore([{ name: 'r.paprikarecipe', data: gz }]);
    const files = await unpackPaprikaBytes(zip);
    expect(files).toHaveLength(1);
    const p = parsePaprikaJson(JSON.parse(files[0]!.jsonText));
    expect(p.input.title).toBe('Antipasto');
  });

  it('handles a bare-gzip single recipe', async () => {
    const gz = await gzipBytes(new TextEncoder().encode(JSON.stringify(SAMPLE)));
    const files = await unpackPaprikaBytes(gz, 'single.paprikarecipe');
    expect(files).toHaveLength(1);
    expect(JSON.parse(files[0]!.jsonText).uid).toBe(SAMPLE.uid);
  });

  it('handles a concatenated gzip stream of two members', async () => {
    const a = await gzipBytes(new TextEncoder().encode(JSON.stringify({ ...SAMPLE, name: 'One' })));
    const b = await gzipBytes(new TextEncoder().encode(JSON.stringify({ ...SAMPLE, name: 'Two', uid: 'UID-2' })));
    const joined = new Uint8Array(a.length + b.length);
    joined.set(a, 0);
    joined.set(b, a.length);
    // Single-member gunzip would only yield the first; the splitter must
    // decode each member separately.
    const files = await unpackPaprikaBytes(joined, 'multi');
    expect(files).toHaveLength(2);
    const names = files.map((f) => (JSON.parse(f.jsonText) as { name: string }).name);
    expect(names).toEqual(['One', 'Two']);
  });

  it('handles bare JSON defensively', async () => {
    const files = await unpackPaprikaBytes(new TextEncoder().encode(JSON.stringify(SAMPLE)));
    expect(JSON.parse(files[0]!.jsonText).name).toBe('Antipasto');
  });
});

describe('yaml import', () => {
  it('parses single recipe with | blocks', () => {
    const yml = `name: My Tasty Recipe
servings: 4-6 servings
source: Food Network
prep_time: 10 min
cook_time: 30 min
categories: [Dinner, Holiday]
difficulty: Easy
rating: 5
notes: |
  This is delicious!!!
ingredients: |
  1/2 lb meat
  salt
directions: |
  Mix things together.
  Eat.
`;
    const out = parsePaprikaYaml(yml);
    expect(out).toHaveLength(1);
    expect(out[0]!.input.title).toBe('My Tasty Recipe');
    expect(out[0]!.input.servings).toBe(4);
    expect(out[0]!.input.ingredients).toHaveLength(2);
    expect(out[0]!.input.steps).toHaveLength(2);
    expect(out[0]!.input.rating).toBe(5);
    expect(out[0]!.input.categories).toEqual(['Dinner', 'Holiday']);
  });

  it('parses a multi-recipe YAML list', () => {
    const yml = `- name: One
  servings: 2
- name: Two
  servings: 4
`;
    const out = parsePaprikaYaml(yml);
    expect(out).toHaveLength(2);
    expect(out.map((p) => p.input.title)).toEqual(['One', 'Two']);
  });

  it('accepts JSON-as-YAML', () => {
    const out = parsePaprikaYaml(JSON.stringify({ ...SAMPLE }));
    expect(out).toHaveLength(1);
    expect(out[0]!.input.title).toBe('Antipasto');
  });
});

describe('html import', () => {
  it('prefers JSON-LD Recipe blocks', () => {
    const html = `<!doctype html><html><head><script type="application/ld+json">${JSON.stringify({
      '@context': 'https://schema.org',
      '@type': 'Recipe',
      name: 'LD Soup',
      recipeIngredient: ['1 onion', '2 cups broth'],
      recipeInstructions: [{ '@type': 'HowToStep', text: 'Simmer.' }],
      recipeYield: '4 servings',
      prepTime: 'PT15M',
      cookTime: 'PT30M',
    })}</script></head><body><h1>Wrong Title</h1></body></html>`;
    const out = parsePaprikaHtml(html);
    expect(out).toHaveLength(1);
    expect(out[0]!.input.title).toBe('LD Soup');
    expect(out[0]!.input.ingredients).toHaveLength(2);
    expect(out[0]!.input.prepMinutes).toBe(15);
    expect(out[0]!.input.cookMinutes).toBe(30);
    expect(out[0]!.warnings.join('\n')).toMatch(/JSON-LD/);
  });

  it('falls back to headings', () => {
    const html = '<html><body><h1>Plain Stew</h1><h2>Ingredients</h2><ul><li>beef</li><li>water</li></ul><h2>Directions</h2><ol><li>Boil.</li></ol></body></html>';
    const out = parsePaprikaHtml(html);
    expect(out[0]!.input.title).toBe('Plain Stew');
    expect(out[0]!.input.ingredients).toHaveLength(2);
    expect(out[0]!.input.steps).toHaveLength(1);
  });
});

describe('POST /api/import + GET /export round-trip', () => {
  it('imports paprika-json, upserts on uid re-import, and exports .paprikarecipes/.yaml', async () => {
    const { app } = await makeApp({ seed: false });
    const payload = JSON.stringify(SAMPLE);
    const first = await req(app, 'POST', '/api/import', {
      body: { format: 'paprika-json', text: payload, householdId: 'hh-demo' },
    });
    expect(first.status).toBe(200);
    const f1 = (await first.json()) as { imported: number; ids: string[]; warnings: string[] };
    expect(f1.imported).toBe(1);
    // uid used as upsert key: stored under the Paprika uid.
    expect(f1.ids[0]).toBe(SAMPLE.uid);

    const second = await req(app, 'POST', '/api/import', {
      body: { format: 'paprika-json', text: payload, householdId: 'hh-demo' },
    });
    expect(second.status).toBe(200);
    const f2 = (await second.json()) as { imported: number; ids: string[] };
    expect(f2.imported).toBe(1);
    expect(f2.ids[0]).toBe(SAMPLE.uid);

    const list = (await (await req(app, 'GET', '/api/recipes?householdId=hh-demo')).json()) as { id: string }[];
    expect(list.filter((r) => r.id === SAMPLE.uid)).toHaveLength(1);

    // .paprikarecipes export round-trips through the unpacker.
    const zipRes = await req(app, 'GET', `/api/export/${SAMPLE.uid}.paprikarecipes`);
    expect(zipRes.status).toBe(200);
    expect(zipRes.headers.get('content-type')).toContain('application/zip');
    const zipBytes = new Uint8Array(await zipRes.arrayBuffer());
    const files = await unpackPaprikaBytes(zipBytes);
    expect(files).toHaveLength(1);
    const back = JSON.parse(files[0]!.jsonText) as Record<string, unknown>;
    expect(back['uid']).toBe(SAMPLE.uid);
    expect(back['name']).toBe('Antipasto');
    // No binary photo store in the API layer: photo_data omitted, so `photo`
    // is null (a filename without data is worse than omitting both).

    // .yaml export is JSON-as-YAML and re-imports.
    const yRes = await req(app, 'GET', `/api/export/${SAMPLE.uid}.yaml`);
    expect(yRes.status).toBe(200);
    expect(yRes.headers.get('content-type')).toContain('text/yaml');
    const re = parsePaprikaYaml(await yRes.text());
    expect(re[0]!.input.title).toBe('Antipasto');
  });

  it('bulk HTML export re-imports every recipe', async () => {
    const { app } = await makeApp({ seed: false });
    for (const title of ['Html One', 'Html Two']) {
      const c = await req(app, 'POST', '/api/recipes', {
        body: {
          title, servings: 2, householdId: 'hh-demo',
          ingredients: [{ name: 'flour' }], steps: [{ text: 'Mix.' }],
        },
      });
      expect(c.status).toBe(201);
    }
    const htmlRes = await req(app, 'GET', '/api/export?format=html&all=true');
    expect(htmlRes.status).toBe(200);
    const back = await req(app, 'POST', '/api/import', {
      body: { format: 'html', text: await htmlRes.text(), householdId: 'hh-demo' },
    });
    expect(back.status).toBe(200);
    const report = (await back.json()) as { imported: number };
    expect(report.imported).toBe(2);
  });

  it('imports a .paprikarecipes zip payload and bulk-exports all', async () => {
    const { app } = await makeApp({ seed: false });
    const gz = await gzipBytes(new TextEncoder().encode(JSON.stringify({ ...SAMPLE, uid: 'UID-ZIP-1', name: 'Zip One' })));
    const zip = zipStore([{ name: 'one.paprikarecipe', data: gz }]);
    let b64 = '';
    const CH = 0x8000;
    for (let i = 0; i < zip.length; i += CH) b64 += String.fromCharCode(...zip.subarray(i, i + CH));
    const res = await req(app, 'POST', '/api/import', {
      body: { format: 'paprika-zip', filename: 'lib.paprikarecipes', payload: btoa(b64), householdId: 'hh-demo' },
    });
    expect(res.status).toBe(200);
    expect(((await res.json()) as { imported: number }).imported).toBe(1);

    const bulk = await req(app, 'GET', '/api/export/all.paprikarecipes');
    expect(bulk.status).toBe(200);
    const files = await unpackPaprikaBytes(new Uint8Array(await bulk.arrayBuffer()));
    expect(files).toHaveLength(1);
  });

  it('returns 415 with re-export guidance for P1 formats', async () => {
    const { app } = await makeApp({ seed: false });
    for (const format of ['mx2', 'fdx', 'mmf', 'yum', 'copymethat', 'pepperplate']) {
      const res = await req(app, 'POST', '/api/import', {
        body: { format, text: 'dummy', householdId: 'hh-demo' },
      });
      expect(res.status).toBe(415);
      expect(((await res.json()) as { error: string }).error).toMatch(/not supported yet/i);
    }
  });

  it('dryRun parses and reports without persisting anything', async () => {
    const { app } = await makeApp({ seed: false });
    const payload = JSON.stringify(SAMPLE);
    const dry = await req(app, 'POST', '/api/import', {
      body: { format: 'paprika-json', text: payload, householdId: 'hh-demo', dryRun: true },
    });
    expect(dry.status).toBe(200);
    const d = (await dry.json()) as { imported: number; updated: number; ids: string[]; warnings: string[]; dryRun: boolean; cookbooksCreated: string[] };
    expect(d.imported).toBe(1);
    expect(d.updated).toBe(0);
    expect(d.dryRun).toBe(true);
    expect(d.ids).toContain(SAMPLE.uid);
    expect(d.cookbooksCreated).toEqual([]);
    // Nothing persisted.
    const list = (await (await req(app, 'GET', '/api/recipes?householdId=hh-demo')).json()) as { id: string }[];
    expect(list).toHaveLength(0);

    // The real import still lands exactly once afterwards.
    const live = await req(app, 'POST', '/api/import', {
      body: { format: 'paprika-json', text: payload, householdId: 'hh-demo' },
    });
    expect(live.status).toBe(200);
    expect(((await live.json()) as { updated: number }).updated).toBe(0);

    // A second dryRun sees the would-be update but still persists nothing new.
    const dry2 = await req(app, 'POST', '/api/import', {
      body: { format: 'paprika-json', text: payload, householdId: 'hh-demo', dryRun: true },
    });
    expect(dry2.status).toBe(200);
    const d2 = (await dry2.json()) as { imported: number; updated: number; dryRun: boolean };
    expect(d2.imported).toBe(1);
    expect(d2.updated).toBe(1);
    expect(d2.dryRun).toBe(true);
    const list2 = (await (await req(app, 'GET', '/api/recipes?householdId=hh-demo')).json()) as { id: string }[];
    expect(list2.filter((r) => r.id === SAMPLE.uid)).toHaveLength(1);
  });

  it('rejects an explicit unknown format with 400 instead of sniffing YAML', async () => {
    const { app } = await makeApp({ seed: false });
    const yml = 'name: Soup\nservings: 2\ningredients: |\n  water\ndirections: |\n  Boil.\n';
    for (const format of ['pepperplate-db', 'pepperplate_db', 'yum-xml', 'bogus-format']) {
      const res = await req(app, 'POST', '/api/import', {
        body: { format, text: yml, householdId: 'hh-demo' },
      });
      expect(res.status).toBe(400);
      expect(((await res.json()) as { error: string }).error).toMatch(/unsupported import format/);
    }
    // Nothing persisted by the rejected imports.
    const list = (await (await req(app, 'GET', '/api/recipes?householdId=hh-demo')).json()) as { id: string }[];
    expect(list).toHaveLength(0);
  });

  it('still sniffs the format when it is omitted', async () => {
    const { app } = await makeApp({ seed: false });
    // YAML default (no filename, no format).
    const yml = 'name: Sniffed Soup\nservings: 2\ningredients: |\n  water\ndirections: |\n  Boil.\n';
    const yRes = await req(app, 'POST', '/api/import', {
      body: { text: yml, householdId: 'hh-demo' },
    });
    expect(yRes.status).toBe(200);
    expect(((await yRes.json()) as { imported: number }).imported).toBe(1);
    // JSON content sniffs to paprika-json.
    const jRes = await req(app, 'POST', '/api/import', {
      body: { text: JSON.stringify({ ...SAMPLE, uid: 'UID-SNIFF-1', name: 'Sniffed Json' }), householdId: 'hh-demo' },
    });
    expect(jRes.status).toBe(200);
    expect(((await jRes.json()) as { imported: number }).imported).toBe(1);
    const list = (await (await req(app, 'GET', '/api/recipes?householdId=hh-demo')).json()) as { title: string }[];
    expect(list.map((r) => r.title).sort()).toEqual(['Sniffed Json', 'Sniffed Soup']);
  });

  it('exportPaprika emits ${UID}.jpg-safe members and exportYaml is valid YAML/JSON', async () => {
    const { app, store } = await makeApp({ seed: false });
    const r = await store.createRecipe(
      {
        title: 'Export: Cake/Bad*Name',
        description: '',
        servings: 8,
        prepMinutes: 90,
        cookMinutes: null,
        rating: 5,
        source: '',
        sourceUrl: '',
        categories: [],
        ingredients: [{ name: 'flour', quantity: 2, unit: 'cups', display: '2 cups flour', position: 0 }],
        steps: [{ position: 0, text: 'Bake.' }],
        householdId: 'hh-demo',
      },
      { deviceId: 'd' },
    );
    const zip = await exportPaprika([
      { ...r, entity: 'recipe' as const },
      { ...(await store.getRecipe(r.id))!, entity: 'recipe' as const },
    ]);
    const files = await unpackPaprikaBytes(zip);
    expect(files).toHaveLength(2);
    // Filenames sanitized (no slashes/stars).
    for (const f of files) expect(f.name).not.toMatch(/[/:*?"<>|]/);
    // Duplicate titles are deduped: member names are unique.
    expect(new Set(files.map((f) => f.name)).size).toBe(files.length);
    // Bulk YAML is a JSON array = valid YAML.
    const y = exportYaml([{ ...r, entity: 'recipe' as const }]);
    expect(JSON.parse(y).name).toBe('Export: Cake/Bad*Name');
    void app;
  });
});
