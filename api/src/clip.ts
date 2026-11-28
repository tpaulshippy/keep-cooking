// Clip parsers: JSON-LD → reader → caption fallback.
// PII: callers log only { strategy, host, confidence } — never url query
// strings, captions, or parsed content.

export type ClipStrategy = 'jsonld' | 'reader' | 'caption' | 'ocr';

export interface ClipRecipeInput {
  title: string;
  description?: string;
  servings?: number;
  prepMinutes?: number | null;
  cookMinutes?: number | null;
  source?: string;
  sourceUrl?: string;
  categories?: string[];
  ingredients: { name: string; quantity?: number | null; unit?: string; display?: string }[];
  steps: { text: string }[];
}

export interface ClipResult {
  strategy: Exclude<ClipStrategy, 'ocr'>;
  confidence: number;
  warnings: string[];
  sourceUrl?: string;
  recipe: ClipRecipeInput;
}

function text(s: unknown): string {
  return typeof s === 'string' ? s.trim() : '';
}

function asArray<T>(v: T | T[] | undefined): T[] {
  if (v == null) return [];
  return Array.isArray(v) ? v : [v];
}

function stripHtml(html: string): string {
  return html
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&apos;/g, "'")
    .replace(/\s+/g, ' ')
    .trim();
}

function firstTag(html: string, tag: string): string {
  const m = html.match(new RegExp(`<${tag}[^>]*>([\\s\\S]*?)<\\/${tag}>`, 'i'));
  return m ? stripHtml(m[1] ?? '') : '';
}

function allListItems(html: string): string[] {
  const out: string[] = [];
  const re = /<li[^>]*>([\s\S]*?)<\/li>/gi;
  let m: RegExpExecArray | null;
  while ((m = re.exec(html)) !== null) {
    const t = stripHtml(m[1] ?? '');
    if (t) out.push(t);
  }
  return out;
}

/** Extract and normalize a schema.org Recipe node from JSON-LD blobs. */
export function parseJsonLd(html: string, sourceUrl?: string): ClipResult | null {
  const scripts: string[] = [];
  const re = /<script[^>]*type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script>/gi;
  let m: RegExpExecArray | null;
  while ((m = re.exec(html)) !== null) scripts.push(m[1] ?? '');
  for (const raw of scripts) {
    let doc: unknown;
    try {
      doc = JSON.parse(raw);
    } catch {
      continue;
    }
    const nodes: unknown[] = [];
    for (const item of asArray(doc as unknown)) {
      const obj = item as Record<string, unknown>;
      if (obj && typeof obj === 'object' && '@graph' in obj) {
        nodes.push(...asArray(obj['@graph'] as unknown));
      } else nodes.push(item);
    }
    for (const n of nodes) {
      const o = n as Record<string, unknown>;
      if (!o || typeof o !== 'object') continue;
      const t = o['@type'];
      const types = asArray<string>(t as string | string[]);
      if (!types.some((x) => String(x).toLowerCase() === 'recipe')) continue;
      const ingredients = asArray<unknown>(o['recipeIngredient'] as unknown[]).map(text).filter(Boolean);
      const rawSteps = o['recipeInstructions'];
      const steps: { text: string }[] = [];
      for (const s of asArray<unknown>(rawSteps as unknown)) {
        if (typeof s === 'string') {
          if (text(s)) steps.push({ text: text(s) });
        } else if (s && typeof s === 'object') {
          const so = s as Record<string, unknown>;
          const t2 = text(so['text']);
          if (t2) steps.push({ text: t2 });
        }
      }
      const title = text(o['name']);
      if (!title) continue;
      const servings = Number.parseFloat(text((o['recipeYield'] as unknown as string[] | string | undefined) ?? '')) || undefined;
      return {
        strategy: 'jsonld',
        confidence: 0.95,
        warnings: [],
        sourceUrl,
        recipe: {
          title,
          description: text(o['description']) || undefined,
          servings: servings && servings > 0 ? servings : 4,
          source: 'clip',
          sourceUrl,
          ingredients: ingredients.map((name) => ({ name })),
          steps,
        },
      };
    }
  }
  return null;
}

/** Reader fallback: title + list items + paragraphs. */
export function parseReader(html: string, sourceUrl?: string): ClipResult | null {
  const title = firstTag(html, 'h1') || firstTag(html, 'title');
  if (!title) return null;
  const items = allListItems(html);
  const warnings: string[] = [];
  if (items.length === 0) warnings.push('no list items found; ingredients may be incomplete');
  const half = Math.max(1, Math.ceil(items.length / 2));
  return {
    strategy: 'reader',
    confidence: 0.6,
    warnings,
    sourceUrl,
    recipe: {
      title,
      servings: 4,
      source: 'clip',
      sourceUrl,
      ingredients: items.slice(0, half).map((name) => ({ name })),
      steps: items.slice(half).map((t) => ({ text: t })),
    },
  };
}

const QTY_RE = /^(\d+(?:[./]\d+)?(?:\s+\d+\/\d+)?)\s*([a-zA-Z]*)\s+(.+)$/;

