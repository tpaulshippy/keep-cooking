// Photo helpers — R2 keys + signed GET URLs (<15min expiry).
// Variants per packages/contracts/PHOTO_VARIANTS.md:
//   photos/{recipeId}/original.jpg | 1024.jpg | thumb.jpg

export const PHOTO_VARIANTS = ['original', '1024', 'thumb'] as const;
export const MAX_SIGNED_URL_TTL_SECONDS = 15 * 60;
export const DEFAULT_SIGNED_URL_TTL_SECONDS = 10 * 60;

export interface PhotoKeys {
  original: string;
  large1024: string;
  thumb: string;
}

/** Canonical R2 keys for a recipe's photo variants. */
export function variantKeys(recipeId: string): PhotoKeys {
  const base = `photos/${recipeId}`;
  return {
    original: `${base}/original.jpg`,
    large1024: `${base}/1024.jpg`,
    thumb: `${base}/thumb.jpg`,
  };
}

function toHex(buf: ArrayBuffer): string {
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/**
 * Sign an R2 object key. Returns a URL valid for `ttlSeconds` (<15min enforced).
 * Uses HMAC-SHA256 over `key:exp` with the app secret. The URL targets
 * GET /photos/dl, which serves the bytes after verifying the signature
 * (see route in index.ts); no PII in URL.
 */
export async function signKey(
  key: string,
  opts: { secret: string; baseUrl: string; ttlSeconds?: number; nowMs?: number },
): Promise<{ url: string; expiresAt: string; key: string }> {
  const ttl = Math.min(opts.ttlSeconds ?? DEFAULT_SIGNED_URL_TTL_SECONDS, MAX_SIGNED_URL_TTL_SECONDS - 1);
  const exp = Math.floor((opts.nowMs ?? Date.now()) / 1000) + ttl;
  const data = new TextEncoder().encode(`${key}:${exp}`);
  const cryptoKey = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(opts.secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const sig = toHex(await crypto.subtle.sign('HMAC', cryptoKey, data));
  const base = opts.baseUrl.replace(/\/$/, '');
  // Single-serve: the byte route is mounted at /api/photos/dl. A prod base
  // already ends in /api; a bare origin (dev/test) needs the prefix so the
  // minted URL hits the serving route in every environment.
  const prefix = base.endsWith('/api') ? '' : '/api';
  return {
    url: `${base}${prefix}/photos/dl?key=${encodeURIComponent(key)}&exp=${exp}&sig=${sig}`,
    expiresAt: new Date(exp * 1000).toISOString(),
    key,
  };
}

/** Verify a signature produced by signKey. */
export async function verifySignature(key: string, exp: number, sig: string, secret: string): Promise<boolean> {
  if (!key || !exp || !sig) return false;
  if (exp * 1000 < Date.now() - 1000) return false; // expired
  if (exp * 1000 - Date.now() > MAX_SIGNED_URL_TTL_SECONDS * 1000) return false; // over max TTL
  const data = new TextEncoder().encode(`${key}:${exp}`);
  const cryptoKey = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const expected = toHex(await crypto.subtle.sign('HMAC', cryptoKey, data));
  return expected.length === sig.length && expected === sig;
}
