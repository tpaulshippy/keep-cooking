// Paprika import/export (P0 parity). Zero-dependency: ZIP/gzip via Web
// Streams (CompressionStream/DecompressionStream work in Workers + Node 18+),
// base64 via atob/btoa, YAML/HTML via small built-in parsers.
//
// Covers: .paprikarecipes (ZIP of *.paprikarecipe), single .paprikarecipe
// (gzip JSON), bare JSON, concatenated gzip streams, YAML (.yml/.yaml,
// JSON-as-YAML), and HTML (JSON-LD -> hRecipe -> headings).

import type { Recipe } from './store';

// ---------- base64 (Worker + Node safe, chunked for large photo_data) ----------

export function b64ToBytes(b64: string): Uint8Array {
  // Old Paprika exports escape slashes as `\/`; tolerate 76-col wrapping.
  const clean = b64.replace(/\\\//g, '/').replace(/\s+/g, '');
  const bin = atob(clean);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i) & 0xff;
  return out;
}

export function bytesToB64(bytes: Uint8Array): string {
  let s = '';
  const CHUNK = 0x8000;
  for (let i = 0; i < bytes.length; i += CHUNK) {
    s += String.fromCharCode(...bytes.subarray(i, i + CHUNK));
  }
  return btoa(s);
}

// ---------- gzip / inflate helpers (Web Streams) ----------

async function pipeThrough(
  data: Uint8Array,
  format: 'gzip' | 'deflate' | 'deflate-raw',
  mode: 'compress' | 'decompress',
): Promise<Uint8Array> {
  const stream = mode === 'compress' ? new CompressionStream(format) : new DecompressionStream(format);
  const copy = Uint8Array.from(data);
  const body = new Blob([copy.buffer as ArrayBuffer]).stream().pipeThrough(stream);
  return new Uint8Array(await new Response(body).arrayBuffer());
}

export const gzipBytes = (data: Uint8Array): Promise<Uint8Array> => pipeThrough(data, 'gzip', 'compress');
export const gunzipBytes = (data: Uint8Array): Promise<Uint8Array> => pipeThrough(data, 'gzip', 'decompress');
export const inflateRawBytes = (data: Uint8Array): Promise<Uint8Array> => pipeThrough(data, 'deflate-raw', 'decompress');

const utf8Encode = (s: string): Uint8Array => new TextEncoder().encode(s);
const utf8Decode = (b: Uint8Array): string => new TextDecoder('utf-8', { fatal: false }).decode(b);

// ---------- CRC32 (for ZIP writing) ----------

const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) {
    let c = n;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[n] = c >>> 0;
  }
  return t;
})();

