import { describe, expect, it } from 'vitest';
import { aggregateWeekToList, guessAisle } from './aggregate';

describe('guessAisle', () => {
  it('classifies staples', () => {
    expect(guessAisle('Whole milk')).toBe('Dairy');
    expect(guessAisle('Chicken breast')).toBe('Meat');
    expect(guessAisle('Spaghetti')).toBe('Dry Goods');
    expect(guessAisle('Mystery powder')).toBe('Other');
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
});
