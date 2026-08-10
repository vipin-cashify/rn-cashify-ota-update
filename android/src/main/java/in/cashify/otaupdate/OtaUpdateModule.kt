package `in`.cashify.otaupdate

import android.content.Context
import android.util.Log
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileNotFoundException

/**
 * JS bridge, exposed as `NativeModules.CashifyOtaUpdate`:
 * - getOtaBundleVersion(): version of the JS bundle this session booted with.
 * - getFileSystemURL(moduleName): `file://` URL of any configured module's
 *   bundle — for JS-side loaders of non-launcher modules, and debugging.
 */
class OtaUpdateModule(private val reactContext: ReactApplicationContext) :
    ReactContextBaseJavaModule(reactContext) {

    override fun getName(): String = NAME

    /**
     * OTA bundle version when a downloaded bundle booted this session, else the
     * host app's versionName (the shipped asset bundle).
     */
    @ReactMethod(isBlockingSynchronousMethod = true)
    fun getOtaBundleVersion(): String {
        return OtaBundleManager.launcherLoadedBundleVersion
            ?: HostAppInfo.versionName(reactContext.applicationContext)
    }

    @ReactMethod
    fun getFileSystemURL(moduleName: String, promise: Promise) {
        CoroutineScope(Dispatchers.IO).launch {
            Log.d("CashifyOTA", "OtaUpdateModule::getFileSystemURL::$moduleName")
            try {
                val appContext = reactContext.applicationContext
                var jsBundleUri = OtaBundleManager.getJsBundleUriForModule(appContext, moduleName)

                // If it's an APK asset, copy it out to cache so JS gets a real file path.
                if (jsBundleUri.startsWith("assets://")) {
                    if (!appContext.assetExists(jsBundleUri)) {
                        throw FileNotFoundException("Asset not found: $jsBundleUri")
                    }
                    val module = OtaModuleManager.getModuleByName(moduleName)
                    val cached = copyAssetToCacheIfNeeded(appContext, jsBundleUri, module?.moduleVersion ?: "0")
                    jsBundleUri = "file://${cached.absolutePath}"
                }
                if (!jsBundleUri.startsWith("file://")) {
                    jsBundleUri = "file://$jsBundleUri"
                }
                promise.resolve(jsBundleUri)
            } catch (fnf: FileNotFoundException) {
                promise.reject(NAME, fnf.message, fnf)
            } catch (e: Exception) {
                Log.e("CashifyOTA", "OtaUpdateModule::getFileSystemURL error", e)
                promise.reject(NAME, "Error getting file system URL", e)
            }
        }
    }

    /**
     * The cache copy is keyed by [moduleVersion] so a binary update never serves
     * the previous binary's cached asset bundle.
     */
    private suspend fun copyAssetToCacheIfNeeded(
        context: Context,
        assetUri: String,
        moduleVersion: String
    ): File = withContext(Dispatchers.IO) {
        val relativePath = assetUri
            .removePrefix("assets://")
            .trim('/')
            .also { require(it.isNotEmpty()) { "Empty asset path: '$assetUri'" } }

        val outFile = File(context.cacheDir, "ota-assets/$moduleVersion/$relativePath")
        if (outFile.exists()) return@withContext outFile
        outFile.parentFile?.takeIf { !it.exists() }?.mkdirs()

        context.openAssetOrNull(assetUri)
            ?.use { input ->
                outFile.outputStream().use { output -> input.copyTo(output) }
            } ?: throw FileNotFoundException("Failed to open asset stream: $relativePath")

        outFile
    }

    companion object {
        const val NAME = "CashifyOtaUpdate"
    }
}
