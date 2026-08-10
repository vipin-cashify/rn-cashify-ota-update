#!/usr/bin/env node
/**
 * OTA bundle build + publish (rn-cashify-ota-update).
 *
 * Run from the CONSUMER repo root (installed as the `cashify-ota-publish` bin).
 * Builds the JS bundle for a module from the consumer's app.json `otaModules`
 * (or legacy `legoModules`), gzips it and
 * uploads to the lego CDN bucket for the target env at:
 *   <bucket>/<modulePath>/<otaVersion>/<bundleName>.zip
 *
 * Modeled on @reglobe/lego-cli's build.native.mjs so it is drop-in compatible
 * with the jenkins-build-pipeline WebBuilder invocation:
 *   yarn ota:build:native --platform=android --env=stage --dev=false \
 *     --dry-run=false --clean=true --force=false --sentry=false --federation=remote
 * (--clean/--sentry/--federation are accepted and ignored.)
 *
 * IMPORTANT:
 * - The payload is PLAIN JS gzipped (`.zip` extension is a lego naming
 *   convention). Never hermesc-compile it: the native downloader appends an
 *   END_OF_FILE_MARKER after the decompressed content, which only stays
 *   harmless inside Metro's trailing sourceMappingURL comment line.
 * - Upload metadata must NOT set Content-Encoding: gzip — CloudFront/URLSession
 *   would transparently decompress and the client-side gunzip would then fail.
 *   Plain `aws s3 cp` (as below, same as lego-cli) is correct.
 * - The OTA version (app.json `otaVersion`) must be semantically GREATER than
 *   the module's `moduleVersion` (the bundle shipped in the store binary),
 *   otherwise devices ignore the release. Enforced below.
 */

import {spawnSync} from 'node:child_process';
import {mkdirSync, readFileSync, writeFileSync} from 'node:fs';
import {join} from 'node:path';
import {gzipSync} from 'node:zlib';

// The bin runs from the CONSUMER repo — its app.json/index.js/build dir, not the lib's.
const ROOT = process.cwd();
const SEMVER_REGEX = /^\d+(\.\d+)*$/;
const IGNORED_FLAGS = ['clean', 'sentry', 'federation'];

function log(...args) {
  console.log('[ota-build-publish]', ...args);
}

function fail(message) {
  console.error('[ota-build-publish] ERROR:', message);
  process.exit(1);
}

// --- arg parsing: supports --key=value and --key value ---------------------
function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i++) {
    const token = argv[i];
    if (!token.startsWith('--')) fail(`Unexpected argument: ${token}`);
    const eq = token.indexOf('=');
    if (eq !== -1) {
      args[token.slice(2, eq)] = token.slice(eq + 1);
    } else {
      const next = argv[i + 1];
      if (next !== undefined && !next.startsWith('--')) {
        args[token.slice(2)] = next;
        i++;
      } else {
        args[token.slice(2)] = 'true';
      }
    }
  }
  return args;
}

function asBool(value, defaultValue = false) {
  if (value === undefined) return defaultValue;
  return String(value).toLowerCase() === 'true';
}

function compareSemanticVersions(v1, v2) {
  const c1 = v1.split('.').map(Number);
  const c2 = v2.split('.').map(Number);
  for (let i = 0; i < Math.min(c1.length, c2.length); i++) {
    if (c1[i] !== c2[i]) return c1[i] - c2[i];
  }
  return c1.length - c2.length;
}

// --- env → infra map (mirrors @reglobe/lego-cli build.native.mjs) ----------
const ENV_CONFIG = {
  stage: {bucket: 's3://rnd.stage.lego.cashify.in', cloudfrontId: '', profile: ['--profile', 'stage']},
  beta: {bucket: 's3://rnd.beta.lego.cashify.in', cloudfrontId: 'EU1MBLCQ6BPID', profile: ['--profile', 'beta']},
  canary: {bucket: 's3://rnd.canary.lego.cashify.in', cloudfrontId: 'E3S67QGPV3MZHI', profile: []},
  prod: {bucket: 's3://rnd.lego.cashify.in', cloudfrontId: 'E1SE00GTM6RCHK', profile: []},
};

const BUNDLE_NAMES = {
  android: 'index.android.bundle',
  ios: 'main.jsbundle',
};

// --- main -------------------------------------------------------------------
const args = parseArgs(process.argv.slice(2));

for (const flag of IGNORED_FLAGS) {
  if (flag in args) log(`ignored flag: --${flag}=${args[flag]}`);
}
const knownFlags = ['platform', 'env', 'dev', 'force', 'dry-run', 'dryrun', 'module', 'ota-version', 'entry-file', ...IGNORED_FLAGS];
for (const key of Object.keys(args)) {
  if (!knownFlags.includes(key)) fail(`Unknown flag: --${key}`);
}

const platform = args.platform;
if (!['android', 'ios'].includes(platform)) fail(`--platform must be android|ios (got: ${platform})`);

const appEnv = args.env;
if (!Object.keys(ENV_CONFIG).includes(appEnv)) fail(`--env must be stage|beta|canary|prod (got: ${appEnv})`);

const dev = asBool(args.dev, false);
const force = asBool(args.force, false);
const dryRun = asBool(args['dry-run'] ?? args.dryrun, false);

const appJson = JSON.parse(readFileSync(join(ROOT, 'app.json'), 'utf-8'));
const otaModules = appJson.otaModules ?? appJson.legoModules ?? {};
const moduleKey = args.module
  ? args.module
  : Object.keys(otaModules).find((key) => otaModules[key].launcher);
const legoModule = otaModules[moduleKey];
if (!legoModule) fail(`Module not found in app.json otaModules (module: ${moduleKey ?? '<launcher>'})`);
const entryFile = args['entry-file'] ?? 'index.js';

