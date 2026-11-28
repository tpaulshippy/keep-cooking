import { describe, expect, it } from 'vitest';
import {
  aggregateWeekToList, guessAisle, scaleIngredientsForServings,
  collectPlanIngredients, splitLeadingQuantity, rescaleDisplay,
} from './aggregate';

describe('guessAisle', () => {
  it('classifies staples', () => {
    expect(guessAisle('Whole milk')).toBe('Dairy');
    expect(guessAisle('Chicken breast')).toBe('Meat');
    expect(guessAisle('Spaghetti')).toBe('Dry Goods');
    expect(guessAisle('Mystery powder')).toBe('Other');
  });

  it('checks Frozen before Dairy', () => {
    expect(guessAisle('ice cream')).toBe('Frozen');
  });

  it('bounds the egg token so eggplant is Produce', () => {
    expect(guessAisle('egg')).toBe('Dairy');
    expect(guessAisle('eggs')).toBe('Dairy');
    expect(guessAisle('2 large eggs')).toBe('Dairy');
    expect(guessAisle('eggplant')).toBe('Produce');
  });
});

describe('aggregateWeekToList', () => {
  it('merges same-name ingredients across recipes', () => {
    const out = aggregateWeekToList([
      { name: 'Cheddar', quantity: 1, unit: 'cups', recipeId: 'a' },
      { name: 'cheddar', quantity: 2, unit: 'cups', recipeId: 'b' },
      { name: 'Lime', quantity: 1, unit: '', recipeId: 'a' },
    ]);
    const cheddar = out.find((i) => i.name.toLowerCase() === 'cheddar');
    expect(cheddar?.quantity).toBe('3 cups');
    expect(out.length).toBe(2);
  });

  it('sorts by aisle', () => {
    const out = aggregateWeekToList([
      { name: 'Mystery powder', quantity: 1, unit: 'bag' },
      { name: 'Milk', quantity: 1, unit: 'gal' },
    ]);
    expect(out[0].aisle).toBe('Dairy');
    expect(out[out.length - 1].aisle).toBe('Other');
  });

  it('keeps display-only quantities', () => {
    const out = aggregateWeekToList([{ name: 'Salt', display: 'a pinch' }]);
    expect(out[0].quantity).toBe('a pinch');
  });

  it('never merges measured with unmeasured (keeps "to taste")', () => {
    const out = aggregateWeekToList([
      { name: 'Salt', quantity: 1, unit: 'tsp' },
      { name: 'Salt', display: 'to taste' },
      { name: 'Salt', display: 'a pinch' },
    ]);
    expect(out.filter((i) => i.name === 'Salt')).toHaveLength(3);
  });

  it('ignores empty displays instead of blanking quantities', () => {
    const out = aggregateWeekToList([{ name: 'Pepper', quantity: 2, unit: 'tsp', display: '  ' }]);
    expect(out[0].quantity).toBe('2 tsp');
  });

  it('strips a trailing ingredient name from caption displays', () => {
    const out = aggregateWeekToList([
      { name: 'oats', quantity: 200, unit: 'g', display: '200 g oats' },
    ]);
    expect(out[0].quantity).toBe('200 g');
  });

  it('falls back to the numeric quantity when only the name remains', () => {
    const out = aggregateWeekToList([
      { name: 'oats', quantity: 200, unit: 'g', display: 'oats' },
    ]);
    expect(out[0].quantity).toBe('200 g');
  });
});

describe('scaleIngredientsForServings', () => {
  it('scales measured quantities, passes unmeasured through', () => {
    const out = scaleIngredientsForServings(
      [
        { name: 'Flour', quantity: 2, unit: 'cups' },
        { name: 'Salt', display: 'to taste' },
      ],
      4,
      8,
    );
    expect(out[0]).toMatchObject({ quantity: 4, display: '4 cups' });
    expect(out[1]).toEqual({ name: 'Salt', display: 'to taste' });
  });

  it('preserves descriptive display text while rescaling the number', () => {
    const out = scaleIngredientsForServings(
      [
        { name: 'Tomatoes', quantity: 2, unit: '', display: '2 ripe, diced' },
        { name: 'Flour', quantity: 1.5, unit: 'cups', display: '1 1/2 cups sifted' },
      ],
      4,
      8,
    );
    expect(out[0]).toMatchObject({ quantity: 4, display: '4 ripe, diced' });
    expect(out[1]).toMatchObject({ quantity: 3, display: '3 cups sifted' });
  });

  it('keeps display text without a leading number unchanged', () => {
    const out = scaleIngredientsForServings(
      [{ name: 'Salt', quantity: 1, unit: 'pinch', display: 'a pinch of salt' }],
      4,
      8,
    );
    expect(out[0]).toMatchObject({ quantity: 2, display: 'a pinch of salt' });
  });
});

describe('splitLeadingQuantity / rescaleDisplay', () => {
  it('parses integers, decimals and fractions', () => {
    expect(splitLeadingQuantity('12 oz')).toEqual({ value: 12, rest: 'oz' });
    expect(splitLeadingQuantity('1 1/2 cups ripe')).toEqual({ value: 1.5, rest: 'cups ripe' });
    expect(splitLeadingQuantity('3/4 tsp')).toEqual({ value: 0.75, rest: 'tsp' });
    expect(splitLeadingQuantity('0.5 l')).toEqual({ value: 0.5, rest: 'l' });
    expect(splitLeadingQuantity('to taste')).toBeNull();
  });

  it('rescales the prefix only', () => {
    expect(rescaleDisplay('2 ripe, diced', 2)).toBe('4 ripe, diced');
    expect(rescaleDisplay('12 oz', 0.5)).toBe('6 oz');
    expect(rescaleDisplay('to taste', 4)).toBe('to taste');
  });
});

describe('collectPlanIngredients', () => {
  const days = ['2026-01-05', '2026-01-06', '2026-01-07', '2026-01-08', '2026-01-09', '2026-01-10', '2026-01-11'];
  const lookup = (id: string) =>
    id === 'pasta'
      ? { servings: 4, ingredients: [{ name: 'Spaghetti', quantity: 12, unit: 'oz' }] }
      : undefined;

  it('filters to the week and scales by plan servings', () => {
    const out = collectPlanIngredients(
      [
        { date: '2026-01-05', servings: 8, recipeId: 'pasta' },
        { date: '2026-02-01', servings: 8, recipeId: 'pasta' }, // outside week
        { date: '2026-01-06', servings: null, recipeId: 'missing' }, // unknown recipe
      ],
      days,
      lookup,
    );
    expect(out).toHaveLength(1);
    expect(out[0]).toMatchObject({ name: 'Spaghetti', quantity: 24, recipeId: 'pasta' });
  });
});
