package `in`.cashify.otaupdate

import android.util.Log
import androidx.annotation.WorkerThread
import okhttp3.MediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.ResponseBody
import okio.Buffer
import okio.BufferedSource
import okio.ForwardingSource
import okio.GzipSource
import okio.Source
import okio.buffer
import okio.sink
import java.io.File
import java.util.concurrent.TimeUnit
import kotlin.math.ln
import kotlin.math.pow

/**
 * Listener for streaming download progress. Called from a background thread on every
 * source read (typically every 8KB). Callers are responsible for any throttling.
 *
 * @param bytesRead total compressed bytes received so far (over the wire)
 * @param totalBytes Content-Length from server, or -1 if unknown
 * @param done true on the final invocation (EOF reached)
 */
typealias BundleDownloadProgressListener = (bytesRead: Long, totalBytes: Long, done: Boolean) -> Unit

object BundleDownloader {

    // Appended after the decompressed JS. Metro bundles end with a
    // `//# sourceMappingURL=...` comment line, so these trailing bytes land inside
    // that comment and the file stays valid JS. This is also why OTA bundles must
    // remain PLAIN JS — hermesc bytecode cannot tolerate appended bytes.
    private val marker = "END_OF_FILE_MARKER".toByteArray()

    /**
     * Streams a remote bundle (gzipped) to disk. Uses its own OkHttpClient, NOT
     * OkHttpClientProvider's shared client — that one carries the API-logger
     * interceptor and OTA downloads should stay off it.
     */
    @WorkerThread
    fun downloadFileSync(
        bundleUrl: String,
        bundleFile: File,
        onProgress: BundleDownloadProgressListener? = null
    ): String? {
        val timeout: Long = 120000 // 2 minutes
        val client = OkHttpClient().newBuilder().callTimeout(timeout, TimeUnit.MILLISECONDS).build()
        val request = Request.Builder().url(bundleUrl).build()
        Log.d("CashifyOTA", "BundleDownloader::downloadFile::bundleUrl: $bundleUrl")
        Log.d("CashifyOTA", "BundleDownloader::downloadFile::bundlePath: ${bundleFile.absolutePath}")
        try {
            client.newCall(request).execute().use { response ->
                require(response.isSuccessful) { "Failed to download bundle: $bundleUrl (HTTP ${response.code})" }
                require(response.body != null) { "Response body is null" }

                val body: ResponseBody = if (onProgress != null) {
                    ProgressResponseBody(response.body!!, onProgress)
                } else {
                    response.body!!
                }
                return writeToFileSync(bundleFile, body.source())
            }
        } catch (e: Exception) {
            // delete the file if download fails
            bundleFile.delete()
            Log.d("CashifyOTA", "BundleDownloader::downloadFile error: ${e.message}")
        }
        return null
    }

    private fun writeToFileSync(bundleFile: File, source: Source): String {
        Log.d("CashifyOTA", "BundleDownloader::writeToFile::FilePath: ${bundleFile.absolutePath}")
        val startTime = System.currentTimeMillis()

        val parentDir = bundleFile.parentFile
        if (parentDir != null && !parentDir.exists()) {
            parentDir.mkdirs()
        }
        if (!bundleFile.exists()) {
            bundleFile.createNewFile()
        }

        val bufferSize = 8192 // 8 KB

        GzipSource(source).buffer().use { bufferedSource ->
            bundleFile.sink().buffer().use { bufferedSink ->
                val buffer = ByteArray(bufferSize)
                var bytesRead: Int
                while (bufferedSource.read(buffer).also { bytesRead = it } != -1) {
                    bufferedSink.write(buffer, 0, bytesRead)
                }
                bufferedSink.write(marker)
            }
        }

        Log.d("CashifyOTA", "BundleDownloader::writeToFile::Time: ${System.currentTimeMillis() - startTime}ms")
        Log.d("CashifyOTA", "BundleDownloader::writeToFile::Size: ${prettyPrintBytes(bundleFile.length())}")
        Log.d("CashifyOTA", "BundleDownloader::writeToFile::Path: ${bundleFile.absolutePath}")
        return bundleFile.absolutePath
    }

    fun hasMarker(file: File): Boolean {
        if (!file.exists() || file.length() < marker.size) return false
        val buffer = ByteArray(marker.size)
        file.inputStream().use { inputStream ->
            inputStream.skip(file.length() - marker.size)
            inputStream.read(buffer, 0, marker.size)
        }
        return buffer.contentEquals(marker)
    }

    private fun prettyPrintBytes(bytes: Long): String {
        if (bytes < 1024) return "$bytes B"
        val exp = (ln(bytes.toDouble()) / ln(1024.0)).toInt()
        val pre = "KMGTPE"[exp - 1] + "iB"
        return String.format("%.1f %s", bytes / 1024.0.pow(exp.toDouble()), pre)
    }
}

/**
 * Wraps an OkHttp ResponseBody to count network bytes as they're read.
 * Tracking happens BEFORE GzipSource decompression, so bytesRead/totalBytes
 * reflect actual wire transfer.
 */
private class ProgressResponseBody(
    private val delegate: ResponseBody,
    private val onProgress: BundleDownloadProgressListener
) : ResponseBody() {

    override fun contentType(): MediaType? = delegate.contentType()

    override fun contentLength(): Long = delegate.contentLength()

    override fun source(): BufferedSource {
        val totalLength = delegate.contentLength()
        return object : ForwardingSource(delegate.source()) {
            private var totalBytesRead = 0L

            override fun read(sink: Buffer, byteCount: Long): Long {
                val n = super.read(sink, byteCount)
                if (n != -1L) {
                    totalBytesRead += n
                }
                onProgress(totalBytesRead, totalLength, n == -1L)
                return n
            }
        }.buffer()
    }
}
