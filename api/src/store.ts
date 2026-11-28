import type { Role } from './auth';
import type { EncryptedEnvelope } from './e2e';
import type { AgentEnrollment } from './agent';

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

// ---------- Device keys (Ed25519 enrollment) ----------

/** Device identity: Ed25519 public key (32B) + optional revocation timestamp. */
export interface DeviceKey {
  deviceId: string;
  publicKey: Uint8Array;
  revokedAt: string | null;
}

const B64_STD_RE = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{4}|[A-Za-z0-9+/]{3}=|[A-Za-z0-9+/]{2}==)$/;

function httpError(status: number, message: string): Error & { status: number } {
  const err = new Error(message) as Error & { status: number };
  err.status = status;
  return err;
}

/** Strict standard-base64 decode (no url-safe alphabet). Throws 400 on malformed input. */
export function decodePublicKeyB64(b64: string): Uint8Array {
  if (typeof b64 !== 'string' || b64.length === 0 || b64.length % 4 !== 0 || !B64_STD_RE.test(b64)) {
    throw httpError(400, 'publicKey must be standard base64');
  }
  let bin: string;
  const g = globalThis as unknown as { Buffer?: { from(s: string, enc: string): Uint8Array } };
  if (g.Buffer?.from) return new Uint8Array(g.Buffer.from(b64, 'base64'));
  try {
    bin = atob(b64);
  } catch {
    throw httpError(400, 'publicKey must be standard base64');
  }
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i) & 0xff;
  return out;
}

/** Constant-time-ish byte equality (lengths compared first). */
export function deviceKeysEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= (a[i] as number) ^ (b[i] as number);
  return diff === 0;
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

/**
 * E2E LWW comparison on parsed timestamps (never lexical, so mixed ISO-8601
 * shapes order correctly). Incoming wins only when strictly newer — stored
 * wins ties (idempotent). An invalid incoming timestamp never wins; an
 * invalid stored timestamp loses to any valid incoming one. Both invalid:
 * stored wins.
 */
export function e2eIsNewer(incomingUpdatedAt: string, currentUpdatedAt: string): boolean {
  const ni = Date.parse(incomingUpdatedAt);
  if (Number.isNaN(ni)) return false;
  const nc = Date.parse(currentUpdatedAt);
  if (Number.isNaN(nc)) return true;
  return ni > nc;
}

