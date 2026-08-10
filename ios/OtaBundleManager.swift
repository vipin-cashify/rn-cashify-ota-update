import Foundation

/// Version selection, download and cleanup for OTA bundles.
///
/// The LAUNCH path (`getLauncherBundleFileURLLocal`) is synchronous and
/// local-only — no Remote Config, no network — so the host's `bundleURL()`
/// never blocks the first frame. Safe-mode kill switches (global and
/// per-module) from Remote Config are applied by the background check and
/// persisted via `OtaPreferences`; the launch path only reads those flags.
///
/// The launcher module's shipped bundle is the host's stock flat
/// `main.jsbundle`, so its asset baseline version comes from `moduleVersion`
/// in app.json. Returning nil hands loading back to the default asset bundle.
///
/// Storage: Application Support/<modulePath>/<version>/main.jsbundle (excluded
/// from iCloud backup).
@objc public class OtaBundleManager: NSObject {

  /// Version of the disk bundle the launcher actually booted with, if any.
  private(set) static var loadedBundleVersion: String?

  /// OTA version when a disk bundle booted, else the host app's versionName
  /// (the shipped asset bundle).
  @objc public static func currentBundleVersion() -> String {
    loadedBundleVersion
      ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0")
  }

  // MARK: - Launch path (synchronous, local-only, never throws)

  public static func getLauncherBundleFileURLLocal() -> URL? {
    let tag = "OtaBundleManager::getLauncherBundleFileURLLocal"
#if DEBUG
    Log.d("\(tag)::debug build, using default bundle source")
    return nil
#else
    if OtaPreferences.isSafeModeEnabled {
      Log.d("\(tag)::safe mode enabled, using asset bundle")
      return nil
    }
    guard let module = OtaModuleManager.shared.launcherModule() else {
      Log.d("\(tag)::no launcher module configured, using asset bundle")
      return nil
    }
    if OtaPreferences.isModuleSafeModeEnabled(module.configKey) {
      Log.d("\(tag)::module safe mode enabled for \(module.moduleName), using asset bundle")
      return nil
    }
    let assetVersion = getJsBundleAssetVersion(module: module)
    guard let diskVersion = getJsBundleDiskVersion(module: module) else {
      Log.d("\(tag)::no valid disk bundle, using asset bundle (\(assetVersion ?? "nil"))")
      OtaModuleManager.shared.setBundleVersion(moduleName: module.moduleName, version: assetVersion ?? "")
      return nil
    }
    // Asset wins ties: disk must be STRICTLY newer than the shipped bundle.
    if let assetVersion, [diskVersion, assetVersion].semanticMax() == assetVersion {
      Log.d("\(tag)::disk \(diskVersion) <= asset \(assetVersion), using asset bundle")
      OtaModuleManager.shared.setBundleVersion(moduleName: module.moduleName, version: assetVersion)
      return nil
    }
    guard let bundleFile = try? buildJsBundleFilePath(modulePath: module.modulePath, version: diskVersion) else {
      return nil
    }
    loadedBundleVersion = diskVersion
    OtaModuleManager.shared.setBundleVersion(moduleName: module.moduleName, version: diskVersion)
    Log.d("\(tag)::loading disk bundle \(diskVersion): \(bundleFile.path)")
    return bundleFile
#endif
  }

  /// Bridge entry for `NativeModules.CashifyOtaUpdate.getFileSystemURL` —
  /// completion form so the ObjC module shim needs no Swift/React interop types.
  @objc public static func fileSystemURL(
    forModule moduleName: String,
    completion: @escaping (NSString?, NSError?) -> Void
  ) {
    do {
      let url = try getJsBundleUriForModule(moduleName: moduleName)
      completion(url.absoluteString as NSString, nil)
    } catch {
      completion(nil, error as NSError)
    }
  }

