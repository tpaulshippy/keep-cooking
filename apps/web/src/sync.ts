// Outbox push: attempts each queued envelope against the API and acks ONLY
// envelopes whose mutation actually succeeded, by (id, updatedAt) identity.
// A failed envelope stops the run; it and everything behind it stay queued.
// Update-404 falls back to create + reconcile (the server assigns its own
// id), but only for ids never observed from the server: a 404 for a
// server-known id with no uncertain match means another device deleted it,
// so the local record collapses to a tombstone (deleted, drained, never
// recreated). Delete-404 counts as success (nothing left to delete).
//
// Retry-safety (no contract changes available — RecipeInput carries no client
// idempotency key and the server stamps its own id/updatedAt): before
// creating, a 404-envelope first lists server records and adopts an
// EXACT-SINGLE match (same deviceId, byte-identical household-scoped content
// signature, and exactly one local peer with that content). That covers the committed-create-
// lost-response case. Zero or 2+ matches, or an already-ambiguous local state
// (e.g. two intentional same-content drafts), fall back to create — the
// status-quo duplicate risk, never a wrong merge.

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
  list(entity: EntityKind): Promise<ServerRecord[]>;
}

/** Strip envelope metadata the client stored alongside pulled payloads. */
export function toRecordInput(payload: unknown): Record<string, unknown> {
  if (payload === null || typeof payload !== 'object' || Array.isArray(payload)) return {};
  const { id: _i, updatedAt: _u, deviceId: _d, deleted: _t, entity: _e, ...input } = payload as Record<string, unknown>;
  return input;
}

/** Canonical content string for cross-id duplicate detection. Both sides are
 * normalized so server defaults ('' / 4 / regenerated child ids) match.
 * householdId is part of every signature: same content in different
 * households (e.g. personal + shared on one device) must never false-match.
 * More fields = fewer adoptions; a missed match falls back to create, the
 * status-quo risk, never a wrong merge. */
