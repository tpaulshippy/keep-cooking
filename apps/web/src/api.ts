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
export interface PhotoSignResponse { url: string; expiresAt: string; key: string; }
export type ExportFormat = 'json' | 'md' | 'html' | 'paprikarecipes' | 'yaml';
export type ExportExt = ExportFormat;
export type ImportFormat =
  | 'paprika-json' | 'paprika-zip' | 'paprika-recipe' | 'yaml' | 'html'
  | 'mx2' | 'mxp' | 'mz2' | 'mmf' | 'fdx' | 'fdxz'
  | 'pepperplate-zip' | 'pepperplate-db' | 'copymethat-zip' | 'yum-xml'
  | 'ysr' | 'mgourmet' | 'dvo' | 'mcb' | 'recipe-manager-txt'
  | 'hcb' | 'myrecipebook-sqlite' | 'rbox';
export interface ImportRequest {
  householdId?: string;
  format: ImportFormat;
  payload?: string;
  payloadJson?: unknown;
  importCookbooks?: boolean;
  dryRun?: boolean;
}
export interface ImportReport {
  imported: Recipe[];
  updated: number;
  warnings?: string[];
  dryRun?: boolean;
  cookbooksCreated?: string[];
}

const LS_OVERRIDE_KEY = 'kc.apiBase';
export const DEFAULT_API_BASE = 'https://keepcooking.app/api';
const LOCAL_API_BASE = 'http://localhost:8787/api';

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

/** Enrollment belongs to the selected backend: flag is keyed by normalized base. */
function enrolledKeyFor(base: string): string {
  return `${ENROLLED_KEY}:${base.replace(/\/+$/, '')}`;
}

export function getDeviceId(): string | null {
  try {
    return localStorage.getItem(DEVICE_ID_KEY);
  } catch {
    return null;
  }
}

