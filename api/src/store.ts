import type { Role } from './auth';

// Row + assembled API types. Recipe/List/etc. mirror the openapi.yaml
// SyncEnvelope allOf (id/updatedAt/deviceId/deleted/entity + fields).

export interface Ingredient {
  id: string;
  name: string;
  quantity: number | null;
  unit: string;
  display: string;
  position: number;
  recipeId: string;
}
export interface Step {
  id: string;
  position: number;
  text: string;
  timers: { seconds: number; label: string }[];
  recipeId: string;
}
export interface RecipeRow {
  id: string;
  householdId: string;
  title: string;
  description: string;
  servings: number;
  prepMinutes: number | null;
  cookMinutes: number | null;
  rating: number | null;
  source: string;
  sourceUrl: string;
  categories: string[];
  photoKeys: { original: string; large1024: string; thumb: string };
  updatedAt: string;
  deviceId: string;
  deleted: boolean;
}
export interface Recipe extends RecipeRow {
  entity: 'recipe';
  ingredients: Ingredient[];
  steps: Step[];
}

export interface ListItem {
  id: string;
  name: string;
  quantity: string;
  aisle: string;
  checked: boolean;
  recipeId: string | null;
}
export interface ShoppingList {
  id: string;
  entity: 'list';
  householdId: string;
  name: string;
  items: ListItem[];
  updatedAt: string;
  deviceId: string;
  deleted: boolean;
}
export interface PantryItem {
  id: string;
  entity: 'pantryItem';
  householdId: string;
  name: string;
  quantity: string;
  location: string;
  expiresAt: string | null;
  lowThreshold: string;
  barcode: string;
  updatedAt: string;
  deviceId: string;
  deleted: boolean;
}
export interface Plan {
  id: string;
  entity: 'plan';
  householdId: string;
  date: string;
  meal: string;
  recipeId: string | null;
  note: string;
  servings: number | null;
  updatedAt: string;
  deviceId: string;
  deleted: boolean;
}
export interface Menu {
  id: string;
  entity: 'menu';
  householdId: string;
  name: string;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  entries: any[];
  updatedAt: string;
  deviceId: string;
  deleted: boolean;
}

export interface Membership {
  householdId: string;
  userId: string;
  role: Role;
}
export interface Household {
  id: string;
  name: string;
}
export interface ShareLink {
  id: string;
  householdId: string;
  recipeIds: string[];
  url: string;
  expiresAt: string;
}

export interface SyncEnvelopeWire {
  id: string;
  updatedAt: string;
  deviceId: string;
  deleted: boolean;
  entity: string;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  payload: any;
}

export const nowIso = () => new Date().toISOString();
export const newId = () =>
  typeof crypto !== 'undefined' && 'randomUUID' in crypto
    ? crypto.randomUUID()
    : `id-${Date.now()}-${Math.floor(Math.random() * 1e9)}`;

