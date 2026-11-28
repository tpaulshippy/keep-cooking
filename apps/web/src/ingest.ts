// Pure helpers for the web Ingest tabs (Link / Text / Photo).
// DOM-free so they are unit-testable; viewIngest in main.ts owns all DOM I/O.
import type { RecipeInput } from './api';

/** First non-empty trimmed line, or '' when the text is blank. */
export function firstNonEmptyLine(text: string): string {
  for (const line of text.split(/\r?\n/)) {
    const t = line.trim();
    if (t) return t;
  }
  return '';
}

/**
 * Offline/local parse of pasted or transcribed text.
 * Same RecipeInput shape as the Link tab offline draft
 * ({ title, description, servings, ingredients, steps, sourceUrl? }),
 * plus source:'clip' mirroring the server caption fallback.
 * Title hint = first non-empty line (max 60 chars, matching Link drafts).
 * Quantity-led lines (e.g. "2 cups flour", "1/2 tsp salt") become
 * ingredients — mirroring api/src/clip.ts parseCaption — so the offline
 * preview shows ingredients instead of dropping them into steps.
 * Field caps mirror recipeInputSchema (description 8000, step text 8000,
 * ingredient name 300 / display 120) so the local draft stays valid.
 */
const PASTED_QTY_RE = /^(\d+(?:[./]\d+)?(?:\s+\d+\/\d+)?)\s*([a-zA-Z]*)\s+(.+)$/;
const PASTED_STEP_VERB_RE = /^(add|mix|heat|bake|stir|cook|serve|top|pour|chop|diced|minced)/i;

function parsePastedQtyIngredient(
  line: string,
  position: number,
): { name: string; quantity?: number | null; unit?: string; display?: string; position?: number } | null {
  const qm = line.match(PASTED_QTY_RE);
  if (!qm) return null;
  const qtyRaw = qm[1]!.trim();
  let qty: number | null = null;
  if (qtyRaw.includes('/')) {
    const parts = qtyRaw.split(/\s+/);
    let total = 0;
    let ok = true;
    for (const p of parts) {
      if (p.includes('/')) {
        const [a, b] = p.split('/').map(Number);
        if (!b) {
          ok = false;
          break;
        }
        total += a! / b!;
      } else {
        total += Number(p);
      }
    }
    qty = ok ? total : null;
  } else {
    qty = Number(qtyRaw);
  }
  return {
    name: qm[3]!.trim().slice(0, 300),
    quantity: Number.isFinite(qty) ? qty : null,
    unit: (qm[2] ?? '').slice(0, 60),
    display: line.slice(0, 120),
    position,
  };
}

export function parsePastedText(
  caption: string,
  opts?: { sourceUrl?: string },
): RecipeInput {
  const lines = caption
    .split(/\r?\n/)
    .map((l) => l.trim().replace(/^([-*•]\s+|\d+[.)]\s+)/, '').trim())
    .filter(Boolean);
  const title = (lines[0] ?? '').slice(0, 60) || 'Pasted draft';
  const ingredients: { name: string; quantity?: number | null; unit?: string; display?: string; position?: number }[] = [];
  const steps: { text: string; position: number }[] = [];
  if (lines.length === 1) {
    // Single-line paste: keep the line as one step (nothing else to split).
    steps.push({ text: lines[0]!.slice(0, 8000), position: 0 });
  } else {
    for (const line of lines.slice(1)) {
      const ing = parsePastedQtyIngredient(line, ingredients.length);
      if (ing) {
        if (ingredients.length < 200) ingredients.push(ing);
        continue;
      }
      if (line.length < 140 && PASTED_STEP_VERB_RE.test(line)) {
        if (steps.length < 200) steps.push({ text: line.slice(0, 8000), position: steps.length });
        continue;
      }
      if (ingredients.length === 0) {
        ingredients.push({ name: line.slice(0, 300), display: line.slice(0, 120), position: 0 });
        continue;
      }
      if (steps.length < 200) steps.push({ text: line.slice(0, 8000), position: steps.length });
    }
  }
  return {
    title,
    description: caption.trim().slice(0, 8000),
    servings: 4,
    source: 'clip',
    ingredients,
    steps,
    ...(opts?.sourceUrl ? { sourceUrl: opts.sourceUrl } : {}),
  };
}

/** Flatten a clipped/parsed recipe into editable preview field text. */
export function recipeToPreviewFields(recipe: RecipeInput): {
  title: string;
  ingredientsText: string;
  stepsText: string;
} {
  const ings = Array.isArray(recipe.ingredients) ? recipe.ingredients : [];
  const steps = Array.isArray(recipe.steps) ? recipe.steps : [];
  return {
    title: recipe.title ?? '',
    ingredientsText: ings
      .map((i) => (i.display ?? i.name ?? '').trim())
      .filter(Boolean)
      .join('\n'),
    stepsText: steps
      .map((s) => (s.text ?? '').trim())
      .filter(Boolean)
      .join('\n'),
  };
}

/**
 * Rebuild a RecipeInput from the editable preview fields.
 * Preserves the base (ClipReport.recipe / offline draft) metadata — source,
 * sourceUrl, servings, description, categories, etc. — overlaying only the
 * edited title/ingredients/steps. Keeps the Link-tab offline draft shape when
 * no base is given.
 */
export function previewToRecipeInput(
  fields: { title: string; ingredientsText: string; stepsText: string },
  baseOrExtra?: RecipeInput | { description?: string; sourceUrl?: string },
  maybeExtra?: { description?: string; sourceUrl?: string },
): RecipeInput {
  const isBaseRecipe = (
    v: unknown,
  ): v is RecipeInput =>
    typeof v === 'object' &&
    v !== null &&
    ('title' in v ||
      'servings' in v ||
      'ingredients' in v ||
      'steps' in v ||
      'source' in v ||
      'categories' in v);
  const base: RecipeInput = isBaseRecipe(baseOrExtra)
    ? (baseOrExtra as RecipeInput)
    : ({} as RecipeInput);
  const legacyExtra = isBaseRecipe(baseOrExtra)
    ? {}
    : ((baseOrExtra ?? {}) as { description?: string; sourceUrl?: string });
  const extra = { ...legacyExtra, ...(maybeExtra ?? {}) };
  const title = fields.title.trim().slice(0, 60) || 'Pasted draft';
  const ingredients = fields.ingredientsText
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter(Boolean)
    .map((line, position) => ({ name: line, display: line, position }));
  const steps = fields.stepsText
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter(Boolean)
    .map((text, position) => ({ text, position }));
  const baseDescription =
    typeof base.description === 'string' ? base.description : undefined;
  const description = extra.description ?? baseDescription ?? fields.stepsText.trim();
  const servings = base.servings ?? 4;
  const baseSourceUrl =
    typeof base.sourceUrl === 'string' ? base.sourceUrl : undefined;
  const sourceUrl = extra.sourceUrl ?? baseSourceUrl;
  return {
    ...base,
    title,
    description,
    servings,
    ingredients,
    steps,
    ...(sourceUrl ? { sourceUrl } : {}),
  };
}
