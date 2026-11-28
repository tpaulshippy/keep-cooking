import './styles.css';
import { api, resolveApiBase, setApiBaseOverride, getApiBaseOverride, enrollDevice } from './api';
import type { RecipeInput } from './api';
import { Store, visible, type SyncEnvelope } from './store';
import { parsePath, href, navigate, initRouter } from './router';
import { scaleQuantity, formatQuantity } from './scale';
import { aggregateWeekToList, collectPlanIngredients, scaleIngredientsForServings } from './aggregate';
import { sortedRows, toggleItemChecked, shopRowHtml } from './lists';
import { pushOutbox, type PushTransport } from './sync';

const store = new Store();
const root = document.getElementById('app')!;

/** Active cook-mode countdown; cleared before starting another timer so two
 *  timers never write to the same #timer element. */
let activeTimer: number | undefined;

/** Selected shopping list; defaults to the most recent list. */
let selectedListId: string | null = null;

/** Plan entry being edited (null = the plan form creates a new entry). */
let editingPlanId: string | null = null;

/** Pantry item being edited (null = the pantry form creates a new item). */
let editingPantryId: string | null = null;

/** Shopping-list item (original index) with its quantity/aisle editor open. */
let editingItemIdx: number | null = null;

// ---- Theme (light/dark/auto, persisted as kc.theme) ----
type ThemePref = 'light' | 'dark' | 'auto';
const THEME_KEY = 'kc.theme';

function getThemePref(): ThemePref {
  try {
    const v = localStorage.getItem(THEME_KEY);
    if (v === 'light' || v === 'dark' || v === 'auto') return v;
  } catch { /* no localStorage (SSR/test): fall through to auto */ }
  return 'auto';
}

/** Apply the preference: explicit light/dark sets data-theme, auto removes
 *  it so the prefers-color-scheme media query in styles.css decides. */
function applyTheme(): void {
  const pref = getThemePref();
  if (pref === 'auto') document.documentElement.removeAttribute('data-theme');
  else document.documentElement.setAttribute('data-theme', pref);
}

function cycleTheme(): void {
  const next: ThemePref = getThemePref() === 'auto' ? 'light' : getThemePref() === 'light' ? 'dark' : 'auto';
  try {
    localStorage.setItem(THEME_KEY, next);
  } catch { /* ignore */ }
  applyTheme();
  render();
}

/** Live transport: every entity maps to its real contract CRUD endpoint. */
const webTransport: PushTransport = {
  update: (entity, id, input) => {
    switch (entity) {
      case 'recipe': return api.updateRecipe(id, input as unknown as RecipeInput);
      case 'list': return api.updateList(id, input as { name: string });
      case 'pantryItem': return api.updatePantryItem(id, input as { name: string });
      case 'plan': return api.updatePlan(id, input as { date: string; meal: string });
      case 'menu': return api.updateMenu(id, input as { name: string });
    }
  },
  create: (entity, input) => {
    switch (entity) {
      case 'recipe': return api.createRecipe(input as unknown as RecipeInput);
      case 'list': return api.createList(input as { name: string });
      case 'pantryItem': return api.createPantryItem(input as { name: string });
      case 'plan': return api.createPlan(input as { date: string; meal: string });
      case 'menu': return api.createMenu(input as { name: string });
    }
  },
  remove: (entity, id) => {
    switch (entity) {
      case 'recipe': return api.deleteRecipe(id);
      case 'list': return api.deleteList(id);
      case 'pantryItem': return api.deletePantryItem(id);
      case 'plan': return api.deletePlan(id);
      case 'menu': return api.deleteMenu(id);
    }
  },
  list: (entity) => {
    switch (entity) {
      case 'recipe': return api.listRecipes();
      case 'list': return api.listLists();
      case 'pantryItem': return api.listPantry();
      case 'plan': return api.listPlans();
      case 'menu': return api.listMenus();
    }
  },
};

const NAV: [string, string][] = [
  ['/', 'Home'],
  ['/recipes', 'Library'],
  ['/plan', 'Plan'],
  ['/lists', 'Shop'],
  ['/menus', 'Menus'],
  ['/ingest', 'Ingest'],
  ['/settings', 'Settings'],
];

function shell(view: string): void {
  const route = parsePath(location.pathname);
  const here = location.pathname;
  const nav = NAV.map(([p, label]) => {
    const active = (p === '/' && route.name === 'home') || href(p) === here;
    return `<a href="${href(p)}"${active ? ' aria-current="page"' : ''}>${label}</a>`;
  }).join('');
  const pref = getThemePref();
  root.innerHTML = `<header class="topbar"><a class="brand" href="${href('/')}">Keep Cooking</a><nav aria-label="Primary">${nav}</nav><button id="themebtn" type="button" aria-label="Color theme (current: ${pref})">Theme: ${pref}</button></header><div class="view">${view}</div>`;
  document.getElementById('themebtn')!.addEventListener('click', cycleTheme);
}

function esc(s: unknown): string {
  return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
}

function recipeTitle(id: string): string {
  const r = store.state.recipes.find((e) => e.id === id);
  const p = r?.payload as { title?: string } | undefined;
  return p?.title ?? id.slice(0, 8);
}

/** Number field helper: blank/invalid -> undefined (field left unset). */
function numVal(v: FormDataEntryValue | null): number | undefined {
  const s = String(v ?? '').trim();
  if (!s) return undefined;
  const n = Number(s);
  return Number.isFinite(n) ? n : undefined;
}

/** Re-read a record's latest payload and upsert a patch (keeps the same id). */
function patchPayload(entity: 'recipe' | 'list' | 'pantryItem' | 'plan' | 'menu', id: string, patch: Record<string, unknown>): void {
  const key = store.collectionKey(entity);
  const env = (store.state[key] as SyncEnvelope[]).find((e) => e.id === id);
  const base = (env?.payload ?? {}) as Record<string, unknown>;
  store.upsert(entity, id, { ...base, ...patch });
}

function render(): void {
  const route = parsePath(location.pathname);
  switch (route.name) {
    case 'recipes': return viewLibrary('');
    case 'recipeNew': return viewRecipeForm(null);
    case 'recipeDetail': return viewRecipeDetail(route.params.id);
    case 'recipeEdit': return viewRecipeForm(route.params.id);
    case 'cook': return viewCook(route.params.id);
    case 'plan': return viewPlan();
    case 'lists': return viewLists();
    case 'menus': return viewMenus();
    case 'ingest': return viewIngest();
    case 'settings': return viewSettings();
    default: return viewHome();
  }
}

// ---- Home ----
function viewHome(): void {
  const recipes = visible(store.state.recipes).slice(0, 5);
  shell(`<h1>Keep Cooking</h1>
  <p>Offline-first recipes, planning, shopping and pantry. Your data lives on this device; sync when online.</p>
  <h2>Recent recipes</h2>
  <ul class="cards">${recipes.map((r) => `<li><a href="${href('/recipes/' + r.id)}">${esc((r.payload as { title?: string }).title ?? r.id)}</a></li>`).join('') || '<li>No recipes yet.</li>'}</ul>
  <p><a href="${href('/ingest')}">Clip a recipe</a> · <a href="${href('/plan')}">Plan the week</a></p>`);
}

