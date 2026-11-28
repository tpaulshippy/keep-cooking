// Pure shopping-list helpers (no DOM): sortable rows, check-off toggling,
// and row markup. Kept here so the toggle-by-original-index logic and the
// check-off markup are unit-testable.

export interface ShopItem {
  name: string;
  quantity?: string;
  aisle?: string;
  checked?: boolean;
  recipeId?: string | null;
}

/** Sort a copy for display while keeping each row's ORIGINAL index, so a
 * toggle maps back to the unsorted array instead of the wrong item. */
export function sortedRows(items: ShopItem[]): { it: ShopItem; i: number }[] {
  return items
    .map((it, i) => ({ it, i }))
    .sort((a, b) => (a.it.aisle ?? '').localeCompare(b.it.aisle ?? '') || a.it.name.localeCompare(b.it.name));
}

/** Toggle one item by original index; all other items pass through untouched. */
export function toggleItemChecked<T extends { checked?: boolean }>(items: T[], index: number, checked: boolean): T[] {
  return items.map((it, i) => (i === index ? { ...it, checked } : it));
}

/** One aisle-sorted row. The name sits in a span adjacent to the checkbox so
 * `input:checked + span` line-through visibly marks the item (bare text nodes
 * can't be selected). `esc` is injected to keep this module DOM-free. */
export function shopRowHtml(it: ShopItem, originalIndex: number, esc: (v: unknown) => string): string {
  return `<li><label><input type="checkbox" data-item="${originalIndex}"${it.checked ? ' checked' : ''} /> <span class="item-name">${esc(it.name)}</span> <span class="muted">${esc(it.quantity ?? '')} · ${esc(it.aisle ?? 'Other')}</span></label></li>`;
}
