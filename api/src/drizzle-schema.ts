import { sqliteTable, text, integer, real, primaryKey, uniqueIndex } from 'drizzle-orm/sqlite-core';

// Drizzle schema — 1:1 with packages/contracts/schema.sql (D1).
// Migrations live in drizzle/0001_init.sql (verbatim schema.sql).

export const households = sqliteTable('households', {
  id: text('id').primaryKey(),
  name: text('name').notNull(),
  createdAt: text('created_at').notNull(),
});

export const memberships = sqliteTable('memberships', {
  householdId: text('household_id').notNull(),
  userId: text('user_id').notNull(),
  role: text('role').notNull(),
});

export const recipes = sqliteTable('recipes', {
  id: text('id').primaryKey(),
  householdId: text('household_id').notNull(),
  title: text('title').notNull(),
  description: text('description').default(''),
  servings: real('servings').default(4),
  prepMinutes: integer('prep_minutes'),
  cookMinutes: integer('cook_minutes'),
  rating: real('rating'),
  source: text('source').default(''),
  sourceUrl: text('source_url').default(''),
  categories: text('categories').default('[]'),
  photoOriginal: text('photo_original'),
  photoLarge1024: text('photo_large1024'),
  photoThumb: text('photo_thumb'),
  updatedAt: text('updated_at').notNull(),
  deviceId: text('device_id').notNull().default(''),
  deleted: integer('deleted').notNull().default(0),
});

export const ingredients = sqliteTable('ingredients', {
  id: text('id').primaryKey(),
  recipeId: text('recipe_id').notNull(),
  name: text('name').notNull(),
  quantity: real('quantity'),
  unit: text('unit').default(''),
  display: text('display').default(''),
  position: integer('position').default(0),
});

export const steps = sqliteTable('steps', {
  id: text('id').primaryKey(),
  recipeId: text('recipe_id').notNull(),
  position: integer('position').notNull(),
  text: text('text').notNull(),
  timers: text('timers').default('[]'),
});

export const shoppingLists = sqliteTable('shopping_lists', {
  id: text('id').primaryKey(),
  householdId: text('household_id').notNull(),
  name: text('name').notNull(),
  updatedAt: text('updated_at').notNull(),
  deviceId: text('device_id').notNull().default(''),
  deleted: integer('deleted').notNull().default(0),
});

export const listItems = sqliteTable('list_items', {
  id: text('id').primaryKey(),
  listId: text('list_id').notNull(),
  name: text('name').notNull(),
  quantity: text('quantity').default(''),
  aisle: text('aisle').default(''),
  checked: integer('checked').default(0),
  recipeId: text('recipe_id'),
});

export const pantryItems = sqliteTable('pantry_items', {
  id: text('id').primaryKey(),
  householdId: text('household_id').notNull(),
  name: text('name').notNull(),
  quantity: text('quantity').default(''),
  location: text('location').default(''),
  expiresAt: text('expires_at'),
  lowThreshold: text('low_threshold').default(''),
  barcode: text('barcode').default(''),
  updatedAt: text('updated_at').notNull(),
  deviceId: text('device_id').notNull().default(''),
  deleted: integer('deleted').notNull().default(0),
});

export const plans = sqliteTable('plans', {
  id: text('id').primaryKey(),
  householdId: text('household_id').notNull(),
  date: text('date').notNull(),
  meal: text('meal').notNull(),
  recipeId: text('recipe_id'),
  note: text('note').default(''),
  servings: real('servings'),
  updatedAt: text('updated_at').notNull(),
  deviceId: text('device_id').notNull().default(''),
  deleted: integer('deleted').notNull().default(0),
});

export const menus = sqliteTable('menus', {
  id: text('id').primaryKey(),
  householdId: text('household_id').notNull(),
  name: text('name').notNull(),
  entries: text('entries').default('[]'),
  updatedAt: text('updated_at').notNull(),
  deviceId: text('device_id').notNull().default(''),
  deleted: integer('deleted').notNull().default(0),
});

export const shareLinks = sqliteTable('share_links', {
  id: text('id').primaryKey(),
  householdId: text('household_id').notNull(),
  recipeIds: text('recipe_ids').notNull().default('[]'),
  url: text('url').notNull(),
  expiresAt: text('expires_at').notNull(),
});

// E2E V1 blind blobs: PK (household_hash, id); header JSON carries the
// plaintext routing header only, ciphertext stays opaque to the server.
export const syncBlobsV2 = sqliteTable('sync_blobs_v2', {
  householdHash: text('household_hash').notNull(),
  id: text('id').notNull(),
  header: text('header').notNull(),
  ciphertext: text('ciphertext').notNull(),
  updatedAt: text('updated_at').notNull(),
}, (t) => ({
  pk: primaryKey({ columns: [t.householdHash, t.id] }),
}));

// Key-only agent enrollments (#26): verifier is hex(SHA256(raw token)) —
// a one-way hash, never key material. PK is the unguessable householdHash.
// household_id carries a UNIQUE index (one label → one bucket; re-binding
// revokes the old hash first) and verifier carries one too (one token → one
// bucket) — mirrors 0004_agent_enrollments.sql + schema.sql.
export const agentEnrollments = sqliteTable('agent_enrollments', {
  householdHash: text('household_hash').primaryKey(),
  householdId: text('household_id').notNull(),
  verifier: text('verifier').notNull(),
  updatedAt: text('updated_at').notNull(),
}, (t) => ({
  verifierIdx: uniqueIndex('idx_agent_enrollments_verifier').on(t.verifier),
  labelIdx: uniqueIndex('idx_agent_enrollments_household_id').on(t.householdId),
}));

// Device keys: 1:1 with drizzle/0003_device_keys.sql (D1). device_id is the
// PK; re-enroll with the same key is idempotent, a different key for the
// same device_id is a 409, and re-enrolling a revoked device is a 410.
export const deviceKeys = sqliteTable('device_keys', {
  deviceId: text('device_id').primaryKey(),
  publicKey: text('public_key').notNull(),
  displayName: text('display_name'),
  createdAt: text('created_at').notNull(),
  revokedAt: text('revoked_at'),
});