export function crc32(data: Uint8Array): number {
  let c = 0xffffffff;
  for (let i = 0; i < data.length; i++) c = CRC_TABLE[(c ^ data[i]!) & 0xff]! ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

// ---------- minimal ZIP reader (stored + deflated entries) ----------

export interface ZipEntry {
  name: string;
  data: Uint8Array;
}

function readU16LE(b: Uint8Array, o: number): number {
  return (b[o]! | (b[o + 1]! << 8)) >>> 0;
}
function readU32LE(b: Uint8Array, o: number): number {
  return (b[o]! | (b[o + 1]! << 8) | (b[o + 2]! << 16) | (b[o + 3]! << 24)) >>> 0;
}

/** Parse a ZIP archive via local file headers. Throws on malformed input. */
export async function unzipEntries(zip: Uint8Array): Promise<ZipEntry[]> {
  const entries: ZipEntry[] = [];
  let o = 0;
  while (o + 30 <= zip.length) {
    const sig = readU32LE(zip, o);
    if (sig === 0x02014b50 || sig === 0x06054b50) break; // central dir / end: done
    if (sig !== 0x04034b50) throw new Error('not a ZIP archive (bad local header)');
    const flags = readU16LE(zip, o + 8);
    const method = readU16LE(zip, o + 10);
    const compSize = readU32LE(zip, o + 18);
    const nameLen = readU16LE(zip, o + 26);
    const extraLen = readU16LE(zip, o + 28);
    const nameStart = o + 30;
    const dataStart = nameStart + nameLen + extraLen;
    if (dataStart > zip.length) throw new Error('truncated ZIP entry');
    if (flags & 0x08) throw new Error('ZIP data-descriptor entries are not supported');
    if (dataStart + compSize > zip.length) throw new Error('truncated ZIP entry data');
    const name = utf8Decode(zip.subarray(nameStart, nameStart + nameLen));
    const raw = zip.subarray(dataStart, dataStart + compSize);
    let data: Uint8Array;
    if (method === 0) data = raw.slice();
    else if (method === 8) data = await inflateRawBytes(raw);
    else throw new Error(`unsupported ZIP method ${method}`);
    // Skip directory entries.
    if (!name.endsWith('/')) entries.push({ name, data });
    o = dataStart + compSize;
  }
  if (entries.length === 0) throw new Error('ZIP archive contains no files');
  return entries;
}

// ---------- minimal ZIP writer (stored entries) ----------

function writeU16LE(v: number): Uint8Array {
  return Uint8Array.of(v & 0xff, (v >>> 8) & 0xff);
}
function writeU32LE(v: number): Uint8Array {
  return Uint8Array.of(v & 0xff, (v >>> 8) & 0xff, (v >>> 16) & 0xff, (v >>> 24) & 0xff);
}
function concat(parts: Uint8Array[]): Uint8Array {
  const total = parts.reduce((n, p) => n + p.length, 0);
  const out = new Uint8Array(total);
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
}

/** Build a ZIP archive with stored (uncompressed) entries. */
export function zipStore(entries: { name: string; data: Uint8Array }[]): Uint8Array {
  const chunks: Uint8Array[] = [];
  const central: Uint8Array[] = [];
  let offset = 0;
  for (const e of entries) {
    const name = utf8Encode(e.name);
    const crc = crc32(e.data);
    const local = concat([
      writeU32LE(0x04034b50),
      writeU16LE(20),
      writeU16LE(0x0800), // UTF-8 names
      writeU16LE(0), // stored
      writeU16LE(0), // mod time
      writeU16LE(0), // mod date
      writeU32LE(crc),
      writeU32LE(e.data.length),
      writeU32LE(e.data.length),
      writeU16LE(name.length),
      writeU16LE(0),
      name,
    ]);
    chunks.push(local, e.data);
    central.push(
      concat([
        writeU32LE(0x02014b50),
        writeU16LE(20),
        writeU16LE(20),
        writeU16LE(0x0800),
        writeU16LE(0),
        writeU16LE(0),
        writeU16LE(0),
        writeU32LE(crc),
        writeU32LE(e.data.length),
        writeU32LE(e.data.length),
        writeU16LE(name.length),
        writeU16LE(0),
        writeU16LE(0),
        writeU16LE(0),
        writeU16LE(0),
        writeU32LE(0),
        writeU32LE(offset),
        name,
      ]),
    );
    offset += local.length + e.data.length;
  }
  const centralDir = concat(central);
  const end = concat([
    writeU32LE(0x06054b50),
    writeU16LE(0),
    writeU16LE(0),
    writeU16LE(entries.length),
    writeU16LE(entries.length),
    writeU32LE(centralDir.length),
    writeU32LE(offset),
    writeU16LE(0),
  ]);
  return concat([...chunks, centralDir, end]);
}

// ---------- free-text servings / duration parsing ----------

const UNICODE_FRACTIONS: Record<string, number> = {
  '½': 0.5,
  '⅓': 1 / 3,
  '⅔': 2 / 3,
  '¼': 0.25,
  '¾': 0.75,
  '⅕': 0.2,
  '⅖': 0.4,
  '⅗': 0.6,
  '⅘': 0.8,
  '⅙': 1 / 6,
  '⅚': 5 / 6,
  '⅛': 0.125,
  '⅜': 0.375,
  '⅝': 0.625,
  '⅞': 0.875,
};

function parseNumberToken(tok: string): number | null {
  const t = tok.trim();
  const uni = UNICODE_FRACTIONS[t];
  if (uni !== undefined) return uni;
  const frac = t.match(/^(\d+(?:\.\d+)?)\s*\/\s*(\d+(?:\.\d+)?)$/);
  if (frac) {
    const den = Number(frac[2]);
    if (den !== 0) return Number(frac[1]) / den;
    return null;
  }
  const n = Number(t);
  return Number.isFinite(n) ? n : null;
}

/**
 * Parse Paprika's free-text servings ("4", "4-6 servings", "1 pie", "1/2",
 * "2 1/2 dozen"). Returns the leading number/fraction/range-start and keeps
 * the raw string for the warning sidecar.
 */
export function parseServings(raw: unknown): { servings: number; rawText: string; note?: string } {
  const text = String(raw ?? '').trim();
  if (!text) return { servings: 4, rawText: '', note: 'servings missing; defaulted to 4' };
  const m = text.match(/(\d+(?:\s+\d+\s*\/\s*\d+)?(?:\.\d+)?(?:\s*\/\s*\d+)?|[¼½¾⅓⅔⅛⅜⅝⅞⅕⅖⅗⅘⅙⅚])\s*(?:-|–|—|to\b)?/i);
  if (!m) return { servings: 4, rawText: text, note: `servings "${text}" has no leading number; defaulted to 4` };
  const head = m[1]!.trim();
  let value: number | null = null;
  const mixed = head.match(/^(\d+)\s+(\d+\s*\/\s*\d+)$/);
  if (mixed) {
    const whole = Number(mixed[1]);
    const frac = parseNumberToken(mixed[2]!);
    if (frac !== null) value = whole + frac;
  } else {
    value = parseNumberToken(head);
  }
  if (value === null || !(value > 0)) {
    return { servings: 4, rawText: text, note: `servings "${text}" unparseable; defaulted to 4` };
  }
  // Clamp into the recipeInputSchema range (0.25..100).
  const clamped = Math.min(100, Math.max(0.25, value));
  const note =
    clamped !== value
      ? `servings "${text}" clamped to ${clamped}`
      : head !== text
        ? `servings "${text}" parsed as ${clamped} (raw preserved)`
        : undefined;
  return { servings: clamped, rawText: text, note };
}

const TIME_UNIT_MIN: [RegExp, number][] = [
  [/\b(hours?|hrs?|h)\b/i, 60],
  [/\b(minutes?|mins?|m)\b/i, 1],
  [/\b(seconds?|secs?|s)\b/i, 1 / 60],
];

/**
 * Parse Paprika's free-text durations ("10 min", "1 hr 15 min", "1:30",
 * "90"). Returns whole minutes or null when absent/unparseable.
 */
export function parseMinutes(raw: unknown): { minutes: number | null; rawText: string; note?: string } {
  const text = String(raw ?? '').trim();
  if (!text) return { minutes: null, rawText: '' };
  // "1:30" / "1:30:00" (h:mm[:ss]).
  const clock = text.match(/(\d+)\s*:\s*(\d{1,2})(?:\s*:\s*(\d{1,2}))?/);
  if (clock) {
    const total = Number(clock[1]) * 60 + Number(clock[2]) + (clock[3] ? Math.round(Number(clock[3]) / 60) : 0);
    return { minutes: total, rawText: text, note: `time "${text}" parsed as ${total} min (raw preserved)` };
  }
  let total = 0;
  let found = false;
  const re = /(\d+(?:\s+\d+\s*\/\s*\d+)?(?:\.\d+)?(?:\s*\/\s*\d+)?|[¼½¾⅓⅔⅛⅜⅝⅞])\s*(hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)\b/gi;
  let m: RegExpExecArray | null;
  while ((m = re.exec(text)) !== null) {
    const num = parseNumberToken(m[1]!);
    if (num === null) continue;
    const unit = m[2]!.toLowerCase();
    // Bare "m" = minutes; bare "s" = seconds.
    let factor: number;
    if (/^(h|hr|hrs|hour|hours)$/.test(unit)) factor = 60;
    else if (/^(s|sec|secs|second|seconds)$/.test(unit)) factor = 1 / 60;
    else factor = 1;
    total += num * factor;
    found = true;
  }
  if (!found) {
    // Bare number => minutes ("90").
    if (/^\d+(?:\.\d+)?$/.test(text)) {
      return { minutes: Math.round(Number(text)), rawText: text, note: `time "${text}" assumed minutes (raw preserved)` };
    }
    return { minutes: null, rawText: text, note: `time "${text}" unparseable; left empty` };
  }
  return { minutes: Math.round(total), rawText: text, note: `time "${text}" parsed as ${Math.round(total)} min (raw preserved)` };
}

/** Parse an ISO-8601 duration (schema.org prepTime/cookTime) to minutes. */
export function parseIsoDuration(raw: string): number | null {
  const m = raw.trim().match(/^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?)?$/i);
  if (!m || m[0] === 'P' || m[0] === 'PT') return null;
  const d = Number(m[1] ?? 0);
  const h = Number(m[2] ?? 0);
  const min = Number(m[3] ?? 0);
  const s = Number(m[4] ?? 0);
  return Math.round(d * 1440 + h * 60 + min + s / 60);
}

