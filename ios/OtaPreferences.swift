import Foundation

/// Local persistence for the OTA system. The safe-mode flags mirror the Remote
/// Config kill switches so the NEXT launch stays on the asset bundle even offline.
enum OtaPreferences {

  private static let safeModeKey = "ota_safe_mode_enabled"
  private static let appVersionKey = "ota_app_version"
  // Prefixed so a module configKey can never collide with the global key.
  private static let moduleSafeModePrefix = "module_safe_mode_"

  static var isSafeModeEnabled: Bool {
    UserDefaults.standard.bool(forKey: safeModeKey)
  }

  static func setSafeModeEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: safeModeKey)
  }

  static func isModuleSafeModeEnabled(_ configKey: String) -> Bool {
    UserDefaults.standard.bool(forKey: moduleSafeModePrefix + configKey)
  }

  static func setModuleSafeModeEnabled(_ configKey: String, _ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: moduleSafeModePrefix + configKey)
  }

  static var storedAppVersion: String? {
    UserDefaults.standard.string(forKey: appVersionKey)
  }

  static func setStoredAppVersion(_ version: String) {
    UserDefaults.standard.set(version, forKey: appVersionKey)
  }
}
