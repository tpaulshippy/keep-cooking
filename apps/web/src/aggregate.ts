// Week -> shopping-list aggregation with aisle guess. Pure functions.

export interface AggIngredient { name: string; quantity?: number | null; unit?: string; display?: string; recipeId?: string; }
export interface AggItem { name: string; quantity: string; aisle: string; recipeId?: string | null; }

const AISLE_RULES: [RegExp, string][] = [
  [/milk|cheese|yogurt|butter|cream|egg/i, 'Dairy'],
  [/apple|banana|onion|garlic|tomato|lettuce|spinach|potato|carrot|lemon|herb|parsley|cilantro|basil/i, 'Produce'],
  [/chicken|beef|pork|fish|salmon|turkey|bacon|sausage/i, 'Meat'],
  [/bread|tortilla|bun|roll|bagel/i, 'Bakery'],
  [/flour|sugar|rice|pasta|spaghetti|noodle|oil|vinegar|spice|salt|pepper|bean|lentil|oat|cereal|honey/i, 'Dry Goods'],
  [/frozen|ice cream|peas\b/i, 'Frozen'],
];

export function guessAisle(name: string): string {
  for (const [re, aisle] of AISLE_RULES) {
    if (re.test(name)) return aisle;
  }
  return 'Other';
}

/** Merge ingredients with the same normalized name+unit; quantities sum. */
export function aggregateWeekToList(ingredients: AggIngredient[]): AggItem[] {
  const byKey = new Map<string, AggItem & { qtyNum: number; unit: string; hasQty: boolean }>();
  for (const ing of ingredients) {
    const name = ing.name.trim();
    if (!name) continue;
    const unit = (ing.unit ?? '').trim();
    const key = `${name.toLowerCase()}|${unit.toLowerCase()}`;
    const qty = typeof ing.quantity === 'number' && isFinite(ing.quantity) ? ing.quantity : NaN;
    const existing = byKey.get(key);
    if (!existing) {
      byKey.set(key, {
        name,
        quantity: ing.display ?? (isNaN(qty) ? '' : unit ? `${trimNum(qty)} ${unit}`.trim() : `${trimNum(qty)}`),
        aisle: guessAisle(name),
        recipeId: ing.recipeId ?? null,
        qtyNum: isNaN(qty) ? 0 : qty,
        unit,
        hasQty: !isNaN(qty),
      });
    } else {
      if (!isNaN(qty)) {
        existing.qtyNum += qty;
        existing.hasQty = true;
        existing.quantity = existing.unit
          ? `${trimNum(existing.qtyNum)} ${existing.unit}`.trim()
          : `${trimNum(existing.qtyNum)}`;
      } else if (!existing.quantity && ing.display) {
        existing.quantity = ing.display;
      }
      if (!existing.recipeId && ing.recipeId) existing.recipeId = ing.recipeId;
    }
  }
  return [...byKey.values()]
    .map(({ qtyNum: _q, unit: _u, hasQty: _h, ...rest }) => rest)
    .sort((a, b) => a.aisle.localeCompare(b.aisle) || a.name.localeCompare(b.name));
}

function trimNum(n: number): string {
  return `${Math.round(n * 100) / 100}`;
}
