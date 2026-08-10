# Integration Guide — rn-cashify-ota-update

Step-by-step guide to add OTA (over-the-air) JS bundle updates to any Cashify
React Native app. After integration, you can ship JS-only changes to users
**without an app-store release**: publish a bundle to S3, bump one Firebase
Remote Config key, and every device picks it up on its next two launches.

Throughout this guide we use an example app called **MyShop**
(`com.cashify.myshop`) so you can see exactly what to substitute.

---

## How it works (2 minutes)

```
App launch
  ├── Is there a valid DOWNLOADED bundle newer than the one shipped in the
  │   binary, and no kill switch active?  (local check — no network, instant)
  │     ├── yes → boot from the downloaded bundle
  │     └── no  → boot from the shipped bundle (normal RN behavior)
  │
  └── In the background (after the app is up):
        1. Ask Firebase Remote Config: "what's the latest bundle version?"
        2. Newer than what we have? → download from S3/CloudFront,
           verify integrity, store on disk
        3. NEXT launch boots from it
```

Key properties:
- **The launch decision never touches the network** — cold start stays fast,
  and the app works fully offline.
- A bad update is recoverable three ways (rollback / per-module kill switch /
  global kill switch — see [Remote Config keys](#remote-config-keys-explained)).
- Debug builds always use Metro and ignore OTA completely.

---

## Prerequisites

| Requirement | Why |
|---|---|
| React Native ≥ 0.71 (bridgeless host recommended) | `getDefaultReactHost(jsBundleFilePath:)` hook |
| Firebase configured in the app (google-services.json / GoogleService-Info.plist) | Version checks use Remote Config. **This lib never calls `FirebaseApp.configure()` — your app must.** |
| iOS: Firebase SDK pinned by the host | via `@react-native-firebase/*` or `$FirebaseSDKVersion` in the Podfile — the lib's `FirebaseRemoteConfig` pod dep is deliberately unversioned |
| `build/` in the consumer repo's `.gitignore` | the publish bin writes `build/ota/<platform>/` |
| AWS CLI creds for the lego buckets (publisher machine / Jenkins agent only) | uploads; devices only need HTTPS |

---

## Step 1 — Install

```json
// package.json
"rn-cashify-ota-update": "github:vipin-cashify/rn-cashify-ota-update#v0.1.0"
```

```bash
yarn install
cd ios && pod install
```

Always pin a **tag** (`#v0.1.0`), never `#main` — yarn.lock pins the resolved
commit, so `#main` consumers silently diverge between fresh installs and
existing lockfiles. Upgrade deliberately with `yarn up rn-cashify-ota-update`.

> Android (optional): if your root `build.gradle` `ext` block pins versions,
> the lib respects `firebaseBomVersion`, `kotlinxCoroutinesVersion`,
> `coreKtxVersion`, `kotlinVersion`.

## Step 2 — app.json config

Add two things to your repo-root `app.json`:

```json
{
  "name": "MyShop",
  "otaVersion": "1.0.1",
  "otaModules": {
    "MyShop": {
      "moduleName": "MyShop",
      "modulePath": "my-shop",
      "configKey": "myshop",
      "moduleVersion": "1.0.0",
      "bundlePriority": 1,
      "otaUpdates": true,
      "launcher": true
    }
  }
}
```

| Field | Meaning | Example |
|---|---|---|
| `modulePath` | Folder name on the CDN and on-device. Unique per app across all Cashify apps (it shares the lego buckets!) | `my-shop` |
| `configKey` | Short key used inside Remote Config key names | `myshop` → `rnb_myshop_latest_version` |
| `moduleVersion` | Version of the JS **shipped inside the binary** (the baseline). Bump it together with your app versionName on every store release | `1.0.0` |
| `otaVersion` | The OTA release you are about to publish. Must be **greater** than `moduleVersion` (the bin enforces this) | `1.0.1` |
| `launcher` | `true` for the module that boots the app. Exactly one | |
| `bundlePriority` | Download order when you have several modules (lower = first) | `1` |

Most apps have **one** module (the app itself). You can add more later — each
versions, rolls back and kill-switches independently (see
[Multi-module](#multi-module-apps)).

## Step 3 — Android wiring (2 edits)

**a) `android/app/build.gradle`** — anywhere AFTER
`apply plugin: "com.android.application"`:

```groovy
// OTA: packages the repo-root app.json into APK assets for the native module config.
apply from: "../../node_modules/rn-cashify-ota-update/android/ota-app-json.gradle"
```

**b) Your `Application` class:**

```kotlin
import `in`.cashify.otaupdate.CashifyOtaUpdate

class MyShopApp : Application(), ReactApplication {

  override val reactHost: ReactHost by lazy {
    CashifyOtaUpdate.init(applicationContext)
    getDefaultReactHost(
      context = applicationContext,
      packageList = PackageList(this).packages,
      // null → default asset bundle / Metro in debug
      jsBundleFilePath = CashifyOtaUpdate.getLauncherBundleFilePath(applicationContext),
    )
  }

  override fun onCreate() {
    super.onCreate()
    loadReactNative(this)
    // Downloads newer bundles for the NEXT launch. Never blocks startup.
    CashifyOtaUpdate.checkForUpdatesAsync(applicationContext)
  }
}
```

## Step 4 — iOS wiring (3 edits)

**a) Xcode:** add the repo-root `app.json` to the app target as a bundle
resource (File → Add Files → select `../app.json`, tick your app target).

**b) `AppDelegate.swift`:**

