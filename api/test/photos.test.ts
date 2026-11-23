import { describe, it, expect } from 'vitest';
import { signKey, verifySignature, variantKeys, MAX_SIGNED_URL_TTL_SECONDS } from '../src/photos';
import { makeApp, req } from './helpers';

describe('photos', () => {
  it('variantKeys follow PHOTO_VARIANTS.md', () => {
    const k = variantKeys('abc123');
    expect(k).toEqual({
      original: 'photos/abc123/original.jpg',
      large1024: 'photos/abc123/1024.jpg',
      thumb: 'photos/abc123/thumb.jpg',
    });
  });

  it('signed URL expiry is < 15min and verifies', async () => {
    const now = Date.now();
    const s = await signKey('photos/abc/original.jpg', { secret: 's', baseUrl: 'https://api.smidgen.local', ttlSeconds: 3600 });
    const expMs = new Date(s.expiresAt).getTime();
    expect(expMs - now).toBeLessThan(MAX_SIGNED_URL_TTL_SECONDS * 1000);
    const u = new URL(s.url);
    expect(u.searchParams.get('key')).toBe('photos/abc/original.jpg');
    const ok = await verifySignature(u.searchParams.get('key')!, Number(u.searchParams.get('exp')), u.searchParams.get('sig')!, 's');
    expect(ok).toBe(true);
    const bad = await verifySignature('photos/abc/original.jpg', Number(u.searchParams.get('exp')), 'deadbeef', 's');
    expect(bad).toBe(false);
  });

  it('GET /photos/sign + /photos/variants', async () => {
    const { app } = await makeApp({ seed: false });
    const v = await req(app, 'GET', '/photos/variants?recipeId=r1');
    expect((await v.json()) as object).toHaveProperty('thumb', 'photos/r1/thumb.jpg');
    const s = await req(app, 'GET', '/photos/sign?key=photos%2Fr1%2Fthumb.jpg');
    expect(s.status).toBe(200);
    const body = (await s.json()) as { url: string; expiresAt: string };
    expect(new Date(body.expiresAt).getTime() - Date.now()).toBeLessThan(15 * 60 * 1000);
  });
});