export interface Store {
  // households / memberships
  ensureHousehold(id: string, name?: string): Promise<Household>;
  getMembership(householdId: string, userId: string): Promise<Membership | null>;
  setMembership(householdId: string, userId: string, role: Role): Promise<void>;
  // Membership count for a household (first-claim bootstrap in auth.ts).
  countMemberships(householdId: string): Promise<number>;
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
  // e2e v1 blind blobs (opaque ciphertext; header-only routing server-side)
  e2ePut(hash: string, env: EncryptedEnvelope): Promise<boolean>;
  e2eList(hash: string, since: string): Promise<EncryptedEnvelope[]>;
  e2eWipe(hash: string): Promise<number>;
  // key-only agent auth (#26): enrollment binds an unguessable householdHash
  // to a plaintext householdId label + token verifier (a hash, never a key).
  agentEnroll(e: AgentEnrollment): Promise<AgentEnrollment>;
  agentGetByVerifier(verifier: string): Promise<AgentEnrollment | null>;
  // Plaintext householdId label -> enrollment (the label is non-secret; the
  // hash binding is what a re-bind must prove, see POST /agent/enroll).
  agentGetByLabel(label: string): Promise<AgentEnrollment | null>;
  // Revoke the enrollment for one household hash (label re-bind to a new
  // hash must kill the old token: D1 row gone + memory indexes cleared so
  // the previous token stops authenticating on every isolate). Returns true
  // when an enrollment was removed.
  agentRevokeByHash(householdHash: string): Promise<boolean>;
  // device keys (Ed25519 enroll; no-clobber: same deviceId + different key
  // throws with status 409; identical re-enroll is idempotent)
  getDevice(deviceId: string): Promise<DeviceKey | null>;
  enrollDevice(input: { deviceId: string; publicKeyB64: string; displayName?: string }): Promise<{ deviceId: string; enrolledAt: string }>;
  // Revoke a device key. Sets revokedAt (idempotent: already-revoked keeps
  // its original timestamp); returns null when the device is unknown.
  // authenticateDevice rejects revoked devices with 401 (see auth.ts).
  revokeDevice(deviceId: string): Promise<{ deviceId: string; revokedAt: string } | null>;
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
  devices = new Map<string, { deviceId: string; publicKeyB64: string; publicKey: Uint8Array; displayName: string | null; createdAt: string; revokedAt: string | null }>();

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
  async countMemberships(householdId: string): Promise<number> {
    let n = 0;
    for (const m of this.memberships.values()) if (m.householdId === householdId) n++;
    return n;
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
      id: typeof g.id === 'string' && g.id ? g.id : newId(),
      name: g.name,
      quantity: g.quantity ?? null,
      unit: g.unit ?? '',
      display: g.display ?? '',
      position: g.position ?? i,
      recipeId: id,
    }));
    const steps: Step[] = (input.steps ?? []).map((s: any, i: number) => ({
      id: typeof s.id === 'string' && s.id ? s.id : newId(),
      position: s.position ?? i,
      text: s.text,
      timers: Array.isArray(s.timers)
        ? s.timers
          .filter((t: any) => t && Number.isInteger(t.seconds) && (t.seconds as number) >= 1)
          .map((t: any) => ({ seconds: t.seconds as number, label: typeof t.label === 'string' && t.label ? t.label : 'Timer' }))
          .slice(0, 20)
        : [],
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
        id: typeof it.id === 'string' && it.id ? it.id : newId(),
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

  // ---------- E2E V1 blind blobs (MemoryStore fallback when no D1) ----------
  // Buckets keyed by householdHash; LWW per id on parsed header.updatedAt
  // timestamps (Date.parse — never lexical, so mixed ISO shapes order
  // correctly). Invalid incoming timestamps never win; an invalid stored
  // timestamp loses to any valid incoming one. Server never inspects
  // ciphertext.

  e2eBlobs = new Map<string, Map<string, EncryptedEnvelope>>();

  // ---------- key-only agent enrollments (#26) ----------
  // byHash is authoritative; byVerifier is a secondary index. Re-enrolling
  // a hash replaces the verifier (token rotation without data-key rotation).
  private agentByHash = new Map<string, AgentEnrollment>();
  private agentByVerifier = new Map<string, string>(); // verifier -> householdHash
  private agentByLabel = new Map<string, string>(); // householdId label -> householdHash

  async agentEnroll(e: AgentEnrollment): Promise<AgentEnrollment> {
    // A verifier already bound to a different hash must never be silently
    // re-pointed: D1 rejects the same upsert through its unique verifier
    // index, so memory must reject too (else one token resolves to different
    // households depending on the isolate). Check before mutating anything.
    const clash = this.agentByVerifier.get(e.verifier);
    if (clash && clash !== e.householdHash) {
      const err = new Error('verifier is already bound to a different household hash') as Error & { status?: number };
      err.status = 409;
      throw err;
    }
    const prev = this.agentByHash.get(e.householdHash);
    if (prev && prev.verifier !== e.verifier) this.agentByVerifier.delete(prev.verifier);
    if (prev && prev.householdId !== e.householdId && this.agentByLabel.get(prev.householdId) === e.householdHash) {
      this.agentByLabel.delete(prev.householdId);
    }
    this.agentByHash.set(e.householdHash, e);
    this.agentByVerifier.set(e.verifier, e.householdHash);
    this.agentByLabel.set(e.householdId, e.householdHash);
    return e;
  }

  async agentGetByVerifier(verifier: string): Promise<AgentEnrollment | null> {
    const hash = this.agentByVerifier.get(verifier);
    if (!hash) return null;
    return this.agentByHash.get(hash) ?? null;
  }

  async agentGetByLabel(label: string): Promise<AgentEnrollment | null> {
    const hash = this.agentByLabel.get(label);
    if (!hash) return null;
    return this.agentByHash.get(hash) ?? null;
  }

  async agentRevokeByHash(householdHash: string): Promise<boolean> {
    const prev = this.agentByHash.get(householdHash);
    if (!prev) return false;
    this.agentByHash.delete(householdHash);
    // Clear secondary indexes only when they still point at this hash (a
    // newer enrollment may already have re-pointed them).
    if (this.agentByVerifier.get(prev.verifier) === householdHash) this.agentByVerifier.delete(prev.verifier);
    if (this.agentByLabel.get(prev.householdId) === householdHash) this.agentByLabel.delete(prev.householdId);
    return true;
  }

  async e2ePut(hash: string, env: EncryptedEnvelope): Promise<boolean> {
    let bucket = this.e2eBlobs.get(hash);
    if (!bucket) {
      bucket = new Map();
      this.e2eBlobs.set(hash, bucket);
    }
    const cur = bucket.get(env.id);
    if (cur && !e2eIsNewer(env.updatedAt, cur.updatedAt)) return false; // stored wins ties: idempotent
    bucket.set(env.id, env);
    return true;
  }

  async e2eList(hash: string, since: string): Promise<EncryptedEnvelope[]> {
    const bucket = this.e2eBlobs.get(hash);
    if (!bucket) return [];
    const sinceT = Date.parse(since);
    return [...bucket.values()]
      .filter((e) => {
        const t = Date.parse(e.updatedAt);
        return !Number.isNaN(t) && !Number.isNaN(sinceT) && t > sinceT;
      })
      .sort((a, b) => a.updatedAt.localeCompare(b.updatedAt) || a.id.localeCompare(b.id));
  }

  async e2eWipe(hash: string): Promise<number> {
    const bucket = this.e2eBlobs.get(hash);
    if (!bucket) return 0;
    const n = bucket.size;
    this.e2eBlobs.delete(hash);
    return n;
  }

  async getDevice(deviceId: string): Promise<DeviceKey | null> {
    const d = this.devices.get(deviceId);
    if (!d) return null;
    return { deviceId: d.deviceId, publicKey: d.publicKey.slice(), revokedAt: d.revokedAt };
  }

  async enrollDevice(input: { deviceId: string; publicKeyB64: string; displayName?: string }): Promise<{ deviceId: string; enrolledAt: string }> {
    if (!input.deviceId || typeof input.deviceId !== 'string') throw httpError(400, 'deviceId is required');
    if (input.displayName !== undefined && (typeof input.displayName !== 'string' || input.displayName.length > 64)) {
      throw httpError(400, 'displayName must be a string of at most 64 chars');
    }
    const bytes = decodePublicKeyB64(input.publicKeyB64);
    if (bytes.length !== 32) throw httpError(400, 'publicKey must decode to exactly 32 bytes');
    const existing = this.devices.get(input.deviceId);
    if (existing) {
      if (existing.revokedAt) {
        throw httpError(410, 'device revoked; enroll a fresh deviceId');
      }
      if (!deviceKeysEqual(existing.publicKey, bytes)) {
        throw httpError(409, 'device already enrolled with different key');
      }
      return { deviceId: existing.deviceId, enrolledAt: existing.createdAt };
    }
    const createdAt = nowIso();
    this.devices.set(input.deviceId, {
      deviceId: input.deviceId,
      publicKeyB64: input.publicKeyB64,
      publicKey: bytes,
      displayName: input.displayName ?? null,
      createdAt,
      revokedAt: null,
    });
    return { deviceId: input.deviceId, enrolledAt: createdAt };
  }

  async revokeDevice(deviceId: string): Promise<{ deviceId: string; revokedAt: string } | null> {
    const d = this.devices.get(deviceId);
    if (!d) return null;
    const revokedAt = d.revokedAt ?? nowIso();
    d.revokedAt = revokedAt;
    return { deviceId: d.deviceId, revokedAt };
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
