// Thin typed fetch client matching packages/contracts/openapi.yaml shapes.
// Reads are open (GET/HEAD). Writes sign the canonical string from
// api/src/auth.ts: METHOD + "\n" + path+query + "\n" + ts + "\n" + hex(SHA256(body)).

export interface Recipe {
  id: string;
  updatedAt: string;
  deviceId?: string;
  deleted?: boolean;
  entity?: string;
  title: string;
  servings: number;
  description?: string;
  ingredients?: Ingredient[];
  steps?: Step[];
  [k: string]: unknown;
}
export interface Ingredient { id?: string; name: string; quantity?: number | null; unit?: string; display?: string; position?: number; }
export interface Step { id?: string; position?: number; text: string; timers?: { seconds: number; label: string }[]; }
export interface RecipeInput { title: string; servings?: number; description?: string; ingredients?: Ingredient[]; steps?: { text: string; position?: number }[]; [k: string]: unknown; }
export interface ShoppingList { id: string; updatedAt: string; name: string; items?: ListItem[]; [k: string]: unknown; }
export interface ListItem { id?: string; name: string; quantity?: string; aisle?: string; checked?: boolean; recipeId?: string | null; }
export interface PantryItem { id: string; updatedAt: string; name: string; quantity?: string; location?: string; [k: string]: unknown; }
export interface Plan { id: string; updatedAt: string; date: string; meal: string; recipeId?: string | null; note?: string; servings?: number; [k: string]: unknown; }
export interface Menu { id: string; updatedAt: string; name: string; entries?: { dayOffset?: number; meal?: string; recipeId?: string; servings?: number }[]; [k: string]: unknown; }
export interface ClipReport { strategy: string; confidence?: number; warnings?: string[]; recipe: RecipeInput; }

const LS_OVERRIDE_KEY = 'kc.apiBase';
export const DEFAULT_API_BASE = 'https://keepcooking.app/api';
const LOCAL_API_BASE = 'http://localhost:8787';

export function resolveApiBase(): string {
  try {
    const override = localStorage.getItem(LS_OVERRIDE_KEY);
    if (override) return override.replace(/\/$/, '');
  } catch { /* no localStorage (SSR/test) */ }
  if (typeof location !== 'undefined' && (location.hostname === 'localhost' || location.hostname === '127.0.0.1')) {
    return LOCAL_API_BASE;
  }
  return DEFAULT_API_BASE;
}

export function setApiBaseOverride(url: string | null): void {
  if (url) localStorage.setItem(LS_OVERRIDE_KEY, url.replace(/\/$/, ''));
  else localStorage.removeItem(LS_OVERRIDE_KEY);
}

export function getApiBaseOverride(): string | null {
  try {
    return localStorage.getItem(LS_OVERRIDE_KEY);
  } catch {
    return null;
  }
}

/** Build the exact request URL once: base may carry a path prefix (/api). */
export function buildUrl(base: string, path: string): URL {
  return new URL(base.replace(/\/+$/, '') + path);
}

/** The path+query the server signs over: exact pathname of the sent URL. */
export function signingPathFor(base: string, path: string): string {
  const url = buildUrl(base, path);
  return url.pathname + url.search;
}