export interface Store {
  // households / memberships
  ensureHousehold(id: string, name?: string): Promise<Household>;
  getMembership(householdId: string, userId: string): Promise<Membership | null>;
  setMembership(householdId: string, userId: string, role: Role): Promise<void>;
  // recipes
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  listRecipes(householdId?: string): Promise<Recipe[]>;
  getRecipe(id: string): Promise<Recipe | null>;
  getRecipeRow(id: string): Promise<RecipeRow | null>;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  createRecipe(input: any, meta: { deviceId: string; id?: string; updatedAt?: string }): Promise<Recipe>;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  updateRecipe(id: string, input: any, meta: { deviceId: string }): Promise<Recipe | null>;
  deleteRecipe(id: string, deviceId: string): Promise<boolean>;
  // lists
  listLists(): Promise<ShoppingList[]>;
  getList(id: string): Promise<ShoppingList | null>;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  createList(input: any, meta: { deviceId: string; id?: string; updatedAt?: string }): Promise<ShoppingList>;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  updateList(id: string, input: any, meta: { deviceId: string }): Promise<ShoppingList | null>;
  deleteList(id: string, deviceId: string): Promise<boolean>;
  // pantry
  listPantry(): Promise<PantryItem[]>;
  getPantry(id: string): Promise<PantryItem | null>;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  createPantry(input: any, meta: { deviceId: string; id?: string; updatedAt?: string }): Promise<PantryItem>;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  updatePantry(id: string, input: any, meta: { deviceId: string }): Promise<PantryItem | null>;
  deletePantry(id: string, deviceId: string): Promise<boolean>;
  // plans
  listPlans(): Promise<Plan[]>;
  getPlan(id: string): Promise<Plan | null>;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  createPlan(input: any, meta: { deviceId: string; id?: string; updatedAt?: string }): Promise<Plan>;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  updatePlan(id: string, input: any, meta: { deviceId: string }): Promise<Plan | null>;
  deletePlan(id: string, deviceId: string): Promise<boolean>;
  // menus
  listMenus(): Promise<Menu[]>;
  getMenu(id: string): Promise<Menu | null>;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  createMenu(input: any, meta: { deviceId: string; id?: string; updatedAt?: string }): Promise<Menu>;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  updateMenu(id: string, input: any, meta: { deviceId: string }): Promise<Menu | null>;
  deleteMenu(id: string, deviceId: string): Promise<boolean>;
  // child rows (for ingredient/step sync entities)
  upsertIngredient(recipeId: string, ing: Ingredient): Promise<void>;
  upsertStep(recipeId: string, step: Step): Promise<void>;
  softDeleteIngredient(id: string): Promise<void>;
  softDeleteStep(id: string): Promise<void>;
  bumpRecipe(recipeId: string, deviceId: string, updatedAt: string): Promise<void>;
  // share
  createShare(h: { id: string; householdId: string; recipeIds: string[]; url: string; expiresAt: string }): Promise<ShareLink>;
  // sync
  pullSince(since: string): Promise<SyncEnvelopeWire[]>;
  getEnvelopeEntity(entity: string, id: string): Promise<SyncEnvelopeWire | null>;
  applyEnvelopeFull(env: SyncEnvelopeWire): Promise<void>;
}

// ---------- shared assemblers (used by both stores) ----------

export function toRecipeEnvelope(r: Recipe): SyncEnvelopeWire {
  const { ingredients, steps, ...rest } = r;
  return {
    id: r.id,
    updatedAt: r.updatedAt,
    deviceId: r.deviceId,
    deleted: r.deleted,
    entity: 'recipe',
    payload: { ...rest, ingredients, steps },
  };
}
export function toListEnvelope(l: ShoppingList): SyncEnvelopeWire {
  return { id: l.id, updatedAt: l.updatedAt, deviceId: l.deviceId, deleted: l.deleted, entity: 'list', payload: { ...l } };
}
export function toPantryEnvelope(p: PantryItem): SyncEnvelopeWire {
  return { id: p.id, updatedAt: p.updatedAt, deviceId: p.deviceId, deleted: p.deleted, entity: 'pantryItem', payload: { ...p } };
}
export function toPlanEnvelope(p: Plan): SyncEnvelopeWire {
  return { id: p.id, updatedAt: p.updatedAt, deviceId: p.deviceId, deleted: p.deleted, entity: 'plan', payload: { ...p } };
}
export function toMenuEnvelope(m: Menu): SyncEnvelopeWire {
  return { id: m.id, updatedAt: m.updatedAt, deviceId: m.deviceId, deleted: m.deleted, entity: 'menu', payload: { ...m } };
}

// ---------- MemoryStore (tests + wrangler dev without D1 binding) ----------

export class MemoryStore implements Store {
  households = new Map<string, Household>();
  memberships = new Map<string, Membership>(); // hh|user
  recipes = new Map<string, RecipeRow & { ingredients: Ingredient[]; steps: Step[] }>();
  lists = new Map<string, ShoppingList>();
  pantry = new Map<string, PantryItem>();
  plans = new Map<string, Plan>();
  menus = new Map<string, Menu>();
  shares = new Map<string, ShareLink>();

