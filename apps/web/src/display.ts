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

/** Compact duration label: 25 -> "25 min", 85 -> "1 hr 25 min", 120 -> "2 hr". */
export function formatMinutes(n: number): string {
  if (!Number.isFinite(n) || n < 0) return '';
  const m = Math.round(n);
  const h = Math.floor(m / 60);
  const rest = m % 60;
  if (h === 0) return `${rest} min`;
  if (rest === 0) return `${h} hr`;
  return `${h} hr ${rest} min`;
}

/** Clamp minute fields to the API range (nonnegative int, ≤10080);
 *  blank/invalid -> undefined (field left unset). */
export function clampMinutes(v: string): number | undefined {
  const s = v.trim();
  if (!s) return undefined;
  const n = Number(s);
  if (!Number.isFinite(n)) return undefined;
  return Math.min(10080, Math.max(0, Math.round(n)));
}

/** Clamp servings to the API range 0.25–100 (quarter steps);
 *  blank/invalid/nonpositive -> default 4. */
export function clampServings(v: string): number {
  const s = v.trim();
  if (!s) return 4;
  const n = Number(s);
  if (!Number.isFinite(n) || n <= 0) return 4;
  return Math.min(100, Math.max(0.25, Math.round(n * 4) / 4));
}

// Editor textarea round-trip shapes (structural subset of the recipe rows).
export interface TextIngredient {
  id?: string; name: string; quantity?: number | null; unit?: string;
  display?: string; position?: number;
}
export interface TextStep {
  id?: string; text: string; position?: number;
  timers?: { seconds: number; label: string }[];
}

/** One textarea line per ingredient. Display+name pairs join as
 *  "display name" unless either side already contains the other
 *  (prevents "line line" duplication when display === name or when the
 *  name already carries the display text, in either direction). A blank
 *  display falls back to the derived "quantity unit name" so the amounts
 *  stay visible (and re-matchable) in the text editor. */
export function ingredientLine(ing: TextIngredient): string {
  const d = (ing.display ?? '').trim();
  const n = (ing.name ?? '').trim();
  if (d && d.toLowerCase() !== n.toLowerCase()) {
    if (n.toLowerCase().startsWith(d.toLowerCase())) return n;
    if (d.toLowerCase().endsWith(n.toLowerCase())) return d;
    return `${d} ${n}`;
  }
  return ingredientLabel(ing).trim() || 'ingredient';
}

/** One textarea line per ingredient, preserving group headers ("X:") as lines. */
export function ingredientsToText(ings: TextIngredient[]): string {
  return ings.map((ing) => ingredientLine(ing)).join('\n');
}

/** Round-trip textarea lines to ingredient rows in three passes:
 *  1. exact line matches carry over id/quantity/unit/display (first match
 *     wins); 2. edited names that still contain (or are contained in) an
 *     unmatched original inherit its quantity/unit/id — a renamed
 *     "Flour" keeps scaling instead of degrading to a bare row (a stale
 *     display that no longer appears in the line is cleared);
 *  3. everything else (incl. "Header:" group lines, which never inherit
 *     structured fields) becomes a plain row. Never drops rows silently —
 *  every non-blank line yields a row. */
export function textToIngredients(text: string, prev: TextIngredient[]): TextIngredient[] {
  const lines = text.split('\n').map((l) => l.trim()).filter(Boolean);
  const byLine = new Map<string, TextIngredient[]>();
  for (const ing of prev) {
    const key = ingredientLine(ing);
    const list = byLine.get(key);
    if (list) list.push(ing);
    else byLine.set(key, [ing]);
  }
  const claimed = new Set<TextIngredient>();
  const out: (TextIngredient | null)[] = lines.map((line) => {
    const match = (byLine.get(line) ?? []).find((ing) => !claimed.has(ing)) ?? null;
    if (match) {
      claimed.add(match);
      return { ...match };
    }
    return null;
  });
  const norm = (s: string): string => s.toLowerCase();
  for (let i = 0; i < lines.length; i++) {
    if (out[i] || lines[i]!.endsWith(':')) continue;
    const line = lines[i]!;
    const cand = prev.find((ing) => {
      if (claimed.has(ing)) return false;
      const name = (ing.name ?? '').trim();
      if (!name || name.endsWith(':')) return false;
      return norm(line) === norm(name) || norm(line).includes(norm(name)) || norm(name).includes(norm(line));
    });
    if (!cand) continue;
    claimed.add(cand);
    const d = (cand.display ?? '').trim();
    out[i] = {
      ...cand,
      name: line,
      display: d && norm(line).includes(norm(d)) ? cand.display : '',
    };
  }
  return lines.map((line, i) => out[i] ?? { name: line }).map((ing, i) => ({ ...ing, position: i }));
}

