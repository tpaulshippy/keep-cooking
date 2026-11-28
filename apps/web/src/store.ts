// localStorage persistence: recipes, plans, menus, lists, pantry.
// Outbox queue of SyncEnvelopes; LWW merge + tombstones.
// Matches the native SyncEngine semantics: last-writer-wins on updatedAt,
// ties broken by stored-wins (lexicographic id), deleted tombstones win.

export type EntityKind = 'recipe' | 'list' | 'pantryItem' | 'plan' | 'menu';

export interface SyncEnvelope<T = unknown> {
  id: string;
  updatedAt: string; // ISO
  deviceId: string;
  deleted?: boolean;
  entity: EntityKind;
  payload: T;
}

export type CollectionKey = 'recipes' | 'plans' | 'menus' | 'lists' | 'pantry';

const LS_PREFIX = 'kc.';
const OUTBOX_KEY = `${LS_PREFIX}outbox`;

export interface StoreState {
  recipes: SyncEnvelope[];
  plans: SyncEnvelope[];
  menus: SyncEnvelope[];
  lists: SyncEnvelope[];
  pantry: SyncEnvelope[];
  outbox: SyncEnvelope[];
}

function load<T>(key: string, fallback: T): T {
  try {
    const raw = localStorage.getItem(LS_PREFIX + key);
    if (!raw) return fallback;
    return JSON.parse(raw) as T;
  } catch {
    return fallback;
  }
}

function save(key: string, value: unknown): void {
  try {
    localStorage.setItem(LS_PREFIX + key, JSON.stringify(value));
  } catch { /* quota/privacy: keep in-memory only */ }
}

export function deviceId(): string {
  let id: string | null = null;
  try {
    id = localStorage.getItem('kc.deviceId');
  } catch { /* ignore */ }
  if (!id) {
    id = crypto.randomUUID();
    try {
      localStorage.setItem('kc.deviceId', id);
    } catch { /* ignore */ }
  }
  return id;
}

/** LWW: incoming wins if newer; equal timestamps keep the stored record. */
export function lwwMerge<T>(stored: SyncEnvelope<T> | undefined, incoming: SyncEnvelope<T>): SyncEnvelope<T> {
  if (!stored) return incoming;
  const s = Date.parse(stored.updatedAt);
  const n = Date.parse(incoming.updatedAt);
  if (n > s) return incoming;
  return stored; // stale or tie: stored wins (idempotent replay safe)
}

export function mergeInto<T>(collection: SyncEnvelope<T>[], incoming: SyncEnvelope<T>): SyncEnvelope<T>[] {
  const idx = collection.findIndex((e) => e.id === incoming.id);
  if (idx === -1) return [...collection, incoming];
  const winner = lwwMerge(collection[idx], incoming);
  const next = [...collection];
  next[idx] = winner;
  return next;
}

/** Visible records (tombstones filtered). */
export function visible<T>(collection: SyncEnvelope<T>[]): SyncEnvelope<T>[] {
  return collection.filter((e) => !e.deleted);
}

function seedRecipes(now: string, dev: string): SyncEnvelope[] {
  const mk = (id: string, title: string, description: string, servings: number,
    ingredients: { name: string; quantity?: number; unit?: string; display?: string }[],
    steps: string[]): SyncEnvelope => ({
    id,
    updatedAt: now,
    deviceId: dev,
    entity: 'recipe',
    payload: { id, title, description, servings, ingredients, steps: steps.map((text, i) => ({ text, position: i })) },
  });
  return [
    mk('demo-pasta', 'Weeknight Pasta', 'Pantry pasta with garlic and olive oil.', 4,
      [
        { name: 'Spaghetti', quantity: 12, unit: 'oz', display: '12 oz' },
        { name: 'Garlic', quantity: 4, unit: 'cloves', display: '4 cloves' },
        { name: 'Olive oil', quantity: 0.25, unit: 'cup', display: '1/4 cup' },
      ],
      ['Boil salted water; cook pasta until al dente.', 'Sizzle garlic in olive oil 2 minutes.', 'Toss pasta with oil and a splash of pasta water.']),
    mk('demo-tacos', 'Sheet-Pan Tacos', 'Crispy oven tacos for busy nights.', 4,
      [
        { name: 'Corn tortillas', quantity: 12, unit: '', display: '12' },
        { name: 'Black beans', quantity: 2, unit: 'cans', display: '2 cans' },
        { name: 'Cheddar', quantity: 2, unit: 'cups', display: '2 cups' },
      ],
      ['Heat oven to 425F.', 'Fill tortillas, bake 10 minutes until crisp.', 'Top with salsa and lime.']),
    mk('demo-soup', 'Lentil Soup', 'One-pot red lentil soup.', 6,
      [
        { name: 'Red lentils', quantity: 2, unit: 'cups', display: '2 cups' },
        { name: 'Onion', quantity: 1, unit: '', display: '1' },
        { name: 'Carrots', quantity: 2, unit: '', display: '2' },
      ],
      ['Soften onion and carrots 8 minutes.', 'Add lentils and 6 cups water; simmer 25 minutes.', 'Season with salt and lemon.']),
  ];
}

