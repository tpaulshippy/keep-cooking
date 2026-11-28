import { describe, expect, it, beforeEach, afterEach } from 'vitest';
import { signingPathFor, buildUrl, enrollDevice, isEnrolled } from './api';

if (typeof localStorage === 'undefined') {
  const mem = new Map<string, string>();
  (globalThis as Record<string, unknown>).localStorage = {
    getItem: (k: string) => (mem.has(k) ? mem.get(k)! : null),
    setItem: (k: string, v: string) => void mem.set(k, String(v)),
    removeItem: (k: string) => void mem.delete(k),
    clear: () => mem.clear(),
  };
}

describe('signingPathFor', () => {
  it('canonical equals the sent path under an /api base', () => {
    const base = 'https://keepcooking.app/api';
    expect(signingPathFor(base, '/recipes')).toBe('/api/recipes');
    expect(signingPathFor(base, '/recipes/abc')).toBe('/api/recipes/abc');
    expect(signingPathFor(base, '/recipes?page=2')).toBe('/api/recipes?page=2');
    // req() signs buildUrl(...).pathname+search and fetches the same URL.
    for (const p of ['/recipes', '/recipes/abc', '/lists']) {
      const url = buildUrl(base, p);
      expect(signingPathFor(base, p)).toBe(url.pathname + url.search);
    }
  });

  it('works for local dev bases too', () => {
    expect(signingPathFor('http://localhost:8787/api', '/recipes')).toBe('/api/recipes');
  });
});

describe('enrollDevice', () => {
  const realFetch = globalThis.fetch;
  let calls: { url: string; body: string }[];

  beforeEach(() => {
    localStorage.clear();
    calls = [];
    globalThis.fetch = (async (url: unknown, init?: { body?: string }) => {
      calls.push({ url: String(url), body: String(init?.body ?? '') });
      return { ok: true, json: async () => ({}) };
    }) as typeof fetch;
  });

  afterEach(() => {
    globalThis.fetch = realFetch;
  });

  it('POSTs the public key on first enroll, then skips when flagged', async () => {
    const id1 = await enrollDevice('web', 'https://x.test/api');
    expect(calls).toHaveLength(1);
    expect(calls[0].url).toBe('https://x.test/api/v2/devices');
    const body = JSON.parse(calls[0].body) as { deviceId: string; publicKey: string };
    expect(body.deviceId).toBe(id1);
    // base64 of exactly 32 raw Ed25519 bytes.
    expect(body.publicKey).toMatch(/^[A-Za-z0-9+/]{43}=$/);
    expect(isEnrolled()).toBe(true);

    const id2 = await enrollDevice('web', 'https://x.test/api');
    expect(calls).toHaveLength(1); // no second POST
    expect(id2).toBe(id1);
  });

  it('a locally-known device id without the flag still POSTs', async () => {
    localStorage.setItem('kc.deviceId', 'pre-existing-id');
    await enrollDevice('web', 'https://x.test/api');
    expect(calls).toHaveLength(1);
    expect(isEnrolled()).toBe(true);
  });
});
