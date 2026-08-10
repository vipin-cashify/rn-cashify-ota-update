# rn-cashify-ota-update

Config-driven OTA (code-push style) JS bundle updates for Cashify React Native
apps. The app launches from the bundle shipped in the binary; a background
check asks Firebase Remote Config whether newer bundles exist per module,
downloads them from S3/CloudFront, and the **next** launch boots from them.
No app-store release for JS-only changes.

Battle-tested lineage: extracted from the CashifyOps app, whose implementation
is a single-bundle-capable port of the lego apps' multi-module OTA system.

## Install (git, no npm)

```json
"rn-cashify-ota-update": "github:vipin-cashify/rn-cashify-ota-update#v0.1.0"
```

Pin a **tag**, not `#main` — yarn.lock pins the resolved commit, so `#main`
consumers silently diverge between fresh installs and existing lockfiles.
Upgrade with `yarn up rn-cashify-ota-update`.

Prerequisites in the host app:
- Firebase configured (google-services.json / GoogleService-Info.plist;
  `FirebaseApp.configure()` on iOS). **The lib never configures Firebase.**
- iOS: the Firebase iOS SDK must be pinned by the host (via
  `@react-native-firebase/*` or an explicit `$FirebaseSDKVersion`) — the lib's
  `FirebaseRemoteConfig` pod dep is deliberately unversioned.
- Android: optionally set `firebaseBomVersion` / `kotlinxCoroutinesVersion` /
  `coreKtxVersion` in the root `ext` block to match your app's versions.
- `build/` must be gitignored in the consumer (the publish bin writes
  `build/ota/<platform>/`).

See **INTEGRATION.md** for the full wiring (4 small host-side hooks).

## app.json config

```json
{
  "otaVersion": "8.0.1",
  "otaModules": {
    "MyApp": {
      "moduleName": "MyApp",
      "modulePath": "my-app",
      "configKey": "myapp",
      "moduleVersion": "8.0.0",
      "bundlePriority": 1,
      "otaUpdates": true,
      "launcher": true
    }
  }
}
```

- `moduleVersion` — version of the bundle **shipped in the binary** (asset
  baseline). Bump alongside the app's versionName on every store release.
- `otaVersion` — the OTA release being published; must be semantically
  **greater** than the target module's `moduleVersion` (bin-enforced).
- `legoModules` is accepted as a fallback key for lego-style apps.
- 1 entry = single-bundle app. N entries = each module versions, downloads,
  rolls back and kill-switches **independently**. Only the `launcher: true`
  module boots natively; other modules' bundles are resolved from JS via
  `getFileSystemURL(moduleName)` for your own loader (e.g. Re.Pack ScriptManager).

## Remote Config keys

| Key | Scope | Meaning |
|---|---|---|
| `rn_bundle_url` | global | CDN base URL ("" = OTA disabled) |
| `rn_enable_safe_mode` | global | Nuclear kill switch — wipes ALL modules' downloaded bundles |
| `rnb_<configKey>_latest_version` | per module | Latest published bundle version ("" = none) |
| `rnb_<configKey>_enable_safe_mode` | per module | Kill switch for ONE module only |

Incident response, least to most drastic:
1. **Per-module rollback** — lower `rnb_<configKey>_latest_version`; devices
   delete newer disk versions for that module only.
2. **Per-module kill switch** — `rnb_<configKey>_enable_safe_mode = true`;
   that module's bundles wipe and it pins to its shipped state (launcher →
   asset bundle; non-launcher → unavailable to the JS loader). Others keep
   updating. Clearing the key auto-recovers.
3. **Global kill switch** — `rn_enable_safe_mode = true`; everything wipes.

Safe-mode flags are persisted on-device, so they hold even offline; recovery is
automatic when the flag clears. A JS-crashing bundle gets one bad session per
device — recovery happens at the next launch's background check (the launch
path is deliberately local-only, no network).

Native↔JS compatibility: gate new bundle versions with **RC conditions on app
version** — never publish a bundle that needs native code older binaries lack.

## Publishing

```bash
# from the consumer repo root
yarn cashify-ota-publish --platform=android --env=stage [--module=Name] [--ota-version=X] [--entry-file=index.js] [--dry-run=true] [--force=true]
```

Bundles with Metro (**plain JS — never hermesc**: the native downloader appends
an `END_OF_FILE_MARKER` that must land inside a trailing `//` comment the bin
adds), gzips (level 9, `.zip` extension by CDN convention), uploads to the
Cashify lego bucket for the env (`stage|beta|canary|prod`), then prints the
Remote Config key to bump manually. Prod artifacts are immutable without
`--force`. S3 objects must NOT carry `Content-Encoding: gzip` (the bin uploads
correctly — transparent CDN decompression would break the client gunzip).

Publish **both platforms before bumping the RC key** (the key is shared).

## JS API

```ts
import {getOtaBundleVersion, getFileSystemURL, isOtaUpdateAvailable} from 'rn-cashify-ota-update';

getOtaBundleVersion();          // "8.0.1" (OTA) or the app versionName (asset)
await getFileSystemURL('MyApp'); // file:// URL of a module's active bundle
```

## Debugging

Both platforms log with tag **`CashifyOTA`**:
`adb logcat -s CashifyOTA` / Console.app filter `CashifyOTA`.
Debug builds always use Metro and skip OTA entirely.
Remote Config is cached 300s — expect up to ~5 min propagation (+1 launch);
debuggable builds and the first launch after an app update force-fetch.