// ---------- ingredient / direction splitting ----------

const KNOWN_UNITS = new Set(
  'cup cups c tbsp tbs tablespoon tablespoons tsp teaspoon teaspoons oz ounce ounces lb lbs pound pounds g gram grams kg kilo kilogram kilograms mg ml milliliter milliliters l liter liters cl dl pint pints quart quarts gallon gallons stick sticks can cans package packages pkg bunch bunches slice slices clove cloves pinch pinches dash dashes scoop scoops handful sprig sprigs stalk stalks'.split(
    ' ',
  ),
);

export interface ParsedIngredient {
  name: string;
  quantity: number | null;
  unit: string;
  display: string;
  position: number;
}

/** Best-effort qty/unit parse; `display` always keeps the original line (lossless). */
export function parseIngredientLine(line: string, position: number): ParsedIngredient {
  const display = line.trim();
  const base = { name: display, quantity: null as number | null, unit: '', display, position };
  const m = display.match(/^(\d+(?:\s+\d+\s*\/\s*\d+)?(?:\.\d+)?(?:\s*\/\s*\d+)?|[¼½¾⅓⅔⅛⅜⅝⅞⅕⅖⅗⅘⅙⅚])\s+(.+)$/);
  if (!m) return base;
  const head = m[1]!.trim();
  const rest = m[2]!.trim();
  let qty: number | null = null;
  const mixed = head.match(/^(\d+)\s+(\d+\s*\/\s*\d+)$/);
  if (mixed) {
    const frac = parseNumberToken(mixed[2]!);
    if (frac !== null) qty = Number(mixed[1]) + frac;
  } else {
    qty = parseNumberToken(head);
  }
  if (qty === null) return base;
  const parts = rest.split(/\s+/);
  let unit = '';
  let name = rest;
  if (parts.length > 1 && KNOWN_UNITS.has(parts[0]!.toLowerCase().replace(/\.$/, ''))) {
    unit = parts[0]!;
    name = parts.slice(1).join(' ');
  }
  return { name, quantity: qty, unit, display, position };
}

const LEADING_NUMBERING = /^\s*(?:step\s*\d+\s*[:.)-]?\s*|\d+\s*[.)\-:]\s+|\(\d+\)\s+)/i;

/** Split directions on blank lines first, else single newlines; strip "1." numbering. */
export function splitDirections(raw: string): string[] {
  const text = String(raw ?? '').replace(/\r\n?/g, '\n');
  const chunks = /\n\s*\n/.test(text) ? text.split(/\n\s*\n/) : text.split('\n');
  return chunks
    .map((c) => c.replace(/\\n/g, '\n').trim().replace(LEADING_NUMBERING, '').trim())
    .filter(Boolean);
}

// ---------- Paprika JSON -> recipe input ----------

export interface ParsedPaprikaRecipe {
  /** Recipe input suitable for recipeInputSchema + createRecipe. */
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  input: any;
  /** Stable Paprika identity; use as upsert key. */
  uid?: string;
  /** Synthesized photo filename (`${UID}.jpg` when photo_data lacks one). */
  photoFilename?: string;
  /** Non-fatal mapping notes; raw free-text preserved here (no schema change). */
  warnings: string[];
  /** Original Paprika object for lossless round-trip sidecar logging. */
  rawKeys: string[];
}

function asStringArray(v: unknown): string[] {
  return Array.isArray(v) ? v.map((x) => String(x)) : [];
}

/**
 * Map one Paprika JSON object (native or YAML-translated) onto a Keep
 * Cooking recipe input. Never throws on missing/odd fields; records notes in
 * `warnings` and preserves raw free-text there.
 */
