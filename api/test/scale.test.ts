import { describe, it, expect } from 'vitest';
import { formatQuantity, scaleRecipe } from '../src/scale';

describe('formatQuantity', () => {
  it('formats whole + fraction with unit', () => {
    expect(formatQuantity(1.5, 'lb')).toBe('1 1/2 lb');
    expect(formatQuantity(0.25, 'cup')).toBe('1/4 cup');
    expect(formatQuantity(2, 'tbsp')).toBe('2 tbsp');
  });
  it('rounds to nearest 1/4 / 1/3 / 1/8', () => {
    expect(formatQuantity(0.333, 'cup')).toBe('1/3 cup');
    expect(formatQuantity(0.666, 'cup')).toBe('2/3 cup');
    expect(formatQuantity(0.125, 'tsp')).toBe('1/8 tsp');
    expect(formatQuantity(1.74, 'cup')).toBe('1 3/4 cup');
  });
  it('handles null quantity', () => {
    expect(formatQuantity(null, 'to taste')).toBe('to taste');
    expect(formatQuantity(null, '')).toBe('');
  });
});

describe('scaleRecipe', () => {
  const ings = [
    { quantity: 1.5, unit: 'lb', display: '1 1/2 lb' },
    { quantity: 3, unit: 'tbsp', display: '3 tbsp' },
    { quantity: null, unit: '', display: 'Salt to taste' },
  ];
  it('doubles 4 -> 8 servings', () => {
    const { factor, ingredients } = scaleRecipe(ings, 4, 8);
    expect(factor).toBe(2);
    expect(ingredients[0]!.quantity).toBe(3);
    expect(ingredients[0]!.display).toBe('3 lb');
    expect(ingredients[1]!.display).toBe('6 tbsp');
    expect(ingredients[2]!.quantity).toBeNull();
  });
  it('halves 4 -> 2 servings with fraction rounding', () => {
    const { ingredients } = scaleRecipe(ings, 4, 2);
    expect(ingredients[0]!.quantity).toBe(0.75);
    expect(ingredients[0]!.display).toBe('3/4 lb');
    expect(ingredients[1]!.display).toBe('1 1/2 tbsp');
  });
  it('scales thirds correctly (1 cup at 3 servings from 9)', () => {
    const { ingredients } = scaleRecipe([{ quantity: 3, unit: 'cup', display: '3 cup' }], 9, 3);
    expect(ingredients[0]!.display).toBe('1 cup');
  });
});