/** Caption fallback: first line = title, qty-lines = ingredients, rest = steps. */
export function parseCaption(caption: string, sourceUrl?: string): ClipResult {
  const lines = caption
    .split(/\r?\n/)
    .map((l) => l.trim().replace(/^([-*•]\s+|\d+[.)]\s+)/, '').trim())
    .filter(Boolean);
  const warnings: string[] = [];
  if (lines.length === 0) {
    return {
      strategy: 'caption',
      confidence: 0.2,
      warnings: ['empty caption'],
      sourceUrl,
      recipe: { title: 'Untitled clip', servings: 4, ingredients: [], steps: [] },
    };
  }
  const title = lines[0] ?? 'Untitled clip';
  const ingredients: ClipRecipeInput['ingredients'] = [];
  const steps: { text: string }[] = [];
  for (const line of lines.slice(1)) {
    const qm = line.match(QTY_RE);
    if (qm) {
      const qtyRaw = qm[1]!.trim();
      let qty: number | null = null;
      if (qtyRaw.includes('/')) {
        const parts = qtyRaw.split(/\s+/);
        let total = 0;
        let ok = true;
        for (const p of parts) {
          if (p.includes('/')) {
            const [a, b] = p.split('/').map(Number);
            if (!b) { ok = false; break; }
            total += a! / b!;
          } else total += Number(p);
        }
        qty = ok ? total : null;
      } else qty = Number(qtyRaw);
      ingredients.push({
        name: qm[3]!.trim(),
        quantity: Number.isFinite(qty) ? qty : null,
        unit: qm[2] ?? '',
        display: line,
      });
    } else if (line.length < 140 && /^(add|mix|heat|bake|stir|cook|serve|top|pour|chop|diced|minced)/i.test(line)) {
      steps.push({ text: line });
    } else if (ingredients.length === 0) {
      ingredients.push({ name: line });
    } else {
      steps.push({ text: line });
    }
  }
  if (ingredients.length === 0) warnings.push('no ingredients detected');
  if (steps.length === 0) warnings.push('no steps detected');
  return {
    strategy: 'caption',
    confidence: 0.45,
    warnings,
    sourceUrl,
    recipe: { title, servings: 4, source: 'clip', sourceUrl, ingredients, steps },
  };
}

export interface ClipInput {
  url?: string;
  caption?: string;
  source?: string;
  fetchFn?: typeof fetch;
}

function hostOf(url: string): string {
  try {
    return new URL(url).host;
  } catch {
    return 'invalid-url';
  }
}

/**
 * Clip pipeline: JSON-LD → reader → caption. Logs only strategy + host +
 * confidence (no PII). `fetchFn` is injectable for tests.
 */
export async function clipRecipe(input: ClipInput): Promise<ClipResult & { log: { strategy: string; host?: string; confidence: number } }> {
  const fetchFn = input.fetchFn ?? fetch;
  if (input.url) {
    const host = hostOf(input.url);
    try {
      const ctrl = new AbortController();
      const t = setTimeout(() => ctrl.abort(), 8000);
      let html = '';
      try {
        const res = await fetchFn(input.url, {
          signal: ctrl.signal,
          headers: { 'user-agent': 'KeepCookingClip/0.1 (+https://keepcooking.app)' },
        });
        const ct = res.headers.get('content-type') ?? '';
        if (!res.ok) throw new Error(`http ${res.status}`);
        if (!ct.includes('html') && !ct.includes('json') && !ct.includes('text')) throw new Error(`unsupported content-type ${ct}`);
        html = await res.text();
      } finally {
        clearTimeout(t);
      }
      const jl = parseJsonLd(html, input.url);
      if (jl) {
        console.log(JSON.stringify({ clip: { strategy: 'jsonld', host, confidence: jl.confidence } }));
        return { ...jl, log: { strategy: 'jsonld', host, confidence: jl.confidence } };
      }
      const rd = parseReader(html, input.url);
      if (rd && (rd.recipe.ingredients.length > 0 || rd.recipe.steps.length > 0)) {
        console.log(JSON.stringify({ clip: { strategy: 'reader', host, confidence: rd.confidence } }));
        return { ...rd, log: { strategy: 'reader', host, confidence: rd.confidence } };
      }
      if (input.caption) {
        const cp = parseCaption(input.caption, input.url);
        console.log(JSON.stringify({ clip: { strategy: 'caption', host, confidence: cp.confidence } }));
        return { ...cp, log: { strategy: 'caption', host, confidence: cp.confidence } };
      }
      // No usable reader content and no caption: graceful degradation with
      // warnings (JS/login walls) — never a hallucinated recipe.
      const cp = parseCaption('', input.url);
      console.log(JSON.stringify({ clip: { strategy: 'caption', host, confidence: cp.confidence } }));
      return { ...cp, log: { strategy: 'caption', host, confidence: cp.confidence } };
    } catch {
      if (input.caption) {
        const cp = parseCaption(input.caption, input.url);
        console.log(JSON.stringify({ clip: { strategy: 'caption', host, confidence: cp.confidence, fetchFailed: true } }));
        return { ...cp, log: { strategy: 'caption', host, confidence: cp.confidence } };
      }
      throw Object.assign(new Error('failed to fetch url and no caption provided'), { status: 422 });
    }
  }
  const cp = parseCaption(input.caption ?? '', undefined);
  console.log(JSON.stringify({ clip: { strategy: 'caption', confidence: cp.confidence } }));
  return { ...cp, log: { strategy: 'caption', confidence: cp.confidence } };
}