  /// Resolves any module's bundle: valid disk bundle first, launcher's flat
  /// asset as fallback. Throws when nothing exists (non-launcher module with no
  /// downloaded bundle, or module safe-mode on a non-launcher module).
  static func getJsBundleUriForModule(moduleName: String) throws -> URL {
    let tag = "OtaBundleManager::getJsBundleUriForModule::\(moduleName)"
    guard let module = OtaModuleManager.shared.getModuleByName(moduleName) else {
      throw OtaBundleManagerError.invalidModule(reason: moduleName)
    }

    let safeMode = OtaPreferences.isSafeModeEnabled
      || OtaPreferences.isModuleSafeModeEnabled(module.configKey)
    if !safeMode,
       let diskVersion = getJsBundleDiskVersion(module: module) {
      let assetVersion = getJsBundleAssetVersion(module: module)
      if assetVersion == nil || [diskVersion, assetVersion!].semanticMax() == diskVersion,
         diskVersion != assetVersion,
         let bundleFile = try? buildJsBundleFilePath(modulePath: module.modulePath, version: diskVersion) {
        OtaModuleManager.shared.setBundleVersion(moduleName: module.moduleName, version: diskVersion)
        Log.d("\(tag)::disk bundle \(diskVersion)")
        return bundleFile
      }
    }
    if module.launcher, let assetUrl = Bundle.main.url(forResource: "main", withExtension: "jsbundle") {
      OtaModuleManager.shared.setBundleVersion(moduleName: module.moduleName, version: module.moduleVersion)
      Log.d("\(tag)::asset bundle \(module.moduleVersion)")
      return assetUrl
    }
    throw OtaBundleManagerError.invalidBundle(reason: "no bundle available for \(moduleName)")
  }

  // MARK: - Background path

  static func downloadBundleIfNeeded(module: OtaModule) async {
    let tag = "OtaBundleManager::downloadBundleIfNeeded::\(module.moduleName)"
    do {
      let remoteVersion = await OtaRemoteConfig.getBundleLatestVersion(module: module)
      Log.d("\(tag)::remoteVersion: \(remoteVersion)")
      if remoteVersion.isEmpty {
        Log.d("\(tag)::remoteVersion is empty, skip download")
        return
      }
      if !remoteVersion.isSemanticVersion {
        Log.e("\(tag)::remoteVersion '\(remoteVersion)' is not a valid version, skip download")
        return
      }

      let assetVersion = getJsBundleAssetVersion(module: module)
      if let assetVersion, [assetVersion, remoteVersion].semanticMax() == assetVersion {
        Log.d("\(tag)::assetVersion \(assetVersion) >= remoteVersion, skip download")
        return
      }

      if let diskVersion = getJsBundleDiskVersion(module: module),
         [diskVersion, remoteVersion].semanticMax() == diskVersion {
        Log.d("\(tag)::diskVersion \(diskVersion) >= remoteVersion, skip download")
        return
      }

      let bundleUrl = await OtaRemoteConfig.getBundleUrl()
      guard !bundleUrl.isEmpty else {
        Log.d("\(tag)::rn_bundle_url is empty, OTA disabled, skip download")
        return
      }

      Log.d("\(tag)::downloading remote bundle \(remoteVersion)")
      try await downloadRemoteBundle(module: module, bundleUrl: bundleUrl, remoteVersion: remoteVersion)
    } catch {
      Log.e("\(tag)::error: \(error.localizedDescription)")
    }
  }

