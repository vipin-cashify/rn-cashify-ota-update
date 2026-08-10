package `in`.cashify.otaupdate

/**
 * One OTA-updatable JS bundle, parsed from the `legoModules` map in app.json
 * (same schema as the lego apps, minus the firestore block).
 *
 * @param moduleVersion version of the bundle SHIPPED in this binary (the asset
 *   baseline) — OTA versions published for the module must be semantically greater.
 * @param launcher true for the module whose bundle boots the ReactHost; its asset
 *   fallback is the stock `assets://index.android.bundle`.
 */
data class OtaModule(
    val moduleName: String,
    val modulePath: String,
    val configKey: String,
    val scheme: String,
    val moduleVersion: String,
    val bundlePriority: Int,
    val otaUpdates: Boolean,
    val launcher: Boolean,
)
