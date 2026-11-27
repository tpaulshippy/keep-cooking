-- Keep Cooking D1 schema v0.1.0 — must stay 1:1 with SwiftData models + openapi.yaml
-- Sync: id TEXT PK (uuid), updated_at TEXT ISO8601, device_id TEXT, deleted INTEGER 0/1 (tombstone), last-write-wins on updated_at.

CREATE TABLE IF NOT EXISTS households (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE TABLE IF NOT EXISTS memberships (
  household_id TEXT NOT NULL REFERENCES households(id),
  user_id TEXT NOT NULL,
  role TEXT NOT NULL CHECK (role IN ('owner','member','viewer')),
  PRIMARY KEY (household_id, user_id)
);
CREATE TABLE IF NOT EXISTS recipes (
  id TEXT PRIMARY KEY,
  household_id TEXT NOT NULL REFERENCES households(id),
  title TEXT NOT NULL,
  description TEXT DEFAULT '',
  servings REAL DEFAULT 4,
  prep_minutes INTEGER,
  cook_minutes INTEGER,
  rating REAL CHECK (rating IS NULL OR (rating >= 0 AND rating <= 5)),
  source TEXT DEFAULT '',
  source_url TEXT DEFAULT '',
  categories TEXT DEFAULT '[]',
  photo_original TEXT, photo_large1024 TEXT, photo_thumb TEXT,
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  device_id TEXT NOT NULL DEFAULT '',
  deleted INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS ingredients (
  id TEXT PRIMARY KEY,
  recipe_id TEXT NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
  name TEXT NOT NULL, quantity REAL, unit TEXT DEFAULT '',
  display TEXT DEFAULT '', position INTEGER DEFAULT 0
);
CREATE TABLE IF NOT EXISTS steps (
  id TEXT PRIMARY KEY,
  recipe_id TEXT NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
  position INTEGER NOT NULL, text TEXT NOT NULL, timers TEXT DEFAULT '[]'
);
CREATE TABLE IF NOT EXISTS shopping_lists (
  id TEXT PRIMARY KEY, household_id TEXT NOT NULL REFERENCES households(id),
  name TEXT NOT NULL,
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  device_id TEXT NOT NULL DEFAULT '', deleted INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS list_items (
  id TEXT PRIMARY KEY,
  list_id TEXT NOT NULL REFERENCES shopping_lists(id) ON DELETE CASCADE,
  name TEXT NOT NULL, quantity TEXT DEFAULT '', aisle TEXT DEFAULT '',
  checked INTEGER DEFAULT 0, recipe_id TEXT REFERENCES recipes(id)
);
CREATE TABLE IF NOT EXISTS pantry_items (
  id TEXT PRIMARY KEY, household_id TEXT NOT NULL REFERENCES households(id),
  name TEXT NOT NULL, quantity TEXT DEFAULT '', location TEXT DEFAULT '',
  expires_at TEXT, low_threshold TEXT DEFAULT '', barcode TEXT DEFAULT '',
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  device_id TEXT NOT NULL DEFAULT '', deleted INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS plans (
  id TEXT PRIMARY KEY, household_id TEXT NOT NULL REFERENCES households(id),
  date TEXT NOT NULL, meal TEXT NOT NULL CHECK (meal IN ('breakfast','lunch','dinner','snack')),
  recipe_id TEXT REFERENCES recipes(id), note TEXT DEFAULT '', servings REAL,
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  device_id TEXT NOT NULL DEFAULT '', deleted INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS menus (
  id TEXT PRIMARY KEY, household_id TEXT NOT NULL REFERENCES households(id),
  name TEXT NOT NULL, entries TEXT DEFAULT '[]',
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
  device_id TEXT NOT NULL DEFAULT '', deleted INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS share_links (
  id TEXT PRIMARY KEY, household_id TEXT NOT NULL REFERENCES households(id),
  recipe_ids TEXT NOT NULL DEFAULT '[]', url TEXT NOT NULL, expires_at TEXT NOT NULL
);
-- Key-only agent auth (#26): verifier = hex(SHA256(raw agent token)), a
-- one-way hash — never key material. PK is the unguessable householdHash.
CREATE TABLE IF NOT EXISTS agent_enrollments (
  household_hash TEXT PRIMARY KEY,
  household_id TEXT NOT NULL REFERENCES households(id),
  verifier TEXT NOT NULL,
  updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_enrollments_verifier ON agent_enrollments(verifier);
CREATE INDEX IF NOT EXISTS idx_recipes_household ON recipes(household_id);
CREATE INDEX IF NOT EXISTS idx_ingredients_recipe ON ingredients(recipe_id);
CREATE INDEX IF NOT EXISTS idx_steps_recipe ON steps(recipe_id);
CREATE INDEX IF NOT EXISTS idx_plans_date ON plans(household_id, date);