/** Steps round-trip on blank-line-separated paragraphs. Exact text matches
 *  keep id/timers; a second positional pass lets in-place text edits keep
 *  their countdowns (trade-off: a reorder moves timers with the position,
 *  not the text — still strictly better than dropping them on every edit). */
export function stepsToText(steps: TextStep[]): string {
  return steps.map((s) => s.text.trim()).filter(Boolean).join('\n\n');
}

export function textToSteps(text: string, prev: TextStep[]): TextStep[] {
  const paras = text.split(/\n\s*\n/).map((b) => b.trim()).filter(Boolean);
  const byText = new Map<string, TextStep[]>();
  for (const s of prev) {
    const list = byText.get(s.text.trim());
    if (list) list.push(s);
    else byText.set(s.text.trim(), [s]);
  }
  const claimed = new Set<TextStep>();
  const out: (TextStep | null)[] = paras.map((para) => {
    const match = (byText.get(para) ?? []).find((s) => !claimed.has(s)) ?? null;
    if (match) {
      claimed.add(match);
      return { ...match, text: para };
    }
    return null;
  });
  for (let i = 0; i < paras.length; i++) {
    if (out[i]) continue;
    const at = prev[i];
    if (at && !claimed.has(at)) {
      claimed.add(at);
      out[i] = { ...at, text: paras[i]! };
    }
  }
  return paras.map((para, i) => out[i] ?? { text: para }).map((s, i) => ({ ...s, position: i }));
}

/** "Key: value" nutrition lines render as a two-column read-only table. */
export function nutritionRows(text: string): { k: string; v: string }[] {
  return text.split('\n').map((l) => l.trim()).filter(Boolean).map((line) => {
    const idx = line.indexOf(':');
    if (idx === -1) return { k: line, v: '' };
    return { k: line.slice(0, idx).trim(), v: line.slice(idx + 1).trim() };
  });
}

// Photo payload shape for the editor Photos row (subset of the recipe payload).
export interface EditorPhotoPayload {
  photos?: unknown; photo?: unknown; photoUrl?: unknown; imageUrl?: unknown;
  photoKeys?: { original?: string; large1024?: string; thumb?: string } | null;
}

/** Photo count reads the API-standard `photoKeys` ({original, large1024,
 *  thumb}) and resolves the thumbnail through the shared hero resolver
 *  (recipePhotoKey — the caller hydrates it for a signed R2 URL), so the
 *  editor never reports zero photos for synced recipes. Legacy bare
 *  http(s) photo fields still render directly. Counts distinct photos. */
export function editorPhotos(p: EditorPhotoPayload): { count: number; key: string | null; legacyUrl: string | null } {
  const std = p.photoKeys;
  const stdKeys = std && typeof std === 'object'
    ? [...new Set(['original', 'large1024', 'thumb']
      .map((k) => String((std as Record<string, unknown>)[k] ?? '').trim())
      .filter(Boolean))]
    : [];
  if (stdKeys.length > 0) {
    const thumb = recipePhotoKey(p, 'large') ?? recipePhotoKey(p, 'thumb');
    return { count: stdKeys.length, key: thumb, legacyUrl: null };
  }
  const raw = p.photos;
  const list: unknown[] = Array.isArray(raw) ? raw : [];
  const candidates: unknown[] = [
    ...list,
    p.photo,
    p.photoUrl,
    p.imageUrl,
  ].filter((v) => typeof v === 'string' && (v as string).trim() !== '');
  const urls = [...new Set(
    candidates.map((v) => safeHttpUrl(v)).filter((v): v is string => v !== null),
  )];
  // Array-form photos count even when the URLs aren't renderable (offline blobs);
  // bare string fields count when they hold a safe http(s) URL.
  const count = Array.isArray(raw) ? new Set(raw.map((v) => JSON.stringify(v))).size : urls.length;
  return { count, key: null, legacyUrl: urls[0] ?? null };
}