async function sha256Hex(data: Uint8Array): Promise<string> {
  const bytes: Uint8Array<ArrayBuffer> = Uint8Array.from(data as Uint8Array);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

function b64encode(bytes: Uint8Array): string {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}
function b64decode(s: string): Uint8Array<ArrayBuffer> {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

const PRIV_KEY = 'kc.devicePriv';
const PUB_KEY = 'kc.devicePub';
const DEVICE_ID_KEY = 'kc.deviceId';
const ENROLLED_KEY = 'kc.deviceEnrolled';

export function getDeviceId(): string | null {
  try {
    return localStorage.getItem(DEVICE_ID_KEY);
  } catch {
    return null;
  }
}

/** True only after a successful POST /v2/devices (persisted flag). */
export function isEnrolled(): boolean {
  try {
    return localStorage.getItem(ENROLLED_KEY) === '1' && !!localStorage.getItem(DEVICE_ID_KEY);
  } catch {
    return false;
  }
}

async function ensureKeypair(): Promise<{ deviceId: string; privateKey: CryptoKey }> {
  let deviceId: string | null = null;
  let privB64: string | null = null;
  try {
    deviceId = localStorage.getItem(DEVICE_ID_KEY);
    privB64 = localStorage.getItem(PRIV_KEY);
  } catch { /* ignore */ }
  if (deviceId && privB64) {
    const privateKey = await crypto.subtle.importKey(
      'pkcs8', b64decode(privB64), { name: 'Ed25519' }, true, ['sign'],
    );
    return { deviceId, privateKey };
  }
  deviceId = crypto.randomUUID();
  const kp = await crypto.subtle.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify']) as CryptoKeyPair;
  const [rawPriv, rawPub] = await Promise.all([
    crypto.subtle.exportKey('pkcs8', kp.privateKey),
    crypto.subtle.exportKey('raw', kp.publicKey),
  ]);
  try {
    localStorage.setItem(DEVICE_ID_KEY, deviceId);
    localStorage.setItem(PRIV_KEY, b64encode(new Uint8Array(rawPriv)));
    localStorage.setItem(PUB_KEY, b64encode(new Uint8Array(rawPub)));
  } catch { /* ignore */ }
  return { deviceId, privateKey: kp.privateKey };
}

/** Enroll this device (POST /v2/devices stays open per contract). Tracks
 * enrollment with a persisted flag: a locally-known device id alone does NOT
 * count as enrolled, so a fresh browser always POSTs its public key. */
export async function enrollDevice(displayName?: string, base = resolveApiBase()): Promise<string> {
  if (isEnrolled()) {
    return getDeviceId() as string;
  }
  let { deviceId, privateKey } = await ensureKeypair();
  void privateKey;
  let pubB64: string | null = null;
  try {
    pubB64 = localStorage.getItem(PUB_KEY);
  } catch { /* ignore */ }
  if (!pubB64) {
    // Key material is incomplete (pre-flag install): rotate to a fresh
    // keypair so the enrolled public key matches the signing key.
    try {
      localStorage.removeItem(DEVICE_ID_KEY);
      localStorage.removeItem(PRIV_KEY);
    } catch { /* ignore */ }
    const fresh = await ensureKeypair();
    deviceId = fresh.deviceId;
    try {
      pubB64 = localStorage.getItem(PUB_KEY);
    } catch { /* ignore */ }
  }
  const res = await fetch(`${base}/v2/devices`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ deviceId, publicKey: pubB64 ?? '', displayName: displayName ?? 'web' }),
  });
  if (!res.ok) throw new Error(`enroll failed: ${res.status}`);
  try {
    localStorage.setItem(ENROLLED_KEY, '1');
  } catch { /* ignore */ }
  return deviceId;
}

async function signHeaders(method: string, pathQuery: string, bodyBytes: Uint8Array): Promise<Record<string, string>> {
  const { deviceId, privateKey } = await ensureKeypair();
  const ts = String(Date.now());
  const bodyHash = await sha256Hex(bodyBytes);
  const canonical = `${method}\n${pathQuery}\n${ts}\n${bodyHash}`;
  const msg: Uint8Array<ArrayBuffer> = Uint8Array.from(new TextEncoder().encode(canonical));
  const sig = await crypto.subtle.sign({ name: 'Ed25519' }, privateKey, msg);
  return {
    'x-device-id': deviceId,
    'x-device-ts': ts,
    'x-device-sig': b64encode(new Uint8Array(sig)),
  };
}

async function req<T>(method: string, path: string, body?: unknown, signed = false, base = resolveApiBase()): Promise<T> {
  const bodyStr = body === undefined ? '' : JSON.stringify(body);
  const headers: Record<string, string> = {};
  if (body !== undefined) headers['content-type'] = 'application/json';
  // One URL object feeds both the signature and the send, so the canonical
  // path+query always equals what the server receives (bases with an /api
  // prefix sign /api/... too).
  const url = buildUrl(base, path);
  if (signed) {
    Object.assign(headers, await signHeaders(method, url.pathname + url.search, new TextEncoder().encode(bodyStr)));
  }
  const res = await fetch(url.toString(), {
    method,
    headers,
    body: body === undefined ? undefined : bodyStr,
  });
  if (!res.ok) throw new Error(`${method} ${path} failed: ${res.status}`);
  if (res.status === 204) return undefined as T;
  return (await res.json()) as T;
}