  async ensureHousehold(id: string, name = id): Promise<Household> {
    let h = this.households.get(id);
    if (!h) {
      h = { id, name };
      this.households.set(id, h);
    }
    return h;
  }
  async getMembership(householdId: string, userId: string): Promise<Membership | null> {
    return this.memberships.get(`${householdId}|${userId}`) ?? null;
  }
  async setMembership(householdId: string, userId: string, role: Role): Promise<void> {
    await this.ensureHousehold(householdId);
    this.memberships.set(`${householdId}|${userId}`, { householdId, userId, role });
  }

  private toRecipe(r: RecipeRow & { ingredients: Ingredient[]; steps: Step[] }): Recipe {
    return { ...r, entity: 'recipe' as const };
  }

  async listRecipes(householdId?: string): Promise<Recipe[]> {
    const out: Recipe[] = [];
    for (const r of this.recipes.values()) {
      if (r.deleted) continue;
      if (householdId && r.householdId !== householdId) continue;
      out.push(this.toRecipe(r));
    }
    return out.sort((a, b) => a.title.localeCompare(b.title));
  }
  async getRecipe(id: string): Promise<Recipe | null> {
    const r = this.recipes.get(id);
    if (!r || r.deleted) return null;
    return this.toRecipe(r);
  }
  async getRecipeRow(id: string): Promise<RecipeRow | null> {
    const r = this.recipes.get(id);
    if (!r) return null;
    const { ingredients, steps, ...row } = r;
    void ingredients;
    void steps;
    return row as RecipeRow;
  }
  async createRecipe(input: any, meta: { deviceId: string; id?: string; updatedAt?: string }): Promise<Recipe> {
    const id = meta.id ?? newId();
    const updatedAt = meta.updatedAt ?? nowIso();
    const ings: Ingredient[] = (input.ingredients ?? []).map((g: any, i: number) => ({
      id: newId(),
      name: g.name,
      quantity: g.quantity ?? null,
      unit: g.unit ?? '',
      display: g.display ?? '',
      position: g.position ?? i,
      recipeId: id,
    }));
    const steps: Step[] = (input.steps ?? []).map((s: any, i: number) => ({
      id: newId(),
      position: s.position ?? i,
      text: s.text,
      timers: [],
      recipeId: id,
    }));
    const row = {
      id,
      householdId: input.householdId ?? 'hh-demo',
      title: input.title,
      description: input.description ?? '',
      servings: input.servings ?? 4,
      prepMinutes: input.prepMinutes ?? null,
      cookMinutes: input.cookMinutes ?? null,
      rating: input.rating ?? null,
      source: input.source ?? '',
      sourceUrl: input.sourceUrl ?? '',
      categories: input.categories ?? [],
      photoKeys: {
        original: input.photoKeys?.original ?? '',
        large1024: input.photoKeys?.large1024 ?? '',
        thumb: input.photoKeys?.thumb ?? '',
      },
      updatedAt,
      deviceId: meta.deviceId,
      deleted: false,
      ingredients: ings,
      steps,
    };
    await this.ensureHousehold(row.householdId);
    this.recipes.set(id, row);
    return this.toRecipe(row);
  }
  async updateRecipe(id: string, input: any, meta: { deviceId: string }): Promise<Recipe | null> {
    const cur = this.recipes.get(id);
    if (!cur || cur.deleted) return null;
    const fresh = await this.createRecipe(input, { deviceId: meta.deviceId, id, updatedAt: nowIso() });
    // preserve nothing else; createRecipe overwrote — keep household if input omitted? input always has householdId default.
    void cur;
    return fresh;
  }
  async deleteRecipe(id: string, deviceId: string): Promise<boolean> {
    const r = this.recipes.get(id);
    if (!r || r.deleted) return false;
    r.deleted = true;
    r.updatedAt = nowIso();
    r.deviceId = deviceId;
    return true;
  }

