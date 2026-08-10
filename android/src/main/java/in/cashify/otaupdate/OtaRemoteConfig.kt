package `in`.cashify.otaupdate

import android.content.Context
import android.util.Log
import com.google.firebase.Firebase
import com.google.firebase.remoteconfig.FirebaseRemoteConfig
import com.google.firebase.remoteconfig.remoteConfig
import com.google.firebase.remoteconfig.remoteConfigSettings
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Remote Config access for the OTA system. FirebaseApp itself must be
 * initialized by the HOST app (google-services plugin auto-init) — this object
 * only reads the shared RemoteConfig singleton.
 *
 * Keys:
 * - `rn_bundle_url` ("" = OTA disabled)
 * - `rn_enable_safe_mode` (global kill switch)
 * - `rnb_<configKey>_latest_version` per module ("" = no OTA published)
 * - `rnb_<configKey>_enable_safe_mode` per-module kill switch
 */
object OtaRemoteConfig {

    private var isConfigFetched = false
    private var fetchTried = false
    private var settingsApplied = false
    private val mutex = Mutex()

    private suspend fun fetchRemoteConfig(context: Context): Boolean {
        return mutex.withLock {
            if (isConfigFetched || fetchTried) return true.also {
                Log.d(
                    "CashifyOTA",
                    "OtaRemoteConfig::Config already fetched: $isConfigFetched, fetchTried: $fetchTried"
                )
            }
            applySettingsOnce()
            // Try with a 2s budget; on failure/timeout, retry once with 5s.
            var success = attemptFetch(context, 2000)
            if (!success) {
                Log.d("CashifyOTA", "OtaRemoteConfig::Fetch failed/timed out, retrying with 5s timeout")
                success = attemptFetch(context, 5000)
            }
            if (!success) {
                fetchTried = true
                Log.d("CashifyOTA", "OtaRemoteConfig::Fetch failed after retry")
            }
            success
        }
    }

    private suspend fun applySettingsOnce() {
        if (settingsApplied) return
        val remoteConfig: FirebaseRemoteConfig = Firebase.remoteConfig
        val configSettings = remoteConfigSettings {
            minimumFetchIntervalInSeconds = 300
        }
        try {
            remoteConfig.setConfigSettingsAsync(configSettings).await()
        } catch (e: Exception) {
            Log.e("CashifyOTA", "OtaRemoteConfig::setConfigSettings failed: ${e.message}")
        }
        settingsApplied = true
    }

    /** One fetch+activate bounded by [timeoutMs]; true on success, false on timeout/exception. */
    private suspend fun attemptFetch(context: Context, timeoutMs: Long): Boolean {
        return withTimeoutOrNull(timeoutMs) {
            val remoteConfig: FirebaseRemoteConfig = Firebase.remoteConfig
            try {
                val forceFetch = shouldForceFetch(context)
                val updated = if (forceFetch) {
                    Log.d("CashifyOTA", "OtaRemoteConfig::Forced fetch")
                    remoteConfig.fetch(0).await()
                    remoteConfig.activate().await()
                } else {
                    Log.d("CashifyOTA", "OtaRemoteConfig::Fetch")
                    remoteConfig.fetchAndActivate().await()
                }
                Log.d("CashifyOTA", "OtaRemoteConfig::Config params updated: $updated")
                isConfigFetched = true
                if (forceFetch) {
                    OtaPreferences.setStoredAppVersion(context, HostAppInfo.versionName(context))
                }
                true
            } catch (e: Exception) {
                Log.e("CashifyOTA", "OtaRemoteConfig::Fetch failed ${e.message}")
                false
            }
        } ?: false
    }

    // Force a fresh fetch (bypassing the 300s cache) on debuggable builds and on
    // the first launch after an app update, so a new binary sees current OTA state.
    private fun shouldForceFetch(context: Context): Boolean {
        if (HostAppInfo.isDebuggable(context)) return true
        val storedVersion = OtaPreferences.getStoredAppVersion(context)
        val currentVersion = HostAppInfo.versionName(context)
        return if (storedVersion != currentVersion) {
            Log.d("CashifyOTA", "OtaRemoteConfig::App version changed $storedVersion -> $currentVersion, forcing fetch")
            true
        } else {
            false
        }
    }

    suspend fun getBundleUrl(context: Context): String {
        fetchRemoteConfig(context)
        return Firebase.remoteConfig.getString("rn_bundle_url")
    }

    suspend fun getEnableSafeMode(context: Context): Boolean {
        fetchRemoteConfig(context)
        return Firebase.remoteConfig.getBoolean("rn_enable_safe_mode")
    }

    suspend fun getModuleEnableSafeMode(context: Context, module: OtaModule): Boolean {
        fetchRemoteConfig(context)
        return Firebase.remoteConfig.getBoolean("rnb_${module.configKey}_enable_safe_mode")
    }

    suspend fun getBundleLatestVersion(context: Context, module: OtaModule): String {
        fetchRemoteConfig(context)
        return Firebase.remoteConfig.getString("rnb_${module.configKey}_latest_version")
    }
}
