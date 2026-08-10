export interface CashifyOtaUpdateNativeModule {
  /**
   * Version of the JS bundle this session booted with: the downloaded OTA
   * bundle's version when one was loaded, else the app's own versionName
   * (the shipped asset bundle). Synchronous.
   */
  getOtaBundleVersion(): string;

  /**
   * Resolves a configured OTA module's bundle to a `file://` URL — for JS-side
   * loaders of non-launcher modules, and debugging. Rejects when the module is
   * unknown or has no bundle available.
   */
  getFileSystemURL(moduleName: string): Promise<string>;
}