export function parsePaprikaJson(json: unknown): ParsedPaprikaRecipe {
  const warnings: string[] = [];
  const warn = (s: string) => warnings.push(s);
  const o = (json ?? {}) as Record<string, unknown>;
  const rawKeys = Object.keys(o);

  const name = String(o['name'] ?? '').trim();
  if (!name) warn('recipe has no name; titled "Untitled Import"');
  const title = name || 'Untitled Import';

  // Ingredients: flat \n-separated text.
  const ingText = String(o['ingredients'] ?? '');
  const ingLines = ingText
    .replace(/\r\n?/g, '\n')
    .split('\n')
    .map((l) => l.trim())
    .filter(Boolean);
  const ingredients = ingLines.map((line, i) => {
    const p = parseIngredientLine(line, i);
    return { name: p.name, quantity: p.quantity, unit: p.unit, display: p.display, position: p.position };
  });

  // Directions -> steps.
  const steps = splitDirections(String(o['directions'] ?? '')).map((text, i) => ({ position: i, text }));

  // Servings / times (free text -> numbers, raw preserved in warnings).
  const servings = parseServings(o['servings']);
  if (servings.note) warn(`${title}: ${servings.note}`);
  const prep = parseMinutes(o['prep_time']);
  if (prep.note && prep.rawText) warn(`${title}: prep_time ${prep.note}`);
  const cook = parseMinutes(o['cook_time']);
  if (cook.note && cook.rawText) warn(`${title}: cook_time ${cook.note}`);
  const totalRaw = o['total_time'] != null && String(o['total_time']).trim() !== '' ? String(o['total_time']) : '';
  if (totalRaw) {
    const total = parseMinutes(totalRaw);
    warn(`${title}: total_time "${totalRaw}" has no Keep Cooking field${total.minutes !== null ? ` (≈${total.minutes} min)` : ''}; raw preserved`);
  }

  // Rating: Paprika 0 = unrated -> null.
  let rating: number | null = null;
  const rRaw = o['rating'];
  if (typeof rRaw === 'number' && Number.isFinite(rRaw) && rRaw > 0) rating = Math.min(5, Math.max(0, Math.round(rRaw)));
  else if (typeof rRaw === 'number' && rRaw !== 0) warn(`${title}: rating "${String(rRaw)}" out of range; left unrated`);

  // Description + notes (notes appended after description, never into steps).
  const description = String(o['description'] ?? '');
  const notes = o['notes'] != null ? String(o['notes']) : '';
  const combinedDescription = notes.trim()
    ? description.trim()
      ? `${description.trim()}\n\nNotes: ${notes.trim()}`
      : `Notes: ${notes.trim()}`
    : description;
  if (notes.trim()) warn(`${title}: notes folded into description (no dedicated field)`);

  // Lossless extras with no Keep Cooking field -> warnings sidecar.
  const difficulty = o['difficulty'] != null ? String(o['difficulty']) : '';
  if (difficulty.trim()) warn(`${title}: difficulty "${difficulty.trim()}" has no field; raw preserved`);
  const nutrition = o['nutritional_info'] != null ? String(o['nutritional_info']) : '';
  if (nutrition.trim()) warn(`${title}: nutritional_info "${nutrition.trim().slice(0, 200)}" has no structured field; raw preserved`);

  // Source: old exports used `source` for the URL; accept both.
  let source = o['source'] != null ? String(o['source']) : '';
  let sourceUrl = o['source_url'] != null ? String(o['source_url']) : '';
  if (!sourceUrl && /^https?:\/\//i.test(source.trim())) {
    sourceUrl = source.trim();
    source = '';
    warn(`${title}: legacy source-as-URL moved to sourceUrl`);
  }

  // Photo: validate base64, synthesize `${UID}.jpg` when missing (Paprika
  // crashes mid-import on photo_data without a photo filename).
  const uid = o['uid'] != null && String(o['uid']).trim() !== '' ? String(o['uid']).trim() : undefined;
  let photoFilename = o['photo'] != null && String(o['photo']).trim() !== '' ? String(o['photo']).trim() : undefined;
  const photoData = o['photo_data'] != null ? String(o['photo_data']) : '';
  const extraPhotos = Array.isArray(o['photos']) ? (o['photos'] as Record<string, unknown>[]) : [];
  if (photoData.trim() !== '') {
    try {
      const bytes = b64ToBytes(photoData);
      if (bytes.length < 4) throw new Error('too short');
      if (!photoFilename) {
        photoFilename = `${uid ?? 'imported'}.jpg`;
        warn(`${title}: photo_data had no photo filename; synthesized "${photoFilename}" (Paprika requires one)`);
      }
      warn(`${title}: embedded photo (${bytes.length} bytes) validated; photo binary must be uploaded to the media store separately`);
    } catch {
      warn(`${title}: photo_data is not valid base64; photo skipped`);
    }
  } else if (photoFilename) {
    warn(`${title}: photo filename "${photoFilename}" references no embedded data; photo skipped`);
  }
  if (extraPhotos.length > 0) {
    warn(`${title}: ${extraPhotos.length} extra photo(s) have no gallery field; raw preserved`);
  }

  // Flags / misc -> warnings sidecar (no model change).
  const fav = o['on_favorites'];
  if (fav === true || fav === 1 || fav === '1' || String(fav).toLowerCase() === 'yes') {
    warn(`${title}: on_favorites set; no favorites field (YAML import ignores it entirely)`);
  }
  if (o['scale'] != null && String(o['scale']).trim() !== '') {
    warn(`${title}: scale "${String(o['scale'])}" has no field; raw preserved`);
  }
  const cookbook = o['cookbook'] ?? o['cookbooks'];
  let categories = asStringArray(o['categories']);
  if (cookbook != null && String(cookbook).trim() !== '' && !categories.includes(String(cookbook).trim())) {
    categories = [...categories, String(cookbook).trim()];
    warn(`${title}: cookbook "${String(cookbook).trim()}" folded into categories (no cookbook field)`);
  }
  const created = o['created'] ?? o['dateAdded'];
  if (created != null && String(created).trim() !== '') {
    warn(`${title}: created "${String(created).trim()}" display-only; import stamps its own updatedAt`);
  }
  const trash = o['in_trash'] ?? o['deleted'];
  if (trash === true || trash === 1 || trash === '1') {
    warn(`${title}: flagged in_trash/deleted in Paprika; imported as active (delete explicitly if unwanted)`);
  }

  const input = {
    title,
    description: combinedDescription,
    servings: servings.servings,
    prepMinutes: prep.minutes,
    cookMinutes: cook.minutes,
    rating,
    source,
    sourceUrl,
    categories,
    ingredients,
    steps,
  };
  return { input, uid, photoFilename, warnings, rawKeys };
}

