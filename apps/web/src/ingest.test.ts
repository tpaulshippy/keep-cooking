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
    expect(r.ingredients).toEqual([]);
    expect(r.steps?.map((s) => s.text)).toEqual(['2 eggs', 'Mix and cook']);
    expect(r.description).toBe('Pancakes\n2 eggs\nMix and cook');
  });
  it('falls back to a draft title for blank text', () => {
    const r = parsePastedText('   ');
    expect(r.title).toBe('Pasted draft');
    expect(r.steps).toEqual([]);
  });
  it('keeps the Link-tab offline draft shape', () => {
    const r = parsePastedText('Soup\nBoil water');
    expect(Object.keys(r).sort()).toEqual(
      ['description', 'ingredients', 'servings', 'steps', 'title'].sort(),
    );
  });
  it('carries sourceUrl through when given', () => {
    const r = parsePastedText('Soup\nBoil', { sourceUrl: 'https://x.example' });
    expect(r.sourceUrl).toBe('https://x.example');
  });
});

describe('preview round-trip', () => {
  it('flattens and rebuilds title/ingredients/steps', () => {
    const fields = recipeToPreviewFields({
      title: 'Omelet',
      servings: 4,
      ingredients: [{ name: '2 eggs', display: '2 eggs', position: 0 }],
      steps: [{ text: 'Beat eggs', position: 0 }],
    });
    expect(fields).toEqual({
      title: 'Omelet',
      ingredientsText: '2 eggs',
      stepsText: 'Beat eggs',
    });
    const rebuilt = previewToRecipeInput(
      { title: ' Omelet ', ingredientsText: '2 eggs\n', stepsText: 'Beat eggs\nServe' },
      { description: 'orig' },
    );
    expect(rebuilt.title).toBe('Omelet');
    expect(rebuilt.ingredients?.map((i) => i.name)).toEqual(['2 eggs']);
    expect(rebuilt.steps?.map((s) => s.text)).toEqual(['Beat eggs', 'Serve']);
    expect(rebuilt.description).toBe('orig');
  });
});
