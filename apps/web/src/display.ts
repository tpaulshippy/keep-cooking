// Pure display/safety helpers (DOM-free, unit-testable).

export interface IngredientLike {
  name: string;
  quantity?: number | null;
  unit?: string;
  display?: string;
}

/** Allowlist http(s) URLs for href rendering. Returns the trimmed URL when
 *  safe, else null (caller renders plain text). Blocks javascript:, data:,
 *  relative paths and anything that doesn't parse as http/https. */
export function safeHttpUrl(url: unknown): string | null {
  const s = String(url ?? '').trim();
  if (!/^https?:\/\//i.test(s)) return null;
  try {
    const u = new URL(s);
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
  } catch {
    return null;
  }
  return s;
}

/** Ingredient row label: explicit display wins (truthy — a blank display
 *  falls back to the derived "quantity unit name" instead of rendering
 *  empty like `??` would). */
export function ingredientLabel(ing: IngredientLike): string {
  if (ing.display) return ing.display;
  return [ing.quantity, ing.unit, ing.name]
    .filter((x) => x !== undefined && x !== null && x !== '')
    .join(' ');
}
