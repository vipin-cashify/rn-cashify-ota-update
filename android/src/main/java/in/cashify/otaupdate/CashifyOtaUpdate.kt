package `in`.cashify.otaupdate

import android.content.Context

/**
 * Public host-app API. Wire into your Application class:
 *
 * ```kotlin
 * override val reactHost: ReactHost by lazy {
 *   CashifyOtaUpdate.init(applicationContext)
 *   getDefaultReactHost(
 *     context = applicationContext,
 *     packageList = ...,
 *     jsBundleFilePath = CashifyOtaUpdate.getLauncherBundleFilePath(applicationContext),
 *   )
 * }
 *
 * override fun onCreate() {
 *   ...
 *   loadReactNative(this)
 *   CashifyOtaUpdate.checkForUpdatesAsync(applicationContext)
 * }
 * ```
 */
object CashifyOtaUpdate {

    /** Synchronous, local-only app.json parse — safe on the launch path. */
    fun init(context: Context) {
        OtaModuleManager.init(context)
    }

    /**
     * LAUNCH PATH — absolute path of a valid downloaded launcher bundle strictly
     * newer than the shipped one, or null (host's default asset loader / Metro).
     * Synchronous, local-only, never throws.
     */
    fun getLauncherBundleFilePath(context: Context): String? {
        return OtaBundleManager.getLauncherBundleFilePathLocal(context)
    }

    /**
     * Fire-and-forget background check: downloads newer bundles (or applies the
     * safe-mode kill switches / rollbacks) for the NEXT launch. Never blocks or
     * crashes startup.
     */
    fun checkForUpdatesAsync(context: Context) {
        OtaModuleManager.loadBundlesAsync(context)
    }
}
