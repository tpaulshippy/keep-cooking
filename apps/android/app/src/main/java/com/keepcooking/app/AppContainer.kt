package com.keepcooking.app

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.preferencesDataStore
import androidx.room.Room
import com.keepcooking.app.data.AppDatabase
import com.keepcooking.app.data.SeedLoader
import com.keepcooking.app.export.RecipeExporter
import com.keepcooking.app.network.ApiService
import com.keepcooking.app.network.createApiService
import com.keepcooking.app.sync.DeviceAuth
import com.keepcooking.app.sync.SyncEngine
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

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

    val api: ApiService by lazy { createApiService(deviceAuth = DeviceAuth.interceptor()) }

    val syncEngine: SyncEngine by lazy {
        SyncEngine(
            database = db,
            api = api,
            dataStore = context.prefsDataStore,
            ioScope = scope,
        )
    }

    val recipeExporter: RecipeExporter by lazy { RecipeExporter(context) }

    /**
     * Shared "keepcooking" DataStore. Screens must reuse this instead of declaring
     * their own `preferencesDataStore(name = "keepcooking")` delegate — two live
     * instances on one file diverge (stale reads) and risk write corruption.
     */
    val appDataStore: DataStore<Preferences> by lazy { context.prefsDataStore }

    /** E2E metadata store (non-secret) + secret store (syncCode only) — parity with iOS E2EKeyStore. */
    val e2eMetaStore by lazy { context.e2eMetaDataStore }
    val e2eSecretStore by lazy { context.e2eSecretDataStore }

    /** One-shot offline seed load — mirrors SyncCoordinator.seedIfNeeded. */
    fun seedIfNeeded() {
        scope.launch(Dispatchers.IO) {
            SeedLoader(context, db).seedIfNeeded()
        }
        // Device identity enroll-once (unsigned, idempotent, best-effort):
        // warms the interceptor state so the first sync/clip is already
        // signed. SyncEngine.activeApi() re-ensures per run regardless.
        scope.launch(Dispatchers.IO) {
            runCatching { DeviceAuth.ensure(appDataStore, SyncEngine.PROD_BASE_URL) }
        }
    }
}