// ---- Library ----
function libraryResultsHtml(query: string): string {
  const all = visible(store.state.recipes);
  const q = query.toLowerCase();
  const list = all.filter((r) => {
    const p = r.payload as { title?: string; description?: string };
    return !q || (p.title ?? '').toLowerCase().includes(q) || (p.description ?? '').toLowerCase().includes(q);
  });
  return list.map((r) => {
    const p = r.payload as { title?: string; servings?: number };
    return `<li><a href="${href('/recipes/' + r.id)}">${esc(p.title ?? r.id)}</a> <span class="muted">serves ${esc(p.servings ?? 4)}</span> <a href="${href('/cook/' + r.id)}">Cook</a></li>`;
  }).join('') || '<li>No matches.</li>';
}

function viewLibrary(q: string): void {
  shell(`<h1>Library</h1>
  <p><a href="${href('/recipes/new')}">New recipe</a></p>
  <form id="search" role="search"><label for="q">Search recipes</label>
  <input id="q" name="q" type="search" value="${esc(q)}" placeholder="Search title or description" /></form>
  <ul class="cards" id="results" aria-live="polite">${libraryResultsHtml(q)}</ul>`);
  const form = document.getElementById('search') as HTMLFormElement;
  const input = document.getElementById('q') as HTMLInputElement;
  // Update only the results list so the input keeps focus, value and caret.
  input.addEventListener('input', () => {
    document.getElementById('results')!.innerHTML = libraryResultsHtml(input.value);
  });
  form.addEventListener('submit', (e) => e.preventDefault());
}

interface RecipeFormPayload {
  title?: string; description?: string; servings?: number;
  prepMinutes?: number; cookMinutes?: number; rating?: number;
  isFavorite?: boolean; source?: string; sourceUrl?: string; categories?: string[];
}

// ---- Recipe new/edit (shared form) ----
function viewRecipeForm(editId: string | null): void {
  const existing = editId ? store.state.recipes.find((e) => e.id === editId && !e.deleted) : undefined;
  if (editId && !existing) {
    shell(`<h1>Not found</h1><p>This recipe is gone. <a href="${href('/recipes')}">Back to Library</a></p>`);
    return;
  }
  const p = (existing?.payload ?? {}) as RecipeFormPayload & Record<string, unknown>;
  const cats = Array.isArray(p.categories) ? (p.categories as string[]).join(', ') : '';
  shell(`<h1>${existing ? 'Edit recipe' : 'New recipe'}</h1>
  <form id="recipeform">
  <label>Title <input name="title" required value="${esc(p.title ?? '')}" /></label>
  <label>Description <textarea name="description" rows="3">${esc(p.description ?? '')}</textarea></label>
  <label>Servings <input name="servings" type="number" min="0.25" max="100" step="0.25" value="${esc(p.servings ?? 4)}" /></label>
  <label>Prep minutes <input name="prepMinutes" type="number" min="0" step="1" value="${esc(p.prepMinutes ?? '')}" /></label>
  <label>Cook minutes <input name="cookMinutes" type="number" min="0" step="1" value="${esc(p.cookMinutes ?? '')}" /></label>
  <label>Rating (0–5) <input name="rating" type="number" min="0" max="5" step="0.5" value="${esc(p.rating ?? '')}" /></label>
  <label><input name="isFavorite" type="checkbox"${p.isFavorite ? ' checked' : ''} /> Favorite</label>
  <label>Source <input name="source" value="${esc(p.source ?? '')}" /></label>
  <label>Source URL <input name="sourceUrl" type="url" value="${esc(p.sourceUrl ?? '')}" /></label>
  <label>Categories (comma-separated) <input name="categories" value="${esc(cats)}" /></label>
  <button type="submit">Save (offline OK)</button> <a href="${existing ? href('/recipes/' + existing.id) : href('/recipes')}">Cancel</a></form>`);
  (document.getElementById('recipeform') as HTMLFormElement).addEventListener('submit', (e) => {
    e.preventDefault();
    const fd = new FormData(e.target as HTMLFormElement);
    const title = String(fd.get('title') || '').trim();
    if (!title) return;
    const servings = numVal(fd.get('servings')) ?? 4;
    const rating = numVal(fd.get('rating'));
    const fields: Record<string, unknown> = {
      title,
      description: String(fd.get('description') || ''),
      servings,
      isFavorite: (e.target as HTMLFormElement).querySelector<HTMLInputElement>('input[name="isFavorite"]')!.checked,
      source: String(fd.get('source') || ''),
      sourceUrl: String(fd.get('sourceUrl') || ''),
      categories: String(fd.get('categories') || '').split(',').map((s) => s.trim()).filter(Boolean),
    };
    const prep = numVal(fd.get('prepMinutes'));
    const cook = numVal(fd.get('cookMinutes'));
    if (prep !== undefined) fields.prepMinutes = prep;
    if (cook !== undefined) fields.cookMinutes = cook;
    if (rating !== undefined) fields.rating = Math.min(5, Math.max(0, rating));
    if (existing) {
      patchPayload('recipe', existing.id, fields);
      navigate('/recipes/' + existing.id);
    } else {
      const env = store.upsert('recipe', '', { ...fields, ingredients: [], steps: [] });
      navigate('/recipes/' + env.id);
    }
  });
}

interface RecipeIngredient { name: string; quantity?: number; unit?: string; display?: string; position?: number; }
interface RecipeStep { text: string; position?: number; timers?: { seconds: number; label: string }[]; }

