// POST /api/import handler logic: parse third-party recipe payloads by
// format and persist via store.createRecipe (uid upsert for native Paprika).
// P1 formats (mx2/mxp/mz2/mmf/fdx/fdxz/pepperplate/copymethat/yum) return 415
// with re-export guidance until their parsers land.

import type { Store } from './store';
import { parseOrThrow, recipeInputSchema } from './zod';
import {
  parsePaprikaHtml,
  parsePaprikaJson,
  parsePaprikaJsonTexts,
  parsePaprikaYaml,
  unpackPaprikaBytes,
  type ParsedPaprikaRecipe,
} from './paprika';

export type ImportFormat =
  | 'paprika-json'
  | 'paprika-zip'
  | 'yaml'
  | 'html'
  | 'mx2'
  | 'mxp'
  | 'mz2'
  | 'mmf'
  | 'fdx'
  | 'fdxz'
  | 'pepperplate'
  | 'copymethat'
  | 'yum';

/** P1 formats: accepted by the detector, rejected with re-export guidance. */
export const P1_REEXPORT_GUIDANCE: Record<string, string> = {
  mx2: 'MasterCook .mx2 import is not supported yet; in MasterCook use File → Export and Mail → MC 5+ / MZ2 and retry when the importer lands.',
  mxp: 'MasterCook .mxp import is not supported yet; in MasterCook use File → Export and Mail → MC 5+ / MZ2 and retry when the importer lands.',
  mz2: 'MasterCook .mz2 import is not supported yet; in MasterCook use File → Export and Mail → MC 5+ / MZ2 and retry when the importer lands.',
  mmf: 'MealMaster .mmf import is not supported yet; re-export from your app as Paprika .paprikarecipes or YAML in the meantime.',
  fdx: 'Living Cookbook .fdx import is not supported yet; in Living Cookbook use File → Export → .fdx again when the importer lands (the native .lcb database is never readable).',
  fdxz: 'Living Cookbook .fdxz import is not supported yet; gunzip it to .fdx and retry when the importer lands (the native .lcb database is never readable).',
  pepperplate: 'Pepperplate import is not supported yet; use Profile → Export Recipe Data (.zip of .txt files) and retry when the importer lands.',
  copymethat: 'Copy Me That import is not supported yet; use More → Download recipes → All recipes → HTML and retry when the importer lands.',
  yum: "Yum .xml import is not supported yet; re-export from Yum as text and import as Paprika YAML in the meantime (one recipe per document, 15 fields).",
};

export interface ImportRequest {
  /** Explicit format override; otherwise detected from filename/content. */
  format?: string;
  /** Original filename (drives format detection + per-recipe names). */
  filename?: string;
  /** File bytes (multipart upload or base64-decoded payload). */
  bytes?: Uint8Array;
  /** Decoded text body (alternative to bytes for text formats). */
  text?: string;
  householdId?: string;
}

export interface ImportResult {
  imported: number;
  ids: string[];
  warnings: string[];
}

/** Detect the import format from filename and/or content sniffing. */
export function detectImportFormat(req: ImportRequest): ImportFormat {
  const explicit = (req.format ?? '').toLowerCase().trim().replace(/[_.]/g, '-');
  const known: ImportFormat[] = [
    'paprika-json',
    'paprika-zip',
    'yaml',
    'html',
    'mx2',
    'mxp',
    'mz2',
    'mmf',
    'fdx',
    'fdxz',
    'pepperplate',
    'copymethat',
    'yum',
  ];
  if ((known as string[]).includes(explicit)) return explicit as ImportFormat;
  // Aliases users actually send.
  const alias: Record<string, ImportFormat> = {
    paprikarecipes: 'paprika-zip',
    paprikarecipe: 'paprika-zip',
    zip: 'paprika-zip',
    json: 'paprika-json',
    yml: 'yaml',
    htm: 'html',
    pepperplatezip: 'pepperplate',
    'copy-me-that': 'copymethat',
  };
  if (alias[explicit]) return alias[explicit]!;
  const name = (req.filename ?? '').toLowerCase();
  if (/\.paprikarecipes$/.test(name) || /\.paprikarecipe$/.test(name)) return 'paprika-zip';
  if (/\.ya?ml$/.test(name)) return 'yaml';
  if (/\.html?$/.test(name)) return 'html';
  if (/\.json$/.test(name)) return 'paprika-json';
  for (const ext of ['mx2', 'mxp', 'mz2', 'mmf', 'fdxz', 'fdx', 'yum'] as const) {
    if (name.endsWith(`.${ext}`)) return ext;
  }
  // Content sniffing when no filename helps.
  const bytes = req.bytes;
  if (bytes && bytes.length >= 4) {
    if (bytes[0] === 0x50 && bytes[1] === 0x4b) return 'paprika-zip';
    if (bytes[0] === 0x1f && bytes[1] === 0x8b) return 'paprika-zip';
  }
  const text = req.text ?? (bytes ? new TextDecoder('utf-8', { fatal: false }).decode(bytes.subarray(0, 4096)) : '');
  const head = text.trimStart().slice(0, 200).toLowerCase();
  if (head.startsWith('{') || head.startsWith('[')) return 'paprika-json';
  if (/<(!doctype html|html|script[^>]*ld\+json|div[^>]*hrecipe)/.test(head)) return 'html';
  return 'yaml';
}

