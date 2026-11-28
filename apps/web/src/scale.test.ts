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
});

describe('formatQuantity', () => {
  it('renders quarter fractions', () => {
    expect(formatQuantity(1.5, 'cups')).toBe('1 1/2 cups');
    expect(formatQuantity(0.25, 'cup')).toBe('1/4 cup');
    expect(formatQuantity(2, '')).toBe('2');
  });

  it('handles missing values', () => {
    expect(formatQuantity(null)).toBe('—');
  });
});