function viewRecipeDetail(id: string): void {
  const env = store.state.recipes.find((e) => e.id === id);
  if (!env || env.deleted) {
    shell(`<h1>Not found</h1><p>This recipe is gone. <a href="${href('/recipes')}">Back to Library</a></p>`);
    return;
  }
  const p = env.payload as {
    title?: string; description?: string; servings?: number;
    prepMinutes?: number; cookMinutes?: number; rating?: number; isFavorite?: boolean;
    source?: string; sourceUrl?: string; categories?: string[];
    ingredients?: RecipeIngredient[]; steps?: RecipeStep[];
  };
  const meta: string[] = [];
  if (p.prepMinutes != null) meta.push(`prep ${esc(p.prepMinutes)} min`);
  if (p.cookMinutes != null) meta.push(`cook ${esc(p.cookMinutes)} min`);
  if (p.rating != null) meta.push(`rating ${esc(p.rating)}/5`);
  if (p.isFavorite) meta.push('★ favorite');
  const ings = [...(p.ingredients ?? [])].sort((a, b) => (a.position ?? 0) - (b.position ?? 0));
  const steps = [...(p.steps ?? [])].sort((a, b) => (a.position ?? 0) - (b.position ?? 0));
  shell(`<h1>${esc(p.title ?? id)}</h1>
  <p class="muted">Serves ${esc(p.servings ?? 4)} · updated ${esc(env.updatedAt)}${meta.length ? ' · ' + meta.join(' · ') : ''}</p>
  ${p.sourceUrl ? `<p>Source: <a href="${esc(p.sourceUrl)}">${esc(p.source || p.sourceUrl)}</a></p>` : p.source ? `<p>Source: ${esc(p.source)}</p>` : ''}
  ${(p.categories ?? []).length ? `<p class="muted">Categories: ${esc((p.categories ?? []).join(', '))}</p>` : ''}
  <p>${esc(p.description ?? '')}</p>
  <h2>Ingredients</h2>
  <ul>${ings.map((ing, i) => `<li>${esc(ing.display ?? [ing.quantity, ing.unit, ing.name].filter((x) => x !== undefined && x !== '').join(' '))}
    <button type="button" data-ing-up="${i}"${i === 0 ? ' disabled' : ''}>↑</button>
    <button type="button" data-ing-down="${i}"${i === ings.length - 1 ? ' disabled' : ''}>↓</button>
    <button type="button" data-ing-del="${i}">Remove</button></li>`).join('') || '<li>No ingredients yet.</li>'}</ul>
  <form id="adding"><h3>Add ingredient</h3>
  <label>Name <input name="name" required /></label>
  <label>Quantity <input name="quantity" type="number" step="any" /></label>
  <label>Unit <input name="unit" /></label>
  <label>Display (optional override) <input name="display" /></label>
  <button type="submit">Add (offline OK)</button></form>
  <h2>Steps</h2>
  <ol>${steps.map((s, i) => `<li><form data-stepform="${i}">
    <label>Text <textarea name="text" rows="2" required>${esc(s.text)}</textarea></label>
    <label>Timer seconds (optional) <input name="seconds" type="number" min="1" step="1" value="${esc(s.timers?.[0]?.seconds ?? '')}" /></label>
    <label>Timer label <input name="label" value="${esc(s.timers?.[0]?.label ?? '')}" placeholder="Timer" /></label>
    <button type="submit">Save step</button>
    <button type="button" data-step-up="${i}"${i === 0 ? ' disabled' : ''}>↑</button>
    <button type="button" data-step-down="${i}"${i === steps.length - 1 ? ' disabled' : ''}>↓</button>
    <button type="button" data-step-del="${i}">Remove</button></form></li>`).join('') || '<li>No steps yet.</li>'}</ol>
  <form id="addstep"><h3>Add step</h3>
  <label>Text <textarea name="text" rows="2" required></textarea></label>
  <label>Timer seconds (optional) <input name="seconds" type="number" min="1" step="1" /></label>
  <label>Timer label <input name="label" placeholder="Timer" /></label>
  <button type="submit">Add step (offline OK)</button></form>
  <p><a href="${href('/cook/' + id)}">Start cook mode</a> · <a href="${href('/recipes/' + id + '/edit')}">Edit details</a> · <a href="${href('/recipes')}">Back</a></p>
  <button id="del" type="button">Delete recipe</button>`);
  const saveIngredients = (next: RecipeIngredient[]) => {
    patchPayload('recipe', id, { ingredients: next.map((ing, i) => ({ ...ing, position: i })) });
    render();
  };
  const saveSteps = (next: RecipeStep[]) => {
    patchPayload('recipe', id, { steps: next.map((s, i) => ({ ...s, position: i })) });
    render();
  };
  document.getElementById('del')!.addEventListener('click', () => {
    store.remove('recipe', id);
    navigate('/recipes');
  });
  document.querySelectorAll<HTMLButtonElement>('[data-ing-del]').forEach((b) => b.addEventListener('click', () => {
    saveIngredients(ings.filter((_, i) => i !== Number(b.dataset.ingDel)));
  }));
  document.querySelectorAll<HTMLButtonElement>('[data-ing-up]').forEach((b) => b.addEventListener('click', () => {
    const i = Number(b.dataset.ingUp);
    if (i <= 0) return;
    const next = [...ings];
    [next[i - 1], next[i]] = [next[i], next[i - 1]];
    saveIngredients(next);
  }));
  document.querySelectorAll<HTMLButtonElement>('[data-ing-down]').forEach((b) => b.addEventListener('click', () => {
    const i = Number(b.dataset.ingDown);
    if (i >= ings.length - 1) return;
    const next = [...ings];
    [next[i + 1], next[i]] = [next[i], next[i + 1]];
    saveIngredients(next);
  }));
  (document.getElementById('adding') as HTMLFormElement).addEventListener('submit', (e) => {
    e.preventDefault();
    const fd = new FormData(e.target as HTMLFormElement);
    const name = String(fd.get('name') || '').trim();
    if (!name) return;
    const q = numVal(fd.get('quantity'));
    saveIngredients([...ings, {
      name,
      ...(q !== undefined ? { quantity: q } : {}),
      unit: String(fd.get('unit') || ''),
      display: String(fd.get('display') || ''),
    }]);
  });
  const readStepForm = (form: HTMLFormElement): RecipeStep | null => {
    const fd = new FormData(form);
    const text = String(fd.get('text') || '').trim();
    if (!text) return null;
    const seconds = numVal(fd.get('seconds'));
    const label = String(fd.get('label') || '').trim() || 'Timer';
    // Optional timer as seconds+label, matching the iOS StepTimer shape
    // ({seconds, label}) produced by StepTimerParser.
    return { text, ...(seconds && seconds > 0 ? { timers: [{ seconds: Math.round(seconds), label }] } : { timers: [] }) };
  };
  document.querySelectorAll<HTMLFormElement>('[data-stepform]').forEach((form) => {
    form.addEventListener('submit', (e) => {
      e.preventDefault();
      const i = Number(form.dataset.stepform);
      const parsed = readStepForm(form);
      if (!parsed) return;
      const next = steps.map((s, j) => (j === i ? parsed : s));
      saveSteps(next);
    });
  });
  document.querySelectorAll<HTMLButtonElement>('[data-step-del]').forEach((b) => b.addEventListener('click', () => {
    saveSteps(steps.filter((_, i) => i !== Number(b.dataset.stepDel)));
  }));
  document.querySelectorAll<HTMLButtonElement>('[data-step-up]').forEach((b) => b.addEventListener('click', () => {
    const i = Number(b.dataset.stepUp);
    if (i <= 0) return;
    const next = [...steps];
    [next[i - 1], next[i]] = [next[i], next[i - 1]];
    saveSteps(next);
  }));
  document.querySelectorAll<HTMLButtonElement>('[data-step-down]').forEach((b) => b.addEventListener('click', () => {
    const i = Number(b.dataset.stepDown);
    if (i >= steps.length - 1) return;
    const next = [...steps];
    [next[i + 1], next[i]] = [next[i], next[i + 1]];
    saveSteps(next);
  }));
  (document.getElementById('addstep') as HTMLFormElement).addEventListener('submit', (e) => {
    e.preventDefault();
    const parsed = readStepForm(e.target as HTMLFormElement);
    if (!parsed) return;
    saveSteps([...steps, parsed]);
  });
}

