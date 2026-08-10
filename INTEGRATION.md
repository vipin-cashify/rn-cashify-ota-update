# Integration Guide

Four host-side hooks. Autolinking registers the RN bridge module
(`NativeModules.CashifyOtaUpdate`) automatically — **do NOT add codegenConfig**
for this package (legacy paper module).

## 1. app.json

Add `otaVersion` + `otaModules` at the repo root (schema in README.md).

## 2. Android

**a) `android/app/build.gradle`** — anywhere AFTER
`apply plugin: "com.android.application"`:

```groovy
// OTA: packages the repo-root app.json into APK assets for the native module config.
apply from: "../../node_modules/rn-cashify-ota-update/android/ota-app-json.gradle"
```

(If your app.json isn't at `<android>/../app.json`, set `otaAppJsonFile` in the
root gradle.properties.)

**b) Application class** (RN 0.71+ bridgeless host):

```kotlin
import `in`.cashify.otaupdate.CashifyOtaUpdate

override val reactHost: ReactHost by lazy {
  // Synchronous + local-only (dir listing + an 18-byte read) — never blocks
  // the first frame; null falls back to the default asset loader / Metro.
  CashifyOtaUpdate.init(applicationContext)
  getDefaultReactHost(
    context = applicationContext,
    packageList = (PackageList(this).packages + extraPackages).toMutableList(),
    jsBundleFilePath = CashifyOtaUpdate.getLauncherBundleFilePath(applicationContext),
  )
}

override fun onCreate() {
  super.onCreate()
  // ...
  loadReactNative(this)
  // Background check — downloads for the NEXT launch. Never blocks/crashes startup.
  CashifyOtaUpdate.checkForUpdatesAsync(applicationContext)
}
```

## 3. iOS

**a) Xcode:** add the repo-root `app.json` to the app target as a bundle
resource (File > Add Files, reference `../app.json`).

**b) `AppDelegate.swift`:**

```swift
import CashifyOtaUpdate

// in didFinishLaunchingWithOptions, BEFORE startReactNative:
OtaModuleManager.shared.initModules()

// AFTER startReactNative:
OtaModuleManager.shared.loadBundlesAsync()

// in your RCTDefaultReactNativeFactoryDelegate:
override func bundleURL() -> URL? {
#if DEBUG
  RCTBundleURLProvider.sharedSettings().jsBundleURL(forBundleRoot: "index")
#else
  OtaBundleManager.getLauncherBundleFileURLLocal()
    ?? Bundle.main.url(forResource: "main", withExtension: "jsbundle")
#endif
}
```

**c) `pod install`.** The lib brings `FirebaseRemoteConfig` (unversioned — your
app must pin the Firebase SDK, see README) and `GzipSwift`.

## 4. Publish script

```json
"scripts": {
  "ota:build:native": "cashify-ota-publish"
}
```

Jenkins (WebBuilder pattern): a job with `buildNativeCmd: 'ota:build:native'`
and `BUILD_NATIVE=true` runs it per platform with the standard flags — the bin
tolerates WebBuilder's extra `--clean/--sentry/--federation` flags.

## Verification checklist (per platform, on stage)

1. Fresh install → logs `CashifyOTA`: "no valid disk bundle, using asset bundle".
2. Publish a bundle + set `rnb_<key>_latest_version` → relaunch → download +
   "bundle installed at".
3. Relaunch → "loading disk bundle <v>"; `getOtaBundleVersion()` returns `<v>`.
4. Rollback: lower the version key → relaunch twice → "rollback detected",
   second launch on asset.
5. Kill switches: per-module key, then global key → bundles wipe, offline
   persistence (airplane mode), auto-recovery on clear.
6. Offline fresh install → RC timeout logs, asset bundle, no crash.
