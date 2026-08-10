import Foundation
import FirebaseRemoteConfig

func isDebugMode() -> Bool {
#if DEBUG
  return true
#else
  return false
#endif
}

/// Deduplicates concurrent Remote Config fetches: one 2s attempt, one 5s retry,
/// then getters serve whatever is activated (unset keys -> ""/false, which are
/// exactly the OTA-disabled defaults). Force-fetches (bypassing the 300s cache)
/// on debug builds and on the first launch after an app update.
actor OtaRemoteConfigManager {
  private var isConfigFetched = false
  private var fetchTried = false
  private var settingsApplied = false
  private var currentTask: Task<Void, Never>?

  private let currentAppVersion =
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"

  func fetchRemoteConfigWithLock() async {
    if isConfigFetched || fetchTried {
      return
    }
    if let task = currentTask {
      await task.value
    } else {
      let task = Task {
        await self.performFetch(forceFetch: self.shouldForceFetch())
      }
      currentTask = task
      _ = await task.value
    }
  }

  private func performFetch(forceFetch: Bool) async {
    defer { currentTask = nil }
    applySettingsOnce()
    // 2s budget first; on failure/timeout retry once with 5s (Android parity).
    var success = await fetchRemoteConfig(forceFetch: forceFetch, timeoutSeconds: 2)
    if !success {
      Log.d("OtaRemoteConfig::fetch failed/timed out, retrying with 5s timeout")
      success = await fetchRemoteConfig(forceFetch: forceFetch, timeoutSeconds: 5)
    }
    if success {
      isConfigFetched = true
      if forceFetch {
        OtaPreferences.setStoredAppVersion(currentAppVersion)
      }
    } else {
      fetchTried = true
      Log.d("OtaRemoteConfig::fetch failed after retry")
    }
  }

  private func applySettingsOnce() {
    guard !settingsApplied else { return }
    let remoteConfig = RemoteConfig.remoteConfig()
    let configSettings = RemoteConfigSettings()
    configSettings.minimumFetchInterval = 300
    remoteConfig.configSettings = configSettings
    settingsApplied = true
  }

  private func fetchRemoteConfig(forceFetch: Bool, timeoutSeconds: Double) async -> Bool {
    do {
      return try await Task<Bool, Error>.withCheckedTimeout(seconds: timeoutSeconds) {
        let remoteConfig = RemoteConfig.remoteConfig()
        if forceFetch {
          Log.d("OtaRemoteConfig::forced fetch")
          try await remoteConfig.fetch(withExpirationDuration: 0)
          _ = try await remoteConfig.activate()
        } else {
          Log.d("OtaRemoteConfig::fetch")
          _ = try await remoteConfig.fetchAndActivate()
        }
        return true
      }
    } catch is TimeoutError {
      Log.d("OtaRemoteConfig::fetch timed out after \(timeoutSeconds)s")
      return false
    } catch {
      Log.d("OtaRemoteConfig::fetch failed: \(error.localizedDescription)")
      return false
    }
  }

  private func shouldForceFetch() -> Bool {
    if isDebugMode() { return true }
    let storedVersion = OtaPreferences.storedAppVersion
    if storedVersion != currentAppVersion {
      Log.d("OtaRemoteConfig::app version changed \(storedVersion ?? "nil") -> \(currentAppVersion), forcing fetch")
      return true
    }
    return false
  }
}

/// Remote Config access for the OTA system. FirebaseApp.configure() must be
/// done by the HOST app — this object never configures Firebase itself.
///
/// Keys: `rn_bundle_url` ("" = OTA disabled), `rn_enable_safe_mode` (global),
/// `rnb_<configKey>_latest_version` and `rnb_<configKey>_enable_safe_mode` per module.
enum OtaRemoteConfig {

  private static let manager = OtaRemoteConfigManager()

  private static func getString(_ key: String) async -> String {
    await manager.fetchRemoteConfigWithLock()
    // stringValue is String? on Firebase iOS SDK 10.x (non-optional from 11).
    return RemoteConfig.remoteConfig().configValue(forKey: key).stringValue ?? ""
  }

  private static func getBoolean(_ key: String) async -> Bool {
    await manager.fetchRemoteConfigWithLock()
    return RemoteConfig.remoteConfig().configValue(forKey: key).boolValue
  }

  static func getBundleUrl() async -> String {
    await getString("rn_bundle_url")
  }

  static func getEnableSafeMode() async -> Bool {
    await getBoolean("rn_enable_safe_mode")
  }

  static func getModuleEnableSafeMode(module: OtaModule) async -> Bool {
    await getBoolean("rnb_\(module.configKey)_enable_safe_mode")
  }

  static func getBundleLatestVersion(module: OtaModule) async -> String {
    await getString("rnb_\(module.configKey)_latest_version")
  }
}
