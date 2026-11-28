import './styles.css';
import { api, resolveApiBase, setApiBaseOverride, getApiBaseOverride, enrollDevice } from './api';
import type { RecipeInput, ImportFormat } from './api';
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
  root.innerHTML = `<header class="topbar"><a class="brand" href="${href('/')}">Keep Cooking</a><nav aria-label="Primary">${nav}</nav></header><div class="view">${view}</div>`;
}

function esc(s: unknown): string {
  return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
}

function recipeTitle(id: string): string {
  const r = store.state.recipes.find((e) => e.id === id);
  const p = r?.payload as { title?: string } | undefined;
  return p?.title ?? id.slice(0, 8);
}

function render(): void {
  const route = parsePath(location.pathname);
  switch (route.name) {
    case 'recipes': return viewLibrary('');
    case 'recipeDetail': return viewRecipeDetail(route.params.id);
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

function viewRecipeDetail(id: string): void {
  const env = store.state.recipes.find((e) => e.id === id);
  if (!env || env.deleted) {
    shell(`<h1>Not found</h1><p>This recipe is gone. <a href="${href('/recipes')}">Back to Library</a></p>`);
    return;
  }
  const p = env.payload as { title?: string; description?: string; servings?: number; ingredients?: { name: string; quantity?: number; unit?: string; display?: string }[]; steps?: { text: string }[] };
  shell(`<h1>${esc(p.title ?? id)}</h1>
  <p class="muted">Serves ${esc(p.servings ?? 4)} · updated ${esc(env.updatedAt)}</p>
  <p>${esc(p.description ?? '')}</p>
  <h2>Ingredients</h2><ul>${(p.ingredients ?? []).map((i) => `<li>${esc(i.display ?? [i.quantity, i.unit, i.name].filter(Boolean).join(' '))}</li>`).join('')}</ul>
  <h2>Steps</h2><ol>${(p.steps ?? []).map((s) => `<li>${esc(s.text)}</li>`).join('')}</ol>
  <p><a href="${href('/cook/' + id)}">Start cook mode</a> · <a href="${href('/recipes')}">Back</a></p>
  <button id="del" type="button">Delete recipe</button>`);
  document.getElementById('del')!.addEventListener('click', () => {
    store.remove('recipe', id);
    navigate('/recipes');
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
  shell(`<h1>Plan — this week</h1>
  ${days.map((date) => `<section aria-label="Plan for ${date}"><h2>${date}</h2><ul>${meals.map((meal) => {
    const found = plans.filter((pl) => (pl.payload as { date?: string; meal?: string }).date === date && (pl.payload as { meal?: string }).meal === meal);
    return `<li><strong>${meal}</strong>: ${found.map((f) => esc(planLabel(f.payload as { recipeId?: string | null; note?: string }))).join(', ') || '—'} <button type="button" data-date="${date}" data-meal="${meal}">+ Add</button></li>`;
  }).join('')}</ul></section>`).join('')}
  <form id="addplan"><h2>Add plan entry</h2>
  <label>Date <input name="date" type="date" required value="${days[0]}" /></label>
  <label>Meal <select name="meal">${meals.map((m) => `<option>${m}</option>`).join('')}</select></label>
  <label>Recipe <select name="recipeId"><option value="">— none —</option>${recipes.map((r) => `<option value="${r.id}">${esc((r.payload as { title?: string }).title ?? r.id)}</option>`).join('')}</select></label>
  <label>Note <input name="note" placeholder="Optional note" /></label>
  <button type="submit">Save (offline OK)</button></form>
  <form id="weeklist"><h2>Week to shopping list</h2><button type="submit">Aggregate week into list</button></form>`);
  (document.getElementById('addplan') as HTMLFormElement).addEventListener('submit', (e) => {
    e.preventDefault();
    const fd = new FormData(e.target as HTMLFormElement);
    const note = String(fd.get('note') || '').trim();
    store.upsert('plan', '', {
      date: String(fd.get('date')), meal: String(fd.get('meal')),
      recipeId: String(fd.get('recipeId') || '') || null, servings: 4,
      ...(note ? { note } : {}),
    });
    render();
  });
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
function viewLists(): void {
  const lists = visible(store.state.lists);
  if (selectedListId && !lists.some((l) => l.id === selectedListId)) selectedListId = null;
  const current = lists.find((l) => l.id === selectedListId) ?? lists[lists.length - 1];
  if (current) selectedListId = current.id;
  const cp = current?.payload as { name?: string; items?: { name: string; quantity?: string; aisle?: string; checked?: boolean }[] } | undefined;
  const rows = sortedRows(cp?.items ?? []);
  shell(`<h1>Shopping lists</h1>
  <form id="newlist"><label>Name <input name="name" required value="Weekly shop" /></label><button type="submit">New list</button></form>
  <ul>${lists.map((l) => `<li><button type="button" data-list="${l.id}"${l.id === current?.id ? ' aria-current="true"' : ''}>${esc((l.payload as { name?: string }).name ?? l.id)}</button></li>`).join('') || '<li>No lists yet.</li>'}</ul>
  <h2>Aisle-sorted pantry</h2>
  <form id="addpantry"><label>Item <input name="name" required /></label><label>Qty <input name="quantity" /></label><button type="submit">Add to pantry</button></form>
  <ul>${visible(store.state.pantry).map((pi) => `<li>${esc((pi.payload as { name?: string }).name)} <span class="muted">${esc((pi.payload as { quantity?: string }).quantity ?? '')}</span></li>`).join('') || '<li>Pantry empty.</li>'}</ul>
  <h2>${esc(cp?.name ?? 'No list yet')}</h2>
  <ul>${rows.map(({ it, i }) => shopRowHtml(it, i, esc)).join('') || '<li>No items.</li>'}</ul>`);
  (document.getElementById('newlist') as HTMLFormElement).addEventListener('submit', (e) => {
    e.preventDefault();
    const name = String(new FormData(e.target as HTMLFormElement).get('name'));
    const env = store.upsert('list', '', { name, items: [] });
    selectedListId = env.id;
    render();
  });
  document.querySelectorAll<HTMLButtonElement>('[data-list]').forEach((b) => {
    b.addEventListener('click', () => {
      selectedListId = b.dataset.list!;
      render();
    });
  });
  (document.getElementById('addpantry') as HTMLFormElement).addEventListener('submit', (e) => {
    e.preventDefault();
    const fd = new FormData(e.target as HTMLFormElement);
    store.upsert('pantryItem', '', { name: String(fd.get('name')), quantity: String(fd.get('quantity') || '') });
    render();
  });
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
  shell(`<h1>Menus</h1>
  <p id="menustatus" role="status" aria-live="polite"></p>
  <ul>${menus.map((m) => {
    const mp = m.payload as { name?: string; entries?: MenuEntry[] };
    return `<li><strong>${esc(mp.name ?? m.id)}</strong> (${(mp.entries ?? []).length} entries)
    <button type="button" data-apply="${m.id}">Apply to week</button>
    <button type="button" data-tolist="${m.id}">Add week to list</button></li>`;
  }).join('') || '<li>No menus yet.</li>'}</ul>
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

// ---- Import/export parity (Paprika full-parity, offline-capable) ----
type AnyRec = Record<string, unknown>;

const IMPORT_ACCEPT = '.paprikarecipes,.paprikarecipe,.yml,.yaml,.html,.htm,.zip,.xml,.mx2,.mxp,.mz2,.mmf,.mm,.fdx,.fdxz,.txt,.db,.mcb';

function inferImportFormat(name: string): ImportFormat {
  const n = name.toLowerCase();
  if (n.endsWith('.paprikarecipes')) return 'paprika-zip';
  if (n.endsWith('.paprikarecipe')) return 'paprika-recipe';
  if (n.endsWith('.yml') || n.endsWith('.yaml')) return 'yaml';
  if (n.endsWith('.html') || n.endsWith('.htm')) return 'html';
  if (n.endsWith('.mx2')) return 'mx2';
  if (n.endsWith('.mxp')) return 'mxp';
  if (n.endsWith('.mz2')) return 'mz2';
  if (n.endsWith('.mmf') || n.endsWith('.mm')) return 'mmf';
  if (n.endsWith('.fdxz')) return 'fdxz';
  if (n.endsWith('.fdx')) return 'fdx';
  if (n.endsWith('.mcb')) return 'mcb';
  if (n.endsWith('.txt')) return 'recipe-manager-txt';
  if (n.endsWith('.db')) return 'pepperplate-db';
  if (n.endsWith('.xml')) return 'yum-xml';
  if (n.endsWith('.zip')) return 'paprika-zip';
  return 'paprika-json';
}

function bytesToBase64(bytes: Uint8Array): string {
  let s = '';
  const CH = 0x8000;
  for (let i = 0; i < bytes.length; i += CH) {
    s += String.fromCharCode(...bytes.subarray(i, i + CH));
  }
  return btoa(s);
}

interface LocalRecipe {
  title: string;
  description: string;
  servings: number;
  servingsText?: string;
  prepMinutes?: number;
  cookMinutes?: number;
  totalMinutes?: number;
  prepTimeText?: string;
  cookTimeText?: string;
  totalTimeText?: string;
  categories: string[];
  rating: number;
  difficulty?: string;
  notes?: string;
  nutritionText?: string;
  source?: string;
  sourceUrl?: string;
  paprikaUid?: string;
  cookbooks: string[];
  isFavorite?: boolean;
  scaleFactor?: string;
  ingredients: { name: string; quantity?: number; unit?: string; display?: string }[];
  steps: { text: string }[];
  updatedAt: string;
}

function localRecipes(): LocalRecipe[] {
  return visible(store.state.recipes).map((e) => {
    const p = (e.payload ?? {}) as AnyRec;
    const str = (v: unknown, fb = ''): string => (typeof v === 'string' ? v : fb);
    const num = (v: unknown): number | undefined => (typeof v === 'number' && Number.isFinite(v) ? v : undefined);
    const ings = (Array.isArray(p['ingredients']) ? (p['ingredients'] as AnyRec[]) : []).map((i) => ({
      name: str(i['name'] ?? i['display'], 'ingredient'),
      ...(num(i['quantity']) !== undefined ? { quantity: num(i['quantity']) as number } : {}),
      ...(typeof i['unit'] === 'string' ? { unit: i['unit'] as string } : {}),
      ...(typeof i['display'] === 'string' ? { display: i['display'] as string } : {}),
    }));
    const steps = (Array.isArray(p['steps']) ? (p['steps'] as AnyRec[]) : [])
      .map((s) => ({ text: str(s['text']) }))
      .filter((s) => s.text);
    return {
      title: str(p['title'], e.id.slice(0, 8)),
      description: str(p['description']),
      servings: num(p['servings']) ?? 4,
      ...(typeof p['servingsText'] === 'string' ? { servingsText: p['servingsText'] as string } : {}),
      ...(num(p['prepMinutes']) !== undefined ? { prepMinutes: num(p['prepMinutes']) as number } : {}),
      ...(num(p['cookMinutes']) !== undefined ? { cookMinutes: num(p['cookMinutes']) as number } : {}),
      ...(num(p['totalMinutes']) !== undefined ? { totalMinutes: num(p['totalMinutes']) as number } : {}),
      ...(typeof p['prepTimeText'] === 'string' ? { prepTimeText: p['prepTimeText'] as string } : {}),
      ...(typeof p['cookTimeText'] === 'string' ? { cookTimeText: p['cookTimeText'] as string } : {}),
      ...(typeof p['totalTimeText'] === 'string' ? { totalTimeText: p['totalTimeText'] as string } : {}),
      categories: Array.isArray(p['categories']) ? (p['categories'] as unknown[]).filter((c): c is string => typeof c === 'string') : [],
      rating: num(p['rating']) ?? 0,
      ...(typeof p['difficulty'] === 'string' ? { difficulty: p['difficulty'] as string } : {}),
      ...(typeof p['notes'] === 'string' ? { notes: p['notes'] as string } : {}),
      ...(typeof p['nutritionText'] === 'string' ? { nutritionText: p['nutritionText'] as string } : {}),
      ...(typeof p['source'] === 'string' ? { source: p['source'] as string } : {}),
      ...(typeof p['sourceUrl'] === 'string' ? { sourceUrl: p['sourceUrl'] as string } : {}),
      ...(typeof p['paprikaUid'] === 'string' ? { paprikaUid: p['paprikaUid'] as string } : {}),
      cookbooks: Array.isArray(p['cookbooks']) ? (p['cookbooks'] as unknown[]).filter((c): c is string => typeof c === 'string') : [],
      ...(typeof p['isFavorite'] === 'boolean' ? { isFavorite: p['isFavorite'] as boolean } : {}),
      ...(typeof p['scaleFactor'] === 'string' ? { scaleFactor: p['scaleFactor'] as string } : {}),
      ingredients: ings,
      steps,
      updatedAt: e.updatedAt,
    };
  });
}

function paprikaDate(iso: string): string {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? '' : d.toISOString().slice(0, 19).replace('T', ' ');
}

/** Keep Cooking -> Paprika native JSON (§1.4). Photo bytes live server-side, so
 *  the offline fallback omits photo_data (and its filename). */
function toPaprikaJson(r: LocalRecipe): AnyRec {
  const uid = (r.paprikaUid ?? crypto.randomUUID()).toUpperCase();
  const time = (raw: string | undefined, mins: number | undefined): string =>
    raw ?? (mins != null ? `${mins} minutes` : '');
  return {
    uid,
    hash: '',
    name: r.title,
    description: r.description,
    ingredients: r.ingredients.map((i) => (i.display ? `${i.display} ${i.name}` : i.name).trim()).join('\n'),
    directions: r.steps.map((s) => s.text).join('\n'),
    notes: r.notes ?? '',
    categories: r.categories,
    servings: r.servingsText ?? String(r.servings),
    prep_time: time(r.prepTimeText, r.prepMinutes),
    cook_time: time(r.cookTimeText, r.cookMinutes),
    total_time: time(r.totalTimeText, r.totalMinutes),
    difficulty: r.difficulty ?? null,
    rating: r.rating,
    nutritional_info: r.nutritionText ?? '',
    source: r.source ?? '',
    source_url: r.sourceUrl ?? null,
    image_url: null,
    photo: null,
    photo_large: null,
    photo_hash: '',
    photo_data: null,
    photos: [],
    photo_url: null,
    created: paprikaDate(r.updatedAt),
    on_favorites: !!r.isFavorite,
    scale: r.scaleFactor ?? null,
    cookbook: r.cookbooks[0] ?? '',
    in_trash: false,
    deleted: false,
  };
}

/** Keep Cooking -> Paprika YAML keys, emitted as JSON-as-YAML (valid YAML, §2). */
function toPaprikaYaml(r: LocalRecipe): AnyRec {
  const full = toPaprikaJson(r);
  return {
    name: full['name'],
    servings: full['servings'],
    source: full['source'],
    source_url: full['source_url'],
    prep_time: full['prep_time'],
    cook_time: full['cook_time'],
    on_favorites: full['on_favorites'] ? 'yes' : 'no',
    categories: full['categories'],
    nutritional_info: full['nutritional_info'],
    difficulty: full['difficulty'],
    rating: full['rating'],
    notes: full['notes'],
    ingredients: full['ingredients'],
    directions: full['directions'],
  };
}

function exportHtmlLocal(): string {
  const recipes = localRecipes();
  const bodies = recipes.map((r) => {
    const ld = {
      '@context': 'https://schema.org',
      '@type': 'Recipe',
      name: r.title,
      description: r.description,
      recipeYield: String(r.servings),
      recipeIngredient: r.ingredients.map((i) => (i.display ? `${i.display} ${i.name}` : i.name).trim()),
      recipeInstructions: r.steps.map((s) => ({ '@type': 'HowToStep', text: s.text })),
      ...(r.prepMinutes != null ? { prepTime: `PT${r.prepMinutes}M` } : {}),
      ...(r.cookMinutes != null ? { cookTime: `PT${r.cookMinutes}M` } : {}),
      ...(r.sourceUrl ? { url: r.sourceUrl } : {}),
    };
    return `<article itemscope itemtype="https://schema.org/Recipe">
<h2 itemprop="name">${esc(r.title)}</h2>
<script type="application/ld+json">${esc(JSON.stringify(ld))}</script>
<p>${esc(r.description)}</p>
<h3>Ingredients</h3>
<ul>${r.ingredients.map((i) => `<li itemprop="recipeIngredient">${esc((i.display ? `${i.display} ${i.name}` : i.name).trim())}</li>`).join('')}</ul>
<h3>Directions</h3>
<ol>${r.steps.map((s) => `<li itemprop="recipeInstructions">${esc(s.text)}</li>`).join('')}</ol>
</article>`;
  }).join('\n');
  return `<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>Keep Cooking export</title></head><body><h1>Keep Cooking export</h1>\n${bodies}\n</body></html>`;
}

function parseServingsNumber(raw: string): number {
  const m = raw.match(/(\d+\s+\d+\s*\/\s*\d+|\d+\s*\/\s*\d+|\d+(?:\.\d+)?)/);
  if (!m) return 4;
  const t = m[1].replace(/\s+/g, ' ').trim();
  if (t.includes('/')) {
    const parts = t.split(' ');
    const frac = (parts[parts.length - 1] ?? '').split('/');
    const n = Number(frac[0]);
    const d = Number(frac[1]);
    const whole = parts.length > 1 ? Number(parts[0]) : 0;
    if (Number.isFinite(n) && Number.isFinite(d) && d !== 0) return whole + n / d;
    return 4;
  }
  const v = Number.parseFloat(t);
  return Number.isFinite(v) && v > 0 ? v : 4;
}

function parseMinutes(raw: string): number | undefined {
  const s = raw.toLowerCase().trim();
  if (!s) return undefined;
  const colon = s.match(/(\d+)\s*:\s*(\d+)/);
  if (colon) return Number(colon[1]) * 60 + Number(colon[2]);
  let mins = 0;
  let found = false;
  const h = s.match(/(\d+(?:\.\d+)?)\s*h(?:ours?|rs?)?/);
  if (h) {
    mins += Number(h[1]) * 60;
    found = true;
  }
  const m = s.match(/(\d+(?:\.\d+)?)\s*m(?:in(?:utes?)?)?/);
  if (m) {
    mins += Number(m[1]);
    found = true;
  }
  if (found) return Math.round(mins);
  const plain = s.match(/(\d+(?:\.\d+)?)/);
  return plain ? Number(plain[1]) : undefined;
}

/** Paprika native JSON -> Keep Cooking RecipeInput (§1.3). Never drops the
 *  line text: every ingredient keeps display = original line. */
function paprikaToRecipeInput(p: AnyRec, importCookbooks: boolean): RecipeInput {
  const str = (v: unknown): string | undefined => (typeof v === 'string' && v ? v : undefined);
  const servingsRaw = str(p['servings']) ?? '';
  const prepRaw = str(p['prep_time']);
  const cookRaw = str(p['cook_time']);
  const totalRaw = str(p['total_time']);
  const ings = str(p['ingredients']) ?? '';
  const dirs = str(p['directions']) ?? '';
  const steps = dirs
    .split(/\n\s*\n|\r\n\s*\r\n/)
    .flatMap((b) => b.split('\n'))
    .map((t) => t.replace(/^\s*\d+[.)]\s*/, '').trim())
    .filter(Boolean)
    .map((text, i) => ({ text, position: i }));
  const cookbook = str(p['cookbook']);
  const categories = (Array.isArray(p['categories']) ? p['categories'] : []).filter((c): c is string => typeof c === 'string');
  const rating = typeof p['rating'] === 'number' ? p['rating'] : 0;
  const fav = p['on_favorites'];
  return {
    title: str(p['name']) ?? 'Untitled import',
    description: str(p['description']) ?? '',
    servings: servingsRaw ? parseServingsNumber(servingsRaw) : 4,
    ...(servingsRaw ? { servingsText: servingsRaw } : {}),
    ...(prepRaw ? { prepTimeText: prepRaw, ...(parseMinutes(prepRaw) !== undefined ? { prepMinutes: parseMinutes(prepRaw) as number } : {}) } : {}),
    ...(cookRaw ? { cookTimeText: cookRaw, ...(parseMinutes(cookRaw) !== undefined ? { cookMinutes: parseMinutes(cookRaw) as number } : {}) } : {}),
    ...(totalRaw ? { totalTimeText: totalRaw, ...(parseMinutes(totalRaw) !== undefined ? { totalMinutes: parseMinutes(totalRaw) as number } : {}) } : {}),
    rating,
    ...(typeof p['difficulty'] === 'string' && p['difficulty'] ? { difficulty: p['difficulty'] as string } : {}),
    ...(str(p['notes']) ? { notes: str(p['notes']) as string } : {}),
    ...(str(p['nutritional_info']) ? { nutritionText: str(p['nutritional_info']) as string } : {}),
    ...(str(p['source']) ? { source: str(p['source']) as string } : {}),
    ...(str(p['source_url']) ?? (str(p['source'])?.startsWith('http') ? str(p['source']) : undefined)
      ? { sourceUrl: (str(p['source_url']) ?? str(p['source'])) as string }
      : {}),
    ...(typeof p['uid'] === 'string' && p['uid'] ? { paprikaUid: (p['uid'] as string).toUpperCase() } : {}),
    ...(typeof p['scale'] === 'string' && p['scale'] ? { scaleFactor: p['scale'] as string } : {}),
    categories: importCookbooks || !cookbook ? categories : [...categories, cookbook],
    ...(importCookbooks && cookbook ? { cookbooks: [cookbook] } : {}),
    ...(fav === true || fav === 1 || fav === '1' || fav === 'yes' ? { isFavorite: true } : {}),
    ingredients: ings.split('\n').map((l) => l.trim()).filter(Boolean).map((line, i) => ({ name: line, display: line, position: i })),
    steps,
  };
}

function htmlToRecipeInputs(doc: Document, importCookbooks: boolean): { recipes: RecipeInput[]; warnings: string[] } {
  const warnings: string[] = [];
  const recipes: RecipeInput[] = [];
  // Prefer JSON-LD Recipe blocks, fall back to hRecipe, then headings (§3).
  const ldBlocks: AnyRec[] = [];
  for (const el of Array.from(doc.querySelectorAll('script[type="application/ld+json"]'))) {
    try {
      const parsed: unknown = JSON.parse(el.textContent ?? '');
      const items = Array.isArray(parsed) ? parsed : [(parsed ?? {}) as AnyRec];
      for (const it of items) {
        const rec = it as AnyRec;
        const graph = rec['@graph'];
        const pool = Array.isArray(graph) ? (graph as AnyRec[]) : [rec];
        for (const g of pool) {
          const t = g['@type'];
          if (t === 'Recipe' || (Array.isArray(t) && (t as unknown[]).includes('Recipe'))) ldBlocks.push(g);
        }
      }
    } catch {
      warnings.push('Skipped an unreadable JSON-LD block.');
    }
  }
  for (const g of ldBlocks) {
    const str = (v: unknown): string => (typeof v === 'string' ? v : '');
    const ings = (Array.isArray(g['recipeIngredient']) ? (g['recipeIngredient'] as unknown[]) : [])
      .filter((x): x is string => typeof x === 'string');
    const instr = g['recipeInstructions'];
    const steps: string[] = Array.isArray(instr)
      ? (instr as unknown[]).map((s) => (typeof s === 'string' ? s : str((s as AnyRec)['text']))).filter(Boolean)
      : (typeof instr === 'string' ? instr.split('\n').filter(Boolean) : []);
    recipes.push({
      title: str(g['name']) || 'Untitled import',
      description: str(g['description']),
      servings: 4,
      ingredients: ings.map((line, i) => ({ name: line, display: line, position: i })),
      steps: steps.map((text, i) => ({ text, position: i })),
      ...(str(g['url']) ? { sourceUrl: str(g['url']) } : {}),
    });
  }
  if (recipes.length) return { recipes, warnings };
  const hrecipes = Array.from(doc.querySelectorAll('.hrecipe, .h-recipe'));
  for (const h of hrecipes) {
    const title = h.querySelector('.fn')?.textContent?.trim() || doc.querySelector('h1')?.textContent?.trim() || 'Untitled import';
    const ings = Array.from(h.querySelectorAll('.ingredient')).map((e) => e.textContent?.trim() ?? '').filter(Boolean);
    const steps = Array.from(h.querySelectorAll('.instructions')).map((e) => e.textContent?.trim() ?? '').filter(Boolean);
    recipes.push({
      title,
      description: h.querySelector('.summary')?.textContent?.trim() ?? '',
      servings: 4,
      ingredients: ings.map((line, i) => ({ name: line, display: line, position: i })),
      steps: steps.map((text, i) => ({ text, position: i })),
    });
  }
  if (recipes.length) {
    warnings.push('No JSON-LD found; parsed hRecipe markup.');
    return { recipes, warnings };
  }
  // Last resort: first h1 + visible lists under Ingredients/Directions headings.
  const title = doc.querySelector('h1')?.textContent?.trim() || 'Untitled import';
  const collect = (names: string[]): string[] => {
    const out: string[] = [];
    for (const h of Array.from(doc.querySelectorAll('h1,h2,h3'))) {
      if (names.some((n) => (h.textContent ?? '').toLowerCase().includes(n))) {
        let sib = h.nextElementSibling;
        while (sib && !/^h[1-3]$/i.test(sib.tagName)) {
          out.push(...Array.from(sib.querySelectorAll('li')).map((li) => li.textContent?.trim() ?? '').filter(Boolean));
          if (/^(ul|ol)$/i.test(sib.tagName)) break;
          sib = sib.nextElementSibling;
        }
      }
    }
    return out;
  };
  warnings.push('No structured metadata found; parsed visible headings (JSON-LD → hRecipe → headings).');
  void importCookbooks;
  return {
    recipes: [{
      title,
      servings: 4,
      ingredients: collect(['ingredient']).map((line, i) => ({ name: line, display: line, position: i })),
      steps: collect(['direction', 'instruction', 'step', 'method']).map((text, i) => ({ text, position: i })),
    }],
    warnings,
  };
}

async function gunzipIfNeeded(buf: Uint8Array): Promise<Uint8Array> {
  const gzipMagic = buf.length > 2 && buf[0] === 0x1f && buf[1] === 0x8b;
  const DS = (globalThis as AnyRec)['DecompressionStream'] as
    | (new (format: string) => { readable: ReadableStream; writable: WritableStream })
    | undefined;
  if (gzipMagic && typeof DS !== 'undefined') {
    try {
      const ds = new DS('gzip');
      const stream = new Blob([buf as unknown as BlobPart]).stream().pipeThrough(ds);
      const out = await new Response(stream).arrayBuffer();
      return new Uint8Array(out);
    } catch {
      return buf; // fall through to plain-text parse
    }
  }
  return buf;
}

/** Offline fallback for text-based imports (JSON / JSON-as-YAML / plain-text
 *  Paprika JSON / HTML). Binary bundles (ZIP/gzip members, SQLite, XML
 *  third-party formats) need the server. */
async function parseOfflineImport(
  buf: Uint8Array,
  fileName: string,
  importCookbooks: boolean,
): Promise<{ recipes: RecipeInput[]; warnings: string[] }> {
  const lower = fileName.toLowerCase();
  const isZip = buf.length > 2 && buf[0] === 0x50 && buf[1] === 0x4b;
  if (isZip || lower.endsWith('.zip') || lower.endsWith('.paprikarecipes') || lower.endsWith('.mz2') || lower.endsWith('.mcb')) {
    throw new Error('ZIP bundles cannot be read offline — reconnect and retry for server-side import.');
  }
  if (lower.endsWith('.db') || lower.endsWith('.sqlite')) {
    throw new Error('SQLite imports need a server connection — reconnect and retry.');
  }
  if (/\.(xml|mx2|mxp|fdx|fdxz|mmf|mm)$/.test(lower)) {
    throw new Error('This format needs server-side parsing — reconnect and retry.');
  }
  const bytes = await gunzipIfNeeded(buf);
  const text = new TextDecoder().decode(bytes);
  const trimmed = text.trim();
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
    const parsed: unknown = JSON.parse(trimmed);
    const items = Array.isArray(parsed) ? parsed : [parsed];
    const recipes: RecipeInput[] = (items as AnyRec[]).map((it) => {
      if (typeof it['name'] === 'string' || typeof it['ingredients'] === 'string') {
        return paprikaToRecipeInput(it, importCookbooks);
      }
      const rawIngs: unknown[] = Array.isArray(it['ingredients']) ? (it['ingredients'] as unknown[]) : [];
      const rawSteps: unknown[] = Array.isArray(it['steps']) ? (it['steps'] as unknown[]) : [];
      return {
        title: typeof it['title'] === 'string' ? (it['title'] as string) : 'Untitled import',
        servings: typeof it['servings'] === 'number' ? (it['servings'] as number) : 4,
        description: typeof it['description'] === 'string' ? (it['description'] as string) : '',
        ingredients: rawIngs.map((l, i) => {
          const o = l as AnyRec;
          const line = typeof l === 'string' ? l : String(o['display'] ?? o['name'] ?? l);
          return { name: typeof o['name'] === 'string' ? (o['name'] as string) : line, display: line, position: i };
        }),
        steps: rawSteps.map((s, i) => {
          const o = s as AnyRec;
          return { text: typeof s === 'string' ? s : String(o['text'] ?? ''), position: i };
        }),
      };
    });
    return {
      recipes,
      warnings: ['Offline fallback: parsed as JSON (photo binaries and cookbook recreation need the server).'],
    };
  }
  if (/<html|<!doctype/i.test(text.slice(0, 500)) || lower.endsWith('.html') || lower.endsWith('.htm')) {
    if (typeof DOMParser === 'undefined') throw new Error('HTML import needs a browser DOM or a server connection.');
    const doc = new DOMParser().parseFromString(text, 'text/html');
    const { recipes, warnings } = htmlToRecipeInputs(doc, importCookbooks);
    return { recipes, warnings: [...warnings, 'Offline fallback: images resolved from the file are skipped.'] };
  }
  throw new Error('Unrecognized file: expected Paprika/JSON/YAML/HTML text or a server connection for binary bundles.');
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
  <p><button type="button" id="expjson">Export JSON</button> <button type="button" id="expmd">Export Markdown</button> <button type="button" id="exchtml">Export HTML</button> <button type="button" id="exppaprika">Export Paprika (.paprikarecipes)</button> <button type="button" id="expyaml">Export YAML</button></p>
  <p id="exportstatus" role="status" aria-live="polite"></p>
  <h2>Import</h2>
  <form id="importform">
  <label>File <input id="importfile" name="file" type="file" accept="${IMPORT_ACCEPT}" required /></label>
  <label>Format <select id="importformat" name="format">
  <option value="auto">Auto (from extension)</option>
  <option value="paprika-zip">Paprika bulk (.paprikarecipes / .zip)</option>
  <option value="paprika-recipe">Paprika single (.paprikarecipe)</option>
  <option value="paprika-json">Paprika JSON</option>
  <option value="yaml">Paprika YAML (.yml/.yaml)</option>
  <option value="html">HTML export</option>
  <option value="mx2">MasterCook MX2</option>
  <option value="mxp">MasterCook MXP</option>
  <option value="mz2">MasterCook MZ2</option>
  <option value="mmf">MealMaster (.mmf)</option>
  <option value="fdx">Living Cookbook FDX</option>
  <option value="fdxz">Living Cookbook FDXZ</option>
  <option value="pepperplate-zip">Pepperplate ZIP</option>
  <option value="pepperplate-db">Pepperplate DB</option>
  <option value="copymethat-zip">Copy Me That ZIP</option>
  <option value="yum-xml">Yum XML</option>
  <option value="mcb">My CookBook (.mcb)</option>
  <option value="recipe-manager-txt">Recipe Manager TXT</option>
  </select></label>
  <label><input id="importcookbooks" type="checkbox" checked /> Import cookbooks from file</label>
  <label><input id="importdryrun" type="checkbox" /> Dry run (preview only)</label>
  <button type="submit">Import</button></form>
  <p id="importstatus" role="status" aria-live="polite"></p>
  <p class="muted">Accepts .paprikarecipes, .paprikarecipe, .yml/.yaml, .html, .zip, .xml and P1 formats (.mx2, .mxp, .mz2, .mmf, .fdx/.fdxz, Pepperplate, Copy Me That, Yum). Offline: text imports (JSON/YAML/HTML) are parsed locally; binary bundles need a server connection.</p>`);
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
  const bulkExport = async (
    format: 'json' | 'md' | 'html' | 'paprikarecipes' | 'yaml',
    onlineName: string,
    offline: { name: string; text: string; type: string },
  ): Promise<void> => {
    const st = () => document.getElementById('exportstatus')!;
    try {
      const blob = await api.fetchExportBlob(api.exportBulkUrl({ format, all: true }));
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = onlineName;
      a.click();
      setTimeout(() => URL.revokeObjectURL(a.href), 1000);
      st().textContent = `Exported the library via the server (${format}).`;
    } catch {
      download(offline.name, offline.text, offline.type);
      st().textContent = 'Server unreachable — saved an offline-generated fallback instead.';
    }
  };
  document.getElementById('exchtml')!.addEventListener('click', () =>
    void bulkExport('html', 'keep-cooking.html', { name: 'keep-cooking.html', text: exportHtmlLocal(), type: 'text/html' }));
  document.getElementById('exppaprika')!.addEventListener('click', () =>
    void bulkExport('paprikarecipes', 'keep-cooking.paprikarecipes', {
      name: 'keep-cooking.paprikarecipes.json',
      text: JSON.stringify(localRecipes().map(toPaprikaJson), null, 2),
      type: 'application/json',
    }));
  document.getElementById('expyaml')!.addEventListener('click', () =>
    void bulkExport('yaml', 'keep-cooking.yaml', {
      name: 'keep-cooking.yaml',
      text: JSON.stringify(localRecipes().map(toPaprikaYaml), null, 2),
      type: 'text/yaml',
    }));
  (document.getElementById('importform') as HTMLFormElement).addEventListener('submit', (e) => {
    e.preventDefault();
    const statusEl = () => document.getElementById('importstatus')!;
    const file = (document.getElementById('importfile') as HTMLInputElement).files?.[0];
    if (!file) {
      statusEl().textContent = 'Choose a file to import.';
      return;
    }
    const sel = (document.getElementById('importformat') as HTMLSelectElement).value;
    const format: ImportFormat = sel === 'auto' ? inferImportFormat(file.name) : (sel as ImportFormat);
    const importCookbooks = (document.getElementById('importcookbooks') as HTMLInputElement).checked;
    const dryRun = (document.getElementById('importdryrun') as HTMLInputElement).checked;
    statusEl().textContent = `Importing ${file.name} (${format})…`;
    void (async () => {
      const buf = new Uint8Array(await file.arrayBuffer());
      try {
        const report = await api.importReport({ format, payload: bytesToBase64(buf), importCookbooks, dryRun });
        if (!dryRun) {
          const now = new Date().toISOString();
          for (const r of report.imported ?? []) {
            store.applyRemote({
              id: r.id, updatedAt: r.updatedAt ?? now, deviceId: (r.deviceId as string | undefined) ?? 'server',
              entity: 'recipe', payload: r,
            } as SyncEnvelope);
          }
          render();
        }
        const warns = report.warnings?.length ? ` Warnings: ${report.warnings.join('; ')}` : '';
        const preview = dryRun && report.imported?.length
          ? ` Preview: ${report.imported.map((r) => r.title).slice(0, 5).join(', ')}${report.imported.length > 5 ? '…' : ''}.`
          : '';
        const cooks = report.cookbooksCreated?.length ? ` Cookbooks: ${report.cookbooksCreated.join(', ')}.` : '';
        statusEl().textContent = `${dryRun ? 'Dry run — ' : ''}imported ${report.imported?.length ?? 0}, updated ${report.updated ?? 0}.${preview}${cooks}${warns}`;
      } catch (err) {
        // Offline fallback: parse text-based formats locally, save via upsert.
        try {
          const { recipes, warnings } = await parseOfflineImport(buf, file.name, importCookbooks);
          if (!dryRun) {
            for (const input of recipes) store.upsert('recipe', '', { ...input, servings: input.servings ?? 4 });
            render();
          }
          const names = recipes.map((r) => r.title).slice(0, 5).join(', ') + (recipes.length > 5 ? '…' : '');
          const warnStr = warnings.length ? ` Warnings: ${warnings.join('; ')}` : '';
          statusEl().textContent = `${dryRun ? 'Dry run (offline) — ' : 'Saved offline — '}parsed ${recipes.length} recipe(s)${recipes.length ? `: ${names}.` : '.'} Server unreachable (${err instanceof Error ? err.message : err}).${warnStr}`;
        } catch (fallbackErr) {
          statusEl().textContent = `Import failed: ${fallbackErr instanceof Error ? fallbackErr.message : fallbackErr}`;
        }
      }
    })();
  });
}

initRouter(render);
render();
