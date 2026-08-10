import Foundation
import Gzip

public class BundleDownloader {

  // Appended after the decompressed JS as the integrity marker. The publish
  // script guarantees the bundle ends with a `//` comment opener, so these
  // trailing bytes stay inside a comment and the file remains valid JS. This is
  // also why OTA bundles must remain PLAIN JS — hermesc bytecode cannot
  // tolerate appended bytes.
  private static let marker = "END_OF_FILE_MARKER".data(using: .utf8)

  /// Downloads the gzipped bundle, decompresses it to `bundleFile` and appends
  /// the integrity marker. Returns nil on any failure (partial file deleted).
  static func downloadFileSync(apiUrl: URL, bundleFile: URL, timeout: TimeInterval = 120.0) async -> URL? {
    Log.d("BundleDownloader::downloadFile::apiUrl: \(apiUrl)")
    Log.d("BundleDownloader::downloadFile::bundlePath: \(bundleFile.path)")

    var request = URLRequest(url: apiUrl)
    request.timeoutInterval = timeout
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
        Log.d("BundleDownloader::downloadFile::failed, HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        return nil
      }
      return writeToFileSync(bundleFile: bundleFile, source: data)
    } catch {
      try? FileManager.default.removeItem(at: bundleFile)
      Log.d("BundleDownloader::downloadFile error: \(error.localizedDescription)")
      return nil
    }
  }

  private static func writeToFileSync(bundleFile: URL, source: Data) -> URL? {
    let parentDir = bundleFile.deletingLastPathComponent()
    do {
      if !FileManager.default.fileExists(atPath: parentDir.path) {
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
      }
      if !FileManager.default.fileExists(atPath: bundleFile.path) {
        FileManager.default.createFile(atPath: bundleFile.path, contents: nil)
      }
    } catch {
      Log.e("BundleDownloader::writeToFile::dir error: \(error.localizedDescription)")
      return nil
    }
    guard decompressGzipData(source, to: bundleFile) else {
      Log.e("BundleDownloader::writeToFile::failed to decompress")
      try? FileManager.default.removeItem(at: bundleFile)
      return nil
    }
    Log.d("BundleDownloader::writeToFile::written to \(bundleFile.path)")
    return bundleFile
  }

  private static func decompressGzipData(_ compressedData: Data, to filePath: URL) -> Bool {
    guard let outputStream = OutputStream(url: filePath, append: false) else {
      Log.e("BundleDownloader::could not create output stream")
      return false
    }
    outputStream.open()
    defer { outputStream.close() }
    do {
      let uncompressedData = try compressedData.gunzipped()
      var success = writeToOutputStream(data: uncompressedData, outputStream: outputStream)
      if success, let mark = marker {
        success = writeToOutputStream(data: mark, outputStream: outputStream)
      }
      return success
    } catch {
      Log.e("BundleDownloader::gunzip failed: \(error.localizedDescription)")
      return false
    }
  }

  private static func writeToOutputStream(data: Data, outputStream: OutputStream) -> Bool {
    let bufferSize = 8192
    var bytesRemaining = data.count
    var bytesWritten = 0

    while bytesRemaining > 0 {
      let chunkSize = min(bufferSize, bytesRemaining)
      let chunk = data.subdata(in: bytesWritten..<(bytesWritten + chunkSize))
      let result = chunk.withUnsafeBytes {
        outputStream.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: chunkSize)
      }
      if result < 0 {
        Log.e("BundleDownloader::failed to write to output stream")
        return false
      }
      bytesWritten += result
      bytesRemaining -= result
    }
    return true
  }

  /// Trailing-bytes integrity check via FileHandle (the lego InputStream
  /// offset-seek approach was unreliable).
  public static func hasMarker(filePath: String) -> Bool {
    guard let marker else { return false }
    let url = URL(fileURLWithPath: filePath)
    guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
    defer { try? handle.close() }
    guard let fileSize = try? handle.seekToEnd(), fileSize >= UInt64(marker.count) else {
      return false
    }
    do {
      try handle.seek(toOffset: fileSize - UInt64(marker.count))
      let tail = try handle.read(upToCount: marker.count)
      return tail == marker
    } catch {
      Log.e("BundleDownloader::hasMarker read failed: \(error.localizedDescription)")
      return false
    }
  }
}
