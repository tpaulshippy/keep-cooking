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
  let calls: { url: string; method?: string; body: string }[];

  beforeEach(() => {
    localStorage.clear();
    calls = [];
    globalThis.fetch = (async (url: unknown, init?: { method?: string; body?: string }) => {
      calls.push({ url: String(url), method: init?.method, body: String(init?.body ?? '') });
      return { ok: true, status: 200, json: async () => ({}) };
    }) as typeof fetch;
  });

  afterEach(() => {
    globalThis.fetch = realFetch;
  });

  it('POSTs the public key on first enroll, then skips when flagged', async () => {
    const id1 = await enrollDevice('web', 'https://x.test/api');
    expect(calls).toHaveLength(1);
    expect(calls[0].url).toBe('https://x.test/api/v2/devices');
    expect(calls[0].method).toBe('POST');
    const body = JSON.parse(calls[0].body) as { deviceId: string; publicKey: string };
    expect(body.deviceId).toBe(id1);
    // base64 of exactly 32 raw Ed25519 bytes.
    expect(body.publicKey).toMatch(/^[A-Za-z0-9+/]{43}=$/);
    expect(isEnrolled('https://x.test/api')).toBe(true);

    const id2 = await enrollDevice('web', 'https://x.test/api');
    expect(calls).toHaveLength(1); // no second POST
    expect(id2).toBe(id1);
  });

  it('a locally-known device id without the flag still POSTs', async () => {
    localStorage.setItem('kc.deviceId', 'pre-existing-id');
    const id = await enrollDevice('web', 'https://x.test/api');
    expect(calls).toHaveLength(1);
    expect(calls[0].method).toBe('POST');
    // The stored id is reused (not rotated) so offline envelopes stamped
    // with it stay attributable.
    expect(id).toBe('pre-existing-id');
    const body = JSON.parse(calls[0].body) as { deviceId: string; publicKey: string };
    expect(body.deviceId).toBe('pre-existing-id');
    expect(body.publicKey).toMatch(/^[A-Za-z0-9+/]{43}=$/);
    expect(isEnrolled('https://x.test/api')).toBe(true);
  });

  it('enrolls per API base: switching bases POSTs again with the same identity', async () => {
    const idA = await enrollDevice('web', 'https://a.test/api');
    expect(calls).toHaveLength(1);
    expect(calls[0].method).toBe('POST');

    const idB = await enrollDevice('web', 'https://b.test/api');
    expect(calls).toHaveLength(2);
    expect(calls[1].url).toBe('https://b.test/api/v2/devices');
    expect(calls[1].method).toBe('POST');
    expect(idB).toBe(idA); // same identity, newly enrolled on the new backend
    expect(isEnrolled('https://a.test/api')).toBe(true);
    expect(isEnrolled('https://b.test/api')).toBe(true);

    const again = await enrollDevice('web', 'https://a.test/api');
    expect(calls).toHaveLength(2); // no repeat POST once each base is flagged
    expect(again).toBe(idA);
  });

  it('rotates identity and retries once on 409, then throws on a second 409', async () => {
    let n = 0;
    globalThis.fetch = (async (url: unknown, init?: { method?: string; body?: string }) => {
      calls.push({ url: String(url), method: init?.method, body: String(init?.body ?? '') });
      n += 1;
      if (n === 1) return { ok: false, status: 409, json: async () => ({}) };
      return { ok: true, status: 200, json: async () => ({}) };
    }) as typeof fetch;

    const id = await enrollDevice('web', 'https://x.test/api');
    expect(calls).toHaveLength(2);
    expect(calls[0].method).toBe('POST');
    expect(calls[1].method).toBe('POST');
    const first = JSON.parse(calls[0].body) as { deviceId: string };
    const second = JSON.parse(calls[1].body) as { deviceId: string };
    expect(second.deviceId).toBe(id);
    expect(second.deviceId).not.toBe(first.deviceId);
    expect(isEnrolled('https://x.test/api')).toBe(true);

    // A repeated 409 is terminal.
    localStorage.clear();
    calls = [];
    globalThis.fetch = (async (url: unknown, init?: { method?: string; body?: string }) => {
      calls.push({ url: String(url), method: init?.method, body: String(init?.body ?? '') });
      return { ok: false, status: 409, json: async () => ({}) };
    }) as typeof fetch;
    await expect(enrollDevice('web', 'https://x.test/api')).rejects.toThrow('enroll failed: 409');
    expect(calls).toHaveLength(2); // initial attempt + exactly one retry
  });
});
