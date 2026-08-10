import Foundation

/// Parses the module map from the app.json bundle resource (key `otaModules`,
/// falling back to `legoModules` for lego-style apps) and orchestrates the
/// background OTA check for every module with `otaUpdates: true`.
public final class OtaModuleManager {

  public static let shared = OtaModuleManager()

  private(set) var modules: [String: OtaModule] = [:]
  private var initialized = false

  private let lock = NSLock()
  private var bundleVersionMap: [String: String] = [:]

  private init() {}

  /// Synchronous, local-only app.json parse — safe on the launch path. Never
  /// throws; on any failure the module map stays empty and OTA is disabled.
  public func initModules() {
    guard !initialized else { return }
    initialized = true
    guard let url = Bundle.main.url(forResource: "app", withExtension: "json") else {
      Log.e("OtaModuleManager::init::app.json not found in bundle, OTA disabled")
      return
    }
    do {
      let data = try Data(contentsOf: url)
      guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        Log.e("OtaModuleManager::init::app.json is not an object, OTA disabled")
        return
      }
      let modulesJson = (json["otaModules"] as? [String: [String: Any]])
        ?? (json["legoModules"] as? [String: [String: Any]])
      guard let modulesJson else {
        Log.e("OtaModuleManager::init::no otaModules/legoModules in app.json, OTA disabled")
        return
      }
      var parsed: [String: OtaModule] = [:]
      for (key, moduleJson) in modulesJson {
        guard
          let moduleName = moduleJson["moduleName"] as? String,
          let modulePath = moduleJson["modulePath"] as? String,
          let configKey = moduleJson["configKey"] as? String,
          let moduleVersion = moduleJson["moduleVersion"] as? String
        else {
          Log.e("OtaModuleManager::init::invalid module entry: \(key)")
          continue
        }
        parsed[key] = OtaModule(
          moduleName: moduleName,
          modulePath: modulePath,
          configKey: configKey,
          scheme: moduleJson["scheme"] as? String ?? "",
          moduleVersion: moduleVersion,
          bundlePriority: moduleJson["bundlePriority"] as? Int ?? Int.max,
          otaUpdates: moduleJson["otaUpdates"] as? Bool ?? false,
          launcher: moduleJson["launcher"] as? Bool ?? false
        )
      }
      modules = parsed
      Log.d("OtaModuleManager::init::modules: \(modules.keys.joined(separator: ","))")
    } catch {
      Log.e("OtaModuleManager::init failed, OTA disabled: \(error.localizedDescription)")
      modules = [:]
    }
  }

  /// Fire-and-forget background check: temp cleanup -> Remote Config -> global
  /// then per-module safe-mode kill switches -> per-module download-if-needed +
  /// stale/rollback cleanup. Downloaded bundles are picked up on the NEXT launch.
  public func loadBundlesAsync() {
    Task.detached(priority: .background) {
      await self.loadBundles()
    }
  }

  private func loadBundles() async {
    initModules()
    let otaModules = modules.values.filter { $0.otaUpdates }
    guard !otaModules.isEmpty else {
      Log.d("OtaModuleManager::no OTA modules configured, skipping")
      return
    }

    OtaBundleManager.cleanupTemporaryBundles()

    // Global kill switch: wipes EVERY module and stops the whole check.
    if await OtaRemoteConfig.getEnableSafeMode() {
      Log.d("OtaModuleManager::global safe mode enabled, clearing all module bundles")
      for module in otaModules {
        OtaBundleManager.cleanupModuleBundles(module: module)
      }
      // Persisted locally so the NEXT launch stays on the asset bundle even offline.
      OtaPreferences.setSafeModeEnabled(true)
      return
    }
    OtaPreferences.setSafeModeEnabled(false)

    let sortedModules = otaModules.sorted {
      ($0.bundlePriority, $0.moduleName) < ($1.bundlePriority, $1.moduleName)
    }
    for module in sortedModules {
      // Per-module kill switch: wipes ONLY this module; others continue.
      if await OtaRemoteConfig.getModuleEnableSafeMode(module: module) {
        Log.d("OtaModuleManager::module safe mode enabled for \(module.moduleName), clearing its bundles")
        OtaBundleManager.cleanupModuleBundles(module: module)
        OtaPreferences.setModuleSafeModeEnabled(module.configKey, true)
        continue
      }
      OtaPreferences.setModuleSafeModeEnabled(module.configKey, false)

      Log.d("OtaModuleManager::checking module: \(module.moduleName), priority: \(module.bundlePriority)")
      await OtaBundleManager.downloadBundleIfNeeded(module: module)
      await OtaBundleManager.cleanupStaleBundles(module: module)
    }
  }

  func launcherModule() -> OtaModule? {
    modules.values.first { $0.launcher }
  }

  func getModuleByName(_ moduleName: String) -> OtaModule? {
    modules[moduleName]
  }

  func getBundleVersion(_ moduleName: String) -> String? {
    lock.lock()
    defer { lock.unlock() }
    return bundleVersionMap[moduleName]
  }

  func setBundleVersion(moduleName: String, version: String) {
    lock.lock()
    defer { lock.unlock() }
    bundleVersionMap[moduleName] = version
  }
}
