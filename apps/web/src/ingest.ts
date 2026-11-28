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
 * ({ title, description, servings, ingredients, steps, sourceUrl? }).
 * Title hint = first non-empty line (max 60 chars, matching Link drafts).
 */
export function parsePastedText(
  caption: string,
  opts?: { sourceUrl?: string },
): RecipeInput {
  const lines = caption
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter(Boolean);
  const title = (lines[0] ?? '').slice(0, 60) || 'Pasted draft';
  const steps =
    lines.length <= 1
      ? lines.map((text, position) => ({ text, position }))
      : lines.slice(1).map((text, position) => ({ text, position }));
  return {
    title,
    description: caption.trim(),
    servings: 4,
    ingredients: [],
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
 * Keeps the Link-tab offline draft shape.
 */
export function previewToRecipeInput(
  fields: { title: string; ingredientsText: string; stepsText: string },
  extra?: { description?: string; sourceUrl?: string },
): RecipeInput {
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
  return {
    title,
    description: extra?.description ?? fields.stepsText.trim(),
    servings: 4,
    ingredients,
    steps,
    ...(extra?.sourceUrl ? { sourceUrl: extra.sourceUrl } : {}),
  };
}