// ---------- .paprikarecipes container handling ----------

const GZIP_MAGIC = [0x1f, 0x8b];

function isGzip(data: Uint8Array): boolean {
  return data.length >= 2 && data[0] === GZIP_MAGIC[0] && data[1] === GZIP_MAGIC[1];
}

function isZip(data: Uint8Array): boolean {
  return data.length >= 4 && data[0] === 0x50 && data[1] === 0x4b && (data[2] === 0x03 || data[2] === 0x05 || data[2] === 0x07);
}

/** Split a concatenated gzip stream on the gzip magic (spec §1.1 order 4). */
function splitGzipMembers(data: Uint8Array): Uint8Array[] {
  const starts: number[] = [];
  for (let i = 0; i + 2 < data.length; i++) {
    if (data[i] === 0x1f && data[i + 1] === 0x8b && data[i + 2] === 0x08) {
      // Avoid re-matching bytes inside deflate payloads: only accept a magic
      // that starts where the previous member's stream would plausibly begin.
      // Simplest robust rule: accept every magic offset; gunzip failures on
      // interior false positives are filtered by JSON validation downstream.
      starts.push(i);
    }
  }
  if (starts.length <= 1) return [data];
  return starts.map((s, i) => data.subarray(s, i + 1 < starts.length ? starts[i + 1] : data.length));
}

export interface UnpackedPaprikaFile {
  name: string;
  jsonText: string;
}

/**
 * Unpack raw bytes in spec §1.1 order: ZIP -> bare gzip -> bare JSON ->
 * concatenated gzip stream. Returns one JSON text per recipe.
 */
export async function unpackPaprikaBytes(data: Uint8Array, fallbackName = 'import'): Promise<UnpackedPaprikaFile[]> {
  // 1. ZIP of *.paprikarecipe (each gzip JSON, fallback plain JSON).
  if (isZip(data)) {
    const entries = await unzipEntries(data);
    const out: UnpackedPaprikaFile[] = [];
    for (const e of entries) {
      if (isGzip(e.data)) {
        try {
          out.push({ name: e.name, jsonText: utf8Decode(await gunzipBytes(e.data)) });
          continue;
        } catch {
          // fall through to raw-JSON attempt
        }
      }
      out.push({ name: e.name, jsonText: utf8Decode(e.data) });
    }
    return out;
  }
  // 2. Bare gzip single (+ 4. concatenated gzip stream). Split on the magic
  // first: a multi-member stream gunzips to concatenated JSON (unparseable),
  // so each member must be decoded separately. If any member fails, fall
  // back to whole-stream gunzip (the extra magic was inside deflate data).
  if (isGzip(data)) {
    const members = splitGzipMembers(data);
    if (members.length > 1) {
      const out: UnpackedPaprikaFile[] = [];
      let failed = false;
      for (let i = 0; i < members.length; i++) {
        try {
          out.push({ name: `${fallbackName}-${i + 1}`, jsonText: utf8Decode(await gunzipBytes(members[i]!)) });
        } catch {
          failed = true;
        }
      }
      if (out.length > 0 && !failed) return out;
      // else fall through to whole-stream attempt below
    }
    try {
      return [{ name: fallbackName, jsonText: utf8Decode(await gunzipBytes(data)) }];
    } catch {
      throw new Error('single .paprikarecipe is not valid gzip JSON');
    }
  }
  // 3. Bare JSON (defensive; some tooling re-exports decompressed).
  return [{ name: fallbackName, jsonText: utf8Decode(data) }];
}

/** Parse unpacked JSON texts (object or array each) via parsePaprikaJson. */
export function parsePaprikaJsonTexts(files: UnpackedPaprikaFile[]): ParsedPaprikaRecipe[] {
  const out: ParsedPaprikaRecipe[] = [];
  for (const f of files) {
    let json: unknown;
    try {
      json = JSON.parse(f.jsonText);
    } catch {
      out.push({
        input: null,
        warnings: [`${f.name}: not valid JSON; skipped`],
        rawKeys: [],
      });
      continue;
    }
    const items = Array.isArray(json) ? json : [json];
    if (items.length === 0) {
      out.push({ input: null, warnings: [`${f.name}: empty recipe list; skipped`], rawKeys: [] });
    }
    for (const item of items) {
      const parsed = parsePaprikaJson(item);
      parsed.warnings = parsed.warnings.map((w) => `${f.name}: ${w}`);
      out.push(parsed);
    }
  }
  return out;
}

// ---------- YAML import (15-field subset; JSON-as-YAML also valid) ----------

function stripYamlComment(line: string): string {
  // Drop trailing unquoted `#` comments (keep `#` inside quotes/flow).
  let inS = false;
  let inD = false;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (ch === "'" && !inD) inS = !inS;
    else if (ch === '"' && !inS) {
      if (line[i - 1] !== '\\') inD = !inD;
    } else if (ch === '#' && !inS && !inD && (i === 0 || /\s/.test(line[i - 1]!))) {
      return line.slice(0, i);
    }
  }
  return line;
}

