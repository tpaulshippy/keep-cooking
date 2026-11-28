import { describe, expect, it } from 'vitest';
import { safeHttpUrl, ingredientLabel, recipePhotoKey } from './display';

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

describe('recipePhotoKey', () => {
  it('prefers thumb for lists, large for detail', () => {
    const payload = { photoKeys: { original: 'photos/r/original.jpg', large1024: 'photos/r/1024.jpg', thumb: 'photos/r/thumb.jpg' } };
    expect(recipePhotoKey(payload, 'thumb')).toBe('photos/r/thumb.jpg');
    expect(recipePhotoKey(payload, 'large')).toBe('photos/r/1024.jpg');
  });

  it('falls back across variants and returns null when empty', () => {
    expect(recipePhotoKey({ photoKeys: { original: 'photos/r/original.jpg' } }, 'thumb')).toBe('photos/r/original.jpg');
    expect(recipePhotoKey({ photoKeys: { thumb: 'photos/r/thumb.jpg' } }, 'large')).toBe('photos/r/thumb.jpg');
    expect(recipePhotoKey({ photoKeys: { original: '', large1024: '', thumb: '' } }, 'thumb')).toBeNull();
    expect(recipePhotoKey({}, 'thumb')).toBeNull();
    expect(recipePhotoKey(null, 'large')).toBeNull();
  });
});
describe('ingredientLabel', () => {
  it('prefixes truthy display with the name, falls back when blank', () => {
    expect(ingredientLabel({ name: 'Salt', display: 'to taste' })).toBe('to taste Salt');
    expect(ingredientLabel({ name: 'Garlic', quantity: 4, unit: 'cloves', display: '4 cloves' }))
      .toBe('4 cloves Garlic');
    expect(ingredientLabel({ name: 'Spaghetti', quantity: 12, unit: 'oz', display: '' }))
      .toBe('12 oz Spaghetti');
    expect(ingredientLabel({ name: 'Salt' })).toBe('Salt');
  });

  it('falls back to derived line for whitespace-only display', () => {
    expect(ingredientLabel({ name: 'Spaghetti', quantity: 12, unit: 'oz', display: '   ' }))
      .toBe('12 oz Spaghetti');
  });

  it('does not duplicate the name when display already ends with it', () => {
    expect(ingredientLabel({ name: 'Spaghetti', display: '12 oz Spaghetti' }))
      .toBe('12 oz Spaghetti');
    expect(ingredientLabel({ name: 'salt', display: 'To Taste Salt' }))
      .toBe('To Taste Salt');
  });
});
