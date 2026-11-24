package com.keepcooking.app

import android.content.Context
import androidx.datastore.preferences.preferencesDataStore
import androidx.room.Room
import com.keepcooking.app.data.AppDatabase
import com.keepcooking.app.data.SeedLoader
import com.keepcooking.app.export.RecipeExporter
import com.keepcooking.app.network.ApiService
import com.keepcooking.app.network.createApiService
import com.keepcooking.app.sync.SyncEngine
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

private val Context.prefsDataStore by preferencesDataStore(name = "keepcooking")

private val Context.prefsDataStore by preferencesDataStore(name = "keepcooking")
private val Context.e2eMetaDataStore by preferencesDataStore(name = "keepcooking_e2e_meta")
private val Context.e2eSecretDataStore by preferencesDataStore(name = "keepcooking_e2e_secret")

/** Simple service locator (mirrors iOS SyncCoordinator.shared wiring). */
class AppContainer(private val context: Context) {

    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    val db: AppDatabase by lazy {
        Room.databaseBuilder(context, AppDatabase::class.java, "keepcooking.db")
            .fallbackToDestructiveMigration()
            .build()
    }

    val api: ApiService by lazy { createApiService() }

    val syncEngine: SyncEngine by lazy {
        SyncEngine(
            database = db,
            api = api,
            dataStore = context.prefsDataStore,
            ioScope = scope,
        )
    }

    val recipeExporter: RecipeExporter by lazy { RecipeExporter(context) }

    /** E2E metadata store (non-secret) + secret store (syncCode only) — parity with iOS E2EKeyStore. */
    val e2eMetaStore by lazy { context.e2eMetaDataStore }
    val e2eSecretStore by lazy { context.e2eSecretDataStore }

    /** One-shot offline seed load — mirrors SyncCoordinator.seedIfNeeded. */
    fun seedIfNeeded() {
        scope.launch(Dispatchers.IO) {
            SeedLoader(context, db).seedIfNeeded()
        }
    }
}