// ---- Cook mode ----
function viewCook(id: string): void {
  const env = store.state.recipes.find((e) => e.id === id);
  if (!env || env.deleted) {
    shell(`<h1>Not found</h1><p><a href="${href('/recipes')}">Back to Library</a></p>`);
    return;
  }
  const p = env.payload as { title?: string; servings?: number; ingredients?: { name: string; quantity?: number; unit?: string; display?: string }[]; steps?: { text: string; timers?: { seconds: number; label: string }[] }[] };
  const base = p.servings ?? 4;
  shell(`<h1>Cook: ${esc(p.title ?? id)}</h1>
  <form id="scale"><label for="serv">Servings (base ${esc(base)})</label>
  <input id="serv" type="number" min="0.25" max="100" step="0.25" value="${esc(base)}" />
  <button type="submit">Scale</button></form>
  <h2>Ingredients</h2><ul id="ings"></ul>
  <h2>Steps</h2><ol id="steps">${(p.steps ?? []).map((s, i) =>
    `<li><label><input type="checkbox" data-step="${i}" /> <span>${esc(s.text)}</span></label>${(s.timers ?? []).map((t) => ` <button type="button" data-timer="${t.seconds}" data-label="${esc(t.label)}">Start ${esc(t.label)} (${t.seconds}s)</button>`).join('')}</li>`).join('')}</ol>
  <p id="timer" role="status" aria-live="polite"></p>
  <p><a href="${href('/recipes/' + id)}">Recipe detail</a></p>`);
  const renderIngs = (target: number) => {
    document.getElementById('ings')!.innerHTML = (p.ingredients ?? []).map((ing) => {
      const q = scaleQuantity(ing.quantity, base, target);
      const label = ing.quantity != null ? formatQuantity(q, ing.unit ?? '') + ' ' + ing.name : (ing.display ? `${ing.display} ${ing.name}` : ing.name);
      return `<li><label><input type="checkbox" /> <span>${esc(label.trim())}</span></label></li>`;
    }).join('');
  };
  renderIngs(base);
  (document.getElementById('scale') as HTMLFormElement).addEventListener('submit', (e) => {
    e.preventDefault();
    renderIngs(Number((document.getElementById('serv') as HTMLInputElement).value) || base);
  });
  document.querySelectorAll<HTMLButtonElement>('[data-timer]').forEach((btn) => {
    btn.addEventListener('click', () => {
      const secs = Number(btn.dataset.timer);
      const label = btn.dataset.label ?? 'Timer';
      const status = document.getElementById('timer')!;
      const end = Date.now() + secs * 1000;
      if (activeTimer !== undefined) window.clearInterval(activeTimer);
      status.textContent = `${label}: ${secs}s remaining`;
      const tick = window.setInterval(() => {
        const left = Math.max(0, Math.round((end - Date.now()) / 1000));
        status.textContent = left > 0 ? `${label}: ${left}s remaining` : `${label} done.`;
        if (left <= 0) {
          window.clearInterval(tick);
          if (activeTimer === tick) activeTimer = undefined;
        }
      }, 500);
      activeTimer = tick;
    });
  });
}

// ---- Plan ----
// Monday-first week, built from local y/m/d components (no UTC shift).
function weekDates(): string[] {
  const out: string[] = [];
  const d = new Date();
  const day = (d.getDay() + 6) % 7; // Monday-first
  d.setDate(d.getDate() - day);
  const pad = (n: number) => String(n).padStart(2, '0');
  for (let i = 0; i < 7; i++) {
    const t = new Date(d.getFullYear(), d.getMonth(), d.getDate() + i);
    out.push(`${t.getFullYear()}-${pad(t.getMonth() + 1)}-${pad(t.getDate())}`);
  }
  return out;
}

function planLabel(fp: { recipeId?: string | null; note?: string }): string {
  const title = fp.recipeId ? recipeTitle(fp.recipeId) : null;
  if (title && fp.note) return `${title} — ${fp.note}`;
  return title ?? fp.note ?? '—';
}

function viewPlan(): void {
  const plans = visible(store.state.plans);
  const days = weekDates();
  const meals = ['breakfast', 'lunch', 'dinner', 'snack'];
  const recipes = visible(store.state.recipes);
  const editing = editingPlanId ? plans.find((pl) => pl.id === editingPlanId) : undefined;
  if (editingPlanId && !editing) editingPlanId = null;
  const ep = editing?.payload as { date?: string; meal?: string; recipeId?: string | null; note?: string; servings?: number } | undefined;
  shell(`<h1>Plan — this week</h1>
  ${days.map((date) => `<section aria-label="Plan for ${date}"><h2>${date}</h2><ul>${meals.map((meal) => {
    const found = plans.filter((pl) => (pl.payload as { date?: string; meal?: string }).date === date && (pl.payload as { meal?: string }).meal === meal);
    return `<li><strong>${meal}</strong>: ${found.map((f) =>
      `${esc(planLabel(f.payload as { recipeId?: string | null; note?: string }))} <button type="button" data-plan-edit="${f.id}">Edit</button> <button type="button" data-plan-del="${f.id}">Delete</button>`).join(', ') || '—'} <button type="button" data-date="${date}" data-meal="${meal}">+ Add</button></li>`;
  }).join('')}</ul></section>`).join('')}
  <form id="addplan"><h2>${editing ? 'Edit plan entry' : 'Add plan entry'}</h2>
  <label>Date <input name="date" type="date" required value="${esc(ep?.date ?? days[0])}" /></label>
  <label>Meal <select name="meal">${meals.map((m) => `<option${(ep?.meal ?? 'dinner') === m ? ' selected' : ''}>${m}</option>`).join('')}</select></label>
  <label>Recipe <select name="recipeId"><option value="">— none —</option>${recipes.map((r) => `<option value="${r.id}"${ep?.recipeId === r.id ? ' selected' : ''}>${esc((r.payload as { title?: string }).title ?? r.id)}</option>`).join('')}</select></label>
  <label>Servings <input name="servings" type="number" min="0.25" max="100" step="0.25" value="${esc(ep?.servings ?? 4)}" /></label>
  <label>Note <input name="note" placeholder="Optional note" value="${esc(ep?.note ?? '')}" /></label>
  <button type="submit">Save (offline OK)</button>${editing ? ' <button type="button" id="cancelplan">Cancel</button>' : ''}</form>
  <form id="weeklist"><h2>Week to shopping list</h2><button type="submit">Aggregate week into list</button></form>`);
  (document.getElementById('addplan') as HTMLFormElement).addEventListener('submit', (e) => {
    e.preventDefault();
    const fd = new FormData(e.target as HTMLFormElement);
    const note = String(fd.get('note') || '').trim();
    const fields = {
      date: String(fd.get('date')), meal: String(fd.get('meal')),
      recipeId: String(fd.get('recipeId') || '') || null,
      servings: numVal(fd.get('servings')) ?? 4,
      ...(note ? { note } : { note: '' }),
    };
    if (editing) {
      patchPayload('plan', editing.id, fields);
      editingPlanId = null;
    } else {
      store.upsert('plan', '', fields);
    }
    render();
  });
  document.getElementById('cancelplan')?.addEventListener('click', () => {
    editingPlanId = null;
    render();
  });
  document.querySelectorAll<HTMLButtonElement>('[data-plan-edit]').forEach((b) => b.addEventListener('click', () => {
    editingPlanId = b.dataset.planEdit!;
    render();
    document.getElementById('addplan')!.scrollIntoView();
  }));
  document.querySelectorAll<HTMLButtonElement>('[data-plan-del]').forEach((b) => b.addEventListener('click', () => {
    if (editingPlanId === b.dataset.planDel) editingPlanId = null;
    store.remove('plan', b.dataset.planDel!);
    render();
  }));
  document.querySelectorAll<HTMLButtonElement>('[data-date]').forEach((b) => {
    b.addEventListener('click', () => {
      const form = document.getElementById('addplan') as HTMLFormElement;
      (form.elements.namedItem('date') as HTMLInputElement).value = b.dataset.date!;
      (form.elements.namedItem('meal') as HTMLSelectElement).value = b.dataset.meal!;
      form.scrollIntoView();
    });
  });
  (document.getElementById('weeklist') as HTMLFormElement).addEventListener('submit', (e) => {
    e.preventDefault();
    // Only this week's plans, each recipe scaled by its plan servings first.
    const lookup = (recipeId: string) => {
      const r = recipes.find((x) => x.id === recipeId);
      const payload = r?.payload as { servings?: number; ingredients?: { name: string; quantity?: number; unit?: string; display?: string }[] } | undefined;
      return payload ? { servings: payload.servings, ingredients: payload.ingredients } : undefined;
    };
    const weekPlans = plans.map((pl) => ({ ...(pl.payload as { date: string; servings?: number; recipeId?: string | null }) }));
    const items = aggregateWeekToList(collectPlanIngredients(weekPlans, days, lookup));
    store.upsert('list', '', { name: `Week of ${days[0]}`, items });
    navigate('/lists');
  });
}

