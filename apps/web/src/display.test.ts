import { describe, expect, it } from 'vitest';
import { safeHttpUrl, ingredientLabel } from './display';

describe('safeHttpUrl', () => {
  it('allows http/https only', () => {
    expect(safeHttpUrl('https://example.com/r')).toBe('https://example.com/r');
    expect(safeHttpUrl('http://example.com/')).toBe('http://example.com/');
    expect(safeHttpUrl('  HTTPS://example.com/x  ')).toBe('HTTPS://example.com/x');
    expect(safeHttpUrl('javascript:alert(1)')).toBeNull();
    expect(safeHttpUrl('JaVaScRiPt:alert(1)')).toBeNull();
    expect(safeHttpUrl('data:text/html,<h1>x</h1>')).toBeNull();
    expect(safeHttpUrl('/relative/path')).toBeNull();
    expect(safeHttpUrl('')).toBeNull();
    expect(safeHttpUrl(null)).toBeNull();
    expect(safeHttpUrl('https://')).toBeNull();
  });
});

describe('ingredientLabel', () => {
  it('prefers display, falls back when blank', () => {
    expect(ingredientLabel({ name: 'Salt', display: 'to taste' })).toBe('to taste');
    expect(ingredientLabel({ name: 'Spaghetti', quantity: 12, unit: 'oz', display: '' }))
      .toBe('12 oz Spaghetti');
    expect(ingredientLabel({ name: 'Salt' })).toBe('Salt');
  });
});
