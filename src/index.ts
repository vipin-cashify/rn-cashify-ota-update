import {NativeModules, Platform} from 'react-native';

import type {CashifyOtaUpdateNativeModule} from './types';

export type {CashifyOtaUpdateNativeModule} from './types';

const LINKING_ERROR =
  "The package 'rn-cashify-ota-update' doesn't seem to be linked. Make sure: \n\n" +
  Platform.select({ios: "- You have run 'pod install'\n", default: ''}) +
  '- You rebuilt the app after installing the package\n';

const nativeModule: CashifyOtaUpdateNativeModule | undefined =
  NativeModules.CashifyOtaUpdate;

const proxy = new Proxy(
  {},
  {
    get(): never {
      throw new Error(LINKING_ERROR);
    },
  },
) as CashifyOtaUpdateNativeModule;

const safeModule: CashifyOtaUpdateNativeModule = nativeModule ?? proxy;

/** True when the native module is linked into this binary. */
export const isOtaUpdateAvailable = (): boolean => nativeModule != null;

/**
 * Version of the JS bundle this session booted with — the OTA version when a
 * downloaded bundle loaded, else the app versionName. Synchronous.
 */
export const getOtaBundleVersion = (): string => safeModule.getOtaBundleVersion();

/**
 * `file://` URL of a configured OTA module's bundle (disk bundle if a newer one
 * is installed, shipped asset otherwise). For JS-side loaders of non-launcher
 * modules, and debugging.
 */
export const getFileSystemURL = (moduleName: string): Promise<string> =>
  safeModule.getFileSystemURL(moduleName);