function parseYamlScalar(raw: string): unknown {
  const s = raw.trim().replace(/,$/, '').trim();
  if (s === '' || s === '~' || s.toLowerCase() === 'null') return null;
  const low = s.toLowerCase();
  if (['yes', 'true', 'on'].includes(low)) return true;
  if (['no', 'false', 'off'].includes(low)) return false;
  if (/^-?\d+$/.test(s)) return Number(s);
  if (/^-?\d*\.\d+$/.test(s)) return Number(s);
  if ((s.startsWith('"') && s.endsWith('"')) || (s.startsWith("'") && s.endsWith("'"))) {
    const inner = s.slice(1, -1);
    return s.startsWith('"') ? inner.replace(/\\"/g, '"').replace(/\\n/g, '\n').replace(/\\\\/g, '\\') : inner.replace(/''/g, "'");
  }
  if (s.startsWith('[') && s.endsWith(']')) {
    const inner = s.slice(1, -1).trim();
    if (!inner) return [];
    return inner.split(',').map((p) => parseYamlScalar(p) as string);
  }
  return s;
}

/**
 * Minimal YAML subset parser for Paprika's 15 fields: top-level mapping or
 * list of mappings, `key: value`, `key: |`/`>` block scalars, `[a, b]` flow
 * lists, `#` comments. Anything fancier should be exported as JSON-as-YAML
 * (which this also accepts via JSON.parse first).
 */
export function parseYamlSubset(text: string): unknown {
  const src = text.replace(/^\uFEFF/, '');
  const trimmed = src.trim();
  if (!trimmed) throw new Error('empty YAML document');
  // JSON is valid YAML.
  if (trimmed.startsWith('{') || trimmed.startsWith('[')) return JSON.parse(trimmed);

  const lines = src.replace(/\r\n?/g, '\n').split('\n');
  // Determine top-level shape: list (`- `) or mapping.
  const firstMeaningful = lines.find((l) => l.trim() !== '' && !l.trim().startsWith('#'));
  if (!firstMeaningful) throw new Error('empty YAML document');
  const isList = /^\s*-\s/.test(firstMeaningful);

  const parseBlock = (blockLines: string[], baseIndent: number): Record<string, unknown> => {
    const obj: Record<string, unknown> = {};
    let i = 0;
    while (i < blockLines.length) {
      const raw = blockLines[i]!;
      const noComment = stripYamlComment(raw);
      if (noComment.trim() === '') {
        i++;
        continue;
      }
      const indent = noComment.match(/^(\s*)/)![1]!.length;
      if (indent < baseIndent) break;
      const m = noComment.match(/^\s*([^:]+?)\s*:\s*(.*)$/);
      if (!m) {
        i++;
        continue;
      }
      const key = m[1]!.trim();
      const rest = m[2]!.trim();
      if (rest === '|' || rest === '>' || rest === '|-' || rest === '>-' || rest === '|+' || rest === '>+') {
        // Block scalar: consume more-indented lines.
        const buf: string[] = [];
        let j = i + 1;
        let childIndent = -1;
        while (j < blockLines.length) {
          const bl = blockLines[j]!;
          if (bl.trim() === '') {
            buf.push('');
            j++;
            continue;
          }
          const bi = bl.match(/^(\s*)/)![1]!.length;
          if (bi <= indent) break;
          if (childIndent < 0) childIndent = bi;
          buf.push(bl.slice(childIndent));
          j++;
        }
        // Trim trailing empties; literal keeps newlines, folded joins.
        while (buf.length > 0 && buf[buf.length - 1] === '') buf.pop();
        obj[key] = rest.startsWith('>') ? buf.join(' ').replace(/\s+/g, ' ').trim() : buf.join('\n');
        i = j;
        continue;
      }
      if (rest === '') {
        // Possibly a nested block or an empty value; collect indented children.
        const childLines: string[] = [];
        let j = i + 1;
        while (j < blockLines.length) {
          const bl = blockLines[j]!;
          if (bl.trim() === '') {
            j++;
            continue;
          }
          const bi = stripYamlComment(bl).match(/^(\s*)/)![1]!.length;
          if (bi <= indent) break;
          childLines.push(bl);
          j++;
        }
        if (childLines.length > 0 && /^\s*-\s/.test(stripYamlComment(childLines[0]!))) {
          obj[key] = childLines
            .map((cl) => stripYamlComment(cl).replace(/^\s*-\s*/, '').trim())
            .filter((s) => s !== '')
            .map((s) => parseYamlScalar(s) as string);
        } else if (childLines.length > 0) {
          obj[key] = parseBlock(childLines, indent + 1);
        } else {
          obj[key] = null;
        }
        i = j;
        continue;
      }
      obj[key] = parseYamlScalar(rest);
      i++;
    }
    return obj;
  };

  if (!isList) return parseBlock(lines, 0);
  // Top-level list: split on `^- ` at indent 0.
  const items: Record<string, unknown>[] = [];
  let current: string[] = [];
  for (const line of lines) {
    if (/^-\s/.test(line) && current.length > 0) {
      items.push(parseBlock(current, 0));
      current = [];
    }
    current.push(line.replace(/^-(\s)/, ' $1').replace(/^-$/, ' '));
  }
  if (current.length > 0) items.push(parseBlock(current, 0));
  return items;
}

/** Translate YAML keys onto native Paprika JSON keys, then map. */
export function parsePaprikaYaml(text: string): ParsedPaprikaRecipe[] {
  let doc: unknown;
  try {
    doc = parseYamlSubset(text);
  } catch (e) {
    return [{ input: null, warnings: [`YAML: ${(e as Error).message}; skipped`], rawKeys: [] }];
  }
  const items = Array.isArray(doc) ? doc : [doc];
  return items.map((item, i) => {
    const o = (item ?? {}) as Record<string, unknown>;
    const translated: Record<string, unknown> = { ...o };
    // YAML `photo` (base64) ~= native `photo_data`.
    if (translated['photo'] != null && translated['photo_data'] == null) {
      translated['photo_data'] = translated['photo'];
      delete translated['photo'];
    }
    const parsed = parsePaprikaJson(translated);
    parsed.warnings = parsed.warnings.map((w) => `yaml[${i}]: ${w}`);
    return parsed;
  });
}

// ---------- HTML import (JSON-LD -> hRecipe -> headings) ----------

function stripTags(html: string): string {
  return html
    .replace(/<script[\s\S]*?<\/script\s*>/gi, '')
    .replace(/<style[\s\S]*?<\/style\s*>/gi, '')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&apos;/g, "'")
    .replace(/&nbsp;/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function findAllRecipeJsonLd(html: string): Record<string, unknown>[] {
  const re = /<script[^>]*type=["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script\s*>/gi;
  let m: RegExpExecArray | null;
  const candidates: unknown[] = [];
  while ((m = re.exec(html)) !== null) {
    try {
      const json = JSON.parse(m[1]!);
      if (Array.isArray(json)) candidates.push(...json);
      else if (json && typeof json === 'object' && Array.isArray((json as Record<string, unknown>)['@graph'])) {
        candidates.push(...((json as Record<string, unknown>)['@graph'] as unknown[]));
      } else candidates.push(json);
    } catch {
      // ignore unparseable blocks
    }
  }
  return candidates.filter((c) => {
    const o = c as Record<string, unknown>;
    const type = o['@type'];
    return type === 'Recipe' || (Array.isArray(type) && type.includes('Recipe'));
  }) as Record<string, unknown>[];
}

function findRecipeJsonLd(html: string): Record<string, unknown> | null {
  return findAllRecipeJsonLd(html)[0] ?? null;
}

function schemaOrgToPaprika(ld: Record<string, unknown>): Record<string, unknown> {
  const instr = ld['recipeInstructions'] ?? ld['instructions'];
  let directions = '';
  if (typeof instr === 'string') directions = instr;
  else if (Array.isArray(instr)) {
    directions = instr
      .map((s) => {
        if (typeof s === 'string') return s;
        const o = s as Record<string, unknown>;
        return String(o['text'] ?? o['name'] ?? '');
      })
      .filter(Boolean)
      .join('\n');
  }
  const ings = ld['recipeIngredient'] ?? ld['ingredients'];
  const ingredients = Array.isArray(ings) ? ings.map(String).join('\n') : String(ings ?? '');
  const timeToText = (v: unknown): string => {
    if (v == null) return '';
    const s = String(v);
    const mins = /^P/i.test(s) ? parseIsoDuration(s) : parseMinutes(s).minutes;
    return mins !== null && mins !== undefined ? `${mins} min` : s;
  };
  const cats = ld['recipeCategory'] ?? ld['keywords'];
  const ratingRaw = (ld['aggregateRating'] as Record<string, unknown> | undefined)?.['ratingValue'];
  return {
    name: ld['name'] ?? '',
    description: ld['description'] ?? '',
    ingredients,
    directions,
    servings: ld['recipeYield'] ?? '',
    prep_time: timeToText(ld['prepTime']),
    cook_time: timeToText(ld['cookTime']),
    total_time: timeToText(ld['totalTime']),
    categories: Array.isArray(cats) ? cats.map(String) : cats != null ? String(cats).split(',').map((s) => s.trim()).filter(Boolean) : [],
    rating: ratingRaw !== undefined ? Number(ratingRaw) : 0,
    source: ld['author'] != null && typeof ld['author'] === 'object' ? String((ld['author'] as Record<string, unknown>)['name'] ?? '') : String(ld['author'] ?? ''),
    source_url: ld['url'] ?? ld['mainEntityOfPage'] ?? '',
  };
}

function extractByClass(html: string, classNames: string[]): string[] {
  const out: string[] = [];
  for (const cls of classNames) {
    const re = new RegExp(
      `<([a-zA-Z][a-zA-Z0-9]*)[^>]*class=["'][^"']*\\b${cls}\\b[^"']*["'][^>]*>([\\s\\S]*?)<\\/\\1\\s*>`,
      'gi',
    );
    let m: RegExpExecArray | null;
    while ((m = re.exec(html)) !== null) {
      const text = stripTags(m[2]!);
      if (text) out.push(text);
    }
  }
  return out;
}

function extractSectionList(html: string, headings: string[]): string[] {
  for (const h of headings) {
    const sec = new RegExp(`<h[1-6][^>]*>\\s*${h}\\s*<\\/h[1-6]\\s*>([\\s\\S]*?)(?=<h[1-6][^>]*>|$)`, 'i').exec(html);
    if (!sec) continue;
    const items: string[] = [];
    const li = /<li[^>]*>([\s\S]*?)<\/li\s*>/gi;
    let m: RegExpExecArray | null;
    while ((m = li.exec(sec[1]!)) !== null) {
      const text = stripTags(m[1]!);
      if (text) items.push(text);
    }
    if (items.length > 0) return items;
    // Fallback: <p>/<br> separated text in the section.
    const text = stripTags(sec[1]!)
      .split(/\n+/)
      .map((s) => s.trim())
      .filter(Boolean);
    if (text.length > 0) return text;
  }
  return [];
}

/** Parse a Paprika HTML export page/file into Paprika-JSON-shaped objects. */
export function parsePaprikaHtml(html: string, docName = 'index.html'): ParsedPaprikaRecipe[] {
  const warnings: string[] = [];
  let mapped: Record<string, unknown> | null = null;

  // 1. Prefer JSON-LD Recipe blocks (Paprika 4+ / schema.org). Accumulate
  // EVERY block so a multi-recipe HTML export round-trips all of them.
  const lds = findAllRecipeJsonLd(html);
  if (lds.length > 0) {
    return lds.map((ld, i) => {
      const parsed = parsePaprikaJson(schemaOrgToPaprika(ld));
      parsed.warnings = [
        `${docName}: parsed recipe ${i + 1}/${lds.length} via JSON-LD Recipe block`,
        ...parsed.warnings.map((w) => `${docName}: ${w}`),
      ];
      return parsed;
    });
  }
  // 2. hRecipe / h-recipe microformats (Paprika <=3 / Windows).
    const fns = extractByClass(html, ['fn', 'p-name']);
    const ings = extractByClass(html, ['ingredient', 'p-ingredient']);
    const instr = extractByClass(html, ['instructions', 'e-instructions', 'p-instructions']);
    const yields = extractByClass(html, ['yield', 'p-yield']);
    const summaries = extractByClass(html, ['summary', 'p-summary']);
    const authors = extractByClass(html, ['author', 'p-author']);
    const tags = extractByClass(html, ['tag', 'p-category']);
    if (fns.length > 0 || (ings.length > 0 && instr.length > 0)) {
      mapped = {
        name: fns[0] ?? '',
        description: summaries[0] ?? '',
        ingredients: ings.join('\n'),
        directions: instr.join('\n'),
        servings: yields[0] ?? '',
        categories: tags,
        source: authors[0] ?? '',
      };
      warnings.push(`${docName}: parsed via hRecipe microformat classes`);
    } else {
      // 3. Visible headings (Ingredients/Directions/Notes).
      const name = /<h1[^>]*>([\s\S]*?)<\/h1\s*>/i.exec(html);
      const ingsH = extractSectionList(html, ['ingredients', 'ingredient']);
      const dirsH = extractSectionList(html, ['directions', 'instructions', 'method', 'preparation', 'steps']);
      const notesH = extractSectionList(html, ['notes?', 'note']);
      if (ingsH.length > 0 || dirsH.length > 0) {
        mapped = {
          name: name ? stripTags(name[1]!) : '',
          ingredients: ingsH.join('\n'),
          directions: dirsH.join('\n'),
          notes: notesH.join('\n'),
        };
        warnings.push(`${docName}: parsed via visible headings fallback (verify field mapping)`);
      }
    }

  if (!mapped) {
    return [{ input: null, warnings: [`${docName}: no JSON-LD, hRecipe, or heading structure found; skipped`], rawKeys: [] }];
  }
  const parsed = parsePaprikaJson(mapped);
  parsed.warnings = [...warnings, ...parsed.warnings.map((w) => `${docName}: ${w}`)];
  return [parsed];
}

// ---------- Keep Cooking -> Paprika (export) ----------

function sanitizeExportName(title: string, used: Set<string>): string {
  const base = (title || 'recipe').replace(/[\\/:*?"<>|]/g, '_').replace(/\s+/g, ' ').trim().slice(0, 80) || 'recipe';
  let name = `${base}.paprikarecipe`;
  let n = 2;
  while (used.has(name)) {
    name = `${base}-${n}.paprikarecipe`;
    n++;
  }
  used.add(name);
  return name;
}

function minutesToText(mins: number | null | undefined): string {
  if (mins === null || mins === undefined) return '';
  if (mins < 60) return `${mins} minutes`;
  const h = Math.floor(mins / 60);
  const m = mins % 60;
  return m === 0 ? `${h} hour${h === 1 ? '' : 's'}` : `${h} hour${h === 1 ? '' : 's'} ${m} minutes`;
}

function createdStamp(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getUTCFullYear()}-${p(d.getUTCMonth() + 1)}-${p(d.getUTCDate())} ${p(d.getUTCHours())}:${p(d.getUTCMinutes())}:${p(d.getUTCSeconds())}`;
}

/** Map a Keep Cooking recipe onto a Paprika native JSON object. */
export function recipeToPaprika(r: Recipe): Record<string, unknown> {
  const uid =
    ((r as unknown as Record<string, unknown>)['paprikaUid'] as string | undefined) ??
    (/^[0-9a-fA-F-]{36}$/.test(r.id) ? r.id.toUpperCase() : crypto.randomUUID().toUpperCase());
  const ingredients = r.ingredients
    .slice()
    .sort((a, b) => a.position - b.position)
    .map((g) => g.display || g.name)
    .join('\n');
  const directions = r.steps
    .slice()
    .sort((a, b) => a.position - b.position)
    .map((s) => s.text)
    .join('\n');
  return {
    uid,
    // `hash` is Paprika's sync change-detection hash; it recomputes on
    // import, so a placeholder is safe.
    hash: '',
    name: r.title,
    description: r.description ?? '',
    ingredients,
    directions,
    notes: '',
    categories: r.categories ?? [],
    servings: String(r.servings ?? ''),
    prep_time: minutesToText(r.prepMinutes),
    cook_time: minutesToText(r.cookMinutes),
    total_time: '',
    difficulty: '',
    rating: r.rating ?? 0,
    nutritional_info: '',
    source: r.source ?? '',
    source_url: r.sourceUrl ?? '',
    image_url: null,
    // No binary photo store in the API layer: omit photo_data (exporting a
    // filename without data is worse than omitting both). When photo_data is
    // ever present, `photo` MUST be a filename (`${UID}.jpg` synthesized).
    photo: null,
    photo_large: null,
    photo_hash: '',
    created: createdStamp(r.updatedAt),
    on_favorites: false,
  };
}

/** Export recipes as a .paprikarecipes ZIP (one gzip-JSON member each). */
export async function exportPaprika(recipes: Recipe[]): Promise<Uint8Array> {
  const used = new Set<string>();
  const members = await Promise.all(
    recipes.map(async (r) => ({
      name: sanitizeExportName(r.title, used),
      data: await gzipBytes(utf8Encode(JSON.stringify(recipeToPaprika(r)))),
    })),
  );
  return zipStore(members);
}

/** Export one recipe as a single .paprikarecipe (gzip JSON) member. */
export async function exportSinglePaprikaRecipe(r: Recipe): Promise<Uint8Array> {
  return gzipBytes(utf8Encode(JSON.stringify(recipeToPaprika(r))));
}

/**
 * Export recipes as YAML. Strategy per spec §2: serialize as JSON
 * (single object, or array for many) with a YAML-compatible extension —
 * valid YAML with zero indentation risk.
 */
export function exportYaml(recipes: Recipe[]): string {
  const objs = recipes.map(recipeToPaprika);
  return JSON.stringify(objs.length === 1 ? objs[0] : objs, null, 2) + '\n';
}