// ---- Shop / Pantry ----
interface PantryForm { name?: string; quantity?: string; location?: string; expiresAt?: string; lowThreshold?: string; barcode?: string; }

function viewLists(): void {
  const lists = visible(store.state.lists);
  if (selectedListId && !lists.some((l) => l.id === selectedListId)) selectedListId = null;
  const current = lists.find((l) => l.id === selectedListId) ?? lists[lists.length - 1];
  if (current) selectedListId = current.id;
  if (editingItemIdx != null && !(current?.payload as { items?: unknown[] } | undefined)?.items?.[editingItemIdx]) editingItemIdx = null;
  const cp = current?.payload as { name?: string; items?: { name: string; quantity?: string; aisle?: string; checked?: boolean; recipeId?: string | null }[] } | undefined;
  const rows = sortedRows(cp?.items ?? []);
  const recipes = visible(store.state.recipes);
  const pantryItems = visible(store.state.pantry);
  const editingPantry = editingPantryId ? pantryItems.find((pi) => pi.id === editingPantryId) : undefined;
  if (editingPantryId && !editingPantry) editingPantryId = null;
  const pp = (editingPantry?.payload ?? {}) as PantryForm;
  shell(`<h1>Shopping lists</h1>
  <form id="newlist"><label>Name <input name="name" required value="Weekly shop" /></label><button type="submit">New list</button></form>
  <ul>${lists.map((l) => `<li><button type="button" data-list="${l.id}"${l.id === current?.id ? ' aria-current="true"' : ''}>${esc((l.payload as { name?: string }).name ?? l.id)}</button></li>`).join('') || '<li>No lists yet.</li>'}</ul>
  ${current ? `<form id="renamelist"><label>Rename list <input name="name" required value="${esc(cp?.name ?? '')}" /></label>
  <button type="submit">Rename</button> <button type="button" id="dellist">Delete list</button></form>` : ''}
  <h2>Aisle-sorted pantry</h2>
  <form id="addpantry"><h3>${editingPantry ? 'Edit pantry item' : 'Add pantry item'}</h3>
  <label>Item <input name="name" required value="${esc(pp.name ?? '')}" /></label>
  <label>Qty <input name="quantity" value="${esc(pp.quantity ?? '')}" /></label>
  <label>Location <input name="location" value="${esc(pp.location ?? '')}" /></label>
  <label>Expires <input name="expiresAt" type="date" value="${esc(pp.expiresAt ?? '')}" /></label>
  <label>Low threshold <input name="lowThreshold" value="${esc(pp.lowThreshold ?? '')}" /></label>
  <label>Barcode <input name="barcode" value="${esc(pp.barcode ?? '')}" /></label>
  <button type="submit">${editingPantry ? 'Save (offline OK)' : 'Add to pantry'}</button>${editingPantry ? ' <button type="button" id="cancelpantry">Cancel</button>' : ''}</form>
  <ul>${pantryItems.map((pi) => {
    const q = pi.payload as PantryForm;
    return `<li>${esc(q.name)} <span class="muted">${esc(q.quantity ?? '')}${q.location ? ' · ' + esc(q.location) : ''}${q.expiresAt ? ' · exp ' + esc(q.expiresAt) : ''}</span>
    <button type="button" data-pantry-edit="${pi.id}">Edit</button> <button type="button" data-pantry-del="${pi.id}">Delete</button></li>`;
  }).join('') || '<li>Pantry empty.</li>'}</ul>
  <h2>${esc(cp?.name ?? 'No list yet')}</h2>
  ${current ? `<form id="additem"><h3>Add item</h3>
  <label>Name <input name="name" required /></label>
  <label>Quantity <input name="quantity" /></label>
  <label>Aisle <input name="aisle" /></label>
  <label>Recipe link <select name="recipeId"><option value="">— none —</option>${recipes.map((r) => `<option value="${r.id}">${esc((r.payload as { title?: string }).title ?? r.id)}</option>`).join('')}</select></label>
  <button type="submit">Add item (offline OK)</button></form>` : ''}
  <ul>${rows.map(({ it, i }) => {
    if (editingItemIdx === i) {
      return `<li><form data-itemsave="${i}"><label><input type="checkbox" data-item="${i}"${it.checked ? ' checked' : ''} /> <span class="item-name">${esc(it.name)}</span></label>
      <label>Qty <input id="item-q-${i}" value="${esc(it.quantity ?? '')}" /></label>
      <label>Aisle <input id="item-a-${i}" value="${esc(it.aisle ?? '')}" /></label>
      <button type="submit">Save</button> <button type="button" data-itemcancel>Cancel</button></form></li>`;
    }
    // Checkbox row keeps the shared shopRowHtml markup (whole-label
    // line-through styling); per-row Edit/Delete ride alongside it.
    return `${shopRowHtml(it, i, esc).replace(/<\/li>$/, '')} <button type="button" data-itemedit="${i}">Edit</button> <button type="button" data-itemdel="${i}">Delete</button></li>`;
  }).join('') || '<li>No items.</li>'}</ul>`);
  (document.getElementById('newlist') as HTMLFormElement).addEventListener('submit', (e) => {
    e.preventDefault();
    const name = String(new FormData(e.target as HTMLFormElement).get('name'));
    const env = store.upsert('list', '', { name, items: [] });
    selectedListId = env.id;
    editingItemIdx = null;
    render();
  });
  document.querySelectorAll<HTMLButtonElement>('[data-list]').forEach((b) => {
    b.addEventListener('click', () => {
      selectedListId = b.dataset.list!;
      editingItemIdx = null;
      render();
    });
  });
  (document.getElementById('renamelist') as HTMLFormElement | null)?.addEventListener('submit', (e) => {
    e.preventDefault();
    if (!current) return;
    patchPayload('list', current.id, { name: String(new FormData(e.target as HTMLFormElement).get('name')) });
    render();
  });
  document.getElementById('dellist')?.addEventListener('click', () => {
    if (!current) return;
    store.remove('list', current.id);
    selectedListId = null;
    editingItemIdx = null;
    render();
  });
  (document.getElementById('addpantry') as HTMLFormElement).addEventListener('submit', (e) => {
    e.preventDefault();
    const fd = new FormData(e.target as HTMLFormElement);
    const name = String(fd.get('name') || '').trim();
    if (!name) return;
    const fields = {
      name,
      quantity: String(fd.get('quantity') || ''),
      location: String(fd.get('location') || ''),
      expiresAt: String(fd.get('expiresAt') || ''),
      lowThreshold: String(fd.get('lowThreshold') || ''),
      barcode: String(fd.get('barcode') || ''),
    };
    if (editingPantry) {
      patchPayload('pantryItem', editingPantry.id, fields);
      editingPantryId = null;
    } else {
      store.upsert('pantryItem', '', fields);
    }
    render();
  });
  document.getElementById('cancelpantry')?.addEventListener('click', () => {
    editingPantryId = null;
    render();
  });
  document.querySelectorAll<HTMLButtonElement>('[data-pantry-edit]').forEach((b) => b.addEventListener('click', () => {
    editingPantryId = b.dataset.pantryEdit!;
    render();
    document.getElementById('addpantry')!.scrollIntoView();
  }));
  document.querySelectorAll<HTMLButtonElement>('[data-pantry-del]').forEach((b) => b.addEventListener('click', () => {
    if (editingPantryId === b.dataset.pantryDel) editingPantryId = null;
    store.remove('pantryItem', b.dataset.pantryDel!);
    render();
  }));
  (document.getElementById('additem') as HTMLFormElement | null)?.addEventListener('submit', (e) => {
    e.preventDefault();
    if (!current) return;
    const fd = new FormData(e.target as HTMLFormElement);
    const name = String(fd.get('name') || '').trim();
    if (!name) return;
    const recipeId = String(fd.get('recipeId') || '') || null;
    const latest = store.state.lists.find((l) => l.id === current.id);
    const payload = (latest?.payload ?? cp) as { name?: string; items?: { name: string; quantity?: string; aisle?: string; checked?: boolean; recipeId?: string | null }[] };
    const nextItems = [...(payload.items ?? []), {
      name,
      quantity: String(fd.get('quantity') || ''),
      aisle: String(fd.get('aisle') || ''),
      checked: false,
      ...(recipeId ? { recipeId } : {}),
    }];
    store.upsert('list', current.id, { ...(payload as object), items: nextItems });
    render();
  });
  document.querySelectorAll<HTMLButtonElement>('[data-itemedit]').forEach((b) => b.addEventListener('click', () => {
    editingItemIdx = Number(b.dataset.itemedit);
    render();
  }));
  document.querySelectorAll<HTMLButtonElement>('[data-itemcancel]').forEach((b) => b.addEventListener('click', () => {
    editingItemIdx = null;
    render();
  }));
  document.querySelectorAll<HTMLButtonElement>('[data-itemdel]').forEach((b) => b.addEventListener('click', () => {
    if (!current) return;
    const idx = Number(b.dataset.itemdel);
    if (editingItemIdx === idx) editingItemIdx = null;
    const latest = store.state.lists.find((l) => l.id === current.id);
    const payload = (latest?.payload ?? cp) as { name?: string; items?: { name: string }[] };
    const nextItems = (payload.items ?? []).filter((_, j) => j !== idx);
    store.upsert('list', current.id, { ...(payload as object), items: nextItems });
    render();
  }));
  document.querySelectorAll<HTMLFormElement>('[data-itemsave]').forEach((form) => form.addEventListener('submit', (ev) => {
    ev.preventDefault();
    if (!current) return;
    const idx = Number(form.dataset.itemsave);
    const q = (document.getElementById(`item-q-${idx}`) as HTMLInputElement).value;
    const a = (document.getElementById(`item-a-${idx}`) as HTMLInputElement).value;
    const latest = store.state.lists.find((l) => l.id === current.id);
    const payload = (latest?.payload ?? cp) as { name?: string; items?: { quantity?: string; aisle?: string }[] };
    const nextItems = (payload.items ?? []).map((it, j) => (j === idx ? { ...it, quantity: q, aisle: a } : it));
    store.upsert('list', current.id, { ...(payload as object), items: nextItems });
    editingItemIdx = null;
    render();
  }));
  if (current) {
    document.querySelectorAll<HTMLInputElement>('[data-item]').forEach((box) => {
      box.addEventListener('change', () => {
        const idx = Number(box.dataset.item);
        // Re-read the latest payload: a previous toggle in this render may
        // already have stored a newer revision than the `cp` closure holds.
        const latest = store.state.lists.find((l) => l.id === current.id);
        const payload = (latest?.payload ?? cp) as { name?: string; items?: { name: string; quantity?: string; aisle?: string; checked?: boolean }[] };
        const nextItems = toggleItemChecked(payload.items ?? [], idx, box.checked);
        store.upsert('list', current.id, { ...(payload as object), items: nextItems });
        render(); // refresh closures so the next toggle reads fresh state
      });
    });
  }
}

