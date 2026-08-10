package `in`.cashify.otaupdate

import android.content.Context

object OtaPreferences {

    private const val PREFS_NAME = "cashify_ota_prefs"
    private const val KEY_SAFE_MODE = "safe_mode_enabled"
    private const val KEY_APP_VERSION = "app_version"

    // Prefixed so a module configKey can never collide with the global
    // safe-mode key (e.g. configKey "enabled").
    private const val KEY_MODULE_SAFE_MODE_PREFIX = "module_safe_mode_"

    fun isSafeModeEnabled(context: Context): Boolean {
        return context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getBoolean(KEY_SAFE_MODE, false)
    }

    fun setSafeModeEnabled(context: Context, enabled: Boolean) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit().putBoolean(KEY_SAFE_MODE, enabled).apply()
    }

    fun isModuleSafeModeEnabled(context: Context, configKey: String): Boolean {
        return context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getBoolean(KEY_MODULE_SAFE_MODE_PREFIX + configKey, false)
    }

    fun setModuleSafeModeEnabled(context: Context, configKey: String, enabled: Boolean) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit().putBoolean(KEY_MODULE_SAFE_MODE_PREFIX + configKey, enabled).apply()
    }

    fun getStoredAppVersion(context: Context): String? {
        return context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString(KEY_APP_VERSION, null)
    }

    fun setStoredAppVersion(context: Context, version: String) {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit().putString(KEY_APP_VERSION, version).apply()
    }
}
