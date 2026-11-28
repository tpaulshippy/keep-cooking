-- Keep Cooking editor metadata backfill (#48): D1 databases created
-- from an older schema.sql have a recipes table without the editor
-- metadata columns (difficulty, cookbooks, total_minutes, notes,
-- nutrition_text). Fresh DBs already get the columns from 0001_init.sql
-- (CREATE TABLE IF NOT EXISTS), so this file is a one-time backfill for
-- those older DBs.
--
-- Canonical migration chain: apply drizzle/0001_init.sql, then
-- 0002_e2e_blobs.sql, 0003_device_keys.sql, 0004_agent_enrollments.sql,
-- 0005_is_favorite.sql, then this file (0006).
-- (`npm run db:apply:local` / `db:apply:remote` do all in order;
-- scripts/deploy-backend.sh applies the same order.)
--
-- Re-apply note: SQLite has no ADD COLUMN IF NOT EXISTS, so re-running
-- this file on a DB that already has the columns fails with
-- "duplicate column name". That failure is benign — the deploy scripts
-- tolerate it (see deploy-backend.sh / package.json).
-- Prefer running once per DB; re-runs are safe to ignore.
ALTER TABLE recipes ADD COLUMN difficulty TEXT DEFAULT '';
ALTER TABLE recipes ADD COLUMN cookbooks TEXT DEFAULT '[]';
ALTER TABLE recipes ADD COLUMN total_minutes INTEGER;
ALTER TABLE recipes ADD COLUMN notes TEXT DEFAULT '';
ALTER TABLE recipes ADD COLUMN nutrition_text TEXT DEFAULT '';