```swift
import CashifyOtaUpdate

// in didFinishLaunchingWithOptions, AFTER FirebaseApp.configure(),
// BEFORE startReactNative:
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

**c)** `cd ios && pod install`

## Step 5 — publish script

```json
// package.json
"scripts": {
  "ota:build:native": "cashify-ota-publish"
}
```

Run it **from the repo root** (it reads `./app.json`).

---

## Remote Config keys (explained)

Open the Firebase console → your app's project → **Remote Config**. You will
create up to 4 kinds of keys. For our MyShop example (`configKey: "myshop"`):

| Key | Type | Example value | What it does |
|---|---|---|---|
| `rn_bundle_url` | String | `https://rnd.lego.cashify.in` | CDN base URL for this environment. `""` (empty) = OTA completely off. **One per project, shared by all modules.** |
| `rnb_myshop_latest_version` | String | `1.0.1` | "The latest published bundle for the *myshop* module is 1.0.1." Devices with anything older download it. `""` = nothing published. **One per module.** |
| `rnb_myshop_enable_safe_mode` | Boolean | `false` | Per-module kill switch. `true` → every device deletes *myshop*'s downloaded bundles and pins to the shipped bundle until you set it back. **One per module, optional (unset = false).** |
| `rn_enable_safe_mode` | Boolean | `false` | GLOBAL kill switch — same as above but for ALL modules at once. |

`rn_bundle_url` per environment:

| Env | Value |
|---|---|
| stage | `https://rnd.stage.lego.cashify.in` |
| beta | `https://rnd.beta.lego.cashify.in` |
| canary | `https://rnd.canary.lego.cashify.in` |
| prod | `https://rnd.lego.cashify.in` |

### ⚠️ If several app flavors share one Firebase project

Scope values with a **condition** so a test rollout never reaches prod users:

1. Remote Config → Conditions → *Add condition*
   → Name: `myshop_stage` → Applies if **App = com.cashify.myshop.stage**.
2. On each key, *Add new value for condition* → `myshop_stage` → the test
   value; keep the **default** value safe (`""` / `false`).

### ⚠️ New JS that needs new native code

If bundle `1.2.0` calls a native module that only exists in binaries ≥ `1.2.0`,
add a condition on **App version ≥ 1.2.0** for `rnb_myshop_latest_version` and
give older versions the last compatible bundle. Never publish a bundle to
binaries whose native side can't run it.

---

## Publishing an update — full example

You fixed a JS bug in MyShop (shipped binary = `1.0.0`) and want to ship it OTA:

```bash
# 1. Bump otaVersion in app.json:  "otaVersion": "1.0.1"   (via PR)

# 2. Build + upload BOTH platforms (repo root; needs AWS creds or run via Jenkins):
yarn ota:build:native --platform=android --env=stage
yarn ota:build:native --platform=ios     --env=stage

# 3. Verify both artifacts exist:
curl -I https://rnd.stage.lego.cashify.in/my-shop/1.0.1/index.android.bundle.zip
curl -I https://rnd.stage.lego.cashify.in/my-shop/1.0.1/main.jsbundle.zip

# 4. Firebase console:  rnb_myshop_latest_version = 1.0.1  → Publish changes
```