const otaVersion = args['ota-version'] ?? appJson.otaVersion;
if (!otaVersion || !SEMVER_REGEX.test(otaVersion)) {
  fail(`otaVersion '${otaVersion}' is not a valid version (digits and dots only) — devices would silently ignore it`);
}
if (!SEMVER_REGEX.test(legoModule.moduleVersion)) {
  fail(`moduleVersion '${legoModule.moduleVersion}' in app.json is not a valid version`);
}
if (compareSemanticVersions(otaVersion, legoModule.moduleVersion) <= 0) {
  fail(
    `otaVersion (${otaVersion}) must be GREATER than moduleVersion (${legoModule.moduleVersion}) — ` +
    `the shipped asset baseline always wins ties, so this release would be a no-op`
  );
}

const bundleName = BUNDLE_NAMES[platform];
const buildDir = join(ROOT, 'build', 'ota', platform);
const bundlePath = join(buildDir, bundleName);
const assetsDest = join(buildDir, 'assets');
mkdirSync(assetsDest, {recursive: true});

log('*'.repeat(60));
log(`module: ${legoModule.moduleName} (${legoModule.modulePath})`);
log(`otaVersion: ${otaVersion} (shipped baseline: ${legoModule.moduleVersion})`);
log(`platform: ${platform}, env: ${appEnv}, dev: ${dev}, force: ${force}, dryRun: ${dryRun}`);
log('*'.repeat(60));

// 1) Metro bundle (PLAIN JS — see header).
const {status: bundleStatus} = spawnSync(
  'npx',
  [
    'react-native', 'bundle',
    '--platform', platform,
    '--dev', String(dev),
    '--minify', 'true',
    '--entry-file', entryFile,
    '--bundle-output', bundlePath,
    '--assets-dest', assetsDest,
    '--reset-cache',
  ],
  {encoding: 'utf-8', cwd: ROOT, stdio: 'inherit'},
);
if (bundleStatus !== 0) fail(`react-native bundle failed with status ${bundleStatus}`);

log(
  'NOTE: bundled image assets are discarded — OTA cannot ship NEW require()\'d images; ' +
  'images added since the shipped binary must be remote URLs.'
);

// 2) gzip (extension .zip is a lego CDN naming convention).
//
// A trailing comment-opener (no newline after it!) is appended first: the
// native downloader writes the literal bytes END_OF_FILE_MARKER after the
// decompressed content as its integrity marker, and plain Metro bundles end
// with an executable statement (`__r(0);`) — a bare marker would be evaluated
// as an undefined identifier and throw at runtime. With this suffix the marker
// lands inside a `//` line comment and the file stays valid JS.
const bundleBuffer = Buffer.concat([readFileSync(bundlePath), Buffer.from('\n//')]);
const zippedBuffer = gzipSync(bundleBuffer, {level: 9});
const zipBundleName = `${bundleName}.zip`;
const bundleZipPath = join(buildDir, zipBundleName);
writeFileSync(bundleZipPath, zippedBuffer);
log(`bundle: ${(bundleBuffer.length / 1048576).toFixed(2)} MiB, gzipped: ${(zippedBuffer.length / 1048576).toFixed(2)} MiB`);

// 3) Upload.
const {bucket, cloudfrontId, profile} = ENV_CONFIG[appEnv];
const s3Key = `${legoModule.modulePath}/${otaVersion}/${zipBundleName}`;
const bundleBucketPath = `${bucket}/${s3Key}`;

if (dryRun) {
  log(`DRY RUN — would upload ${bundleZipPath} to ${bundleBucketPath}`);
  log(`DRY RUN — aws s3 cp ${bundleZipPath} ${bundleBucketPath} ${profile.join(' ')}`);
  process.exit(0);
}

const {status: headStatus} = spawnSync(
  'aws',
  ['s3api', 'head-object', '--bucket', bucket.replace('s3://', ''), '--key', s3Key, ...profile],
  {encoding: 'utf-8', cwd: ROOT},
);
const s3BundleExists = headStatus === 0;
if (s3BundleExists) {
  if (force) {
    log(`object already exists at ${bundleBucketPath} — force overwriting`);
  } else if (appEnv === 'prod') {
    fail(`object already exists at ${bundleBucketPath} — bump otaVersion (prod artifacts are immutable without --force)`);
  } else {
    log(`object already exists at ${bundleBucketPath} — overwriting (non-prod)`);
  }
}

log(`uploading to ${bundleBucketPath}`);
const {status: uploadStatus} = spawnSync(
  'aws',
  ['s3', 'cp', bundleZipPath, bundleBucketPath, ...profile],
  {encoding: 'utf-8', cwd: ROOT, stdio: 'inherit'},
);
if (uploadStatus !== 0) fail(`aws s3 cp failed with status ${uploadStatus}`);

// 4) CloudFront invalidation only when an existing object was overwritten.
if (s3BundleExists && cloudfrontId) {
  log(`invalidating CloudFront ${cloudfrontId} for /${s3Key}`);
  const {status: invalidationStatus} = spawnSync(
    'aws',
    ['cloudfront', 'create-invalidation', '--distribution-id', cloudfrontId, '--paths', `/${s3Key}`, ...profile],
    {encoding: 'utf-8', cwd: ROOT, stdio: 'inherit'},
  );
  if (invalidationStatus !== 0) fail(`cloudfront invalidation failed with status ${invalidationStatus}`);
}

log('done. Next steps:');
log(`  1. verify: curl -I https://${bucket.replace('s3://', '')}/${s3Key}`);
log(`  2. publish the OTHER platform for the same otaVersion (shared RC key)`);
log(`  3. Firebase console (${appEnv}): set rnb_${legoModule.configKey}_latest_version = ${otaVersion}`);
