package com.keepcooking.app

import androidx.room.Room
import androidx.sqlite.db.SupportSQLiteDatabase
import androidx.sqlite.db.SupportSQLiteOpenHelper
import androidx.sqlite.db.framework.FrameworkSQLiteOpenHelperFactory
import com.keepcooking.app.data.AppDatabase
import com.keepcooking.app.data.MIGRATION_2_3
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

/**
 * MIGRATION_2_3 regression test (robolectric, hermetic file DB, no network):
 * a v2 `recipes` table (all v2 columns, i.e. current columns minus
 * nutritionText) migrates to v3 with the row intact and
 * nutritionText == '', and Room opens the migrated file without a schema
 * validation failure (the Room-side counterpart of the
 * `@ColumnInfo(defaultValue = "''")` annotation).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], manifest = Config.NONE)
class Migration23Test {

    @Test
    fun `migrate 2 to 3 preserves rows with empty nutritionText and passes Room validation`() = runTest {
        val context = RuntimeEnvironment.getApplication()
        val dbName = "migration23-test.db"
        context.getDatabasePath(dbName).delete()

        // Canonical v3 DDL + identity hash straight from Room so every
        // non-recipes table matches Room's expected schema exactly.
        val reference = Room.inMemoryDatabaseBuilder(
            context,
            AppDatabase::class.java,
        ).allowMainThreadQueries().build()
        val refDb = reference.openHelper.writableDatabase
        val v3Ddl = mutableListOf<Pair<String, String>>()
        refDb.query(
            "SELECT name, sql FROM sqlite_master " +
                "WHERE type = 'table' AND name NOT IN " +
                "('android_metadata', 'room_master_table', 'sqlite_sequence')",
            emptyArray(),
        ).use { c ->
            while (c.moveToNext()) {
                v3Ddl += c.getString(0) to c.getString(1)
            }
        }
        val identityHash = refDb.query(
            "SELECT identity_hash FROM room_master_table WHERE id = 42 LIMIT 1",
            emptyArray(),
        ).use { c ->
            assertTrue("reference Room db has an identity hash", c.moveToFirst())
            c.getString(0)
        }
        reference.close()
        assertTrue("reference schema covers recipes", v3Ddl.any { it.first == "recipes" })

        // v2 schema = v3 schema minus the nutritionText column.
        val v2Ddl = v3Ddl.map { (name, sql) ->
            if (name != "recipes") return@map sql
            val stripped = stripNutritionTextColumn(sql)
            assertTrue(
                "stripped v2 recipes DDL drops nutritionText: $sql",
                !stripped.contains("nutritionText"),
            )
            stripped
        }

        val factory = FrameworkSQLiteOpenHelperFactory()
        val callback = object : SupportSQLiteOpenHelper.Callback(2) {
            override fun onCreate(db: SupportSQLiteDatabase) {
                v2Ddl.forEach { db.execSQL(it) }
            }

            override fun onUpgrade(db: SupportSQLiteDatabase, oldVersion: Int, newVersion: Int) = Unit
        }
        val helper = factory.create(
            SupportSQLiteOpenHelper.Configuration.builder(context)
                .name(dbName)
                .callback(callback)
                .build(),
        )
        val db = helper.writableDatabase
        db.execSQL(
            "INSERT INTO recipes (id, householdId, title, recipeDescription, servings, " +
                "prepMinutes, cookMinutes, rating, isFavorite, source, sourceUrl, " +
                "categoriesJson, photoOriginal, photoLarge1024, photoThumb, " +
                "updatedAt, deviceId, deleted) VALUES " +
                "('r1', 'hh-demo', 'Soup', 'Tasty.', 4.0, 10, 20, 4.5, 0, " +
                "'src', 'https://src', '[]', NULL, NULL, NULL, 1700000000000, 'd1', 0)",
        )

        // The migration under test: ADD COLUMN with DEFAULT ''.
        MIGRATION_2_3.migrate(db)

        // Row survives with the backfill default.
        db.query("SELECT nutritionText FROM recipes WHERE id = 'r1'", emptyArray()).use { c ->
            assertTrue("migrated row is present", c.moveToFirst())
            assertEquals("", c.getString(0))
        }

        // Stamp Room metadata + version so the follow-up Room open validates
        // the migrated schema instead of re-running the migration.
        db.execSQL("CREATE TABLE IF NOT EXISTS room_master_table (id INTEGER PRIMARY KEY, identity_hash TEXT)")
        db.execSQL(
            "INSERT OR REPLACE INTO room_master_table (id, identity_hash) VALUES (42, ?)",
            arrayOf(identityHash),
        )
        db.version = 3
        helper.close()

        // Must not throw "Room cannot verify the data integrity" (or any
        // IllegalStateException): this is what fails without the
        // @ColumnInfo(defaultValue = "''") annotation on upgraded databases.
        val migrated = Room.databaseBuilder(
            context,
            AppDatabase::class.java,
            dbName,
        ).addMigrations(MIGRATION_2_3).allowMainThreadQueries().build()
        val row = migrated.recipes().byId("r1")
        assertNotNull("migrated row readable via Room", row)
        assertEquals("", row!!.nutritionText)
        migrated.close()

        context.getDatabasePath(dbName).delete()
    }

    /**
     * Drops the nutritionText column definition Room generates for v3
     * ("`nutritionText` TEXT NOT NULL DEFAULT ''", backtick- or
     * double-quote-quoted) from a CREATE TABLE statement.
     */
    private fun stripNutritionTextColumn(sql: String): String {
        val variants = listOf(
            ", `nutritionText` TEXT NOT NULL DEFAULT ''",
            ", \"nutritionText\" TEXT NOT NULL DEFAULT ''",
            ", `nutritionText` TEXT NOT NULL DEFAULT ('')",
            ", \"nutritionText\" TEXT NOT NULL DEFAULT ('')",
        )
        for (v in variants) {
            if (sql.contains(v)) return sql.replace(v, "")
        }
        // Spacing-tolerant fallback (keeps PRIMARY KEY and neighbors intact).
        return sql.replace(
            Regex(",\\s*[`\"']nutritionText[`\"']\\s+TEXT[^,]*DEFAULT[^,]*\\(''[^)]*\\)"),
            "",
        ).replace(
            Regex(",\\s*[`\"']nutritionText[`\"']\\s+TEXT[^,]*DEFAULT\\s*''"),
            "",
        )
    }
}