  async listLists(): Promise<ShoppingList[]> {
    return [...this.lists.values()].filter((l) => !l.deleted);
  }
  async getList(id: string): Promise<ShoppingList | null> {
    const l = this.lists.get(id);
    return l && !l.deleted ? l : null;
  }
  async createList(input: any, meta: { deviceId: string; id?: string; updatedAt?: string }): Promise<ShoppingList> {
    const id = meta.id ?? newId();
    const l: ShoppingList = {
      id,
      entity: 'list',
      householdId: input.householdId ?? 'hh-demo',
      name: input.name,
      items: (input.items ?? []).map((it: any) => ({
        id: newId(),
        name: it.name,
        quantity: it.quantity ?? '',
        aisle: it.aisle ?? '',
        checked: it.checked ?? false,
        recipeId: it.recipeId ?? null,
      })),
      updatedAt: meta.updatedAt ?? nowIso(),
      deviceId: meta.deviceId,
      deleted: false,
    };
    await this.ensureHousehold(l.householdId);
    this.lists.set(id, l);
    return l;
  }
  async updateList(id: string, input: any, meta: { deviceId: string }): Promise<ShoppingList | null> {
    const cur = this.lists.get(id);
    if (!cur || cur.deleted) return null;
    const next = await this.createList(input, { deviceId: meta.deviceId, id });
    return next;
  }
  async deleteList(id: string, deviceId: string): Promise<boolean> {
    const l = this.lists.get(id);
    if (!l || l.deleted) return false;
    l.deleted = true;
    l.updatedAt = nowIso();
    l.deviceId = deviceId;
    return true;
  }

  async listPantry(): Promise<PantryItem[]> {
    return [...this.pantry.values()].filter((p) => !p.deleted);
  }
  async getPantry(id: string): Promise<PantryItem | null> {
    const p = this.pantry.get(id);
    return p && !p.deleted ? p : null;
  }
  async createPantry(input: any, meta: { deviceId: string; id?: string; updatedAt?: string }): Promise<PantryItem> {
    const id = meta.id ?? newId();
    const p: PantryItem = {
      id,
      entity: 'pantryItem',
      householdId: input.householdId ?? 'hh-demo',
      name: input.name,
      quantity: input.quantity ?? '',
      location: input.location ?? '',
      expiresAt: input.expiresAt ?? null,
      lowThreshold: input.lowThreshold ?? '',
      barcode: input.barcode ?? '',
      updatedAt: meta.updatedAt ?? nowIso(),
      deviceId: meta.deviceId,
      deleted: false,
    };
    await this.ensureHousehold(p.householdId);
    this.pantry.set(id, p);
    return p;
  }
  async updatePantry(id: string, input: any, meta: { deviceId: string }): Promise<PantryItem | null> {
    const cur = this.pantry.get(id);
    if (!cur || cur.deleted) return null;
    return this.createPantry(input, { deviceId: meta.deviceId, id });
  }
  async deletePantry(id: string, deviceId: string): Promise<boolean> {
    const p = this.pantry.get(id);
    if (!p || p.deleted) return false;
    p.deleted = true;
    p.updatedAt = nowIso();
    p.deviceId = deviceId;
    return true;
  }

  async listPlans(): Promise<Plan[]> {
    return [...this.plans.values()].filter((p) => !p.deleted).sort((a, b) => a.date.localeCompare(b.date));
  }
  async getPlan(id: string): Promise<Plan | null> {
    const p = this.plans.get(id);
    return p && !p.deleted ? p : null;
  }
  async createPlan(input: any, meta: { deviceId: string; id?: string; updatedAt?: string }): Promise<Plan> {
    const id = meta.id ?? newId();
    const p: Plan = {
      id,
      entity: 'plan',
      householdId: input.householdId ?? 'hh-demo',
      date: input.date,
      meal: input.meal,
      recipeId: input.recipeId ?? null,
      note: input.note ?? '',
      servings: input.servings ?? null,
      updatedAt: meta.updatedAt ?? nowIso(),
      deviceId: meta.deviceId,
      deleted: false,
    };
    await this.ensureHousehold(p.householdId);
    this.plans.set(id, p);
    return p;
  }
  async updatePlan(id: string, input: any, meta: { deviceId: string }): Promise<Plan | null> {
    const cur = this.plans.get(id);
    if (!cur || cur.deleted) return null;
    return this.createPlan(input, { deviceId: meta.deviceId, id });
  }
  async deletePlan(id: string, deviceId: string): Promise<boolean> {
    const p = this.plans.get(id);
    if (!p || p.deleted) return false;
    p.deleted = true;
    p.updatedAt = nowIso();
    p.deviceId = deviceId;
    return true;
  }

