import Foundation

/// One OTA-updatable JS bundle, parsed from the `legoModules` map in the
/// app.json bundle resource (same schema as the lego apps, minus firestore).
///
/// `moduleVersion` is the version of the bundle SHIPPED in this binary (the
/// asset baseline) — OTA versions published for the module must be semantically
/// greater. `launcher` marks the module whose bundle boots React Native; its
/// asset fallback is the stock `main.jsbundle`.
struct OtaModule {
  let moduleName: String
  let modulePath: String
  let configKey: String
  let scheme: String
  let moduleVersion: String
  let bundlePriority: Int
  let otaUpdates: Bool
  let launcher: Bool
}
