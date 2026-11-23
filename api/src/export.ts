import type { Recipe, Plan } from './store';

function escHtml(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}
function escIcs(s: string): string {
  return s.replace(/\\/g, '\\\\').replace(/;/g, '\\;').replace(/,/g, '\\,').replace(/\n/g, '\\n');
}

/** Markdown export of a recipe. */
export function recipeToMarkdown(r: Recipe): string {
  const lines: string[] = [`# ${r.title}`, ''];
  if (r.description) lines.push(r.description, '');
  lines.push(`Servings: ${r.servings}`);
  if (r.prepMinutes != null || r.cookMinutes != null) {
    lines.push(`Time: prep ${r.prepMinutes ?? '?'} min · cook ${r.cookMinutes ?? '?'} min`, '');
  }
  lines.push('## Ingredients', '');
  for (const g of r.ingredients) lines.push(`- ${g.display || g.name}`);
  lines.push('', '## Steps', '');
  r.steps
    .slice()
    .sort((a, b) => a.position - b.position)
    .forEach((s, i) => lines.push(`${i + 1}. ${s.text}`));
  lines.push('');
  return lines.join('\n');
}

/** Self-contained Schema.org HTML export of a recipe. */
export function recipeToHtml(r: Recipe): string {
  const jsonLd = {
    '@context': 'https://schema.org',
    '@type': 'Recipe',
    name: r.title,
    description: r.description,
    recipeYield: r.servings,
    prepTime: r.prepMinutes != null ? `PT${r.prepMinutes}M` : undefined,
    cookTime: r.cookMinutes != null ? `PT${r.cookMinutes}M` : undefined,
    recipeIngredient: r.ingredients.map((g) => g.display || g.name),
    recipeInstructions: r.steps
      .slice()
      .sort((a, b) => a.position - b.position)
      .map((s) => ({ '@type': 'HowToStep', text: s.text })),
  };
  const ings = r.ingredients.map((g) => `<li>${escHtml(g.display || g.name)}</li>`).join('');
  const steps = r.steps
    .slice()
    .sort((a, b) => a.position - b.position)
    .map((s) => `<li>${escHtml(s.text)}</li>`)
    .join('');
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escHtml(r.title)}</title><script type="application/ld+json">${JSON.stringify(jsonLd)}</script><style>body{font-family:system-ui,sans-serif;max-width:40rem;margin:2rem auto;padding:0 1rem}</style></head><body><h1>${escHtml(r.title)}</h1>${r.description ? `<p>${escHtml(r.description)}</p>` : ''}<p>Servings: ${escHtml(String(r.servings))}</p><h2>Ingredients</h2><ul>${ings}</ul><h2>Steps</h2><ol>${steps}</ol></body></html>`;
}

/** webcal feed (text/calendar) for meal plans. */
export function plansToIcs(plans: Plan[], lookupTitle: (recipeId: string | null) => string | null): string {
  const stamp = new Date().toISOString().replace(/[-:]/g, '').split('.')[0] + 'Z';
  const events = plans
    .filter((p) => /^\d{4}-\d{2}-\d{2}$/.test(p.date))
    .map((p) => {
      const title = (p.recipeId && lookupTitle(p.recipeId)) || p.note || p.meal;
      const d = p.date.replace(/-/g, '');
      return [
        'BEGIN:VEVENT',
        `UID:${p.id}@smidgen`,
        `DTSTAMP:${stamp}`,
        `DTSTART;VALUE=DATE:${d}`,
        `SUMMARY:${escIcs(`${p.meal}: ${title}`)}`,
        p.note ? `DESCRIPTION:${escIcs(p.note)}` : null,
      ]
        .filter(Boolean)
        .join('\r\n');
    });
  return ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Smidgen//Meal Plans//EN', ...events, 'END:VCALENDAR'].join('\r\n') + '\r\n';
}