export function contentSignature(entity: EntityKind, input: Record<string, unknown>): string {
  const household = input.householdId ?? '';
  switch (entity) {
    case 'recipe': {
      const ings = (input.ingredients as Array<Record<string, unknown>> | undefined) ?? [];
      const steps = (input.steps as Array<Record<string, unknown> | string> | undefined) ?? [];
      return JSON.stringify({
        h: household,
        t: input.title ?? '',
        s: input.servings ?? 4,
        i: ings.map((g) => [g.name ?? '', g.quantity ?? null, g.unit ?? '', g.display ?? '']),
        st: steps.map((s) => (s !== null && typeof s === 'object' ? (s.text ?? '') : s)),
      });
    }
    case 'list': {
      const items = (input.items as Array<Record<string, unknown>> | undefined) ?? [];
      return JSON.stringify({
        h: household,
        n: input.name ?? '',
        i: items.map((it) => [it.name ?? '', it.quantity ?? '', it.aisle ?? '']),
      });
    }
    case 'pantryItem':
      return JSON.stringify({ h: household, n: input.name ?? '', q: input.quantity ?? '', l: input.location ?? '' });
    case 'plan':
      return JSON.stringify({
        h: household,
        d: input.date ?? '', m: input.meal ?? '', r: input.recipeId ?? null,
        n: input.note ?? '', s: input.servings ?? null,
      });
    case 'menu': {
      const entries = (input.entries as Array<Record<string, unknown>> | undefined) ?? [];
      return JSON.stringify({
        h: household,
        n: input.name ?? '',
        e: entries.map((e) => [e.dayOffset ?? 0, e.meal ?? '', e.recipeId ?? '', e.servings ?? null]),
      });
    }
  }
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

function envIdentity(env: Pick<SyncEnvelope, 'id' | 'updatedAt'>): Pick<SyncEnvelope, 'id' | 'updatedAt'> {
  return { id: env.id, updatedAt: env.updatedAt };
}

function isNotFound(err: unknown): boolean {
  const msg = err instanceof Error ? err.message : String(err);
  return /(^|\D)404(\D|$)/.test(msg);
}

/**
 * Find a previously-committed server record for a 404-envelope: exactly one
 * same-device, same-content server record not attributable to another local,
 * with exactly one local peer holding that content. Anything ambiguous (or a
 * failed list when offline) yields null → caller creates as before.
 */
export async function findUncertainMatch(
  store: Store,
  list: (entity: EntityKind) => Promise<ServerRecord[]>,
  env: SyncEnvelope,
): Promise<ServerRecord | null> {
  let records: ServerRecord[];
  try {
    records = await list(env.entity);
  } catch {
    return null;
  }
  const sig = contentSignature(env.entity, toRecordInput(env.payload));
  const localPeers = (
    store.state[store.collectionKey(env.entity)] as SyncEnvelope[]
  ).filter((e) => contentSignature(env.entity, toRecordInput(e.payload)) === sig);
  if (localPeers.length !== 1) return null; // intentional duplicates stay duplicates
  const hits = records.filter(
    (r) => r.deviceId === env.deviceId && contentSignature(env.entity, toRecordInput(r)) === sig,
  );
  return hits.length === 1 ? hits[0] : null;
}

async function pushOne(
  store: Store,
  transport: PushTransport,
  listed: Map<EntityKind, ServerRecord[] | null>,
  env: SyncEnvelope,
): Promise<boolean> {
  const input = toRecordInput(env.payload);
  if (env.deleted) {
    try {
      await transport.remove(env.entity, env.id);
    } catch (err) {
      if (!isNotFound(err)) return false; // 404: already gone counts as success
    }
    store.drainOutbox([envIdentity(env)]);
    return true;
  }
  try {
    const record = await transport.update(env.entity, env.id, input);
    // The echo carries a fresh server timestamp: merging it blindly would
    // LWW-clobber a newer local revision of the same record still queued
    // behind this envelope (and that revision's follow-up push would then
    // look stale). The collection already holds the newer local content, so
    // when siblings remain queued, acknowledge this envelope without merging
    // its echo; the sibling's own push applies its echo in turn.
    const hasQueuedNewer = store.state.outbox.some(
      (e) => e !== env && e.entity === env.entity && e.id === env.id,
    );
    if (!hasQueuedNewer) {
      store.applyRemote(toEnvelope(env, record), { pruneSuperseded: false });
    }
    store.drainOutbox([envIdentity(env)]);
    return true;
  } catch (err) {
    if (!isNotFound(err)) return false;
  }
  // Update-404: either a fresh offline record or a retry after a lost create
  // response. Never resurrect something deleted locally while offline.
  const col = store.state[store.collectionKey(env.entity)] as SyncEnvelope[];
  if (col.some((e) => e.id === env.id && e.deleted)) {
    store.drainOutbox([envIdentity(env)]); // the queued tombstone handles the server
    return true;
  }
  try {
    if (!listed.has(env.entity)) {
      try {
        listed.set(env.entity, await transport.list(env.entity));
      } catch {
        return false; // offline: retry later
      }
    }
    const adopted = await findUncertainMatch(store, async () => listed.get(env.entity) ?? [], env);
    if (adopted) {
      const server = toEnvelope(env, adopted);
      store.reconcileLocalId(env.id, server, { pruneSuperseded: false });
      store.drainOutbox([{ id: server.id, updatedAt: env.updatedAt }]);
      return true;
    }
    // No uncertain match. If this id was previously observed from the server
    // (pulled or echoed — not a purely local create), the 404 means another
    // device deleted it after this device's offline edit. Recreating under a
    // new id would resurrect the deletion, so honor the remote delete: collapse
    // the local record to a tombstone and drain without creating. deleted=true
    // filters the record from views while the envelope still LWW-merges like
    // any tombstone; pruneSuperseded:false leaves any newer queued revisions
    // to 404-and-drain explicitly on their own turn rather than vanishing.
    if (store.isServerKnown(env.entity, env.id)) {
      store.applyRemote(
        {
          id: env.id,
          updatedAt: new Date().toISOString(),
          deviceId: env.deviceId,
          deleted: true,
          entity: env.entity,
          payload: {},
        },
        { pruneSuperseded: false },
      );
      store.drainOutbox([envIdentity(env)]);
      return true;
    }
    const record = await transport.create(env.entity, input);
    const server = toEnvelope(env, record);
    store.reconcileLocalId(env.id, server, { pruneSuperseded: false });
    store.drainOutbox([{ id: server.id, updatedAt: env.updatedAt }]);
    return true;
  } catch {
    return false;
  }
}

export interface PushResult { pushed: number; failed: boolean; }

// In-flight push per store: a second concurrent pushOutbox (e.g.
// double-clicking Push) joins the running one instead of draining the queue
// twice and duplicating 404-to-create records. Released in finally so a
// throw can never wedge later pushes.
const inFlight = new WeakMap<Store, Promise<PushResult>>();

export function pushOutbox(store: Store, transport: PushTransport): Promise<PushResult> {
  const running = inFlight.get(store);
  if (running) return running;
  const run = (async (): Promise<PushResult> => {
    try {
      const listed = new Map<EntityKind, ServerRecord[] | null>();
      let pushed = 0;
      // Always take the live head: an earlier reconcile in this run rewrites
      // pending ids, and rewritten revisions must be pushed in the same run.
      // Every success path drains its envelope, so this always terminates.
      for (;;) {
        const env = store.state.outbox[0];
        if (!env) break;
        if (await pushOne(store, transport, listed, env)) pushed++;
        else return { pushed, failed: true }; // stop: this envelope and the rest stay queued
      }
      return { pushed, failed: false };
    } finally {
      inFlight.delete(store);
    }
  })();
  inFlight.set(store, run);
  return run;
}
