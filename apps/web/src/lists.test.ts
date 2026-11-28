import { describe, expect, it } from 'vitest';
import { sortedRows, toggleItemChecked, shopRowHtml } from './lists';

const esc = (v: unknown) => String(v ?? '').replace(/&/g, '&amp;');

describe('sortedRows', () => {
  it('sorts by aisle but keeps original indexes', () => {
    const rows = sortedRows([
      { name: 'Chips', aisle: 'Snacks' },
      { name: 'Milk', aisle: 'Dairy' },
    ]);
    expect(rows.map((r) => r.it.name)).toEqual(['Milk', 'Chips']);
    expect(rows[0]).toMatchObject({ i: 1 });
    expect(rows[1]).toMatchObject({ i: 0 });
  });
});

describe('toggleItemChecked', () => {
  it('toggles by original index only', () => {
    const items = [
      { name: 'a', checked: false },
      { name: 'b', checked: false },
    ];
    const out = toggleItemChecked(items, 1, true);
    expect(out[1].checked).toBe(true);
    expect(out[0].checked).toBe(false);
    expect(items[1].checked).toBe(false); // no mutation
  });
});

describe('shopRowHtml', () => {
  it('puts the name in a span adjacent to the checkbox (checked line-through hits it)', () => {
    const html = shopRowHtml({ name: 'Milk', quantity: '1 gal', aisle: 'Dairy', checked: true }, 3, esc);
    expect(html).toContain('data-item="3"');
    expect(html).toMatch(/<input[^>]*\/> <span class="item-name">Milk<\/span>/);
  });
});
