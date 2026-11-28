// Outbox push: attempts each queued envelope against the API and acks ONLY
// envelopes whose mutation actually succeeded, by (id, updatedAt) identity.
// A failed envelope stops the run; it and everything behind it stay queued.
// Update-404 falls back to create + reconcile (the server assigns its own
// id), so offline-created records never duplicate on a later pull. Delete-404
// counts as success (nothing left to delete).

import { Store, type EntityKind, type SyncEnvelope } from './store';

export interface ServerRecord {
  id: string;
  updatedAt?: string;
  deviceId?: string;
  [k: string]: unknown;
}

export interface PushTransport {
  update(entity: EntityKind, id: string, input: Record<string, unknown>): Promise<ServerRecord>;
  create(entity: EntityKind, input: Record<string, unknown>): Promise<ServerRecord>;
  remove(entity: EntityKind, id: string): Promise<void>;
}

/** Strip envelope metadata the client stored alongside pulled payloads. */
export function toRecordInput(payload: unknown): Record<string, unknown> {
  if (payload === null || typeof payload !== 'object' || Array.isArray(payload)) return {};
  const { id: _i, updatedAt: _u, deviceId: _d, deleted: _t, entity: _e, ...input } = payload as Record<string, unknown>;
  return input;
}

function toEnvelope(env: SyncEnvelope, record: ServerRecord): SyncEnvelope {
  return {
    id: record.id ?? env.id,
    updatedAt: typeof record.updatedAt === 'string' ? record.updatedAt : env.updatedAt,
    deviceId: typeof record.deviceId === 'string' ? record.deviceId : env.deviceId,
    entity: env.entity,
    payload: record,
  };
}

function isNotFound(err: unknown): boolean {
  const msg = err instanceof Error ? err.message : String(err);
  return /(^|\D)404(\D|$)/.test(msg);
}

export interface PushResult { pushed: number; failed: boolean; }

export async function pushOutbox(store: Store, transport: PushTransport): Promise<PushResult> {
  const pending = [...store.state.outbox];
  let pushed = 0;
  for (const env of pending) {
    try {
      const input = toRecordInput(env.payload);
      if (env.deleted) {
        try {
          await transport.remove(env.entity, env.id);
        } catch (err) {
          if (!isNotFound(err)) throw err; // 404: already gone counts as success
        }
        store.drainOutbox([{ id: env.id, updatedAt: env.updatedAt }]);
        pushed++;
        continue;
      }
      try {
        const record = await transport.update(env.entity, env.id, input);
        store.applyRemote(toEnvelope(env, record));
        store.drainOutbox([{ id: env.id, updatedAt: env.updatedAt }]);
      } catch (err) {
        if (!isNotFound(err)) throw err;
        const record = await transport.create(env.entity, input);
        const server = toEnvelope(env, record);
        store.reconcileLocalId(env.id, server);
        store.drainOutbox([{ id: server.id, updatedAt: env.updatedAt }]);
      }
      pushed++;
    } catch {
      return { pushed, failed: true }; // stop: this envelope and the rest stay queued
    }
  }
  return { pushed, failed: false };
}
