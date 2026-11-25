package com.keepcooking.app

import android.app.Application

/**
 * Keep Cooking Application — parity with apps/ios/App/KeepCookingApp.swift.
 *
 * Owns the Room database, DataStore preferences, and SyncEngine singletons.
 * Offline-first: local Room is the source of truth; SyncEngine mirrors to
 * the API when online (same LWW + tombstone contract as iOS SyncEngine).
 */
class KeepCookingApp : Application() {

    lateinit var container: AppContainer
        private set

    override fun onCreate() {
        super.onCreate()
        container = AppContainer(this)
    }
}
