import { describe, expect, it } from 'vitest';
import { scaleQuantity, formatQuantity } from './scale';

describe('scaleQuantity', () => {
  it('scales proportionally', () => {
    expect(scaleQuantity(2, 4, 8)).toBe(4);
    expect(scaleQuantity(1, 4, 2)).toBe(0.5);
    expect(scaleQuantity(0.25, 4, 6)).toBe(0.38); // 0.375 rounded to 2dp
  });

  it('is null-safe', () => {
    expect(scaleQuantity(null, 4, 8)).toBeNull();
    expect(scaleQuantity(undefined, 4, 8)).toBeNull();
  });

  it('guards degenerate servings', () => {
    expect(scaleQuantity(2, 0, 8)).toBe(2);
    expect(scaleQuantity(2, 4, 0)).toBe(2);
  });

  it('returns the original quantity when scaling overflows to Infinity', () => {
    expect(scaleQuantity(1e308, 1, 10)).toBe(1e308);
  });
});

describe('formatQuantity', () => {
  it('renders quarter fractions', () => {
    expect(formatQuantity(1.5, 'cups')).toBe('1 1/2 cups');
    expect(formatQuantity(0.25, 'cup')).toBe('1/4 cup');
    expect(formatQuantity(2, '')).toBe('2');
  });

  it('rounds to nearest 1/4 / 1/3 / 1/8 (mirrors api/src/scale.ts)', () => {
    expect(formatQuantity(1.5, 'lb')).toBe('1 1/2 lb');
    expect(formatQuantity(2, 'tbsp')).toBe('2 tbsp');
    expect(formatQuantity(0.333, 'cup')).toBe('1/3 cup');
    expect(formatQuantity(0.666, 'cup')).toBe('2/3 cup');
    expect(formatQuantity(0.125, 'tsp')).toBe('1/8 tsp');
    expect(formatQuantity(1.74, 'cup')).toBe('1 3/4 cup');
  });

  it('handles missing values', () => {
    expect(formatQuantity(null)).toBe('—');
  });

  it('preserves sign for negative quarters', () => {
    expect(formatQuantity(-1.5, 'cups')).toBe('-1 1/2 cups');
    expect(formatQuantity(-0.25, 'cup')).toBe('-1/4 cup');
    expect(formatQuantity(-2, '')).toBe('-2');
  });
});
