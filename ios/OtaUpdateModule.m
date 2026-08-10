#import <React/RCTBridgeModule.h>

// Generated Swift header for this pod's module (CashifyOtaUpdate). Angle-bracket
// form is canonical under use_frameworks!; quoted form covers static-library builds.
#if __has_include(<CashifyOtaUpdate/CashifyOtaUpdate-Swift.h>)
#import <CashifyOtaUpdate/CashifyOtaUpdate-Swift.h>
#else
#import "CashifyOtaUpdate-Swift.h"
#endif

// JS bridge, exposed as `NativeModules.CashifyOtaUpdate` (legacy paper module —
// do NOT add codegen). Mirrors the Android OtaUpdateModule.
@interface OtaUpdateModule : NSObject <RCTBridgeModule>
@end

@implementation OtaUpdateModule

RCT_EXPORT_MODULE(CashifyOtaUpdate);

+ (BOOL)requiresMainQueueSetup
{
  return NO;
}

// OTA bundle version when a downloaded bundle booted this session, else the
// host app's versionName (the shipped asset bundle).
RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(getOtaBundleVersion)
{
  return [OtaBundleManager currentBundleVersion];
}

RCT_EXPORT_METHOD(getFileSystemURL:(NSString *)moduleName
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
  [OtaBundleManager fileSystemURLForModule:moduleName
                                completion:^(NSString *_Nullable url, NSError *_Nullable error) {
    if (url != nil) {
      resolve(url);
    } else {
      reject(@"CashifyOtaUpdate", error.localizedDescription ?: @"Error getting file system URL", error);
    }
  }];
}

@end
