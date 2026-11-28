import { describe, expect, it } from 'vitest';
import { aggregateWeekToList, guessAisle, scaleIngredientsForServings, collectPlanIngredients } from './aggregate';

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
