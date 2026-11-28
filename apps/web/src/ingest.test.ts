import { describe, expect, it } from 'vitest';
import {
  firstNonEmptyLine,
  parsePastedText,
  previewToRecipeInput,
  recipeToPreviewFields,
} from './ingest';

describe('firstNonEmptyLine', () => {
  it('returns the first non-empty line', () => {
    expect(firstNonEmptyLine('\n  \nPancakes\n2 eggs')).toBe('Pancakes');
  });
  it('returns empty for blank text', () => {
    expect(firstNonEmptyLine('  \n ')).toBe('');
  });
});

describe('parsePastedText', () => {
  it('uses the first line as the title hint', () => {
    const r = parsePastedText('Pancakes\n2 eggs\nMix and cook');
    expect(r.title).toBe('Pancakes');
    expect(r.servings).toBe(4);
    expect(r.ingredients?.map((i) => i.display ?? i.name)).toEqual(['2 eggs']);
    expect(r.steps?.map((s) => s.text)).toEqual(['Mix and cook']);
    expect(r.description).toBe('Pancakes\n2 eggs\nMix and cook');
  });
  it('splits quantity-led lines into ingredients like the server caption fallback', () => {
    const r = parsePastedText('Pancakes\n2 cups flour\n1/2 tsp salt\nMix and cook');
    expect(r.ingredients?.map((i) => i.display ?? i.name)).toEqual([
      '2 cups flour',
      '1/2 tsp salt',
    ]);
    expect(r.ingredients?.[0]).toMatchObject({ quantity: 2, unit: 'cups' });
    expect(r.ingredients?.[1]?.quantity).toBeCloseTo(0.5);
    expect(r.steps?.map((s) => s.text)).toEqual(['Mix and cook']);
  });
  it('tags the offline draft with source clip', () => {
    expect(parsePastedText('Soup\n2 cups water\nBoil').source).toBe('clip');
  });
  it('caps description and step text to the recipe limits', () => {
    const long = 'x'.repeat(9000);
    const r = parsePastedText(`Title\n${long}`);
    expect((r.description ?? '').length).toBeLessThanOrEqual(8000);
    for (const s of r.steps ?? []) expect(s.text.length).toBeLessThanOrEqual(8000);
    // Single-line overflow still truncates rather than dropping.
    const single = parsePastedText(long);
    expect((single.description ?? '').length).toBeLessThanOrEqual(8000);
  });
  it('falls back to a draft title for blank text', () => {
    const r = parsePastedText('   ');
    expect(r.title).toBe('Pasted draft');
    expect(r.steps).toEqual([]);
  });
  it('keeps the Link-tab offline draft shape (plus source clip)', () => {
    const r = parsePastedText('Soup\nBoil water');
    expect(Object.keys(r).sort()).toEqual(
      ['description', 'ingredients', 'servings', 'source', 'steps', 'title'].sort(),
    );
  });
  it('carries sourceUrl through when given', () => {
    const r = parsePastedText('Soup\nBoil', { sourceUrl: 'https://x.example' });
    expect(r.sourceUrl).toBe('https://x.example');
  });
});

describe('preview round-trip', () => {
  it('flattens and rebuilds title/ingredients/steps while preserving base metadata', () => {
    const base = {
      title: 'Omelet',
      description: 'orig',
      servings: 2,
      source: 'grandma',
      sourceUrl: 'https://example.com/omelet',
      categories: ['breakfast'],
      ingredients: [{ name: '2 eggs', display: '2 eggs', position: 0 }],
      steps: [{ text: 'Beat eggs', position: 0 }],
    };
    const fields = recipeToPreviewFields(base);
    expect(fields).toEqual({
      title: 'Omelet',
      ingredientsText: '2 eggs',
      stepsText: 'Beat eggs',
    });
    const rebuilt = previewToRecipeInput(
      {
        title: ` ${fields.title} `,
        ingredientsText: `${fields.ingredientsText}\n`,
        stepsText: `${fields.stepsText}\nServe`,
      },
      base,
      { description: 'orig' },
    );
    expect(rebuilt.title).toBe('Omelet');
    expect(rebuilt.ingredients?.map((i) => i.name)).toEqual(['2 eggs']);
    expect(rebuilt.steps?.map((s) => s.text)).toEqual(['Beat eggs', 'Serve']);
    expect(rebuilt.description).toBe('orig');
    expect(rebuilt.servings).toBe(2);
    expect(rebuilt.source).toBe('grandma');
    expect(rebuilt.sourceUrl).toBe('https://example.com/omelet');
    expect(rebuilt.categories).toEqual(['breakfast']);
  });
});
