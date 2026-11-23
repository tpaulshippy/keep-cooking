// Scale lib: quantities × servings/baseServings, display fraction-rounded
// to 1/4 steps with 1/2, 1/3, 2/3, 1/8 support (per contracts README).

const FRACS: { value: number; label: string }[] = [
  { value: 0, label: '' },
  { value: 1 / 8, label: '1/8' },
  { value: 1 / 4, label: '1/4' },
  { value: 1 / 3, label: '1/3' },
  { value: 1 / 2, label: '1/2' },
  { value: 2 / 3, label: '2/3' },
  { value: 3 / 4, label: '3/4' },
  { value: 7 / 8, label: '7/8' },
  { value: 1, label: '' }, // carry into whole
];

export function fractionLabel(rem: number): { whole: number; label: string } {
  let best = FRACS[0]!;
  let bestDist = Infinity;
  for (const f of FRACS) {
    const d = Math.abs(f.value - rem);
    if (d < bestDist) {
      bestDist = d;
      best = f;
    }
  }
  if (best.value === 1) return { whole: 1, label: '' };
  return { whole: 0, label: best.label };
}

/** Format a scaled quantity as a fraction-rounded display string. */
export function formatQuantity(qty: number | null, unit: string): string {
  if (qty == null || Number.isNaN(qty)) return unit ? unit : '';
  if (qty <= 0) return unit ? `0 ${unit}` : '0';
  const rounded8 = Math.round(qty * 8) / 8;
  // Prefer thirds when closer than eighths (e.g. 0.333).
  const rounded3 = Math.round(qty * 3) / 3;
  const use = Math.abs(rounded3 - qty) < Math.abs(rounded8 - qty) - 1e-9 ? rounded3 : rounded8;
  let whole = Math.floor(use + 1e-9);
  let rem = use - whole;
  if (rem > 1 - 1e-9) {
    whole += 1;
    rem = 0;
  } else if (rem < 1e-9) {
    rem = 0;
  }
  const { whole: carry, label } = fractionLabel(rem);
  whole += carry;
  const num = label ? (whole > 0 ? `${whole} ${label}` : label) : `${whole}`;
  const trimmed = num === '0' && label ? label : num;
  return unit ? `${trimmed} ${unit}`.trim() : trimmed;
}

export interface ScalableIngredient {
  quantity: number | null;
  unit: string;
  display: string;
}

/** Scale a recipe's ingredient quantities; returns new servings + ingredients. */
export function scaleRecipe<T extends ScalableIngredient>(
  ingredients: T[],
  baseServings: number,
  targetServings: number,
): { factor: number; ingredients: T[] } {
  const base = baseServings > 0 ? baseServings : 4;
  const factor = targetServings / base;
  const scaled = ingredients.map((ing) => {
    const q = ing.quantity == null ? null : Math.round(ing.quantity * factor * 1000) / 1000;
    return { ...ing, quantity: q, display: formatQuantity(q, ing.unit || '') };
  });
  return { factor, ingredients: scaled };
}
