import { createApp } from '../src/index';
import { MemoryStore } from '../src/store';
import { seedStore } from '../seed';

export async function makeApp(opts: { seed?: boolean } = {}) {
  const store = new MemoryStore();
  if (opts.seed !== false) await seedStore(store);
  const app = createApp(store, { baseUrl: 'https://api.keepcooking.local', secret: 'test-secret' });
  return { app, store };
}

export function headers(role: 'owner' | 'member' | 'viewer' = 'owner', user?: string) {
  const u = user ?? (role === 'owner' ? 'u-owner' : role === 'member' ? 'u-member' : 'u-viewer');
  return { 'x-user-id': u, 'x-role': role, 'x-device-id': 'test-device', 'content-type': 'application/json' };
}

export async function req(
  app: ReturnType<typeof createApp>,
  method: string,
  path: string,
  opts: { body?: unknown; role?: 'owner' | 'member' | 'viewer'; headers?: Record<string, string> } = {},
) {
  const h = { ...headers(opts.role ?? 'owner'), ...(opts.headers ?? {}) };
  return app.request(path, {
    method,
    headers: h,
    body: opts.body === undefined ? undefined : JSON.stringify(opts.body),
  });
}