  static func cleanupStaleBundles(module: OtaModule) async {
    let tag = "OtaBundleManager::cleanupStaleBundles::\(module.moduleName)"
    let fileManager = FileManager.default
    guard let moduleDir = try? getFilesDir(modulePath: module.modulePath),
          fileManager.fileExists(atPath: moduleDir.path) else {
      return
    }
    do {
      var versionDirs = try fileManager.contentsOfDirectory(
        at: moduleDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
      guard !versionDirs.isEmpty else { return }

      let assetVersion = getJsBundleAssetVersion(module: module)
      let remoteVersion = await OtaRemoteConfig.getBundleLatestVersion(module: module)
      Log.d("\(tag)::assetVersion: \(assetVersion ?? "nil"), remoteVersion: \(remoteVersion)")

      var invalidVersions: [String] = []
      for versionDir in versionDirs {
        let name = versionDir.lastPathComponent
        let contents = try? fileManager.contentsOfDirectory(
          at: versionDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        // empty directory
        if let contents, contents.isEmpty {
          Log.d("\(tag)::empty version directory: \(name)")
          try? fileManager.removeItem(at: versionDir)
          invalidVersions.append(name)
          continue
        }
        // rollback: remote was lowered below this version
        if !remoteVersion.isEmpty, remoteVersion != name,
           [remoteVersion, name].semanticMin() == remoteVersion {
          Log.d("\(tag)::rollback detected, deleting: \(name)")
          try? fileManager.removeItem(at: versionDir)
          invalidVersions.append(name)
          continue
        }
        // stale: not newer than the shipped bundle
        if let assetVersion, [assetVersion, name].semanticMax() == assetVersion {
          Log.d("\(tag)::stale version detected, deleting: \(name)")
          try? fileManager.removeItem(at: versionDir)
          invalidVersions.append(name)
          continue
        }
        let bundleFile = versionDir.appendingPathComponent(getBundleName())
        if !fileManager.fileExists(atPath: bundleFile.path)
            || !BundleDownloader.hasMarker(filePath: bundleFile.path) {
          Log.d("\(tag)::missing/corrupt bundle, deleting: \(name)")
          try? fileManager.removeItem(at: versionDir)
          invalidVersions.append(name)
          continue
        }
      }

      versionDirs = versionDirs.filter { !invalidVersions.contains($0.lastPathComponent) }
      guard versionDirs.count > 1 else { return }
      // Keep only the newest valid version.
      guard let latestVersion = versionDirs.map(\.lastPathComponent).semanticMax() else { return }
      for versionDir in versionDirs where versionDir.lastPathComponent != latestVersion {
        Log.d("\(tag)::deleting old version directory: \(versionDir.lastPathComponent)")
        try? fileManager.removeItem(at: versionDir)
      }
    } catch {
      Log.e("\(tag)::error: \(error.localizedDescription)")
    }
  }

  static func cleanupTemporaryBundles() {
    let tag = "OtaBundleManager::cleanupTemporaryBundles"
    let fileManager = FileManager.default
    let tempDir = fileManager.temporaryDirectory
    guard let tempFiles = try? fileManager.contentsOfDirectory(
      at: tempDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else {
      return
    }
    for tempFile in tempFiles where tempFile.lastPathComponent.hasSuffix(".tmp") {
      do {
        try fileManager.removeItem(at: tempFile)
        Log.d("\(tag)::deleted temporary file: \(tempFile.path)")
      } catch {
        Log.e("\(tag)::failed to delete \(tempFile.path): \(error.localizedDescription)")
      }
    }
  }

  static func cleanupModuleBundles(module: OtaModule) {
    let tag = "OtaBundleManager::cleanupModuleBundles::\(module.moduleName)"
    let fileManager = FileManager.default
    guard let moduleDir = try? getFilesDir(modulePath: module.modulePath),
          fileManager.fileExists(atPath: moduleDir.path) else {
      return
    }
    do {
      try fileManager.removeItem(at: moduleDir)
      Log.d("\(tag)::deleted module directory: \(moduleDir.path)")
    } catch {
      Log.e("\(tag)::failed to delete \(moduleDir.path): \(error.localizedDescription)")
    }
  }

  private static func downloadRemoteBundle(
    module: OtaModule,
    bundleUrl: String,
    remoteVersion: String
  ) async throws {
    let tag = "OtaBundleManager::downloadRemoteBundle::\(module.moduleName)"
    let fileManager = FileManager.default
    let destinationFile = try buildJsBundleFilePath(modulePath: module.modulePath, version: remoteVersion)
    let tempFile = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tmp")

    guard let remoteUrl = buildJsBundleRemoteUrl(
      bundleUrl: bundleUrl, module: module, version: remoteVersion) else {
      throw OtaBundleManagerError.downloadFailed(reason: "invalid remote URL")
    }

    guard await BundleDownloader.downloadFileSync(apiUrl: remoteUrl, bundleFile: tempFile) != nil else {
      try? fileManager.removeItem(at: tempFile)
      throw OtaBundleManagerError.downloadFailed(reason: "failed to download \(remoteUrl.absoluteString)")
    }

    guard BundleDownloader.hasMarker(filePath: tempFile.path) else {
      Log.d("\(tag)::downloaded bundle has no marker, deleting")
      try? fileManager.removeItem(at: tempFile)
      return
    }

    do {
      let destinationDir = destinationFile.deletingLastPathComponent()
      if !fileManager.fileExists(atPath: destinationDir.path) {
        try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)
      }
      excludeFromBackup(try getFilesDir(modulePath: module.modulePath))
      if fileManager.fileExists(atPath: destinationFile.path) {
        _ = try fileManager.replaceItemAt(destinationFile, withItemAt: tempFile)
      } else {
        try fileManager.moveItem(at: tempFile, to: destinationFile)
      }
      Log.d("\(tag)::bundle installed at: \(destinationFile.path)")
    } catch {
      Log.e("\(tag)::error installing bundle: \(error.localizedDescription)")
      try? fileManager.removeItem(at: tempFile)
      try? fileManager.removeItem(at: destinationFile)
    }
  }

  // MARK: - Paths & versions

  /// The version of the bundle shipped inside this binary. The launcher's flat
  /// asset carries `moduleVersion` from app.json; non-launcher modules ship no
  /// asset at all (disk/remote only).
  private static func getJsBundleAssetVersion(module: OtaModule) -> String? {
    module.launcher ? module.moduleVersion : nil
  }

  private static func getJsBundleDiskVersion(module: OtaModule) -> String? {
    let fileManager = FileManager.default
    guard let moduleDir = try? getFilesDir(modulePath: module.modulePath),
          let versionDirs = try? fileManager.contentsOfDirectory(
            at: moduleDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else {
      return nil
    }
    let validVersions = versionDirs
      .map(\.lastPathComponent)
      .filter { version in
        guard let bundleFile = try? buildJsBundleFilePath(modulePath: module.modulePath, version: version) else {
          return false
        }
        return fileManager.fileExists(atPath: bundleFile.path)
          && BundleDownloader.hasMarker(filePath: bundleFile.path)
      }
    return validVersions.semanticMax()
  }

  private static func buildJsBundleRemoteUrl(bundleUrl: String, module: OtaModule, version: String) -> URL? {
    let base = bundleUrl.hasSuffix("/") ? String(bundleUrl.dropLast()) : bundleUrl
    let url = URL(string: "\(base)/\(module.modulePath)/\(version)/\(getBundleName()).zip")
    Log.d("OtaBundleManager::buildJsBundleRemoteUrl::url: \(url?.absoluteString ?? "nil")")
    return url
  }

  private static func buildJsBundleFilePath(modulePath: String, version: String) throws -> URL {
    try getFilesDir(modulePath: modulePath)
      .appendingPathComponent(version)
      .appendingPathComponent(getBundleName())
  }

  /// Application Support/<modulePath> — NOT Documents (user-visible + backed
  /// up); backup exclusion is set when the directory is created.
  private static func getFilesDir(modulePath: String) throws -> URL {
    try FileManager.default
      .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .appendingPathComponent(modulePath)
  }

  private static func excludeFromBackup(_ url: URL) {
    var mutableUrl = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    do {
      try mutableUrl.setResourceValues(values)
    } catch {
      Log.e("OtaBundleManager::excludeFromBackup failed for \(url.path): \(error.localizedDescription)")
    }
  }

  private static func getBundleName() -> String {
    "main.jsbundle"
  }
}

enum OtaBundleManagerError: Error {
  case invalidModule(reason: String)
  case invalidBundle(reason: String)
  case downloadFailed(reason: String)
}
