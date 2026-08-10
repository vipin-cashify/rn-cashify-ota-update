package `in`.cashify.otaupdate

import android.content.Context
import android.content.res.AssetManager
import java.io.IOException
import java.io.InputStream
import java.util.concurrent.ConcurrentHashMap

// APK assets are immutable, so listings are cached for the process lifetime.
private val assetListCache = ConcurrentHashMap<String, Set<String>>()

fun AssetManager.listCached(path: String): Set<String> =
    assetListCache.computeIfAbsent(path) {
        try {
            list(path)?.toSet() ?: emptySet()
        } catch (e: IOException) {
            emptySet()
        }
    }

fun Context.assetExists(assetUri: String): Boolean {
    val cleaned = assetUri.removePrefix("assets://").trim('/')
    if (cleaned.isEmpty()) return false
    val segments = cleaned.split('/')
    val fileName = segments.last()
    val dir = if (segments.size > 1) segments.dropLast(1).joinToString("/") else ""
    return assets.listCached(dir).contains(fileName)
}

fun Context.openAssetOrNull(assetUri: String): InputStream? =
    try {
        assets.open(assetUri.removePrefix("assets://").trim('/'))
    } catch (e: IOException) {
        null
    }
