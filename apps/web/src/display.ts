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

/** Recipe photo variant: `thumb` for list rows, `large` for detail/cook hero. */
export type PhotoVariant = 'thumb' | 'large';

/** Preferred R2 photo key (or absolute http(s) image URL) for a recipe
 *  payload. Reads `photoKeys` ({original, large1024, thumb}); thumb rows
 *  prefer thumb → large1024 → original, detail prefers large1024 →
 *  original → thumb. Returns null when no usable value is stored. */
export function recipePhotoKey(payload: unknown, variant: PhotoVariant): string | null {
  const p = payload as { photoKeys?: unknown } | null | undefined;
  const keys = (p?.photoKeys ?? {}) as Record<string, unknown>;
  const str = (v: unknown): string | null => {
    const s = String(v ?? '').trim();
    return s ? s : null;
  };
  const ordered = variant === 'thumb'
    ? [str(keys.thumb), str(keys.large1024), str(keys.original)]
    : [str(keys.large1024), str(keys.original), str(keys.thumb)];
  return ordered.find((k) => k !== null) ?? null;
}

/** Ingredient row label: the name always survives. Seed/API `display`
 *  strings are quantity-only ("12 oz", "to taste"), so a truthy display
 *  prefixes the name; a blank display falls back to the derived
 *  "quantity unit name" (never `??`, which would render a blank row). */
export function ingredientLabel(ing: IngredientLike): string {
  const display = ing.display?.trim();
  if (display) {
    const name = ing.name.trim();
    if (name !== '' && display.toLowerCase().endsWith(name.toLowerCase())) return display;
    return `${display} ${name}`.trim();
  }
  return [ing.quantity, ing.unit, ing.name]
    .filter((x) => x !== undefined && x !== null && x !== '')
    .join(' ');
}