interface MenuEntry { dayOffset?: number; meal?: string; recipeId?: string; servings?: number; note?: string; }

// ---- Menus ----
function viewMenus(): void {
  const menus = visible(store.state.menus);
  const recipes = visible(store.state.recipes);
  const meals = ['breakfast', 'lunch', 'dinner', 'snack'];
  shell(`<h1>Menus</h1>
  <p id="menustatus" role="status" aria-live="polite"></p>
  ${menus.map((m) => {
    const mp = m.payload as { name?: string; entries?: MenuEntry[] };
    const entries = mp.entries ?? [];
    return `<section aria-label="Menu ${esc(mp.name ?? m.id)}">
    <h2>${esc(mp.name ?? m.id)} (${entries.length} entries)</h2>
    <form data-renamemenu="${m.id}"><label>Rename <input name="name" required value="${esc(mp.name ?? '')}" /></label>
    <button type="submit">Rename</button> <button type="button" data-delmenu="${m.id}">Delete menu</button></form>
    <ul>${entries.map((en, i) => `<li>Day ${esc(en.dayOffset ?? 0)} · ${esc(en.meal ?? 'dinner')} · ${esc(en.recipeId ? recipeTitle(en.recipeId) : '—')}${en.servings != null ? ` · serves ${esc(en.servings)}` : ''}${en.note ? ` · ${esc(en.note)}` : ''}
      <button type="button" data-delentry="${m.id}:${i}">Remove</button></li>`).join('') || '<li>No entries yet.</li>'}</ul>
    <form data-addentry="${m.id}"><h3>Add entry</h3>
    <label>Day offset (0–6) <input name="dayOffset" type="number" min="0" max="6" step="1" value="0" /></label>
    <label>Meal <select name="meal">${meals.map((meal) => `<option${meal === 'dinner' ? ' selected' : ''}>${meal}</option>`).join('')}</select></label>
    <label>Recipe <select name="recipeId">${recipes.map((r) => `<option value="${r.id}">${esc((r.payload as { title?: string }).title ?? r.id)}</option>`).join('')}</select></label>
    <label>Servings <input name="servings" type="number" min="0.25" max="100" step="0.25" value="4" /></label>
    <label>Note <input name="note" placeholder="Optional note" /></label>
    <button type="submit">Add entry (offline OK)</button></form>
    <p><button type="button" data-apply="${m.id}">Apply to week</button>
    <button type="button" data-tolist="${m.id}">Add week to list</button></p></section>`;
  }).join('') || '<p>No menus yet.</p>'}
  <form id="newmenu"><h2>New menu</h2><label>Name <input name="name" required /></label>
  <button type="submit">Save</button></form>`);
  (document.getElementById('newmenu') as HTMLFormElement).addEventListener('submit', (e) => {
    e.preventDefault();
    const name = String(new FormData(e.target as HTMLFormElement).get('name'));
    store.upsert('menu', '', {
      name,
      entries: recipes.slice(0, 3).map((r, i) => ({ dayOffset: i, meal: 'dinner', recipeId: r.id, servings: 4 })),
    });
    render();
  });
  document.querySelectorAll<HTMLFormElement>('[data-renamemenu]').forEach((form) => form.addEventListener('submit', (e) => {
    e.preventDefault();
    patchPayload('menu', form.dataset.renamemenu!, { name: String(new FormData(form).get('name')) });
    render();
  }));
  document.querySelectorAll<HTMLButtonElement>('[data-delmenu]').forEach((b) => b.addEventListener('click', () => {
    store.remove('menu', b.dataset.delmenu!);
    render();
  }));
  document.querySelectorAll<HTMLButtonElement>('[data-delentry]').forEach((b) => b.addEventListener('click', () => {
    const [menuId, idxStr] = (b.dataset.delentry ?? '').split(':');
    const m = store.state.menus.find((x) => x.id === menuId);
    if (!m) return;
    const entries = [...((m.payload as { entries?: MenuEntry[] }).entries ?? [])];
    entries.splice(Number(idxStr), 1);
    patchPayload('menu', menuId, { entries });
    render();
  }));
  document.querySelectorAll<HTMLFormElement>('[data-addentry]').forEach((form) => form.addEventListener('submit', (e) => {
    e.preventDefault();
    const menuId = form.dataset.addentry!;
    const fd = new FormData(form);
    const off = numVal(fd.get('dayOffset')) ?? 0;
    const note = String(fd.get('note') || '').trim();
    const m = store.state.menus.find((x) => x.id === menuId);
    if (!m) return;
    const entries = [...((m.payload as { entries?: MenuEntry[] }).entries ?? [])];
    entries.push({
      dayOffset: Math.min(6, Math.max(0, Math.round(off))),
      meal: String(fd.get('meal') || 'dinner'),
      recipeId: String(fd.get('recipeId') || ''),
      servings: numVal(fd.get('servings')) ?? 4,
      ...(note ? { note } : {}),
    });
    patchPayload('menu', menuId, { entries });
    render();
  }));
  const applyMenu = (menuId: string, toList: boolean) => {
    const m = store.state.menus.find((x) => x.id === menuId);
    const mp = m?.payload as { name?: string; entries?: MenuEntry[] };
    const entries = mp?.entries ?? [];
    const days = weekDates();
    if (toList) {
      const ings = entries.flatMap((en) => {
        // This-week entries only, mirroring the apply-to-plan branch.
        const off = en.dayOffset ?? 0;
        if (!Number.isInteger(off) || off < 0 || off > 6) return [];
        const r = recipes.find((x) => x.id === en.recipeId);
        const payload = r?.payload as { servings?: number; ingredients?: { name: string; quantity?: number; unit?: string; display?: string }[] } | undefined;
        if (!payload) return [];
        const recipeServings = payload.servings ?? 4;
        return scaleIngredientsForServings(payload.ingredients ?? [], recipeServings, en.servings ?? recipeServings)
          .map((i) => ({ ...i, recipeId: r?.id }));
      });
      store.upsert('list', '', { name: `${mp?.name ?? 'Menu'} — shopping`, items: aggregateWeekToList(ings) });
      navigate('/lists');
      return;
    }
    let skipped = 0;
    const validMeals = new Set(['breakfast', 'lunch', 'dinner', 'snack']);
    for (const en of entries) {
      const off = en.dayOffset ?? 0;
      // Never collapse out-of-week entries onto Sunday: skip visibly.
      if (!Number.isInteger(off) || off < 0 || off > 6) {
        skipped++;
        continue;
      }
      // Only the plan meal enum is displayable and API-accepted: skip visibly.
      const meal = en.meal ?? 'dinner';
      if (!validMeals.has(meal)) {
        skipped++;
        continue;
      }
      store.upsert('plan', '', {
        date: days[off], meal, recipeId: en.recipeId ?? null,
        servings: en.servings ?? 4, ...(en.note ? { note: en.note } : {}),
      });
    }
    if (skipped > 0) {
      document.getElementById('menustatus')!.textContent =
        `Applied ${entries.length - skipped} of ${entries.length} entries — ${skipped} outside this week or with unknown meal skipped.`;
      return; // stay: the skip count must remain visible
    }
    navigate('/plan');
  };
  document.querySelectorAll<HTMLButtonElement>('[data-apply]').forEach((b) => b.addEventListener('click', () => applyMenu(b.dataset.apply!, false)));
  document.querySelectorAll<HTMLButtonElement>('[data-tolist]').forEach((b) => b.addEventListener('click', () => applyMenu(b.dataset.tolist!, true)));
}

