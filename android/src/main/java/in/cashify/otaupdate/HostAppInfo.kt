package `in`.cashify.otaupdate

import android.content.Context
import android.content.pm.ApplicationInfo

/**
 * Host-app facts resolved at runtime — a library cannot reference the host's
 * BuildConfig, so debuggability and versionName come from the platform instead.
 */
internal object HostAppInfo {

    fun isDebuggable(context: Context): Boolean {
        return (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
    }

    /** Host versionName; PackageInfo.versionName is nullable, default matches iOS. */
    fun versionName(context: Context): String {
        return try {
            context.packageManager.getPackageInfo(context.packageName, 0).versionName ?: "0.0"
        } catch (e: Exception) {
            "0.0"
        }
    }
}