  async listMenus(): Promise<Menu[]> {
    return [...this.menus.values()].filter((m) => !m.deleted);
  }
  async getMenu(id: string): Promise<Menu | null> {
    const m = this.menus.get(id);
    return m && !m.deleted ? m : null;
  }
  async createMenu(input: any, meta: { deviceId: string; id?: string; updatedAt?: string }): Promise<Menu> {
    const id = meta.id ?? newId();
    const m: Menu = {
      id,
      entity: 'menu',
      householdId: input.householdId ?? 'hh-demo',
      name: input.name,
      entries: input.entries ?? [],
      updatedAt: meta.updatedAt ?? nowIso(),
      deviceId: meta.deviceId,
      deleted: false,
    };
    await this.ensureHousehold(m.householdId);
    this.menus.set(id, m);
    return m;
  }
  async updateMenu(id: string, input: any, meta: { deviceId: string }): Promise<Menu | null> {
    const cur = this.menus.get(id);
    if (!cur || cur.deleted) return null;
    return this.createMenu(input, { deviceId: meta.deviceId, id });
  }
  async deleteMenu(id: string, deviceId: string): Promise<boolean> {
    const m = this.menus.get(id);
    if (!m || m.deleted) return false;
    m.deleted = true;
    m.updatedAt = nowIso();
    m.deviceId = deviceId;
    return true;
  }

  async upsertIngredient(recipeId: string, ing: Ingredient): Promise<void> {
    const r = this.recipes.get(recipeId);
    if (!r) return;
    const i = r.ingredients.findIndex((g) => g.id === ing.id);
    if (i >= 0) r.ingredients[i] = ing;
    else r.ingredients.push(ing);
  }
  async upsertStep(recipeId: string, step: Step): Promise<void> {
    const r = this.recipes.get(recipeId);
    if (!r) return;
    const i = r.steps.findIndex((s) => s.id === step.id);
    if (i >= 0) r.steps[i] = step;
    else r.steps.push(step);
  }
  async softDeleteIngredient(id: string): Promise<void> {
    for (const r of this.recipes.values()) {
      const i = r.ingredients.findIndex((g) => g.id === id);
      if (i >= 0) r.ingredients.splice(i, 1);
    }
  }
  async softDeleteStep(id: string): Promise<void> {
    for (const r of this.recipes.values()) {
      const i = r.steps.findIndex((s) => s.id === id);
      if (i >= 0) r.steps.splice(i, 1);
    }
  }
  async bumpRecipe(recipeId: string, deviceId: string, updatedAt: string): Promise<void> {
    const r = this.recipes.get(recipeId);
    if (r) {
      r.updatedAt = updatedAt;
      r.deviceId = deviceId;
    }
  }

  async createShare(h: { id: string; householdId: string; recipeIds: string[]; url: string; expiresAt: string }): Promise<ShareLink> {
    const s: ShareLink = { ...h };
    this.shares.set(h.id, s);
    return s;
  }

  async pullSince(since: string): Promise<SyncEnvelopeWire[]> {
    const out: SyncEnvelopeWire[] = [];
    for (const r of this.recipes.values()) {
      if (r.updatedAt > since) out.push(toRecipeEnvelope(this.toRecipe(r)));
    }
    for (const l of this.lists.values()) if (l.updatedAt > since) out.push(toListEnvelope(l));
    for (const p of this.pantry.values()) if (p.updatedAt > since) out.push(toPantryEnvelope(p));
    for (const p of this.plans.values()) if (p.updatedAt > since) out.push(toPlanEnvelope(p));
    for (const m of this.menus.values()) if (m.updatedAt > since) out.push(toMenuEnvelope(m));
    return out.sort((a, b) => a.updatedAt.localeCompare(b.updatedAt));
  }