Devices fetch RC (cached up to 300s), download on that launch, and **run the
new bundle on the launch after that**. Verify on a device:
`adb logcat -s CashifyOTA` → "downloading remote bundle 1.0.1" → relaunch →
"loading disk bundle 1.0.1".

Useful bin flags: `--dry-run=true` (build+gzip only, no upload),
`--module=Name` (non-launcher module), `--ota-version=X` (override app.json),
`--entry-file=src/index.js`, `--force=true` (overwrite existing artifact +
CloudFront invalidation; prod artifacts are immutable without it).

Rules the bin enforces / you must follow:
- **Plain JS only** — never hermesc-compile the OTA bundle (the downloader
  appends an integrity marker that must land in a trailing `//` comment).
- OTA version must be **greater** than `moduleVersion`, or devices ignore it.
- Publish **both platforms before** bumping the RC key (it's shared).
- Never hand-set `Content-Encoding: gzip` on the S3 objects.
- OTA cannot ship NEW `require()`d images — new imagery must be remote URLs
  until the next store release.

## Something broke — incident playbook

Least to most drastic (all take effect within ~5 min + next launch):

```text
1. ROLLBACK one module      rnb_myshop_latest_version: 1.0.1 → 1.0.0
                            devices delete the 1.0.1 bundle, run 1.0.0/shipped
2. KILL one module          rnb_myshop_enable_safe_mode = true
                            myshop pins to its shipped bundle; other modules unaffected
3. KILL everything          rn_enable_safe_mode = true
                            all downloaded bundles wiped, everything on shipped bundles
```

Kill-switch flags persist on-device (work offline afterwards). Recovery is
automatic when you set the key back to `false` — devices re-download. Note: a
JS-crashing bundle still gets **one bad session** per device; recovery happens
at the next launch's background check.

## Multi-module apps

Add more entries to `otaModules` — e.g. a `Reports` module
(`configKey: "reports"`, `modulePath: "myshop-reports"`, `launcher: false`):

- Its own RC keys: `rnb_reports_latest_version`, `rnb_reports_enable_safe_mode`.
- Publish with `yarn ota:build:native --module=Reports --ota-version=2.1.0 ...`.
- Download/rollback/kill switch are fully independent of other modules.
- Only the launcher boots natively; load a non-launcher bundle from JS:

```ts
import {getFileSystemURL} from 'rn-cashify-ota-update';
const url = await getFileSystemURL('Reports'); // file://... for your loader
```

## JS API

```ts
import {getOtaBundleVersion, getFileSystemURL, isOtaUpdateAvailable} from 'rn-cashify-ota-update';

getOtaBundleVersion();  // "1.0.1" when an OTA bundle booted, else the app versionName
```

## Verification checklist (run once per platform on stage)

1. Fresh install → `CashifyOTA` logs: "no valid disk bundle, using asset bundle".
2. Publish + set the version key → relaunch → "downloading remote bundle" →
   "bundle installed at".
3. Relaunch → "loading disk bundle <v>"; `getOtaBundleVersion()` = `<v>`.
4. Rollback (lower the key) → relaunch twice → "rollback detected", then asset.
5. Kill switch on → bundles wipe; relaunch in airplane mode → still shipped
   bundle. Off → re-download.
6. Airplane-mode fresh install → RC timeout logs, normal startup, no crash.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `LINKING_ERROR` from the JS API | Rebuild the app after install; iOS: re-run `pod install` |
| "no otaModules/legoModules in app.json, OTA disabled" | Android: the gradle `apply from:` line is missing; iOS: app.json not added as a bundle resource |
| Download never happens | `rn_bundle_url` or `rnb_<key>_latest_version` empty / not published, RC condition doesn't match the app, or version ≤ `moduleVersion` |
| Update takes minutes to arrive | Remote Config caches 300s — expected. App-update or debuggable builds force-fetch |
| Bundle downloads but next launch still old | Version not strictly greater than `moduleVersion`, or a safe-mode flag is set |
| `pod install` Firebase version conflict | Host must pin the Firebase SDK (RNFB or `$FirebaseSDKVersion`) |