export class Store {
  state: StoreState;

  constructor() {
    const now = new Date().toISOString();
    const dev = deviceId();
    const recipes = load<SyncEnvelope[]>('recipes', []);
    this.state = {
      recipes: recipes.length ? recipes : seedRecipes(now, dev),
      plans: load<SyncEnvelope[]>('plans', []),
      menus: load<SyncEnvelope[]>('menus', []),
      lists: load<SyncEnvelope[]>('lists', []),
      pantry: load<SyncEnvelope[]>('pantry', []),
      outbox: load<SyncEnvelope[]>('outbox', []),
    };
    if (!recipes.length) save('recipes', this.state.recipes);
  }

  private persist(): void {
    save('recipes', this.state.recipes);
    save('plans', this.state.plans);
    save('menus', this.state.menus);
    save('lists', this.state.lists);
    save('pantry', this.state.pantry);
    save('outbox', this.state.outbox);
  }

  collectionKey(entity: EntityKind): CollectionKey {
    switch (entity) {
      case 'recipe': return 'recipes';
      case 'plan': return 'plans';
      case 'menu': return 'menus';
      case 'list': return 'lists';
      case 'pantryItem': return 'pantry';
    }
  }

  /** Local upsert: stamps updatedAt/deviceId, merges LWW, enqueues outbox. */
  upsert(entity: EntityKind, id: string, payload: unknown): SyncEnvelope {
    const env: SyncEnvelope = {
      id: id || crypto.randomUUID(),
      updatedAt: new Date().toISOString(),
      deviceId: deviceId(),
      entity,
      payload,
    };
    const key = this.collectionKey(entity);
    this.state[key] = mergeInto(this.state[key] as SyncEnvelope[], env) as never;
    this.state.outbox = [...this.state.outbox, env];
    this.persist();
    return env;
  }

  /** Local delete: writes a tombstone envelope (LWW-compatible). */
  remove(entity: EntityKind, id: string): SyncEnvelope {
    const env: SyncEnvelope = {
      id, updatedAt: new Date().toISOString(), deviceId: deviceId(), deleted: true, entity, payload: {},
    };
    const key = this.collectionKey(entity);
    this.state[key] = mergeInto(this.state[key] as SyncEnvelope[], env) as never;
    this.state.outbox = [...this.state.outbox, env];
    this.persist();
    return env;
  }

  /** Apply a remote envelope (pull): LWW merge, no outbox enqueue. */
  applyRemote(env: SyncEnvelope): void {
    const key = this.collectionKey(env.entity);
    this.state[key] = mergeInto(this.state[key] as SyncEnvelope[], env) as never;
    this.persist();
  }

  /** Drain outbox (called after successful push). Returns drained envelopes. */
  drainOutbox(ids: string[]): SyncEnvelope[] {
    const drained = this.state.outbox.filter((e) => ids.includes(e.id));
    const idSet = new Set(ids);
    this.state.outbox = this.state.outbox.filter((e) => !idSet.has(e.id));
    this.persist();
    return drained;
  }

  clearAll(): void {
    this.state = { recipes: [], plans: [], menus: [], lists: [], pantry: [], outbox: [] };
    this.persist();
  }
}