  async getEnvelopeEntity(entity: string, id: string): Promise<SyncEnvelopeWire | null> {
    if (entity === 'recipe') {
      const r = this.recipes.get(id);
      return r ? toRecipeEnvelope(this.toRecipe(r)) : null;
    }
    if (entity === 'list') {
      const l = this.lists.get(id);
      return l ? toListEnvelope(l) : null;
    }
    if (entity === 'pantryItem') {
      const p = this.pantry.get(id);
      return p ? toPantryEnvelope(p) : null;
    }
    if (entity === 'plan') {
      const p = this.plans.get(id);
      return p ? toPlanEnvelope(p) : null;
    }
    if (entity === 'menu') {
      const m = this.menus.get(id);
      return m ? toMenuEnvelope(m) : null;
    }
    return null;
  }

  async applyEnvelopeFull(env: SyncEnvelopeWire): Promise<void> {
    const p: any = env.payload ?? {};
    if (env.entity === 'recipe') {
      const existing = this.recipes.get(env.id);
      const ings: Ingredient[] = (p.ingredients ?? existing?.ingredients ?? []).map((g: any, i: number) => ({
        id: g.id ?? newId(),
        name: g.name ?? '',
        quantity: g.quantity ?? null,
        unit: g.unit ?? '',
        display: g.display ?? '',
        position: g.position ?? i,
        recipeId: env.id,
      }));
      const steps: Step[] = (p.steps ?? existing?.steps ?? []).map((s: any, i: number) => ({
        id: s.id ?? newId(),
        position: s.position ?? i,
        text: s.text ?? '',
        timers: s.timers ?? [],
        recipeId: env.id,
      }));
      this.recipes.set(env.id, {
        id: env.id,
        householdId: p.householdId ?? existing?.householdId ?? 'hh-demo',
        title: p.title ?? existing?.title ?? 'Untitled',
        description: p.description ?? '',
        servings: p.servings ?? 4,
        prepMinutes: p.prepMinutes ?? null,
        cookMinutes: p.cookMinutes ?? null,
        rating: p.rating ?? null,
        source: p.source ?? '',
        sourceUrl: p.sourceUrl ?? '',
        categories: p.categories ?? [],
        photoKeys: p.photoKeys ?? { original: '', large1024: '', thumb: '' },
        updatedAt: env.updatedAt,
        deviceId: env.deviceId,
        deleted: env.deleted,
        ingredients: ings,
        steps,
      });
      return;
    }
    if (env.entity === 'list') {
      this.lists.set(env.id, {
        id: env.id,
        entity: 'list',
        householdId: p.householdId ?? 'hh-demo',
        name: p.name ?? 'List',
        items: (p.items ?? []).map((it: any) => ({
          id: it.id ?? newId(),
          name: it.name ?? '',
          quantity: it.quantity ?? '',
          aisle: it.aisle ?? '',
          checked: it.checked ?? false,
          recipeId: it.recipeId ?? null,
        })),
        updatedAt: env.updatedAt,
        deviceId: env.deviceId,
        deleted: env.deleted,
      });
      return;
    }
    if (env.entity === 'pantryItem') {
      this.pantry.set(env.id, {
        id: env.id, entity: 'pantryItem', householdId: p.householdId ?? 'hh-demo',
        name: p.name ?? '', quantity: p.quantity ?? '', location: p.location ?? '',
        expiresAt: p.expiresAt ?? null, lowThreshold: p.lowThreshold ?? '', barcode: p.barcode ?? '',
        updatedAt: env.updatedAt, deviceId: env.deviceId, deleted: env.deleted,
      });
      return;
    }
    if (env.entity === 'plan') {
      this.plans.set(env.id, {
        id: env.id, entity: 'plan', householdId: p.householdId ?? 'hh-demo',
        date: p.date ?? '2026-01-01', meal: p.meal ?? 'dinner', recipeId: p.recipeId ?? null,
        note: p.note ?? '', servings: p.servings ?? null,
        updatedAt: env.updatedAt, deviceId: env.deviceId, deleted: env.deleted,
      });
      return;
    }
    if (env.entity === 'menu') {
      this.menus.set(env.id, {
        id: env.id, entity: 'menu', householdId: p.householdId ?? 'hh-demo',
        name: p.name ?? 'Menu', entries: p.entries ?? [],
        updatedAt: env.updatedAt, deviceId: env.deviceId, deleted: env.deleted,
      });
    }
  }
}