// ---- Ingest ----
function viewIngest(): void {
  shell(`<h1>Clip a recipe</h1>
  <form id="clip"><label>Source URL <input name="url" type="url" placeholder="https://…" /></label>
  <label>Caption or pasted text <textarea name="caption" rows="4"></textarea></label>
  <label>From clipboard <input name="fromclip" type="checkbox" /></label>
  <button type="submit">Clip</button></form>
  <p id="status" role="status" aria-live="polite"></p>
  <p class="muted">Offline: saves as a local draft recipe. Online: also sends to the API clip endpoint.</p>`);
  (document.getElementById('clip') as HTMLFormElement).addEventListener('submit', async (e) => {
    e.preventDefault();
    const fd = new FormData(e.target as HTMLFormElement);
    let url = String(fd.get('url') || '');
    let caption = String(fd.get('caption') || '');
    const status = document.getElementById('status')!;
    if (fd.get('fromclip')) {
      try {
        caption = await navigator.clipboard.readText();
      } catch {
        status.textContent = 'Clipboard unavailable; paste manually.';
        return;
      }
    }
    if (!url && !caption) {
      status.textContent = 'Provide a URL or caption.';
      return;
    }
    const source = url ? 'url' : 'clipboard';
    try {
      const report = await api.clip({ url: url || undefined, caption: caption || undefined, source });
      const env = store.upsert('recipe', '', { ...report.recipe, servings: report.recipe.servings ?? 4 });
      status.textContent = `Clipped via ${report.strategy}.`;
      navigate('/recipes/' + env.id);
    } catch {
      // Offline fallback: local draft.
      const env = store.upsert('recipe', '', {
        title: caption.slice(0, 60) || url || 'Clipped draft',
        description: caption,
        servings: 4,
        ingredients: [],
        steps: caption ? [{ text: caption, position: 0 }] : [],
        sourceUrl: url || undefined,
      });
      status.textContent = 'Saved offline as a draft.';
      navigate('/recipes/' + env.id);
    }
  });
}

