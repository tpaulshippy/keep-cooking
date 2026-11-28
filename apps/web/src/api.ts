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

export function getDeviceId(): string | null {
  try {
    return localStorage.getItem(DEVICE_ID_KEY);
  } catch {
    return null;
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

/** Enroll this device (POST /v2/devices stays open per contract). */
export async function enrollDevice(displayName?: string, base = resolveApiBase()): Promise<string> {
  const existing = getDeviceId();
  if (existing) {
    // Already enrolled locally; verify server knows us is caller's job.
    return existing;
  }
  const { deviceId, privateKey } = await ensureKeypair();
  void privateKey;
  const pubB64 = (() => {
    try {
      const raw = localStorage.getItem(PUB_KEY) ?? '';
      // Server expects base64 of exactly 32 bytes (raw Ed25519 public key).
      return raw;
    } catch {
      return '';
    }
  })();
  const res = await fetch(`${base}/v2/devices`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ deviceId, publicKey: pubB64, displayName: displayName ?? 'web' }),
  });
  if (!res.ok) throw new Error(`enroll failed: ${res.status}`);
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
  if (signed) {
    Object.assign(headers, await signHeaders(method, path, new TextEncoder().encode(bodyStr)));
  }
  const res = await fetch(`${base}${path}`, {
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
  listPantry: (base?: string) => req<PantryItem[]>('GET', '/pantry', undefined, false, base ?? resolveApiBase()),
  listPlans: (base?: string) => req<Plan[]>('GET', '/plans', undefined, false, base ?? resolveApiBase()),
  createPlan: (input: { date: string; meal: string; recipeId?: string | null; note?: string; servings?: number }, base?: string) =>
    req<Plan>('POST', '/plans', input, true, base ?? resolveApiBase()),
};
