// Week -> shopping-list aggregation with aisle guess. Pure functions.

import { scaleQuantity, formatQuantity } from './scale';

export interface AggIngredient { name: string; quantity?: number | null; unit?: string; display?: string; recipeId?: string; }
export interface AggItem { name: string; quantity: string; aisle: string; recipeId?: string | null; }

const AISLE_RULES: [RegExp, string][] = [
  [/frozen|ice cream|peas\b/i, 'Frozen'],
  [/milk|cheese|yogurt|butter|cream|\beggs?\b/i, 'Dairy'],
  [/apple|banana|onion|garlic|tomato|lettuce|spinach|potato|carrot|lemon|herb|parsley|cilantro|basil|eggplant/i, 'Produce'],
  [/chicken|beef|pork|fish|salmon|turkey|bacon|sausage/i, 'Meat'],
  [/bread|tortilla|bun|roll|bagel/i, 'Bakery'],
  [/flour|sugar|rice|pasta|spaghetti|noodle|oil|vinegar|spice|salt|pepper|bean|lentil|oat|cereal|honey/i, 'Dry Goods'],
];

export function guessAisle(name: string): string {
  for (const [re, aisle] of AISLE_RULES) {
    if (re.test(name)) return aisle;
  }
  return 'Other';
}

/** Caption-ingested recipes store the whole ingredient line in `display`
 * (e.g. display "200 g oats" alongside name "oats"). Strip a trailing
 * ingredient name so the shopping quantity shows the amount, not
 * "amount + name". Returns the stripped text (may be ''). */
export function stripTrailingName(display: string, name: string): string {
  const d = display.trim();
  const n = name.trim();
  if (!d || !n) return d;
  if (d.toLowerCase().endsWith(n.toLowerCase())) {
    return d.slice(0, d.length - n.length).trim();
  }
  return d;
}

/** Merge ingredients with the same normalized name+unit; quantities sum.
 * Measured and unmeasured entries never merge (so 'to taste' survives next
 * to a measured amount), and distinct unmeasured displays stay separate. */
export function aggregateWeekToList(ingredients: AggIngredient[]): AggItem[] {
  const byKey = new Map<string, AggItem & { qtyNum: number; unit: string; hasQty: boolean }>();
  for (const ing of ingredients) {
    const name = ing.name.trim();
    if (!name) continue;
    const unit = (ing.unit ?? '').trim();
    const display = ing.display?.trim() ? ing.display.trim() : undefined;
    const qty = typeof ing.quantity === 'number' && isFinite(ing.quantity) ? ing.quantity : NaN;
    const key = isNaN(qty)
      ? `${name.toLowerCase()}|${unit.toLowerCase()}|${(display ?? '').toLowerCase()}`
      : `${name.toLowerCase()}|${unit.toLowerCase()}`;
    const existing = byKey.get(key);
    if (!existing) {
      const numericFallback = isNaN(qty) ? '' : unit ? `${trimNum(qty)} ${unit}`.trim() : `${trimNum(qty)}`;
      let qtyText = numericFallback;
      if (display) {
        const stripped = stripTrailingName(display, name);
        qtyText = stripped ? stripped : numericFallback;
      }
      byKey.set(key, {
        name,
        quantity: qtyText,
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
      } else if (!existing.quantity && display) {
        existing.quantity = display;
      }
      if (!existing.recipeId && ing.recipeId) existing.recipeId = ing.recipeId;
    }
  }
  return [...byKey.values()]
    .map(({ qtyNum: _q, unit: _u, hasQty: _h, ...rest }) => rest)
    .sort((a, b) => a.aisle.localeCompare(b.aisle) || a.name.localeCompare(b.name));
}

/** Split "1 1/2 cups ripe, diced" into value 1.5 + rest "cups ripe, diced".
 * Returns null when the text has no leading number. */
export function splitLeadingQuantity(text: string): { value: number; rest: string } | null {
  const m = text.match(/^\s*(\d+\s+\d+\s*\/\s*\d+|\d+\s*\/\s*\d+|\d+(?:\.\d+)?)\s*(.*)$/);
  if (!m) return null;
  const [, num, rest] = m;
  let value: number;
  if (num.includes('/')) {
    const [whole, frac] = num.split(/\s+/).length > 1
      ? [num.split(/\s+/)[0], num.split(/\s+/).slice(1).join(' ')]
      : ['0', num];
    const [n, d] = frac.split('/').map(Number);
    if (!isFinite(n) || !isFinite(d) || d === 0) return null;
    value = Number(whole) + n / d;
  } else {
    value = Number(num);
  }
  if (!isFinite(value)) return null;
  return { value, rest: rest.trim() };
}

/** Rescale a display string's numeric prefix by factor, preserving the
 * remaining text ('2 ripe, diced' ×2 → '4 ripe, diced'). No leading number →
 * display returned unchanged. */
export function rescaleDisplay(display: string, factor: number): string {
  const parsed = splitLeadingQuantity(display);
  if (!parsed) return display;
  const scaled = formatQuantity(parsed.value * factor);
  return parsed.rest ? `${scaled} ${parsed.rest}` : scaled;
}

/** Scale a recipe's ingredients from its base servings to a target (e.g. a
 * plan's servings). Measured quantities scale numerically; the display keeps
 * any descriptive text ('2 ripe, diced' ×2 → '4 ripe, diced'). Unmeasured
 * entries ('to taste') pass through untouched. */
export function scaleIngredientsForServings(
  ingredients: AggIngredient[],
  recipeServings: number | null | undefined,
  targetServings: number | null | undefined,
): AggIngredient[] {
  const base = recipeServings && isFinite(recipeServings) && recipeServings > 0 ? recipeServings : 4;
  const target = targetServings && isFinite(targetServings) && targetServings > 0 ? targetServings : base;
  return ingredients.map((ing) => {
    if (typeof ing.quantity !== 'number' || !isFinite(ing.quantity)) return ing;
    const q = scaleQuantity(ing.quantity, base, target);
    const unit = (ing.unit ?? '').trim();
    const baseDisplay = ing.display?.trim() ? ing.display.trim() : formatQuantity(ing.quantity, unit);
    return { ...ing, quantity: q, display: rescaleDisplay(baseDisplay, target / base) };
  });
}

export interface PlanMeal { date: string; servings?: number | null; recipeId?: string | null; }
export interface RecipeForPlan { servings?: number | null; ingredients?: AggIngredient[]; }

/** Ingredients for one week's plans: filtered to the displayed days, each
 * recipe scaled by its plan servings before aggregation. */
export function collectPlanIngredients(
  plans: PlanMeal[],
  days: string[],
  lookup: (recipeId: string) => RecipeForPlan | undefined,
): AggIngredient[] {
  const inWeek = new Set(days);
  return plans
    .filter((pl) => pl.recipeId && inWeek.has(pl.date))
    .flatMap((pl) => {
      const recipe = lookup(pl.recipeId as string);
      if (!recipe) return [];
      const recipeServings = recipe.servings ?? 4;
      return scaleIngredientsForServings(
        recipe.ingredients ?? [],
        recipeServings,
        pl.servings ?? recipeServings,
      ).map((i) => ({ ...i, recipeId: pl.recipeId ?? undefined }));
    });
}

function trimNum(n: number): string {
  return `${Math.round(n * 100) / 100}`;
}
