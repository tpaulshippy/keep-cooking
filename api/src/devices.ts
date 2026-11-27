import type { Context } from 'hono';
import { base64ByteLength } from './e2e';
import { deviceKeysEqual, decodePublicKeyB64, type Store } from './store';

// POST /v2/devices — device enrollment (Pass 1 sketch).
// NOT wired into createApp here: route wiring is owned by the api-auth lane.
// Expected body: { deviceId: UUIDv4, publicKey: base64(32B Ed25519), displayName?: <=64 }.
// Responses: 201 { deviceId, enrolledAt } on first enroll,
// 200 { deviceId, enrolledAt } on idempotent re-enroll (same key),
// 409 on same deviceId with a different key, 400 on validation failure.

const UUIDV4_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export async function devicesEnroll(c: Context, store: Store): Promise<Response> {
  const body = (await c.req.json().catch(() => ({}))) as {
    deviceId?: unknown;
    publicKey?: unknown;
    displayName?: unknown;
  };
  const { deviceId, publicKey, displayName } = body;
  if (typeof deviceId !== 'string' || !UUIDV4_RE.test(deviceId)) {
    return c.json({ error: 'deviceId must be UUIDv4' }, 400);
  }
  if (typeof publicKey !== 'string' || base64ByteLength(publicKey) !== 32) {
    return c.json({ error: 'publicKey must be base64 of exactly 32 bytes' }, 400);
  }
  if (displayName !== undefined && (typeof displayName !== 'string' || displayName.length > 64)) {
    return c.json({ error: 'displayName must be a string of at most 64 chars' }, 400);
  }
  const incoming = decodePublicKeyB64(publicKey);
  const existing = await store.getDevice(deviceId);
  if (existing && !deviceKeysEqual(existing.publicKey, incoming)) {
    return c.json({ error: 'device already enrolled with different key' }, 409);
  }
  try {
    const res = await store.enrollDevice({
      deviceId,
      publicKeyB64: publicKey,
      ...(typeof displayName === 'string' ? { displayName } : {}),
    });
    return c.json(res, existing ? 200 : 201);
  } catch (e) {
    const status = (e as { status?: unknown } | null | undefined)?.status;
    if (status === 409) return c.json({ error: 'device already enrolled with different key' }, 409);
    throw e;
  }
}
