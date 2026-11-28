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
      status.textContent = `${label}: ${secs}s remaining`;
      const tick = window.setInterval(() => {
        const left = Math.max(0, Math.round((end - Date.now()) / 1000));
        status.textContent = left > 0 ? `${label}: ${left}s remaining` : `${label} done.`;
        if (left <= 0) window.clearInterval(tick);
      }, 500);
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
  const current = lists[lists.length - 1];
  const cp = current?.payload as { name?: string; items?: { name: string; quantity?: string; aisle?: string; checked?: boolean }[] } | undefined;
  const rows = sortedRows(cp?.items ?? []);
  shell(`<h1>Shopping lists</h1>
  <form id="newlist"><label>Name <input name="name" required value="Weekly shop" /></label><button type="submit">New list</button></form>
  <h2>Aisle-sorted pantry</h2>
  <form id="addpantry"><label>Item <input name="name" required /></label><label>Qty <input name="quantity" /></label><button type="submit">Add to pantry</button></form>
  <ul>${visible(store.state.pantry).map((pi) => `<li>${esc((pi.payload as { name?: string }).name)} <span class="muted">${esc((pi.payload as { quantity?: string }).quantity ?? '')}</span></li>`).join('') || '<li>Pantry empty.</li>'}</ul>
  <h2>${esc(cp?.name ?? 'No list yet')}</h2>
  <ul>${rows.map(({ it, i }) => shopRowHtml(it, i, esc)).join('') || '<li>No items.</li>'}</ul>`);
  (document.getElementById('newlist') as HTMLFormElement).addEventListener('submit', (e) => {
    e.preventDefault();
    const name = String(new FormData(e.target as HTMLFormElement).get('name'));
    store.upsert('list', '', { name, items: [] });
    render();
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
    for (const en of entries) {
      const off = en.dayOffset ?? 0;
      // Never collapse out-of-week entries onto Sunday: skip visibly.
      if (!Number.isInteger(off) || off < 0 || off > 6) {
        skipped++;
        continue;
      }
      store.upsert('plan', '', {
        date: days[off], meal: en.meal ?? 'dinner', recipeId: en.recipeId ?? null,
        servings: en.servings ?? 4, ...(en.note ? { note: en.note } : {}),
      });
    }
    if (skipped > 0) {
      document.getElementById('menustatus')!.textContent =
        `Applied ${entries.length - skipped} of ${entries.length} entries — ${skipped} outside this week skipped.`;
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
    status().textContent = result.failed
      ? `Pushed ${result.pushed} envelope(s); ${remaining} retained offline — will retry.`
      : result.pushed
        ? `Pushed ${result.pushed} envelope(s).`
        : 'Outbox empty — nothing to push.';
    render();
  });
  document.getElementById('pull')!.addEventListener('click', async () => {
    try {
      const recipes = await api.listRecipes();
      for (const r of recipes) {
        store.applyRemote({ id: r.id, updatedAt: r.updatedAt ?? new Date().toISOString(), deviceId: r.deviceId ?? 'server', entity: 'recipe', payload: r } as SyncEnvelope);
      }
      status().textContent = `Pulled ${recipes.length} recipe(s).`;
      render();
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

initRouter(render);
render();