export const api = {
  base: resolveApiBase,
  health: (base?: string) => req<{ ok: boolean; version?: string }>('GET', '/health', undefined, false, base ?? resolveApiBase()),
  listRecipes: (base?: string) => req<Recipe[]>('GET', '/recipes', undefined, false, base ?? resolveApiBase()),
  getRecipe: (id: string, base?: string) => req<Recipe>('GET', `/recipes/${id}`, undefined, false, base ?? resolveApiBase()),
  createRecipe: (input: RecipeInput, base?: string) => req<Recipe>('POST', '/recipes', input, true, base ?? resolveApiBase()),
  updateRecipe: (id: string, input: RecipeInput, base?: string) => req<Recipe>('PUT', `/recipes/${id}`, input, true, base ?? resolveApiBase()),
  deleteRecipe: (id: string, base?: string) => req<void>('DELETE', `/recipes/${id}`, undefined, true, base ?? resolveApiBase()),
  scaleRecipe: (id: string, servings: number, base?: string) =>
    req<Recipe>('POST', `/recipes/${id}/scale`, { servings }, true, base ?? resolveApiBase()),
  clip: (input: { url?: string; caption?: string; source?: string }, base?: string) =>
    req<ClipReport>('POST', '/clip', input, true, base ?? resolveApiBase()),
  listLists: (base?: string) => req<ShoppingList[]>('GET', '/lists', undefined, false, base ?? resolveApiBase()),
  createList: (input: { name: string; items?: ListItem[] }, base?: string) =>
    req<ShoppingList>('POST', '/lists', input, true, base ?? resolveApiBase()),
  updateList: (id: string, input: { name: string; items?: ListItem[] }, base?: string) =>
    req<ShoppingList>('PUT', `/lists/${id}`, input, true, base ?? resolveApiBase()),
  deleteList: (id: string, base?: string) => req<void>('DELETE', `/lists/${id}`, undefined, true, base ?? resolveApiBase()),
  listPantry: (base?: string) => req<PantryItem[]>('GET', '/pantry', undefined, false, base ?? resolveApiBase()),
  createPantryItem: (input: { name: string; quantity?: string; location?: string; [k: string]: unknown }, base?: string) =>
    req<PantryItem>('POST', '/pantry', input, true, base ?? resolveApiBase()),
  updatePantryItem: (id: string, input: { name: string; quantity?: string; location?: string; [k: string]: unknown }, base?: string) =>
    req<PantryItem>('PUT', `/pantry/${id}`, input, true, base ?? resolveApiBase()),
  deletePantryItem: (id: string, base?: string) => req<void>('DELETE', `/pantry/${id}`, undefined, true, base ?? resolveApiBase()),
  listPlans: (base?: string) => req<Plan[]>('GET', '/plans', undefined, false, base ?? resolveApiBase()),
  createPlan: (input: { date: string; meal: string; recipeId?: string | null; note?: string; servings?: number }, base?: string) =>
    req<Plan>('POST', '/plans', input, true, base ?? resolveApiBase()),
  updatePlan: (id: string, input: { date: string; meal: string; recipeId?: string | null; note?: string; servings?: number }, base?: string) =>
    req<Plan>('PUT', `/plans/${id}`, input, true, base ?? resolveApiBase()),
  deletePlan: (id: string, base?: string) => req<void>('DELETE', `/plans/${id}`, undefined, true, base ?? resolveApiBase()),
  createMenu: (input: { name: string; entries?: { dayOffset?: number; meal?: string; recipeId?: string; servings?: number }[] }, base?: string) =>
    req<Menu>('POST', '/menus', input, true, base ?? resolveApiBase()),
  updateMenu: (id: string, input: { name: string; entries?: { dayOffset?: number; meal?: string; recipeId?: string; servings?: number }[] }, base?: string) =>
    req<Menu>('PUT', `/menus/${id}`, input, true, base ?? resolveApiBase()),
  deleteMenu: (id: string, base?: string) => req<void>('DELETE', `/menus/${id}`, undefined, true, base ?? resolveApiBase()),
};