function httpError(status: number, message: string): Error & { status: number } {
  const err = new Error(message) as Error & { status: number };
  err.status = status;
  return err;
}

/** Parse the request payload into Paprika-mapped recipes (no persistence). */
export async function parseImportPayload(req: ImportRequest): Promise<ParsedPaprikaRecipe[]> {
  const format = detectImportFormat(req);
  const p1 = P1_REEXPORT_GUIDANCE[format];
  if (p1) throw httpError(415, p1);

  const textOf = (): string => {
    if (req.text !== undefined) return req.text;
    if (req.bytes) return new TextDecoder('utf-8').decode(req.bytes);
    return '';
  };

  switch (format) {
    case 'paprika-json': {
      const text = textOf().trim();
      if (!text) throw httpError(400, 'empty import payload');
      let json: unknown;
      try {
        json = JSON.parse(text);
      } catch {
        throw httpError(400, 'paprika-json payload is not valid JSON');
      }
      const items = Array.isArray(json) ? json : [json];
      return items.map((item) => parsePaprikaJson(item));
    }
    case 'paprika-zip': {
      if (!req.bytes || req.bytes.length === 0) throw httpError(400, 'paprika-zip import requires file bytes');
      const files = await unpackPaprikaBytes(req.bytes, (req.filename ?? 'import').replace(/\.[^.]+$/, '') || 'import').catch(
        (e) => {
          throw httpError(400, `cannot unpack Paprika archive: ${(e as Error).message}`);
        },
      );
      return parsePaprikaJsonTexts(files);
    }
    case 'yaml': {
      const text = textOf();
      if (!text.trim()) throw httpError(400, 'empty YAML payload');
      return parsePaprikaYaml(text);
    }
    case 'html': {
      const text = textOf();
      if (!text.trim()) throw httpError(400, 'empty HTML payload');
      return parsePaprikaHtml(text, req.filename ?? 'index.html');
    }
    default:
      throw httpError(400, `unsupported import format "${req.format ?? ''}"`);
  }
}

/**
 * Full import: parse + persist each recipe via createRecipe (uid upsert:
 * a stored recipe with the Paprika uid is updated in place, else created
 * with the uid as its id for re-import idempotency). Invalid recipes are
 * skipped with a warning; unparseable payloads throw 4xx.
 */
export async function runImport(
  store: Store,
  req: ImportRequest,
  meta: { deviceId: string; householdId: string },
): Promise<ImportResult> {
  const parsed = await parseImportPayload(req);
  const warnings: string[] = [];
  const ids: string[] = [];
  let imported = 0;
  for (const p of parsed) {
    warnings.push(...p.warnings);
    if (!p.input) continue; // already warned (e.g. bad JSON member)
    let input: unknown;
    try {
      input = parseOrThrow(recipeInputSchema, { ...p.input, householdId: meta.householdId });
    } catch (e) {
      warnings.push(`${p.input?.title ?? 'recipe'}: validation failed (${(e as Error).message}); skipped`);
      continue;
    }
    const existing = p.uid ? await store.getRecipe(p.uid).catch(() => null) : null;
    if (existing) {
      const updated = await store.updateRecipe(existing.id, input, { deviceId: meta.deviceId });
      if (updated) {
        ids.push(updated.id);
        imported++;
      }
    } else {
      const created = await store.createRecipe(input, {
        deviceId: meta.deviceId,
        ...(p.uid ? { id: p.uid } : {}),
      });
      ids.push(created.id);
      imported++;
    }
  }
  return { imported, ids, warnings };
}
