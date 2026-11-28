import { describe, expect, it } from 'vitest';
import {
  safeHttpUrl, ingredientLabel, recipePhotoKey, formatMinutes, clampMinutes,
  clampServings, ingredientLine, ingredientsToText, textToIngredients,
  stepsToText, textToSteps, nutritionRows, editorPhotos,
} from './display';

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

describe('ingredientLine', () => {
  it('joins display + name without duplicating either direction', () => {
    expect(ingredientLine({ name: 'Salt', display: 'to taste' })).toBe('to taste Salt');
    // Name already carries the display (either direction) — no duplication.
    expect(ingredientLine({ name: '1 pouch (17.5 oz) Sugar Cookie Mix', display: '1 pouch (17.5 oz)' }))
      .toBe('1 pouch (17.5 oz) Sugar Cookie Mix');
    expect(ingredientLine({ name: 'Spaghetti', display: '12 oz Spaghetti' })).toBe('12 oz Spaghetti');
    expect(ingredientLine({ name: 'Sugar Cookie Mix', display: 'Sugar Cookie Mix' }))
      .toBe('Sugar Cookie Mix');
  });

  it('renders blank-display rows as quantity unit name', () => {
    expect(ingredientLine({ name: 'Flour', quantity: 2, unit: 'cups', display: '' }))
      .toBe('2 cups Flour');
  });
});

describe('textToIngredients', () => {
  it('preserves id/quantity/unit on exact matches and renames', () => {
    const prev = [{ id: 'a', name: 'Flour', quantity: 2, unit: 'cups', display: '', position: 0 }];
    const [row] = textToIngredients('2 cups Flour', prev);
    expect(row).toMatchObject({ id: 'a', quantity: 2, unit: 'cups' });
    // Edited name still contains the original: structured fields survive.
    const [renamed] = textToIngredients('2 cups Whole wheat flour', prev);
    expect(renamed).toMatchObject({ id: 'a', quantity: 2, unit: 'cups' });
    expect(renamed!.name).toBe('2 cups Whole wheat flour');
  });

  it('keeps group headers as plain rows and never drops lines', () => {
    const rows = textToIngredients('Cookie Base:\n1 egg\n', [{ name: 'x', position: 0 }]);
    expect(rows).toHaveLength(2);
    expect(rows[0]).toMatchObject({ name: 'Cookie Base:' });
    expect(rows[1]).toMatchObject({ name: '1 egg', position: 1 });
  });
});

describe('textToSteps', () => {
  it('preserves timers on in-place text edits', () => {
    const prev = [{
      id: 's1', text: 'Stir 5 min.', position: 0,
      timers: [{ seconds: 300, label: 'Stir' }],
    }];
    const [edited] = textToSteps('Stir 10 min.', prev);
    expect(edited).toMatchObject({ id: 's1', text: 'Stir 10 min.' });
    expect(edited!.timers).toEqual([{ seconds: 300, label: 'Stir' }]);
  });
});

describe('formatMinutes/clamps', () => {
  it('formats durations like the native sheet', () => {
    expect(formatMinutes(25)).toBe('25 min');
    expect(formatMinutes(60)).toBe('1 hr');
    expect(formatMinutes(85)).toBe('1 hr 25 min');
  });

  it('clamps numbers to the API ranges', () => {
    expect(clampMinutes('-1')).toBe(0);
    expect(clampMinutes('1.5')).toBe(2);
    expect(clampMinutes('99999')).toBe(10080);
    expect(clampMinutes('15000')).toBe(10080);
    expect(clampMinutes('15000', 20160)).toBe(15000);
    expect(clampMinutes('99999', 20160)).toBe(20160);
    expect(clampMinutes('')).toBeUndefined();
    expect(clampServings('-2')).toBe(4);
    expect(clampServings('1000')).toBe(100);
    expect(clampServings('0.1')).toBe(0.25);
    expect(clampServings('2.5')).toBe(2.5);
  });
});

describe('editorPhotos', () => {
  it('reads photoKeys for count and resolves through the shared key', () => {
    const got = editorPhotos({ photoKeys: { original: 'photos/r/o.jpg', large1024: 'photos/r/1024.jpg', thumb: 'photos/r/thumb.jpg' } });
    expect(got.count).toBe(3);
    expect(got.key).toBe('photos/r/1024.jpg');
    expect(got.legacyUrl).toBeNull();
  });

  it('dedupes keys and falls back to legacy urls', () => {
    const dup = editorPhotos({ photoKeys: { original: 'photos/r/o.jpg', large1024: 'photos/r/o.jpg', thumb: '' } });
    expect(dup.count).toBe(1);
    expect(editorPhotos({ photo: 'https://example.com/p.jpg' })).toMatchObject({ count: 1, legacyUrl: 'https://example.com/p.jpg' });
    expect(editorPhotos({})).toMatchObject({ count: 0, key: null, legacyUrl: null });
  });
});

describe('nutritionRows', () => {
  it('splits key/value lines for the table view', () => {
    expect(nutritionRows('Calories: 130 calories\nNo colon line')).toEqual([
      { k: 'Calories', v: '130 calories' },
      { k: 'No colon line', v: '' },
    ]);
  });
});

describe('stepsToText/ingredientsToText', () => {
  it('round-trips through the textarea formats', () => {
    expect(ingredientsToText([{ name: 'Flour', quantity: 2, unit: 'cups', display: '' }]))
      .toBe('2 cups Flour');
    expect(stepsToText([{ text: 'A' }, { text: 'B' }])).toBe('A\n\nB');
  });
});