/** True only after a successful POST /v2/devices against that base (persisted per-base flag). */
export function isEnrolled(base = resolveApiBase()): boolean {
  try {
    return localStorage.getItem(enrolledKeyFor(base)) === '1' && !!localStorage.getItem(DEVICE_ID_KEY);
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
  // Reuse the stored device id when present so pre-enrollment offline
  // envelopes stamped with it stay attributable; only mint a fresh id when
  // none is stored. (The 409-conflict rotation in enrollDevice is the sole
  // rotation trigger.)
  if (!deviceId) {
    deviceId = crypto.randomUUID();
  }
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
 * enrollment per backend with a persisted flag: a locally-known device id
 * alone does NOT count as enrolled, so a fresh browser — or a switch of the
 * API-base override — always POSTs its public key to that server. */
export async function enrollDevice(displayName?: string, base = resolveApiBase()): Promise<string> {
  const normalizedBase = base.replace(/\/+$/, '');
  const enrolledKey = enrolledKeyFor(normalizedBase);
  if (isEnrolled(normalizedBase)) {
    return getDeviceId() as string;
  }
  const postEnrollment = (id: string, pubB64: string) =>
    fetch(`${normalizedBase}/v2/devices`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ deviceId: id, publicKey: pubB64 ?? '', displayName: displayName ?? 'web' }),
    });
  const readPubKey = (): string | null => {
    try {
      return localStorage.getItem(PUB_KEY);
    } catch {
      return null;
    }
  };
  let { deviceId, privateKey } = await ensureKeypair();
  void privateKey;
  let pubB64 = readPubKey();
  if (!pubB64) {
    // Key material is incomplete: regenerate keys for the STORED device id
    // (never rotate the id here — offline envelopes may already reference it).
    try {
      localStorage.removeItem(PRIV_KEY);
    } catch { /* ignore */ }
    const repaired = await ensureKeypair();
    deviceId = repaired.deviceId;
    pubB64 = readPubKey();
  }
  let res = await postEnrollment(deviceId, pubB64 ?? '');
  if (res.status === 409) {
    // deviceId is bound to a different key server-side: drop this identity
    // (id + keypair + this base's enrolled flag), mint a fresh one, retry once.
    try {
      localStorage.removeItem(DEVICE_ID_KEY);
      localStorage.removeItem(PRIV_KEY);
      localStorage.removeItem(PUB_KEY);
      localStorage.removeItem(enrolledKey);
    } catch { /* ignore */ }
    const fresh = await ensureKeypair();
    deviceId = fresh.deviceId;
    pubB64 = readPubKey();
    res = await postEnrollment(deviceId, pubB64 ?? '');
  }
  if (!res.ok) throw new Error(`enroll failed: ${res.status}`);
  try {
    localStorage.setItem(enrolledKey, '1');
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

export interface E2EStoredResponse { stored: string[]; }

/** GET /v2/sync/:hash — unsigned read of one household bucket. */
export async function e2ePull(hash: string, since: string | null, base = resolveApiBase()): Promise<unknown[]> {
  const url = buildUrl(base, `/v2/sync/${hash}`);
  if (since) url.searchParams.set('since', since);
  const res = await fetch(url.toString());
  if (!res.ok) throw new Error(`GET /v2/sync failed: ${res.status}`);
  return (await res.json()) as unknown[];
}

/** PUT /v2/sync/:hash — Ed25519-signed upsert batch. Returns accepted ids. */
export async function e2ePush(hash: string, envelopes: unknown[], base = resolveApiBase()): Promise<E2EStoredResponse> {
  const bodyStr = JSON.stringify(envelopes);
  const url = buildUrl(base, `/v2/sync/${hash}`);
  const headers = await signHeaders('PUT', url.pathname + url.search, new TextEncoder().encode(bodyStr));
  headers['content-type'] = 'application/json';
  const res = await fetch(url.toString(), { method: 'PUT', headers, body: bodyStr });
  if (!res.ok) throw new Error(`PUT /v2/sync failed: ${res.status}`);
  return (await res.json()) as E2EStoredResponse;
}

/**
 * Acceptable custom-server values: blank (built-in) or an http(s) URL;
 * http:// only for local dev hosts. Returns an error message, else null.
 * Parity with the iOS/Android Settings validators.
 */
export function validateCustomServer(raw: string): string | null {
  const trimmed = raw.trim();
  if (!trimmed) return null;
  let url: URL | null = null;
  try {
    url = new URL(trimmed);
  } catch {
    url = null;
  }
  const host = url?.hostname.toLowerCase() ?? '';
  if (!url || !host || url.search || url.hash) return 'That server URL does not look valid — keeping current server.';
  const scheme = url.protocol.toLowerCase().replace(/:$/, '');
  const isLocalDev = host === 'localhost' || host === '127.0.0.1' || host.endsWith('.local');
  if (scheme !== 'https' && !(scheme === 'http' && isLocalDev)) {
    return 'Server must use HTTPS (http:// is only allowed for localhost / 127.0.0.1 / *.local dev servers).';
  }
  return null;
}

/** Per-recipe export URL: GET /export/{id}.{json|md|html|paprikarecipes|yaml} (open, unsigned). */
export function recipeExportUrl(id: string, ext: ExportExt, base = resolveApiBase()): string {
  return buildUrl(base, `/export/${encodeURIComponent(id)}.${ext}`).toString();
}

/** Bulk export URL: GET /export?format=&all=true|ids=|cookbook= (open, unsigned). */
export function bulkExportUrl(
  opts: { format?: ExportFormat; all?: boolean; ids?: string[]; cookbook?: string },
  base = resolveApiBase(),
): string {
  const url = buildUrl(base, '/export');
  if (opts.format) url.searchParams.set('format', opts.format);
  if (opts.all) url.searchParams.set('all', 'true');
  else if (opts.ids?.length) url.searchParams.set('ids', opts.ids.join(','));
  if (opts.cookbook) url.searchParams.set('cookbook', opts.cookbook);
  return url.toString();
}

/** URL builders for every export route (per-recipe + bulk). */
export const exportUrls = { recipe: recipeExportUrl, bulk: bulkExportUrl };

export const api = {
  base: resolveApiBase,
  health: (base?: string) => req<{ ok: boolean; version?: string }>('GET', '/health', undefined, false, base ?? resolveApiBase()),
  importReport: (input: ImportRequest, base?: string) =>
    req<ImportReport>('POST', '/import', { householdId: 'web', ...input }, true, base ?? resolveApiBase()),
  /** Per-recipe export URL: GET /export/{id}.{json|md|html|paprikarecipes|yaml} (open, unsigned). */
  exportRecipeUrl: (id: string, ext: ExportExt, base?: string) =>
    recipeExportUrl(id, ext, base ?? resolveApiBase()),
  /** Bulk export URL: GET /export?format=&all=true|ids=|cookbook= (open, unsigned). */
  exportBulkUrl: (opts: { format?: ExportFormat; all?: boolean; ids?: string[]; cookbook?: string }, base?: string) =>
    bulkExportUrl(opts, base ?? resolveApiBase()),
  /** Fetch an (open, unsigned) export URL and return the bytes as a Blob. */
  fetchExportBlob: async (url: string): Promise<Blob> => {
    const res = await fetch(url);
    if (!res.ok) throw new Error(`export failed: ${res.status}`);
    return await res.blob();
  },
  listRecipes: (base?: string) => req<Recipe[]>('GET', '/recipes', undefined, false, base ?? resolveApiBase()),
  getRecipe: (id: string, base?: string) => req<Recipe>('GET', `/recipes/${id}`, undefined, false, base ?? resolveApiBase()),
  createRecipe: (input: RecipeInput, base?: string) => req<Recipe>('POST', '/recipes', input, true, base ?? resolveApiBase()),
  updateRecipe: (id: string, input: RecipeInput, base?: string) => req<Recipe>('PUT', `/recipes/${id}`, input, true, base ?? resolveApiBase()),
  deleteRecipe: (id: string, base?: string) => req<void>('DELETE', `/recipes/${id}`, undefined, true, base ?? resolveApiBase()),
  scaleRecipe: (id: string, servings: number, base?: string) =>
    req<Recipe>('POST', `/recipes/${id}/scale`, { servings }, true, base ?? resolveApiBase()),
  /** Mint a short-lived photo URL: GET /photos/sign?key=… (open, unsigned).
   *  R2 keys (photos/…) resolve to signed /photos/dl URLs; the API 404s
   *  when photo serving is not configured — callers hide the image then. */
  photoSign: (key: string, base?: string) =>
    req<PhotoSignResponse>('GET', `/photos/sign?key=${encodeURIComponent(key)}`, undefined, false, base ?? resolveApiBase()),
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
  listMenus: (base?: string) => req<Menu[]>('GET', '/menus', undefined, false, base ?? resolveApiBase()),
  createMenu: (input: { name: string; entries?: { dayOffset?: number; meal?: string; recipeId?: string; servings?: number }[] }, base?: string) =>
    req<Menu>('POST', '/menus', input, true, base ?? resolveApiBase()),
  updateMenu: (id: string, input: { name: string; entries?: { dayOffset?: number; meal?: string; recipeId?: string; servings?: number }[] }, base?: string) =>
    req<Menu>('PUT', `/menus/${id}`, input, true, base ?? resolveApiBase()),
  deleteMenu: (id: string, base?: string) => req<void>('DELETE', `/menus/${id}`, undefined, true, base ?? resolveApiBase()),
};