// ---- Settings ----
function exportJSON(): string {
  return JSON.stringify(store.state, null, 2);
}

function exportMarkdown(): string {
  const lines = ['# Keep Cooking export', ''];
  for (const r of visible(store.state.recipes)) {
    const p = r.payload as { title?: string; ingredients?: { name: string; display?: string }[]; steps?: { text: string }[] };
    lines.push(`## ${p.title ?? r.id}`, '');
    for (const i of p.ingredients ?? []) lines.push(`- ${i.display ? `${i.display} ` : ''}${i.name}`);
    lines.push('');
    (p.steps ?? []).forEach((s, n) => lines.push(`${n + 1}. ${s.text}`));
    lines.push('');
  }
  return lines.join('\n');
}

function download(name: string, text: string, type: string): void {
  const a = document.createElement('a');
  a.href = URL.createObjectURL(new Blob([text], { type }));
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}

function viewSettings(): void {
  const override = getApiBaseOverride();
  shell(`<h1>Settings</h1>
  <p>API base: <code>${esc(resolveApiBase())}</code> ${override ? '(override)' : '(default)'}</p>
  <form id="apibase"><label>API_BASE_URL override <input name="api" type="url" value="${esc(override ?? '')}" placeholder="${esc(resolveApiBase())}" /></label>
  <button type="submit">Save</button> <button type="button" id="clearapi">Clear</button></form>
  <h2>Sync</h2>
  <p>Outbox: ${store.state.outbox.length} pending envelope(s).</p>
  <p><button type="button" id="enroll">Enroll device</button>
  <button type="button" id="push">Push outbox</button>
  <button type="button" id="pull">Pull recipes</button>
  <button type="button" id="share">Copy share link</button></p>
  <p id="syncstatus" role="status" aria-live="polite"></p>
  <h2>Export</h2>
  <p><button type="button" id="expjson">Export JSON</button> <button type="button" id="expmd">Export Markdown</button></p>`);
  (document.getElementById('apibase') as HTMLFormElement).addEventListener('submit', (e) => {
    e.preventDefault();
    const v = String(new FormData(e.target as HTMLFormElement).get('api') || '').trim();
    setApiBaseOverride(v || null);
    render();
  });
  document.getElementById('clearapi')!.addEventListener('click', () => {
    setApiBaseOverride(null);
    render();
  });
  const status = () => document.getElementById('syncstatus')!;
  document.getElementById('enroll')!.addEventListener('click', async () => {
    try {
      const id = await enrollDevice('web');
      status().textContent = `Enrolled device ${id}.`;
    } catch (err) {
      status().textContent = `Enroll failed (offline?): ${err instanceof Error ? err.message : err}`;
    }
  });
  document.getElementById('push')!.addEventListener('click', async () => {
    const result = await pushOutbox(store, webTransport);
    const remaining = store.state.outbox.length;
    // render() rebuilds the view (and its empty status), so set status after.
    render();
    status().textContent = result.failed
      ? `Pushed ${result.pushed} envelope(s); ${remaining} retained offline — will retry.`
      : result.pushed
        ? `Pushed ${result.pushed} envelope(s).`
        : 'Outbox empty — nothing to push.';
  });
  document.getElementById('pull')!.addEventListener('click', async () => {
    try {
      const [recipes, lists, pantry, plans, menus] = await Promise.all([
        api.listRecipes(), api.listLists(), api.listPantry(), api.listPlans(), api.listMenus(),
      ]);
      const now = new Date().toISOString();
      for (const r of recipes) {
        store.applyRemote({ id: r.id, updatedAt: r.updatedAt ?? now, deviceId: r.deviceId ?? 'server', entity: 'recipe', payload: r } as SyncEnvelope);
      }
      for (const l of lists) {
        store.applyRemote({ id: l.id, updatedAt: l.updatedAt ?? now, deviceId: (l.deviceId as string | undefined) ?? 'server', entity: 'list', payload: l } as SyncEnvelope);
      }
      for (const pi of pantry) {
        store.applyRemote({ id: pi.id, updatedAt: pi.updatedAt ?? now, deviceId: (pi.deviceId as string | undefined) ?? 'server', entity: 'pantryItem', payload: pi } as SyncEnvelope);
      }
      for (const pl of plans) {
        store.applyRemote({ id: pl.id, updatedAt: pl.updatedAt ?? now, deviceId: (pl.deviceId as string | undefined) ?? 'server', entity: 'plan', payload: pl } as SyncEnvelope);
      }
      for (const m of menus) {
        store.applyRemote({ id: m.id, updatedAt: m.updatedAt ?? now, deviceId: (m.deviceId as string | undefined) ?? 'server', entity: 'menu', payload: m } as SyncEnvelope);
      }
      // render() rebuilds the view (and its empty status), so set status after.
      render();
      status().textContent = `Pulled ${recipes.length} recipe(s), ${lists.length} list(s), ${pantry.length} pantry item(s), ${plans.length} plan(s), ${menus.length} menu(s).`;
    } catch (err) {
      status().textContent = `Pull failed (offline?): ${err instanceof Error ? err.message : err}`;
    }
  });
  document.getElementById('share')!.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(location.href.split('#')[0]);
      status().textContent = 'Share link copied.';
    } catch {
      status().textContent = 'Clipboard unavailable.';
    }
  });
  document.getElementById('expjson')!.addEventListener('click', () => download('keep-cooking.json', exportJSON(), 'application/json'));
  document.getElementById('expmd')!.addEventListener('click', () => download('keep-cooking.md', exportMarkdown(), 'text/markdown'));
}

applyTheme();
initRouter(render);
render();
