package `in`.cashify.otaupdate

import android.content.Context
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap

/**
 * Parses the module map from the app.json packaged into APK assets (key
 * `otaModules`, falling back to `legoModules` for lego-style apps) and
 * orchestrates the background OTA check for every module with `otaUpdates: true`.
 */
object OtaModuleManager {

    @Volatile
    internal var modules: Map<String, OtaModule> = emptyMap()
        private set

    @Volatile
    private var initialized = false

    // Thread-safe map of the bundle version actually resolved per module.
    private val bundleVersionMap = ConcurrentHashMap<String, String>()

    /**
     * Synchronous, local-only app.json parse — safe to call on the launch path.
     * Never throws; on any failure the module map stays empty and OTA is disabled.
     */
    fun init(context: Context, assetFileName: String = "app.json") {
        if (initialized) return
        try {
            val jsonString =
                context.assets.open(assetFileName).bufferedReader().use { it.readText() }
            val root = JSONObject(jsonString)
            val modulesJson = root.optJSONObject("otaModules") ?: root.optJSONObject("legoModules")
            if (modulesJson == null) {
                Log.w("CashifyOTA", "OtaModuleManager::init::no otaModules/legoModules in $assetFileName, OTA disabled")
                initialized = true
                return
            }
            val parsed = mutableMapOf<String, OtaModule>()
            modulesJson.keys().forEach { key ->
                val moduleJson = modulesJson.getJSONObject(key)
                parsed[key] = OtaModule(
                    moduleName = moduleJson.getString("moduleName"),
                    modulePath = moduleJson.getString("modulePath"),
                    configKey = moduleJson.getString("configKey"),
                    scheme = moduleJson.optString("scheme", ""),
                    moduleVersion = moduleJson.getString("moduleVersion"),
                    bundlePriority = moduleJson.optInt("bundlePriority", Int.MAX_VALUE),
                    otaUpdates = moduleJson.optBoolean("otaUpdates", false),
                    launcher = moduleJson.optBoolean("launcher", false),
                )
            }
            modules = parsed.toMap()
            initialized = true
            Log.d("CashifyOTA", "OtaModuleManager::init::modules: ${modules.keys.joinToString(",")}")
        } catch (t: Throwable) {
            Log.e("CashifyOTA", "OtaModuleManager::init failed, OTA disabled: ${t.message}", t)
            modules = emptyMap()
            initialized = true
        }
    }

    /**
     * Fire-and-forget background check: temp cleanup -> Remote Config -> global
     * then per-module safe-mode kill switches -> per-module download-if-needed +
     * stale/rollback cleanup. Downloaded bundles are picked up on the NEXT launch.
     */
    fun loadBundlesAsync(context: Context) {
        CoroutineScope(Dispatchers.IO).launch {
            try {
                init(context)
                val otaModules = modules.values.filter { it.otaUpdates }
                if (otaModules.isEmpty()) {
                    Log.d("CashifyOTA", "OtaModuleManager::no OTA modules configured, skipping")
                    return@launch
                }

                OtaBundleManager.cleanupTemporaryBundles(context)

                if (!NetworkUtil.isNetworkAvailable(context)) {
                    Log.d("CashifyOTA", "OtaModuleManager::network not available, skipping bundle check")
                    return@launch
                }

                // Global kill switch: wipes EVERY module and stops the whole check.
                if (OtaRemoteConfig.getEnableSafeMode(context)) {
                    Log.d("CashifyOTA", "OtaModuleManager::global safe mode enabled, clearing all module bundles")
                    otaModules.forEach { OtaBundleManager.cleanupModuleBundles(context, it) }
                    // Persisted locally so the NEXT launch stays on the asset bundle
                    // even when offline.
                    OtaPreferences.setSafeModeEnabled(context, true)
                    return@launch
                }
                OtaPreferences.setSafeModeEnabled(context, false)

                val sortedModules =
                    otaModules.sortedWith(compareBy({ it.bundlePriority }, { it.moduleName }))
                sortedModules.forEach { module ->
                    // Per-module kill switch: wipes ONLY this module; others continue.
                    if (OtaRemoteConfig.getModuleEnableSafeMode(context, module)) {
                        Log.d(
                            "CashifyOTA",
                            "OtaModuleManager::module safe mode enabled for ${module.moduleName}, clearing its bundles"
                        )
                        OtaBundleManager.cleanupModuleBundles(context, module)
                        OtaPreferences.setModuleSafeModeEnabled(context, module.configKey, true)
                        return@forEach
                    }
                    OtaPreferences.setModuleSafeModeEnabled(context, module.configKey, false)

                    Log.d(
                        "CashifyOTA",
                        "OtaModuleManager::checking module: ${module.moduleName}, priority: ${module.bundlePriority}"
                    )
                    OtaBundleManager.downloadBundleIfNeeded(context, module)
                    OtaBundleManager.cleanupStaleBundles(context, module)
                }
            } catch (t: Throwable) {
                Log.e("CashifyOTA", "OtaModuleManager::loadBundlesAsync failed: ${t.message}", t)
            }
        }
    }

    fun launcherModule(): OtaModule? = modules.values.firstOrNull { it.launcher }

    fun getModuleByName(moduleName: String): OtaModule? = modules[moduleName]

    fun getBundleVersion(moduleName: String): String? = bundleVersionMap[moduleName]

    fun setBundleVersion(moduleName: String, version: String) {
        bundleVersionMap[moduleName] = version
    }
}
